import 'dart:io';

import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_client.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_install.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/ui_support.dart';

/// The launcher's own way of starting the host (AppModel.openRetroHost), with a host that writes
/// the environment it got and exits.
void main() {
  test('on Linux the host gets the launcher\'s environment without what the AppImage set', () async {
    final work = Directory.systemTemp.createTempSync('retro-host-launch-env-');
    final host = p.join(work.path, 'anyps5-retro-host');
    File(host).writeAsStringSync('#!/bin/sh\nenv > "\$(dirname "\$0")/env.txt"\n');
    expect(Process.runSync('chmod', ['+x', host]).exitCode, 0);
    File(p.join(work.path, RetroHostInstall.coreName(HostSystem.linux))).createSync();
    final launcher = {
      RetroHostInstall.variable: host,
      'APPIMAGE': '/home/u/AnyPS5.AppImage',
      'APPDIR': '/tmp/.mount_AnyPS5x',
      'ARGV0': 'AnyPS5.AppImage',
      'OWD': '/home/u',
      'XDG_DATA_DIRS': '/tmp/.mount_AnyPS5x/usr/share:/usr/local/share:/usr/share',
      'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
      'ANYPS5_LAUNCH_ENV_TEST': 'kept',
    };
    final fixture = makeFixture(withToolkit: false, environment: launcher);
    try {
      final install = RetroHostInstall.locate(launcher, debug: true, system: HostSystem.linux)!;
      final session = fixture.model.openRetroHost(install, volume: 1, muted: false);
      session.ready.ignore();
      expect(await session.ended.timeout(const Duration(seconds: 20)), RetroHostEnd.hostFailure);
      await session.close();
      final written = {
        for (final line in File(p.join(work.path, 'env.txt')).readAsLinesSync())
          if (line.contains('=')) line.substring(0, line.indexOf('=')): line.substring(line.indexOf('=') + 1),
      };
      expect(written['ANYPS5_LAUNCH_ENV_TEST'], 'kept');
      expect(written['XDG_DATA_DIRS'], '/usr/local/share:/usr/share');
      for (final name in ['APPIMAGE', 'APPDIR', 'ARGV0', 'OWD']) {
        expect(written, isNot(contains(name)), reason: name);
      }
      const shell = {'PWD', 'OLDPWD', 'SHLVL', '_'};
      expect(
        written.keys.where((name) => !launcher.containsKey(name) && !shell.contains(name)),
        isEmpty,
        reason: 'only the launcher\'s environment, not the test process\'s',
      );
    } finally {
      fixture.dispose();
      work.deleteSync(recursive: true);
    }
  }, skip: Platform.isLinux ? null : 'starts a shell script');

  test('on Windows the host gets the launcher\'s environment as it is', () {
    expect(RetroHostInstall.environmentFor(HostSystem.windows, const {'APPIMAGE': '/a', 'PATH': '/p'}), isNull);
    expect(RetroHostInstall.environmentFor(HostSystem.linux, const {'APPIMAGE': '/a', 'PATH': '/p'}), {'PATH': '/p'});
  });

  test('a whole environment cannot be empty, since the host would then get the launcher\'s', () {
    for (final environment in [null, const <String, String>{}]) {
      expect(
        () => RetroHostClient.start(command: ['/bin/true'], environment: environment, inheritEnvironment: false),
        throwsArgumentError,
      );
    }
  });
}
