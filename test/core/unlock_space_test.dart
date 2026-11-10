import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/file_links.dart';
import 'package:anyps5_desktop/core/free_space.dart';
import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/installer.dart';
import 'package:anyps5_desktop/core/process_control.dart';
import 'package:anyps5_desktop/core/toolkit.dart';
import 'package:anyps5_desktop/core/unlock_space.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_toolkit.dart';
import '../support/fixtures.dart';
import '../support/self_builder.dart';

/// The free space an unlock asks for before it writes anything, the refusal when the games
/// folder's drive does not have it, and unlocking faster: the relinker's output kept, a
/// background unlock that stops for a game and goes on.
void main() {
  const mib = 1 << 20;

  group('the math', () {
    test('a new unlock that links its output needs the binaries four times and the margin', () {
      expect(const UnlockSpace(executables: 100 * mib, linksOutput: true).needed, 400 * mib + UnlockSpace.margin);
    });

    test('without links the installed copy of the relinked files counts too', () {
      expect(const UnlockSpace(executables: 100 * mib, linksOutput: false).needed, 600 * mib + UnlockSpace.margin);
    });

    test('copied libraries and game files are added', () {
      const space = UnlockSpace(executables: 10 * mib, libraries: 30 * mib, copied: 2000 * mib, linksOutput: true);
      expect(space.needed, 40 * mib + 30 * mib + 2000 * mib + UnlockSpace.margin);
      expect(space.copies, isTrue);
    });

    test('a kept relink leaves only its copy', () {
      expect(
        const UnlockSpace(executables: 100 * mib, linksOutput: true, keptRelink: 250 * mib).needed,
        UnlockSpace.margin,
      );
      expect(
        const UnlockSpace(executables: 100 * mib, linksOutput: false, keptRelink: 250 * mib).needed,
        250 * mib + UnlockSpace.margin,
      );
    });
  });

  group('the refusal', () {
    const space = UnlockSpace(executables: 100 * mib, linksOutput: true);

    test('enough space goes ahead', () {
      expect(space.shortage(free: space.needed, folder: 'D:\\Games'), isNull);
    });

    test('too little says how much is needed and free', () {
      final shortage = space.shortage(free: space.needed - 1, folder: 'D:\\Games')!;
      expect(shortage.needed, space.needed);
      expect(shortage.free, space.needed - 1);
      expect(shortage.missing, 1);
      expect(shortage.folder, 'D:\\Games');
      expect(shortage.copying, isFalse);
      expect(shortage.toString(), contains('D:\\Games'));
    });

    test('a shortage while copying says so', () {
      const copying = UnlockSpace(executables: mib, copied: 5000 * mib, linksOutput: true);
      expect(copying.shortage(free: 100 * mib, folder: '/media/usb')!.copying, isTrue);
    });

    test('a drive that does not say how much is free never blocks', () {
      expect(
        const UnlockSpace(executables: 100000 * mib, linksOutput: false).shortage(free: null, folder: '/nas'),
        isNull,
      );
    });
  });

  group('free space', () {
    test('a 64-bit statvfs: available blocks times the fragment size', () {
      final bytes = Uint8List(FreeSpace.statvfsBytes);
      final data = ByteData.sublistView(bytes);
      data.setUint64(0, 4096, Endian.host); // f_bsize
      data.setUint64(8, 4096, Endian.host); // f_frsize
      data.setUint64(16, 1000000, Endian.host); // f_blocks
      data.setUint64(24, 600000, Endian.host); // f_bfree
      data.setUint64(32, 500000, Endian.host); // f_bavail
      expect(FreeSpace.parseStatvfs(bytes), 500000 * 4096);
      data.setUint64(8, 0, Endian.host);
      expect(FreeSpace.parseStatvfs(bytes), 500000 * 4096, reason: 'f_bsize where f_frsize is 0');
      expect(FreeSpace.parseStatvfs(Uint8List(8)), isNull);
    });

    test('this computer says how much is free, where a folder is or would be', () {
      final temp = temporaryFolder('free');
      addTearDown(() => temp.deleteSync(recursive: true));
      expect(FreeSpace.of(temp.path), greaterThan(0));
      expect(FreeSpace.of(p.join(temp.path, 'not', 'yet')), greaterThan(0));
    });
  });

  group('the pipeline', () {
    late Directory temp;
    late String root;
    late String toolkitFolder;

    setUp(() {
      temp = temporaryFolder('space');
      root = p.join(temp.path, 'Games');
      toolkitFolder = makeFakeToolkit(p.join(temp.path, 'toolkit'));
    });
    tearDown(() {
      FileLinks.calls = FileLinks.system;
      temp.deleteSync(recursive: true);
    });

    Game makeGame() {
      final folder = makeDump(
        root,
        'Astro',
        titleId: 'PPSA01234',
        eboot: const [0],
        files: {'data/level1.bin': 'level data'},
      );
      File(p.join(folder, 'eboot.bin')).writeAsBytesSync(typicalSelf());
      Directory(p.join(folder, 'sce_module')).createSync();
      File(p.join(folder, 'sce_module', 'libgame.sprx')).writeAsBytesSync(typicalSelf(seed: 2));
      return GameLibrary.inspect(folder)!;
    }

    bool relinkerRan() => File(p.join(toolkitFolder, 'arguments.txt')).existsSync();
    void forgetRelinkerRun() => File(p.join(toolkitFolder, 'arguments.txt')).deleteSync();

    test('the plan counts the executable and modules and what would be copied', () {
      final game = makeGame();
      final space = Installer.plan(game, root, toolkit: Toolkit(toolkitFolder)).space!;
      expect(
        space.executables,
        File(p.join(game.folder, 'eboot.bin')).lengthSync() +
            File(p.join(game.folder, 'sce_module', 'libgame.sprx')).lengthSync(),
      );
      expect(space.copied, 0, reason: 'hard links on one drive');
      expect(space.linksOutput, isTrue);
      FileLinks.calls = LinkCalls(hardLink: (_, _) => false, symbolicLink: (_, _) => false);
      final copying = Installer.plan(game, root, toolkit: Toolkit(toolkitFolder)).space!;
      expect(copying.copied, Installer.payloadSize(game.folder));
      expect(copying.libraries, greaterThan(0), reason: 'the libraries are copied too');
      expect(copying.linksOutput, isFalse);
    });

    test('with too little space nothing is written: no work folder, no half-made game, no progress', () async {
      final game = makeGame();
      final steps = <InstallStep>[];
      final installer = Installer(
        game: game,
        toolkit: Toolkit(toolkitFolder),
        root: root,
        freeSpace: (_) => mib,
        onProgress: (step, _) => steps.add(step),
      );
      await expectLater(installer.run(), throwsA(isA<SpaceShortage>()));
      expect(steps, isEmpty);
      expect(relinkerRan(), isFalse);
      expect(Directory(p.join(root, GameLibrary.storeName, 'Work')).existsSync(), isFalse);
      final games = Directory(p.join(root, GameLibrary.storeName, 'Games'));
      expect(games.existsSync() ? games.listSync() : const <FileSystemEntity>[], isEmpty);
    });

    test('a copy that does not fit is refused, the same copy with the room goes ahead', () async {
      FileLinks.calls = LinkCalls(hardLink: (_, _) => false, symbolicLink: (_, _) => false);
      final game = makeGame();
      final needed = Installer.plan(game, root, toolkit: Toolkit(toolkitFolder)).space!.needed;
      await expectLater(
        Installer(game: game, toolkit: Toolkit(toolkitFolder), root: root, freeSpace: (_) => needed - 1).run(),
        throwsA(isA<SpaceShortage>().having((shortage) => shortage.copying, 'copying', isTrue)),
      );
      final installed = await Installer(
        game: game,
        toolkit: Toolkit(toolkitFolder),
        root: root,
        freeSpace: (_) => needed,
      ).run();
      expect(Directory(installed).existsSync(), isTrue);
    });

    test('unknown free space lets the unlock go on', () async {
      final installed = await Installer(
        game: makeGame(),
        toolkit: Toolkit(toolkitFolder),
        root: root,
        freeSpace: (_) => null,
      ).run();
      expect(Directory(installed).existsSync(), isTrue);
    });

    test('unlocking again with nothing changed skips the relinker; a change relinks', () async {
      final game = makeGame();
      final installed = await Installer(game: game, toolkit: Toolkit(toolkitFolder), root: root).run();
      expect(relinkerRan(), isTrue);
      final kept = Installer.keptRelink(game, root);
      expect(File(p.join(kept, 'out', 'app.elf')).existsSync(), isTrue);
      forgetRelinkerRun();
      final lines = <String>[];
      await Installer(game: game, toolkit: Toolkit(toolkitFolder), root: root, onLog: lines.add).run();
      expect(relinkerRan(), isFalse);
      expect(lines, contains(contains('reused')));
      expect(File(p.join(installed, 'app.elf')).readAsStringSync(), contains('relinked game'));
      expect(File(p.join(installed, 'app0', 'sce_module', 'libgame.prx')).readAsStringSync(), 'relinked module');
      expect(Installer.plan(game, root, toolkit: Toolkit(toolkitFolder)).space!.keptRelink, isNotNull);
      // The installed executable is the kept one, hard linked: no second copy.
      File(p.join(kept, 'out', 'app.elf')).writeAsStringSync('# one file\n', mode: FileMode.append);
      expect(File(p.join(installed, 'app.elf')).readAsStringSync(), endsWith('# one file\n'));

      // Another resolution, another toolkit or an updated executable: the relinker runs again.
      File(p.join(toolkitFolder, 'version.txt')).writeAsStringSync('toolkit-2\n');
      await Installer(game: game, toolkit: Toolkit(toolkitFolder), root: root).run();
      expect(relinkerRan(), isTrue);
      forgetRelinkerRun();
      File(p.join(game.folder, 'eboot.bin')).writeAsBytesSync(typicalSelf(seed: 9));
      await Installer(game: game, toolkit: Toolkit(toolkitFolder), root: root).run();
      expect(relinkerRan(), isTrue);

      await Installer.uninstall(game, root);
      expect(Directory(kept).existsSync(), isFalse, reason: 'uninstall removes the kept output');
    });

    test('a paused unlock waits and goes on when resumed', () async {
      final game = makeGame();
      final steps = <InstallStep>[];
      final installer = Installer(
        game: game,
        toolkit: Toolkit(toolkitFolder),
        root: root,
        onProgress: (step, _) => steps.add(step),
      );
      installer.pause();
      final done = installer.run();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(steps, isEmpty);
      expect(relinkerRan(), isFalse);
      installer.resume();
      await done;
      expect(relinkerRan(), isTrue);
    });

    test('cancel while paused stops at once', () async {
      final installer = Installer(game: makeGame(), toolkit: Toolkit(toolkitFolder), root: root)..pause();
      final done = installer.run();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      installer.cancel();
      await expectLater(done, throwsA(isA<InstallCancelled>()));
    });
  });

  group('process control', () {
    test('a stopped process stays where it is until resumed; a background one runs at nice 19', () async {
      final process = await Process.start('sleep', ['1']);
      expect(ProcessControl.lower(process.pid), isTrue);
      expect(ProcessControl.niceness(process.pid), 19);
      expect(ProcessControl.suspend(process.pid), isTrue);
      var exited = false;
      unawaited(process.exitCode.then((_) => exited = true));
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(exited, isFalse, reason: 'stopped: its sleep could not finish');
      expect(ProcessControl.resume(process.pid), isTrue);
      await process.exitCode.timeout(const Duration(seconds: 5));
    }, skip: Platform.isWindows ? 'sleep is a POSIX tool; the Windows calls are not run here' : false);
  });
}
