import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/power_profiles.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fixtures.dart';

/// The macOS launcher's PowerProfilesTests, case for case, and the Windows and Linux readings.
void main() {
  final start = DateTime.utc(2026, 11, 1, 12);
  DateTime at(num seconds) => start.add(Duration(milliseconds: (seconds * 1000).round()));
  final settle = PowerPolicy.sourceSettle.inSeconds;
  final coolDown = PowerPolicy.coolDown.inSeconds;

  PowerReading state({bool battery = false, ThermalLevel thermal = ThermalLevel.nominal, bool lowPower = false}) =>
      PowerReading(hasBattery: true, onBattery: battery, batteryPercent: 80, thermal: thermal, lowPowerMode: lowPower);

  group('the policy', () {
    test('plugged in changes nothing', () {
      final policy = PowerPolicy();
      expect(policy.update(state(), at(0)), PowerAdjustment.none);
      expect(policy.mode, PowerMode.pluggedIn);
      expect(policy.update(state(thermal: ThermalLevel.fair), at(5)), PowerAdjustment.none);
    });

    test('on battery at start the battery profile holds at once', () {
      final policy = PowerPolicy();
      final adjustment = policy.update(state(battery: true), at(0));
      expect(policy.mode, PowerMode.battery);
      expect(adjustment.frameCap, 40);
      expect(adjustment.pauseFrameGeneration, isTrue);
      expect(adjustment.dimEffects, isTrue);
      expect(adjustment.lowerResolution, isFalse);
    });

    test('unplugging settles before the profile changes', () {
      final policy = PowerPolicy()..update(state(), at(0));
      expect(policy.update(state(battery: true), at(1)), PowerAdjustment.none);
      expect(policy.update(state(battery: true), at(1 + settle - 1)), PowerAdjustment.none);
      expect(policy.update(state(battery: true), at(1 + settle)).frameCap, 40);
      expect(policy.mode, PowerMode.battery);
    });

    test('a slipping cable does not flap', () {
      final policy = PowerPolicy()..update(state(), at(0));
      for (var second = 1; second < 60; second += 2) {
        policy.update(state(battery: true), at(second));
        expect(policy.update(state(), at(second + 1)), PowerAdjustment.none);
      }
      expect(policy.mode, PowerMode.pluggedIn);
    });

    test('plugging back in restores after settling', () {
      final policy = PowerPolicy()..update(state(battery: true), at(0));
      expect(policy.update(state(), at(1)).frameCap, 40);
      expect(policy.update(state(), at(1 + settle)), PowerAdjustment.none);
      expect(policy.mode, PowerMode.pluggedIn);
    });

    test('battery saver counts as saving power', () {
      final policy = PowerPolicy();
      expect(policy.update(state(lowPower: true), at(0)).frameCap, 40);
      expect(policy.mode, PowerMode.battery);
    });

    test('hot takes hold at once', () {
      final policy = PowerPolicy()..update(state(), at(0));
      final adjustment = policy.update(state(thermal: ThermalLevel.serious), at(1));
      expect(policy.mode, PowerMode.hot);
      expect(adjustment.frameCap, 40);
      expect(adjustment.pauseFrameGeneration, isTrue);
      expect(policy.update(state(thermal: ThermalLevel.critical), at(2)).pauseFrameGeneration, isTrue);
    });

    test('cooling down waits so the cap does not flap', () {
      final policy = PowerPolicy()..update(state(thermal: ThermalLevel.serious), at(0));
      for (var second = 1; second < 300; second += 20) {
        expect(policy.update(state(thermal: ThermalLevel.fair), at(second)).frameCap, 40);
        expect(policy.update(state(thermal: ThermalLevel.serious), at(second + 10)).frameCap, 40);
      }
      expect(policy.mode, PowerMode.hot);
      policy.update(state(thermal: ThermalLevel.fair), at(400));
      expect(policy.update(state(thermal: ThermalLevel.fair), at(400 + coolDown - 1)).frameCap, 40);
      expect(policy.update(state(), at(400 + coolDown)), PowerAdjustment.none);
      expect(policy.mode, PowerMode.pluggedIn);
    });

    test('hot on battery takes the stricter of both', () {
      final policy = PowerPolicy(
        profiles: const PowerProfiles(
          battery: PowerProfile(
            on: true,
            frameCap: 45,
            lowerResolution: false,
            pauseFrameGeneration: false,
            dimEffects: true,
          ),
          hot: PowerProfile(
            on: true,
            frameCap: 30,
            lowerResolution: true,
            pauseFrameGeneration: true,
            dimEffects: false,
          ),
        ),
      );
      final adjustment = policy.update(state(battery: true, thermal: ThermalLevel.serious), at(0));
      expect(policy.mode, PowerMode.hot);
      expect(
        adjustment,
        const PowerAdjustment(frameCap: 30, lowerResolution: true, pauseFrameGeneration: true, dimEffects: true),
      );
    });

    test('an uncapped profile leaves the other cap', () {
      final policy = PowerPolicy(
        profiles: PowerProfiles(
          battery: PowerProfile.battery.copyWith(frameCap: 0),
          hot: PowerProfile.hot.copyWith(frameCap: 45),
        ),
      );
      expect(policy.update(state(battery: true, thermal: ThermalLevel.critical), at(0)).frameCap, 45);
    });

    test('a profile turned off changes nothing', () {
      final policy = PowerPolicy(profiles: PowerProfiles(battery: PowerProfile.battery.copyWith(on: false)));
      expect(policy.update(state(battery: true), at(0)), PowerAdjustment.none);
      expect(policy.mode, PowerMode.battery);
    });

    test('changing the profiles applies at once', () {
      final policy = PowerPolicy()..update(state(battery: true), at(0));
      policy.profiles = PowerProfiles(battery: PowerProfile.battery.copyWith(frameCap: 30));
      expect(policy.adjustment.frameCap, 30);
    });

    test('heat that cannot be read is never hot', () {
      final policy = PowerPolicy()..update(const PowerReading(hasBattery: true, onBattery: false), at(0));
      expect(policy.mode, PowerMode.pluggedIn);
      expect(policy.adjustment, PowerAdjustment.none);
    });
  });

  group('undo', () {
    test('undo lifts the heat adjustment for this episode', () {
      final policy = PowerPolicy()..update(state(thermal: ThermalLevel.serious), at(0));
      expect(policy.canUndo, isTrue);
      expect(policy.undo(), PowerAdjustment.none);
      expect(policy.canUndo, isFalse);
      expect(policy.update(state(thermal: ThermalLevel.serious), at(30)), PowerAdjustment.none);
      expect(policy.update(state(thermal: ThermalLevel.fair), at(40)), PowerAdjustment.none);
      expect(policy.update(state(thermal: ThermalLevel.serious), at(50)), PowerAdjustment.none);
    });

    test('undo gives way when it gets hotter', () {
      final policy = PowerPolicy()..update(state(thermal: ThermalLevel.serious), at(0));
      policy.undo();
      expect(policy.update(state(thermal: ThermalLevel.critical), at(10)).frameCap, 40);
    });

    test('a new episode after cooling applies again', () {
      final policy = PowerPolicy()..update(state(thermal: ThermalLevel.serious), at(0));
      policy
        ..undo()
        ..update(state(), at(10))
        ..update(state(), at(10 + coolDown));
      expect(policy.mode, PowerMode.pluggedIn);
      expect(policy.update(state(thermal: ThermalLevel.serious), at(200)).frameCap, 40);
      expect(policy.canUndo, isTrue);
    });

    test('undo while hot on battery keeps the battery profile', () {
      final policy = PowerPolicy(
        profiles: PowerProfiles(
          battery: PowerProfile.battery.copyWith(frameCap: 45),
          hot: PowerProfile.hot.copyWith(frameCap: 30),
        ),
      )..update(state(battery: true, thermal: ThermalLevel.serious), at(0));
      expect(policy.undo().frameCap, 45);
      expect(policy.mode, PowerMode.battery);
      expect(policy.canUndo, isTrue);
      expect(policy.undo(), PowerAdjustment.none);
    });

    test('battery undo lasts until the power source changes', () {
      final policy = PowerPolicy()..update(state(battery: true), at(0));
      policy.undo();
      expect(policy.update(state(battery: true), at(100)), PowerAdjustment.none);
      policy
        ..update(state(), at(101))
        ..update(state(), at(101 + settle))
        ..update(state(battery: true), at(200));
      expect(policy.update(state(battery: true), at(200 + settle)).frameCap, 40);
    });

    test('nothing to undo plugged in', () {
      final policy = PowerPolicy()..update(state(), at(0));
      expect(policy.canUndo, isFalse);
      expect(policy.undo(), PowerAdjustment.none);
    });

    test('entering heat is reported once', () {
      final policy = PowerPolicy()..update(state(), at(0));
      expect(policy.becameHot, isFalse);
      policy.update(state(thermal: ThermalLevel.serious), at(1));
      expect(policy.becameHot, isTrue);
      policy.update(state(thermal: ThermalLevel.critical), at(2));
      expect(policy.becameHot, isFalse);
    });
  });

  group('profiles saved', () {
    test('profiles decode with missing fields, as the Mac\'s', () {
      final decoded = PowerProfiles.fromJson(jsonDecode('{"battery":{"frameCap":30}}'));
      expect(decoded.battery.frameCap, 30);
      expect(decoded.battery.on, isTrue);
      expect(decoded.battery.pauseFrameGeneration, isTrue);
      expect(decoded.hot, PowerProfile.hot);
      expect(PowerProfiles.fromJson(decoded.toJson()), decoded);
      expect(PowerProfiles.fromJson('garbage'), const PowerProfiles());
    });

    test('the keys are the Mac\'s', () {
      expect(const PowerProfiles().toJson(), {
        'battery': {
          'on': true,
          'frameCap': 40,
          'lowerResolution': false,
          'pauseFrameGeneration': true,
          'dimEffects': true,
        },
        'hot': {'on': true, 'frameCap': 40, 'lowerResolution': false, 'pauseFrameGeneration': true, 'dimEffects': true},
      });
    });

    test('frame caps offered', () => expect(PowerProfile.frameCaps, [0, 30, 40, 45]));
  });

  group('the engine\'s side', () {
    test('control file text', () {
      expect(
        EngineControl.text(
          const PowerAdjustment(frameCap: 40, lowerResolution: true, pauseFrameGeneration: true, dimEffects: true),
        ),
        'fps_cap=40\nframe_gen=0\n',
      );
      expect(EngineControl.text(PowerAdjustment.none), 'fps_cap=0\nframe_gen=1\n');
    });

    test('launch environment', () {
      expect(
        EngineControl.environment(
          '/tmp/power.txt',
          const PowerAdjustment(frameCap: 30, lowerResolution: false, pauseFrameGeneration: false, dimEffects: false),
        ),
        {'ANYPS5_POWER_CONTROL': '/tmp/power.txt', 'ANYPS5_FPS_CAP': '30'},
      );
      expect(EngineControl.environment('/tmp/power.txt', PowerAdjustment.none)['ANYPS5_FPS_CAP'], '0');
    });

    test('the control file is written whole', () {
      final temp = temporaryFolder('power');
      addTearDown(() => temp.deleteSync(recursive: true));
      final file = p.join(temp.path, 'Power', 'control.txt');
      EngineControl.write(
        const PowerAdjustment(frameCap: 45, lowerResolution: false, pauseFrameGeneration: false, dimEffects: false),
        file,
      );
      expect(File(file).readAsStringSync(), 'fps_cap=45\nframe_gen=1\n');
      expect(File('$file.tmp').existsSync(), isFalse);
    });
  });

  group('battery time', () {
    test('the system\'s estimate comes first', () {
      final estimate = BatteryEstimate()..add(percent: 80, onBattery: true, at: at(0));
      expect(estimate.minutesLeft(system: 125), 125);
    });

    test('without the system\'s estimate the drain is measured', () {
      final estimate = BatteryEstimate()..add(percent: 80, onBattery: true, at: at(0));
      expect(estimate.minutesLeft(), isNull);
      estimate.add(percent: 78, onBattery: true, at: at(60));
      expect(estimate.minutesLeft(), isNull);
      estimate.add(percent: 76, onBattery: true, at: at(600));
      expect(estimate.minutesLeft(), 190);
    });

    test('charging starts the measure again', () {
      final estimate = BatteryEstimate()
        ..add(percent: 80, onBattery: true, at: at(0))
        ..add(percent: 70, onBattery: true, at: at(600))
        ..add(percent: 71, onBattery: false, at: at(700));
      expect(estimate.minutesLeft(), isNull);
      estimate.add(percent: 71, onBattery: true, at: at(800));
      expect(estimate.minutesLeft(), isNull);
    });
  });

  group('readings on Windows', () {
    test('a laptop on battery, with Windows\' estimate and battery saver', () {
      final reading = PowerReader.fromWindowsStatus(
        acLine: 0,
        batteryFlag: 1,
        percent: 64,
        systemStatus: 1,
        lifeSeconds: 7500,
      );
      expect(reading.hasBattery, isTrue);
      expect(reading.onBattery, isTrue);
      expect(reading.batteryPercent, 64);
      expect(reading.minutesToEmpty, 125);
      expect(reading.lowPowerMode, isTrue);
      expect(reading.readsHeat, isFalse, reason: 'the heat is WindowsHeat\'s, given apart (windows_heat_test.dart)');
    });

    test('a desktop has no battery; an unknown estimate is none', () {
      final desktop = PowerReader.fromWindowsStatus(acLine: 1, batteryFlag: 128, percent: 255);
      expect(desktop.hasBattery, isFalse);
      expect(desktop.onBattery, isFalse);
      expect(desktop.batteryPercent, isNull);
      final charging = PowerReader.fromWindowsStatus(acLine: 1, batteryFlag: 8, percent: 90);
      expect(charging.onBattery, isFalse);
      expect(charging.minutesToEmpty, isNull);
    });
  });

  group('readings on Linux', () {
    late Directory root;
    setUp(() => root = temporaryFolder('sysfs'));
    tearDown(() => root.deleteSync(recursive: true));

    void write(String path, String text) {
      final file = File(p.join(root.path, path));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('$text\n');
    }

    PowerReading read() => PowerReader.fromSysfs(
      powerSupply: p.join(root.path, 'power_supply'),
      thermal: p.join(root.path, 'thermal'),
      hwmon: p.join(root.path, 'hwmon'),
      platformProfile: p.join(root.path, 'platform_profile'),
    );

    test('a laptop on battery: its level, the time from energy over power, a mouse left out', () {
      write('power_supply/AC/type', 'Mains');
      write('power_supply/AC/online', '0');
      write('power_supply/BAT0/type', 'Battery');
      write('power_supply/BAT0/status', 'Discharging');
      write('power_supply/BAT0/capacity', '58');
      write('power_supply/BAT0/energy_now', '30000000');
      write('power_supply/BAT0/power_now', '15000000');
      write('power_supply/hidpp_battery_0/type', 'Battery');
      write('power_supply/hidpp_battery_0/scope', 'Device');
      write('power_supply/hidpp_battery_0/capacity', '100');
      write('power_supply/hidpp_battery_0/status', 'Discharging');
      write('platform_profile', 'low-power');
      final reading = read();
      expect(reading.hasBattery, isTrue);
      expect(reading.onBattery, isTrue);
      expect(reading.batteryPercent, 58);
      expect(reading.minutesToEmpty, 120);
      expect(reading.lowPowerMode, isTrue);
      expect(reading.thermal, isNull, reason: 'no sensor here');
    });

    test('plugged in, charging: not on battery', () {
      write('power_supply/ADP1/type', 'Mains');
      write('power_supply/ADP1/online', '1');
      write('power_supply/BAT1/type', 'Battery');
      write('power_supply/BAT1/status', 'Charging');
      write('power_supply/BAT1/capacity', '91');
      final reading = read();
      expect(reading.onBattery, isFalse);
      expect(reading.batteryPercent, 91);
      expect(reading.minutesToEmpty, isNull);
      expect(reading.lowPowerMode, isFalse);
    });

    test('the processor\'s zones give the heat, against their critical trip', () {
      write('thermal/thermal_zone0/type', 'iwlwifi_1');
      write('thermal/thermal_zone0/temp', '99000');
      write('thermal/thermal_zone1/type', 'x86_pkg_temp');
      write('thermal/thermal_zone1/temp', '62000');
      expect(read().thermal, ThermalLevel.nominal, reason: 'the Wi-Fi card is not the processor');
      write('thermal/thermal_zone1/temp', '78000');
      expect(read().thermal, ThermalLevel.fair);
      write('thermal/thermal_zone1/temp', '86000');
      expect(read().thermal, ThermalLevel.serious);
      write('thermal/thermal_zone1/temp', '96000');
      expect(read().thermal, ThermalLevel.critical);
      // A zone whose critical trip is 90 °C: hot from 75, critical from 85.
      write('thermal/thermal_zone1/temp', '80000');
      write('thermal/thermal_zone1/trip_point_0_type', 'passive');
      write('thermal/thermal_zone1/trip_point_0_temp', '70000');
      write('thermal/thermal_zone1/trip_point_1_type', 'critical');
      write('thermal/thermal_zone1/trip_point_1_temp', '90000');
      expect(read().thermal, ThermalLevel.serious);
      write('thermal/thermal_zone1/temp', '86000');
      expect(read().thermal, ThermalLevel.critical);
    });

    test('without zones, the processor\'s hwmon sensor', () {
      write('hwmon/hwmon0/name', 'nvme');
      write('hwmon/hwmon0/temp1_input', '99000');
      expect(read().thermal, isNull, reason: 'a drive is not the processor');
      write('hwmon/hwmon3/name', 'k10temp');
      write('hwmon/hwmon3/temp1_input', '88500');
      expect(read().thermal, ThermalLevel.serious);
    });
  });
}
