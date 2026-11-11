import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/file_links.dart';
import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/game_process.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/installer.dart';
import 'package:anyps5_desktop/core/toolkit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_toolkit.dart';
import '../support/fixtures.dart';
import '../support/self_builder.dart';

void main() {
  late Directory temp;
  late String root;
  late String toolkitFolder;

  setUp(() {
    temp = temporaryFolder('install');
    root = p.join(temp.path, 'Games');
    toolkitFolder = makeFakeToolkit(p.join(temp.path, 'toolkit'));
  });
  tearDown(() => temp.deleteSync(recursive: true));

  /// A dump with a SELF eboot, a SELF module in sce_module and an ELF plugin elsewhere.
  Game makeGame({List<int>? eboot}) {
    final folder = makeDump(
      root,
      'Astro',
      titleId: 'PPSA01234',
      names: {'en-US': 'Astro Bot'},
      eboot: eboot ?? const [0],
      files: {'data/level1.bin': 'level data', 'sce_sys/trophy2/trophy00.ucp': 'trophies'},
    );
    if (eboot == null) File(p.join(folder, 'eboot.bin')).writeAsBytesSync(typicalSelf());
    Directory(p.join(folder, 'sce_module')).createSync();
    File(p.join(folder, 'sce_module', 'libgame.sprx')).writeAsBytesSync(typicalSelf(seed: 2));
    Directory(p.join(folder, 'Media', 'Plugins')).createSync(recursive: true);
    File(p.join(folder, 'Media', 'Plugins', 'plugin.prx')).writeAsBytesSync([...elfHead, 1, 2, 3]);
    return GameLibrary.inspect(folder)!;
  }

  group('install', () {
    test('unwraps, relinks and lays the game out as upstream runtime layout says', () async {
      final game = makeGame();
      final steps = <InstallStep>[];
      final relinkFractions = <double>[];
      final lines = <String>[];
      final installer = Installer(
        game: game,
        toolkit: Toolkit(toolkitFolder),
        root: root,
        clock: () => DateTime.utc(2026, 10, 24, 12),
        onProgress: (step, fraction) {
          if (steps.isEmpty || steps.last != step) steps.add(step);
          if (step == InstallStep.relink) relinkFractions.add(fraction);
        },
        onLog: lines.add,
      );
      final installed = await installer.run();
      expect(installed, Installer.installedFolder(game, root));
      expect(p.basename(installed), startsWith('PPSA01234-'));
      expect(steps, InstallStep.values);
      expect(relinkFractions.first, 0);
      expect(relinkFractions.last, 1);
      for (var index = 1; index < relinkFractions.length; index++) {
        expect(relinkFractions[index], greaterThanOrEqualTo(relinkFractions[index - 1]));
      }
      expect(relinkFractions, contains(closeTo(0.85, 1e-9)), reason: 'PRX conversion 2/2');

      // The relinker ran in the unwrapped source with every module folder.
      final arguments = fakeRelinkerArguments(toolkitFolder);
      expect(p.basename(arguments[0]), 'source');
      expect(arguments.sublist(1, arguments.length - 1), [
        '--module-dir',
        '.',
        '--module-dir',
        'Media/Plugins',
        'eboot.bin',
      ]);
      expect(p.basename(arguments.last), 'app.elf');
      expect(lines.where((line) => RegExp(r'^eboot\.bin: unwrapped, \d+ bytes$').hasMatch(line)), hasLength(1));
      expect(lines, contains('Guest module: app0/sce_module/libgame.prx'));

      // The layout.
      expect(File(p.join(installed, 'app.elf')).existsSync(), isTrue);
      expect(File(p.join(installed, 'app.elf')).statSync().modeString(), startsWith('rwx'));
      expect(File(p.join(installed, 'libs', 'libkernel.prx')).readAsStringSync(), 'kernel library');
      expect(File(p.join(installed, 'libs', 'libSceVideoOut.prx')).existsSync(), isTrue);
      expect(File(p.join(installed, 'libs', 'README.txt')).existsSync(), isFalse);
      // app0 holds the game's own files, the original eboot.bin among them.
      expect(File(p.join(installed, 'app0', 'eboot.bin')).readAsBytesSync(), typicalSelf());
      expect(File(p.join(installed, 'app0', 'data', 'level1.bin')).readAsStringSync(), 'level data');
      expect(File(p.join(installed, 'app0', 'sce_sys', 'param.json')).existsSync(), isTrue);
      // The relinked module replaced the link, and the dump's own file is untouched.
      expect(File(p.join(installed, 'app0', 'sce_module', 'libgame.prx')).readAsStringSync(), 'relinked module');
      expect(File(p.join(game.folder, 'sce_module', 'libgame.sprx')).readAsBytesSync(), typicalSelf(seed: 2));
      expect(File(p.join(game.folder, 'sce_module', 'libgame.prx')).existsSync(), isFalse);
      // The record and the launch script.
      final record = Installer.record(installed, system: HostSystem.linux)!;
      expect(record.titleId, 'PPSA01234');
      expect(record.toolkit, 'toolkit-1');
      expect(record.system, 'linux');
      expect(record.source, game.folder);
      expect(record.date, DateTime.utc(2026, 10, 24, 12));
      final script = File(p.join(installed, 'launch.sh')).readAsStringSync();
      expect(script, startsWith('#!/bin/sh\n'));
      expect(script, contains('exec ./app.elf "\$@"'));
      // Nothing is left in the store but the game.
      expect(Directory(p.join(root, GameLibrary.storeName, 'Work')).listSync(), isEmpty);
      expect(Directory('$installed.partial').existsSync(), isFalse);
      // The store is not a game.
      expect(GameLibrary.scan(root).map((game) => game.titleId), ['PPSA01234']);
    });

    test('game files are hard links on the same volume, so they take no space', () async {
      final game = makeGame();
      final installed = await Installer(game: game, toolkit: Toolkit(toolkitFolder), root: root).run();
      final original = File(p.join(game.folder, 'data', 'level1.bin'));
      final linked = File(p.join(installed, 'app0', 'data', 'level1.bin'));
      expect(FileSystemEntity.typeSync(linked.path, followLinks: false), FileSystemEntityType.file);
      expect(linked.statSync().modified, original.statSync().modified);
      // Same inode: a hard link (stat -f %i on macOS, stat -c %i on Linux).
      String inode(String path) {
        final result = Process.runSync('stat', Platform.isMacOS ? ['-f', '%i', path] : ['-c', '%i', path]);
        return (result.stdout as String).trim();
      }

      expect(inode(linked.path), inode(original.path));
    });

    test('symbolic links and copies work as well', () async {
      for (final mode in [LinkMode.symbolic, LinkMode.copy]) {
        final game = makeGame();
        final installed = await Installer(
          game: game,
          toolkit: Toolkit(toolkitFolder),
          root: root,
          linkMode: mode,
        ).run();
        final linked = p.join(installed, 'app0', 'data', 'level1.bin');
        expect(
          FileSystemEntity.typeSync(linked, followLinks: false),
          mode == LinkMode.symbolic ? FileSystemEntityType.link : FileSystemEntityType.file,
        );
        expect(File(linked).readAsStringSync(), 'level data');
        expect(File(p.join(installed, 'app0', 'sce_module', 'libgame.prx')).readAsStringSync(), 'relinked module');
        expect(File(p.join(game.folder, 'sce_module', 'libgame.sprx')).readAsBytesSync(), typicalSelf(seed: 2));
        Directory(game.folder).deleteSync(recursive: true);
      }
    });

    test('installing again keeps what the game wrote: saves, trophies, data', () async {
      final game = makeGame();
      final installed = await Installer(game: game, toolkit: Toolkit(toolkitFolder), root: root).run();
      File(p.join(installed, '_sd', 'slot0', 'save.dat')).createSync(recursive: true);
      File(p.join(installed, '_sd', 'slot0', 'save.dat')).writeAsStringSync('progress');
      File(p.join(installed, '_trophy', '1_0.txt')).createSync(recursive: true);
      File(p.join(installed, 'app.elf')).writeAsStringSync('old executable');
      Link(p.join(installed, 'stray-link')).createSync(temp.path);
      makeFakeToolkit(toolkitFolder, version: 'toolkit-2');
      final again = await Installer(game: game, toolkit: Toolkit(toolkitFolder), root: root).run();
      expect(again, installed);
      expect(File(p.join(installed, '_sd', 'slot0', 'save.dat')).readAsStringSync(), 'progress');
      expect(File(p.join(installed, '_trophy', '1_0.txt')).existsSync(), isTrue);
      expect(File(p.join(installed, 'app.elf')).readAsStringSync(), isNot('old executable'));
      expect(
        FileSystemEntity.typeSync(p.join(installed, 'stray-link'), followLinks: false),
        FileSystemEntityType.notFound,
      );
      expect(Installer.record(installed, system: HostSystem.linux)!.toolkit, 'toolkit-2');
    });

    test('the Windows layout: app.exe from relinker.exe with --windows --windows-gui, DLLs, launch.cmd', () async {
      makeFakeToolkit(toolkitFolder, windowsDlls: true);
      final game = makeGame();
      final toolkit = Toolkit(toolkitFolder, system: HostSystem.windows);
      final installed = await Installer(game: game, toolkit: toolkit, root: root).run();
      final arguments = fakeRelinkerArguments(toolkitFolder);
      expect(arguments.sublist(1, 3), ['--windows', '--windows-gui']);
      expect(p.basename(arguments.last), 'app.exe');
      expect(File(p.join(installed, 'app.exe')).existsSync(), isTrue);
      expect(File(p.join(installed, 'libs', 'libwinpthread-1.dll')).existsSync(), isTrue);
      final script = File(p.join(installed, 'launch.cmd')).readAsStringSync();
      expect(script, startsWith('@echo off\r\n'));
      expect(script, contains('"%~dp0app.exe" %*\r\n'));
      expect(Installer.record(installed, system: HostSystem.windows)!.system, 'windows');
      expect(Installer.record(installed, system: HostSystem.linux), isNull, reason: 'no app.elf');
    });

    test('a failing relinker: the error carries its last line, nothing is left behind', () async {
      makeFakeToolkit(toolkitFolder, mode: 'fail');
      final game = makeGame();
      final lines = <String>[];
      await expectLater(
        Installer(game: game, toolkit: Toolkit(toolkitFolder), root: root, onLog: lines.add).run(),
        throwsA(
          predicate((e) => e is InstallError && e.message == 'relinker failed (3): relink: unsupported relocation'),
        ),
      );
      expect(lines, contains('PRX conversion | libgame.prx | 100% (2/2)'));
      expect(lines.where((line) => line.contains('(1/2)')), isEmpty, reason: 'only the last state of a rewritten line');
      expect(Directory(p.join(root, GameLibrary.storeName, 'Work')).listSync(), isEmpty);
      expect(Directory(Installer.installedFolder(game, root)).existsSync(), isFalse);
    });

    test('a relinker that writes nothing', () async {
      makeFakeToolkit(toolkitFolder, mode: 'silent');
      await expectLater(
        Installer(game: makeGame(), toolkit: Toolkit(toolkitFolder), root: root).run(),
        throwsA(predicate((e) => e is InstallError && e.message == 'relinker wrote no executable')),
      );
    });

    test('an encrypted dump is refused before the relinker runs', () async {
      final game = makeGame(eboot: [9, 9, 9, 9]);
      await expectLater(
        Installer(game: game, toolkit: Toolkit(toolkitFolder), root: root).run(),
        throwsA(
          predicate(
            (e) =>
                e is InstallError &&
                e.message ==
                    'eboot.bin in the dump is encrypted (neither an ELF nor a decrypted SELF container): '
                        'dump the game again with a dumper that decrypts it',
          ),
        ),
      );
      expect(File(p.join(toolkitFolder, 'arguments.txt')).existsSync(), isFalse);
    });

    test('a re-signed dump is read from eboot.bin.esbak', () async {
      final game = makeGame(eboot: [1, 2, 3, 4]);
      File(p.join(game.folder, 'eboot.bin.esbak')).writeAsBytesSync([...elfHead, 0, 0]);
      final lines = <String>[];
      await Installer(game: game, toolkit: Toolkit(toolkitFolder), root: root, onLog: lines.add).run();
      expect(lines, contains('eboot.bin: from .esbak'));
    });

    test('cancelling stops the relinker and cleans up', () async {
      makeFakeToolkit(toolkitFolder, mode: 'slow');
      final game = makeGame();
      late Installer installer;
      installer = Installer(
        game: game,
        toolkit: Toolkit(toolkitFolder),
        root: root,
        onProgress: (step, fraction) {
          if (step == InstallStep.relink) Future<void>.delayed(const Duration(milliseconds: 300), installer.cancel);
        },
      );
      final watch = Stopwatch()..start();
      await expectLater(installer.run(), throwsA(isA<InstallCancelled>()));
      expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
      expect(Directory(p.join(root, GameLibrary.storeName, 'Work')).listSync(), isEmpty);
    });

    test('a toolkit without a relinker or libraries is refused', () async {
      final empty = p.join(temp.path, 'empty');
      Directory(empty).createSync();
      await expectLater(
        Installer(game: makeGame(), toolkit: Toolkit(empty), root: root).run(),
        throwsA(predicate((e) => e is InstallError && e.message.startsWith('the toolkit has no relinker'))),
      );
    });

    test('removeLeftovers clears work folders and half-made games, uninstall removes the game', () async {
      final game = makeGame();
      final installed = await Installer(game: game, toolkit: Toolkit(toolkitFolder), root: root).run();
      Directory(p.join(root, GameLibrary.storeName, 'Work', 'x')).createSync(recursive: true);
      Directory('$installed-other.partial').createSync();
      Installer.removeLeftovers(root);
      expect(Directory(p.join(root, GameLibrary.storeName, 'Work')).existsSync(), isFalse);
      expect(Directory('$installed-other.partial').existsSync(), isFalse);
      expect(Directory(installed).existsSync(), isTrue);
      await Installer.uninstall(game, root);
      expect(Directory(installed).existsSync(), isFalse);
      expect(
        File(p.join(game.folder, 'data', 'level1.bin')).readAsStringSync(),
        'level data',
        reason: 'the dump stays',
      );
    });
  });

  group('relink inputs', () {
    /// What a relink by hand leaves in a dump: the relinker writes its modules into the app0 it is
    /// pointed at, which is the dump when the dump is used as app0. On Windows they are PE files.
    void pollute(String folder) {
      File(p.join(folder, 'sce_module', 'libgame.sprx.guest.prx')).writeAsBytesSync([0x4D, 0x5A, 0x90, 0]);
      File(p.join(folder, 'sce_module', 'libSceFace.PRX.GUEST.PRX')).writeAsBytesSync([0x4D, 0x5A, 0x90, 0]);
      File(p.join(folder, 'Media', 'Plugins', 'plugin.prx.guest.prx')).writeAsBytesSync([0x4D, 0x5A, 0x90, 0]);
    }

    test('a relinker output in the dump is never an input', () {
      final game = makeGame();
      pollute(game.folder);
      expect(Installer.modules(game.folder), ['Media/Plugins/plugin.prx', 'sce_module/libgame.sprx']);
      expect(Installer.isRelinkerOutput('libSceFace.prx.guest.prx'), isTrue);
      expect(Installer.isRelinkerOutput('C:\\Games\\x\\sce_module\\libc.prx.Guest.prx'), isTrue);
      expect(Installer.isRelinkerOutput('libSceFace.prx'), isFalse);
      expect(Installer.isRelinkerOutput('guest.prx.esbak'), isFalse);
    });

    test('a dump with outputs of an earlier relink in it unlocks; only this relink\'s outputs go in', () async {
      final game = makeGame();
      pollute(game.folder);
      final installed = await Installer(game: game, toolkit: Toolkit(toolkitFolder), root: root).run();
      final runs = fakeRelinkerInputs(toolkitFolder);
      expect(runs, [
        ['Media/Plugins/plugin.prx', 'eboot.bin', 'sce_module/libgame.sprx'],
      ]);
      // The output is beside the source, never in it.
      final arguments = fakeRelinkerArguments(toolkitFolder);
      expect(p.isWithin(arguments.first, arguments.last), isFalse);
      // The stale outputs stay in the dump, out of the game.
      final app0 = p.join(installed, 'app0');
      expect(File(p.join(app0, 'sce_module', 'libgame.sprx.guest.prx')).existsSync(), isFalse);
      expect(File(p.join(app0, 'sce_module', 'libSceFace.PRX.GUEST.PRX')).existsSync(), isFalse);
      expect(File(p.join(app0, 'Media', 'Plugins', 'plugin.prx.guest.prx')).existsSync(), isFalse);
      expect(File(p.join(app0, 'sce_module', 'libgame.prx')).readAsStringSync(), 'relinked module');
      expect(File(p.join(game.folder, 'sce_module', 'libgame.sprx.guest.prx')).existsSync(), isTrue);
    });

    test('a relink after an engine update over a polluted dump and store heals', () async {
      final game = makeGame();
      final installed = await Installer(game: game, toolkit: Toolkit(toolkitFolder), root: root).run();
      // Outputs of a relink by hand land in the dump, a stale one in the kept relink and in the game.
      pollute(game.folder);
      final kept = Installer.keptRelink(game, root);
      File(p.join(kept, 'out', 'app0', 'sce_module', 'stale.prx.guest.prx'))
        ..createSync(recursive: true)
        ..writeAsStringSync('stale');
      File(p.join(installed, 'app0', 'sce_module', 'libSceFace.PRX.GUEST.PRX')).writeAsStringSync('stale');
      // Update from Git: another engine build, so the kept relink is not reused.
      makeFakeToolkit(toolkitFolder, version: 'toolkit-2');
      final lines = <String>[];
      await Installer(game: game, toolkit: Toolkit(toolkitFolder), root: root, onLog: lines.add).run();
      expect(lines.where((line) => line.contains('reused')), isEmpty);
      expect(fakeRelinkerInputs(toolkitFolder), [
        ['Media/Plugins/plugin.prx', 'eboot.bin', 'sce_module/libgame.sprx'],
      ]);
      final app0 = p.join(installed, 'app0');
      expect(File(p.join(app0, 'sce_module', 'stale.prx.guest.prx')).existsSync(), isFalse);
      expect(File(p.join(app0, 'sce_module', 'libSceFace.PRX.GUEST.PRX')).existsSync(), isFalse);
      expect(File(p.join(kept, 'out', 'app0', 'sce_module', 'stale.prx.guest.prx')).existsSync(), isFalse);
      expect(Installer.record(installed, system: HostSystem.linux)!.toolkit, 'toolkit-2');
      // And the next unlock with nothing changed reuses the healed relink.
      await Installer(game: game, toolkit: Toolkit(toolkitFolder), root: root, onLog: lines.add).run();
      expect(lines.where((line) => line.contains('reused')), hasLength(1));
    });

    test('an encrypted module is left out by name; the game unlocks without it', () async {
      final game = makeGame();
      File(p.join(game.folder, 'sce_module', 'libSceFace.prx')).writeAsBytesSync([9, 9, 9, 9, 9, 9, 9, 9]);
      final lines = <String>[];
      final installer = Installer(game: game, toolkit: Toolkit(toolkitFolder), root: root, onLog: lines.add);
      final installed = await installer.run();
      expect(installer.leftOut, [const LeftOutModule('sce_module/libSceFace.prx', LeftOutReason.encrypted)]);
      expect(
        lines,
        contains(
          'sce_module/libSceFace.prx in the dump is encrypted (neither an ELF nor a decrypted SELF container): '
          'it is left out, and the game is unlocked without it',
        ),
      );
      expect(fakeRelinkerInputs(toolkitFolder).single, isNot(contains('sce_module/libSceFace.prx')));
      expect(Directory(installed).existsSync(), isTrue);
    });

    // ctrl's Gran Turismo 7 report: "pdiWheel_0.prx is neither an ELF nor a decrypted SELF
    // container" stopped another launcher's unlock. Here such a module is left out and the game
    // unlocks, whether its bytes are no container at all or an encrypted SELF.
    for (final (kind, bytes) in [
      ('neither an ELF nor a SELF', [for (var index = 0; index < 4096; index++) (index * 131 + 7) & 0xFF]),
      ('a SELF that cannot be unwrapped', [0x4F, 0x15, 0x3D, 0x1D, ...List.filled(60, 0xA5)]),
    ]) {
      test('Gran Turismo 7: a pdiWheel_0.prx that is $kind is left out; the game unlocks', () async {
        final game = makeGame();
        File(p.join(game.folder, 'sce_module', 'pdiWheel_0.prx')).writeAsBytesSync(bytes);
        final lines = <String>[];
        final installer = Installer(game: game, toolkit: Toolkit(toolkitFolder), root: root, onLog: lines.add);
        final installed = await installer.run();
        expect(installer.leftOut.map((module) => (module.path, module.reason)), [
          ('sce_module/pdiWheel_0.prx', LeftOutReason.encrypted),
        ]);
        expect(lines.where((line) => line.contains('pdiWheel_0.prx') && line.contains('it is left out')), hasLength(1));
        expect(fakeRelinkerInputs(toolkitFolder).single, isNot(contains('sce_module/pdiWheel_0.prx')));
        expect(fakeRelinkerInputs(toolkitFolder).single, contains('sce_module/libgame.sprx'));
        expect(File(p.join(installed, 'app.elf')).existsSync(), isTrue);
        expect(Directory(installed).existsSync(), isTrue);
      });
    }

    test('a module the relinker cannot convert is left out and the relink runs again', () async {
      makeFakeToolkit(toolkitFolder, failOn: 'sce_module/libgame.sprx');
      final game = makeGame();
      final lines = <String>[];
      final installer = Installer(game: game, toolkit: Toolkit(toolkitFolder), root: root, onLog: lines.add);
      final installed = await installer.run();
      expect(installer.leftOut, [
        const LeftOutModule(
          'sce_module/libgame.sprx',
          LeftOutReason.notRelinked,
          'Unsupported relocation type 0x25 (offset 0x1234)',
        ),
      ]);
      expect(fakeRelinkerInputs(toolkitFolder), [
        ['Media/Plugins/plugin.prx', 'eboot.bin', 'sce_module/libgame.sprx'],
        ['Media/Plugins/plugin.prx', 'eboot.bin'],
      ]);
      expect(
        lines,
        contains(
          'sce_module/libgame.sprx: the relinker could not convert it (Unsupported relocation type 0x25 '
          '(offset 0x1234)); it is left out and the relink runs again without it',
        ),
      );
      expect(File(p.join(installed, 'app.elf')).existsSync(), isTrue);
      // Reused, the kept relink says again what it left out.
      final again = Installer(game: game, toolkit: Toolkit(toolkitFolder), root: root);
      await again.run();
      expect(again.leftOut, installer.leftOut);
      expect(fakeRelinkerInputs(toolkitFolder), hasLength(2), reason: 'not run again');
    });

    /// A dump whose [modules] are plain ELF files, those in [containers] SELF containers.
    Game makeDumpOf(String name, List<String> modules, {Set<String> containers = const {}}) {
      final folder = makeDump(root, name, titleId: 'PPSA22116', names: {'en-US': name});
      for (final module in modules) {
        final file = File(p.join(folder, p.joinAll(module.split('/'))))..parent.createSync(recursive: true);
        file.writeAsBytesSync(containers.contains(module) ? typicalSelf(seed: 3) : [...elfHead, 4, 5, 6]);
      }
      return GameLibrary.inspect(folder)!;
    }

    // Slick Daddy's Lost in Play (Desktop #144): the dump holds libc.prx and libSceNpCppWebApi.prx
    // in sce_module and again in decrypted/sce_module. The relinker stopped twice with
    // "Conflicting guest output filename", each time naming sce_module's copy, which was left out.
    // The game was unlocked with the copies from decrypted/sce_module, where the Windows relinker
    // leaves libc.prx unstarted, and stopped at its start.
    const lostInPlay = [
      'Media/Modules/Il2cppUserAssemblies.prx',
      'Media/Modules/PS5Util.prx',
      'Media/Plugins/CommonDialog.prx',
      'Media/Plugins/PSN.prx',
      'Media/Plugins/SaveData.prx',
      'Media/Plugins/Share.prx',
      'Media/Plugins/lib_burst_generated.prx',
      'Media/Plugins/libfmod.prx',
      'Media/Plugins/libfmodstudio.prx',
      'Media/Plugins/libresonanceaudio.prx',
      'decrypted/sce_module/libSceNpCppWebApi.prx',
      'decrypted/sce_module/libc.prx',
      'sce_module/libSceNpCppWebApi.prx',
      'sce_module/libc.prx',
    ];
    for (final system in HostSystem.values) {
      test('Lost in Play on ${system.name}: of the copies in decrypted/sce_module and sce_module, '
          'sce_module\'s are relinked', () async {
        makeFakeToolkit(toolkitFolder, windowsDlls: system == HostSystem.windows);
        final game = makeDumpOf(
          'Lost in Play',
          lostInPlay,
          containers: {'sce_module/libSceNpCppWebApi.prx', 'sce_module/libc.prx'},
        );
        final lines = <String>[];
        final installer = Installer(
          game: game,
          toolkit: Toolkit(toolkitFolder, system: system),
          root: root,
          onLog: lines.add,
        );
        final installed = await installer.run();
        final kept = lostInPlay.where((module) => !module.startsWith('decrypted/')).toList();
        // One run, without a conflict: nothing is left out, and nothing came from decrypted.
        expect(fakeRelinkerInputs(toolkitFolder), [
          [...kept.sublist(0, 10), 'eboot.bin', ...kept.sublist(10)],
        ]);
        expect(installer.leftOut, isEmpty);
        expect(lines.where((line) => line.contains('Conflicting')), isEmpty);
        // What upstream's guide passes for a Unity game, and the folder of eboot.bin as ever.
        final arguments = fakeRelinkerArguments(toolkitFolder);
        expect(arguments.sublist(arguments.indexOf('--module-dir'), arguments.length - 1), [
          '--module-dir',
          '.',
          '--module-dir',
          'Media/Modules',
          '--module-dir',
          'Media/Plugins',
          'eboot.bin',
        ]);
        expect(
          lines,
          containsAll([
            'decrypted/sce_module/libSceNpCppWebApi.prx: the dump has this module as '
                'sce_module/libSceNpCppWebApi.prx too, the game is unlocked with that one',
            'decrypted/sce_module/libc.prx: the dump has this module as sce_module/libc.prx too, '
                'the game is unlocked with that one',
          ]),
        );
        // The game's files are all there, the copies too; the dump is as it was.
        expect(File(p.join(installed, 'app0', 'decrypted', 'sce_module', 'libc.prx')).existsSync(), isTrue);
        expect(File(p.join(game.folder, 'decrypted', 'sce_module', 'libc.prx')).readAsBytesSync(), [
          ...elfHead,
          4,
          5,
          6,
        ]);
      });
    }

    // Lenny4250gh's report (Desktop #145): Minecraft and other dumps with modules next to
    // eboot.bin that sce_module holds too. An engine before v0.1.4 names eboot.bin in the
    // conflict, which stopped the unlock; a later one named sce_module's copy, which was left out.
    test('modules next to eboot.bin and again in sce_module: sce_module\'s are relinked, '
        'one next to eboot.bin alone still is', () async {
      final game = makeDumpOf('Minecraft', [
        'libSceFace.prx',
        'libc.prx',
        'libcohtml.Prospero.prx',
        'sce_module/libSceFace.prx',
        'sce_module/libc.prx',
      ]);
      final lines = <String>[];
      final installer = Installer(game: game, toolkit: Toolkit(toolkitFolder), root: root, onLog: lines.add);
      await installer.run();
      expect(fakeRelinkerInputs(toolkitFolder), [
        ['eboot.bin', 'libcohtml.Prospero.prx', 'sce_module/libSceFace.prx', 'sce_module/libc.prx'],
      ]);
      expect(installer.leftOut, isEmpty);
      final arguments = fakeRelinkerArguments(toolkitFolder);
      expect(arguments.sublist(1, arguments.length - 1), ['--module-dir', '.', 'eboot.bin']);
      expect(
        lines,
        contains('libc.prx: the dump has this module as sce_module/libc.prx too, the game is unlocked with that one'),
      );
    });

    test('a Unity game: one plugin that sce_module holds too costs the folder none of its others', () async {
      final game = makeDumpOf('Unity', [
        'Media/Modules/PS5Util.prx',
        'Media/Plugins/PSN.prx',
        'Media/Plugins/libfmod.prx',
        'sce_module/libc.prx',
        'sce_module/libfmod.prx',
      ]);
      final installer = Installer(game: game, toolkit: Toolkit(toolkitFolder), root: root);
      await installer.run();
      expect(fakeRelinkerInputs(toolkitFolder), [
        [
          'Media/Modules/PS5Util.prx',
          'Media/Plugins/PSN.prx',
          'eboot.bin',
          'sce_module/libc.prx',
          'sce_module/libfmod.prx',
        ],
      ]);
      final arguments = fakeRelinkerArguments(toolkitFolder);
      expect(arguments.sublist(1, arguments.length - 1), [
        '--module-dir',
        '.',
        '--module-dir',
        'Media/Modules',
        '--module-dir',
        'Media/Plugins',
        'eboot.bin',
      ]);
      expect(installer.leftOut, isEmpty);
    });

    test('a dump without a module in two places is relinked as before, each module where it is', () async {
      final game = makeDumpOf('Unity', [
        'Media/Modules/Il2cppUserAssemblies.prx',
        'Media/Plugins/PSN.prx',
        'decrypted/extra.prx',
        'sce_module/libc.prx',
        'top.prx',
      ]);
      final toolkit = Toolkit(toolkitFolder);
      final all = Installer.modules(game.folder);
      expect(Installer.modulesOf(game, HostSystem.linux), all);
      expect(Installer.modulesOf(game, HostSystem.windows), all);
      final lines = <String>[];
      await Installer(game: game, toolkit: toolkit, root: root, onLog: lines.add).run();
      expect(fakeRelinkerInputs(toolkitFolder), [
        [
          'Media/Modules/Il2cppUserAssemblies.prx',
          'Media/Plugins/PSN.prx',
          'decrypted/extra.prx',
          'eboot.bin',
          'sce_module/libc.prx',
          'top.prx',
        ],
      ]);
      final arguments = fakeRelinkerArguments(toolkitFolder);
      expect(arguments.sublist(1, arguments.length - 1), [
        '--module-dir',
        '.',
        '--module-dir',
        'Media/Modules',
        '--module-dir',
        'Media/Plugins',
        '--module-dir',
        'decrypted',
        'eboot.bin',
      ]);
      expect(lines.where((line) => line.contains('the dump has this module')), isEmpty);
    });

    test('a failed executable stops the unlock with the relinker\'s whole reason', () async {
      makeFakeToolkit(toolkitFolder, failOn: 'eboot.bin');
      final game = makeGame();
      final failure = await Installer(
        game: game,
        toolkit: Toolkit(toolkitFolder),
        root: root,
      ).run().then<Object?>((_) => null, onError: (Object error) => error);
      expect(failure, isA<ToolFailed>());
      final message = (failure! as ToolFailed).message;
      // The file as the dump has it: the work folder is gone by now.
      expect(message, 'relinker failed (2): FAIL: Unsupported relocation type 0x25 (offset 0x1234)\nInput: eboot.bin');
      expect(fakeRelinkerInputs(toolkitFolder), hasLength(1));
      expect(Directory(Installer.installedFolder(game, root)).existsSync(), isFalse);
    });

    test('games folders with spaces and letters beyond ASCII', () async {
      final spaced = p.join(temp.path, 'Oyunlar', 'PlayStation 5 Oyunları');
      final folder = makeDump(spaced, 'Kahve Molası', titleId: 'PPSA05678', names: {'en-US': 'Coffee'});
      File(p.join(folder, 'eboot.bin')).writeAsBytesSync(typicalSelf());
      File(p.join(folder, 'sce_module', 'libgame.sprx'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(typicalSelf(seed: 2));
      makeFakeToolkit(toolkitFolder, failOn: 'sce_module/libgame.sprx');
      final game = GameLibrary.inspect(folder)!;
      final installer = Installer(game: game, toolkit: Toolkit(toolkitFolder), root: spaced);
      final installed = await installer.run();
      expect(installer.leftOut.single.path, 'sce_module/libgame.sprx');
      expect(
        fakeRelinkerArguments(toolkitFolder).first,
        contains(p.join('Oyunlar', 'PlayStation 5 Oyunları', GameLibrary.storeName, 'Work')),
      );
      expect(File(p.join(installed, 'app.elf')).existsSync(), isTrue);
    });

    test('the module a failure names: inside the source tree, never the executable', () {
      ToolFailed failed(String input) =>
          ToolFailed('relinker.exe', 2, ['PRX conversion', 'FAIL: bad', 'Input: $input']);
      final source = p.join(temp.path, 'Work', '1-2', 'source');
      final modules = ['sce_module/libSceNpCppWebApi.prx', 'Media/Plugins/a.prx'];
      expect(
        Installer.failedModule(failed(p.join(source, 'sce_module', 'libSceNpCppWebApi.prx')), source, modules),
        'sce_module/libSceNpCppWebApi.prx',
      );
      expect(Installer.failedModule(failed('Media/Plugins/a.prx'), source, modules), 'Media/Plugins/a.prx');
      expect(Installer.failedModule(failed(p.join(source, 'eboot.bin')), source, modules), isNull);
      expect(Installer.failedModule(failed(p.join(temp.path, 'elsewhere.prx')), source, modules), isNull);
      expect(Installer.failedModule(ToolFailed('relinker', 2, ['FAIL: bad']), source, modules), isNull);
    });

    test('the error text: from the last FAIL line to the end, else the last line', () {
      final failure = ToolFailed('relinker.exe', 2, [
        'Instruction scan | eboot.bin | 100%',
        r'FAIL: Code analysis: branch into skipped range tail (offset 0x4a10)',
        r'Input: C:\Oyunlar\PlayStation 5\.AnyPS5\Work\1-2\source\sce_module\libSceNpCppWebApi.prx',
      ]);
      expect(
        failure.message,
        'relinker.exe failed (2): FAIL: Code analysis: branch into skipped range tail (offset 0x4a10)\n'
        r'Input: C:\Oyunlar\PlayStation 5\.AnyPS5\Work\1-2\source\sce_module\libSceNpCppWebApi.prx',
      );
      expect(failure.reason, 'Code analysis: branch into skipped range tail (offset 0x4a10)');
      expect(failure.input, r'C:\Oyunlar\PlayStation 5\.AnyPS5\Work\1-2\source\sce_module\libSceNpCppWebApi.prx');
      expect(
        ToolFailed('relinker', 2, [
          'FAIL: x',
          'Input: ${p.join(temp.path, 'source', 'sce_module', 'a.prx')}',
        ], workingDirectory: p.join(temp.path, 'source')).message,
        'relinker failed (2): FAIL: x\nInput: sce_module/a.prx',
      );
      expect(ToolFailed('relinker', 3, ['a', 'b']).message, 'relinker failed (3): b');
      expect(ToolFailed('relinker', 3, const []).message, 'relinker failed (3)');
    });
  });

  // The launcher's interface runs on the same isolate as an unlock: a copy or a removal done
  // there in one piece froze the screen (no other game could be picked, Windows called the window
  // not responding). The heavy file work goes to the system's file threads, and the event loop
  // keeps turning while it runs.
  group('off the interface thread', () {
    /// How many times a 1 ms timer fired while [work] ran: none when it held the isolate.
    Future<int> ticksDuring(Future<void> Function() work) async {
      var ticks = 0;
      final timer = Timer.periodic(const Duration(milliseconds: 1), (_) => ticks++);
      await work();
      final during = ticks;
      timer.cancel();
      return during;
    }

    test('copying a game file lets the screen go on', () async {
      final source = Directory(p.join(temp.path, 'dump'))..createSync();
      final big = File(p.join(source.path, 'big.bin')).openSync(mode: FileMode.write);
      final chunk = List<int>.filled(1 << 20, 7);
      for (var index = 0; index < 64; index++) {
        big.writeFromSync(chunk);
      }
      big.closeSync();
      final target = p.join(temp.path, 'copied');
      final fractions = <double>[];
      final ticks = await ticksDuring(
        () => Installer.copyTree(source.path, target, LinkMode.copy, progress: fractions.add),
      );
      expect(ticks, greaterThan(0));
      expect(File(p.join(target, 'big.bin')).lengthSync(), 64 << 20);
      expect(fractions.last, 1);
    });

    test('putting the new install in place of the old one lets the screen go on', () async {
      final installed = p.join(temp.path, 'Installed');
      for (var index = 0; index < 1500; index++) {
        File(p.join(installed, 'app0', 'data${index % 30}', 'file$index.bin'))
          ..createSync(recursive: true)
          ..writeAsStringSync('old');
      }
      File(p.join(installed, '_sd', 'save.dat'))
        ..createSync(recursive: true)
        ..writeAsStringSync('saved');
      final partial = '$installed.partial';
      File(p.join(partial, 'app0', 'eboot.bin'))
        ..createSync(recursive: true)
        ..writeAsStringSync('new');
      final ticks = await ticksDuring(() => Installer.placeInstalled(partial, installed));
      expect(ticks, greaterThan(0));
      expect(File(p.join(installed, 'app0', 'eboot.bin')).readAsStringSync(), 'new');
      expect(File(p.join(installed, '_sd', 'save.dat')).readAsStringSync(), 'saved', reason: 'the saves move over');
      expect(Directory(p.join(installed, 'app0', 'data0')).existsSync(), isFalse);
      expect(Directory(partial).existsSync(), isFalse);
    });

    // Issue 55: Uninstall deleted the whole game in one piece, and Windows called the launcher
    // not responding while it went.
    test('uninstalling a big game lets the screen go on', () async {
      final game = makeGame();
      final installed = await Installer(game: game, toolkit: Toolkit(toolkitFolder), root: root).run();
      for (var index = 0; index < 1500; index++) {
        File(p.join(installed, '_data', 'data${index % 30}', 'file$index.bin'))
          ..createSync(recursive: true)
          ..writeAsStringSync('written by the game');
      }
      // What an uninstall left when the launcher closed before it was done.
      final removing = Installer.removingFolder(root);
      File(p.join(removing, 'left-over', 'file.bin'))
        ..createSync(recursive: true)
        ..writeAsStringSync('old');
      final ticks = await ticksDuring(() {
        final gone = Installer.uninstall(game, root);
        expect(Directory(installed).existsSync(), isFalse, reason: 'not installed from the moment it is asked');
        expect(Directory(Installer.keptRelink(game, root)).existsSync(), isFalse);
        return gone;
      });
      expect(ticks, greaterThan(0));
      expect(Directory(removing).listSync(), isEmpty, reason: 'what was set aside is gone, and what was left');
      expect(
        File(p.join(game.folder, 'data', 'level1.bin')).readAsStringSync(),
        'level data',
        reason: 'the dump stays',
      );
    });

    test('measuring a dump to copy lets the screen go on', () async {
      final source = Directory(p.join(temp.path, 'dump'))..createSync();
      for (var index = 0; index < 1500; index++) {
        File(p.join(source.path, 'data${index % 30}', 'file$index.bin'))
          ..createSync(recursive: true)
          ..writeAsStringSync('1234');
      }
      var size = 0;
      final ticks = await ticksDuring(() async => size = await Installer.measurePayload(source.path));
      expect(ticks, greaterThan(0));
      expect(size, 1500 * 4);
      expect(size, Installer.payloadSize(source.path));
    });
  });

  group('links across volumes', () {
    // Another volume than the dump's: no hard links. What Windows does there depends on
    // Developer Mode (or an elevated launcher): symbolic links, else nothing but copies.
    final symbolic = LinkCalls(hardLink: (_, _) => false, symbolicLink: FileLinks.system.symbolicLink);
    final neither = LinkCalls(hardLink: (_, _) => false, symbolicLink: (_, _) => false);
    tearDown(() => FileLinks.calls = FileLinks.system);

    test('the probe takes a symbolic link where no hard link works, a copy only where neither does', () {
      final sample = File(p.join(temp.path, 'dump', 'eboot.bin'))
        ..createSync(recursive: true)
        ..writeAsStringSync('eboot');
      final target = p.join(temp.path, 'store');
      expect(FileLinks.probe(sample.path, target), LinkMode.hard);
      FileLinks.calls = symbolic;
      expect(FileLinks.probe(sample.path, target), LinkMode.symbolic);
      FileLinks.calls = neither;
      expect(FileLinks.probe(sample.path, target), LinkMode.copy);
      // A link made but not readable through (Windows refusing to follow it) is no link.
      FileLinks.calls = LinkCalls(
        hardLink: (_, _) => false,
        symbolicLink: (_, created) => FileLinks.system.symbolicLink(p.join(temp.path, 'nowhere'), created),
      );
      expect(FileLinks.probe(sample.path, target), LinkMode.copy);
      // The probe leaves nothing behind, and the dump is untouched.
      expect(Directory(target).listSync(), isEmpty);
      expect(sample.readAsStringSync(), 'eboot');
    });

    test('across volumes the game links to the dump: its files take no space, the relinked ones are real', () async {
      FileLinks.calls = symbolic;
      final game = makeGame();
      final lines = <String>[];
      final installed = await Installer(
        game: game,
        toolkit: Toolkit(toolkitFolder),
        root: root,
        onLog: lines.add,
      ).run();
      final app0 = p.join(installed, 'app0');
      for (final file in ['eboot.bin', 'data/level1.bin', 'sce_sys/param.json', 'sce_module/libgame.sprx']) {
        final path = p.join(app0, p.joinAll(file.split('/')));
        expect(FileSystemEntity.typeSync(path, followLinks: false), FileSystemEntityType.link, reason: file);
        expect(Link(path).targetSync(), p.join(game.folder, p.joinAll(file.split('/'))), reason: file);
      }
      expect(File(p.join(app0, 'data', 'level1.bin')).readAsStringSync(), 'level data');
      // The relinked module is a file of the game's own, the dump's module untouched.
      final relinked = p.join(app0, 'sce_module', 'libgame.prx');
      expect(FileSystemEntity.typeSync(relinked, followLinks: false), FileSystemEntityType.file);
      expect(File(relinked).readAsStringSync(), 'relinked module');
      expect(File(p.join(game.folder, 'sce_module', 'libgame.sprx')).readAsBytesSync(), typicalSelf(seed: 2));
      expect(lines, contains(contains('links to it')));
      expect(await Installer.brokenLink(installed), isNull);
    });

    test('installing again and uninstalling never write through a link into the dump', () async {
      FileLinks.calls = symbolic;
      final game = makeGame();
      // A module of the dump under the name the relinked one gets: app0 links to it first.
      final moduleInDump = File(p.join(game.folder, 'sce_module', 'libgame.prx'))..writeAsBytesSync([...elfHead, 9]);
      final installed = await Installer(game: game, toolkit: Toolkit(toolkitFolder), root: root).run();
      // The relinked module took the place of the link to the dump's module.
      final placed = p.join(installed, 'app0', 'sce_module', 'libgame.prx');
      expect(FileSystemEntity.typeSync(placed, followLinks: false), FileSystemEntityType.file);
      expect(File(placed).readAsStringSync(), 'relinked module');
      expect(moduleInDump.readAsBytesSync(), [...elfHead, 9]);
      // Placing over a link replaces the link, not what it points to.
      final level = p.join(installed, 'app0', 'data', 'level1.bin');
      final patched = File(p.join(temp.path, 'patched.bin'))..writeAsStringSync('patched');
      FileLinks.place(patched.path, level, LinkMode.copy);
      expect(File(level).readAsStringSync(), 'patched');
      expect(File(p.join(game.folder, 'data', 'level1.bin')).readAsStringSync(), 'level data');
      await Installer(game: game, toolkit: Toolkit(toolkitFolder), root: root).run();
      expect(FileSystemEntity.typeSync(level, followLinks: false), FileSystemEntityType.link);
      await Installer.uninstall(game, root);
      expect(Directory(installed).existsSync(), isFalse);
      expect(File(p.join(game.folder, 'data', 'level1.bin')).readAsStringSync(), 'level data');
      expect(File(p.join(game.folder, 'eboot.bin')).readAsBytesSync(), typicalSelf());
      expect(moduleInDump.readAsBytesSync(), [...elfHead, 9]);
    });

    test('a dump moved or emptied after the install is found before the game starts', () async {
      FileLinks.calls = symbolic;
      final game = makeGame();
      final installed = await Installer(game: game, toolkit: Toolkit(toolkitFolder), root: root).run();
      File(p.join(game.folder, 'data', 'level1.bin')).deleteSync();
      expect(await Installer.brokenLink(installed), p.join('data', 'level1.bin'));
      Directory(game.folder).renameSync('${game.folder}-moved');
      expect(await Installer.brokenLink(installed), 'eboot.bin');
      // Hard linked and copied games keep their files whatever happens to the dump.
      FileLinks.calls = FileLinks.system;
      final other = makeGame();
      final hard = await Installer(game: other, toolkit: Toolkit(toolkitFolder), root: root).run();
      Directory(other.folder).deleteSync(recursive: true);
      expect(await Installer.brokenLink(hard), isNull);
    });

    test('the plan says up front when the files would be copied and how much', () {
      final game = makeGame();
      expect(Installer.plan(game, root).mode, LinkMode.hard);
      FileLinks.calls = symbolic;
      expect(Installer.plan(game, root).copies, isFalse);
      FileLinks.calls = neither;
      final plan = Installer.plan(game, root);
      expect(plan.copies, isTrue);
      expect(plan.bytes, Installer.payloadSize(game.folder));
      expect(plan.bytes, greaterThan(0));
      expect(Installer.plan(game, root, knownSize: 42).bytes, 42);
    });

    test('where neither link works the game is copied, and says why', () async {
      FileLinks.calls = neither;
      final game = makeGame();
      final lines = <String>[];
      final installed = await Installer(
        game: game,
        toolkit: Toolkit(toolkitFolder),
        root: root,
        onLog: lines.add,
      ).run();
      final level = p.join(installed, 'app0', 'data', 'level1.bin');
      expect(FileSystemEntity.typeSync(level, followLinks: false), FileSystemEntityType.file);
      expect(lines, contains(contains('Developer Mode')));
    });
  });

  group('starting', () {
    test('the game starts in its folder with the environment, its output appended to the log', () async {
      final game = makeGame();
      final installed = await Installer(game: game, toolkit: Toolkit(toolkitFolder), root: root).run();
      final log = p.join(temp.path, 'logs', 'PPSA01234.log');
      for (var run = 0; run < 2; run++) {
        final running = await GameProcess.start(
          installed: installed,
          system: HostSystem.linux,
          environment: {'ANYPS5_LANGUAGE': '19', 'ANYPS5_OVERLAY': '1'},
          logFile: log,
          arguments: ['--test'],
        );
        expect(await running.exitCode, 0);
      }
      final text = File(log).readAsStringSync();
      expect(RegExp('relinked game --test').allMatches(text), hasLength(2));
      expect(text, contains('ANYPS5_LANGUAGE=19'));
      expect(text, contains('ANYPS5_OVERLAY=1'));
      expect(text, contains(p.basename(installed)));
      expect(text, contains('--- exit 0'));
    });

    test('a game that is not installed does not start', () async {
      expect(
        () => GameProcess.start(
          installed: p.join(temp.path, 'none'),
          environment: const {},
          logFile: p.join(temp.path, 'l'),
        ),
        throwsA(isA<ProcessException>()),
      );
    });
  });

  group('parts', () {
    test('modules: .prx and .sprx outside sce_sys, three levels at most', () {
      final folder = makeDump(
        root,
        'M',
        files: {
          'sce_module/libc.prx': '',
          'sce_module/libSceFios2.sprx': '',
          'sce_sys/about/right.sprx': '',
          'Media/Plugins/a.prx': '',
          'Media/Plugins/deeper/b.prx': '',
          'top.PRX': '',
          'notes.txt': '',
          '.hidden/c.prx': '',
        },
      );
      expect(Installer.modules(folder), [
        'Media/Plugins/a.prx',
        'sce_module/libSceFios2.sprx',
        'sce_module/libc.prx',
        'top.PRX',
      ]);
    });

    test('module directories: the parent, then folders other than the standard ones and fakelib', () {
      expect(
        Installer.moduleDirectories([
          'Media/Modules/x.prx',
          'Media/Plugins/a.prx',
          'Media/Plugins/b.prx',
          'fakelib/libc.prx',
          'prx/y.prx',
          'sce_module/libc.prx',
          'sce_modules/z.prx',
          'Media/Other/x.sprx',
          'top.prx',
        ]),
        ['.', 'Media/Modules', 'Media/Plugins'],
      );
    });

    test('a module in several folders: the standard folder\'s copy, else the one next to eboot.bin, '
        'else the nearest', () {
      Map<String, String> duplicates(List<String> modules, {bool foldCase = false}) =>
          Installer.duplicateModules(modules, foldCase: foldCase);
      // A dumper's folder beside sce_module, a backup folder, a copy next to eboot.bin.
      expect(
        duplicates([
          'backup/libc.prx',
          'decrypted/sce_module/libc.prx',
          'libc.prx',
          'sce_module/libc.prx',
          'sce_module/libSceFios2.sprx',
        ]),
        {
          'backup/libc.prx': 'sce_module/libc.prx',
          'decrypted/sce_module/libc.prx': 'sce_module/libc.prx',
          'libc.prx': 'sce_module/libc.prx',
        },
      );
      // sce_module before prx, any standard folder before the rest.
      expect(duplicates(['Media/Plugins/a.prx', 'prx/a.prx', 'sce_module/a.prx']), {
        'Media/Plugins/a.prx': 'sce_module/a.prx',
        'prx/a.prx': 'sce_module/a.prx',
      });
      expect(duplicates(['Media/Plugins/a.prx', 'prx/a.prx']), {'Media/Plugins/a.prx': 'prx/a.prx'});
      // In no standard folder: next to eboot.bin, then the nearest folder, then the first by name.
      expect(duplicates(['Media/Plugins/a.prx', 'a.prx', 'old/a.prx']), {
        'Media/Plugins/a.prx': 'a.prx',
        'old/a.prx': 'a.prx',
      });
      expect(duplicates(['Media/Plugins/a.prx', 'old/a.prx']), {'Media/Plugins/a.prx': 'old/a.prx'});
      expect(duplicates(['Media/Modules/a.prx', 'Media/Plugins/a.prx', 'Media/Plugins/b.prx']), {
        'Media/Plugins/a.prx': 'Media/Modules/a.prx',
      });
      // A module in one place alone stays, wherever it is, and a name is a whole file name.
      expect(
        duplicates([
          'Media/Modules/x.prx',
          'Media/Plugins/y.prx',
          'decrypted/sce_module/only.prx',
          'sce_module/x.sprx',
          'top.prx',
        ]),
        isEmpty,
      );
      // Folders the relinker never reads are no one's copy: fakelib, one below sce_module, one
      // with no .prx in it.
      expect(
        duplicates(['Media/Other/libc.sprx', 'fakelib/libc.prx', 'sce_module/libc.prx', 'sce_module/old/libc.prx']),
        isEmpty,
      );
      // The Windows relinker tells names apart without their case, the Linux one with it.
      expect(duplicates(['Media/Plugins/LibFmod.prx', 'sce_module/libfmod.prx']), isEmpty);
      expect(duplicates(['Media/Plugins/LibFmod.prx', 'sce_module/libfmod.prx'], foldCase: true), {
        'Media/Plugins/LibFmod.prx': 'sce_module/libfmod.prx',
      });
      // The folders that go to the relinker are those of what is left.
      expect(Installer.moduleDirectories(['Media/Plugins/a.prx', 'sce_module/libc.prx']), ['.', 'Media/Plugins']);
      expect(Installer.moduleDirectories(['sce_module/libc.prx']), ['.']);
    });

    test('relink progress rises through the phases and never goes back', () {
      final progress = RelinkProgress();
      expect(progress.read('Instruction scan | eboot.bin | 50%'), closeTo(0.1, 1e-9));
      expect(progress.read('Instruction scan | libc.prx | 90%'), isNull);
      expect(progress.read('Instruction conversion | eboot.bin | 100%'), closeTo(0.45, 1e-9));
      expect(progress.read('Instruction scan | eboot.bin | 100%'), isNull, reason: 'lower than reached');
      expect(progress.read('Syscall scan | eboot.bin | 100%'), closeTo(0.55, 1e-9));
      expect(progress.read('PRX conversion | x.prx | 100% (3/6)'), closeTo(0.7, 1e-9));
      expect(progress.read('Output image | eboot.bin | 100%'), closeTo(0.95, 1e-9));
      expect(progress.read('Write output | eboot.bin | 100%'), closeTo(1, 1e-9));
      expect(progress.read('Some line without fields'), isNull);
    });

    test('output collector: lines, carriage-return rewrites, a last line without newline', () {
      final logged = <String>[];
      final statuses = <String>[];
      final collector = OutputCollector(log: logged.add, status: statuses.add);
      collector.add(utf8.encode('first\nprogress 1\rprogress 2\rprog'));
      collector.add(utf8.encode('ress 3\nlast'));
      collector.flush();
      expect(logged, ['first', 'progress 3', 'last']);
      expect(statuses, ['first', 'progress 1', 'progress 2', 'progress 3']);
      expect(collector.lines, ['first', 'progress 3', 'last']);
    });

    test('placing over a hard link never writes through to the dump', () {
      final dump = File(p.join(temp.path, 'dump.bin'))..writeAsStringSync('original');
      final linked = p.join(temp.path, 'linked.bin');
      expect(FileLinks.hardLink(dump.path, linked), isTrue);
      final relinked = File(p.join(temp.path, 'relinked.bin'))..writeAsStringSync('relinked');
      FileLinks.place(relinked.path, linked, LinkMode.copy);
      expect(File(linked).readAsStringSync(), 'relinked');
      expect(dump.readAsStringSync(), 'original');
      expect(FileLinks.hardLink(p.join(temp.path, 'missing'), p.join(temp.path, 'x')), isFalse);
    });

    test('the installed folder name: title ID letters and digits, and a hash of the dump path', () {
      final a = Game(
        folder: '/games/A',
        titleId: 'PPSA-01234',
        name: 'A',
        names: const {},
        defaultLanguage: 'en-US',
        version: '1',
        executable: ExecutableKind.elf,
      );
      final b = Game(
        folder: '/games/B',
        titleId: 'PPSA-01234',
        name: 'B',
        names: const {},
        defaultLanguage: 'en-US',
        version: '1',
        executable: ExecutableKind.elf,
      );
      final first = Installer.installedFolder(a, '/games');
      expect(first, startsWith(p.join('/games', '.AnyPS5', 'Games', 'PPSA01234-')));
      expect(Installer.installedFolder(a, '/games'), first, reason: 'stable');
      expect(Installer.installedFolder(b, '/games'), isNot(first));
      // The same FNV-1a as the macOS launcher: 64-bit, low 24 bits in hex.
      var hash = 0xCBF29CE484222325;
      for (final byte in utf8.encode('/games/A')) {
        hash = (hash ^ byte) * 0x100000001B3;
      }
      expect(p.basename(first), 'PPSA01234-${(hash & 0xFFFFFF).toRadixString(16)}');
    });
  });

  group('toolkit and paths', () {
    test('locate takes ANYPS5_TOOLKIT first, then the first usable candidate', () {
      final empty = p.join(temp.path, 'empty');
      Directory(empty).createSync();
      expect(Toolkit.locate([empty, toolkitFolder], environment: const {})!.root, toolkitFolder);
      expect(Toolkit.locate([empty], environment: {'ANYPS5_TOOLKIT': toolkitFolder})!.root, toolkitFolder);
      expect(Toolkit.locate([empty], environment: const {}), isNull);
      expect(Toolkit(empty).problem, ToolkitProblem.noRelinker);
      expect(Toolkit(toolkitFolder).version, 'toolkit-1');
      expect(Toolkit(empty).version, 'unknown');
      expect(Toolkit(toolkitFolder).libraryFiles.map(p.basename), ['libSceVideoOut.prx', 'libkernel.prx']);
    });

    test('a folder put together without version.txt is named by its files; rebuilt, the name changes', () {
      final own = makeFakeToolkit(p.join(temp.path, 'own'));
      File(p.join(own, 'version.txt')).deleteSync();
      final first = Toolkit(own).version;
      expect(first, matches(RegExp(r'^local-[0-9a-f]{12}$')));
      expect(Toolkit(own).version, first, reason: 'the same files, the same name');
      File(p.join(own, 'libs', 'libkernel.prx')).writeAsStringSync('kernel library, built again');
      expect(Toolkit(own).version, allOf(startsWith('local-'), isNot(first)));
      File(p.join(own, 'libs', 'README.txt')).writeAsStringSync('still not a library, longer now');
      final second = Toolkit(own).version;
      File(p.join(own, 'libs', 'README.txt')).writeAsStringSync('changed again');
      expect(Toolkit(own).version, second, reason: 'only the relinker, the libraries and the patches count');
    });

    test('app paths follow XDG on Linux and APPDATA on Windows', () {
      final linux = AppPaths.forSystem(HostSystem.linux, environment: {'HOME': '/home/u', 'XDG_CONFIG_HOME': '/cfg'});
      expect(linux.config, '/cfg/AnyPS5');
      expect(linux.logs, '/home/u/.local/state/AnyPS5/logs');
      expect(linux.cache, '/home/u/.cache/AnyPS5');
      expect(linux.shaderCache('ppsa01234'), '/home/u/.cache/AnyPS5/ppsa01234/shader_cache');
      expect(linux.toolkits, '/home/u/.local/share/AnyPS5/Toolkits');
      final xdgData = AppPaths.forSystem(HostSystem.linux, environment: {'HOME': '/home/u', 'XDG_DATA_HOME': '/data'});
      expect(xdgData.toolkits, '/data/AnyPS5/Toolkits');
      final windows = AppPaths.forSystem(
        HostSystem.windows,
        environment: {
          'USERPROFILE': r'C:\Users\u',
          'APPDATA': r'C:\Users\u\AppData\Roaming',
          'LOCALAPPDATA': r'C:\Users\u\AppData\Local',
        },
      );
      expect(windows.config, r'C:\Users\u\AppData\Roaming\AnyPS5');
      expect(windows.logs, r'C:\Users\u\AppData\Local\AnyPS5\Logs');
      expect(windows.pictures, r'C:\Users\u\Pictures\AnyPS5');
      expect(windows.toolkits, r'C:\Users\u\AppData\Local\AnyPS5\Toolkits');
    });
  });
}
