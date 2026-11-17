import 'dart:ffi';

import 'package:anyps5_desktop/core/retro_host/retro_host_protocol.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/launcher.dart';
import 'package:anyps5_desktop/ui/retro_host/retro_play_view.dart';
import 'package:anyps5_desktop/ui/retro_host/retro_unchecked_mark.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/ps1_launcher.dart';
import '../support/ps2_host_recording.dart';
import '../support/ui_support.dart';
import 'retro_host/fake_retro_host_session.dart';

/// A PS1 game in the emulator host as it looks: loading, stopped on an error, its menu over the
/// game, the mark of a game on an unchecked host, and Settings › Emulators with the host's rows; and
/// a PS2 game's rows and its missing BIOS.
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
  /// the host `ANYPS5_RETRO_HOST` names, as a debug or test build has it.
  Future<void> playing(WidgetTester tester, {RetroStatus? status, bool frame = true, bool unchecked = false}) async {
    launcher = unchecked ? Ps1Launcher() : (await tester.runAsync(Ps1Launcher.withRelease))!;
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
