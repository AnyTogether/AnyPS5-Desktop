import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/launch_resolution.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _toml = '''
format = 1

[[patch]]
name = "width"
target = "eboot.bin"
va = 0x1234
type = "u32"
expected = 1920
value = 1920

[[patch]]
name = "height"
target = "eboot.bin"
va = 0x1240
type = "u32"
expected = 1080
value = 1080
''';

const _known = ['1280x720', '1600x900', '1920x1080'];

/// A Linux output: code placed at 0x400000, one load segment from file offset 0x1000.
Uint8List _elf({required int width, required int height}) {
  final bytes = ByteData(0x3000);
  bytes
    ..setUint8(0, 0x7f)
    ..setUint8(1, 0x45)
    ..setUint8(2, 0x4c)
    ..setUint8(3, 0x46)
    ..setUint16(0x10, 2, Endian.little)
    ..setUint64(0x20, 0x40, Endian.little)
    ..setUint16(0x36, 56, Endian.little)
    ..setUint16(0x38, 1, Endian.little)
    ..setUint32(0x40, 1, Endian.little)
    ..setUint64(0x48, 0x1000, Endian.little)
    ..setUint64(0x50, 0x400000, Endian.little)
    ..setUint64(0x60, 0x2000, Endian.little)
    ..setUint32(0x2234, width, Endian.little)
    ..setUint32(0x2240, height, Endian.little);
  return bytes.buffer.asUint8List();
}

/// A Windows output: RVA 0x10000 is guest address 0, one section from file offset 0x400.
Uint8List _pe({required int width, required int height}) {
  const coff = 0x84;
  const optional = 0xf0;
  const table = coff + 20 + optional;
  final bytes = ByteData(0x3000);
  bytes
    ..setUint8(0, 0x4d)
    ..setUint8(1, 0x5a)
    ..setUint32(0x3c, 0x80, Endian.little)
    ..setUint16(coff + 2, 1, Endian.little)
    ..setUint16(coff + 16, optional, Endian.little)
    ..setUint32(table + 12, 0x10000, Endian.little)
    ..setUint32(table + 16, 0x2000, Endian.little)
    ..setUint32(table + 20, 0x400, Endian.little)
    ..setUint32(0x400 + 0x1234, width, Endian.little)
    ..setUint32(0x400 + 0x1240, height, Endian.little);
  return bytes.buffer.asUint8List();
}

(int, int) _elfValues(String path) {
  final bytes = ByteData.sublistView(File(path).readAsBytesSync());
  return (bytes.getUint32(0x2234, Endian.little), bytes.getUint32(0x2240, Endian.little));
}

(int, int) _peValues(String path) {
  final bytes = ByteData.sublistView(File(path).readAsBytesSync());
  return (bytes.getUint32(0x400 + 0x1234, Endian.little), bytes.getUint32(0x400 + 0x1240, Endian.little));
}

void main() {
  late Directory folder;
  late String executable;

  setUp(() {
    folder = Directory.systemTemp.createTempSync('launch-resolution');
    executable = p.join(folder.path, 'app');
  });

  tearDown(() => folder.deleteSync(recursive: true));

  Future<LaunchResolutionResult> apply(String wanted) =>
      LaunchResolution.apply(executable: executable, patch: _toml, wanted: wanted, known: _known);

  test('Linux: the values at the guest address plus 0x400000 change', () async {
    File(executable).writeAsBytesSync(_elf(width: 1920, height: 1080));
    expect(await apply('1600x900'), LaunchResolutionResult.written);
    expect(_elfValues(executable), (1600, 900));
    expect(File('$executable.resolution').existsSync(), isFalse);
    expect(await apply('1600x900'), LaunchResolutionResult.unchanged);
    expect(await apply('1920x1080'), LaunchResolutionResult.written);
    expect(_elfValues(executable), (1920, 1080));
  });

  test('Windows: the values in the section holding RVA 0x10000 plus the guest address change', () async {
    File(executable).writeAsBytesSync(_pe(width: 1920, height: 1080));
    expect(await apply('1280x720'), LaunchResolutionResult.written);
    expect(_peValues(executable), (1280, 720));
  });

  test('nothing is written where the values are not a resolution the game could have', () async {
    final bytes = _elf(width: 1234, height: 5678);
    File(executable).writeAsBytesSync(bytes);
    expect(await apply('1600x900'), LaunchResolutionResult.refused);
    expect(File(executable).readAsBytesSync(), bytes);
    File(executable).writeAsStringSync('#!/bin/sh\necho not an image\n');
    expect(await apply('1600x900'), LaunchResolutionResult.refused);
  });

  test('a kept relink hard linked to the executable stays as it was', () async {
    File(executable).writeAsBytesSync(_elf(width: 1920, height: 1080));
    final kept = p.join(folder.path, 'kept');
    Process.runSync('ln', [executable, kept]);
    await apply('1280x720');
    expect(_elfValues(executable), (1280, 720));
    expect(_elfValues(kept), (1920, 1080));
  }, skip: Platform.isWindows ? 'ln' : false);
}
