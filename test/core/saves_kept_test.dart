import 'dart:io';

import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/installer.dart';
import 'package:anyps5_desktop/core/relinker_flags.dart';
import 'package:anyps5_desktop/core/toolkit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_toolkit.dart';
import '../support/fixtures.dart';
import '../support/self_builder.dart';

/// A game's saves and trophies live in the installation the launcher builds, so whatever removes
/// or replaces an installation has to leave them: Remove installation keeps them in the store as
/// Delete game does, every rebuild carries them into the new one, and one that is interrupted or
/// fails leaves them where the next unlock finds them.
void main() {
  late Directory temp;
  late String root;
  late String toolkitFolder;

  setUp(() {
    temp = temporaryFolder('saves');
    root = p.join(temp.path, 'Games');
    toolkitFolder = makeFakeToolkit(p.join(temp.path, 'toolkit'));
  });
  tearDown(() => temp.deleteSync(recursive: true));

  Game makeGame() {
    final folder = makeDump(root, 'Astro', titleId: 'PPSA01234', files: {'data/level1.bin': 'level data'});
    File(p.join(folder, 'eboot.bin')).writeAsBytesSync(typicalSelf());
    return GameLibrary.inspect(folder)!;
  }

  void write(String path, String text) => File(path)
    ..createSync(recursive: true)
    ..writeAsStringSync(text);

  String read(String path) => File(path).readAsStringSync();

  /// What a player has in an installed game: saves, save memory, trophies, another profile's
  /// parked saves, whose are in place, and the game's download data.
  const played = {
    '_sd/slot1/save.dat': 'forty hours',
    '_sd_mem/u1/slot0.bin': 'memory',
    '_trophy/268435456_0.txt': '12 1',
    '_profiles/second/_sd/save.dat': 'another player',
    '.anyps5-profile': 'first',
    'download0/settings.bin': 'downloaded',
  };

  void play(String installed) {
    for (final MapEntry(key: relative, value: text) in played.entries) {
      write(p.joinAll([installed, ...relative.split('/')]), text);
    }
  }

  void expectPlayed(String folder, {String? reason}) {
    for (final MapEntry(key: relative, value: text) in played.entries) {
      final file = File(p.joinAll([folder, ...relative.split('/')]));
      expect(file.existsSync(), isTrue, reason: '$relative ${reason ?? 'is there'}');
      expect(file.readAsStringSync(), text, reason: relative);
    }
  }

  Future<String> install(Game game, {List<RelinkerFlag> flags = const [], List<String> custom = const []}) => Installer(
    game: game,
    toolkit: Toolkit(toolkitFolder),
    root: root,
    relinkerFlags: flags,
    customRelinkerOptions: custom,
  ).run();

  group('Remove installation', () {
    test('keeps the saves, trophies and download data in the store, and the next unlock takes them back', () async {
      final game = makeGame();
      final installed = await install(game);
      play(installed);
      Directory(p.join(installed, 'download1')).createSync();

      await Installer.uninstall(game, root);
      expect(Directory(installed).existsSync(), isFalse, reason: 'the installation is gone');
      final kept = Installer.keptSaves(installed);
      expect(kept, p.join(root, GameLibrary.storeName, 'Saves', p.basename(installed)));
      expectPlayed(kept, reason: 'is kept');
      expect(Directory(kept).listSync().map((entry) => p.basename(entry.path)).toSet(), {
        '_sd',
        '_sd_mem',
        '_trophy',
        '_profiles',
        '.anyps5-profile',
        'download0',
      }, reason: 'only what is the player\'s own, and no empty folder');
      expect(Directory(Installer.removingFolder(root)).listSync(), isEmpty);
      expect(read(p.join(game.folder, 'data', 'level1.bin')), 'level data', reason: 'the dump stays');

      final again = await install(game);
      expect(again, installed);
      expectPlayed(installed, reason: 'is back');
      expect(Directory(kept).existsSync(), isFalse, reason: 'nothing left to keep');
    });

    test('removed twice with saves each time: both are kept, the older never written over', () async {
      final game = makeGame();
      final installed = await install(game);
      write(p.join(installed, '_sd', 'save.dat'), 'first run');
      await Installer.uninstall(game, root);
      // Installed again by hand without the launcher's unlock, so the kept ones are still there.
      write(p.join(installed, 'app.elf'), 'relinked');
      write(p.join(installed, '_sd', 'save.dat'), 'second run');
      await Installer.uninstall(game, root);
      final kept = Installer.keptSaves(installed);
      expect(read(p.join(kept, '_sd', 'save.dat')), 'first run');
      final beside = Directory(kept).listSync().where((entry) => p.basename(entry.path).startsWith('_sd.')).single;
      expect(read(p.join(beside.path, 'save.dat')), 'second run');
    });

    test('saves that cannot be kept: nothing is removed and the game stays installed', () async {
      final game = makeGame();
      final installed = await install(game);
      play(installed);
      // Where the kept saves go is taken by a file.
      write(p.join(root, GameLibrary.storeName, 'Saves'), 'in the way');
      expect(() => Installer.uninstall(game, root), throwsA(isA<FileSystemException>()));
      expectPlayed(installed, reason: 'stays in the game');
      expect(Installer.record(installed, system: HostSystem.linux), isNotNull, reason: 'still installed');
      expect(Directory(Installer.removingFolder(root)).existsSync(), isFalse, reason: 'nothing was set aside');
    });

    test('a part that cannot be moved after others were: those go back, the game is as it was', () async {
      final game = makeGame();
      final installed = await install(game);
      play(installed);
      // The trophies cannot be read, so they cannot be told from an empty folder.
      Process.runSync('chmod', ['000', p.join(installed, '_trophy')]);
      addTearDown(() => Process.runSync('chmod', ['755', p.join(installed, '_trophy')]));
      expect(() => Installer.uninstall(game, root), throwsA(isA<FileSystemException>()));
      Process.runSync('chmod', ['755', p.join(installed, '_trophy')]);
      expectPlayed(installed, reason: 'is back in the game');
      final kept = Directory(Installer.keptSaves(installed));
      expect(kept.existsSync() ? kept.listSync() : const <FileSystemEntity>[], isEmpty);
    }, skip: Platform.isWindows ? 'no chmod' : null);
  });

  group('a rebuild keeps the saves', () {
    test('after an engine change', () async {
      final game = makeGame();
      final installed = await install(game);
      play(installed);
      makeFakeToolkit(toolkitFolder, version: 'toolkit-2');
      await install(game);
      expect(Installer.record(installed, system: HostSystem.linux)!.toolkit, 'toolkit-2');
      expectPlayed(installed);
    });

    test('with another engine altogether (a game\'s own engine, a checkout built again)', () async {
      final game = makeGame();
      final installed = await install(game);
      play(installed);
      final other = makeFakeToolkit(p.join(temp.path, 'other-engine'), version: 'upstream-v0.1.3');
      await Installer(game: game, toolkit: Toolkit(other), root: root).run();
      expect(Installer.record(installed, system: HostSystem.linux)!.toolkit, 'upstream-v0.1.3');
      expectPlayed(installed);
    });

    test('after the relinker options change', () async {
      final game = makeGame();
      makeFakeToolkit(toolkitFolder, traceImports: true);
      final installed = await install(game);
      play(installed);
      await install(game, flags: [RelinkerFlag.traceImports], custom: ['--exclude-sce-module', 'libx.sprx']);
      final record = Installer.record(installed, system: HostSystem.linux)!;
      expect(record.relinkerFlags, ['--trace-imports']);
      expect(record.customRelinkerOptions, ['--exclude-sce-module', 'libx.sprx']);
      expectPlayed(installed);
    });

    test('after an update is added', () async {
      final game = makeGame();
      final installed = await install(game);
      play(installed);
      final update = makeDump(root, 'Astro-UPDATE', titleId: 'PPSA01234', version: '01.005.000');
      File(p.join(update, 'eboot.bin')).writeAsBytesSync(typicalSelf(seed: 3));
      final updated = GameLibrary.scan(root).single;
      expect(updated.update?.version, '01.005.000');
      expect(Installer.installedFolder(updated, root), installed, reason: 'the same installation');
      await install(updated);
      expect(Installer.record(installed, system: HostSystem.linux)!.update, '01.005.000');
      expectPlayed(installed);
    });

    test('a rebuild that fails leaves the game and its saves as they were', () async {
      final game = makeGame();
      final installed = await install(game);
      play(installed);
      makeFakeToolkit(toolkitFolder, mode: 'fail', version: 'toolkit-2');
      await expectLater(install(game), throwsA(isA<InstallError>()));
      expect(Installer.record(installed, system: HostSystem.linux)!.toolkit, 'toolkit-1');
      expectPlayed(installed);
    });
  });

  group('a rebuild that does not finish', () {
    test('the new one cannot take its place: the saves wait in the store and come back', () async {
      final game = makeGame();
      final installed = Installer.installedFolder(game, root);
      final kept = Installer.keptSaves(installed);
      play(kept);
      final partial = '$installed.partial';
      write(p.join(partial, 'app.elf'), 'relinked');
      // Something that is no folder is where the game goes.
      write(installed, 'in the way');
      await expectLater(Installer.placeInstalled(partial, installed), throwsA(isA<FileSystemException>()));
      expectPlayed(kept, reason: 'waits in the store, out of the half-made game');
      File(installed).deleteSync();
      Directory(partial).deleteSync(recursive: true);

      await install(game);
      expectPlayed(installed, reason: 'is back');
    });

    test('the launcher closed while the new one took the old one\'s place: the next unlock has the saves', () async {
      final game = makeGame();
      final installed = await install(game);
      // As it is left when the launcher goes between the saves moving over and the swap.
      play('$installed.partial');
      makeFakeToolkit(toolkitFolder, version: 'toolkit-2');
      await install(game);
      expect(Installer.record(installed, system: HostSystem.linux)!.toolkit, 'toolkit-2');
      expectPlayed(installed);
    });

    test('the same with the old one already gone: they wait in the store', () async {
      final game = makeGame();
      final installed = Installer.installedFolder(game, root);
      play('$installed.partial');
      await install(game);
      expectPlayed(installed);
      expect(Directory(Installer.keptSaves(installed)).existsSync(), isFalse);
    });

    test('removeLeftovers takes the saves out of a half-made game before it removes it', () async {
      final game = makeGame();
      final installed = await install(game);
      play('$installed.partial');
      write(p.join('$installed.partial', 'app0', 'data.bin'), 'half made');
      Installer.removeLeftovers(root);
      expect(Directory('$installed.partial').existsSync(), isFalse);
      expectPlayed(installed, reason: 'is back in the game that is still there');

      // With no game left to take them, they wait where the next unlock looks.
      await Installer.uninstall(game, root);
      final kept = Installer.keptSaves(installed);
      Directory(kept).renameSync('$installed.partial');
      Installer.removeLeftovers(root);
      expect(Directory('$installed.partial').existsSync(), isFalse);
      expectPlayed(kept);
    });
  });
}
