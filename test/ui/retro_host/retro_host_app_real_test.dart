import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/controllers/pad_info.dart';
import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/gamepad/pad_navigation.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_client.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_install.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/retro_host/retro_host_game.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

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
    final hostFolder = Directory(p.join(work.path, 'host'))..createSync();
    final host = File(path('host')).copySync(p.join(hostFolder.path, p.basename(path('host')))).path;
    File(path('core')).copySync(p.join(hostFolder.path, RetroHostInstall.coreName(HostSystem.current)));

    final fixture = makeFixture(withToolkit: false, environment: {RetroHostInstall.variable: host});
    final model = fixture.model;
    final sessions = <RecordingSession>[];
    model.openRetroHost = (install, {required volume, required muted}) {
      final session = RecordingSession(RetroHostClient.start(command: [install.host], volume: volume, muted: muted));
      sessions.add(session);
      return session;
    };
    try {
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
    } finally {
      model.dispose();
      for (final session in sessions) {
        await session.ended.timeout(const Duration(seconds: 20), onTimeout: () => RetroHostEnd.clean);
      }
      fixture.dispose();
      work.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
