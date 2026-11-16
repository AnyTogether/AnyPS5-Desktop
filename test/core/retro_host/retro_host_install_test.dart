import 'dart:convert';
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
      final found = RetroHostInstall.locate({'ANYPS5_RETRO_HOST': host}, build: RetroHostBuild.debug, system: system);
      expect((found?.host, found?.core), (host, core.path));
      core.deleteSync();
    }
    expect(RetroHostInstall.coreName(HostSystem.windows), 'swanstation_libretro.dll');
    expect(RetroHostInstall.coreName(HostSystem.linux), 'swanstation_libretro.so');
  });

  test('a test build runs that host too, unchecked', () {
    final core = File(p.join(folder.path, RetroHostInstall.coreName(HostSystem.current)))..createSync();
    final found = RetroHostInstall.locate(
      {'ANYPS5_RETRO_HOST': host},
      build: RetroHostBuild.test,
      system: HostSystem.current,
    );
    expect((found?.host, found?.core, found?.checked), (host, core.path, false));
  });

  test('a release build ignores the variable, as protocol.md says, whatever else the environment holds', () {
    File(p.join(folder.path, RetroHostInstall.coreName(HostSystem.current))).createSync();
    final environment = {'ANYPS5_RETRO_HOST': host, RetroHostBuild.testDefine: 'true'};
    expect(RetroHostInstall.locate(environment, build: RetroHostBuild.release, system: HostSystem.current), isNull);
  });

  group('the build', () {
    test('a debug launcher is a debug build, one compiled with the define a test build, any other a release', () {
      expect(RetroHostBuild.of(debug: true, test: false), RetroHostBuild.debug);
      expect(RetroHostBuild.of(debug: true, test: true), RetroHostBuild.debug);
      expect(RetroHostBuild.of(debug: false, test: true), RetroHostBuild.test);
      expect(RetroHostBuild.of(debug: false, test: false), RetroHostBuild.release);
      expect([for (final build in RetroHostBuild.values) build.runsUnchecked], [false, true, true]);
    });

    test('a launcher compiled without the define is a release when it is not a debug build', () {
      expect(RetroHostBuild.testDefined, isFalse);
      expect(RetroHostBuild.of(debug: false), RetroHostBuild.release);
      expect(
        RetroHostInstall.locate(
          {'ANYPS5_RETRO_HOST': host, RetroHostBuild.testDefine: 'true'},
          build: RetroHostBuild.of(debug: false),
          system: HostSystem.current,
        ),
        isNull,
      );
    });

    test('no workflow or packaging script compiles a test build', () {
      final scripts = [
        for (final folder in ['.github', 'packaging', 'tool'])
          ...Directory(folder).listSync(recursive: true).whereType<File>(),
      ];
      expect(scripts, isNotEmpty);
      final compiling = [
        for (final script in scripts)
          if (utf8.decode(script.readAsBytesSync(), allowMalformed: true).contains(RetroHostBuild.testDefine))
            script.path,
      ];
      expect(compiling, isEmpty);
    });
  });

  test('no host without the variable, with a relative or missing host, or without the core beside it', () {
    final system = HostSystem.current;
    expect(RetroHostInstall.locate({'ANYPS5_RETRO_HOST': host}, build: RetroHostBuild.debug, system: system), isNull);
    File(p.join(folder.path, RetroHostInstall.coreName(system))).createSync();
    expect(RetroHostInstall.locate(const {}, build: RetroHostBuild.debug, system: system), isNull);
    expect(
      RetroHostInstall.locate(const {'ANYPS5_RETRO_HOST': ''}, build: RetroHostBuild.debug, system: system),
      isNull,
    );
    expect(
      RetroHostInstall.locate(
        const {'ANYPS5_RETRO_HOST': 'anyps5-retro-host'},
        build: RetroHostBuild.debug,
        system: system,
      ),
      isNull,
    );
    expect(
      RetroHostInstall.locate(
        {'ANYPS5_RETRO_HOST': p.join(folder.path, 'gone')},
        build: RetroHostBuild.debug,
        system: system,
      ),
      isNull,
    );
  });

  test('the host path is given without . or .. segments (protocol.md "Paths")', () {
    final core = File(p.join(folder.path, RetroHostInstall.coreName(HostSystem.current)))..createSync();
    final named = p.join(folder.path, 'sub', '..', 'anyps5-retro-host');
    Directory(p.join(folder.path, 'sub')).createSync();
    final found = RetroHostInstall.locate(
      {'ANYPS5_RETRO_HOST': named},
      build: RetroHostBuild.debug,
      system: HostSystem.current,
    );
    expect((found?.host, found?.core), (host, core.path));
  });
}
