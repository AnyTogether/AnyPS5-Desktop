import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/gamepad/linux_input_class.dart';
import 'package:anyps5_desktop/core/gamepad/linux_pads.dart';
import 'package:anyps5_desktop/core/gamepad/pad_navigation.dart';
import 'package:test/test.dart';

/// HP's freefall accelerometer (hp_accel + lis3lv02d) beside a DualSense, as
/// /proc/bus/input/devices lists them (issue #195): both have a js node.
const accelerometer = '''
I: Bus=0019 Vendor=0000 Product=0000 Version=0000
N: Name="ST LIS3LV02DL Accelerometer"
P: Phys=lis3lv02d/input0
S: Sysfs=/devices/platform/lis3lv02d/input/input10
U: Uniq=
H: Handlers=event9 js0
B: PROP=0
B: EV=9
B: ABS=7
''';

const dualSense = '''
I: Bus=0003 Vendor=054c Product=0ce6 Version=8111
N: Name="Sony Interactive Entertainment DualSense Wireless Controller"
P: Phys=usb-0000:00:14.0-2/input3
S: Sysfs=/devices/pci0000:00/0000:00:14.0/usb1/1-2/1-2:1.3/0003:054C:0CE6.0005/input/input21
U: Uniq=a0:ab:51:00:00:01
H: Handlers=event21 js1
B: PROP=0
B: EV=20000b
B: KEY=7fdb000000000000 0 0 0 0
B: ABS=3003f
B: FF=107030000 0
''';

const keyboard = '''
I: Bus=0011 Vendor=0001 Product=0001 Version=ab41
N: Name="AT Translated Set 2 keyboard"
H: Handlers=sysrq kbd event3 leds
B: PROP=0
B: EV=120013
''';

