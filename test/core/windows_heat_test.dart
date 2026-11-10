import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/power_profiles.dart';
import 'package:anyps5_desktop/core/windows_heat.dart';
import 'package:test/test.dart';

/// The heat on Windows: the levels a processor's and a graphics card's temperature map to, the
/// reader's lines, the script that runs with administrator rights, and nothing read where nothing
/// is there.
void main() {
  group('levels', () {
    test('a processor or thermal zone: 75, 85 and 95 °C, lower against a critical trip', () {
      expect(PowerReader.processorLevel(74.9), ThermalLevel.nominal);
      expect(PowerReader.processorLevel(75), ThermalLevel.fair);
      expect(PowerReader.processorLevel(85), ThermalLevel.serious);
      expect(PowerReader.processorLevel(94.9), ThermalLevel.serious);
      expect(PowerReader.processorLevel(95), ThermalLevel.critical);
      // A zone whose critical trip is 90 °C: serious from 75, critical from 85.
      expect(PowerReader.processorLevel(75, critical: 90), ThermalLevel.serious);
      expect(PowerReader.processorLevel(85, critical: 90), ThermalLevel.critical);
      // A trip far up changes nothing.
      expect(PowerReader.processorLevel(84, critical: 128), ThermalLevel.fair);
    });

    test('a graphics card: 75, 85 and 92 °C, lower against its own slowdown temperature', () {
      expect(PowerReader.graphicsLevel(74.9), ThermalLevel.nominal);
      expect(PowerReader.graphicsLevel(80), ThermalLevel.fair);
      expect(PowerReader.graphicsLevel(85), ThermalLevel.serious);
      expect(PowerReader.graphicsLevel(91.9), ThermalLevel.serious);
      expect(PowerReader.graphicsLevel(92), ThermalLevel.critical);
      // A card that slows down at 87 °C: serious from 82, critical at 87.
      expect(PowerReader.graphicsLevel(82, slowdown: 87), ThermalLevel.serious);
      expect(PowerReader.graphicsLevel(87, slowdown: 87), ThermalLevel.critical);
      expect(PowerReader.graphicsLevel(90, slowdown: 100), ThermalLevel.serious);
    });

    test('a card is critical sooner than a processor at the same temperature', () {
      expect(const HeatSensor.graphics(93).level, ThermalLevel.critical);
      expect(const HeatSensor.zone(93).level, ThermalLevel.serious);
    });

    test('the hottest plausible sensor wins; none is no level', () {
      expect(WindowsHeat.levelOf(const []), isNull);
      expect(WindowsHeat.levelOf(const [HeatSensor.zone(48), HeatSensor.graphics(86)]), ThermalLevel.serious);
      expect(WindowsHeat.levelOf(const [HeatSensor.zone(52), HeatSensor.graphics(66)]), ThermalLevel.nominal);
      // A zone left at 0 °C or a sensor at 200 °C is not there.
      expect(WindowsHeat.levelOf(const [HeatSensor.zone(0.05), HeatSensor.graphics(200)]), isNull);
      expect(WindowsHeat.levelOf(const [HeatSensor.zone(-273.15), HeatSensor.zone(61)]), ThermalLevel.nominal);
    });

    test('the Windows reading carries the level given; without one the heat is not read', () {
      final cool = PowerReader.fromWindowsStatus(acLine: 1, batteryFlag: 8, percent: 90);
      expect(cool.readsHeat, isFalse);
      final hot = PowerReader.fromWindowsStatus(acLine: 1, batteryFlag: 8, percent: 90, thermal: ThermalLevel.serious);
      expect(hot.readsHeat, isTrue);
      expect(hot.hot, isTrue);
    });
  });

  group('the reader\'s lines', () {
    final now = DateTime.utc(2026, 11, 10, 12);
    final seconds = now.millisecondsSinceEpoch ~/ 1000;

    test('fresh, with zones in tenths of a kelvin and their critical trip', () {
      final report = ReaderReport.parse('anyps5-heat 1\ntime $seconds\nzone 3332 3732\nzone 3182 0\n', now);
      expect(report.fresh, isTrue);
      expect(report.zones, hasLength(2));
      expect(report.zones[0].graphics, isFalse);
      expect(report.zones[0].celsius, closeTo(60.05, 0.001));
      expect(report.zones[0].limit, closeTo(100.05, 0.001));
      expect(report.zones[1].celsius, closeTo(45.05, 0.001));
      expect(report.zones[1].limit, isNull, reason: 'a trip of 0 K is one the firmware left unset');
    });

    test('Windows answering with lines of its own (CRLF) still reads', () {
      final report = ReaderReport.parse('anyps5-heat 1\r\ntime ${seconds - 5}\r\nzone 3532 3782\r\n', now);
      expect(report.fresh, isTrue);
      expect(WindowsHeat.levelOf(report.zones), ThermalLevel.fair);
    });

    test('running but without a zone: fresh, nothing to read', () {
      final report = ReaderReport.parse('anyps5-heat 1\ntime $seconds\n', now);
      expect(report.fresh, isTrue);
      expect(report.zones, isEmpty);
    });

    test('a zone at 0 K or 0 °C is left out', () {
      final report = ReaderReport.parse('anyps5-heat 1\ntime $seconds\nzone 0 0\nzone 2732 0\n', now);
      expect(report.fresh, isTrue);
      expect(report.zones, isEmpty);
    });

    test('old, without a time, or not the reader\'s: nothing', () {
      expect(ReaderReport.parse('anyps5-heat 1\ntime ${seconds - 60}\nzone 3332 3732\n', now).fresh, isFalse);
      expect(ReaderReport.parse('anyps5-heat 1\nzone 3332 3732\n', now).fresh, isFalse);
      expect(ReaderReport.parse('something else\ntime $seconds\n', now).fresh, isFalse);
      expect(ReaderReport.parse('', now).fresh, isFalse);
      expect(ReaderReport.parse('anyps5-heat 1\ntime soon\nzone hot 0\n', now).fresh, isFalse);
    });
  });

  group('the reader with administrator rights', () {
    const stop = r"C:\Users\Seán O'Brien ‘test’\AppData\Roaming\AnyPS5\Power\heat-reader.stop";

    String decode(String encoded) {
      final bytes = base64.decode(encoded);
      return String.fromCharCodes([for (var at = 0; at < bytes.length; at += 2) bytes[at] | bytes[at + 1] << 8]);
    }

    test('PowerShell from System32 by its full path, never from the search path', () {
      expect(
        WindowsHeat.windowsPowerShell({'SystemRoot': r'D:\WINDOWS'}),
        r'D:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe',
      );
      expect(WindowsHeat.windowsPowerShell(const {}), r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe');
    });

    test('the script goes in encoded, whole, and the stop file\'s path never as PowerShell', () {
      final script = WindowsHeat.readerScript(parent: 4242, stopFile: stop);
      final arguments = WindowsHeat.readerArguments(script);
      expect(arguments, startsWith('-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden '));
      final encoded = arguments.split(' ').last;
      expect(decode(encoded), script);
      expect(script, contains('Get-Process -Id 4242'));
      expect(script, isNot(contains("O'Brien")), reason: 'a quote in a folder name must not end a string');
      expect(script, contains(WindowsHeat.encodeCommand(stop)));
      expect(decode(WindowsHeat.encodeCommand(stop)), stop);
    });

    test('it reads the ACPI zones into a volatile key only administrators write, and ends with the launcher', () {
      final script = WindowsHeat.readerScript(parent: 1, stopFile: stop);
      expect(script, contains('Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature'));
      expect(script, contains("'${WindowsHeat.readerKey}'"));
      expect(script, contains('LocalMachine.CreateSubKey'));
      expect(script, contains('[Microsoft.Win32.RegistryOptions]::Volatile'));
      expect(script, contains("SetValue('${WindowsHeat.readerValue}'"));
      expect(script, contains(r'$parent.WaitForExit(5000)'));
      expect(script, contains(r'Test-Path -LiteralPath $stop'));
      expect(script, contains('DeleteSubKey'));
      expect(script, isNot(contains('Remove-Item')), reason: 'it deletes nothing in the user\'s folders');
      expect(script, isNot(contains('Set-Content')), reason: 'it writes nothing in the user\'s folders');
    });

    test('where nothing is there, nothing is read and nothing is asked', () async {
      final heat = WindowsHeat.instance;
      expect(heat.read(graphics: true, now: DateTime.now()), isEmpty);
      expect(heat.level(graphics: true), isNull);
      expect(heat.graphicsFound, isFalse);
      expect(heat.zonesWithoutAdmin, isFalse);
      expect(await heat.startReader(stopFile: stop), isFalse);
      expect(heat.readerState, HeatReaderState.off);
    }, skip: Platform.isWindows ? 'reads the computer it runs on' : false);
  });
}
