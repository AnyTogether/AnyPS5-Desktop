import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/gamepad/pad_navigation.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/components.dart';
import 'package:anyps5_desktop/ui/console_badge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/ui_support.dart';
import 'desktop_features_test.dart' show FakePads;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('anyps5/retro_core');

  test('PS3 graphics preferences keep separate choices for each title', () {
    final temp = Directory.systemTemp.createTempSync('anyps5-ps3-preferences-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final path = p.join(temp.path, 'preferences.json');
    final choices = {
      'PS3-BCUS98208': {'rpcs3_resolution_scale': '150', 'rpcs3_msaa': 'auto'},
      'PS3-BLES00123': {'rpcs3_resolution_scale': '100'},
    };
    (Preferences()..retroPs3Graphics = choices).save(path);
    expect(Preferences.load(path).retroPs3Graphics, choices);
  });

  testWidgets('PS4 and PS5 title IDs select accessible console badges', (tester) async {
    for (final (titleId, expected) in [('CUSA12345', PlayStationConsole.ps4), ('PPSA12345', PlayStationConsole.ps5)]) {
      final game = Game(
        folder: 'test',
        titleId: titleId,
        name: 'Console badge test',
        names: const {},
        defaultLanguage: 'en-US',
        version: '',
        executable: ExecutableKind.disc,
      );
      expect(PlayStationConsole.forGame(game), expected);
      await tester.pumpWidget(
        MaterialApp(
          home: Center(child: ConsoleBadge(console: expected)),
        ),
      );
      final badge = tester.widget<Text>(find.text(expected.name.toUpperCase()));
      expect(badge.semanticsLabel, expected.label);
    }
  });

  testWidgets('embedded boot keeps one progress bar and the same cover through compilation', (tester) async {
    final env = <String, String>{};
    final fixture = makeFixture(environment: env);
    final model = fixture.model;
    addTearDown(() {
      model.dispose();
      fixture.dispose();
    });
    final folder = fixture.temp.path;
    env['ANYPS5_LIBRETRO_HOME'] = folder;
    File(p.join(folder, 'swanstation_libretro.dll')).createSync();
    final disc = File(p.join(folder, 'boot.cue'))..createSync();
    final icon = File(p.join(folder, 'cover.png'))..writeAsBytesSync(iconArt(0x102030, 0x304050));
    final game = Game(
      folder: folder,
      titleId: 'BOOT12345',
      name: 'Embedded boot game',
      names: const {'en-US': 'Embedded boot game'},
      defaultLanguage: 'en-US',
      version: '',
      executable: ExecutableKind.disc,
      retro: (platform: RetroPlatform.ps1, path: disc.path),
      icon: icon.path,
    );
    var status = <String, Object?>{};
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => switch (call.method) {
        'start' => 42,
        'status' => status,
        _ => null,
      },
    );
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await pumpLauncher(tester, model);
    final play = model.play(game);
    await tester.pump();
    final bar = find.byType(LinearProgressIndicator);
    final cover = find.byWidgetPredicate((widget) => widget is ArtworkImage && widget.path == icon.path);
    expect(bar, findsOneWidget);
    expect(cover, findsOneWidget);
    expect(tester.widget<LinearProgressIndicator>(bar).value, isNull);
    final coverRect = tester.getRect(cover);
    final barRect = tester.getRect(bar);

    status = {'presented': true, 'progressLabel': 'Compiling PPU modules', 'progressPercent': 43};
    await tester.pump(const Duration(milliseconds: 150));
    expect(model.starting, isNull);
    expect(bar, findsOneWidget);
    expect(tester.widget<LinearProgressIndicator>(bar).value, 0.43);
    expect(find.text('43%'), findsOneWidget);
    expect(tester.getRect(cover), coverRect);
    expect(tester.getRect(bar), barRect);

    status = {'presented': true, 'progressLabel': 'Loading shader cache', 'progressPercent': 72};
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('72%'), findsOneWidget);
    expect(tester.getRect(cover), coverRect);

    status = {'presented': true};
    await tester.pump(const Duration(milliseconds: 150));
    expect(cover, findsNothing);
    expect(bar, findsNothing);
    expect(find.byType(Texture), findsOneWidget);

    status = {'ended': true};
    await tester.pump(const Duration(milliseconds: 150));
    await play;
  });

  for (final platform in RetroPlatform.ps1AndPs2) {
    testWidgets('embedded ${platform.name} Graphics resumes one texture and remembers resolution per title', (
      tester,
    ) async {
      final env = <String, String>{};
      final pads = FakePads();
      final fixture = makeFixture(environment: env, pads: () => pads);
      final model = fixture.model;
      model.startPads();
      addTearDown(() {
        model.dispose();
        fixture.dispose();
      });
      env['ANYPS5_LIBRETRO_HOME'] = fixture.temp.path;
      final core = platform == RetroPlatform.ps1 ? 'swanstation_libretro.dll' : 'pcsx2_libretro.dll';
      File(p.join(fixture.temp.path, core)).createSync();
      final folder = Directory(p.join(model.root!, 'Embedded'))..createSync();
      final disc = platform == RetroPlatform.ps1 ? 'game.cue' : 'game.iso';
      File(p.join(folder.path, disc)).createSync();
      File(p.join(folder.path, 'retro.json')).writeAsStringSync(
        jsonEncode({'platform': platform.name, 'titleId': 'TEST12345', 'name': 'Embedded game', 'disc': disc}),
      );
      final otherFolder = Directory(p.join(model.root!, 'Other'))..createSync();
      File(p.join(otherFolder.path, disc)).createSync();
      File(p.join(otherFolder.path, 'retro.json')).writeAsStringSync(
        jsonEncode({'platform': platform.name, 'titleId': 'TEST67890', 'name': 'Other game', 'disc': disc}),
      );
      final calls = <MethodCall>[];
      var ended = false;
      var saveError = '';
      int? progress;
      final isPs1 = platform == RetroPlatform.ps1;
      final resolution = isPs1 ? 'swanstation_GPU_ResolutionScale' : 'pcsx2_upscale_multiplier';
      final scales = isPs1 ? ['1', '2', '3', '4'] : ['1x (Native)', '2x', '4x'];
      var selected = 0;
      var graphicsPending = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        switch (call.method) {
          case 'start':
            expect(call.arguments['core'], p.join(fixture.temp.path, core));
            ended = false;
            final saved = call.arguments['internalResolution'] as String?;
            selected = saved == null ? 0 : scales.indexOf(saved);
            return 123;
          case 'status':
            return {
              'presented': true,
              'ended': ended,
              'aspect': 4 / 3,
              'error': ended ? saveError : '',
              if (progress != null) 'progressLabel': 'Compiling modules',
              'progressPercent': ?progress,
              'graphicsPending': graphicsPending,
              'options': {
                resolution: {
                  'values': scales,
                  'selected': selected,
                  'activeValue': scales[graphicsPending ? 0 : selected],
                },
              },
            };
          case 'option':
            expect(call.arguments['key'], resolution);
            if (call.arguments['value'] != scales[1]) return false;
            graphicsPending = true;
            selected = 1;
            return true;
          case 'stop':
            ended = true;
        }
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      });
      model.rescan();
      final title = model.games.singleWhere((game) => game.name == 'Embedded game');
      final other = model.games.singleWhere((game) => game.name == 'Other game');
      final play = model.play(title);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(model.embeddedGame?.textureId, 123);
      expect(model.starting, isNull);

      progress = 43;
      model.setActive(false);
      await tester.pump();
      expect(calls.where((call) => call.method == 'pause'), isEmpty);
      expect(calls.lastWhere((call) => call.method == 'input').arguments, [0, 0, 0, 0, 0]);
      await tester.pump(const Duration(milliseconds: 150));
      expect(model.embeddedGame?.progress, (label: 'Compiling modules', percent: 43));
      progress = null;
      pads.press(PadButton.guide);
      await tester.pump(const Duration(milliseconds: 150));
      expect(model.embeddedGame?.progress, isNull);
      expect(model.overlay, Layer.quickMenu);
      expect(calls.where((call) => call.method == 'pause').last.arguments, true);
      model.setActive(true);
      final graphics = model.panelCategories().single.rows.singleWhere((row) => row.id == 'retroGraphics');
      (graphics.kind as ActionRow).run();
      final filter = model.panelCategories().single.rows.first.kind as ChoiceRow;
      filter.set(1);
      expect(model.embeddedGame?.filter, 1);
      final internalResolution = model.panelCategories().single.rows.singleWhere((row) => row.id == resolution);
      expect(internalResolution.title, 'Internal resolution');
      final choice = internalResolution.kind as ChoiceRow;
      expect(choice.options[1], '2x');
      choice.set(1);
      await tester.pump();
      expect(model.preferences.retroInternalResolution, isEmpty);
      graphicsPending = false;
      await tester.pump(const Duration(milliseconds: 150));
      expect(model.embeddedGame?.options[resolution]?.selected, 1);
      choice.set(scales.length - 1);
      await tester.pump();
      expect(model.preferences.retroInternalResolution, {title.id: scales[1]});
      model.closeOverlay();
      await tester.pump();
      expect(model.overlay, isNull);
      expect(calls.where((call) => call.method == 'pause').last.arguments, false);

      await model.openQuickMenu();
      model.resumeGame();
      await tester.pump();
      expect(model.embeddedGame?.textureId, 123);
      expect(calls.where((call) => call.method == 'start'), hasLength(1));

      if (platform == RetroPlatform.ps1) {
        model.closeRunningGame();
        await tester.pump(const Duration(milliseconds: 150));
      } else {
        saveError = 'Could not write the memory card';
        final quit = model.prepareToQuit();
        await tester.pump(const Duration(milliseconds: 150));
        expect(await quit, isFalse);
        expect(model.toast, saveError);
      }
      await play;
      expect(model.running, isNull);
      expect(calls.map((call) => call.method), containsAllInOrder(['stop', 'release']));

      final preferencesFile = p.join(fixture.temp.path, 'preferences.json');
      model.preferences.save(preferencesFile);
      model.preferences.retroInternalResolution = Preferences.load(preferencesFile).retroInternalResolution;
      saveError = '';
      for (final (game, expected) in [(other, null), (title, scales[1])]) {
        final relaunch = model.play(game);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));
        final start = calls.lastWhere((call) => call.method == 'start');
        expect(start.arguments['internalResolution'], expected);
        expect(model.embeddedGame?.options[resolution]?.selected, expected == null ? 0 : 1);
        model.closeRunningGame();
        await tester.pump(const Duration(milliseconds: 150));
        await relaunch;
      }
      await tester.pump(const Duration(seconds: 5));
    });
  }
}
