import 'dart:io';

import 'package:anyps5_desktop/core/game_settings.dart';
import 'package:anyps5_desktop/core/installer.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/ui_support.dart';
import 'desktop_features_test.dart' show FakeDesktop, FakePads;

/// Start animation (Default Display and Game Settings, full screen only), and how long a game's cover stays.
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

    test('a game follows the default unless it chose; only full screen fades', () {
      const settings = GameSettings();
      expect(settings.ownStartAnimation, isNull);
      expect(settings.fadesCover, isTrue, reason: 'full screen and on by default');
      expect(settings.copyWith(fullscreen: false).fadesCover, isFalse, reason: 'a window has no fade');
      expect(settings.copyWith(startAnimation: false).fadesCover, isFalse);
      final following = settings.withDefaults(const DisplayDefaults(startAnimation: false));
      expect(following.startAnimation, isFalse);
      expect(following.copyWith(startAnimation: true).fadesCover, isTrue, reason: 'its own choice wins');
      expect(settings.toJson().containsKey('startAnimation'), isFalse);
      final own = GameSettings.fromJson({'startAnimation': false});
      expect(own.ownStartAnimation, isFalse);
      expect(GameSettings.fromJson(own.toJson()), own);
      expect(own.followsDisplayDefaults, isFalse);
      expect(own.followingDisplayDefaults().followsDisplayDefaults, isTrue);
    });

    test('is a row of Default Display, only while the default is full screen', () {
      final fixture = makeFixture();
      addTearDown(fixture.dispose);
      final model = fixture.model;
      model.open(Layer.settings);
      List<String> ids() => model.panelCategories().firstWhere((c) => c.id == 'displayDefaults').rows.map((r) => r.id).toList();
      expect(ids(), contains('defaultStartAnimation'));
      final row = model.panelCategories().firstWhere((c) => c.id == 'displayDefaults').rows.firstWhere((r) => r.id == 'defaultStartAnimation');
      expect((row.kind as ToggleRow).value, isTrue);
      (row.kind as ToggleRow).set(false);
      expect(model.preferences.displayDefaults.startAnimation, isFalse);
      model.preferences.displayDefaults = model.preferences.displayDefaults.copyWith(fullscreen: false);
      expect(ids(), isNot(contains('defaultStartAnimation')));
    });

    test('is a row of a game\'s Display, only while it starts in full screen', () {
      final fixture = makeFixture();
      addTearDown(fixture.dispose);
      final model = fixture.model;
      final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
      model.select(model.games.indexOf(orbit));
      model.open(Layer.gameSettings);
      List<String> ids() => model.panelCategories().single.rows.map((r) => r.id).toList();
      expect(ids(), contains('startAnimation'));
      final choice = model.panelCategories().single.rows.firstWhere((r) => r.id == 'startAnimation').kind as ChoiceRow;
      expect(choice.selected, 0, reason: 'Default');
      choice.set(2);
      expect(model.currentSettings(orbit).ownStartAnimation, isFalse);
      model.saveSettings(orbit, model.currentSettings(orbit).copyWith(fullscreen: false));
      expect(ids(), isNot(contains('startAnimation')), reason: 'a window has no fade');
    });
  });

  group('the cover while a game opens', () {
    late FakeDesktop desktop;
    late FakePads pads;
    late Fixture fixture;
    late AppModel model;

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
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(condition(), isTrue);
    }

    late Future<void> playing;

    Future<void> playOrbit() async {
      final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
      final installed = Installer.installedFolder(orbit, model.root!);
      File(p.join(installed, 'app.elf')).writeAsStringSync('#!/bin/sh\nsleep 5\n');
      if (!Platform.isWindows) Process.runSync('chmod', ['755', p.join(installed, 'app.elf')]);
      model.select(model.games.indexOf(orbit));
      playing = model.play(orbit);
      await until(() => model.running != null);
    }

    test('stays up after the process started, separate from `starting`; gone once it has settled', () async {
      await playOrbit();
      expect(model.starting, isNull, reason: '`starting` still means only the process being started');
      await until(() => desktop.coverEvents.isNotEmpty);
      await until(() => model.coverGame == null);
      model.stopGame();
      await playing;
    }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);

    test('a desktop with a picture over the game takes the cover\'s place at once', () async {
      desktop.coverWorks = true;
      await playOrbit();
      await until(() => desktop.coverEvents.contains('gone'));
      expect(desktop.coverEvents.take(2), ['asked', 'covered']);
      expect(model.coverGame, isNull);
      model.stopGame();
      await playing;
    }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);

    test('a game that exits before it opens a window takes the cover with it at once', () async {
      desktop.windowNeverOpens = true;
      final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
      final installed = Installer.installedFolder(orbit, model.root!);
      File(p.join(installed, 'app.elf')).writeAsStringSync('#!/bin/sh\nsleep 1\nexit 1\n');
      Process.runSync('chmod', ['755', p.join(installed, 'app.elf')]);
      model.select(model.games.indexOf(orbit));
      playing = model.play(orbit);
      await until(() => model.coverGame != null);
      await until(() => model.coverGame == null);
      expect(desktop.coverEvents, contains('no window'), reason: 'the wait for the window stopped with the process');
      await playing;
    }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);

    test('a menu opened over the cover shows: the cover goes', () async {
      desktop.windowNeverOpens = true;
      await playOrbit();
      await until(() => model.coverGame != null);
      model.open(Layer.quickMenu);
      expect(model.coverGame, isNull);
      expect(model.overlay, Layer.quickMenu);
      model.stopGame();
      await playing;
    }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);

    test('in a window: no fade, so no cover is kept and the desktop is not asked for one', () async {
      model.preferences.displayDefaults = const DisplayDefaults(fullscreen: false);
      await playOrbit();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(model.coverGame, isNull);
      expect(desktop.coverEvents, isEmpty);
      model.stopGame();
      await playing;
    }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);

    test('off: no cover is kept and the desktop is not asked for one', () async {
      model.preferences.displayDefaults = const DisplayDefaults(startAnimation: false);
      await playOrbit();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(model.coverGame, isNull);
      expect(desktop.coverEvents, isEmpty);
      model.stopGame();
      await playing;
    }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);
  });
}
