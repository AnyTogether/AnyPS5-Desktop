import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/game_deletion.dart';
import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/installer.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_commands.dart';
import '../support/fixtures.dart';

/// A trash in a temporary folder: what is moved lands in [folder], unless [answer] says otherwise
/// for that path. Nothing outside the test's own folders is ever touched.
class FakeTrash extends Trash {
  FakeTrash(this.folder, {this.answer});

  final String folder;
  final TrashResult? Function(String path)? answer;
  final moved = <String>[];

  @override
  Future<TrashResult> move(String path) async {
    final said = answer?.call(path);
    if (said != null) return said;
    Directory(folder).createSync(recursive: true);
    final target = p.join(folder, p.basename(path));
    FileSystemEntity.isDirectorySync(path) ? Directory(path).renameSync(target) : File(path).renameSync(target);
    moved.add(path);
    return const Trashed();
  }
}

/// Delete game, away from the interface: what it may take, what it refuses, and how it ends
/// when the trash takes the files, has no room for them, or fails. Everything in temporary
/// folders, with a trash that is one of them.
void main() {
  late Directory temp;
  late String root;
  late String trashFolder;

  setUp(() {
    temp = temporaryFolder('deletion');
    // Links resolved, so a temporary folder behind a link (macOS's /var) compares as itself.
    root = p.join(temp.resolveSymbolicLinksSync(), 'Games');
    trashFolder = p.join(temp.resolveSymbolicLinksSync(), 'Trash');
    Directory(root).createSync(recursive: true);
  });
  tearDown(() => temp.deleteSync(recursive: true));

  void write(String path, String text) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(text);
  }

  void makeUpdate(String folder, String titleId) {
    write(p.join(folder, 'sce_sys', 'param.json'), jsonEncode({'titleId': titleId, 'contentVersion': '01.004.000'}));
    write(p.join(folder, 'eboot.bin'), 'update');
  }

  List<Game> scan([List<String>? roots]) => GameLibrary.surveyAll(roots ?? [root]).games;

  Game game(String titleId, [List<Game>? games]) => (games ?? scan()).firstWhere((game) => game.titleId == titleId);

  DeletionPlan plan(Game game, {List<String>? roots, List<Game>? games}) =>
      GameDeletion.plan(game, root: root, roots: roots ?? [root], games: games ?? scan(roots));

  Matcher refuses(DeletionRefusal reason) =>
      throwsA(isA<DeletionRefused>().having((refused) => refused.reason, 'reason', reason));

  group('what goes', () {
    test('only the game\'s own folder, when nothing belongs to it', () {
      final astro = makeDump(root, 'astro', titleId: 'PPSA01001');
      makeDump(root, 'stray', titleId: 'PPSA02002');
      expect(plan(game('PPSA01001')).items, [astro]);
    });

    test('its update, its add-ons and the archives they were unpacked from go with it', () {
      final astro = makeDump(root, 'astro', titleId: 'PPSA01001');
      makeUpdate(p.join(root, 'astro-UPDATE'), 'PPSA01001');
      write(p.join(root, 'astro-DLC', 'SKINPACK00000001', 'data.bin'), 'dlc');
      write(p.join(root, 'astro.zip'), 'the zip it came in');
      write(p.join(root, 'astro-UPDATE.ffpfsc'), 'the update\'s file');
      write(p.join(root, 'notes.txt'), 'the player\'s own');
      makeDump(root, 'stray', titleId: 'PPSA02002');
      final found = plan(game('PPSA01001'));
      expect(found.folder, astro);
      expect(found.extras.toSet(), {
        p.join(root, 'astro-UPDATE'),
        p.join(root, 'astro-DLC'),
        p.join(root, 'astro.zip'),
        p.join(root, 'astro-UPDATE.ffpfsc'),
      });
      expect(GameDeletion.size(found.items), greaterThan(0));
    });

    test('an update two dumps of one title share stays', () {
      makeDump(root, 'astro', titleId: 'PPSA01001');
      makeDump(root, 'astro-copy', titleId: 'PPSA01001');
      makeUpdate(p.join(root, 'PPSA01001-UPDATE'), 'PPSA01001');
      final games = scan();
      expect(games.where((game) => game.update != null), hasLength(2), reason: 'both dumps use the update');
      final first = games.firstWhere((game) => p.basename(game.folder) == 'astro');
      expect(plan(first, games: games).items, [first.folder]);
    });

    test('an update that is a link is never taken', () {
      final astro = makeDump(root, 'astro', titleId: 'PPSA01001');
      final elsewhere = p.join(temp.resolveSymbolicLinksSync(), 'Elsewhere', 'update');
      makeUpdate(elsewhere, 'PPSA01001');
      Link(p.join(root, 'astro-UPDATE')).createSync(elsewhere);
      final found = game('PPSA01001');
      expect(found.update, isNotNull, reason: 'the library follows the link');
      expect(plan(found).items, [astro]);
    });
  });

  group('what is refused', () {
    test('a dump kept loose in a games folder: the games folder itself never goes', () {
      makeDump(p.dirname(root), 'Games', titleId: 'PPSA01001');
      makeDump(root, 'stray', titleId: 'PPSA02002');
      final loose = scan().single;
      expect(loose.folder, root, reason: 'the scan stops at the games folder: it is the game');
      expect(() => plan(loose), refuses(DeletionRefusal.libraryFolder));
    });

    test('a game whose folder holds another games folder', () {
      final astro = makeDump(root, 'astro', titleId: 'PPSA01001');
      final inner = p.join(astro, 'More');
      makeDump(inner, 'stray', titleId: 'PPSA02002');
      expect(() => plan(game('PPSA01001'), roots: [root, inner]), refuses(DeletionRefusal.libraryFolder));
    });

    test('a game that is a link to a folder outside the games folder', () {
      final elsewhere = makeDump(p.join(temp.resolveSymbolicLinksSync(), 'Elsewhere'), 'astro', titleId: 'PPSA01001');
      Link(p.join(root, 'astro')).createSync(elsewhere);
      final linked = game('PPSA01001');
      expect(() => plan(linked), refuses(DeletionRefusal.linkedElsewhere));
      expect(Directory(elsewhere).existsSync(), isTrue);
    });

    test('a game reached through a linked folder that leads out of the games folder', () {
      final outside = p.join(temp.resolveSymbolicLinksSync(), 'Elsewhere', 'shelf');
      makeDump(outside, 'astro', titleId: 'PPSA01001');
      Link(p.join(root, 'shelf')).createSync(outside);
      final reached = game('PPSA01001');
      expect(reached.folder, p.join(root, 'shelf', 'astro'));
      expect(() => plan(reached), refuses(DeletionRefusal.linkedElsewhere));
    });

    test('a games folder that is itself a link is still the library: its games can go', () {
      final real = p.join(temp.resolveSymbolicLinksSync(), 'Drive', 'Games');
      makeDump(real, 'astro', titleId: 'PPSA01001');
      final linked = p.join(temp.resolveSymbolicLinksSync(), 'GamesLink');
      Link(linked).createSync(real);
      final games = GameLibrary.surveyAll([linked]).games;
      final found = GameDeletion.plan(games.single, root: linked, roots: [linked], games: games);
      expect(found.items, [p.join(linked, 'astro')]);
    });

    test('a folder another game of the library lives in', () {
      final astro = makeDump(root, 'astro', titleId: 'PPSA01001');
      final games = [
        game('PPSA01001'),
        Game(
          folder: p.join(astro, 'bonus'),
          titleId: 'PPSA09009',
          name: 'Bonus',
          names: const {},
          defaultLanguage: 'en-US',
          version: '1.0',
          executable: ExecutableKind.elf,
        ),
      ];
      expect(() => plan(games.first, games: games), refuses(DeletionRefusal.sharedFolder));
    });
  });

  group('how it ends', () {
    test('everything in the trash, the game\'s folder first, nothing else touched', () async {
      final astro = makeDump(root, 'astro', titleId: 'PPSA01001');
      makeUpdate(p.join(root, 'astro-UPDATE'), 'PPSA01001');
      write(p.join(root, 'astro.zip'), 'zip');
      final stray = makeDump(root, 'stray', titleId: 'PPSA02002');
      final trash = FakeTrash(trashFolder);
      final outcome = await GameDeletion.run(plan(game('PPSA01001')), trash: trash);
      expect(outcome, isA<Deleted>().having((deleted) => deleted.left, 'left', isEmpty));
      expect(trash.moved.first, astro);
      expect(Directory(astro).existsSync(), isFalse);
      expect(Directory(p.join(root, 'astro-UPDATE')).existsSync(), isFalse);
      expect(File(p.join(root, 'astro.zip')).existsSync(), isFalse);
      expect(File(p.join(trashFolder, 'astro', 'eboot.bin')).existsSync(), isTrue, reason: 'moved, not destroyed');
      expect(Directory(stray).existsSync(), isTrue);
      expect(scan().map((game) => game.titleId), ['PPSA02002']);
    });

    test('no trash where the game is: nothing is touched, and it asks before deleting for good', () async {
      final astro = makeDump(root, 'astro', titleId: 'PPSA01001');
      makeUpdate(p.join(root, 'astro-UPDATE'), 'PPSA01001');
      final found = plan(game('PPSA01001'));
      final none = FakeTrash(trashFolder, answer: (_) => const NoTrash());
      expect(await GameDeletion.run(found, trash: none), isA<NeedsPermanent>());
      expect(await GameDeletion.run(found, trash: null), isA<NeedsPermanent>(), reason: 'a system without one');
      expect(Directory(astro).existsSync(), isTrue);
      expect(Directory(p.join(root, 'astro-UPDATE')).existsSync(), isTrue);

      final asked = <String>[];
      final outcome = await GameDeletion.run(
        found,
        trash: none,
        permanent: true,
        remove: (path) async {
          asked.add(path);
          await GameDeletion.removeForGood(path);
        },
      );
      expect(outcome, isA<Deleted>());
      expect(asked, found.items);
      expect(Directory(astro).existsSync(), isFalse);
      expect(Directory(trashFolder).existsSync(), isFalse, reason: 'the trash was never asked');
    });

    test('the trash fails on the game\'s folder: nothing is touched and the reason is given', () async {
      final astro = makeDump(root, 'astro', titleId: 'PPSA01001');
      makeUpdate(p.join(root, 'astro-UPDATE'), 'PPSA01001');
      final trash = FakeTrash(trashFolder, answer: (path) => path == astro ? const TrashFailed('in use') : null);
      final outcome = await GameDeletion.run(plan(game('PPSA01001')), trash: trash);
      expect(outcome, isA<DeletionFailed>().having((failed) => failed.message, 'message', 'in use'));
      expect(trash.moved, isEmpty, reason: 'the update is not taken without its game');
      expect(Directory(astro).existsSync(), isTrue);
      expect(Directory(p.join(root, 'astro-UPDATE')).existsSync(), isTrue);
    });

    test('something that belongs to it cannot follow: the game is deleted and what stayed is named', () async {
      final astro = makeDump(root, 'astro', titleId: 'PPSA01001');
      final update = p.join(root, 'astro-UPDATE');
      makeUpdate(update, 'PPSA01001');
      final trash = FakeTrash(trashFolder, answer: (path) => path == update ? const TrashFailed('in use') : null);
      final outcome = await GameDeletion.run(plan(game('PPSA01001')), trash: trash);
      expect(outcome, isA<Deleted>().having((deleted) => deleted.left, 'left', [update]));
      expect(Directory(astro).existsSync(), isFalse);
      expect(Directory(update).existsSync(), isTrue);
    });

    test('a folder that became a link after it was planned is never followed', () async {
      final astro = makeDump(root, 'astro', titleId: 'PPSA01001');
      final found = plan(game('PPSA01001'));
      final elsewhere = p.join(temp.resolveSymbolicLinksSync(), 'Elsewhere');
      Directory(elsewhere).createSync();
      Directory(astro).renameSync(p.join(elsewhere, 'astro'));
      Link(astro).createSync(p.join(elsewhere, 'astro'));
      final trash = FakeTrash(trashFolder);
      expect(await GameDeletion.run(found, trash: trash), isA<DeletionFailed>());
      expect(await GameDeletion.run(found, trash: trash, permanent: true), isA<DeletionFailed>());
      expect(File(p.join(elsewhere, 'astro', 'eboot.bin')).existsSync(), isTrue);
      expect(trash.moved, isEmpty);
    });

    test('a folder that is gone says so', () async {
      final astro = makeDump(root, 'astro', titleId: 'PPSA01001');
      final found = plan(game('PPSA01001'));
      Directory(astro).deleteSync(recursive: true);
      expect(await GameDeletion.run(found, trash: FakeTrash(trashFolder)), isA<DeletionFailed>());
    });

    test('deleting for good removes links, never what they point to', () async {
      final astro = makeDump(root, 'astro', titleId: 'PPSA01001');
      final kept = p.join(temp.resolveSymbolicLinksSync(), 'Elsewhere', 'kept.bin');
      write(kept, 'not the game\'s');
      Link(p.join(astro, 'link.bin')).createSync(kept);
      await GameDeletion.removeForGood(astro);
      expect(Directory(astro).existsSync(), isFalse);
      expect(File(kept).readAsStringSync(), 'not the game\'s');
    });
  });

  group('the trash on Linux', () {
    test('gio trash takes it', () async {
      final astro = makeDump(root, 'astro', titleId: 'PPSA01001');
      final commands = FakeCommands({
        'gio trash': FakeResult(effect: () => Directory(astro).renameSync(p.join(temp.path, 'gone'))),
      });
      expect(await LinuxTrash(commands).move(astro), isA<Trashed>());
      expect(commands.lines, ['gio trash -- $astro']);
    });

    test('without gio, KDE\'s kioclient is asked', () async {
      final astro = makeDump(root, 'astro', titleId: 'PPSA01001');
      final commands = FakeCommands({
        'gio': const FakeResult(missing: true),
        'kioclient6': FakeResult(effect: () => Directory(astro).renameSync(p.join(temp.path, 'gone'))),
      });
      expect(await LinuxTrash(commands).move(astro), isA<Trashed>());
      expect(commands.lines.last, 'kioclient6 --noninteractive move -- $astro trash:/');
    });

    test('a place gio cannot trash from, and no other tool: no trash, with what gio said', () async {
      final astro = makeDump(root, 'astro', titleId: 'PPSA01001');
      final commands = FakeCommands({
        'gio': const FakeResult(code: 1, lines: ['gio: Trashing on system internal mounts is not supported']),
        'kioclient': const FakeResult(missing: true),
      });
      final result = await LinuxTrash(commands).move(astro);
      expect(result, isA<NoTrash>().having((none) => none.detail, 'detail', contains('not supported')));
      expect(Directory(astro).existsSync(), isTrue);
    });

    test('a tool that says it worked while the folder is still there is not believed', () async {
      final astro = makeDump(root, 'astro', titleId: 'PPSA01001');
      expect(await LinuxTrash(FakeCommands()).move(astro), isA<NoTrash>());
      expect(Directory(astro).existsSync(), isTrue);
    });
  });

  group('the saves', () {
    test('kept in the store when the game is deleted, and back in the game unlocked there again', () async {
      final astro = game('PPSA01001', [GameLibrary.inspect(makeDump(root, 'astro', titleId: 'PPSA01001'))!]);
      final installed = Installer.installedFolder(astro, root);
      write(p.join(installed, 'app.elf'), 'relinked');
      write(p.join(installed, 'app0', 'data.bin'), 'the game');
      write(p.join(installed, '_sd', 'slot1', 'save.dat'), 'forty hours');
      write(p.join(installed, '_trophy', 'earned.json'), '[1,2]');
      write(p.join(installed, '_profiles', 'second', '_sd', 'save.dat'), 'another player');
      write(p.join(installed, '.anyps5-profile'), 'first');

      Installer.keepSaves(astro, root);
      await Installer.uninstall(astro, root);
      expect(Directory(installed).existsSync(), isFalse, reason: 'the installation is gone');
      final kept = Installer.keptSaves(installed);
      expect(p.isWithin(p.join(root, GameLibrary.storeName), kept), isTrue);
      expect(File(p.join(kept, '_sd', 'slot1', 'save.dat')).readAsStringSync(), 'forty hours');
      expect(File(p.join(kept, '_trophy', 'earned.json')).existsSync(), isTrue);
      expect(File(p.join(kept, '_profiles', 'second', '_sd', 'save.dat')).existsSync(), isTrue);
      expect(File(p.join(kept, '.anyps5-profile')).readAsStringSync(), 'first');
      expect(Directory(p.join(kept, 'app0')).existsSync(), isFalse, reason: 'only what is the player\'s own');

      // The game added again in the same folder and unlocked: the new installation takes them.
      final partial = '$installed.partial';
      write(p.join(partial, 'app.elf'), 'relinked again');
      await Installer.placeInstalled(partial, installed);
      expect(File(p.join(installed, '_sd', 'slot1', 'save.dat')).readAsStringSync(), 'forty hours');
      expect(File(p.join(installed, '_profiles', 'second', '_sd', 'save.dat')).readAsStringSync(), 'another player');
      expect(File(p.join(installed, '.anyps5-profile')).readAsStringSync(), 'first');
      expect(Directory(kept).existsSync(), isFalse, reason: 'nothing left to keep');
    });

    test('saves kept twice are both there: the older ones are never written over', () {
      final astro = GameLibrary.inspect(makeDump(root, 'astro', titleId: 'PPSA01001'))!;
      final installed = Installer.installedFolder(astro, root);
      write(p.join(installed, '_sd', 'save.dat'), 'first run');
      Installer.keepSaves(astro, root);
      write(p.join(installed, '_sd', 'save.dat'), 'second run');
      Installer.keepSaves(astro, root);
      final kept = Directory(Installer.keptSaves(installed)).listSync().map((entry) => p.basename(entry.path)).toList();
      expect(kept, hasLength(2));
      expect(File(p.join(Installer.keptSaves(installed), '_sd', 'save.dat')).readAsStringSync(), 'first run');
    });

    test('a game never unlocked has nothing to keep', () {
      final astro = GameLibrary.inspect(makeDump(root, 'astro', titleId: 'PPSA01001'))!;
      Installer.keepSaves(astro, root);
      expect(Directory(Installer.keptSaves(Installer.installedFolder(astro, root))).existsSync(), isFalse);
    });
  });
}
