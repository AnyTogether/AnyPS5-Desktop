import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/game_settings.dart';
import 'package:anyps5_desktop/core/gamepad/pad_navigation.dart';
import 'package:anyps5_desktop/core/installer.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/ui_support.dart';
import 'desktop_features_test.dart' show FakeDesktop, FakePads;

/// Settings › Default Display: the display every game without a choice of its own starts with,
/// and Game Settings saying where a value comes from.
void main() {
  late FakePads pads;
  late FakeDesktop desktop;
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

  Game orbit() => model.games.firstWhere((game) => game.titleId == 'PPSA01001');
  PanelRow row(String id) => model
      .panelCategories()
      .expand((category) => category.rows)
      .firstWhere((row) => row.id == id, orElse: () => throw StateError('no row $id'));
  bool hasRow(String id) => model.panelCategories().expand((category) => category.rows).any((row) => row.id == id);

  void openDefaults() {
    model.open(Layer.settings);
    model.panelCategory = model.panelCategories().indexWhere((category) => category.id == 'displayDefaults');
    model.panelRow = 0;
  }

  void openGame() {
    model.select(model.games.indexOf(orbit()));
    model.open(Layer.gameSettings);
  }

  test('the Settings section starts in full screen, vertical sync on', () {
    openDefaults();
    final category = model.panelCategories()[model.panelCategory];
    expect(category.title, T.text('displayDefaults'));
    expect(
      category.rows.map((row) => row.id),
      ['defaultDisplay', 'defaultStartAnimation', 'defaultVsync'],
      reason: 'no size in full screen, but the start animation',
    );
    expect((row('defaultDisplay').kind as ChoiceRow).selected, 1);
    expect(model.preferences.displayDefaults.windowSize, 75);
    expect((row('defaultVsync').kind as ToggleRow).value, isTrue);
    expect(model.preferences.displayDefaults, const DisplayDefaults());
    expect(
      model.preferences.toJson()['displayDefaults'],
      {'fullscreen': true, 'windowSize': 75, 'vsync': true},
      reason: 'written in every file, so a file without it is an older launcher\'s',
    );
  });

  test('a controller changes the defaults like any other row: ✕ to edit, → to change', () {
    openDefaults();
    expect(model.panelCategories()[model.panelCategory].rows[model.panelRow].id, 'defaultDisplay');
    pads.press(PadButton.south);
    pads.press(PadButton.dpadLeft);
    expect(model.preferences.displayDefaults.fullscreen, isFalse);
    pads.press(PadButton.south);
    expect(hasRow('defaultWindowSize'), isTrue, reason: 'windowed has a size');
    pads.press(PadButton.dpadDown);
    pads.press(PadButton.dpadDown);
    expect(model.panelCategories()[model.panelCategory].rows[model.panelRow].id, 'defaultVsync');
    pads.press(PadButton.south);
    expect(model.preferences.displayDefaults.vsync, isFalse);
    expect(model.preferences.toJson()['displayDefaults'], {'fullscreen': false, 'windowSize': 75, 'vsync': false});
    expect(Preferences.fromJson(model.preferences.toJson()).displayDefaults, model.preferences.displayDefaults);
  });

  test('a game with no choice of its own follows the defaults; its own choice wins', () {
    model.preferences.displayDefaults = const DisplayDefaults(vsync: false);
    final following = model.launchSettings(orbit());
    expect(following.fullscreen, isTrue);
    expect(following.vsync, isFalse);
    expect(following.environment(launcherLanguage: 1)['ANYPS5_FULLSCREEN'], '1');

    model.saveSettings(orbit(), const GameSettings(fullscreen: false, windowSize: 60));
    final own = model.launchSettings(orbit());
    expect(own.fullscreen, isFalse);
    expect(own.windowSize, 60);
    expect(own.vsync, isFalse, reason: 'vertical sync still follows the default');
  });

  test('Game Settings says which values are the default, and each can go back to it', () {
    model.preferences.displayDefaults = const DisplayDefaults(fullscreen: true);
    openGame();
    final display = row('display').kind as ChoiceRow;
    expect(display.options, [
      T.format('followDefault', [T.text('fullscreen')]),
      T.text('windowed'),
      T.text('fullscreen'),
    ]);
    expect(display.selected, 0);
    expect(hasRow('windowSize'), isFalse, reason: 'the default is full screen');
    final vsync = row('vsync').kind as ChoiceRow;
    expect(vsync.options, [
      T.format('followDefault', [T.text('on')]),
      T.text('on'),
      T.text('off'),
    ]);
    expect(vsync.selected, 0);
    expect(hasRow('useDisplayDefaults'), isFalse, reason: 'nothing of its own to go back from');

    display.set(1);
    expect(model.currentSettings(orbit()).ownFullscreen, isFalse);
    final size = row('windowSize').kind as StepperRow;
    expect(size.value, 75);
    expect(size.format(size.value), T.format('followDefault', ['75%']), reason: 'the size is still the default one');
    size.set(80);
    expect(model.currentSettings(orbit()).ownWindowSize, 80);
    expect((row('windowSize').kind as StepperRow).format(80), '80%');
    (row('vsync').kind as ChoiceRow).set(2);
    expect(model.currentSettings(orbit()).ownVsync, isFalse);

    (row('display').kind as ChoiceRow).set(0);
    expect(model.currentSettings(orbit()).ownFullscreen, isNull);
    expect(model.launchSettings(orbit()).fullscreen, isTrue);

    (row('useDisplayDefaults').kind as ActionRow).run();
    expect(model.currentSettings(orbit()).followsDisplayDefaults, isTrue);
    expect(hasRow('useDisplayDefaults'), isFalse);
  });

  test('a game that chose before the update keeps its choice', () {
    model.saveSettings(
      orbit(),
      GameSettings.fromJson(const {'fullscreen': true, 'windowSize': 75, 'vsync': true, 'overlay': 'off'}),
    );
    openGame();
    expect((row('display').kind as ChoiceRow).selected, 2, reason: 'its own Full Screen');
    expect((row('vsync').kind as ChoiceRow).selected, 0, reason: 'never changed: the default');
    model.preferences.displayDefaults = const DisplayDefaults(vsync: false);
    expect(model.launchSettings(orbit()).fullscreen, isTrue);
    expect(model.launchSettings(orbit()).vsync, isFalse);
  });

  test('a game started with no choice anywhere opens in full screen', () async {
    final installed = Installer.installedFolder(orbit(), model.root!);
    File(p.join(installed, 'app.elf')).writeAsStringSync('#!/bin/sh\nexit 0\n');
    if (!Platform.isWindows) Process.runSync('chmod', ['755', p.join(installed, 'app.elf')]);
    model.select(model.games.indexOf(orbit()));
    await model.play(orbit());
    expect(desktop.calls.first, 'display fullscreen', reason: 'upstream\'s engine: the launcher presses F11');
  }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);

  group('an update keeps what games opened with before', () {
    late Directory folder;

    setUp(() => folder = Directory.systemTemp.createTempSync('display_defaults_prefs'));
    tearDown(() => folder.deleteSync(recursive: true));

    test('preferences saved before the full-screen default still open games in a window', () {
      final old = Preferences.fromJson({'prepareNewGames': true, 'stickDeadzone': 10});
      expect(old.displayDefaults.fullscreen, isFalse);
      expect(old.displayDefaults.windowSize, 75);
      final game = const GameSettings().withDefaults(old.displayDefaults);
      expect(game.fullscreen, isFalse);
      expect(game.environment(launcherLanguage: 1)['ANYPS5_FULLSCREEN'], '0');
      expect(game.fadesCover, isFalse);
    });

    test('a first start, with no file, opens games in full screen', () {
      final file = p.join(folder.path, 'preferences.json');
      expect(Preferences.load(file, systemLocales: const ['en']).displayDefaults.fullscreen, isTrue);
      expect(Preferences().displayDefaults.fullscreen, isTrue);
    });

    test('a file from an older launcher stays Window, and the launcher\'s own save keeps the choice either way', () {
      final file = p.join(folder.path, 'preferences.json');
      File(file).writeAsStringSync('{"prepareNewGames":true}');
      final loaded = Preferences.load(file);
      expect(loaded.displayDefaults.fullscreen, isFalse);
      File(file).writeAsStringSync(jsonEncode(loaded.toJson()));
      expect(Preferences.load(file).displayDefaults.fullscreen, isFalse, reason: 'saved as Window, read as Window');
      // Window chosen for a launcher that started in full screen, and full screen chosen back.
      final fresh = Preferences()..displayDefaults = const DisplayDefaults(fullscreen: false);
      File(file).writeAsStringSync(jsonEncode(fresh.toJson()));
      expect(Preferences.load(file).displayDefaults.fullscreen, isFalse);
      File(file).writeAsStringSync(jsonEncode((Preferences()..prepareNewGames = false).toJson()));
      expect(Preferences.load(file).displayDefaults.fullscreen, isTrue, reason: 'new launcher, nothing changed: its default stays');
    });

    test('a game started from the command line reads the same rule', () {
      final file = p.join(folder.path, 'preferences.json');
      expect(DisplayDefaults.load(file).fullscreen, isTrue, reason: 'no file');
      File(file).writeAsStringSync('{"theme":1}');
      expect(DisplayDefaults.load(file).fullscreen, isFalse, reason: 'older launcher');
      File(file).writeAsStringSync('{"theme":1,"displayDefaults":{"fullscreen":true}}');
      expect(DisplayDefaults.load(file).fullscreen, isTrue);
      File(file).writeAsStringSync('{"displayDefaults":"nonsense"}');
      expect(DisplayDefaults.load(file), const DisplayDefaults(), reason: 'a broken value is the built-in one');
    });

    test('a game file from before the settings version keeps Window or Full Screen as written', () {
      final window = GameSettings.fromJson(const {'fullscreen': false, 'windowSize': 75, 'vsync': true, 'overlay': 'off'});
      final full = GameSettings.fromJson(const {'fullscreen': true, 'windowSize': 75, 'vsync': true, 'overlay': 'off'});
      const defaults = DisplayDefaults();
      expect(window.withDefaults(defaults).fullscreen, isFalse, reason: 'still Window under a full-screen default');
      expect(full.withDefaults(const DisplayDefaults.window()).fullscreen, isTrue);
      expect(window.followingDisplayDefaults().withDefaults(defaults).fullscreen, isTrue, reason: 'Use defaults is the way back');
    });
  });

  test('the texts are in English and Turkish', () {
    for (final language in [Language.english, Language.byCode('tr')]) {
      T.language = language;
      for (final key in ['displayDefaults', 'displayDefaultsDetail', 'followDefault', 'useDisplayDefaults']) {
        expect(T.text(key), isNot(key));
      }
    }
    T.language = Language.english;
    expect(T.format('followDefault', ['Window']), 'Default (Window)');
  });
}
