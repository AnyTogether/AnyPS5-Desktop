import 'dart:io';

import 'package:anyps5_desktop/core/game_settings.dart';
import 'package:anyps5_desktop/core/installer.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/ui_support.dart';
import 'desktop_features_test.dart' show FakeDesktop, FakePads;

/// Start animation (Default Display and Game Settings), and how long a game's cover stays.
void main() {
  group('the setting', () {
    test('on by default, and the key is written only when it is off', () {
      expect(const DisplayDefaults().startAnimation, isTrue);
      expect(const DisplayDefaults().toJson().containsKey('startAnimation'), isFalse);
      const off = DisplayDefaults(startAnimation: false);
      expect(off.toJson()['startAnimation'], isFalse);
      expect(DisplayDefaults.fromJson(off.toJson()), off);
      expect(DisplayDefaults.fromJson(const {}).startAnimation, isTrue, reason: 'files from before have none');
      expect(off.isBuiltIn, isFalse);
    });

    test('a game follows the default unless it chose; only full screen fades over the game', () {
      const settings = GameSettings();
      expect(settings.ownStartAnimation, isNull);
      // Built-in display default is windowed: cover can show, but no layered fade over the game.
      expect(settings.fullscreen, isFalse);
      expect(settings.fadesCover, isFalse, reason: 'windowed: no layered fade');
      expect(settings.copyWith(fullscreen: true).fadesCover, isTrue, reason: 'full screen and on by default');
      expect(settings.copyWith(fullscreen: true, startAnimation: false).fadesCover, isFalse);
      final following = settings.withDefaults(const DisplayDefaults(startAnimation: false));
      expect(following.startAnimation, isFalse);
      expect(
        following.copyWith(fullscreen: true, startAnimation: true).fadesCover,
        isTrue,
        reason: 'its own choice wins',
      );
      expect(settings.toJson().containsKey('startAnimation'), isFalse);
      final own = GameSettings.fromJson({'startAnimation': false});
      expect(own.ownStartAnimation, isFalse);
      expect(GameSettings.fromJson(own.toJson()), own);
      expect(own.followsDisplayDefaults, isFalse);
      expect(own.followingDisplayDefaults().followsDisplayDefaults, isTrue);
    });

    test('is a row of Default Display for windowed and full screen', () {
      final fixture = makeFixture();
      addTearDown(fixture.dispose);
      final model = fixture.model;
      model.open(Layer.settings);
      List<String> ids() =>
          model.panelCategories().firstWhere((c) => c.id == 'displayDefaults').rows.map((r) => r.id).toList();
      expect(ids(), contains('defaultStartAnimation'));
      final row = model
          .panelCategories()
          .firstWhere((c) => c.id == 'displayDefaults')
          .rows
          .firstWhere((r) => r.id == 'defaultStartAnimation');
      expect((row.kind as ToggleRow).value, isTrue);
      (row.kind as ToggleRow).set(false);
      expect(model.preferences.displayDefaults.startAnimation, isFalse);
      // Still shown when the default is full screen.
      model.preferences.displayDefaults = model.preferences.displayDefaults.copyWith(fullscreen: true);
      expect(ids(), contains('defaultStartAnimation'));
    });

    test('is a row of a game\'s Display for windowed and full screen', () {
      final fixture = makeFixture();
      addTearDown(fixture.dispose);
      final model = fixture.model;
      final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
      model.select(model.games.indexOf(orbit));
      model.open(Layer.gameSettings);
      List<String> ids() => model.panelCategories().single.rows.map((r) => r.id).toList();
      expect(ids(), contains('startAnimation'));
      final choice =
          model.panelCategories().single.rows.firstWhere((r) => r.id == 'startAnimation').kind as ChoiceRow;
      expect(choice.selected, 0, reason: 'Default');
      choice.set(2);
      expect(model.currentSettings(orbit).ownStartAnimation, isFalse);
      model.saveSettings(orbit, model.currentSettings(orbit).copyWith(fullscreen: true));
      expect(ids(), contains('startAnimation'));
    });
  });

  group('the cover while a game opens', () {
    late FakeDesktop desktop;
    late FakePads pads;
    late Fixture fixture;
    late AppModel model;
    late Future<void> playing;

    setUp(() {
      pads = FakePads();
      desktop = FakeDesktop();
      fixture = makeFixture(pads: () => pads, desktop: desktop);
      model = fixture.model..startPads();
    });

    tearDown(() {
      model.dispose();
      fixture.dispose();
    });

    Future<void> until(bool Function() condition, {int tries = 500}) async {
      for (var index = 0; index < tries && !condition(); index++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(condition(), isTrue);
    }

    Future<void> startOrbit({
      required bool fullscreen,
      bool startAnimation = true,
      bool coverWorks = false,
      bool windowNeverOpens = false,
      String script = '#!/bin/sh\nsleep 30\n',
    }) async {
      desktop.coverWorks = coverWorks;
      desktop.windowNeverOpens = windowNeverOpens;
      model.preferences.displayDefaults = DisplayDefaults(
        fullscreen: fullscreen,
        startAnimation: startAnimation,
      );
      final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
      final installed = Installer.installedFolder(orbit, model.root!);
      File(p.join(installed, 'app.elf')).writeAsStringSync(script);
      Process.runSync('chmod', ['755', p.join(installed, 'app.elf')]);
      model.select(model.games.indexOf(orbit));
      playing = model.play(orbit);
    }

    test('stays up after the process started, separate from starting; gone once it has settled', () async {
      // Full screen without a layered desktop: fadeCover is asked and returns false; the cover
      // stays on the home screen until applyDisplay completes, then drops.
      desktop.displayDelay = const Duration(milliseconds: 500);
      await startOrbit(fullscreen: true);
      await until(() => model.coverGame != null);
      await until(() => model.starting == null && model.running != null);
      expect(model.coverGame, isNotNull, reason: 'cover kept after starting cleared');
      expect(desktop.coverEvents, contains('asked'));
      await until(() => model.coverGame == null);
      model.stopGame();
      await playing;
    }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);

    test('a desktop with a picture over the game takes the cover\'s place at once', () async {
      await startOrbit(fullscreen: true, coverWorks: true);
      await until(() => desktop.coverEvents.contains('covered'));
      await until(() => desktop.coverEvents.contains('gone'));
      expect(desktop.coverEvents.take(2), ['asked', 'covered']);
      expect(model.coverGame, isNull);
      model.stopGame();
      await playing;
    }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);

    test('a game that exits before it opens a window takes the cover with it at once', () async {
      await startOrbit(
        fullscreen: true,
        windowNeverOpens: true,
        script: '#!/bin/sh\nsleep 1\nexit 1\n',
      );
      await until(() => model.coverGame != null);
      await until(() => model.coverGame == null);
      expect(desktop.coverEvents, contains('no window'), reason: 'the wait for the window stopped with the process');
      await playing;
    }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);

    test('a menu opened over the cover shows: the cover goes', () async {
      await startOrbit(fullscreen: true, windowNeverOpens: true);
      await until(() => model.coverGame != null);
      model.open(Layer.quickMenu);
      expect(model.coverGame, isNull);
      expect(model.overlay, Layer.quickMenu);
      model.stopGame();
      await playing;
    }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);

    test('in a window: cover stays on the home screen, desktop is not asked for a layered fade', () async {
      desktop.displayDelay = const Duration(milliseconds: 500);
      await startOrbit(fullscreen: false);
      await until(() => model.coverGame != null);
      expect(desktop.coverEvents, isEmpty, reason: 'no layered fade in a window');
      // Cover stays until the display step finishes (or the game exits).
      model.stopGame();
      await until(() => model.coverGame == null);
      await playing;
    }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);

    test('off: no cover is kept and the desktop is not asked for one', () async {
      await startOrbit(fullscreen: true, startAnimation: false);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(model.coverGame, isNull);
      expect(desktop.coverEvents, isEmpty);
      model.stopGame();
      await playing;
    }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);
  });
}

