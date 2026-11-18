import 'dart:ffi';
import 'dart:io';

import 'package:anyps5_desktop/core/retro_host/retro_host_protocol.dart';
import 'package:anyps5_desktop/core/retro_host/retro_state_slots.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/launcher.dart';
import 'package:anyps5_desktop/ui/retro_host/retro_play_view.dart';
import 'package:anyps5_desktop/ui/retro_host/retro_unchecked_mark.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/ps1_launcher.dart';
import '../support/ps2_host_recording.dart';
import '../support/save_states_host_recording.dart';
import '../support/ui_support.dart';
import 'retro_host/fake_retro_host_session.dart';

/// A PS1 game in the emulator host as it looks: loading, stopped on an error, its menu over the
/// game, its save state slots and the question before one is overwritten, the mark of a game on an
/// unchecked host, and Settings › Emulators with the host's rows; and a PS2 game's rows and its
/// missing BIOS.
void main() {
  late Ps1Launcher launcher;
  final shell = find.byType(LauncherShell);
  final slots = <FakeSlot>[];

  tearDown(() {
    T.language = Language.english;
    launcher.dispose();
    for (final slot in slots) {
      slot.free();
    }
    slots.clear();
  });

  /// A frame of the game: bands of colour, as a title screen might be.
  FakeSlot picture() {
    final slot = FakeSlot(320, 240);
    slots.add(slot);
    final pixels = slot.pixels.asTypedList(320 * 240 * 4);
    const bands = [
      [24, 32, 96, 255],
      [48, 80, 160, 255],
      [220, 120, 40, 255],
      [250, 210, 90, 255],
    ];
    for (var y = 0; y < 240; y++) {
      final band = bands[(y * bands.length) ~/ 240];
      for (var x = 0; x < 320; x++) {
        pixels.setAll((y * 320 + x) * 4, band);
      }
    }
    return slot;
  }

  /// A game playing on the signed release's host, as a release has it, or with [unchecked] on
  /// the host `ANYPS5_RETRO_HOST` names, as a debug or test build has it; with [saveStates], a host
  /// that lists `saveStates`.
  Future<void> playing(
    WidgetTester tester, {
    RetroStatus? status,
    bool frame = true,
    bool unchecked = false,
    bool saveStates = false,
  }) async {
    launcher = unchecked ? Ps1Launcher() : (await tester.runAsync(Ps1Launcher.withRelease))!;
    launcher.session.canSaveStates = saveStates;
    launcher.model.setRetroHostPs1(true);
    await tester.runAsync(() => launcher.start(status: status));
    await pumpLauncher(tester, launcher.model);
    if (frame) {
      launcher.session.send(picture().pin());
      for (var turn = 0; turn < 20 && launcher.play.host.picture.value == null; turn++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      }
      await settle(tester);
    }
  }

  testWidgets('loading: what the host is loading and how far', (tester) async {
    await playing(
      tester,
      status: const RetroStatus(
        ready: false,
        ended: false,
        error: '',
        errorCode: '',
        progressLabel: 'Compiling shaders',
        progressPercent: 40,
      ),
      frame: false,
    );
    expect(find.byKey(const ValueKey('retro-loading')), findsOneWidget);
    expect(find.text('Compiling shaders'), findsOneWidget);
    await expectLater(shell, matchesGoldenFile('goldens/retro_host_loading_en.png'));
  });

  testWidgets('stopped: no BIOS, the way back to the library, and the BIOS folder', (tester) async {
    await playing(tester, status: fakeStatus(ready: false, ended: true, errorCode: RetroErrorCode.bios), frame: false);
    expect(find.byKey(const ValueKey('retro-error')), findsOneWidget);
    expect(find.text('Night Racer stopped'), findsOneWidget);
    expect(find.text(T.text('retroHostBiosDetail')), findsOneWidget);
    expect(find.text(T.text('retroHostBiosFolder')), findsOneWidget);
    await expectLater(shell, matchesGoldenFile('goldens/retro_host_error_bios_en.png'));
  });

  testWidgets('playing: the picture over the whole window', (tester) async {
    await playing(tester);
    expect(find.byType(RetroPlayView), findsOneWidget);
    expect(launcher.play.host.picture.value, isNotNull);
    await expectLater(shell, matchesGoldenFile('goldens/retro_host_playing_en.png'));
  });

  testWidgets("playing on an unchecked host: the test build's mark in the corner", (tester) async {
    await playing(tester, unchecked: true);
    expect(launcher.play.unchecked, isTrue);
    expect(find.byType(RetroUncheckedMark), findsOneWidget);
    expect(find.text(T.text('retroHostUnchecked')), findsOneWidget);
    await expectLater(shell, matchesGoldenFile('goldens/retro_host_playing_unchecked_en.png'));
  });

  testWidgets('the menu over the paused game: discs, its sections, Close Game', (tester) async {
    await playing(tester, status: recordedStatus());
    launcher.model.openRetroMenu();
    await settle(tester);
    expect(find.text('Disc 2'), findsOneWidget);
    for (final key in ['retroMenuAudio', 'retroMenuController', 'retroMenuConsole', 'retroMenuAdvanced']) {
      expect(find.text(T.text(key)), findsOneWidget, reason: key);
    }
    expect(find.text('Internal Resolution Scale'), findsNothing, reason: 'graphics is not in the menu');
    expect(find.text(T.text('quickCloseGame')), findsOneWidget);
    await expectLater(shell, matchesGoldenFile('goldens/retro_host_menu_en.png'));
  });

  /// Saves the game shown into [slots] as a player would, from its menu, with the host writing each
  /// state's file as the recorded host did; each is then dated [at], so the time shown is the same
  /// on every computer.
  Future<RetroStateFolder> saved(WidgetTester tester, List<int> slots, DateTime at) async {
    final recording = SaveStatesHostRecording.load();
    final model = launcher.model;
    final folder = RetroStateFolder(folder: p.normalize(model.paths.retroStates()), disc: launcher.disc);
    launcher.session
      ..callResults['saveState'] = recording.calls('slots', 'saveState').first.reply['result']
      ..onCall = (method, args) {
        if (method == 'saveState') {
          File(folder.statePath((args! as Map)['slot'] as int))
            ..createSync(recursive: true)
            ..writeAsBytesSync([1]);
        }
      };
    for (final slot in slots) {
      model.openRetroMenu();
      (model.panelCategories().single.rows.singleWhere((row) => row.id == 'saveState').kind as ActionRow).run();
      await tester.runAsync(() async {
        (model.panelCategories().single.rows[slot].kind as ActionRow).run();
        for (var turn = 0; turn < 50 && !File(folder.picturePath(slot)).existsSync(); turn++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        File(folder.statePath(slot)).setLastModifiedSync(at.add(Duration(minutes: slot)));
        File(folder.picturePath(slot)).setLastModifiedSync(at.add(Duration(minutes: slot, seconds: 1)));
      });
      expect(File(folder.picturePath(slot)).existsSync(), isTrue, reason: 'slot $slot kept its picture');
    }
    await tester.runAsync(() => launcher.play.states.refresh());
    model.toast = null;
    return folder;
  }

  testWidgets('the menu with save states: Save State, and Load State once one is saved', (tester) async {
    await playing(tester, status: recordedStatus(), saveStates: true);
    await saved(tester, [0], DateTime(2026, 11, 18, 14, 3));
    launcher.model.openRetroMenu();
    await settle(tester);
    expect(find.text(T.text('retroMenuSaveState')), findsOneWidget);
    expect(find.text(T.text('retroMenuLoadState')), findsOneWidget);
    expect(find.text(T.text('retroMenuLoadStatePs1Detail')), findsOneWidget);
    await expectLater(shell, matchesGoldenFile('goldens/retro_host_menu_states_en.png'));
  });

  testWidgets("Save State: the game's slots, with when each state was saved and its picture", (tester) async {
    await playing(tester, status: recordedStatus(), saveStates: true);
    await saved(tester, [0, 2], DateTime(2026, 11, 18, 14, 3));
    final model = launcher.model..openRetroMenu();
    (model.panelCategories().single.rows.singleWhere((row) => row.id == 'saveState').kind as ActionRow).run();
    model.panelRow = 2;
    // The slots' pictures are decoded once their rows are built, so a second settle draws them.
    await settle(tester);
    await settle(tester);
    expect(find.text('Slot 1'), findsOneWidget);
    expect(find.text('2026-11-18 14:03'), findsOneWidget);
    expect(find.text('2026-11-18 14:05'), findsOneWidget);
    expect(find.text(T.text('retroStateEmpty')), findsNWidgets(RetroStateFolder.slots - 2));
    await expectLater(shell, matchesGoldenFile('goldens/retro_host_save_state_en.png'));
  });

  testWidgets('Overwrite slot 1?: Cancel first, and when the state it replaces was saved', (tester) async {
    await playing(tester, status: recordedStatus(), saveStates: true);
    await saved(tester, [0], DateTime(2026, 11, 18, 14, 3));
    final model = launcher.model..openRetroMenu();
    (model.panelCategories().single.rows.singleWhere((row) => row.id == 'saveState').kind as ActionRow).run();
    (model.panelCategories().single.rows.first.kind as ActionRow).run();
    await settle(tester);
    expect(model.overlay, Layer.retroOverwriteState);
    expect(find.text('Overwrite slot 1?'), findsOneWidget);
    expect(find.text(T.format('retroStateOverwriteDetail', ['2026-11-18 14:03'])), findsOneWidget);
    await expectLater(shell, matchesGoldenFile('goldens/retro_host_overwrite_state_en.png'));
  });

  testWidgets('a section of the menu: Console, with the options that need a restart marked', (tester) async {
    await playing(tester, status: recordedStatus());
    final model = launcher.model..openRetroMenu();
    (model.panelCategories().single.rows.singleWhere((row) => row.id == 'section-console').kind as ActionRow).run();
    await settle(tester);
    expect(find.text('Console Region'), findsOneWidget);
    expect(find.text('NTSC-U BIOS'), findsOneWidget);
    expect(find.text(T.text('retroMenuOptionRestartOnlyDetail')), findsNWidgets(3), reason: 'region, BIOS, fast boot');
    await expectLater(shell, matchesGoldenFile('goldens/retro_host_menu_console_en.png'));
  });

  testWidgets('settings: Emulators with the host turned on and its BIOS folder', (tester) async {
    launcher = Ps1Launcher();
    final model = launcher.model..setRetroHostPs1(true);
    model.open(Layer.settings);
    model.selectCategory(model.panelCategories().indexWhere((category) => category.id == 'emulators'));
    await pumpLauncher(tester, model);
    expect(find.text('Run PS1 games in the separate host'), findsOneWidget);
    expect(find.text('PS1 BIOS folder'), findsOneWidget);
    await expectLater(shell, matchesGoldenFile('goldens/settings_emulators_host_en.png'));
  });

  testWidgets('settings: Emulators with LRPS2 beside the host, PS2 turned on, and its BIOS folder', (tester) async {
    launcher = Ps1Launcher(ps2: true);
    final model = launcher.model
      ..setRetroHostPs1(true)
      ..setRetroHostPs2(true);
    model.open(Layer.settings);
    model.selectCategory(model.panelCategories().indexWhere((category) => category.id == 'emulators'));
    model.panelRow = model.panelCategories()[model.panelCategory].rows.indexWhere(
      (row) => row.id == 'retro-host-ps2-bios',
    );
    await pumpLauncher(tester, model);
    expect(find.text('Run PS2 games in the separate host'), findsOneWidget);
    expect(find.text('PS2 BIOS folder'), findsOneWidget);
    await tester.ensureVisible(find.text('PS2 BIOS folder'));
    await settle(tester);
    await expectLater(shell, matchesGoldenFile('goldens/settings_emulators_host_ps2_en.png'));
  });

  testWidgets('stopped: a PS2 game whose host found no PS2 BIOS, as the real LRPS2 said', (tester) async {
    launcher = Ps1Launcher(ps2: true);
    final model = launcher.model..setRetroHostPs2(true);
    launcher.session.nextStatus = Ps2HostRecording.load().lastStatus('lrps2-no-bios-folder');
    await tester.runAsync(() async {
      final playing = model.play(launcher.ps2Game);
      launcher.session.readyCompleter.complete();
      await playing;
      await pumpEventQueue();
    });
    await pumpLauncher(tester, model);
    expect(find.byKey(const ValueKey('retro-error')), findsOneWidget);
    expect(find.text('Sky Racer stopped'), findsOneWidget);
    expect(find.text(T.text('retroHostPs2BiosDetail')), findsOneWidget);
    expect(find.text(T.text('retroHostPs2BiosFolder')), findsOneWidget);
    await expectLater(shell, matchesGoldenFile('goldens/retro_host_error_ps2_bios_en.png'));
  });

  testWidgets('settings: Emulators offering the PS1 emulator before one is installed', (tester) async {
    launcher = Ps1Launcher(hostFound: false, retroHostApi: Uri.parse('http://127.0.0.1:9/api'));
    final model = launcher.model;
    model.open(Layer.settings);
    model.selectCategory(model.panelCategories().indexWhere((category) => category.id == 'emulators'));
    await pumpLauncher(tester, model);
    expect(find.text(T.text('retroHostDownload')), findsOneWidget);
    expect(find.text('Run PS1 games in the separate host'), findsNothing);
    await expectLater(shell, matchesGoldenFile('goldens/settings_emulators_host_download_en.png'));
  });

  testWidgets('settings: Emulators with the downloaded PS1 emulator installed and turned on', (tester) async {
    launcher = (await tester.runAsync(Ps1Launcher.withRelease))!;
    final model = launcher.model..setRetroHostPs1(true);
    model.open(Layer.settings);
    model.selectCategory(model.panelCategories().indexWhere((category) => category.id == 'emulators'));
    await pumpLauncher(tester, model);
    expect(find.text(T.format('retroHostInstalled', ['1.0.0'])), findsOneWidget);
    expect(find.text('Run PS1 games in the separate host'), findsOneWidget);
    await expectLater(shell, matchesGoldenFile('goldens/settings_emulators_host_release_en.png'));
  });
}
