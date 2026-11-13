import 'dart:async';
import 'dart:io';

import 'package:anyps5_desktop/core/file_links.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/installer.dart';
import 'package:anyps5_desktop/core/relinker_flags.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:anyps5_desktop/core/save_backup.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_toolkit.dart';
import '../support/fixtures.dart';
import '../support/self_builder.dart';
import '../support/ui_support.dart';

/// The launcher's state machine with the fake toolkit: installs, failures, the queue, updates
/// and a game started and ended.
void main() {
  late Fixture fixture;
  late AppModel model;

  setUp(() {
    fixture = makeFixture();
    model = fixture.model;
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

  int indexOf(String titleId) => model.games.indexWhere((game) => game.titleId == titleId);

  test('a failed install shows the relinker message; trying again starts over', () async {
    makeFakeToolkit(fixture.toolkit, mode: 'fail');
    final game = model.games[indexOf('PPSA02002')];
    File(p.join(game.folder, 'eboot.bin')).writeAsBytesSync(typicalSelf());
    model.primaryAction(game);
    expect(model.stateOf(game), isA<Installing>());
    await until(() => model.stateOf(game) is Failed);
    expect((model.stateOf(game) as Failed).message, 'relinker failed (3): relink: unsupported relocation');
    expect(model.toast, startsWith(T.text('unlockFailed')));
    makeFakeToolkit(fixture.toolkit);
    model.primaryAction(game);
    await until(() => model.stateOf(game) is Installed);
    expect(model.records[game.id]!.toolkit, 'toolkit-1');
  });

  test('a relinker option chosen for a game reaches its rebuild and its record', () async {
    makeFakeToolkit(fixture.toolkit, traceImports: true);
    final game = model.games[indexOf('PPSA02002')];
    File(p.join(game.folder, 'eboot.bin')).writeAsBytesSync(typicalSelf());
    model.saveSettings(game, model.currentSettings(game).withRelinkerFlag(RelinkerFlag.traceImports, true));
    model.primaryAction(game);
    await until(() => model.stateOf(game) is Installed);
    expect(fakeRelinkerRuns(fixture.toolkit).single, startsWith('--trace-imports'));
    expect(model.records[game.id]!.relinkerFlags, ['--trace-imports']);
  });

  test('a second game waits its turn and can leave the queue', () async {
    makeFakeToolkit(fixture.toolkit, mode: 'slow');
    final first = model.games[indexOf('PPSA02002')];
    final second = model.games[indexOf('PPSA03003')];
    for (final game in [first, second]) {
      File(p.join(game.folder, 'eboot.bin')).writeAsBytesSync(typicalSelf());
    }
    model.unlock(first);
    model.unlock(second);
    expect(model.stateOf(first), isA<Installing>());
    expect(model.stateOf(second), isA<Queued>());
    model.primaryAction(second);
    expect(model.stateOf(second), isA<Locked>(), reason: 'cancelled while queued');
    await until(() => model.progress[first.id]?.$1 == InstallStep.relink);
    model.cancelUnlock(first);
    await until(() => model.stateOf(first) is Locked);
    expect(model.failures, isEmpty, reason: 'a cancel is not a failure');
  });

  test('a game made with an older toolkit is rebuilt before it starts, not started as it is', () async {
    final orbit = model.games[indexOf('PPSA01001')];
    File(p.join(orbit.folder, 'eboot.bin')).writeAsBytesSync(typicalSelf());
    expect(model.stateOf(orbit), isA<Installed>().having((state) => state.outdated, 'outdated', isFalse));
    expect(model.needsRebuild(orbit), isFalse);
    makeFakeToolkit(fixture.toolkit, version: 'toolkit-2');
    // The toolkit is read again with the library (or when the launcher comes back in front), not
    // on every frame.
    model.rescan();
    expect(model.stateOf(orbit), isA<Installed>().having((state) => state.outdated, 'outdated', isTrue));
    expect(model.needsRebuild(orbit), isTrue);
    expect(model.records[orbit.id]!.toolkit, 'toolkit-1');
    model.primaryAction(orbit);
    expect(model.overlay, isNull, reason: 'no question: the stale copy is rebuilt');
    expect(model.toast, 'Orbit Runner was made with another engine. Rebuilding it first');
    expect(model.starting, isNull, reason: 'the stale copy did not start');
    expect(model.afterRebuild?.$1, orbit.id, reason: 'the start waits on the rebuild');
    expect(model.queue.contains(orbit.id) || model.progress.containsKey(orbit.id), isTrue);
    // What waits goes on once the copy is the new engine's (the start itself is the next test's).
    var went = false;
    model.afterRebuild = (orbit.id, () => went = true);
    await until(() => went);
    expect(model.records[orbit.id]!.toolkit, 'toolkit-2');
    expect(model.needsRebuild(orbit), isFalse);
    expect(model.afterRebuild, isNull);
  });

  test('a rebuild that is cancelled or fails starts nothing, and the copy can still be played as it is', () async {
    final orbit = model.games[indexOf('PPSA01001')];
    File(p.join(orbit.folder, 'eboot.bin')).writeAsBytesSync(typicalSelf());
    makeFakeToolkit(fixture.toolkit, mode: 'slow', version: 'toolkit-2');
    model.rescan();
    var went = false;
    model.rebuildFirst(orbit, () => went = true);
    expect(model.afterRebuild?.$1, orbit.id);
    model.cancelUnlock(orbit);
    expect(model.afterRebuild, isNull);
    await until(() => model.stateOf(orbit) is Installed);
    expect(went, isFalse);

    makeFakeToolkit(fixture.toolkit, mode: 'fail', version: 'toolkit-3');
    model.rescan();
    model.rebuildFirst(orbit, () => went = true);
    await until(() => model.stateOf(orbit) is Failed);
    expect(went, isFalse);
    expect(model.afterRebuild, isNull);
    // The copy is still there: Play offers to try again or to play it as it is.
    model.select(indexOf('PPSA01001'));
    model.primaryAction(orbit);
    expect(model.overlay, Layer.updateChoice);
    expect(model.panelCategories().single.rows.map((row) => row.id), ['update', 'play']);
  });

  test('playing writes the input file, passes the environment and ends with the game', () async {
    final orbit = model.games[indexOf('PPSA01001')];
    final installed = Installer.installedFolder(orbit, model.root!);
    File(p.join(installed, 'app.elf')).writeAsStringSync('#!/bin/sh\nenv | grep ^ANYPS5_ | sort\nsleep 0.3\n');
    if (!Platform.isWindows) Process.runSync('chmod', ['755', p.join(installed, 'app.elf')]);
    final playing = model.play(orbit);
    expect(model.stateOf(orbit), isA<Starting>());
    await until(() => model.stateOf(orbit) is Running);
    await playing;
    expect(model.stateOf(orbit), isA<Installed>());
    final log = File(model.paths.logFile(orbit.titleId)).readAsStringSync();
    expect(log, contains('ANYPS5_LANGUAGE=1'));
    expect(log, contains('ANYPS5_INPUT_CONFIG=${p.join(model.paths.inputFilesFolder, '${orbit.slug}.ini')}'));
    expect(log, contains('ANYPS5_SHADER_CACHE_DIR=${model.paths.shaderCache(orbit.slug)}'));
    expect(
      File(p.join(model.paths.inputFilesFolder, '${orbit.slug}.ini')).readAsStringSync(),
      contains('Cross = KEY:K'),
    );
    expect(model.preferences.lastPlayed, contains(orbit.id));
  });

  test('saves are backed up and restored from the game settings', () {
    final orbit = model.games[indexOf('PPSA01001')];
    final installed = Installer.installedFolder(orbit, model.root!);
    File(p.join(installed, '_sd', 'save.dat'))
      ..createSync(recursive: true)
      ..writeAsStringSync('one');
    model.select(indexOf('PPSA01001'));
    model.open(Layer.gameSettings);
    final backup = model.panelCategories().single.rows.firstWhere((row) => row.id == 'backup');
    (backup.kind as ActionRow).run();
    expect(model.toast, T.text('savesBackedUp'));
    File(p.join(installed, '_sd', 'save.dat')).writeAsStringSync('two');
    final restore = model.panelCategories().single.rows.firstWhere((row) => row.id == 'restore');
    (restore.kind as ActionRow).run();
    expect(File(p.join(installed, '_sd', 'save.dat')).readAsStringSync(), 'one');
    expect(model.toast, T.text('savesRestored'));
  });

  test('Restore saves… takes the backup the user picks, with the current saves backed up first', () async {
    String? picked;
    final own = makeFixture(pickFile: (label, extensions) async => picked);
    addTearDown(own.dispose);
    addTearDown(own.model.dispose);
    final launcher = own.model;
    final orbit = launcher.games.firstWhere((game) => game.titleId == 'PPSA01001');
    final installed = Installer.installedFolder(orbit, launcher.root!);
    File(p.join(installed, '_sd', 'save.dat'))
      ..createSync(recursive: true)
      ..writeAsStringSync('one');
    launcher.select(launcher.games.indexOf(orbit));
    launcher.open(Layer.gameSettings);
    (launcher.panelCategories().single.rows.firstWhere((row) => row.id == 'backup').kind as ActionRow).run();
    final backups = SaveBackup.backups(launcher.backupFolder(orbit));
    expect(backups, hasLength(1));
    final older = backups.single;
    File(p.join(installed, '_sd', 'save.dat')).writeAsStringSync('two');
    // Nothing picked: nothing happens.
    PanelRow restore() => launcher.panelCategories().single.rows.firstWhere((row) => row.id == 'restoreChoose');
    (restore().kind as ActionRow).run();
    await Future<void>.delayed(Duration.zero);
    expect(File(p.join(installed, '_sd', 'save.dat')).readAsStringSync(), 'two');
    expect(restore().title, T.text('restoreSaves'));
    picked = older;
    await launcher.restoreChosenSaves(orbit);
    expect(File(p.join(installed, '_sd', 'save.dat')).readAsStringSync(), 'one');
    expect(launcher.toast, T.text('savesRestored'));
    expect(SaveBackup.backups(launcher.backupFolder(orbit)), hasLength(2), reason: 'the current saves were kept first');
  });

  test('a dump copied into the games folder shows up on its own', () async {
    model.watchGamesFolders();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    makeDump(model.root!, 'late', titleId: 'PPSA09009', names: {'en-US': 'Late Arrival'});
    await until(() => model.games.any((game) => game.titleId == 'PPSA09009'));
    expect(model.games, hasLength(5));
  });

  group('a new game in the games folder', () {
    late List<(String, String)> notices;
    late Directory staging;

    setUp(() {
      notices = [];
      model.desktopNotify = (title, body) => notices.add((title, body));
      staging = Directory(p.join(fixture.temp.path, 'staging'))..createSync();
    });

    /// A dump copied the way a big copy lands: its folder, a while later sce_sys, then eboot.bin.
    Future<String> copyInSteps(String parent, String name, String titleId, String title) async {
      final source = makeDump(staging.path, name, titleId: titleId, names: {'en-US': title}, pictures: ['icon0.png']);
      final folder = p.join(parent, name);
      Directory(folder).createSync(recursive: true);
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      Directory(p.join(folder, 'sce_sys')).createSync();
      for (final file in Directory(p.join(source, 'sce_sys')).listSync().whereType<File>()) {
        file.copySync(p.join(folder, 'sce_sys', p.basename(file.path)));
      }
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      File(p.join(source, 'eboot.bin')).copySync(p.join(folder, 'eboot.bin'));
      return folder;
    }

    test('copied into a subfolder in steps, it shows up, is selected and announced', () async {
      model.watchGamesFolders();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final folder = await copyInSteps(p.join(model.root!, 'More', 'Games'), 'late', 'PPSA09019', 'Late Arrival');
      await until(() => model.games.any((game) => game.titleId == 'PPSA09019'));
      expect(model.toast, T.format('newGame', ['Late Arrival']));
      expect(model.toastIcon, p.join(folder, 'sce_sys', 'icon0.png'));
      expect(model.selectedGame?.titleId, 'PPSA09019', reason: 'on the home screen the new game is selected');
      expect(notices, isEmpty, reason: 'the launcher is in front: its own toast is enough');
    });

    test('with the launcher in the background a desktop notice says it too', () async {
      model.watchGamesFolders();
      model.setActive(false);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      makeDump(model.root!, 'late', titleId: 'PPSA09029', names: {'en-US': 'Night Shift'});
      await until(() => notices.isNotEmpty);
      expect(notices.single, (T.format('newGame', ['Night Shift']), T.text('newGameDetail')));
    });

    test('several at once are counted; removed games go without a word; the first scan says nothing', () {
      expect(model.toast, isNull, reason: 'the fixture\'s scans were the first');
      for (final (index, name) in ['Alpha', 'Beta', 'Gamma'].indexed) {
        makeDump(model.root!, 'new$index', titleId: 'PPSA0710$index', names: {'en-US': name});
      }
      model.rescan();
      expect(model.toast, T.format('newGames', [3]));
      model.toast = null;
      Directory(p.join(model.root!, 'new0')).deleteSync(recursive: true);
      model.rescan();
      expect(model.toast, isNull);
      expect(model.games.any((game) => game.titleId == 'PPSA07100'), isFalse);
    });

    test('a new games folder is a new start, not a pile of new games', () async {
      final other = Directory(p.join(fixture.temp.path, 'other'))..createSync();
      makeDump(other.path, 'one', titleId: 'PPSA08001', names: {'en-US': 'Other One'});
      model.preferences.gamesFolders = [other.path];
      model.rescan();
      expect(model.games.single.titleId, 'PPSA08001');
      expect(model.toast, isNull);
    });

    test('an unlock going on does not hold the new game back, nor is it disturbed', () async {
      final stray = model.games[indexOf('PPSA02002')];
      File(p.join(stray.folder, 'eboot.bin')).writeAsBytesSync(typicalSelf());
      model.watchGamesFolders();
      model.unlock(stray);
      expect(model.stateOf(stray), isA<Installing>());
      makeDump(model.root!, 'during', titleId: 'PPSA09039', names: {'en-US': 'Meanwhile'});
      await until(() => model.games.any((game) => game.titleId == 'PPSA09039'));
      expect(model.toast, T.format('newGame', ['Meanwhile']));
      await until(() => model.stateOf(model.games.firstWhere((game) => game.id == stray.id)) is Installed);
    });
  });

  group('an unlock that would copy', () {
    // The games folder cannot link to the dump: another drive, Windows without Developer Mode.
    setUp(() => FileLinks.calls = LinkCalls(hardLink: (_, _) => false, symbolicLink: (_, _) => false));
    tearDown(() => FileLinks.calls = FileLinks.system);

    List<String> rowIds() => model.panelCategories().single.rows.map((row) => row.id).toList();

    test('asks first, says how much and why, and copies when told to', () async {
      final stray = model.games[indexOf('PPSA02002')];
      File(p.join(stray.folder, 'eboot.bin')).writeAsBytesSync(typicalSelf());
      model.sizes[stray.id] = 31400000000;
      model.unlock(stray);
      expect(model.overlay, Layer.copyWarning);
      expect(model.stateOf(stray), isA<Locked>(), reason: 'nothing starts before the answer');
      expect(model.panelCategories().single.title, T.text('copyWarningTitle'));
      expect(rowIds(), ['why', 'sameDrive', 'copyAnyway', 'cancel'], reason: 'no Developer Mode on Linux');
      final why = model.panelCategories().single.rows.first.kind as InfoRow;
      expect(why.text, contains('31.4 GB'));
      // The keyboard and the pad move through it like any panel: the explanation is skipped.
      expect(model.panelRow, 1);
      model.handle(Command.down);
      model.handle(Command.select);
      expect(model.overlay, isNull);
      expect(model.stateOf(stray), isA<Installing>());
      await until(() => model.stateOf(stray) is Installed);
      final installed = Installer.installedFolder(stray, model.root!);
      expect(
        FileSystemEntity.typeSync(p.join(installed, 'app0', 'sce_sys', 'param.json'), followLinks: false),
        FileSystemEntityType.file,
      );
    });

    test('on Windows it offers Developer Mode; the folder choice and cancel start nothing', () {
      model.dispose();
      fixture.dispose();
      fixture = makeFixture(system: HostSystem.windows);
      model = fixture.model;
      final stray = model.games[indexOf('PPSA02002')];
      model.sizes[stray.id] = 52000000000;
      model.unlock(stray);
      expect(rowIds(), ['why', 'sameDrive', 'developerMode', 'copyAnyway', 'cancel']);
      expect((model.panelCategories().single.rows.first.kind as InfoRow).text, contains('Developer Mode'));
      model.handle(Command.down);
      model.handle(Command.select);
      expect(fixture.opened, [Uri.parse('ms-settings:developers')]);
      expect(model.overlay, isNull);
      expect(model.toast, T.text('copyFixDeveloperModeThen'));
      expect(model.stateOf(stray), isA<Locked>());
      model.unlock(stray);
      model.handle(Command.select);
      expect(model.overlay, isNull, reason: 'the games folder was chosen');
      expect(model.stateOf(stray), isA<Locked>());
      model.unlock(stray);
      model.handle(Command.back);
      expect(model.overlay, isNull);
      expect(model.stateOf(stray), isA<Locked>());
      expect(model.queue, isEmpty);
    });

    test('a small copy goes ahead without asking', () {
      final stray = model.games[indexOf('PPSA02002')];
      model.sizes[stray.id] = 6000000;
      model.unlock(stray);
      expect(model.overlay, isNull);
      expect(model.stateOf(stray), isNot(isA<Locked>()));
    });
  });

  test('a game whose dump moved away from its links says so instead of starting', () async {
    final orbit = model.games[indexOf('PPSA01001')];
    final installed = Installer.installedFolder(orbit, model.root!);
    Directory(p.join(installed, 'app0')).createSync(recursive: true);
    Link(p.join(installed, 'app0', 'eboot.bin')).createSync(p.join(model.root!, 'moved-away', 'eboot.bin'));
    await model.play(orbit);
    expect(model.toast, T.text('dumpMoved'));
    expect(model.stateOf(orbit), isA<Installed>());
    expect(File(model.paths.logFile(orbit.titleId)).existsSync(), isFalse, reason: 'nothing started');
  });

  test('uninstalling removes the installed game and keeps the dump', () async {
    final orbit = model.games[indexOf('PPSA01001')];
    await model.uninstall(orbit);
    expect(model.stateOf(orbit), isA<Locked>());
    expect(Directory(Installer.installedFolder(orbit, model.root!)).existsSync(), isFalse);
    expect(File(p.join(orbit.folder, 'eboot.bin')).existsSync(), isTrue);
  });

  // Issue 55: pressed again and again while a big game went, the launcher stopped answering.
  test('Uninstall is done at once while the files go after; a second one or an unlock waits for them', () async {
    final orbit = model.games[indexOf('PPSA01001')];
    File(p.join(orbit.folder, 'eboot.bin')).writeAsBytesSync(typicalSelf());
    final installed = Installer.installedFolder(orbit, model.root!);
    final removeAside = Installer.removeAside;
    addTearDown(() => Installer.removeAside = removeAside);
    final removing = <String>[];
    final slow = Completer<void>();
    Installer.removeAside = (path) async {
      removing.add(path);
      await slow.future;
      await removeAside(path);
    };
    final first = model.uninstall(orbit);
    expect(model.stateOf(orbit), isA<Locked>());
    expect(model.toast, T.text('uninstallDone'));
    expect(Directory(installed).existsSync(), isFalse);
    expect(removing, isNotEmpty);
    for (final path in removing) {
      expect(Directory(path).existsSync(), isTrue, reason: 'set aside, not deleted on the screen\'s thread');
    }
    final asked = List.of(removing);
    await model.uninstall(orbit);
    expect(removing, asked, reason: 'a second Uninstall starts nothing');
    model.rescan();
    expect(model.stateOf(orbit), isA<Locked>());
    model.unlock(orbit);
    expect(model.stateOf(orbit), isA<Installing>());
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(model.stateOf(orbit), isA<Installing>(), reason: 'the unlock waits for the old files');
    expect(Directory(installed).existsSync(), isFalse);
    slow.complete();
    await first;
    for (final path in removing) {
      expect(Directory(path).existsSync(), isFalse);
    }
    await until(() => model.stateOf(orbit) is Installed);
  });
}
