import 'dart:io';

import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/core/game_archives.dart';
import 'package:anyps5_desktop/ui/game_files_model.dart';
import 'package:anyps5_desktop/ui/launcher.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/ffpfsc_builder.dart';
import '../support/fixtures.dart';
import '../support/ui_support.dart';

/// A game dropped into the games folder as a zip is offered for unpacking and shows as a game;
/// an update (a zip, or a folder chosen in Game settings) goes beside its game.
void main() {
  late Fixture fixture;
  late AppModel model;
  late String root;

  Future<void> until(bool Function() condition) async {
    for (var tries = 0; tries < 500 && !condition(); tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(condition(), isTrue);
  }

  /// [folder] (a dump) zipped into [zipPath], inside one folder named [inside] when given.
  void zipFolder(String folder, String zipPath, {String? inside}) {
    final archive = Archive();
    for (final file in Directory(folder).listSync(recursive: true).whereType<File>()) {
      final name = p.posix.joinAll(p.split(p.relative(file.path, from: folder)));
      archive.addFile(ArchiveFile.bytes(inside == null ? name : '$inside/$name', file.readAsBytesSync()));
    }
    File(zipPath).writeAsBytesSync(ZipEncoder().encodeBytes(archive));
  }

  PanelRow row(String id) => model.panelCategories().single.rows.firstWhere((row) => row.id == id);
  List<String> rowIds() => model.panelCategories().single.rows.map((row) => row.id).toList();

  setUp(() {
    fixture = makeFixture();
    model = fixture.model;
    root = model.preferences.gamesFolders.single;
  });

  tearDown(() {
    model.dispose();
    fixture.dispose();
  });

  group('the panel', () {
    Fixture? current;
    tearDown(() {
      current?.model.dispose();
      current?.dispose();
      current = null;
    });

    GameArchive packed(Fixture fixture) {
      final games = fixture.model.preferences.gamesFolders.single;
      final made = makeDump(fixture.temp.path, 'made', titleId: 'PPSA09009', names: {'en-US': 'Packed Hero'});
      zipFolder(made, p.join(games, 'Packed Hero (PPSA09009).zip'));
      return GameArchives.find([games]).single;
    }

    testWidgets('a zip with a game, offered for unpacking', (tester) async {
      final fixture = current = makeFixture();
      final launcher = fixture.model;
      final archive = packed(fixture);
      launcher.freeSpace = (_) => 412000000000;
      launcher.files.asked = UnpackAsk(archive, GameArchives.plan(archive.path), into: archive.folder);
      launcher.open(Layer.gameFiles);
      await pumpLauncher(tester, launcher);
      expect(find.text('Unpack game'), findsOneWidget);
      await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/unpack_game_en.png'));
    });

    testWidgets('unpacking, in Turkish', (tester) async {
      final fixture = current = makeFixture(language: Language.byCode('tr'));
      final launcher = fixture.model;
      final archive = packed(fixture);
      final ask = UnpackAsk(archive, GameArchives.plan(archive.path), into: archive.folder);
      launcher.files
        ..asked = ask
        ..working = ask
        ..done = 14200000000
        ..total = 34600000000;
      launcher.open(Layer.gameFiles);
      await pumpLauncher(tester, launcher);
      expect(find.text('Çıkarılıyor… %41'), findsOneWidget);
      await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/unpack_progress_tr.png'));
    });
  });

  test('a .ffpfsc is offered with its game name and ID, unpacked beside it and read as a game', () async {
    TestFfpfsc(TestFfpfsc.game()).write(p.join(root, 'Small.ffpfsc'));
    model.rescan();
    await until(() => model.overlay == Layer.gameFiles);
    expect(model.panelCategories().single.title, 'Unpack game');
    expect(row('files-about').title, 'Small Quest (PPSA07007)');
    expect(row('files-about').picture, isNotNull);
    expect(
      (row('files-about').kind as InfoRow).text,
      startsWith('A game is inside. It unpacks into the folder Small next to it.'),
    );
    (row('files-go').kind as ActionRow).run();
    await until(() => model.games.any((game) => game.titleId == 'PPSA07007'));
    expect(File(p.join(root, 'Small', 'eboot.bin')).existsSync(), isTrue);
    expect(model.toast, 'Small.ffpfsc is unpacked. The game file can be deleted now.');
    // Unpacked: not offered again.
    model.rescan();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(model.overlay, isNull);
  });

  test('a compressed .ffpfsc says so and offers no Unpack', () async {
    final image = TestFfpfsc(TestFfpfsc.game());
    final table = image.pfscStart + 0x400;
    final first = image.get64(table);
    for (var index = 1; index <= image.blocks; index++) {
      image.set(first + index * 0x8000, table + index * 8, 8);
    }
    image.write(p.join(root, 'Packed.ffpfsc'));
    model.rescan();
    await until(() => model.overlay == Layer.gameFiles);
    expect(rowIds(), ['files-about', 'files-later']);
    expect((row('files-about').kind as InfoRow).text, T.text('ffpfscCompressed'));
    expect(Directory(p.join(root, 'Packed')).existsSync(), isFalse);
  });

  group('Add game file', () {
    String? picked;
    late Fixture fixture2;
    late AppModel launcher;
    late String games;

    setUp(() {
      picked = null;
      fixture2 = makeFixture(pickFile: (label, extensions) async => picked);
      launcher = fixture2.model;
      games = launcher.preferences.gamesFolders.single;
    });

    tearDown(() {
      launcher.dispose();
      fixture2.dispose();
    });

    test('a game file outside the library unpacks into the first games folder', () async {
      final elsewhere = Directory(p.join(fixture2.temp.path, 'Elsewhere'))..createSync();
      TestFfpfsc(TestFfpfsc.game()).write(p.join(elsewhere.path, 'Small.ffpfsc'));
      picked = p.join(elsewhere.path, 'Small.ffpfsc');
      await launcher.files.addGameFile();
      expect(launcher.overlay, Layer.gameFiles);
      final ask = launcher.files.asked! as UnpackAsk;
      expect(ask.into, p.join(games, 'Small'));
      expect(
        (launcher.panelCategories().single.rows.first.kind as InfoRow).text,
        startsWith('A game is inside. It unpacks into the folder Small in your games folder.'),
      );
      await launcher.files.start();
      expect(File(p.join(games, 'Small', 'eboot.bin')).existsSync(), isTrue);
      expect(File(p.join(elsewhere.path, 'Small', 'eboot.bin')).existsSync(), isFalse);
    });

    test('a folder of its name is never written over, and a damaged file is said', () async {
      TestFfpfsc(TestFfpfsc.game()).write(p.join(games, 'Small.ffpfsc'));
      Directory(p.join(games, 'Small')).createSync();
      File(p.join(games, 'Small', 'mine.txt')).writeAsStringSync('keep');
      picked = p.join(games, 'Small.ffpfsc');
      await launcher.files.addGameFile();
      expect(launcher.toast, T.format('addGameFileThere', ['Small']));
      expect(launcher.files.asked, isNull);
      expect(File(p.join(games, 'Small', 'mine.txt')).readAsStringSync(), 'keep');

      File(p.join(games, 'Bad.ffpfsc')).writeAsBytesSync(List.filled(100, 1));
      picked = p.join(games, 'Bad.ffpfsc');
      await launcher.files.addGameFile();
      expect(launcher.toast, T.text('ffpfscDamaged'));
      expect(launcher.files.asked, isNull);
    });

    test('without a games folder it says to add one first', () async {
      launcher.preferences.gamesFolders = const [];
      await launcher.files.addGameFile();
      expect(launcher.toast, T.text('addGameFileNoFolder'));
    });
  });

  test('a zip with a game is offered, unpacked into the folder beside it and read as a game', () async {
    final made = makeDump(fixture.temp.path, 'made', titleId: 'PPSA09009', names: {'en-US': 'Packed Hero'});
    zipFolder(made, p.join(root, 'Packed Hero.zip'), inside: 'PPSA09009-app');
    model.rescan();
    await until(() => model.overlay == Layer.gameFiles);
    expect(model.panelCategories().single.title, 'Unpack game');
    expect(rowIds(), ['files-about', 'files-go', 'files-later']);
    expect(
      (row('files-about').kind as InfoRow).text,
      startsWith('A game is inside. It unpacks into the folder Packed Hero next to it.'),
    );
    (row('files-go').kind as ActionRow).run();
    await until(() => model.games.any((game) => game.titleId == 'PPSA09009'));
    expect(File(p.join(root, 'Packed Hero', 'eboot.bin')).existsSync(), isTrue, reason: 'its one folder left out');
    expect(model.overlay, isNull);
    expect(model.toast, 'Packed Hero.zip is unpacked. The zip can be deleted now.');
    // Unpacked: not offered again.
    model.rescan();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(model.overlay, isNull);
  });

  test('Not now closes it for this run; a zip without a game is never offered', () async {
    File(p.join(root, 'notes.zip'))
        .writeAsBytesSync(ZipEncoder().encodeBytes(Archive()..addFile(ArchiveFile.bytes('readme.txt', [1, 2, 3]))));
    final made = makeDump(fixture.temp.path, 'made', titleId: 'PPSA09009');
    zipFolder(made, p.join(root, 'Later.zip'));
    model.rescan();
    await until(() => model.overlay == Layer.gameFiles);
    expect((model.files.asked! as UnpackAsk).archive.name, 'Later.zip');
    model.handle(Command.back);
    expect(model.overlay, isNull);
    model.rescan();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(model.overlay, isNull);
    expect(Directory(p.join(root, 'Later')).existsSync(), isFalse);
  });

  test('a zip too large for the drive says so and offers no Unpack', () async {
    model.freeSpace = (_) => 1000;
    final made = makeDump(fixture.temp.path, 'made', titleId: 'PPSA09009');
    zipFolder(made, p.join(root, 'Big.zip'));
    model.rescan();
    await until(() => model.overlay == Layer.gameFiles);
    expect(rowIds(), ['files-about', 'files-later']);
    expect((row('files-about').kind as InfoRow).text, contains('and the drive has 1.0 KB.'));
  });

  test('a zip of a newer version of a game in the library unpacks as its update', () async {
    final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
    final patch = makeDump(fixture.temp.path, 'patch', titleId: 'PPSA01001', version: '01.005.000');
    zipFolder(patch, p.join(root, 'orbit patch 1.05.zip'));
    model.rescan();
    await until(() => model.overlay == Layer.gameFiles);
    expect(model.panelCategories().single.title, 'Update for Orbit Runner');
    expect((row('files-about').kind as InfoRow).text, contains('It is update 01.005 of this game'));
    (row('files-go').kind as ActionRow).run();
    await until(() => model.files.working == null && model.overlay == null);
    final updated = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
    expect(updated.update?.folder, p.join(root, '${p.basename(orbit.folder)}-UPDATE'));
    expect(updated.update?.version, '01.005.000');
    expect(model.games.where((game) => game.titleId == 'PPSA01001'), hasLength(1), reason: 'no second game');
    expect(model.toast, 'The update for Orbit Runner is in place. Unlock the game again to apply it.');
    // The game's own folder is untouched.
    expect(File(p.join(orbit.folder, 'sce_sys', 'param.json')).readAsStringSync(), contains('01.000.000'));
  });

  test('Add update takes a folder of the game\'s update and puts it beside the game', () async {
    final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
    final elsewhere = p.join(fixture.temp.path, 'Downloads');
    var picked = makeDump(elsewhere, 'wrong', titleId: 'PPSA02002', version: '01.002.000');
    final picking = makeFixture(pickFolder: (_) async => picked);
    addTearDown(() {
      picking.model.dispose();
      picking.dispose();
    });
    final launcher = picking.model;
    final game = launcher.games.firstWhere((game) => game.titleId == 'PPSA01001');
    await launcher.files.addUpdate(game);
    expect(launcher.toast, 'That folder holds another game, not Orbit Runner.');
    picked = makeDump(elsewhere, 'old', titleId: 'PPSA01001', version: '01.000.000');
    await launcher.files.addUpdate(game);
    expect(launcher.toast, "That folder is no update. Its version is not newer than the game's 01.000.000.");
    picked = makeDump(elsewhere, 'patch', titleId: 'PPSA01001', version: '01.010.000');
    await launcher.files.addUpdate(game);
    expect(launcher.overlay, Layer.gameFiles);
    expect(launcher.panelCategories().single.title, 'Add update to Orbit Runner');
    expect(launcher.panelCategories().single.rows.first.title, 'Update 01.010');
    (launcher.panelCategories().single.rows.firstWhere((row) => row.id == 'files-go').kind as ActionRow).run();
    await until(() => launcher.files.working == null && launcher.overlay == null);
    final target = p.join(launcher.preferences.gamesFolders.single, '${p.basename(game.folder)}-UPDATE');
    expect(File(p.join(target, 'eboot.bin')).existsSync(), isTrue);
    expect(launcher.games.firstWhere((game) => game.titleId == 'PPSA01001').update?.version, '01.010.000');
    expect(launcher.toast, startsWith('The update for Orbit Runner is in place.'));
    // One update at a time: a second one is refused while the first is there.
    picked = makeDump(elsewhere, 'patch2', titleId: 'PPSA01001', version: '01.020.000');
    await launcher.files.addUpdate(launcher.games.firstWhere((game) => game.titleId == 'PPSA01001'));
    expect(launcher.toast, contains('has an update folder already'));
    expect(orbit.folder, isNotEmpty);
  });
}
