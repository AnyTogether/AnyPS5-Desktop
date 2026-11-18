import 'dart:async';
import 'dart:io';

import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/gamepad/pad_navigation.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_client.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_protocol.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/background.dart';
import 'package:anyps5_desktop/ui/components.dart';
import 'package:anyps5_desktop/ui/home.dart';
import 'package:anyps5_desktop/ui/retro_host/retro_host_game.dart';
import 'package:anyps5_desktop/ui/retro_host/retro_option_sections.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_process.dart';
import '../support/ps1_launcher.dart';
import 'retro_host/fake_retro_host_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Ps1Launcher launcher;
  tearDown(() => launcher.dispose());

  test('off as it starts: a PS1 disc still goes to the emulator chosen, and the row shows only with a host', () async {
    launcher = Ps1Launcher();
    final model = launcher.model;
    expect(model.preferences.retroHostPs1, isFalse);
    expect(model.stateOf(launcher.game), isA<NeedsEmulator>());
    final emulators = launcher.emulatorSettings();
    expect(emulators.rows.map((row) => row.id), contains('retro-host-ps1'));
    expect(emulators.rows.map((row) => row.id), isNot(contains('retro-host-bios')));

    model.closeOverlay();
    model.preferences.retroEmulators['ps1'] = (File(
      p.join(launcher.fixture.temp.path, 'duckstation'),
    )..createSync()).path;
    final process = FakeGameProcess();
    addTearDown(process.quit);
    var launches = 0;
    model.startRetroGame = ({required installed, required program, required arguments, required logFile}) async {
      launches++;
      return runningFor(process);
    };
    final playing = model.play(launcher.game);
    await pumpEventQueue();
    expect(launches, 1);
    expect(launcher.opened, isEmpty);
    expect(model.retroPlay, isNull);
    process.quit();
    await playing;
  });

  test('without a host the row is not there and the setting does nothing', () async {
    launcher = Ps1Launcher(hostFound: false);
    final model = launcher.model..setRetroHostPs1(true);
    final emulators = launcher.emulatorSettings();
    expect(emulators.rows.map((row) => row.id), isNot(contains('retro-host-ps1')));
    expect(model.playsInHost(RetroPlatform.ps1), isFalse);
    expect(model.stateOf(launcher.game), isA<NeedsEmulator>());
  });

  test('on: the disc plays in the host with the paths, the volume and the options the player kept', () async {
    launcher = Ps1Launcher();
    final model = launcher.model
      ..setRetroHostPs1(true)
      ..preferences.retroHostVolume = 40
      ..preferences.retroHostMuted = true
      ..preferences.retroHostOptions.addAll({
        'swanstation_CDROM_ReadSpeedup': '2',
        'swanstation_GPU_ResolutionScale': '2',
        'swanstation_GPU_TextureFilter': 'Bilinear',
      });
    expect(model.stateOf(launcher.game), isA<Installed>(), reason: 'no DuckStation needed');
    expect(launcher.emulatorSettings().rows.map((row) => row.id), contains('retro-host-bios'));
    model.closeOverlay();

    final playing = model.play(launcher.game);
    await pumpEventQueue();
    expect(model.retroPlay?.game, launcher.game);
    expect(model.retroPlay!.loading, isTrue);
    expect(model.retroInGame, isTrue);
    final (install, volume, muted) = launcher.opened.single;
    expect((install.host, install.core), (launcher.host, launcher.core));
    expect((volume, muted), (0.4, true));
    launcher.session.nextStatus = fakeStatus(ready: false);
    launcher.session.readyCompleter.complete();
    await playing;
    expect(launcher.play.loading, isTrue);
    expect(launcher.session.startArgs, {
      'core': launcher.core,
      'disc': p.normalize(launcher.disc),
      'system': p.normalize(model.paths.retroSystem),
      'saves': p.normalize(model.paths.retroSaves),
      'options': {'swanstation_CDROM_ReadSpeedup': '2', 'swanstation_GPU_ResolutionScale': '2'},
    }, reason: 'the internal resolution is sent; another graphics option has no page yet, so it is kept back');
    expect(Directory(model.paths.retroSystem).existsSync(), isTrue);
    expect(model.preferences.lastPlayed[launcher.game.id], isNotNull);

    launcher.session.nextStatus = fakeStatus();
    await launcher.play.host.refresh();
    expect(launcher.play.host.phase, RetroHostGamePhase.playing);
    expect(launcher.play.loading, isFalse);
    expect(launcher.play.problem, isNull);
  });

  test(
    'on the game screen the controller is the game\'s: only PS acts, and opens the menu over the paused game',
    () async {
      launcher = Ps1Launcher();
      final model = launcher.model..setRetroHostPs1(true);
      await launcher.start();
      final session = launcher.session;

      for (final command in [Command.select, Command.back, Command.options, Command.left, Command.nextGame]) {
        model.padCommand(switch (command) {
          Command.select => PadCommand.select,
          Command.back => PadCommand.back,
          Command.options => PadCommand.menu,
          Command.left => PadCommand.left,
          _ => PadCommand.nextGame,
        });
      }
      expect(model.overlay, isNull, reason: 'Cross, Circle, Start, the D-pad and R1 are the game\'s');
      final asked = model.sounds.requests;
      model.padCommand(PadCommand.up);
      model.padCommand(PadCommand.down);
      expect(model.sounds.requests, asked, reason: 'no launcher sound for a direction the game took');
      expect(session.calls.where((call) => call.$1 == 'pause'), isEmpty);
      expect(model.phonePadMovesLauncher, isFalse, reason: 'a phone\'s Options does not open Settings over the game');

      model.padCommand(PadCommand.home);
      await pumpEventQueue();
      expect(model.overlay, Layer.retroMenu);
      expect(launcher.play.menu.isOpen, isTrue);
      expect(launcher.play.controls.suspended, isTrue);
      expect(session.calls.last, ('pause', true));

      model.padCommand(PadCommand.home);
      await pumpEventQueue();
      expect(model.overlay, isNull);
      expect(launcher.play.controls.suspended, isFalse);
      expect(session.calls.last, ('pause', false));

      model.openRetroMenu();
      model.handle(Command.options);
      await pumpEventQueue();
      expect(model.overlay, isNull, reason: 'Options leaves the menu as Back does');
      expect(launcher.play.menu.isOpen, isFalse);
      expect(session.calls.last, ('pause', false));

      model.openRetroMenu();
      model.homeHeld();
      await pumpEventQueue();
      expect(model.overlay, isNull, reason: 'held PS leaves the game menu, not opens the home menu');
      expect(launcher.play.menu.isOpen, isFalse);

      model.mouseBack();
      expect(model.overlay, Layer.retroMenu, reason: 'the mouse\'s Back opens the menu');
      model.handle(Command.back);
      expect(model.overlay, isNull);
    },
  );

  test('the menu: discs, a page per section, the core\'s options and the volume, kept for later games', () async {
    launcher = Ps1Launcher();
    final model = launcher.model..setRetroHostPs1(true);
    await launcher.start(status: recordedStatus());
    final session = launcher.session;
    await model.openQuickMenu();
    await pumpEventQueue();
    expect(model.overlay, Layer.retroMenu);
    expect(model.panelCategories().single.title, 'Night Racer');
    expect(
      [for (final row in model.panelCategories().single.rows) row.id],
      [
        'resume',
        'disc-0',
        'disc-1',
        'section-audio',
        'resolution',
        'section-controller',
        'section-console',
        'section-advanced',
        'closeGame',
      ],
      reason: 'Graphics is not in the menu but for the internal resolution; a section shows only with rows',
    );
    expect(launcher.row('disc-0').detail, 'In the console.');
    expect(launcher.row('section-console').title, T.text('retroMenuConsole'));

    session.callResults['changeDisc'] = true;
    (launcher.row('disc-1').kind as ActionRow).run();
    await pumpEventQueue();
    expect(session.calls, contains(('changeDisc', 1)));

    (launcher.row('section-console').kind as ActionRow).run();
    expect(model.overlay, Layer.retroMenu);
    expect(model.panelCategories().single.title, T.text('retroMenuConsole'));
    expect(
      [for (final row in model.panelCategories().single.rows) row.id],
      [
        'option-swanstation_Console_Region',
        'option-swanstation_BIOS_PathNTSCU',
        'option-swanstation_BIOS_PatchFastBoot',
        'option-swanstation_CDROM_RegionCheck',
        'option-swanstation_CDROM_ReadSpeedup',
        'option-swanstation_CDROM_SeekSpeedup',
        'option-swanstation_CPU_Overclock',
      ],
      reason: 'in the order the host lists them; the 8 MB RAM of the development console is not shown',
    );
    expect(launcher.row('option-swanstation_Console_Region').detail, T.text('retroMenuOptionRestartOnlyDetail'));
    expect(launcher.row('option-swanstation_BIOS_PathNTSCU').title, 'NTSC-U BIOS');
    expect(launcher.row('option-swanstation_CDROM_ReadSpeedup').detail, isNull);

    session.callResults['option'] = true;
    final speed = launcher.row('option-swanstation_CDROM_ReadSpeedup').kind as ChoiceRow;
    expect(speed.options.take(2), ['None (Double Speed)', '2x (Quad Speed)']);
    session.nextStatus = recordedStatus(selected: {'swanstation_CDROM_ReadSpeedup': 1});
    speed.set(1);
    await pumpEventQueue();
    expect(session.calls.last.$1, 'option');
    expect(session.calls.last.$2, {'key': 'swanstation_CDROM_ReadSpeedup', 'value': '2'});
    expect(model.preferences.retroHostOptions, {'swanstation_CDROM_ReadSpeedup': '2'});

    final region = launcher.row('option-swanstation_Console_Region').kind as ChoiceRow;
    session.nextStatus = _pending(
      recordedStatus(selected: {'swanstation_CDROM_ReadSpeedup': 1}),
      'swanstation_Console_Region',
      2,
    );
    region.set(2);
    await pumpEventQueue();
    expect(launcher.row('option-swanstation_Console_Region').detail, T.text('retroMenuOptionRestartDetail'));

    model.handle(Command.back);
    expect(model.overlay, Layer.retroMenu, reason: 'Back on a section goes back to the first page');
    expect(model.panelCategories().single.id, 'retroMenu');
    expect(model.panelRow, 6, reason: 'on the Console row');
    expect(launcher.play.menu.isOpen, isTrue);

    (launcher.row('section-advanced').kind as ActionRow).run();
    expect(
      [for (final row in model.panelCategories().single.rows) row.id],
      [
        'option-swanstation_CDROM_ReadThread',
        'option-swanstation_CDROM_LoadImagePatches',
        'option-swanstation_CDROM_LoadImageToRAM',
        'option-swanstation_CDROM_PreCacheCHD',
        'option-swanstation_CPU_ExecutionMode',
        'option-swanstation_CDROM_ReadaheadSectors',
        'option-swanstation_Main_ApplyGameSettings',
        'option-swanstation_Main_RunaheadFrameCount',
        'option-swanstation_Hacks_OldMDECRoutines',
      ],
    );
    expect(launcher.row('option-swanstation_CDROM_LoadImagePatches').title, 'Apply Image Patches');
    expect(launcher.row('option-swanstation_CPU_ExecutionMode').title, 'CPU Execution Mode');
    model.handle(Command.back);

    (launcher.row('section-audio').kind as ActionRow).run();
    expect(
      [for (final row in model.panelCategories().single.rows) row.id],
      ['volume', 'mute', 'option-swanstation_CDROM_MuteCDAudio', 'option-swanstation_Audio_FastHook'],
    );
    expect(
      launcher.play.menu.optionsIn(RetroOptionSection.graphics),
      hasLength(16),
      reason: 'kept for a Graphics page',
    );
    expect(launcher.row('option-swanstation_Audio_FastHook').title, 'Use Per-Frame Audio Batching');
    expect(launcher.row('option-swanstation_Audio_FastHook').detail, T.text('retroMenuOptionRestartOnlyDetail'));
    final volume = launcher.row('volume').kind as StepperRow;
    expect(volume.value, 100);
    volume.set(50);
    await pumpEventQueue();
    expect(session.calls.last.$1, 'volume');
    expect(session.calls.last.$2, {'level': 0.5, 'muted': false});
    expect(model.preferences.retroHostVolume, 50);
    (launcher.row('mute').kind as ToggleRow).set(true);
    await pumpEventQueue();
    expect(session.calls.last.$2, {'level': 0.5, 'muted': true});
    expect(model.preferences.retroHostMuted, isTrue);

    model.handle(Command.options);
    await pumpEventQueue();
    expect(model.overlay, isNull, reason: 'Options leaves the menu from a section too');
    expect(session.calls.last, ('pause', false));
    model.openRetroMenu();
    expect(model.panelCategories().single.id, 'retroMenu', reason: 'the menu opens on its first page');
    (launcher.row('resume').kind as ActionRow).run();
    await pumpEventQueue();
    expect(model.overlay, isNull);
  });

  test('the internal resolution after Audio: Native to 4x of what the host lists, kept for later games', () async {
    launcher = Ps1Launcher();
    final model = launcher.model..setRetroHostPs1(true);
    await launcher.start(status: recordedStatus());
    final session = launcher.session;
    model.openRetroMenu();
    await pumpEventQueue();
    final row = launcher.row('resolution');
    expect(row.title, T.text('retroResolution'));
    expect(row.detail, T.text('retroResolutionDetail'));
    final choice = row.kind as ChoiceRow;
    expect(choice.options, ['Native', '2x', '3x', '4x'], reason: 'the host lists 1 to 8; 5x to 8x are not offered');
    expect(choice.selected, 0);

    session.callResults['option'] = false;
    choice.set(3);
    await pumpEventQueue();
    expect(session.calls.last.$1, 'option');
    expect(session.calls.last.$2, {'key': 'swanstation_GPU_ResolutionScale', 'value': '4'});
    expect(model.preferences.retroHostOptions, isNot(contains('swanstation_GPU_ResolutionScale')), reason: 'refused');

    session.callResults['option'] = true;
    session.nextStatus = recordedStatus(selected: {'swanstation_GPU_ResolutionScale': 3});
    choice.set(3);
    await pumpEventQueue();
    expect(model.preferences.retroHostOptions['swanstation_GPU_ResolutionScale'], '4');
    expect((launcher.row('resolution').kind as ChoiceRow).selected, 3);
    expect(model.overlay, Layer.retroMenu, reason: 'the menu stays open on its first page');
  });

  test('no internal resolution row while the host draws without the GPU', () async {
    launcher = Ps1Launcher();
    final model = launcher.model..setRetroHostPs1(true);
    final software = RetroStatus.parse({...recordedStatus().toJson(), 'hardware': false});
    await launcher.start(status: software);
    model.openRetroMenu();
    await pumpEventQueue();
    expect([for (final row in model.panelCategories().single.rows) row.id], isNot(contains('resolution')));
  });

  test('an option a player has no use for is neither shown nor sent, though it was kept', () async {
    launcher = Ps1Launcher();
    final model = launcher.model
      ..setRetroHostPs1(true)
      ..preferences.retroHostOptions.addAll({
        'swanstation_Console_Enable8MBRAM': 'true',
        'swanstation_Display_ShowOSDMessages': 'true',
        'swanstation_CDROM_ReadSpeedup': '2',
      });
    await launcher.start(status: recordedStatus());
    expect(launcher.session.startArgs!['options'], {'swanstation_CDROM_ReadSpeedup': '2'});
    model.openRetroMenu();
    for (final section in retroMenuSections.keys) {
      (launcher.row('section-${section.name}').kind as ActionRow).run();
      final ids = [for (final row in model.panelCategories().single.rows) row.id];
      expect(ids, isNot(contains('option-swanstation_Console_Enable8MBRAM')));
      expect(ids, isNot(contains('option-swanstation_Display_ShowOSDMessages')));
      model.handle(Command.back);
    }
  });

  test('Close Game stops and forgets the game and keeps the host for the next one', () async {
    launcher = Ps1Launcher();
    final model = launcher.model..setRetroHostPs1(true);
    model.select(model.games.indexOf(launcher.game));
    await launcher.start();
    final session = launcher.session;
    model.openRetroMenu();
    await pumpEventQueue();
    session.callGate = Completer<void>();
    (launcher.row('closeGame').kind as ActionRow).run();
    model.padCommand(PadCommand.home);
    expect(model.overlay, isNull, reason: 'no menu while the game closes');
    session.callGate!.complete();
    await pumpEventQueue();
    expect(model.retroPlay, isNull);
    expect(model.overlay, isNull);
    expect(session.calls.map((call) => call.$1), containsAllInOrder(['stop', 'release']));
    expect(session.shutdownAsked, isFalse);
    expect(model.retroHostKeeper.holding, isTrue);

    session.calls.clear();
    model.preferences.retroHostVolume = 70;
    await launcher.start();
    expect(launcher.opened, hasLength(1), reason: 'the next game starts on the same host');
    expect(launcher.play.host.session, same(session));
    expect(launcher.play.host.phase, RetroHostGamePhase.playing);
    expect(session.calls.first.$1, 'volume');
    expect(session.calls.first.$2, {'level': 0.7, 'muted': false});
    expect(model.retroHostKeeper.holding, isFalse, reason: 'taken by the game');
  });

  test('the kept host is shut down when the player leaves the PS1 games', () async {
    launcher = Ps1Launcher();
    final model = launcher.model..setRetroHostPs1(true);
    model.select(model.games.indexOf(launcher.game));
    await launcher.start();
    await model.closeRetroGame();
    expect(model.retroHostKeeper.holding, isTrue);
    model.setRetroHostPs1(false);
    await pumpEventQueue();
    expect(model.retroHostKeeper.holding, isFalse);
    expect(launcher.session.shutdownAsked, isTrue);
    expect(launcher.session.closed, isTrue);
  });

  test('the kept host is shut down after a quiet while', () async {
    launcher = Ps1Launcher();
    final model = launcher.model..setRetroHostPs1(true);
    model.retroHostKeeper.idleLimit = const Duration(milliseconds: 20);
    model.select(model.games.indexOf(launcher.game));
    await launcher.start();
    await model.closeRetroGame();
    expect(model.retroHostKeeper.holding, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await pumpEventQueue();
    expect(model.retroHostKeeper.holding, isFalse);
    expect(launcher.session.shutdownAsked, isTrue);
    expect(launcher.session.closed, isTrue);
  });

  test('a kept host that crashed is forgotten, and the next game starts a new one', () async {
    launcher = Ps1Launcher();
    final model = launcher.model..setRetroHostPs1(true);
    model.select(model.games.indexOf(launcher.game));
    await launcher.start();
    await model.closeRetroGame();
    final first = launcher.session;
    first.endedCompleter.complete(RetroHostEnd.hostFailure);
    await pumpEventQueue();
    expect(model.retroHostKeeper.holding, isFalse);
    expect(first.closed, isTrue);

    launcher.sessions.add(FakeRetroHostSession());
    await launcher.start();
    expect(launcher.opened, hasLength(2));
    expect(launcher.play.host.session, same(launcher.session));
    expect(launcher.play.host.phase, RetroHostGamePhase.playing);
  });

  test('a host that crashed during a game is shut down, not kept, and the next game starts a new one', () async {
    launcher = Ps1Launcher();
    final model = launcher.model..setRetroHostPs1(true);
    model.select(model.games.indexOf(launcher.game));
    await launcher.start();
    final first = launcher.session;
    first.nextStatus = const RetroStatus.failed(
      error: 'The emulator closed unexpectedly.',
      errorCode: RetroErrorCode.hostExited,
    );
    first.endedCompleter.complete(RetroHostEnd.hostFailure);
    await pumpEventQueue();
    expect(launcher.play.problem, 'retroHostExitedDetail');
    model.handle(Command.select);
    await pumpEventQueue();
    expect(model.retroPlay, isNull);
    expect(model.retroHostKeeper.holding, isFalse);
    expect(first.closed, isTrue);

    launcher.sessions.add(FakeRetroHostSession());
    await launcher.start();
    expect(launcher.opened, hasLength(2));
    expect(launcher.play.host.phase, RetroHostGamePhase.playing);
  });

  test('a host that still reports a game after release is shut down, not kept', () async {
    launcher = Ps1Launcher();
    final model = launcher.model..setRetroHostPs1(true);
    model.select(model.games.indexOf(launcher.game));
    await launcher.start();
    final session = launcher.session..stopStatus = fakeStatus();
    await model.closeRetroGame();
    expect(session.calls.map((call) => call.$1), containsAllInOrder(['stop', 'release']));
    expect(model.retroHostKeeper.holding, isFalse);
    expect(session.shutdownAsked, isTrue);
  });

  test('a game that ended on its own is forgotten with release before its host is kept', () async {
    launcher = Ps1Launcher();
    final model = launcher.model..setRetroHostPs1(true);
    model.select(model.games.indexOf(launcher.game));
    await launcher.start();
    final session = launcher.session;
    session.nextStatus = fakeStatus(ended: true, errorCode: RetroErrorCode.bios);
    await launcher.play.host.refresh();
    expect(launcher.play.problem, 'retroHostBiosDetail');
    model.handle(Command.select);
    await pumpEventQueue();
    expect(model.retroPlay, isNull);
    expect(session.calls.map((call) => call.$1), contains('release'));
    expect(model.retroHostKeeper.holding, isTrue);
  });

  test('another game starting lets the kept host go', () async {
    launcher = Ps1Launcher();
    final model = launcher.model..setRetroHostPs1(true);
    model.select(model.games.indexOf(launcher.game));
    await launcher.start();
    await model.closeRetroGame();
    expect(model.retroHostKeeper.holding, isTrue);
    model.starting = launcher.game;
    model.savePreferences();
    await pumpEventQueue();
    model.starting = null;
    expect(model.retroHostKeeper.holding, isFalse);
    expect(launcher.session.shutdownAsked, isTrue);
  });

  test('a game that stops on an error shows why; Enter goes back to the library', () async {
    launcher = Ps1Launcher();
    final model = launcher.model..setRetroHostPs1(true);
    await launcher.start();
    launcher.session.nextStatus = fakeStatus(ended: true, errorCode: RetroErrorCode.bios);
    await launcher.play.host.refresh();
    expect(model.retroPlay, isNotNull);
    expect(launcher.play.problem, 'retroHostBiosDetail');
    model.padCommand(PadCommand.home);
    expect(model.overlay, isNull, reason: 'a game that ended has no menu');

    model.handle(Command.select);
    await pumpEventQueue();
    expect(model.retroPlay, isNull);
    expect(launcher.session.shutdownAsked, isTrue);
  });

  test('each error code has its own words, and an unknown one is an error without a known cause', () {
    launcher = Ps1Launcher();
    for (final (code, key) in [
      (RetroErrorCode.bios, 'retroHostBiosDetail'),
      (RetroErrorCode.disc, 'retroHostDiscDetail'),
      (RetroErrorCode.core, 'retroHostCoreDetail'),
      (RetroErrorCode.stalled, 'retroHostStalledDetail'),
      (RetroErrorCode.didNotStart, 'retroHostDidNotStartDetail'),
      (RetroErrorCode.frameTooLarge, 'retroHostFrameTooLargeDetail'),
      (RetroErrorCode.other, 'retroHostOtherDetail'),
      (RetroErrorCode.hostExited, 'retroHostExitedDetail'),
      (RetroErrorCode.hostHung, 'retroHostHungDetail'),
      ('somethingNew', 'retroHostOtherDetail'),
    ]) {
      expect(retroHostErrorKey(code), key, reason: code);
      expect(T.text(key), isNot(key), reason: '$key is in en.json');
    }
    expect(retroHostErrorKey(RetroErrorCode.none), isNull);
    for (final key in ['retroHostOutdatedDetail', 'retroHostNotStartedDetail', 'retroHostLoading', 'retroHostBack']) {
      expect(T.text(key), isNot(key), reason: '$key is in en.json');
    }
  });

  test('a game that could not be followed is an error, though its last status said none', () async {
    launcher = Ps1Launcher();
    final model = launcher.model..setRetroHostPs1(true);
    await launcher.start();
    launcher.session.statusError = const RetroCallError(RetroCallError.argument, 'refused');
    await launcher.play.host.refresh();
    expect(launcher.play.host.phase, RetroHostGamePhase.ended);
    expect(launcher.play.host.endStatus?.errorCode, RetroErrorCode.none);
    expect(launcher.play.problem, 'retroHostOtherDetail');
    expect(model.retroPlay, isNotNull, reason: 'the error screen stays');
  });

  test('the launcher going away while Close Game waits on the host lets go of everything once', () async {
    launcher = Ps1Launcher();
    final model = launcher.model..setRetroHostPs1(true);
    await launcher.start();
    final gate = launcher.session.callGate = Completer<void>();
    final closing = model.closeRetroGame();
    await pumpEventQueue();
    final play = launcher.play;
    expect(play.counted, isTrue, reason: 'the play time is counted before waiting on the host');
    launcher.disposeModel();
    gate.complete();
    await closing;
    expect(launcher.session.shutdownAsked, isTrue);
    expect(launcher.session.closed, isTrue);
  });

  test('a host that cannot be started says so and leaves the library as it was', () async {
    launcher = Ps1Launcher();
    final model = launcher.model..setRetroHostPs1(true);
    model.openRetroHost = (install, {checked, required volume, required muted}) =>
        throw const ProcessException('anyps5-retro-host', [], 'not executable');
    await model.play(launcher.game);
    expect(model.retroPlay, isNull);
    expect(model.toast, T.text('retroHostNotStartedDetail'));
  });

  test('one game at a time: nothing else starts over it, and a family limit closes it', () async {
    launcher = Ps1Launcher();
    final model = launcher.model..setRetroHostPs1(true);
    await launcher.start();
    var launches = 0;
    model.startRetroGame = ({required installed, required program, required arguments, required logFile}) async {
      launches++;
      throw StateError('no other game may start');
    };
    await model.play(launcher.game);
    expect(launcher.opened, hasLength(1));
    expect(launches, 0);

    await model.closeGame();
    expect(model.retroPlay, isNull);
    expect(launcher.session.shutdownAsked, isTrue);
  });

  test('a layer that replaced the menu and closes gives the game back, not a paused game unseen', () async {
    launcher = Ps1Launcher();
    final model = launcher.model..setRetroHostPs1(true);
    await launcher.start();
    model.open(Layer.family);
    await pumpEventQueue();
    expect(launcher.play.menu.isOpen, isTrue, reason: 'a notice straight over the game pauses it');
    expect(launcher.play.controls.suspended, isTrue, reason: 'the notice takes the controller');
    expect(launcher.session.calls.last, ('pause', true));
    model.closeOverlay();
    await pumpEventQueue();
    expect(launcher.play.menu.isOpen, isFalse);
    model.openRetroMenu();
    await pumpEventQueue();
    model.open(Layer.family);
    expect(launcher.play.menu.isOpen, isTrue, reason: 'still paused under the notice');
    model.closeOverlay();
    await pumpEventQueue();
    expect(model.retroInGame, isTrue);
    expect(launcher.play.menu.isOpen, isFalse);
    expect(launcher.play.controls.suspended, isFalse);
    expect(launcher.session.calls.last, ('pause', false));
  });

  test('a game that stopped on an error is over at once, though its error screen stays', () async {
    launcher = Ps1Launcher();
    final model = launcher.model..setRetroHostPs1(true);
    await launcher.start();
    final play = launcher.play;
    expect(play.over, isFalse);
    launcher.session.nextStatus = fakeStatus(ended: true, errorCode: RetroErrorCode.disc);
    await play.host.refresh();
    final ended = play.endedAt;
    expect(ended, isNotNull);
    expect(play.counted, isFalse, reason: 'counted once, when it is closed');
    expect(model.retroPlay, isNotNull);
    await model.closeRetroGame();
    expect(model.retroPlay, isNull);
    expect(play.endedAt, ended, reason: 'play time stops when the game did');
  });

  test('a game that ends without an error goes straight back to the library', () async {
    launcher = Ps1Launcher();
    final model = launcher.model..setRetroHostPs1(true);
    await launcher.start();
    launcher.session.nextStatus = fakeStatus(ended: true);
    await launcher.play.host.refresh();
    await pumpEventQueue();
    expect(model.retroPlay, isNull);
  });

  test('a memory card the host cannot read is said once, and the game plays on', () async {
    launcher = Ps1Launcher();
    final model = launcher.model..setRetroHostPs1(true);
    await launcher.start();
    expect(model.toast, isNot(T.text('retroHostCardUnreadable')));
    launcher.session.nextStatus = fakeStatus(cardUnreadable: true);
    await launcher.play.host.refresh();
    await pumpEventQueue();
    expect(model.toast, T.text('retroHostCardUnreadable'));
    expect(model.retroPlay, isNotNull);
    expect(launcher.play.problem, isNull);
    model.show('something else');
    await launcher.play.host.refresh();
    await pumpEventQueue();
    expect(model.toast, 'something else', reason: 'once per game');
  });

  test('a host that speaks another protocol version says it needs updating', () async {
    launcher = Ps1Launcher();
    final model = launcher.model..setRetroHostPs1(true);
    final playing = model.play(launcher.game);
    launcher.session.readyCompleter.completeError(const RetroHostGone(RetroHostEnd.unsupported));
    launcher.session.endedCompleter.complete(RetroHostEnd.unsupported);
    await playing;
    await pumpEventQueue();
    expect(launcher.play.problem, 'retroHostOutdatedDetail');
  });

  test('Esc or PS while it loads gives the start up', () async {
    launcher = Ps1Launcher();
    final model = launcher.model..setRetroHostPs1(true);
    final playing = model.play(launcher.game);
    await pumpEventQueue();
    model.padCommand(PadCommand.home);
    launcher.session.readyCompleter.complete();
    await playing;
    await pumpEventQueue();
    expect(model.retroPlay, isNull);
    expect(launcher.session.startArgs, isNull, reason: 'start is never sent for a start given up');
  });

  testWidgets('the home screen rests under a game in the host: its background and focus ring are still', (
    tester,
  ) async {
    launcher = Ps1Launcher();
    final model = launcher.model..setRetroHostPs1(true);
    ArtworkImage.readSynchronously = true;
    await tester.runAsync(ThemeBackground.preload);
    Widget home() => Directionality(
      textDirection: TextDirection.ltr,
      child: Backdrop(model: model),
    );
    bool still() => tester.widget<ThemeBackground>(find.byType(ThemeBackground)).paused;
    await tester.pumpWidget(home());
    expect(still(), isFalse);
    expect(model.homeRingMoves, isTrue);

    await tester.runAsync(launcher.start);
    await tester.pumpWidget(home());
    expect(model.gamePlaying, isTrue);
    expect(still(), isTrue);
    expect(model.homeRingMoves, isFalse);

    await tester.runAsync(model.closeRetroGame);
    await tester.pumpWidget(home());
    expect(still(), isFalse, reason: 'the library is back');
    expect(model.homeRingMoves, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  test('a status that says nothing new changes nothing in the launcher; the menu follows one that does', () async {
    launcher = Ps1Launcher();
    final model = launcher.model..setRetroHostPs1(true);
    await launcher.start(status: menuStatus());
    var heard = 0;
    model.addListener(() => heard++);
    for (var asked = 0; asked < 4; asked++) {
      launcher.session.nextStatus = menuStatus();
      await launcher.play.host.refresh();
    }
    expect(heard, 0, reason: 'a game that plays on is not the launcher rebuilt twice a second');

    launcher.session.nextStatus = menuStatus(busy: true);
    await launcher.play.host.refresh();
    expect(heard, 0, reason: "with no menu open, only the game's own screen follows the host");

    model.openRetroMenu();
    await pumpEventQueue();
    heard = 0;
    launcher.session.nextStatus = menuStatus();
    await launcher.play.host.refresh();
    expect(heard, 1, reason: 'the open menu shows that the disc change ended');
    expect(launcher.row('disc-1').detail, isNull);
    model.resumeRetroGame();
    await pumpEventQueue();

    heard = 0;
    launcher.session.nextStatus = fakeStatus(ended: true, errorCode: RetroErrorCode.disc);
    await launcher.play.host.refresh();
    expect(heard, greaterThan(0), reason: "a game that stopped on an error is the launcher's change");
    expect(launcher.play.problem, 'retroHostDiscDetail');
  });

  test('the host is looked for once, not on every use', () async {
    launcher = Ps1Launcher();
    final model = launcher.model..setRetroHostPs1(true);
    final found = model.retroHostInstall;
    expect(found, isNotNull);
    File(launcher.host).deleteSync();
    expect(model.retroHostInstall, same(found));
    expect(model.playsInHost(RetroPlatform.ps1), isTrue);
  });

  test("quitting shuts the game's host down, which stops the game and writes its memory cards", () async {
    launcher = Ps1Launcher();
    final model = launcher.model..setRetroHostPs1(true);
    await launcher.start();
    final session = launcher.session;
    await model.shutDownRetroHosts();
    expect(session.shutdownAsked, isTrue, reason: 'protocol.md "shutdown": the host stops its game as stop does');
    expect(session.closed, isTrue);
    expect(model.retroHostKeeper.holding, isFalse);
  });

  test('quitting shuts a kept host down', () async {
    launcher = Ps1Launcher();
    final model = launcher.model..setRetroHostPs1(true);
    model.select(model.games.indexOf(launcher.game));
    await launcher.start();
    await model.closeRetroGame();
    expect(model.retroHostKeeper.holding, isTrue);
    await model.shutDownRetroHosts();
    expect(launcher.session.shutdownAsked, isTrue);
    expect(launcher.session.closed, isTrue);
    expect(model.retroHostKeeper.holding, isFalse);
  });

  test('quitting while Close Game still waits on the host shuts it down, not kept', () async {
    launcher = Ps1Launcher();
    final model = launcher.model..setRetroHostPs1(true);
    model.select(model.games.indexOf(launcher.game));
    await launcher.start();
    final session = launcher.session;
    final gate = session.callGate = Completer<void>();
    final closing = model.closeRetroGame();
    await pumpEventQueue();
    final quitting = model.shutDownRetroHosts();
    gate.complete();
    await Future.wait([closing, quitting]);
    expect(session.shutdownAsked, isTrue);
    expect(session.closed, isTrue);
    expect(model.retroHostKeeper.holding, isFalse, reason: 'a host told to shut down is not kept for a next game');
    expect(model.retroPlay, isNull);
  });

  test('quitting waits only a short while for a host that does not exit', () async {
    launcher = Ps1Launcher();
    final model = launcher.model..setRetroHostPs1(true);
    await launcher.start();
    final session = launcher.session..exitsOnShutdown = false;
    final waited = Stopwatch()..start();
    await model.shutDownRetroHosts(limit: const Duration(milliseconds: 50));
    expect(session.shutdownAsked, isTrue);
    expect(session.closed, isFalse, reason: 'the host has not exited');
    expect(waited.elapsed, lessThan(RetroHostPlaying.quitLimit));
    session.endedCompleter.complete(RetroHostEnd.clean);
    await pumpEventQueue();
  });

  test('a game with no BIOS offers the BIOS folder on its error screen', () async {
    launcher = Ps1Launcher();
    final model = launcher.model..setRetroHostPs1(true);
    await launcher.start();
    launcher.session.nextStatus = fakeStatus(ended: true, errorCode: RetroErrorCode.bios);
    await launcher.play.host.refresh();
    model.handle(Command.options);
    expect(launcher.fixture.folders, [model.paths.retroSystem]);
    expect(model.retroPlay, isNotNull, reason: 'the error screen stays');
  });

  test('another error has no folder to open', () async {
    launcher = Ps1Launcher();
    final model = launcher.model..setRetroHostPs1(true);
    await launcher.start();
    launcher.session.nextStatus = fakeStatus(ended: true, errorCode: RetroErrorCode.disc);
    await launcher.play.host.refresh();
    model.handle(Command.options);
    expect(launcher.fixture.folders, isEmpty);
    expect(model.retroPlay, isNotNull);
  });

  test('Screenshot and Share say they are not there yet for a game in the host', () async {
    launcher = Ps1Launcher();
    final model = launcher.model..setRetroHostPs1(true);
    await launcher.start();
    expect(await model.takeScreenshot(), isNull);
    expect(model.toast, T.text('retroHostNoCapture'));
    model.show('something else');
    expect(await model.saveClip(), isNull);
    expect(model.toast, T.text('retroHostNoCapture'));
  });

  test("the loading line is the host's own words in English and the launcher's in other languages", () {
    launcher = Ps1Launcher();
    const status = RetroStatus(
      ready: false,
      ended: false,
      error: '',
      errorCode: '',
      progressLabel: 'Compiling shaders',
      progressPercent: 40,
    );
    expect(retroLoadingText(status), 'Compiling shaders');
    expect(retroLoadingText(null), T.text('retroHostLoading'));
    try {
      T.language = Language.byCode('tr');
      expect(T.language.code, 'tr');
      expect(retroLoadingText(status), T.text('retroHostLoading'));
    } finally {
      T.language = Language.english;
    }
  });
}

RetroStatus _pending(RetroStatus status, String key, int selected) {
  final json = status.toJson();
  final options = (json['options']! as Map).cast<String, Object?>();
  final option = (options[key]! as Map).cast<String, Object?>();
  option['selected'] = selected;
  options[key] = option;
  return RetroStatus.parse(json);
}
