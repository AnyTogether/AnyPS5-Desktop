import 'dart:async';
import 'dart:io';

import 'package:anyps5_desktop/core/game_deletion.dart';
import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/installer.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/confirm_card.dart';
import 'package:anyps5_desktop/ui/game_delete_model.dart';
import 'package:anyps5_desktop/ui/launcher.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_process.dart';
import '../support/ui_support.dart';

/// A trash in the test's own temporary folder. [hold] keeps a move waiting, [answer] says
/// something else than "moved" for a path. Nothing outside the fixture is ever touched.
class FakeTrash extends Trash {
  FakeTrash({this.answer, this.hold});

  late String folder;
  TrashResult? Function(String path)? answer;
  Completer<void>? hold;
  final asked = <String>[];

  @override
  Future<TrashResult> move(String path) async {
    asked.add(path);
    await hold?.future;
    final said = answer?.call(path);
    if (said != null) return said;
    Directory(folder).createSync(recursive: true);
    final target = p.join(folder, p.basename(path));
    FileSystemEntity.isDirectorySync(path) ? Directory(path).renameSync(target) : File(path).renameSync(target);
    return const Trashed();
  }
}

/// Game Settings › Delete game: the game itself off the disk, not only what the launcher built.
void main() {
  late Fixture fixture;
  late AppModel model;
  late FakeTrash trash;

  void start({HostSystem system = HostSystem.linux, Language language = Language.english}) {
    trash = FakeTrash();
    fixture = makeFixture(trash: trash, system: system, language: language);
    trash.folder = p.join(fixture.temp.path, 'Trash');
    model = fixture.model;
  }

  tearDown(() {
    T.language = Language.english;
    fixture.dispose();
  });

  Game gameOf(String titleId) => model.games.firstWhere((game) => game.titleId == titleId);

  List<PanelRow> settingsOf(Game game) {
    model.select(model.games.indexOf(game));
    model.open(Layer.gameSettings);
    return model.panelCategories().single.rows;
  }

  Future<void> settled() async {
    await Future.wait(List.of(model.deletion.running));
    await Future<void>.delayed(Duration.zero);
  }

  group('the action', () {
    test('Delete game is the last row, after Uninstall, destructive, for an installed and a locked game', () {
      start();
      final installed = settingsOf(gameOf('PPSA01001'));
      expect(installed.map((row) => row.id).toList().sublist(installed.length - 2), ['uninstall', 'deleteGame']);
      expect(installed.last.title, 'Delete game');
      expect((installed.last.kind as ActionRow).destructive, isTrue);
      expect(model.panelRow, isNot(installed.length - 1), reason: 'never where the focus starts');
      final locked = settingsOf(gameOf('PPSA02002'));
      expect(locked.map((row) => row.id), isNot(contains('uninstall')));
      expect(locked.last.id, 'deleteGame');
    });

    test('while the game plays the row says to close it first, and the card does not open', () {
      start();
      final orbit = gameOf('PPSA01001');
      model.running = (orbit, runningFor(FakeGameProcess()));
      final row = settingsOf(orbit).last;
      expect(row.id, 'deleteGame');
      expect(row.kind, isA<InfoRow>().having((info) => info.text, 'text', T.text('closeGameFirst')));
      model.deletion.open(orbit);
      expect(model.overlay, isNot(Layer.confirmDeleteGame));
      expect(model.toast, T.text('closeGameFirst'));
      model.running = null;
    });
  });

  group('the card', () {
    test('names the game, its folder and its size; Cancel is where the focus starts', () async {
      start();
      final orbit = gameOf('PPSA01001');
      (settingsOf(orbit).last.kind as ActionRow).run();
      // The size is measured away from the interface.
      await Future<void>.delayed(Duration.zero);
      expect(model.overlay, Layer.confirmDeleteGame);
      expect(model.twoChoice, isTrue);
      final category = model.panelCategories().single;
      expect(category.title, 'Delete Orbit Runner?');
      expect(category.rows.map((row) => row.id), ['cancel', 'delete']);
      expect(model.panelRow, 0, reason: 'Enter on the card as it opens deletes nothing');
      final ask = model.deletion.ask!;
      expect(ask.plan.folder, orbit.folder);
      expect(ask.size, greaterThan(0));
      expect(ask.permanent, isFalse);

      model.handle(Command.select);
      expect(model.overlay, isNull);
      expect(model.deletion.ask, isNull);
      expect(model.games, contains(orbit));
      expect(trash.asked, isEmpty);
      expect(Directory(orbit.folder).existsSync(), isTrue);
    });

    test('Back cancels, even from the destructive answer', () {
      start();
      final orbit = gameOf('PPSA01001');
      model.deletion.open(orbit);
      model.handle(Command.right);
      expect(model.panelRow, 1);
      model.handle(Command.back);
      expect(model.overlay, isNull);
      expect(trash.asked, isEmpty);
      expect(model.games, contains(orbit));
    });

    test('a game that started while the card was up is not deleted', () {
      start();
      final orbit = gameOf('PPSA01001');
      model.deletion.open(orbit);
      model.running = (orbit, runningFor(FakeGameProcess()));
      model.deletion.confirm();
      expect(model.toast, T.text('closeGameFirst'));
      expect(trash.asked, isEmpty);
      expect(model.games, contains(orbit));
      model.running = null;
    });
  });

  group('deleting', () {
    test('the tile leaves at once; the files go to the trash, the installation goes, the saves stay', () async {
      start();
      final orbit = gameOf('PPSA01001');
      final installed = Installer.installedFolder(orbit, model.root!);
      Directory(p.join(installed, '_sd')).createSync();
      File(p.join(installed, '_sd', 'save.dat')).writeAsStringSync('forty hours');
      File(p.join(model.root!, 'astro.zip')).writeAsStringSync('the zip it came in');
      final others = [
        for (final game in model.games)
          if (game.id != orbit.id) game.id,
      ];
      trash.hold = Completer<void>();
      model.select(model.games.indexOf(orbit));
      model.deletion.open(orbit);
      model.handle(Command.right);
      model.handle(Command.select);

      expect(model.overlay, isNull);
      expect(model.games.map((game) => game.id), others, reason: 'gone from the library when the answer is given');
      expect(model.selectedGame, isNotNull);
      expect(Directory(orbit.folder).existsSync(), isTrue, reason: 'its files go after, off the interface');
      model.rescan();
      expect(model.games.map((game) => game.id), others, reason: 'a scan meanwhile does not bring it back');

      trash.hold!.complete();
      await settled();
      expect(trash.asked, [orbit.folder, p.join(model.root!, 'astro.zip')]);
      expect(Directory(orbit.folder).existsSync(), isFalse);
      expect(File(p.join(trash.folder, 'astro', 'eboot.bin')).existsSync(), isTrue, reason: 'in the trash, whole');
      expect(File(p.join(trash.folder, 'astro.zip')).existsSync(), isTrue);
      expect(File(p.join(installed, 'app.elf')).existsSync(), isFalse, reason: 'the installation went too');
      expect(
        File(p.join(Installer.keptSaves(installed), '_sd', 'save.dat')).readAsStringSync(),
        'forty hours',
        reason: 'the saves are kept in the store',
      );
      expect(model.toast, T.format('deleteGameDone', ['Orbit Runner', 'Trash']));
      expect(model.games.map((game) => game.id), others);
      expect(model.deletion.hidden, isEmpty);
      expect(model.records.containsKey(orbit.id), isFalse);
    });

    test('the files could not go: the tile comes back, selected, with the reason', () async {
      start();
      final orbit = gameOf('PPSA01001');
      final installed = Installer.installedFolder(orbit, model.root!);
      trash.answer = (_) => const TrashFailed('the folder is in use');
      model.select(model.games.indexOf(orbit));
      model.deletion.open(orbit);
      model.deletion.confirm();
      expect(model.games, isNot(contains(orbit)));
      await settled();
      expect(model.games, contains(orbit));
      expect(model.selectedGame?.id, orbit.id);
      expect(model.stateOf(orbit), isA<Installed>(), reason: 'nothing of the installation was touched');
      expect(File(p.join(installed, 'app.elf')).existsSync(), isTrue);
      expect(Directory(orbit.folder).existsSync(), isTrue);
      expect(model.toast, T.format('deleteGameFailed', ['Orbit Runner', 'the folder is in use']));
      expect(model.overlay, isNull);
    });

    test('no trash where the game is: asked again, Cancel first, before anything is deleted for good', () async {
      start(system: HostSystem.windows);
      final orbit = gameOf('PPSA01001');
      trash.answer = (_) => const NoTrash();
      model.deletion.open(orbit);
      model.deletion.confirm();
      await settled();
      expect(Directory(orbit.folder).existsSync(), isTrue, reason: 'nothing was touched');
      expect(model.games, contains(orbit));
      expect(model.overlay, Layer.confirmDeleteGame);
      expect(model.deletion.ask?.permanent, isTrue);
      final category = model.panelCategories().single;
      expect(category.title, 'Delete Orbit Runner for good?');
      expect(category.rows.map((row) => row.title), ['Cancel', 'Delete for good']);
      expect(model.panelRow, 0);

      // Cancel: everything stays.
      model.handle(Command.select);
      expect(model.overlay, isNull);
      expect(Directory(orbit.folder).existsSync(), isTrue);

      // Asked and answered again: this time it is deleted for good, never through the trash.
      model.deletion.open(orbit);
      model.deletion.confirm();
      await settled();
      final asked = trash.asked.length;
      model.deletion.confirm();
      expect(model.games, isNot(contains(orbit)));
      await settled();
      expect(trash.asked, hasLength(asked), reason: 'the trash is not asked again');
      expect(Directory(orbit.folder).existsSync(), isFalse);
      expect(Directory(trash.folder).existsSync(), isFalse);
      expect(model.toast, T.format('deleteGameDoneForever', ['Orbit Runner']));
      expect(model.games, isNot(contains(orbit)));
    });

    test('a system without a trash service asks the same way', () async {
      fixture = makeFixture(system: HostSystem.windows);
      model = fixture.model;
      final orbit = gameOf('PPSA01001');
      model.deletion.open(orbit);
      model.deletion.confirm();
      await settled();
      expect(Directory(orbit.folder).existsSync(), isTrue);
      expect(model.deletion.ask?.permanent, isTrue);
    });

    test('a dump kept loose in the games folder is refused with the reason, and nothing opens', () {
      start();
      final root = model.root!;
      final loose = Game(
        folder: root,
        titleId: 'PPSA09009',
        name: 'Loose',
        names: const {},
        defaultLanguage: 'en-US',
        version: '1.0',
        executable: ExecutableKind.elf,
      );
      model.deletion.open(loose);
      expect(model.overlay, isNot(Layer.confirmDeleteGame));
      expect(model.toast, T.text('deleteGameRefusedFolder'));
      expect(trash.asked, isEmpty);
    });

    test('the library is left without the game, the selection on a game that is there', () async {
      start();
      final orbit = gameOf('PPSA01001');
      model.deletion.open(orbit);
      model.deletion.confirm();
      await settled();
      expect(model.games.map((game) => game.titleId), isNot(contains('PPSA01001')));
      expect(model.selectedGame, isNotNull, reason: 'the selection rests on a game that is there');
    });
  });

  group('how it looks', () {
    final shell = find.byType(LauncherShell);

    Future<void> card(
      WidgetTester tester,
      String golden, {
      required Language language,
      required HostSystem system,
      required String root,
      required List<String> items,
      bool permanent = false,
    }) async {
      start(system: system, language: language);
      final orbit = gameOf('PPSA01001');
      model.select(model.games.indexOf(orbit));
      // A made-up place, the same on every machine that draws the picture.
      model.deletion.ask = DeleteAsk(
        DeletionPlan(game: orbit, root: root, items: items),
        permanent: permanent,
      )..size = 48200000000;
      model.open(Layer.confirmDeleteGame);
      await pumpLauncher(tester, model);
      expect(find.byType(ConfirmCard), findsOneWidget);
      expect(find.byKey(const ValueKey('delete-path')), findsOneWidget);
      expect(model.panelRow, 0);
      await expectLater(shell, matchesGoldenFile(golden));
    }

    testWidgets(
      'Delete game on Linux: the folder, what goes with it, what stays',
      (tester) => card(
        tester,
        'goldens/delete_game_en.png',
        language: Language.english,
        system: HostSystem.linux,
        root: '/home/utku/Games',
        items: const [
          '/home/utku/Games/Orbit Runner',
          '/home/utku/Games/Orbit Runner-UPDATE',
          '/home/utku/Games/Orbit Runner.zip',
        ],
      ),
    );

    testWidgets(
      'Delete game in Turkish, on Windows: the Recycle Bin by its name',
      (tester) => card(
        tester,
        'goldens/delete_game_tr.png',
        language: Language.byCode('tr'),
        system: HostSystem.windows,
        root: r'D:\Oyunlar',
        items: const [r'D:\Oyunlar\PPSA01001'],
      ),
    );

    testWidgets(
      'no Recycle Bin for it: asked again before deleting for good',
      (tester) => card(
        tester,
        'goldens/delete_game_for_good_en.png',
        language: Language.english,
        system: HostSystem.windows,
        root: r'E:\Games',
        items: const [r'E:\Games\PPSA01001'],
        permanent: true,
      ),
    );

    testWidgets('the card: Cancel on the left with the focus, Delete game on the right; a click on Cancel closes it', (
      tester,
    ) async {
      start();
      final orbit = gameOf('PPSA01001');
      model.select(model.games.indexOf(orbit));
      model.deletion.open(orbit);
      await pumpLauncher(tester, model);
      expect(find.text('Delete Orbit Runner?'), findsOneWidget);
      expect(find.text(orbit.folder), findsOneWidget);
      expect(find.text(T.text('deleteGameStays')), findsOneWidget);
      final cancel = tester.getCenter(find.byKey(const ValueKey('answer-cancel')));
      final delete = tester.getCenter(find.byKey(const ValueKey('answer-delete')));
      expect(cancel.dx, lessThan(delete.dx));
      await press(tester, LogicalKeyboardKey.enter);
      expect(model.overlay, isNull);
      expect(trash.asked, isEmpty);
      expect(model.games, contains(orbit));
    });
  });
}
