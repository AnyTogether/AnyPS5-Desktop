import 'dart:io';

import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/installer.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/engine_model.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_elf.dart';
import '../support/fake_github.dart';
import '../support/fake_toolkit.dart';
import '../support/self_builder.dart';
import '../support/ui_support.dart';

/// The AnyPS5 engine downloaded by the launcher itself: onboarding, settings, updates. (The
/// screens are in launcher_test.dart: a file with widget tests gets no real HTTP.)
void main() {
  tearDown(() => T.language = Language.english);

  Future<void> until(bool Function() condition) async {
    for (var tries = 0; tries < 500 && !condition(); tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(condition(), isTrue);
  }

  group('a game\'s own engine', () {
    late FakeGitHub github;
    late Fixture fixture;
    late AppModel model;

    setUp(() async {
      github = await FakeGitHub.start();
      fixture = makeFixture(engine: github.api);
      model = fixture.model;
      for (final version in ['0.1.2', '0.1.3']) {
        makeFakeToolkit(p.join(model.paths.toolkits, version), version: 'upstream-v$version');
      }
      model.engine.refresh();
      // A dump the fake relinker takes.
      final game = model.games.firstWhere((game) => game.titleId == 'PPSA02002');
      File(p.join(game.folder, 'eboot.bin')).writeAsBytesSync(typicalSelf());
    });

    tearDown(() async {
      model.dispose();
      await github.close();
      fixture.dispose();
    });

    Game neon() => model.games.firstWhere((game) => game.titleId == 'PPSA02002');
    List<PanelRow> rows(Game game) => model.engine.gameRows(game);
    PanelRow row(Game game, String id) => rows(game).firstWhere((row) => row.id == id);
    void pin(Game game, String key) => model.saveSettings(game, model.currentSettings(game).copyWith(engine: key));

    test('Game Settings lists the default and the downloaded engines, and says what unlocked it', () {
      final kind = row(neon(), 'engine').kind as ChoiceRow;
      expect(kind.options, [
        'Default (${EngineModel.label(model.toolkit!)})',
        ...model.engine.downloaded.map(EngineModel.label),
      ]);
      expect(kind.selected, 0);
      expect(row(neon(), 'engine').detail, 'Used when you unlock it');
      model.open(Layer.gameSettings);
      final inPanel = model.panelCategories().expand((category) => category.rows).map((row) => row.id);
      expect(inPanel, contains('engine'));
      kind.set(1);
      expect(model.currentSettings(neon()).engine, p.basename(model.engine.downloaded.first.root));
      expect((row(neon(), 'engine').kind as ChoiceRow).selected, 1);
      (row(neon(), 'engine').kind as ChoiceRow).set(0);
      expect(model.currentSettings(neon()).engine, isNull);
    });

    test('a chosen engine unlocks the game whatever the default is, and the default stays', () async {
      final game = neon();
      final pinned = model.engine.downloaded.last;
      expect(pinned.version, isNot(model.toolkitVersion));
      pin(game, p.basename(pinned.root));
      final before = model.preferences.toolkitFolder;
      model.unlock(game);
      await until(() => !model.unlocking && model.records.containsKey(game.id));
      expect(model.records[game.id]!.toolkit, pinned.version);
      expect(model.preferences.toolkitFolder, before);
      expect(model.stateOf(game), isA<Installed>().having((state) => state.outdated, 'outdated', isFalse));
      expect(row(game, 'engine').detail, 'Unlocked with ${EngineModel.nameOf(pinned.version)}');
    });

    test('the default changing leaves a game with its own engine as it is, and other games are told', () async {
      final game = neon();
      final ownKit = model.engine.downloaded.first;
      pin(game, p.basename(ownKit.root));
      model.unlock(game);
      await until(() => !model.unlocking && model.records.containsKey(game.id));
      // The default becomes the other downloaded engine, of a new version the game was not made with.
      final other = model.engine.downloaded.last;
      model.engine.use(other);
      expect(model.stateOf(game), isA<Installed>().having((state) => state.outdated, 'outdated', isFalse));
      expect(model.engine.gamesFromOtherEngines(), 1, reason: 'Orbit Runner, not the game with its own engine');
    });

    test('a pinned engine that is not on disk says so and offers the download; the default stays', () async {
      final game = neon();
      github.releases.add(upstreamRelease('0.1.9'));
      pin(game, '0.1.9');
      expect(model.missingEngine(game), '0.1.9');
      expect(row(game, 'engine').detail, 'v0.1.9 is not on this computer. Download it to unlock this game.');
      final before = model.preferences.toolkitFolder;
      // Play says it and opens the row, instead of doing nothing.
      model.select(model.games.indexOf(game));
      model.unlock(game);
      expect(model.toast, contains('v0.1.9'));
      expect(model.overlay, Layer.gameSettings);
      expect(model.queue, isEmpty);
      model.closeOverlay();
      final download = row(game, 'engineGameDownload');
      expect(download.title, 'Download v0.1.9');
      (download.kind as ActionRow).run();
      await until(() => model.missingEngine(game) == null && model.engine.downloading == null);
      expect(model.preferences.toolkitFolder, before, reason: 'the default stays what it was');
      expect(model.engine.downloaded.map((kit) => p.basename(kit.root)), contains('0.1.9'));
      expect(model.toolkitFor(game)?.version, 'upstream-v0.1.9', reason: 'what unlocks it now');
    });

    test('an engine GitHub no longer lists: said, nothing happens to the default', () async {
      final game = neon();
      pin(game, '0.0.1');
      (row(game, 'engineGameDownload').kind as ActionRow).run();
      await until(() => model.toast == 'v0.0.1 can no longer be downloaded.');
      expect(model.missingEngine(game), '0.0.1');
    });

    test('an AnyPS5-ARM engine chosen for one game names the source on the row', () {
      final game = neon();
      makeFakeToolkit(p.join(model.paths.toolkits, 'arm-5ca076a87'), version: 'arm-5ca076a87');
      model.engine.refresh();
      final kind = row(game, 'engine').kind as ChoiceRow;
      expect(kind.options, contains('AnyPS5-ARM 5ca076a87'));
      pin(game, 'arm-5ca076a87');
      expect(model.toolkitFor(game)?.version, 'arm-5ca076a87');
      expect(model.engine.readsDisplaySettingsOf(game), isTrue, reason: 'the game, not the default upstream engine');
      expect(model.engine.readsDisplaySettings, isFalse);
    });

    test('deleting: one version at a time, never the one in use, and a game\'s own stays', () {
      model.open(Layer.settings);
      List<PanelRow> engineRows() => model.panelCategories().firstWhere((category) => category.id == 'engine').rows;
      PanelRow delete(String id) => engineRows().firstWhere((row) => row.id == 'engineDelete-$id');
      final key = p.basename(model.engine.downloaded.last.root);
      expect(delete(key).title, 'Delete ${EngineModel.label(model.engine.downloaded.last)}');
      expect((delete(key).kind as ActionRow).destructive, isTrue);
      // Chosen by a game: in use.
      pin(neon(), key);
      expect(delete(key).detail, T.text('engineInUse'));
      expect((delete(key).kind as ActionRow).destructive, isFalse);
      (delete(key).kind as ActionRow).run();
      expect(model.toast, T.text('engineInUseNoDelete'));
      model.engine.deleteOthers();
      expect(model.engine.downloaded.map((kit) => p.basename(kit.root)), contains(key), reason: 'a game chose it');
      // No game chooses it any more: it goes.
      model.saveSettings(neon(), model.currentSettings(neon()).copyWith(engine: null));
      (delete(key).kind as ActionRow).run();
      expect(model.toast, 'Deleted ${EngineModel.nameOf(key)}');
      expect(model.engine.downloaded.map((kit) => p.basename(kit.root)), isNot(contains(key)));
    });
  });

  group('model', () {
    late FakeGitHub github;
    late Fixture fixture;
    late AppModel model;

    setUp(() async {
      github = await FakeGitHub.start();
      fixture = makeFixture(onboarded: false, withToolkit: false, engine: github.api);
      model = fixture.model;
    });

    tearDown(() async {
      model.dispose();
      await github.close();
      fixture.dispose();
    });

    PanelRow row(String id) => model
        .panelCategories()
        .expand((category) => category.rows)
        .firstWhere((row) => row.id == id, orElse: () => throw StateError('no row $id'));

    void choose(String id) => (row(id).kind as ActionRow).run();

    Future<void> toToolkitStep() async {
      model.onboardingStep = 2;
      model.onboardingChoice = 1;
      model.onboardingConfirm();
      expect(model.onboardingStep, 3);
      await until(() => !model.engine.checking);
    }

    test('onboarding: the toolkit step finds the newest engine and downloads it', () async {
      github.releases.addAll([upstreamRelease('0.1.3'), upstreamRelease('0.1.2')]);
      expect(model.toolkit, isNull);
      await toToolkitStep();
      expect(model.engine.checkError, isNull);
      expect(model.engine.latest?.tag, 'v0.1.3');
      expect(model.onboardingChoice, 0, reason: 'the download is offered first');
      model.onboardingConfirm();
      expect(model.engine.downloading?.version, '0.1.3');
      await until(() => model.engine.downloading == null);
      final toolkit = model.toolkit!;
      expect(toolkit.version, 'upstream-v0.1.3');
      expect(toolkit.root, p.join(model.paths.toolkits, '0.1.3'));
      expect(model.preferences.toolkitFolder, toolkit.root);
      expect(model.onboardingChoice, 2, reason: 'next comes Start');
      // Orbit Runner was unlocked with the fixture's toolkit: Play will offer Update and play.
      expect(model.toast, 'AnyPS5 engine v0.1.3 is ready · Update and play offered for installed games: 1');
      model.onboardingConfirm();
      expect(model.onboardingStep, 4, reason: 'then offline or online');
      model.onboardingConfirm();
      expect(model.preferences.onboarded, isTrue);
    });

    test('onboarding: without GitHub the card says so, and choosing it asks again', () async {
      github.apiStatus = 500;
      await toToolkitStep();
      expect(model.engine.checkError, isNotNull);
      github.apiStatus = null;
      github.releases.add(upstreamRelease('0.1.3'));
      model.onboardingConfirm();
      await until(() => model.engine.latest != null && !model.engine.checking);
      expect(model.engine.downloading, isNull, reason: 'the first choice only looked again');
    });

    test('a release without checksums is downloaded only when chosen a second time', () async {
      github.releases.add(upstreamRelease('0.1.3')..digests = false);
      await toToolkitStep();
      model.onboardingConfirm();
      await until(() => model.engine.unverified != null);
      expect(model.toast, T.text('engineUnverified'));
      expect(github.downloads, isEmpty);
      expect(model.toolkit, isNull);
      model.onboardingConfirm();
      await until(() => model.toolkit != null);
      expect(model.toolkit!.version, 'upstream-v0.1.3');
      expect(model.engine.unverified, isNull);
    });

    test('settings: the engine in use, other versions to switch to or download, the old ones deleted', () async {
      github.releases.addAll([upstreamRelease('0.1.2'), upstreamRelease('0.1.1')]);
      await model.engine.check(quiet: true);
      model.open(Layer.settings);
      expect(model.panelCategories().map((category) => category.id), contains('engine'));
      expect((row('engineCurrent').kind as InfoRow).text, 'Not found');
      expect(row('engineDownload').title, 'Download v0.1.2');
      choose('engineDownload');
      await until(() => model.engine.downloading == null && model.toolkit != null);
      choose('engine-0.1.1');
      await until(() => model.engine.downloading == null && model.toolkit!.version == 'upstream-v0.1.1');
      expect((row('engineCurrent').kind as InfoRow).text, 'v0.1.1');
      expect((row('engine-0.1.1').kind as InfoRow).text, 'In use');
      expect(row('engine-0.1.2').detail, 'Downloaded · select to use');
      choose('engine-0.1.2');
      expect(model.toolkit!.version, 'upstream-v0.1.2');
      expect(model.toast, 'Now using the AnyPS5 engine v0.1.2 · Update and play offered for installed games: 1');
      expect(row('engineDeleteOld').detail, 'Downloaded versions not in use: 1');
      choose('engineDeleteOld');
      expect(model.engine.downloaded.map((kit) => p.basename(kit.root)), ['0.1.2']);
      expect(
        model.panelCategories().expand((category) => category.rows).map((row) => row.id),
        isNot(contains('engineDeleteOld')),
      );
      expect(row('engine-0.1.1').detail, contains('select to download'));
      choose('engineCheck');
      await until(() => !model.engine.checking);
      expect(model.toast, 'The AnyPS5 engine is up to date (v0.1.2)');
    });

    test('a newer engine marks installed games; Update and play downloads it, then unlocks again', () async {
      github.releases.add(upstreamRelease('0.1.2'));
      await model.engine.download();
      final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
      final installed = Installer.installedFolder(orbit, model.root!);
      File(p.join(installed, Installer.recordName)).writeAsStringSync(
        '{"date":"2026-10-24T12:00:00Z","source":"${orbit.folder}","system":"linux","titleID":"PPSA01001",'
        '"toolkit":"upstream-v0.1.2"}',
      );
      model.preferences.onboarded = true;
      model.rescan();
      expect(model.stateOf(orbit), isA<Installed>().having((state) => state.outdated, 'outdated', isFalse));

      github.releases.insert(0, upstreamRelease('0.1.3'));
      await model.engine.startupCheck();
      expect(model.engine.updateAvailable, isTrue);
      expect(model.toast, 'AnyPS5 engine v0.1.3 is out: Settings › AnyPS5 engine');
      expect(model.stateOf(orbit), isA<Installed>().having((state) => state.outdated, 'outdated', isTrue));
      model.select(model.games.indexOf(orbit));
      model.primaryAction(orbit);
      expect(model.overlay, Layer.updateChoice);
      expect(row('update').detail, startsWith('Downloads AnyPS5 engine v0.1.3'));
      choose('update');
      await until(() => model.engine.downloading == null && model.toolkit!.version == 'upstream-v0.1.3');
      expect(model.engine.updateAvailable, isFalse);
      // The game is unlocked again with the new engine.
      expect(
        model.queue.contains(orbit.id) || model.progress.containsKey(orbit.id) || model.failures.containsKey(orbit.id),
        isTrue,
      );
      await until(() => !model.progress.containsKey(orbit.id) && !model.queue.contains(orbit.id));
      // 0.1.2 stays: the game was made with it.
      expect(model.engine.downloaded.map((kit) => p.basename(kit.root)), ['0.1.3', '0.1.2']);
    });

    test('a folder of the user\'s own is not nagged about engine updates', () async {
      github.releases.add(upstreamRelease('0.1.3'));
      model.preferences.toolkitFolder = fixture.toolkit;
      model.preferences.onboarded = true;
      await model.engine.check(quiet: true);
      expect(model.engine.updateAvailable, isFalse);
      final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
      expect(model.stateOf(orbit), isA<Installed>().having((state) => state.outdated, 'outdated', isFalse));
      model.open(Layer.settings);
      expect(row('engineOwn').detail, T.format('engineOwnInUse', [fixture.toolkit]));
      expect(
        model.panelCategories().expand((category) => category.rows).map((row) => row.id),
        isNot(contains('engineDownload')),
      );
    });
  });

  group('an engine changed under installed games', () {
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

    Game orbit() => model.games.firstWhere((game) => game.titleId == 'PPSA01001');
    bool outdated() => (model.stateOf(orbit()) as Installed).outdated;

    void installedWith(String toolkit) {
      final installed = Installer.installedFolder(orbit(), model.root!);
      File(p.join(installed, Installer.recordName)).writeAsStringSync(
        '{"date":"2026-10-24T12:00:00Z","source":"${orbit().folder}","system":"linux","titleID":"PPSA01001",'
        '"toolkit":"$toolkit"}',
      );
      model.rescan();
    }

    test('a folder of the user\'s own built again in place: its games are rebuilt before they start', () {
      final own = makeFakeToolkit(p.join(fixture.temp.path, 'own'));
      File(p.join(own, 'version.txt')).deleteSync();
      model.preferences.toolkitFolder = own;
      installedWith(model.toolkitVersion!);
      expect(outdated(), isFalse);

      // A git pull and a build in a terminal, the launcher behind it.
      File(p.join(own, 'libs', 'libkernel.prx')).writeAsStringSync('kernel library, built again');
      model.setActive(false);
      model.setActive(true);
      expect(outdated(), isTrue, reason: 'the games were made with the libraries before the build');
      expect(model.needsRebuild(orbit()), isTrue);
      model.select(model.games.indexOf(orbit()));
      model.primaryAction(orbit());
      expect(model.overlay, isNull, reason: 'no question: the copy is rebuilt with the engine at hand');
      expect(model.afterRebuild?.$1, orbit().id);
      expect(model.starting, isNull);
      model.cancelUnlock(orbit());
    });

    test('choosing another engine says the installed games will offer Update and play', () async {
      installedWith(model.toolkitVersion!);
      final other = makeFakeToolkit(p.join(fixture.temp.path, 'other'), version: 'toolkit-2');
      model.preferences.toolkitFolder = null;
      model.useOwnFolder(other);
      expect(model.toolkitVersion, 'toolkit-2');
      expect(outdated(), isTrue);
      expect(model.toast, '${T.text('engineOwnChosen')} · ${T.format('engineGamesToUpdate', [1])}');
    });
  });

  group('glibc', () {
    PanelRow? row(AppModel model, String id) {
      model.open(Layer.settings);
      return model.panelCategories().expand((category) => category.rows).where((row) => row.id == id).firstOrNull;
    }

    test('an engine needing a newer glibc is said in Settings and before a game is unlocked', () {
      final fixture = makeFixture(glibc: '2.35');
      addTearDown(fixture.dispose);
      final model = fixture.model;
      addTearDown(model.dispose);
      File(p.join(fixture.toolkit, 'libs', 'libkernel.prx')).writeAsBytesSync(elfNeeding(['GLIBC_2.38']));
      final warning = row(model, 'engineGlibc');
      expect(warning?.title, 'Games need glibc 2.38 or newer; this system has 2.35');
      expect(warning?.detail, contains('Ubuntu 24.04'));
      final locked = model.games.firstWhere((game) => game.titleId == 'PPSA03003');
      model.unlock(locked);
      expect(model.toast, 'Games need glibc 2.38 or newer; this system has 2.35');
      expect(
        model.queue.contains(locked.id) || model.progress.containsKey(locked.id),
        isTrue,
        reason: 'it is unlocked all the same',
      );
      model.cancelUnlock(locked);
      T.language = Language.byCode('tr');
      expect(row(model, 'engineGlibc')?.title, 'Oyunlar glibc 2.38 veya daha yenisini istiyor; bu sistemde 2.35 var');
    });

    test('nothing is said when the system has enough, or its glibc is unknown', () {
      for (final glibc in ['2.39', null]) {
        final fixture = makeFixture(glibc: glibc);
        File(p.join(fixture.toolkit, 'libs', 'libkernel.prx')).writeAsBytesSync(elfNeeding(['GLIBC_2.38']));
        expect(row(fixture.model, 'engineGlibc'), isNull);
        fixture.model.dispose();
        fixture.dispose();
      }
    });
  });
}
