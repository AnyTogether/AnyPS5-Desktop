import 'dart:async';
import 'dart:io';

import 'package:anyps5_desktop/core/engine_checkout.dart';
import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/installer.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/components.dart';
import 'package:anyps5_desktop/ui/game_action.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_commands.dart';
import '../support/fake_process.dart';
import '../support/ui_support.dart';

/// A game's state from start to end (GameState), what its main button says in each one
/// (GameAction), and the screens that follow it: the library while another game updates, a
/// game's settings in every state, Stop on a game playing.
void main() {
  tearDown(() => T.language = Language.english);

  Future<void> until(bool Function() condition, {String? reason}) async {
    for (var tries = 0; tries < 2000 && !condition(); tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(condition(), isTrue, reason: reason);
  }

  Game titled(AppModel model, String titleId) => model.games.firstWhere((game) => game.titleId == titleId);

  group('the main button follows the state', () {
    const job = EngineJob(step: GitStep.building, lines: ['[3/90] relinker.cpp.o'], forGame: 'x');
    final cases = <(GameState, String, ActionTone)>[
      (const Locked(), 'Unlock', ActionTone.normal),
      (const Installed(), 'Play', ActionTone.normal),
      (const Installed(outdated: true), 'Play', ActionTone.normal),
      (const Queued(), 'Cancel', ActionTone.normal),
      (const Installing(InstallStep.copy, 0.5), 'Cancel', ActionTone.normal),
      (const Installing(InstallStep.copy, 0.5, preparing: true), 'Play when ready', ActionTone.normal),
      (const Queued(updating: true), 'Waiting to update', ActionTone.busy),
      (const Queued(updating: true, waitingForEngine: true), 'Waiting for engine', ActionTone.busy),
      (const Installing(InstallStep.copy, 0.5, updating: true), 'Updating… 75%', ActionTone.busy),
      (const Installing(InstallStep.unwrap, 0.5, playsAfter: true), 'Unlocking… 6%', ActionTone.busy),
      (const WaitingForEngine(job, forThisGame: true), 'Updating engine…', ActionTone.busy),
      (const WaitingForEngine(job), 'Waiting for engine', ActionTone.busy),
      (const Starting(), 'Starting…', ActionTone.busy),
      (const Running(4242), 'Playing', ActionTone.normal),
      (const Stopping(4242), 'Stopping…', ActionTone.danger),
      (const Failed('relinker failed'), 'Try again', ActionTone.normal),
    ];
    for (final (state, title, tone) in cases) {
      test('${state.runtimeType}: $title', () {
        final action = GameAction.of(state);
        expect(action.title, title);
        expect(action.tone, tone);
      });
    }

    test('an update carries its share; the engine build, a start and a stop are under way', () {
      expect(GameAction.of(const Installing(InstallStep.copy, 0.5, updating: true)).progress, closeTo(0.75, 0.001));
      expect(GameAction.of(const Installing(InstallStep.relink, 0, updating: true)).indeterminate, isTrue);
      expect(GameAction.of(const WaitingForEngine(job, forThisGame: true)).indeterminate, isTrue);
      expect(GameAction.of(const Starting()).indeterminate, isTrue);
      expect(GameAction.of(const Stopping(1)).indeterminate, isTrue);
      expect(GameAction.of(const Installed()).progress, isNull);
    });

    test('Turkish', () {
      T.language = Language.byCode('tr');
      expect(GameAction.of(const Running(1)).title, 'Oynanıyor');
      expect(GameAction.of(const Installing(InstallStep.copy, 0.5, updating: true)).title, 'Güncelleniyor… %75');
      expect(GameAction.of(const WaitingForEngine(job)).title, 'Motor bekleniyor');
    });
  });

  group('playing and Stop', () {
    late Fixture fixture;
    late AppModel model;
    late FakeGameStarts starts;
    late Game orbit;

    setUp(() {
      fixture = makeFixture();
      model = fixture.model;
      starts = FakeGameStarts();
      model.startGame = starts.call;
      model.stopGrace = const Duration(milliseconds: 80);
      orbit = titled(model, 'PPSA01001');
      model.select(model.games.indexOf(orbit));
    });

    tearDown(() {
      model.dispose();
      fixture.dispose();
    });

    test(
      'Play: starting, running with its process, the main button keeps it, Stop asks it to close, then ready',
      () async {
        expect(model.stateOf(orbit), isA<Installed>());
        model.primaryAction(orbit);
        expect(model.stateOf(orbit), isA<Starting>());
        await until(() => model.running != null);
        expect(model.stateOf(orbit), isA<Running>().having((state) => state.pid, 'pid', 4242));
        expect(GameAction.of(model.stateOf(orbit)).title, 'Playing');
        model.primaryAction(orbit);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(model.stateOf(orbit), isA<Running>(), reason: 'the press brings it to the front, it does not stop it');
        expect(starts.last.signals, isEmpty);
        unawaited(model.stopRunningGame());
        expect(model.stateOf(orbit), isA<Stopping>());
        await until(() => model.running == null);
        expect(starts.last.signals, [ProcessSignal.sigterm], reason: 'asked to close as its window would');
        expect(model.stateOf(orbit), isA<Installed>());
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(starts.last.signals, [ProcessSignal.sigterm], reason: 'nothing is ended after it closed');
      },
    );

    test('a game that does not close when asked is ended after the grace', () async {
      starts = FakeGameStarts(() => FakeGameProcess(ignoresTerm: true));
      model.startGame = starts.call;
      model.primaryAction(orbit);
      await until(() => model.running != null);
      unawaited(model.stopRunningGame());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(model.stateOf(orbit), isA<Stopping>(), reason: 'still closing within the grace');
      model.primaryAction(orbit);
      expect(starts.last.signals, [ProcessSignal.sigterm], reason: 'a second press does not start again');
      await until(() => model.running == null);
      expect(starts.last.signals, [ProcessSignal.sigterm, ProcessSignal.sigkill]);
      expect(model.stateOf(orbit), isA<Installed>());
    });

    test('the game quit in game: ready again, and Close game in the quick menu closes it the same way', () async {
      model.primaryAction(orbit);
      await until(() => model.running != null);
      starts.last.quit();
      await until(() => model.running == null);
      expect(model.stateOf(orbit), isA<Installed>());
      model.primaryAction(orbit);
      await until(() => model.running != null);
      model.closeRunningGame();
      await until(() => model.running == null);
      expect(starts.last.signals, [ProcessSignal.sigterm]);
    });
  });

  group('the engine built before a game plays', () {
    late FakeCommands commands;
    late Fixture fixture;
    late AppModel model;
    late FakeGameStarts starts;
    late String checkout;
    late Completer<void> build;
    var head = 'aaaaaaaa11';

    setUp(() {
      head = 'aaaaaaaa11';
      build = Completer<void>();
      commands = FakeCommands();
      commands.results['git rev-parse HEAD'] = FakeResult(output: () => [head]);
      commands.results['git rev-list'] = const FakeResult(lines: ['2']);
      commands.results['git pull'] = FakeResult(lines: const ['Fast-forward'], effect: () => head = 'bbbbbbbb22');
      commands.results['cmake --build'] = FakeResult(
        lines: const ['[41/90] Building CXX object relinker.cpp.o'],
        hold: build,
        effect: () => buildFakeCheckout(checkout, kernel: 'kernel library, built again'),
      );
      fixture = makeFixture(commands: commands);
      model = fixture.model;
      starts = FakeGameStarts();
      model.startGame = starts.call;
      checkout = makeFakeCheckout(p.join(fixture.temp.path, 'AnyPS5'));
      model.useOwnFolder(checkout);
      final orbit = titled(model, 'PPSA01001');
      File(p.join(Installer.installedFolder(orbit, model.root!), Installer.recordName)).writeAsStringSync(
        '{"date":"2026-10-24T12:00:00Z","source":"${orbit.folder}","system":"linux","titleID":"PPSA01001",'
        '"toolkit":"${model.toolkitVersion}"}',
      );
      model.rescan();
      model.preferences.engineGitBeforePlay = true;
    });

    tearDown(() {
      if (!build.isCompleted) build.complete();
      model.dispose();
      fixture.dispose();
    });

    test('Play: updating the engine, the others wait for it, then the update and the game', () async {
      final orbit = titled(model, 'PPSA01001');
      final neon = titled(model, 'PPSA02002');
      model.select(model.games.indexOf(orbit));
      model.primaryAction(orbit);
      await until(() => model.engine.git.step == GitStep.building);
      final waiting = model.stateOf(orbit);
      expect(waiting, isA<WaitingForEngine>().having((state) => state.forThisGame, 'for this game', isTrue));
      expect(GameAction.of(waiting).title, 'Updating engine…');
      expect(model.engine.git.job?.step, GitStep.building);
      // Another game stays usable: its unlock waits for the build instead of being refused.
      model.primaryAction(neon);
      expect(model.stateOf(neon), isA<Queued>().having((state) => state.waitingForEngine, 'waits', isTrue));
      expect(model.progress, isEmpty, reason: 'nothing is relinked on a build half done');
      model.cancelUnlock(neon);
      // A second press says what goes on, and changes nothing.
      model.primaryAction(orbit);
      expect(model.toast, T.format('gameStartsAfterEngine', [orbit.name]));
      expect(model.engine.git.running, isTrue);
      build.complete();
      await until(() => model.progress.containsKey(orbit.id) || model.queue.contains(orbit.id));
      final updating = model.stateOf(orbit);
      expect(updating, anyOf(isA<Queued>(), isA<Installing>().having((state) => state.updating, 'updating', isTrue)));
      if (updating is Installing) expect(updating.playsAfter, isTrue);
      model.primaryAction(orbit);
      expect(model.toast, T.format('gameUpdatingHint', [orbit.name]), reason: 'Play again does not cancel it');
      await until(() => model.running != null, reason: 'it starts once updated');
      expect(model.stateOf(orbit), isA<Running>());
      expect(model.records[orbit.id]?.toolkit, model.toolkitVersion, reason: 'relinked with the new build');
      starts.last.quit();
      await until(() => model.running == null);
    });

    test('Update from Git waits while a game is unlocked; the game plays with the build it has', () async {
      final neon = titled(model, 'PPSA02002');
      model.unlock(neon);
      expect(model.unlocking, isTrue);
      expect(await model.engine.git.update(), isFalse);
      expect(model.toast, T.text('engineGitWaitUnlock'));
      expect(commands.lines.where((line) => line.startsWith('git pull')), isEmpty);
      model.cancelUnlock(neon);
      await until(() => !model.unlocking);
    });
  });

  group('screens', () {
    late Fixture fixture;
    late AppModel model;
    late Game orbit;

    setUp(() {
      fixture = makeFixture();
      model = fixture.model;
      orbit = titled(model, 'PPSA01001');
      model.select(model.games.indexOf(orbit));
    });

    tearDown(() {
      model.dispose();
      fixture.dispose();
    });

    List<PanelRow> settingsRows() => model.panelCategories().single.rows;
    PanelRow row(String id) => settingsRows().firstWhere((row) => row.id == id);

    testWidgets('while one game updates, the others can be browsed and opened', (tester) async {
      // Orbit Runner, installed, is being unlocked again.
      model.progress[orbit.id] = (InstallStep.copy, 0.4);
      await pumpLauncher(tester, model);
      expect(find.text('Updating… 72%'), findsOneWidget);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(model.selectedGame?.titleId, isNot('PPSA01001'));
      expect(find.text('Updating… 72%'), findsNothing, reason: 'the next game shows its own button');
      expect(find.byKey(const ValueKey('primary-action')), findsOneWidget);
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.arrowLeft);
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(model.selectedGame?.titleId, 'PPSA01001');
      expect(find.text('Updating… 72%'), findsOneWidget, reason: 'the update went on meanwhile');
      expect(tester.takeException(), isNull);
      model.progress.clear();
    });

    testWidgets('its settings open mid-update: Cancel update first, what cannot change says why', (tester) async {
      model.progress[orbit.id] = (InstallStep.relink, 0.3);
      await pumpLauncher(tester, model);
      await tester.tap(find.byIcon(Icons.more_horiz_rounded));
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(model.overlay, Layer.gameSettings);
      expect(settingsRows().first.id, 'cancelJob');
      expect(settingsRows().first.title, 'Cancel update');
      expect(find.text('Cancel update'), findsOneWidget);
      for (final id in ['reinstall', 'uninstall']) {
        expect(row(id).kind, isA<InfoRow>().having((kind) => kind.text, 'why', T.text('gameBusyUpdating')));
      }
      expect(settingsRows().where((row) => row.id == 'playTraced'), isEmpty, reason: 'no start mid-update');
      // The install is swapped in, the scan sees the folder gone for a moment: the page holds.
      final installed = Installer.installedFolder(orbit, model.root!);
      Directory(installed).renameSync('$installed.moving');
      model.rescan();
      await settle(tester);
      expect(tester.takeException(), isNull);
      Directory('$installed.moving').renameSync(installed);
      model.progress.clear();
      model.rescan();
      await settle(tester);
      expect(row('reinstall').kind, isA<ActionRow>(), reason: 'usable again once done');
      expect(settingsRows().first.id, isNot('cancelJob'));
    });

    testWidgets('the engine build shows on Home and on the game; its settings can stop it', (tester) async {
      model.engine.git
        ..step = GitStep.building
        ..forGame = orbit.id
        ..lines.add('[41/90] Building CXX object relinker.cpp.o');
      await pumpLauncher(tester, model);
      expect(find.text('Engine build · Building the relinker and libraries'), findsOneWidget);
      expect(find.text('Updating engine…'), findsOneWidget);
      expect(find.text('[41/90] Building CXX object relinker.cpp.o'), findsOneWidget);
      model.handle(Command.options);
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(settingsRows().first.title, 'Stop engine build');
      expect(row('reinstall').kind, isA<InfoRow>().having((kind) => kind.text, 'why', T.text('gameBusyEngine')));
      model.engine.git
        ..step = null
        ..forGame = null;
      model.refresh();
      await settle(tester);
      expect(find.text('Engine build · Building the relinker and libraries'), findsNothing);
    });

    testWidgets('a game playing: the button says Playing, the game\'s menu asks it to close', (tester) async {
      final process = FakeGameProcess(ignoresTerm: true);
      model.stopGrace = const Duration(seconds: 30);
      model.running = (orbit, runningFor(process));
      await pumpLauncher(tester, model);
      final button = tester.widget<ConsoleButton>(find.byKey(const ValueKey('primary-action')));
      expect(button.title, 'Playing');
      expect(button.stop, isFalse);
      await tester.tap(find.byKey(const ValueKey('primary-action')));
      await settle(tester);
      expect(process.signals, isEmpty, reason: 'the press brings it to the front');
      unawaited(model.stopRunningGame());
      await settle(tester);
      expect(process.signals, [ProcessSignal.sigterm]);
      expect(find.text('Stopping…'), findsOneWidget);
      model.handle(Command.options);
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(row('uninstall').kind, isA<InfoRow>().having((kind) => kind.text, 'why', T.text('closeGameFirst')));
      // Still there after the grace: it is ended.
      await tester.pump(const Duration(seconds: 31));
      expect(process.signals, [ProcessSignal.sigterm, ProcessSignal.sigkill]);
      model.running = null;
      model.stopping = false;
    });
  });
}
