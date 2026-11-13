import 'dart:io';

import 'package:anyps5_desktop/core/gamepad/pad_navigation.dart';
import 'package:anyps5_desktop/core/installer.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fixtures.dart';
import '../support/self_builder.dart';
import '../support/ui_support.dart';
import 'desktop_features_test.dart' show FakePads;

/// Several games folders (a library over more than one drive): the preferences, the library made
/// of them all, a folder whose drive is unplugged, and Settings › Game library's rows.
void main() {
  late Fixture fixture;
  late AppModel model;
  late FakePads pads;

  /// What the folder picker answers next; null is a cancel.
  String? picked;

  setUp(() {
    pads = FakePads();
    fixture = makeFixture(pickFolder: (_) async => picked, pads: () => pads);
    model = fixture.model;
    picked = null;
  });

  tearDown(() {
    model.dispose();
    T.language = Language.english;
    fixture.dispose();
  });

  Future<void> until(bool Function() condition) async {
    for (var tries = 0; tries < 500 && !condition(); tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(condition(), isTrue);
  }

  String folder(String name) => p.join(fixture.temp.path, name);

  /// A second folder with a game of its own and a copy of Neon Alley, scanned.
  String addSecond() {
    final second = folder('Drive2');
    makeDump(second, 'own', titleId: 'PPSA05005', names: {'en-US': 'Second Drive Game'});
    makeDump(second, 'copy', titleId: 'PPSA02002', names: {'en-US': 'Neon Alley'});
    model.preferences.gamesFolders = [...model.preferences.gamesFolders, second];
    model.rescan();
    return second;
  }

  List<PanelRow> libraryRows() {
    if (model.overlay != Layer.settings) model.open(Layer.settings);
    return model.panelCategories().firstWhere((category) => category.id == 'library').rows;
  }

  List<String> rowIds() => libraryRows().map((row) => row.id).toList();

  void openLibrarySettings() {
    model.open(Layer.settings);
    model.panelCategory = model.panelCategories().indexWhere((category) => category.id == 'library');
    model.panelRow = 0;
  }

  group('preferences', () {
    test('a file from before with one games folder keeps it, as a list of one', () {
      final old = Preferences.fromJson({'gamesFolder': '/Games', 'onboarded': true});
      expect(old.gamesFolders, ['/Games']);
      expect(Preferences.fromJson(const {}).gamesFolders, isEmpty);
      expect(Preferences.fromJson({'gamesFolder': null}).gamesFolders, isEmpty);
    });

    test('the list is saved in order and read back; the first is still written for an older launcher', () {
      final file = p.join(fixture.temp.path, 'preferences.json');
      (Preferences()..gamesFolders = ['/B', '/A']).save(file);
      expect(Preferences.load(file).gamesFolders, ['/B', '/A']);
      final json = (Preferences()..gamesFolders = ['/B', '/A']).toJson();
      expect(json['gamesFolders'], ['/B', '/A']);
      expect(json['gamesFolder'], '/B');
      expect(Preferences().toJson()['gamesFolder'], isNull);
    });

    test('the list wins over the old key; junk and repeats in it are left out', () {
      final both = Preferences.fromJson({
        'gamesFolders': ['/A', 7, '', '/B', '/A'],
        'gamesFolder': '/Old',
      });
      expect(both.gamesFolders, ['/A', '/B']);
    });
  });

  group('the library', () {
    test('is every folder\'s games; a title in two folders shows once, from the first', () {
      final second = addSecond();
      expect(model.games, hasLength(5));
      expect(model.games.map((game) => game.name), contains('Second Drive Game'));
      final neon = model.games.where((game) => game.titleId == 'PPSA02002').single;
      expect(p.isWithin(model.root!, neon.folder), isTrue, reason: 'the first folder\'s copy');
      expect(model.folderCounts, {model.root!: 4, second: 2});
    });

    test('a folder added is a new start, not a pile of new games', () {
      addSecond();
      expect(model.toast, isNull);
    });

    test('a folder whose drive is unplugged stays in the list, its games hidden until it is back', () {
      final missing = folder('Unplugged');
      model.preferences.gamesFolders = [model.root!, missing];
      model.rescan();
      expect(model.games, hasLength(4));
      expect(model.preferences.gamesFolders, [model.root!, missing]);
      expect(model.folderCounts[missing], isNull);
      expect(libraryRows()[1].detail, startsWith('Not connected'));
      makeDump(missing, 'back', titleId: 'PPSA06006', names: {'en-US': 'Plugged In'});
      model.rescan();
      expect(model.games.map((game) => game.name), contains('Plugged In'));
      expect(model.folderCounts[missing], 1);
      expect(libraryRows()[1].detail, startsWith('1 game'));
      expect(model.toast, isNull, reason: 'games coming back with their drive are not new');
    });

    test('every connected folder is watched: a dump copied into the second shows up on its own', () async {
      final second = addSecond();
      model.watchGamesFolders();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      makeDump(second, 'late', titleId: 'PPSA09019', names: {'en-US': 'Second Late'});
      await until(() => model.games.any((game) => game.titleId == 'PPSA09019'));
      expect(model.toast, T.format('newGame', ['Second Late']));
    });

    test('a game is unlocked into the store of the folder it was found in, and found there again', () async {
      final second = addSecond();
      final game = model.games.firstWhere((game) => game.titleId == 'PPSA05005');
      expect(model.rootOf(game), second);
      File(p.join(game.folder, 'eboot.bin')).writeAsBytesSync(typicalSelf());
      model.unlock(game);
      await until(() => model.stateOf(game) is Installed);
      final installed = Installer.installedFolder(game, second);
      expect(File(p.join(installed, Installer.recordName)).existsSync(), isTrue);
      expect(Directory(Installer.installedFolder(game, model.root!)).existsSync(), isFalse);
      model.rescan();
      expect(model.stateOf(model.games.firstWhere((game) => game.titleId == 'PPSA05005')), isA<Installed>());
      final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
      expect(model.rootOf(orbit), model.root, reason: 'an unlock from before stays where it is');
      expect(model.stateOf(orbit), isA<Installed>());
    });

    test('with the first folder unplugged the other folders\' games still unlock and play', () async {
      final second = addSecond();
      final first = model.root!;
      model.preferences.gamesFolders = [folder('Unplugged'), second, first];
      model.rescan();
      final game = model.games.firstWhere((game) => game.titleId == 'PPSA05005');
      File(p.join(game.folder, 'eboot.bin')).writeAsBytesSync(typicalSelf());
      model.unlock(game);
      await until(() => model.stateOf(game) is Installed);
      expect(Directory(folder('Unplugged')).existsSync(), isFalse, reason: 'nothing written where the drive was');
    });
  });

  group('Settings › Game library', () {
    test('a row per folder with its games, then Add folder', () {
      final second = addSecond();
      final rows = libraryRows();
      expect(rowIds(), ['folder-0', 'folder-1', 'addFolder', 'addGameFile', 'rescan', 'prepareNewGames', 'retroLibrary']);
      expect(rows[0].title, model.root);
      expect(rows[0].detail, '4 games · ${T.text('folderRemove')}');
      expect(rows[1].title, second);
      expect(rows[1].detail, '2 games · ${T.text('folderRemove')}');
      expect(rows.take(3).every((row) => row.focusable), isTrue);
      T.language = Language.byCode('tr');
      expect(libraryRows()[1].detail, '2 oyun · Kütüphaneden kaldır');
      expect(T.text('addFolder'), 'Klasör ekle');
    });

    test('with the keys: down to a folder, Enter takes it out, Enter on Add folder adds one', () {
      final second = addSecond();
      openLibrarySettings();
      model.command(Command.down);
      expect(model.panelRow, 1);
      model.command(Command.select);
      expect(model.preferences.gamesFolders, [model.root]);
      expect(model.games, hasLength(4));
      expect(model.toast, T.text('folderRemoved'));
      expect(Directory(second).existsSync(), isTrue, reason: 'nothing on the drive goes');
      expect(rowIds()[model.panelRow], 'addFolder', reason: 'the focus stays where the row was');
    });

    test('Add folder appends the picked folder; one already there is said, not added twice', () async {
      final second = folder('Drive2');
      makeDump(second, 'own', titleId: 'PPSA05005', names: {'en-US': 'Second Drive Game'});
      openLibrarySettings();
      model.command(Command.down);
      expect(rowIds()[model.panelRow], 'addFolder');
      picked = second;
      model.command(Command.select);
      await until(() => model.preferences.gamesFolders.length == 2);
      expect(model.preferences.gamesFolders, [fixture.model.root, second]);
      expect(model.games, hasLength(5));
      picked = p.join(second, '.');
      await model.addGamesFolder();
      expect(model.preferences.gamesFolders, hasLength(2));
      expect(model.toast, T.text('folderAlreadyAdded'));
    });

    test('with a controller: Cross on a folder row takes it out', () {
      addSecond();
      model.startPads();
      openLibrarySettings();
      pads.press(PadButton.dpadDown);
      expect(model.panelRow, 1);
      pads.press(PadButton.south);
      expect(model.preferences.gamesFolders, hasLength(1));
    });

    test('taking out the last folder leaves the empty library', () {
      openLibrarySettings();
      model.command(Command.select);
      expect(model.preferences.gamesFolders, isEmpty);
      expect(model.root, isNull);
      expect(model.games, isEmpty);
      expect(rowIds(), ['addFolder', 'addGameFile', 'rescan', 'prepareNewGames', 'retroLibrary']);
    });
  });

  group('the other ways in', () {
    test('Select on the empty shelf adds a folder, keeping the ones there', () async {
      final empty = folder('Empty');
      Directory(empty).createSync();
      final games = model.root!;
      model.preferences.gamesFolders = [empty];
      model.rescan();
      expect(model.games, isEmpty);
      model.focus = HomeFocus.tiles;
      picked = games;
      model.command(Command.select);
      await until(() => model.preferences.gamesFolders.length == 2);
      expect(model.preferences.gamesFolders, [empty, games]);
      expect(model.games, hasLength(4));
    });

    test('onboarding picks the first folder; choosing again changes it', () async {
      final games = model.root!;
      model.preferences.gamesFolders = [];
      picked = folder('Elsewhere');
      await model.chooseGamesFolder();
      expect(model.preferences.gamesFolders, [folder('Elsewhere')]);
      picked = games;
      await model.chooseGamesFolder();
      expect(model.preferences.gamesFolders, [games]);
    });

    test('the copy warning\'s folder fix puts the picked folder first and keeps the others', () async {
      final second = addSecond();
      final first = model.root!;
      picked = second;
      await model.chooseFirstGamesFolder();
      expect(model.preferences.gamesFolders, [second, first]);
      picked = folder('Drive3');
      Directory(picked!).createSync();
      await model.chooseFirstGamesFolder();
      expect(model.preferences.gamesFolders, [folder('Drive3'), second, first]);
    });
  });
}
