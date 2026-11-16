import 'dart:io';

import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_install.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory folder;
  late String host;
  setUp(() {
    folder = Directory.systemTemp.createTempSync('retro-host-install-');
    host = (File(p.join(folder.path, 'anyps5-retro-host'))..createSync()).path;
  });
  tearDown(() => folder.deleteSync(recursive: true));

  test('a debug build runs the host ANYPS5_RETRO_HOST names, with the SwanStation library beside it', () {
    for (final system in HostSystem.values) {
      final core = File(p.join(folder.path, RetroHostInstall.coreName(system)))..createSync();
      final found = RetroHostInstall.locate({'ANYPS5_RETRO_HOST': host}, debug: true, system: system);
      expect((found?.host, found?.core), (host, core.path));
      core.deleteSync();
    }
    expect(RetroHostInstall.coreName(HostSystem.windows), 'swanstation_libretro.dll');
    expect(RetroHostInstall.coreName(HostSystem.linux), 'swanstation_libretro.so');
  });

  test('a release build ignores the variable, as protocol.md says', () {
    File(p.join(folder.path, RetroHostInstall.coreName(HostSystem.current))).createSync();
    expect(RetroHostInstall.locate({'ANYPS5_RETRO_HOST': host}, debug: false, system: HostSystem.current), isNull);
  });

  test('no host without the variable, with a relative or missing host, or without the core beside it', () {
    final system = HostSystem.current;
    expect(RetroHostInstall.locate({'ANYPS5_RETRO_HOST': host}, debug: true, system: system), isNull);
    File(p.join(folder.path, RetroHostInstall.coreName(system))).createSync();
    expect(RetroHostInstall.locate(const {}, debug: true, system: system), isNull);
    expect(RetroHostInstall.locate(const {'ANYPS5_RETRO_HOST': ''}, debug: true, system: system), isNull);
    expect(
      RetroHostInstall.locate(const {'ANYPS5_RETRO_HOST': 'anyps5-retro-host'}, debug: true, system: system),
      isNull,
    );
    expect(
      RetroHostInstall.locate({'ANYPS5_RETRO_HOST': p.join(folder.path, 'gone')}, debug: true, system: system),
      isNull,
    );
  });

  test('the host path is given without . or .. segments (protocol.md "Paths")', () {
    final core = File(p.join(folder.path, RetroHostInstall.coreName(HostSystem.current)))..createSync();
    final named = p.join(folder.path, 'sub', '..', 'anyps5-retro-host');
    Directory(p.join(folder.path, 'sub')).createSync();
    final found = RetroHostInstall.locate({'ANYPS5_RETRO_HOST': named}, debug: true, system: HostSystem.current);
    expect((found?.host, found?.core), (host, core.path));
  });
}
