import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/managed_retro.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('a configured PS3 package must exist and match the supported build', () async {
    final temp = Directory.systemTemp.createTempSync('anyps5-managed-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final packages = Directory(p.join(temp.path, 'packages'))..createSync();
    final managed = ManagedRetro(p.join(temp.path, 'emulators'), packageDirectory: packages.path);

    expect(managed.isInstalled(RetroPlatform.ps3), isFalse);
    await expectLater(
      ManagedRetro(managed.root).install(RetroPlatform.ps3),
      throwsA(isA<FormatException>().having((error) => error.message, 'message', contains('verified RPCS3 package'))),
    );
    await expectLater(managed.install(RetroPlatform.ps3), throwsFormatException);
    File(p.join(packages.path, 'rpcs3_libretro.dll.zip')).writeAsBytesSync([0, 1, 2]);
    await expectLater(managed.install(RetroPlatform.ps3), throwsFormatException);
    expect(managed.isInstalled(RetroPlatform.ps3), isFalse);
  });

  test('an existing PS3 DLL still needs a matching digest', () async {
    final root = Directory.systemTemp.createTempSync('anyps5-managed-');
    addTearDown(() => root.deleteSync(recursive: true));
    final managed = ManagedRetro(root.path);
    final dll = ByteData(88)
      ..setUint16(0, 0x5a4d, Endian.little)
      ..setUint32(60, 64, Endian.little)
      ..setUint32(64, 0x4550, Endian.little)
      ..setUint16(68, 0x8664, Endian.little)
      ..setUint16(86, 0x2000, Endian.little);
    File(p.join(root.path, ManagedRetro.libraryName(RetroPlatform.ps3))).writeAsBytesSync(dll.buffer.asUint8List());

    expect(managed.isInstalled(RetroPlatform.ps3), isTrue);
    await expectLater(managed.install(RetroPlatform.ps3), throwsFormatException);
  });

  test('a rejected BIOS replacement preserves the private copy', () async {
    final temp = Directory.systemTemp.createTempSync('anyps5-managed-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final managed = ManagedRetro(p.join(temp.path, 'emulators'));
    final source = File(p.join(temp.path, 'source.rom'));
    final bytes = Uint8List(512 * 1024)..[0] = 1;
    await source.writeAsBytes(bytes);

    expect(managed.hasBios(RetroPlatform.ps1), isFalse);
    await managed.importBios(RetroPlatform.ps1, source.path);
    final imported = File(p.join(managed.systemPath, 'anyps5-imported.bin'));
    expect(managed.hasBios(RetroPlatform.ps1), isTrue);
    expect(managed.hasBios(RetroPlatform.ps2), isFalse);

    bytes[0] = 2;
    await source.writeAsBytes(bytes);
    await managed.importBios(RetroPlatform.ps1, source.path);
    await source.writeAsBytes([0]);
    await expectLater(managed.importBios(RetroPlatform.ps1, source.path), throwsFormatException);
    await source.delete();
    expect(await imported.readAsBytes(), bytes);
  });
}
