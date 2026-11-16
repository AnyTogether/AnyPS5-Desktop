import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/controllers/pad_info.dart';
import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/gamepad/pad_navigation.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_client.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_install.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_release.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_store.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/retro_host/retro_host_game.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/fake_github.dart';
import '../../support/retro_host_release_fixture.dart';
import '../../support/signing.dart';
import '../../support/ui_support.dart';
import 'real_host_support.dart';

/// The launcher itself plays a PS1 disc from its emulator library in the real emulator host:
/// Settings › Emulators › Run PS1 games in the separate host on, the host found through
/// ANYPS5_RETRO_HOST beside its SwanStation library, the disc from a games folder, the app's
/// controller reader seating two controllers, PS opening the game's menu, and Close Game.
///
/// ANYPS5_RETRO_HOST_REAL names the JSON file of test/core/retro_host/retro_host_real_test.dart
/// (`host`, `core`, `bios`, `program`, `discBuilder`, and optionally `environment`). Without it
/// the test is skipped. The host is started with the test's own environment, as the launcher
/// starts it, so whatever the host needs to load (WinLibs' runtime on Windows) has to be on the
/// test's PATH.
///
/// With `packer` (the host repository's tools/package_release.py) and `coreLicence` (SwanStation's
/// LICENSE) the launcher gets its host as a release build does instead: the host and core are
/// packed as a release by that packer, signed with the fixture key of
/// test/fixtures/retro_host_release, published on a fake GitHub, downloaded through Settings ›
/// Emulators, and every host is started through its checked files. With `releaseFolder` instead (a
/// folder of what the host repository's release workflow packed, such as its `release-<system>`
/// artifact: this system's zip and `.files`), that very release is signed and published, so the
/// files the launcher installs and runs are the files the workflow packed; `host` and `core` are
/// then not needed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final configPath = Platform.environment['ANYPS5_RETRO_HOST_REAL'];
  if (configPath == null || configPath.isEmpty) {
    test('the launcher plays a PS1 disc in the real host', () {}, skip: 'ANYPS5_RETRO_HOST_REAL is not set');
    return;
  }
  final config = jsonDecode(File(configPath).readAsStringSync()) as Map<String, Object?>;
  String path(String key) => File(config[key]! as String).absolute.path;

  test('the launcher plays a PS1 disc in the real host', () async {
    final work = Directory.systemTemp.createTempSync('retro-host-app-real-');
    final release = config['packer'] != null || config['releaseFolder'] != null;
    String? host;
    if (!release) {
      final hostFolder = Directory(p.join(work.path, 'host'))..createSync();
      host = File(path('host')).copySync(p.join(hostFolder.path, p.basename(path('host')))).path;
      File(path('core')).copySync(p.join(hostFolder.path, RetroHostInstall.coreName(HostSystem.current)));
    }
    // The test binding answers every HTTP request with 400; the release comes from a fake GitHub.
    HttpOverrides.global = null;
    final github = release ? await FakeGitHub.start(repository: RetroHostStore.repository) : null;
    if (github != null) github.releases.add(FakeRelease('v1.0.0', _packed(config, work, path)));
    final fixture = makeFixture(
      withToolkit: false,
      environment: {RetroHostInstall.variable: ?host},
      retroHostApi: github?.api,
      retroHostKeys: release ? retroHostFixtureKeys() : null,
    );
    final model = fixture.model;
    final sessions = <RecordingSession>[];
    final checks = <RetroHostChecked?>[];
    model.openRetroHost = (install, {checked, required volume, required muted}) {
      checks.add(checked);
      final session = RecordingSession(
        RetroHostClient.start(command: [install.host], checked: checked, volume: volume, muted: muted),
      );
      sessions.add(session);
      return session;
    };
    try {
      if (release) {
        await model.retroHostDownload.download();
        expect(model.toast, T.format('retroHostReady', ['1.0.0']), reason: '${model.retroHostDownload.error}');
        expect(model.retroHostInstall?.checked, isTrue);
        model.setRetroHostPs1(false);
        stdout.writeln('release: downloaded and installed into ${model.paths.retroHost}');
      }
      final folder = Directory(p.join(model.root!, 'Hello World'))..createSync();
      final built = Process.runSync(pythonPath(), [
        path('discBuilder'),
        path('program'),
        p.join(folder.path, 'Hello World.cue'),
      ]);
      expect(built.exitCode, 0, reason: 'make_test_disc.py: ${built.stderr}');
      Directory(model.paths.retroSystem).createSync(recursive: true);
      File(path('bios')).copySync(p.join(model.paths.retroSystem, 'openbios.bin'));

      model.setRetroLibrary(true);
      final game = model.games.singleWhere((game) => game.retro?.platform == RetroPlatform.ps1);
      expect(model.stateOf(game), isA<NeedsEmulator>(), reason: 'no DuckStation, host off');
      model.setRetroHostPs1(true);
      expect(model.stateOf(game), isA<Installed>(), reason: 'the host plays it');
      model.preferences.retroHostVolume = 0;
      model.preferences.retroHostMuted = true;
      model.controllers.preview(
        const [PadInfo(id: 'one', name: 'Pad one', kind: PadKind.dualSense, driver: 'test')],
        states: {'one': PadState.idle},
      );

      model.select(model.games.indexOf(game));
      await model.play(game);
      final play = model.retroPlay!;
      expect(model.retroInGame, isTrue);
      await until(() => play.host.phase != RetroHostGamePhase.loading, const Duration(seconds: 60));
      expect(
        play.host.phase,
        RetroHostGamePhase.playing,
        reason: 'status ${play.host.status?.toJson()} ${play.host.failure}',
      );
      final session = sessions.single;
      if (release) {
        expect(checks.single?.held, isTrue, reason: 'the host was started through its checked files');
        stdout.writeln('release: started from ${checks.single!.program ?? checks.single!.executable}');
      }
      stdout.writeln('welcome: host ${session.client.hostVersion}, pixel format ${session.client.pixelFormat}');
      expect((play.host.volume, play.host.muted), (0.0, true), reason: 'the client sends it after welcome');

      final pictures = <Uint8List>[];
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (pictures.length < 2 && DateTime.now().isBefore(deadline)) {
        final pixels = await framePixels(play.host.picture.value);
        if (pixels != null && showsPicture(pixels) && (pictures.isEmpty || !samePixels(pictures.first, pixels))) {
          pictures.add(pixels);
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(pictures, hasLength(2), reason: 'two pictures on screen that are not black and differ');

      model.controllers.preview(
        const [
          PadInfo(id: 'one', name: 'Pad one', kind: PadKind.dualSense, driver: 'test'),
          PadInfo(id: 'two', name: 'Pad two', kind: PadKind.xbox, driver: 'test'),
        ],
        states: {
          'one': PadState.idle,
          'two': const PadState(pressed: {PadButton.south}),
        },
      );
      Iterable<(String, Object?, Object?)> ports() => session.answers.where((answer) => answer.$1 == 'connectedPorts');
      await until(() => ports().isNotEmpty, const Duration(seconds: 2));
      expect(ports().first, ('connectedPorts', 2, true), reason: 'the app\'s second controller joined port 2');

      model.padCommand(PadCommand.home);
      expect(model.overlay, Layer.retroMenu);
      await until(
        () => session.answers.any((answer) => answer.$1 == 'pause' && answer.$2 == true),
        const Duration(seconds: 2),
      );
      List<PanelRow> rows() => model.panelCategories().single.rows;
      stdout.writeln('menu: ${[for (final row in rows()) row.id]}');
      expect(
        [
          for (final row in rows())
            if (row.id.startsWith('section-')) row.id,
        ],
        ['section-audio', 'section-controller', 'section-console', 'section-advanced'],
      );
      for (final section in ['console', 'controller', 'advanced']) {
        (rows().singleWhere((row) => row.id == 'section-$section').kind as ActionRow).run();
        final ids = [for (final row in rows()) row.id];
        stdout.writeln('$section: $ids');
        expect(ids, everyElement(startsWith('option-swanstation_')), reason: section);
        expect(ids, isNotEmpty, reason: section);
        model.handle(Command.back);
      }
      expect(play.host.paused, isTrue, reason: 'Back from a section stays in the menu');
      (rows().singleWhere((row) => row.id == 'section-console').kind as ActionRow).run();
      final speed = rows().singleWhere((row) => row.id == 'option-swanstation_CDROM_ReadSpeedup');
      final choice = speed.kind as ChoiceRow;
      choice.set((choice.selected + 1) % choice.options.length);
      await until(() => session.answers.any((answer) => answer.$1 == 'option'), const Duration(seconds: 5));
      expect(session.answers.lastWhere((answer) => answer.$1 == 'option').$3, isTrue);
      await until(
        () => model.preferences.retroHostOptions.containsKey('swanstation_CDROM_ReadSpeedup'),
        const Duration(seconds: 2),
      );
      model.handle(Command.back);
      (rows().singleWhere((row) => row.id == 'section-audio').kind as ActionRow).run();
      (rows().singleWhere((row) => row.id == 'volume').kind as StepperRow).set(30);
      await until(
        () => session.answers.any((answer) => answer.$1 == 'volume' && (answer.$2! as Map)['level'] == 0.3),
        const Duration(seconds: 2),
      );
      expect(model.preferences.retroHostVolume, 30);
      model.padCommand(PadCommand.home);
      expect(model.overlay, isNull);
      await until(
        () => session.answers.any((answer) => answer.$1 == 'pause' && answer.$2 == false),
        const Duration(seconds: 2),
      );
      expect(play.host.phase, RetroHostGamePhase.playing);

      model.openRetroMenu();
      (model.panelCategories().single.rows.singleWhere((row) => row.id == 'closeGame').kind as ActionRow).run();
      await until(() => model.retroPlay == null, const Duration(seconds: 20));
      expect(session.answers.map((answer) => answer.$1), contains('release'));
      expect(play.host.phase, RetroHostGamePhase.closed);
      expect(model.retroHostKeeper.holding, isTrue, reason: 'the host is kept for the next game');
      final card = File(p.join(model.paths.retroSaves, 'Hello World.srm'));
      stdout.writeln('memory card: ${card.existsSync() ? card.lengthSync() : 'none'} bytes');

      await model.play(game);
      final second = model.retroPlay!;
      await until(() => second.host.phase != RetroHostGamePhase.loading, const Duration(seconds: 60));
      expect(second.host.phase, RetroHostGamePhase.playing, reason: '${second.host.failure}');
      expect(sessions, hasLength(1), reason: 'the second game runs in the same host');
      expect(
        session.client.frame?.epoch,
        2,
        reason: 'protocol.md "start": the epoch is one more for each later game in a host',
      );
      model.openRetroMenu();
      (model.panelCategories().single.rows.singleWhere((row) => row.id == 'closeGame').kind as ActionRow).run();
      await until(() => model.retroPlay == null, const Duration(seconds: 20));
      expect(model.retroHostKeeper.holding, isTrue);

      model.setRetroHostPs1(false);
      expect(model.retroHostKeeper.holding, isFalse, reason: 'the player left the PS1 games in the host');
      expect(await session.ended.timeout(const Duration(seconds: 20)), RetroHostEnd.clean);
      if (release) {
        await session.client.exited.timeout(const Duration(seconds: 20));
        expect(checks.single?.held, isFalse, reason: 'its files are let go once the host has exited');
      }
    } finally {
      await github?.close();
      model.dispose();
      for (final session in sessions) {
        await session.ended.timeout(const Duration(seconds: 20), onTimeout: () => RetroHostEnd.clean);
      }
      fixture.dispose();
      work.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}

/// The release to publish: the folder `releaseFolder` names, or the real host and core packed as
/// release 1.0.0 for this system by the host repository's packer; with SHA256SUMS of its files,
/// signed by the fixture key as sign.sh signs it.
Map<String, List<int>> _packed(Map<String, Object?> config, Directory work, String Function(String) path) {
  final Directory out;
  if (config['releaseFolder'] != null) {
    out = Directory(path('releaseFolder'));
  } else {
    out = Directory(p.join(work.path, 'release'))..createSync();
    _pack(out, path);
  }
  final files = {
    for (final file in out.listSync().whereType<File>())
      if (p.basename(file.path).startsWith('anyps5-retro-host-')) p.basename(file.path): file.readAsBytesSync(),
  };
  final sums = sumsOf(files);
  return {
    ...files,
    'SHA256SUMS': sums,
    'SHA256SUMS.sig': utf8.encode('${retroHostFixtureKey().signatureLine(sums)}\n'),
  };
}

void _pack(Directory out, String Function(String) path) {
  final packed = Process.runSync(pythonPath(), [
    path('packer'),
    '--version',
    '1.0.0',
    '--system',
    RetroHostSystem.current!.name,
    '--host',
    path('host'),
    '--core',
    path('core'),
    '--core-licence',
    path('coreLicence'),
    '--host-commit',
    '0' * 40,
    '--swanstation-commit',
    '0' * 40,
    '--out',
    out.path,
  ]);
  expect(packed.exitCode, 0, reason: 'package_release.py: ${packed.stderr}');
}