void main() {
  group('LinuxInputClass', () {
    test('bitmaps are the kernel\'s hex words, the last one bits 0 to 63', () {
      expect(LinuxInputClass.bit('7', 0), isTrue);
      expect(LinuxInputClass.bit('7', 2), isTrue);
      expect(LinuxInputClass.bit('7', 3), isFalse);
      // BTN_SOUTH (0x130) in a DualSense's KEY bitmap, four words up.
      expect(LinuxInputClass.bit('7fdb000000000000 0 0 0 0', 0x130), isTrue);
      expect(LinuxInputClass.bit('7fdb000000000000 0 0 0 0', 0x12f), isFalse);
      expect(LinuxInputClass.bit('ffffffffffffffff', 63), isTrue, reason: 'a full word is no overflow');
      expect(LinuxInputClass.bit('', 0), isFalse);
      expect(LinuxInputClass.bit('40', 6), isTrue);
    });

    test('an accelerometer is left out by its name, its PROP bit, udev or its axes alone', () {
      expect(LinuxInputClass.skipReason(name: 'ST LIS3LV02DL Accelerometer', axes: '7'), 'accelerometer');
      expect(LinuxInputClass.skipReason(name: 'Some sensor', properties: '40', keys: '1', axes: '3'), 'accelerometer');
      expect(
        LinuxInputClass.skipReason(name: 'lis3lv02d', keys: '1', udev: 'I:123\nE:ID_INPUT=1\nE:ID_INPUT_ACCELEROMETER=1\nG:seat\n'),
        'accelerometer',
      );
      // No udev entry, no name: no keys and an X, Y and Z axis, as udev's own rule.
      expect(LinuxInputClass.skipReason(name: 'freefall', axes: '7'), 'accelerometer');
    });

    test('udev\'s word decides between a joystick and anything else', () {
      expect(LinuxInputClass.skipReason(name: 'Pad', axes: '7', udev: 'E:ID_INPUT=1\nE:ID_INPUT_JOYSTICK=1\n'), isNull);
      expect(LinuxInputClass.skipReason(name: 'Tablet', udev: 'E:ID_INPUT=1\nE:ID_INPUT_TABLET=1\n'), 'not a joystick for udev');
      // An entry udev has not finished (no ID_INPUT yet) says nothing.
      expect(LinuxInputClass.skipReason(name: 'Pad', keys: '1', axes: '3', udev: 'I:123\n'), isNull);
    });

    test('pads are kept: buttons and sticks, with or without what the kernel lists', () {
      expect(
        LinuxInputClass.skipReason(
          name: 'Sony Interactive Entertainment DualSense Wireless Controller',
          keys: '7fdb000000000000 0 0 0 0',
          axes: '3003f',
        ),
        isNull,
      );
      expect(LinuxInputClass.skipReason(name: 'Microsoft X-Box 360 pad'), isNull);
    });

    test('udev entries are read from the device number sysfs gives', () {
      final root = Directory.systemTemp.createTempSync('udev');
      addTearDown(() => root.deleteSync(recursive: true));
      Directory('${root.path}/sys/event9').createSync(recursive: true);
      File('${root.path}/sys/event9/dev').writeAsStringSync('13:73\n');
      Directory('${root.path}/udev').createSync();
      File('${root.path}/udev/c13:73').writeAsStringSync('E:ID_INPUT=1\nE:ID_INPUT_ACCELEROMETER=1\n');
      final entry = LinuxInputClass.udevEntry('event9', sysClass: '${root.path}/sys', udevData: '${root.path}/udev');
      expect(LinuxInputClass.parseUdev(entry!), {'ID_INPUT': '1', 'ID_INPUT_ACCELEROMETER': '1'});
      expect(LinuxInputClass.udevEntry('event10', sysClass: '${root.path}/sys', udevData: '${root.path}/udev'), isNull);
    });
  });

  group('LinuxPadSource and devices that are no controller', () {
    late Directory root;
    late String devices;
    late String input;

    setUp(() {
      root = Directory.systemTemp.createTempSync('pads');
      devices = '${root.path}/devices';
      input = '${root.path}/input';
      Directory(input).createSync();
      File(devices).writeAsStringSync('$accelerometer\n$dualSense\n$keyboard');
    });
    tearDown(() => root.deleteSync(recursive: true));

    LinuxPadSource source(Future<EvdevProbe> Function(String path) probe, {Duration timeout = const Duration(seconds: 3)}) =>
        LinuxPadSource(
          devicesFile: devices,
          inputFolder: input,
          sysClass: '${root.path}/none',
          udevData: '${root.path}/none',
          probe: probe,
          probeTimeout: timeout,
        );

    test('the accelerometer is never opened; the DualSense is, and read', () async {
      // One press of Cross in the DualSense's node.
      final press = ByteData(24)
        ..setUint16(16, 1, Endian.little)
        ..setUint16(18, 0x130, Endian.little)
        ..setInt32(20, 1, Endian.little);
      File('$input/event21').writeAsBytesSync(press.buffer.asUint8List());
      final probed = <String>[];
      final reader = source((path) async {
        probed.add(path);
        return const EvdevProbe(readable: true, ranges: {0: (0, 255), 1: (0, 255)});
      });
      final events = <PadEvent>[];
      reader.start(events.add);
      addTearDown(reader.stop);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(probed, ['$input/event21']);
      expect(events.whereType<PadButtonEvent>().single.button, PadButton.south);
      expect(reader.skipped, ['ST LIS3LV02DL Accelerometer (accelerometer)']);
      expect(reader.description, contains('ST LIS3LV02DL Accelerometer (accelerometer): left alone'));
    });

    test('an open that does not come back is "not answering" and is not tried again', () async {
      final probed = <String>[];
      final never = Completer<EvdevProbe>();
      final reader = source((path) {
        probed.add(path);
        return never.future;
      }, timeout: const Duration(milliseconds: 50));
      reader.start((_) {});
      addTearDown(reader.stop);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(reader.notAnswering, ['Sony Interactive Entertainment DualSense Wireless Controller']);
      expect(reader.description, contains('(not answering)'));
      reader
        ..scanNow()
        ..scanNow();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(probed, hasLength(1), reason: 'a second open would hang the same way');
      expect(reader.pads, isEmpty);
      // Gone from the list while its open is still out: still not tried when it is back.
      File(devices).writeAsStringSync(accelerometer);
      reader.scanNow();
      File(devices).writeAsStringSync('$accelerometer\n$dualSense');
      reader.scanNow();
      expect(probed, hasLength(1));
    });

    test('a node the user may not read is refused, as before', () async {
      final reader = source((path) async => const EvdevProbe(readable: false));
      reader.start((_) {});
      addTearDown(reader.stop);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(reader.refused, ['Sony Interactive Entertainment DualSense Wireless Controller']);
      expect(reader.notAnswering, isEmpty);
    });

    test('controllers() splits the list without opening anything', () {
      final (pads, skipped) = LinuxPadSource.controllers(devicesFile: devices, sysClass: '${root.path}/none', udevData: '${root.path}/none');
      expect(pads.map((pad) => pad.event), ['event21']);
      expect(skipped, {'event9': 'ST LIS3LV02DL Accelerometer (accelerometer)'});
    });
  });
}
