import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _AccessNative = Int32 Function(Pointer<Utf8> path, Int32 mode);
typedef _Access = int Function(Pointer<Utf8> path, int mode);

/// Which Linux input devices with a joystick handler are controllers, decided without opening
/// them. Opening an evdev or js node starts the driver: an accelerometer such as HP's
/// lis3lv02d (hp_accel) reads its axes over ACPI right then, and that read can hang in the
/// kernel for good (issue #195). Such a node is never opened; what tells it apart is read from
/// /proc/bus/input/devices (the name, the PROP, KEY and ABS bitmaps) and from udev's database
/// in /run/udev/data, which the kernel and udev wrote without asking the device.
abstract final class LinuxInputClass {
  /// INPUT_PROP_ACCELEROMETER: the kernel's own word that the device measures motion.
  static const _accelerometerProperty = 0x06;

  /// Why [name] is not a controller, null when it is one (or nothing says it is not).
  /// [properties], [keys] and [axes] are the B: PROP=, KEY= and ABS= bitmaps of its block in
  /// /proc/bus/input/devices; [udev] is its udev database entry (the E: lines), null when
  /// there is none.
  static String? skipReason({
    required String name,
    String properties = '',
    String keys = '',
    String axes = '',
    String? udev,
  }) {
    if (bit(properties, _accelerometerProperty)) return 'accelerometer';
    final udevProperties = udev == null ? null : parseUdev(udev);
    if (udevProperties?['ID_INPUT_ACCELEROMETER'] == '1') return 'accelerometer';
    if (RegExp('accelerometer|motion sensors?', caseSensitive: false).hasMatch(name)) return 'accelerometer';
    if (udevProperties != null && udevProperties['ID_INPUT'] == '1') {
      // udev looked at it: a joystick or gamepad has ID_INPUT_JOYSTICK, anything else is not one.
      return udevProperties['ID_INPUT_JOYSTICK'] == '1' ? null : 'not a joystick for udev';
    }
    // No udev word: udev's own rule, no keys at all and an X, Y and Z axis, is an accelerometer.
    final noKeys = !RegExp('[1-9a-fA-F]').hasMatch(keys);
    if (noKeys && bit(axes, 0) && bit(axes, 1) && bit(axes, 2)) return 'accelerometer';
    return null;
  }

  /// Whether [bitmap] (the kernel's hex words, most significant first, each a 64-bit long) has
  /// bit [index] set.
  static bool bit(String bitmap, int index, {int wordBits = 64}) {
    final words = bitmap.trim().split(RegExp(r'\s+')).where((word) => word.isNotEmpty).toList();
    final at = words.length - 1 - index ~/ wordBits;
    if (at < 0) return false;
    final word = BigInt.tryParse(words[at], radix: 16);
    if (word == null) return false;
    return (word >> (index % wordBits)) & BigInt.one == BigInt.one;
  }

  /// The E: lines of a udev database entry, as a map.
  static Map<String, String> parseUdev(String text) => {
    for (final line in text.split('\n'))
      if (line.startsWith('E:') && line.contains('='))
        line.substring(2, line.indexOf('=')): line.substring(line.indexOf('=') + 1).trim(),
  };

  /// udev's database entry for [event] (event9): /sys/class/input/event9/dev gives its device
  /// number (13:73), /run/udev/data/c13:73 its properties. Both are plain files the kernel and
  /// udev keep; neither read reaches the device. Null when either is missing.
  static String? udevEntry(String event, {String sysClass = '/sys/class/input', String udevData = '/run/udev/data'}) {
    try {
      final number = File('$sysClass/$event/dev').readAsStringSync().trim();
      if (!RegExp(r'^\d+:\d+$').hasMatch(number)) return null;
      return File('$udevData/c$number').readAsStringSync();
    } on FileSystemException {
      return null;
    }
  }

  /// Whether the user may read [path], asked with access(2): a permission check on the path
  /// only, the device itself is not opened (so its driver is not started).
  static bool readable(String path) {
    try {
      final access = DynamicLibrary.process().lookupFunction<_AccessNative, _Access>('access');
      return using((arena) => access(path.toNativeUtf8(allocator: arena), 4 /* R_OK */) == 0);
    } on Object {
      return false;
    }
  }
}
