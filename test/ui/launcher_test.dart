import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/controls.dart';
import 'package:anyps5_desktop/core/engine_checkout.dart';
import 'package:anyps5_desktop/core/file_links.dart';
import 'package:anyps5_desktop/core/gamepad/pad_navigation.dart';
import 'package:anyps5_desktop/core/font_download.dart';
import 'package:anyps5_desktop/core/game_settings.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/installer.dart';
import 'package:anyps5_desktop/core/remote/remote_server.dart';
import 'package:anyps5_desktop/core/system_fonts.dart';
import 'package:anyps5_desktop/core/toolkit_download.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/confirm_card.dart';
import 'package:anyps5_desktop/ui/launcher.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:anyps5_desktop/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_process.dart';
import '../support/fake_toolkit.dart';
import '../support/pak_writer.dart';
import '../support/ui_support.dart';

void main() {
  late Fixture fixture;

  tearDown(() {
    T.language = Language.english;
    Motion.reduced = false;
    fixture.dispose();
  });

  final shell = find.byType(LauncherShell);

  int indexOf(AppModel model, String titleId) => model.games.indexWhere((game) => game.titleId == titleId);

  group('golden', () {
    testWidgets('home, cosmic, an installed game selected, another installing', (tester) async {
      fixture = makeFixture();
      final model = fixture.model;
      model.select(indexOf(model, 'PPSA01001'));
      model.progress[model.games[indexOf(model, 'PPSA03003')].id] = (InstallStep.copy, 0.45);
      await pumpLauncher(tester, model);
      await expectLater(shell, matchesGoldenFile('goldens/home_cosmic.png'));
    });

    testWidgets('home, a game updating with the engine being built: its button and Home say so', (tester) async {
      fixture = makeFixture();
      final model = fixture.model;
      final orbit = model.games[indexOf(model, 'PPSA01001')];
      model.select(indexOf(model, 'PPSA01001'));
      model.engine.git
        ..step = GitStep.building
        ..forGame = orbit.id
        ..lines.add('[41/90] Building CXX object relinker.cpp.o');
      model.handle(Command.down);
      Motion.reduced = true;
      await pumpLauncher(tester, model);
      await expectLater(shell, matchesGoldenFile('goldens/home_engine_build.png'));
      model.engine.git
        ..step = null
        ..forGame = null;
      model.progress[orbit.id] = (InstallStep.copy, 0.4);
      model.refresh();
      await settle(tester);
      await expectLater(shell, matchesGoldenFile('goldens/home_updating.png'));
      model.progress.clear();
    });

    testWidgets('home, sunset, back from a game playing: the button says Playing', (tester) async {
      fixture = makeFixture(theme: 2);
      final model = fixture.model;
      model.select(indexOf(model, 'PPSA01001'));
      model.running = (model.games[indexOf(model, 'PPSA01001')], runningFor(FakeGameProcess()));
      model.handle(Command.down);
      await pumpLauncher(tester, model);
      await expectLater(shell, matchesGoldenFile('goldens/home_playing.png'));
      model.running = null;
    });

    testWidgets('home, aurora, in Turkish, a locked game with the play button focused', (tester) async {
      fixture = makeFixture(theme: 1, language: Language.byCode('tr'));
      final model = fixture.model;
      model.select(indexOf(model, 'PPSA02002'));
      model.handle(Command.down);
      await pumpLauncher(tester, model);
      expect(find.text('Kilidi aç'), findsOneWidget);
      await expectLater(shell, matchesGoldenFile('goldens/home_aurora_tr.png'));
    });

    testWidgets('home, cosmic, in Arabic: mirrored, as on the Mac', (tester) async {
      fixture = makeFixture(language: Language.byCode('ar'));
      final model = fixture.model;
      model.select(indexOf(model, 'PPSA02002'));
      await pumpLauncher(tester, model);
      await expectLater(shell, matchesGoldenFile('goldens/home_cosmic_ar.png'));
    });

    testWidgets('settings in Arabic: mirrored, as on the Mac', (tester) async {
      fixture = makeFixture(language: Language.byCode('ar'));
      final model = fixture.model..open(Layer.settings);
      await pumpLauncher(tester, model);
      await expectLater(shell, matchesGoldenFile('goldens/settings_ar.png'));
    });

    testWidgets('home, sunset, a game that failed and one that cannot be read', (tester) async {
      fixture = makeFixture(theme: 2);
      final model = fixture.model;
      // The relinker's reason and the file it names, both shown, wrapped.
      model.failures[model.games[indexOf(model, 'PPSA02002')].id] =
          'relinker.exe failed (2): FAIL: Code analysis: branch into skipped range tail, a jump from 0x14d3ff1c4 '
          'lands inside an instruction the scan stepped over (offset 0x4a10)\nInput: eboot.bin';
      model.select(indexOf(model, 'PPSA02002'));
      await pumpLauncher(tester, model);
      await expectLater(shell, matchesGoldenFile('goldens/home_sunset_failed.png'));
    });

    testWidgets('library grid', (tester) async {
      fixture = makeFixture();
      final model = fixture.model;
      model.open(Layer.library);
      model.handle(Command.right);
      await pumpLauncher(tester, model);
      await expectLater(shell, matchesGoldenFile('goldens/library.png'));
    });

    testWidgets('settings, appearance', (tester) async {
      fixture = makeFixture(theme: 2);
      final model = fixture.model;
      model.open(Layer.settings);
      await pumpLauncher(tester, model);
      await expectLater(shell, matchesGoldenFile('goldens/settings.png'));
    });

    testWidgets('game settings', (tester) async {
      fixture = makeFixture();
      final model = fixture.model;
      model.select(indexOf(model, 'PPSA01001'));
      model.open(Layer.gameSettings);
      model.handle(Command.down);
      await pumpLauncher(tester, model);
      await expectLater(shell, matchesGoldenFile('goldens/game_settings.png'));
    });

    testWidgets('game settings, advanced: custom relinker options not saved, launch options', (tester) async {
      fixture = makeFixture();
      final model = fixture.model;
      final orbit = model.games[indexOf(model, 'PPSA01001')];
      model.select(indexOf(model, 'PPSA01001'));
      model.saveSettings(orbit, const GameSettings(launchOptions: 'APS5_REPORT=0 --aps5-report=off'));
      model.open(Layer.gameSettings);
      model.open(Layer.advanced);
      final rows = model.panelCategories().single.rows;
      (rows.firstWhere((row) => row.id == 'relinkerCustomOptions').kind as TextRow).set('--lazy-binding --windows');
      model.panelRow = rows.indexWhere((row) => row.id == 'launchOptions');
      await pumpLauncher(tester, model);
      // The rebuild options at the top, the Launch section under them.
      await tester.ensureVisible(find.byKey(const ValueKey('row-relinker---trace-imports')));
      await tester.pump(const Duration(seconds: 1));
      await expectLater(shell, matchesGoldenFile('goldens/advanced_options_en.png'));
    });

    testWidgets('controls, waiting for a key', (tester) async {
      fixture = makeFixture(theme: 1);
      final model = fixture.model;
      model.open(Layer.controls);
      // Past gyro aiming to the second pad action.
      model.handle(Command.down);
      model.handle(Command.down);
      model.handle(Command.select);
      await pumpLauncher(tester, model);
      await expectLater(shell, matchesGoldenFile('goldens/controls.png'));
    });

    testWidgets("controls, an Unreal game's own actions under each button", (tester) async {
      fixture = makeFixture(theme: 1);
      final model = fixture.model;
      final game = model.selectedGame!;
      final paks = Directory(p.join(game.folder, 'Orbit', 'Content', 'Paks'))..createSync(recursive: true);
      PakWriter(
        files: [
          (
            path: 'Orbit/Config/DefaultInput.ini',
            data: utf8.encode(
              '[/Script/Engine.InputSettings]\n'
              '+ActionMappings=(ActionName="Jump",Key=Gamepad_FaceButton_Bottom)\n'
              '+ActionMappings=(ActionName="Interact_Primary",Key=Gamepad_FaceButton_Left)\n'
              '+ActionMappings=(ActionName="IA_Crouch",Key=Gamepad_FaceButton_Right)\n'
              '+ActionMappings=(ActionName="Dodge",Key=Gamepad_FaceButton_Right)\n'
              '+ActionMappings=(ActionName="OpenMap",Key=Gamepad_FaceButton_Top)\n'
              '+ActionMappings=(ActionName="ToggleHUD",Key=Gamepad_LeftShoulder)\n',
            ),
            zlib: true,
          ),
        ],
      ).write(p.join(paks.path, 'pakchunk0-ps5.pak'));
      model.open(Layer.controls);
      expect(model.gameControls[game.id]?[PadAction.cross], ['Jump']);
      await pumpLauncher(tester, model);
      expect(find.text(T.text('controlsFromGame')), findsOneWidget);
      expect(find.text('Crouch, Dodge'), findsOneWidget);
      expect(find.text('Toggle HUD'), findsOneWidget);
      await expectLater(shell, matchesGoldenFile('goldens/controls_unreal.png'));
      // Read once: the panel opened again asks the files nothing more.
      PakWriter(files: const []).write(p.join(paks.path, 'pakchunk0-ps5.pak'));
      model.open(Layer.gameSettings);
      model.open(Layer.controls);
      expect(model.gameControls[game.id]?[PadAction.cross], ['Jump']);
    });

    testWidgets('onboarding: language, theme and toolkit steps', (tester) async {
      fixture = makeFixture(onboarded: false, withToolkit: false);
      final model = fixture.model;
      await pumpLauncher(tester, model);
      await expectLater(shell, matchesGoldenFile('goldens/onboarding_language.png'));
      await press(tester, LogicalKeyboardKey.enter);
      await expectLater(shell, matchesGoldenFile('goldens/onboarding_theme.png'));
      model.onboardingStep = 3;
      model.engine.latest = sampleRelease('0.1.3');
      model.refresh();
      await settle(tester);
      await expectLater(shell, matchesGoldenFile('goldens/onboarding_toolkit.png'));
    });

    testWidgets('onboarding: the engine downloading, in Turkish', (tester) async {
      fixture = makeFixture(onboarded: false, withToolkit: false, theme: 1, language: Language.byCode('tr'));
      final model = fixture.model;
      model.onboardingStep = 3;
      final release = sampleRelease('0.1.3');
      final package = release.packageFor(model.system)!;
      model.engine
        ..latest = release
        ..downloading = package
        ..progress = ToolkitProgress(ToolkitPhase.download, (package.size * 0.42).round(), package.size);
      await pumpLauncher(tester, model);
      expect(find.text('AnyPS5 motorunu indir'), findsOneWidget);
      expect(find.text('Kendi klasörüm var'), findsOneWidget);
      expect(find.textContaining('/ 106'), findsOneWidget);
      await expectLater(shell, matchesGoldenFile('goldens/onboarding_engine_download_tr.png'));
      model.engine
        ..downloading = null
        ..progress = null;
    });

    testWidgets('settings: the AnyPS5 engine', (tester) async {
      fixture = makeFixture(withToolkit: false);
      final model = fixture.model;
      // Two downloaded engines, the newer one in use.
      for (final version in ['0.1.2', '0.1.3']) {
        makeFakeToolkit(p.join(model.paths.toolkits, version), version: 'upstream-v$version');
      }
      model.engine.refresh();
      model.engine
        ..latest = sampleRelease('0.1.3')
        ..releases = [sampleRelease('0.1.4-rc1', prerelease: true), sampleRelease('0.1.3'), sampleRelease('0.1.2')];
      model.open(Layer.settings);
      await pumpLauncher(tester, model);
      for (var tab = 0; tab < 2; tab++) {
        await press(tester, LogicalKeyboardKey.keyE);
      }
      expect(model.panelCategories()[model.panelCategory].id, 'engine');
      expect(find.text('Check for engine updates'), findsOneWidget);
      expect(find.text('v0.1.4-rc1 · Pre-release'), findsOneWidget);
      expect(find.text('Downloaded · select to use'), findsOneWidget);
      expect(find.text('Delete other versions'), findsOneWidget);
      await expectLater(shell, matchesGoldenFile('goldens/settings_engine.png'));
    });

    testWidgets('settings: fonts', (tester) async {
      fixture = makeFixture(builtInFonts: p.absolute(SystemFonts.assetFolder), cjkFonts: FontArchive.notoSansCjk);
      final model = fixture.model;
      model.open(Layer.settings);
      model.selectCategory(model.panelCategories().indexWhere((category) => category.id == 'fonts'));
      await pumpLauncher(tester, model);
      expect(find.text('Noto Sans · Built in'), findsNWidgets(2), reason: 'Latin and Latin Italic');
      expect(find.text('Download Japanese, Chinese and Korean now'), findsOneWidget);
      await expectLater(shell, matchesGoldenFile('goldens/settings_fonts.png'));
    });

    testWidgets('trophies', (tester) async {
      fixture = makeFixture(theme: 1);
      final model = fixture.model;
      model.select(indexOf(model, 'PPSA01001'));
      model.open(Layer.trophies);
      model.handle(Command.down);
      await pumpLauncher(tester, model);
      await expectLater(shell, matchesGoldenFile('goldens/trophies.png'));
    });

    testWidgets('a new game copied in: its toast with the icon', (tester) async {
      fixture = makeFixture();
      final model = fixture.model;
      final orbit = model.games[indexOf(model, 'PPSA01001')];
      model.select(indexOf(model, 'PPSA01001'));
      model.show(T.format('newGame', [orbit.name]), icon: orbit.icon);
      await pumpLauncher(tester, model);
      await expectLater(shell, matchesGoldenFile('goldens/new_game_toast.png'));
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('a phone asking to pair', (tester) async {
      fixture = makeFixture();
      final model = fixture.model;
      model.pairing = const PairingRequest(id: 'r', deviceName: "Utku's iPhone", code: '4071');
      await pumpLauncher(tester, model);
      await expectLater(shell, matchesGoldenFile('goldens/pairing.png'));
    });

    testWidgets('a phone with upstream\'s engine in use: the switch to AnyPS5-ARM\'s, in Turkish', (tester) async {
      fixture = makeFixture(language: Language.byCode('tr'));
      final model = fixture.model;
      model.preferences.toolkitFolder = makeFakeToolkit(
        p.join(fixture.temp.path, 'upstream'),
        version: 'upstream-v0.1.4',
      );
      model.askPhoneEngine();
      expect(model.overlay, Layer.phoneEngine);
      await pumpLauncher(tester, model);
      expect(find.text('AnyPS5-ARM motoruna geç'), findsOneWidget);
      await expectLater(shell, matchesGoldenFile('goldens/phone_engine_tr.png'));
    });
  });

  group('a failed unlock', () {
    const failure =
        'relinker.exe failed (2): FAIL: Code analysis: branch into skipped range tail (offset 0x4a10)\n'
        'Input: sce_module/libSceNpCppWebApi.prx';

    testWidgets('home shows the reason and the file; Copy error copies all the relinker printed', (tester) async {
      fixture = makeFixture();
      final model = fixture.model;
      final game = model.games[indexOf(model, 'PPSA02002')];
      model.failures[game.id] = failure;
      File(p.join(model.paths.logs, '${game.titleId}-unlock.log'))
        ..createSync(recursive: true)
        ..writeAsStringSync('PRX conversion | libSceNpCppWebApi.prx | 100% (1/2)\n$failure\n');
      model.select(indexOf(model, 'PPSA02002'));
      await pumpLauncher(tester, model);
      expect(find.textContaining('branch into skipped range tail'), findsOneWidget);
      expect(find.textContaining('libSceNpCppWebApi.prx'), findsOneWidget);
      await tester.tap(find.text('Copy error'));
      await tester.pump();
      expect(fixture.copied.single, startsWith(failure));
      expect(fixture.copied.single, contains('PRX conversion | libSceNpCppWebApi.prx | 100% (1/2)'));
      expect(model.toast, 'Error copied');
      await tester.pump(const Duration(seconds: 5));
    });

    test('the game\'s settings have the error first, to copy with the controller', () {
      fixture = makeFixture();
      final model = fixture.model;
      final game = model.games[indexOf(model, 'PPSA02002')];
      model.failures[game.id] = failure;
      model.select(indexOf(model, 'PPSA02002'));
      model.open(Layer.gameSettings);
      final row = model.panelCategories().first.rows.first;
      expect(row.id, 'unlockError');
      expect(row.detail, contains('libSceNpCppWebApi.prx'));
      expect(row.detail, endsWith('Select to copy the whole error.'));
      model.handle(Command.select);
      expect(fixture.copied.single, startsWith(failure));
    });

    test('a game ready without some of its modules says so in one short sentence, without the files', () {
      fixture = makeFixture();
      final game = fixture.model.games.first;
      expect(
        AppModel.leftOutText(game, const [
          LeftOutModule('sce_module/libSceNpCppWebApi.prx', LeftOutReason.notRelinked, 'bad'),
          LeftOutModule('sce_module/libSceNpWebApi.prx', LeftOutReason.notRelinked, 'bad'),
        ]),
        '${game.name} is ready. A few of its files could not be converted and were left out.',
      );
      expect(
        AppModel.leftOutText(game, const [
          LeftOutModule('sce_module/libSceNpCppWebApi.prx', LeftOutReason.notRelinked),
          LeftOutModule('sce_module/libSceFace.prx', LeftOutReason.encrypted),
        ]),
        '${game.name} is ready, but some of its files are encrypted in the dump. If it does not start, dump it again.',
      );
      // Gran Turismo 7's pdiWheel_0.prx, neither an ELF nor a SELF: the same short note, no file named.
      final note = AppModel.leftOutText(game, const [
        LeftOutModule('sce_module/pdiWheel_0.prx', LeftOutReason.encrypted),
      ]);
      expect(
        note,
        '${game.name} is ready, but some of its files are encrypted in the dump. If it does not start, dump it again.',
      );
      expect(note, isNot(contains('pdiWheel')));
    });
  });

  group('keyboard', () {
    testWidgets('an unlock that would copy asks first; Enter and the arrows answer it', (tester) async {
      FileLinks.calls = LinkCalls(hardLink: (_, _) => false, symbolicLink: (_, _) => false);
      addTearDown(() => FileLinks.calls = FileLinks.system);
      fixture = makeFixture(system: HostSystem.windows);
      final model = fixture.model;
      model.select(indexOf(model, 'PPSA02002'));
      model.sizes[model.selectedGame!.id] = 52000000000;
      await pumpLauncher(tester, model);
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.enter);
      expect(model.overlay, Layer.copyWarning);
      expect(find.text(T.text('copyWarningTitle')), findsOneWidget);
      expect(find.textContaining('52.0 GB'), findsWidgets);
      expect(find.text(T.text('copyFixFolder')), findsOneWidget);
      expect(find.text(T.text('copyFixDeveloperMode')), findsOneWidget);
      expect(find.text(T.text('copyAnyway')), findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'nothing overflows');
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.enter);
      expect(fixture.opened, [Uri.parse('ms-settings:developers')]);
      expect(model.overlay, isNull);
      expect(find.text(T.text('copyFixDeveloperModeThen')), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('arrows move the tiles and the focus, Escape comes back', (tester) async {
      fixture = makeFixture();
      final model = fixture.model;
      await pumpLauncher(tester, model);
      expect(model.selected, 0);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(model.selected, 1);
      await press(tester, LogicalKeyboardKey.keyE);
      expect(model.selected, 2);
      await press(tester, LogicalKeyboardKey.keyQ);
      expect(model.selected, 1);
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(model.focus, const HomeFocus.actions(0));
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(model.focus, const HomeFocus.actions(1), reason: 'Orbit Runner has trophies');
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(model.focus, const HomeFocus.actions(2));
      await press(tester, LogicalKeyboardKey.enter);
      expect(model.overlay, Layer.gameSettings);
      await press(tester, LogicalKeyboardKey.escape);
      expect(model.overlay, isNull);
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(model.focus, HomeFocus.tiles);
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(model.focus, const HomeFocus.top(1));
      await press(tester, LogicalKeyboardKey.enter);
      expect(model.overlay, Layer.settings);
    });

    testWidgets('Escape on the home screen asks "Quit AnyPS5?", Cancel first; elsewhere it keeps its meaning', (
      tester,
    ) async {
      final quits = <int>[];
      fixture = makeFixture(quit: quits.add);
      final model = fixture.model;
      await pumpLauncher(tester, model);
      await press(tester, LogicalKeyboardKey.escape);
      expect(model.overlay, Layer.confirmQuit);
      expect(model.panelCategories().single.rows.map((row) => row.id), ['cancel', 'quit']);
      expect(model.panelRow, 0, reason: 'Cancel is where the focus starts: a second Enter does not quit');
      expect(find.text(T.text('quitQuestion')), findsOneWidget);
      await press(tester, LogicalKeyboardKey.enter);
      expect(model.overlay, isNull);
      await press(tester, LogicalKeyboardKey.escape);
      await press(tester, LogicalKeyboardKey.escape);
      expect(model.overlay, isNull, reason: 'Escape on the question is Cancel');
      model.handle(Command.back);
      expect(model.overlay, isNull, reason: 'Circle on the home screen asks nothing');
      expect(quits, isEmpty);

      await press(tester, LogicalKeyboardKey.arrowUp);
      await press(tester, LogicalKeyboardKey.escape);
      expect(model.focus, HomeFocus.tiles, reason: 'from the top bar Escape still comes back to the games');
      expect(model.overlay, isNull);
      model.open(Layer.settings);
      await press(tester, LogicalKeyboardKey.escape);
      expect(model.overlay, isNull, reason: 'a panel open: Escape closes it, as before');

      await press(tester, LogicalKeyboardKey.escape);
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.enter);
      expect(quits, [0]);
    });

    testWidgets('"Quit AnyPS5?" is a small yes or no: Cancel and Quit side by side, ← and → between them', (
      tester,
    ) async {
      final quits = <int>[];
      fixture = makeFixture(quit: quits.add);
      final model = fixture.model;
      await pumpLauncher(tester, model);
      await press(tester, LogicalKeyboardKey.escape);
      expect(model.overlay, Layer.confirmQuit);
      expect(find.byType(ConfirmCard), findsOneWidget);
      expect(find.text('Stay on the home screen'), findsNothing, reason: 'no line under Cancel');
      final cancel = tester.getCenter(find.byKey(const ValueKey('answer-cancel')));
      final quit = tester.getCenter(find.byKey(const ValueKey('answer-quit')));
      expect(cancel.dy, quit.dy, reason: 'on one line');
      expect(cancel.dx, lessThan(quit.dx), reason: 'Cancel on the left, Quit on the right');
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(model.panelRow, 1);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(model.panelRow, 1, reason: 'the arrows stop at the last answer');
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(model.panelRow, 0);
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.escape);
      expect(model.overlay, isNull, reason: 'Escape cancels, even on Quit');
      expect(quits, isEmpty);
      // The pad's ← and → too, and Cross on Quit quits.
      await press(tester, LogicalKeyboardKey.escape);
      model.padCommand(PadCommand.right);
      expect(model.panelRow, 1);
      model.padCommand(PadCommand.left);
      expect(model.panelRow, 0);
      await tester.tap(find.byKey(const ValueKey('answer-quit')));
      await tester.pump();
      expect(quits, [0], reason: 'a click on Quit quits');
    });

    testWidgets('with no games, Up still reaches the top bar and its Settings', (tester) async {
      fixture = makeFixture();
      final model = fixture.model;
      await pumpLauncher(tester, model);
      model.games = [];
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(model.focus, const HomeFocus.top(1));
      await press(tester, LogicalKeyboardKey.enter);
      expect(model.overlay, Layer.settings);
      await press(tester, LogicalKeyboardKey.escape);
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(model.focus, HomeFocus.tiles);
    });

    testWidgets('settings: Q and E change the category, arrows change a value', (tester) async {
      fixture = makeFixture();
      final model = fixture.model;
      model.open(Layer.settings);
      await pumpLauncher(tester, model);
      expect(model.preferences.theme, 0);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(model.preferences.theme, 1, reason: 'the first row is the theme');
      expect(model.look, LookStyle.aurora);
      await press(tester, LogicalKeyboardKey.keyE);
      expect(model.panelCategory, 1);
      // Library, the AnyPS5 engine, Profiles, AnyTogether and the phones, then the language (the
      // fonts are near the end now).
      await press(tester, LogicalKeyboardKey.keyE);
      await press(tester, LogicalKeyboardKey.keyE);
      await press(tester, LogicalKeyboardKey.keyE);
      await press(tester, LogicalKeyboardKey.keyE);
      await press(tester, LogicalKeyboardKey.keyE);
      expect(model.panelCategories()[model.panelCategory].id, 'general');
      // The next language after English, by its own name.
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(T.language, T.languages[1]);
      expect(T.text('language'), isNot('Language'));
      expect(find.text(T.text('language')), findsWidgets);
    });

    testWidgets('game settings change and are kept per game', (tester) async {
      fixture = makeFixture();
      final model = fixture.model;
      final game = model.selectedGame!;
      await pumpLauncher(tester, model);
      await press(tester, LogicalKeyboardKey.keyO);
      expect(model.overlay, Layer.gameSettings);
      // Default, Window, Full screen.
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(model.currentSettings(game).fullscreen, isTrue);
      final environment = model.currentSettings(game).environment(launcherLanguage: 1);
      expect(environment['ANYPS5_FULLSCREEN'], '1');
      // Window size is hidden in fullscreen; Upscaling comes next, then vertical sync.
      await press(tester, LogicalKeyboardKey.arrowDown);
      // Bilinear, FSR 1.
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(model.currentSettings(game).upscaler, Upscaler.fsr1);
      expect(model.currentSettings(game).environment(launcherLanguage: 1)['ANYPS5_UPSCALER'], 'fsr1');
      // FSR sharpness shows with FSR 1: 0.2, one tenth up.
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(model.currentSettings(game).environment(launcherLanguage: 1)['ANYPS5_FSR_SHARPNESS'], '0.3');
      await press(tester, LogicalKeyboardKey.arrowDown);
      // Default, On, Off.
      await press(tester, LogicalKeyboardKey.enter);
      await press(tester, LogicalKeyboardKey.enter);
      expect(model.currentSettings(game).vsync, isFalse);
    });

    testWidgets('controls of a game whose files name no actions show no line about them', (tester) async {
      fixture = makeFixture();
      final model = fixture.model;
      model.open(Layer.controls);
      await pumpLauncher(tester, model);
      expect(find.text(T.text('controlsFromGame')), findsNothing);
      expect(model.gameControls[model.selectedGame!.id], isEmpty);
    });

    testWidgets('a pad action takes the next key pressed', (tester) async {
      fixture = makeFixture();
      final model = fixture.model;
      final game = model.selectedGame!;
      model.open(Layer.controls);
      await pumpLauncher(tester, model);
      // Gyro aiming comes first, then the pad's actions.
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.enter);
      expect(model.capturing, PadAction.cross);
      expect(find.text(T.text('pressKey')), findsOneWidget);
      await press(tester, LogicalKeyboardKey.keyZ);
      expect(model.capturing, isNull);
      expect(Controls.sources(PadAction.cross, model.currentSettings(game).controls!), ['KEY:Z']);
      expect(find.text('Z'), findsOneWidget);
    });

    testWidgets('a row moved to below the panel scrolls into view', (tester) async {
      fixture = makeFixture();
      final model = fixture.model;
      model.open(Layer.controls);
      await pumpLauncher(tester, model);
      // Gyro aiming's row comes first, then the pad's actions.
      for (var row = 0; row < 23; row++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump(const Duration(milliseconds: 50));
      }
      await settle(tester);
      expect(model.panelRow, 23);
      final title = AppModel.padActionTitle(PadAction.values[22]);
      final rect = tester.getRect(find.text(title));
      expect(rect.top, greaterThan(0));
      expect(rect.bottom, lessThan(900));
      expect(
        tester.getRect(find.text(AppModel.padActionTitle(PadAction.cross))).bottom,
        lessThan(200),
        reason: 'the first rows scrolled away',
      );
    });

    testWidgets('the library picks a game', (tester) async {
      fixture = makeFixture();
      final model = fixture.model;
      await pumpLauncher(tester, model);
      await press(tester, LogicalKeyboardKey.arrowUp);
      await press(tester, LogicalKeyboardKey.arrowLeft);
      await press(tester, LogicalKeyboardKey.enter);
      expect(model.overlay, Layer.library);
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.enter);
      expect(model.overlay, isNull);
      expect(model.selected, 2);
    });

    testWidgets('onboarding: language, theme, folder, toolkit, then the home screen', (tester) async {
      fixture = makeFixture(onboarded: false, withToolkit: false);
      final model = fixture.model;
      model.preferences.gamesFolders = [];
      model.games = [];
      await pumpLauncher(tester, model);
      expect(find.text('Welcome to AnyPS5'), findsOneWidget);
      // Down is the next row of languages, right the next card: Türkçe is on the second row.
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(T.language, T.languages[AppModel.languageColumns]);
      final turkish = T.languages.indexOf(Language.byCode('tr'));
      expect(turkish ~/ AppModel.languageColumns, 1);
      for (var card = AppModel.languageColumns; card < turkish; card++) {
        await press(tester, LogicalKeyboardKey.arrowRight);
      }
      expect(T.language, Language.byCode('tr'));
      expect(find.text("AnyPS5'e hoş geldin"), findsOneWidget);
      await press(tester, LogicalKeyboardKey.enter);
      expect(model.onboardingStep, 1);
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(model.preferences.theme, 2);
      await press(tester, LogicalKeyboardKey.enter);
      expect(model.onboardingStep, 2);
      await press(tester, LogicalKeyboardKey.enter);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await settle(tester);
      expect(model.preferences.gamesFolders, isNotEmpty, reason: 'the picker answered');
      expect(model.games, hasLength(4));
      expect(model.onboardingChoice, 1);
      await press(tester, LogicalKeyboardKey.enter);
      expect(model.onboardingStep, 3);
      expect(model.onboardingChoice, 0, reason: 'the download is the first choice');
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.enter);
      expect(model.onboardingStep, 4, reason: 'offline or online last');
      expect(find.text('Çevrimdışı oyna'), findsOneWidget);
      await press(tester, LogicalKeyboardKey.enter);
      expect(model.preferences.onboarded, isTrue);
      expect(model.profiles.book.profiles.single.mode.name, 'offline');
      expect(find.text('Oyunlar'), findsOneWidget);
    });

    testWidgets('a locked game without a toolkit says so; with one it is queued', (tester) async {
      fixture = makeFixture(withToolkit: false);
      final model = fixture.model;
      model.select(indexOf(model, 'PPSA02002'));
      await pumpLauncher(tester, model);
      await press(tester, LogicalKeyboardKey.enter);
      expect(model.toast, T.text('noToolkit'));
      expect(find.text(T.text('noToolkit')), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      expect(model.toast, isNull);
    });

    testWidgets('the trophy button opens the trophies; L1 and R1 leave them on a game without', (tester) async {
      fixture = makeFixture();
      final model = fixture.model;
      model.select(indexOf(model, 'PPSA01001'));
      await pumpLauncher(tester, model);
      expect(find.text('2/5'), findsOneWidget);
      expect(model.actionCount, 3);
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.enter);
      expect(model.overlay, Layer.trophies);
      expect(find.text('Liftoff'), findsOneWidget);
      expect(find.text(T.text('trophyHidden')), findsOneWidget);
      await press(tester, LogicalKeyboardKey.keyE);
      expect(model.overlay, isNull, reason: 'the next game has no trophies');
      expect(model.focus, const HomeFocus.actions(1), reason: 'the settings button of a game without trophies');
    });

    testWidgets('the pairing card answers with Enter', (tester) async {
      fixture = makeFixture();
      final model = fixture.model;
      model.pairing = const PairingRequest(id: 'r', deviceName: 'Phone', code: '1234');
      await pumpLauncher(tester, model);
      expect(find.text('1'), findsOneWidget);
      await press(tester, LogicalKeyboardKey.enter);
      expect(model.pairing, isNull);
    });
  });

  test('the fixture writes nothing outside its folder', () {
    fixture = makeFixture();
    expect(fixture.model.persist, isFalse);
    expect(fixture.model.paths.config, startsWith(fixture.temp.path));
    expect(Directory(fixture.model.paths.config).existsSync(), isFalse);
  });
}
