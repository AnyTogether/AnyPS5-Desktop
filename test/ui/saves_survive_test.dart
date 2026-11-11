import 'dart:io';

import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/installer.dart';
import 'package:anyps5_desktop/core/relinker_flags.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_commands.dart';
import '../support/fake_github.dart';
import '../support/fake_toolkit.dart';
import '../support/fixtures.dart';
import '../support/self_builder.dart';
import '../support/ui_support.dart';

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
    File(p.joinAll([installed, ...relative.split('/')]))
      ..createSync(recursive: true)
      ..writeAsStringSync(text);
  }
}

void expectPlayed(String folder, {String? reason}) {
  for (final MapEntry(key: relative, value: text) in played.entries) {
    final file = File(p.joinAll([folder, ...relative.split('/')]));
    expect(file.existsSync(), isTrue, reason: '$relative ${reason ?? 'is there'}');
    expect(file.readAsStringSync(), text, reason: relative);
  }
}

Future<void> until(bool Function() condition) async {
  for (var tries = 0; tries < 1000 && !condition(); tries++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue);
}

/// The saves and trophies of an installed game through everything the launcher does to its
/// installation: Remove installation keeps them in the store and the next unlock takes them
/// back, and every way a game is built again carries them into the new one.
void main() {
  tearDown(() => T.language = Language.english);

  group('with the launcher\'s engine', () {
    late Fixture fixture;
    late AppModel model;

    setUp(() {
      fixture = makeFixture();
      model = fixture.model;
    });

    tearDown(() {
      model.dispose();
      fixture.dispose();
    });

    /// Orbit Runner, installed, with a dump the fake relinker takes and a player's saves in it.
    (Game, String) orbitPlayed() {
      final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
      File(p.join(orbit.folder, 'eboot.bin')).writeAsBytesSync(typicalSelf());
      final installed = Installer.installedFolder(orbit, model.root!);
      play(installed);
      return (orbit, installed);
    }

    List<PanelRow> settingsOf(Game game) {
      model.select(model.games.indexOf(game));
      model.open(Layer.gameSettings);
      return model.panelCategories().single.rows;
    }

    test('Remove installation says the saves are kept, keeps them, and Unlock brings them back', () async {
      final (orbit, installed) = orbitPlayed();
      (settingsOf(orbit).firstWhere((row) => row.id == 'uninstall').kind as ActionRow).run();
      expect(model.overlay, Layer.confirmUninstall);
      final confirm = model.panelCategories().single.rows.first;
      expect(
        confirm.detail,
        'Remove the installation? Your game files stay; the game shows as locked again. '
        'Your saves and trophies are kept and come back when you unlock the game again.',
      );
      expect(confirm.wraps, isTrue, reason: 'read whole, never cut short');
      (confirm.kind as ActionRow).run();
      expect(model.stateOf(orbit), isA<Locked>());
      expect(model.toast, T.text('uninstallDone'));
      expect(File(p.join(installed, 'app.elf')).existsSync(), isFalse, reason: 'the installation is gone');
      final kept = Installer.keptSaves(installed);
      expectPlayed(kept, reason: 'is kept in the store');

      model.rescan();
      model.unlock(orbit);
      await until(() => model.stateOf(orbit) is Installed);
      expectPlayed(installed, reason: 'is back');
      expect(Directory(kept).existsSync(), isFalse, reason: 'nothing left to keep');
    });

    test('saves that cannot be kept: Remove installation says so and removes nothing', () async {
      final (orbit, installed) = orbitPlayed();
      // Where the kept saves go is taken by a file.
      File(p.join(model.root!, GameLibrary.storeName, 'Saves')).writeAsStringSync('in the way');
      await model.uninstall(orbit);
      expect(model.toast, startsWith('The installation could not be removed: '));
      expect(model.stateOf(orbit), isA<Installed>());
      expect(model.records.containsKey(orbit.id), isTrue);
      expectPlayed(installed, reason: 'stays in the game');
    });

    test('a copy made by another engine is rebuilt before it starts: the saves are in the new one', () async {
      final (orbit, installed) = orbitPlayed();
      makeFakeToolkit(fixture.toolkit, version: 'toolkit-2');
      model.rescan();
      expect(model.needsRebuild(orbit), isTrue);
      model.primaryAction(orbit);
      expect(model.afterRebuild?.$1, orbit.id, reason: 'the stale copy is rebuilt on its own');
      // The start that waits on the rebuild is not this test's.
      var rebuilt = false;
      model.afterRebuild = (orbit.id, () => rebuilt = true);
      await until(() => rebuilt);
      expect(model.records[orbit.id]!.toolkit, 'toolkit-2');
      expectPlayed(installed);
    });

    test('Unlock again after the relinker options change: the saves are in the new one', () async {
      final (orbit, installed) = orbitPlayed();
      makeFakeToolkit(fixture.toolkit, traceImports: true);
      model.rescan();
      model.saveSettings(orbit, model.currentSettings(orbit).withRelinkerFlag(RelinkerFlag.traceImports, true));
      (settingsOf(orbit).firstWhere((row) => row.id == 'reinstall').kind as ActionRow).run();
      await until(() => model.records[orbit.id]?.relinkerFlags.contains('--trace-imports') ?? false);
      await until(() => model.stateOf(orbit) is Installed);
      expectPlayed(installed);
    });

    test('unlocked again after an update is added: the saves are in the new one', () async {
      final (orbit, installed) = orbitPlayed();
      final update = makeDump(
        p.dirname(orbit.folder),
        '${p.basename(orbit.folder)}-UPDATE',
        titleId: 'PPSA01001',
        version: '01.010.000',
      );
      File(p.join(update, 'eboot.bin')).writeAsBytesSync(typicalSelf(seed: 3));
      model.rescan();
      final updated = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
      expect(updated.update?.version, '01.010.000');
      model.unlock(updated);
      await until(() => model.records[updated.id]?.update == '01.010.000');
      await until(() => model.stateOf(updated) is Installed);
      expectPlayed(installed);
    });

    test('a rebuild that fails leaves the saves in the copy that is still there', () async {
      final (orbit, installed) = orbitPlayed();
      makeFakeToolkit(fixture.toolkit, mode: 'fail', version: 'toolkit-2');
      model.rescan();
      model.unlock(orbit);
      await until(() => model.stateOf(orbit) is Failed);
      expectPlayed(installed);
    });
  });

  group('a game\'s own engine', () {
    late FakeGitHub github;
    late Fixture fixture;
    late AppModel model;

    setUp(() async {
      github = await FakeGitHub.start();
      fixture = makeFixture(engine: github.api);
      model = fixture.model;
      makeFakeToolkit(p.join(model.paths.toolkits, '0.1.3'), version: 'upstream-v0.1.3');
      model.engine.refresh();
    });

    tearDown(() async {
      model.dispose();
      await github.close();
      fixture.dispose();
    });

    test('switched to another engine and unlocked with it: the saves are in the new one', () async {
      final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
      File(p.join(orbit.folder, 'eboot.bin')).writeAsBytesSync(typicalSelf());
      final installed = Installer.installedFolder(orbit, model.root!);
      play(installed);
      expect(model.records[orbit.id]!.toolkit, isNot('upstream-v0.1.3'));
      model.saveSettings(orbit, model.currentSettings(orbit).copyWith(engine: '0.1.3'));
      model.unlock(orbit);
      await until(() => model.records[orbit.id]?.toolkit == 'upstream-v0.1.3');
      await until(() => !model.unlocking);
      expectPlayed(installed);
    });
  });

  group('Update from Git', () {
    late FakeCommands commands;
    late Fixture fixture;
    late AppModel model;
    late String checkout;
    var head = 'aaaaaaaa11';

    setUp(() {
      head = 'aaaaaaaa11';
      commands = FakeCommands();
      commands.results['git rev-parse HEAD'] = FakeResult(output: () => [head]);
      fixture = makeFixture(commands: commands);
      model = fixture.model;
      checkout = makeFakeCheckout(p.join(fixture.temp.path, 'AnyPS5'));
      model.useOwnFolder(checkout);
    });

    tearDown(() {
      model.dispose();
      fixture.dispose();
    });

    test('the engine built again and its games relinked: the saves are in the new ones', () async {
      final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
      File(p.join(orbit.folder, 'eboot.bin')).writeAsBytesSync(typicalSelf());
      final installed = Installer.installedFolder(orbit, model.root!);
      // Unlocked with the checkout's build as it is now.
      File(p.join(installed, Installer.recordName)).writeAsStringSync(
        '{"date":"2026-10-24T12:00:00Z","source":"${orbit.folder}","system":"linux","titleID":"PPSA01001",'
        '"toolkit":"${model.toolkitVersion}"}',
      );
      model.rescan();
      play(installed);
      final before = model.toolkitVersion;
      // git pull brings a commit; the build writes new libraries.
      commands.results['git pull'] = FakeResult(lines: const ['Fast-forward'], effect: () => head = 'bbbbbbbb22');
      commands.results['cmake --build'] = FakeResult(
        lines: const ['[1/1] Linking libkernel.prx'],
        effect: () => buildFakeCheckout(checkout, kernel: 'kernel library, built again'),
      );
      model.open(Layer.settings);
      final update = model
          .panelCategories()
          .expand((category) => category.rows)
          .firstWhere((row) => row.id == 'engineGitUpdate');
      (update.kind as ActionRow).run();
      await until(() => !model.engine.git.running);
      expect(model.toolkitVersion, isNot(before), reason: 'the build changed the engine');
      model.closeOverlay();
      model.engine.git.relinkAll();
      await until(() => model.records[orbit.id]?.toolkit == model.toolkitVersion);
      await until(() => !model.unlocking);
      expectPlayed(installed);
    });
  });
}
