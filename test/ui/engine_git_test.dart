import 'dart:async';
import 'dart:io';

import 'package:anyps5_desktop/core/engine_checkout.dart';
import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/installer.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_commands.dart';
import '../support/fake_process.dart';
import '../support/phone/fake_phone.dart' show FakePhone;
import '../support/phone/messages.dart' show Launch, Pairing, Welcome;
import '../support/ui_support.dart';

/// Settings › AnyPS5 engine › Update from Git, for an engine folder that is a git checkout.
void main() {
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
    T.language = Language.english;
    model.dispose();
    fixture.dispose();
  });

  Future<void> until(bool Function() condition) async {
    for (var tries = 0; tries < 2000 && !condition(); tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(condition(), isTrue);
  }

  PanelRow? row(String id) {
    if (model.overlay != Layer.settings) model.open(Layer.settings);
    return model.panelCategories().expand((category) => category.rows).where((row) => row.id == id).firstOrNull;
  }

  void choose(String id) => (row(id)!.kind as ActionRow).run();

  Game orbit() => model.games.firstWhere((game) => game.titleId == 'PPSA01001');
  GameState orbitState() => model.stateOf(orbit());

  /// Orbit Runner unlocked with the checkout's build as it is now.
  void installedWithCurrentBuild() {
    final installed = Installer.installedFolder(orbit(), model.root!);
    File(p.join(installed, Installer.recordName)).writeAsStringSync(
      '{"date":"2026-10-24T12:00:00Z","source":"${orbit().folder}","system":"linux","titleID":"PPSA01001",'
      '"toolkit":"${model.toolkitVersion}"}',
    );
    model.rescan();
  }

  /// git pull brings a commit; the build writes new libraries.
  void remoteHasNewCommit() {
    commands.results['git pull'] = FakeResult(lines: const ['Fast-forward'], effect: () => head = 'bbbbbbbb22');
    commands.results['cmake --build'] = FakeResult(
      lines: const ['[1/2] Building CXX object core/libs/kernel.cpp.o', '[2/2] Linking libkernel.prx'],
      effect: () => buildFakeCheckout(checkout, kernel: 'kernel library, built again'),
    );
  }

  test('the checkout is the engine: its build is used, and Settings offers Update from Git', () {
    expect(model.toolkit?.root, checkout);
    expect(model.toolkit?.relinker, p.join(checkout, 'build', 'core', 'relinker', 'relinker'));
    expect(row('engineOwn')?.detail, T.format('engineOwnCheckout', [checkout]));
    expect(row('engineGitUpdate')?.title, 'Update from Git');
    expect(row('engineGitUpdate')?.detail, contains('build'));
    expect((row('engineGitBeforePlay')?.kind as ToggleRow?)?.value, isFalse, reason: 'off unless asked for');
    expect(commands.calls, isEmpty, reason: 'nothing runs until asked');
    expect(model.toast, startsWith(T.text('engineOwnCheckoutChosen')));
  });

  test('a folder that is not a checkout offers none of it', () {
    model.useOwnFolder(fixture.toolkit);
    expect(row('engineGitUpdate'), isNull);
    expect(row('engineGitBeforePlay'), isNull);
  });

  test('success: the fingerprint changes, installed games offer Update and play, Relink All', () async {
    installedWithCurrentBuild();
    final before = model.toolkitVersion;
    expect(orbitState(), isA<Installed>().having((state) => state.outdated, 'outdated', isFalse));
    remoteHasNewCommit();
    choose('engineGitUpdate');
    expect(model.engine.git.running, isTrue);
    expect(row('engineGitUpdate')?.title, startsWith('Updating from Git · '));
    await until(() => !model.engine.git.running);
    expect(model.toolkitVersion, isNot(before), reason: 'the build changed the libraries');
    expect(orbitState(), isA<Installed>().having((state) => state.outdated, 'outdated', isTrue));
    expect(model.toast, 'Engine updated from Git to bbbbbbb · ${T.format('engineGamesToUpdate', [1])}');
    expect(model.preferences.engineGitBuilt[checkout], 'bbbbbbbb22');
    model.select(model.games.indexOf(orbit()));
    model.primaryAction(orbit());
    expect(model.overlay, isNot(Layer.updateChoice));
    expect(model.afterRebuild?.$1, orbit().id, reason: 'Play rebuilds the copy first');
    model.cancelUnlock(orbit());
    await until(() => orbitState() is Installed);
    expect(row('engineGitRelinkAll')?.detail, T.format('engineGitRelinkAllDetail', [1]));
    choose('engineGitRelinkAll');
    expect(model.queue.contains(orbit().id) || model.progress.containsKey(orbit().id), isTrue);
    model.cancelUnlock(orbit());
  });

  test('live progress: the step and the last lines, and selecting it stops', () async {
    final hold = Completer<void>();
    commands.results['cmake --build'] = FakeResult(
      lines: const ['[7/90] Building CXX object relinker.cpp.o'],
      hold: hold,
    );
    choose('engineGitUpdate');
    await until(() => row('engineGitUpdate')!.title.endsWith(T.text('engineGitStepBuilding')));
    await until(() => row('engineGitUpdate')!.detail!.contains('[7/90]'));
    model.select(model.games.indexOf(orbit()));
    model.primaryAction(orbit());
    expect(model.starting, isNull, reason: 'no game starts on a build half done');
    expect(model.stateOf(orbit()), isA<WaitingForEngine>());
    expect(model.toast, T.text('gameWaitsForEngine'));
    choose('engineGitUpdate');
    await until(() => !model.engine.git.running);
    expect(model.toast, T.text('engineGitStopped'));
    expect(row('engineGitFailed'), isNull, reason: 'a stop is no failure');
    expect(hold.isCompleted, isFalse);
  });

  test('a tree with uncommitted changes is refused; the failure can be copied', () async {
    commands.results['git status'] = const FakeResult(lines: [' M core/relinker/main.cpp']);
    choose('engineGitUpdate');
    await until(() => !model.engine.git.running);
    expect(model.toast, T.format('engineGitFailed', [T.text('engineGitDirty')]));
    expect(commands.lines.where((line) => line.startsWith('git pull')), isEmpty);
    final failed = row('engineGitFailed')!;
    expect(failed.detail, contains('core/relinker/main.cpp'));
    choose('engineGitFailed');
    expect(fixture.copied.single, contains('core/relinker/main.cpp'));
    expect(model.toast, T.text('engineGitCopied'));
  });

  test('a failed build shows the end of its output', () async {
    commands.results['cmake --build'] = const FakeResult(
      code: 1,
      lines: ['FAILED: relinker.cpp.o', 'error: expected ;'],
    );
    choose('engineGitUpdate');
    await until(() => !model.engine.git.running);
    expect(row('engineGitFailed')?.title, T.format('engineGitFailed', [T.text('engineGitBuildFailed')]));
    expect(row('engineGitFailed')?.detail, contains('error: expected ;'));
    choose('engineGitFailed');
    expect(fixture.copied.single, contains('FAILED: relinker.cpp.o'));
  });

  test('git missing: said, with the guide of this tree to open', () async {
    commands.results['git --version'] = const FakeResult(missing: true);
    choose('engineGitUpdate');
    await until(() => !model.engine.git.running);
    expect(
      model.toast,
      T.format('engineGitFailed', [
        T.format('engineGitMissing', ['Git']),
      ]),
    );
    expect(row('engineGitGuide')?.title, T.text('engineGitGuideUpstream'));
    choose('engineGitGuide');
    expect(fixture.opened.single, EngineCheckout.upstreamLinuxGuide);
    expect(model.engine.git.guide, EngineCheckout.upstreamLinuxGuide, reason: 'upstream\'s tree: upstream\'s guide');
  });

  test('no build folder: Update from Git sets one up with CMake, then pulls and builds', () async {
    final bare = makeFakeCheckout(p.join(fixture.temp.path, 'Bare'), configured: false);
    model.useOwnFolder(bare);
    expect(row('engineGitUpdate')?.detail, T.text('engineGitSetUpDetail'));
    final hold = Completer<void>();
    commands.results['cmake -S'] = FakeResult(
      lines: const ['-- Configuring done'],
      hold: hold,
      effect: () => configureFakeCheckout(bare),
    );
    commands.results['cmake --build'] = FakeResult(effect: () => buildFakeCheckout(bare));
    choose('engineGitUpdate');
    await until(() => row('engineGitUpdate')!.title.endsWith(T.text('engineGitStepConfiguring')));
    hold.complete();
    await until(() => !model.engine.git.running);
    expect(model.engine.git.failure, isNull);
    expect(commands.lines, contains(startsWith('cmake -S . -B build -G Ninja')));
    expect(model.toolkit?.root, bare, reason: 'the build it set up is the engine now');
    expect(row('engineGitUpdate')?.detail, T.format('engineGitUpdateDetail', ['build']));
    expect(row('engineGitGuide'), isNull);
  });

  test('no build folder and no compiler: says which, and opens AnyPS5-ARM\'s guide for its tree', () async {
    final bare = makeFakeCheckout(p.join(fixture.temp.path, 'Arm'), configured: false, arm: true);
    model.useOwnFolder(bare);
    commands.results['g++ --version'] = const FakeResult(missing: true);
    choose('engineGitUpdate');
    await until(() => !model.engine.git.running);
    expect(
      model.toast,
      T.format('engineGitFailed', [
        T.format('engineGitMissing', [T.text('engineToolCompiler')]),
      ]),
    );
    expect(commands.lines.where((line) => line.startsWith('git pull')), isEmpty);
    expect(row('engineGitGuide')?.title, T.text('engineGitGuideArm'));
    choose('engineGitGuide');
    expect(fixture.opened.single, EngineCheckout.armGuide);
  });

  group('before playing', () {
    setUp(() {
      installedWithCurrentBuild();
      model.preferences.engineGitBeforePlay = true;
      model.select(model.games.indexOf(orbit()));
      model.toast = null;
      // The game keeps running until stopped: a game that ends at once could be gone (and its
      // end said) before the test looks.
      final executable = File(p.join(Installer.installedFolder(orbit(), model.root!), 'app.elf'));
      executable.writeAsStringSync('#!/bin/sh\nsleep 20\n');
      if (!Platform.isWindows) Process.runSync('chmod', ['755', executable.path]);
    });

    Future<void> stop() async {
      model.stopGame();
      await until(() => model.running == null);
    }

    test('new commits: pulled and built, then the game is unlocked again and started', () async {
      commands.results['git rev-list'] = const FakeResult(lines: ['2']);
      remoteHasNewCommit();
      model.primaryAction(orbit());
      await until(() => model.engine.git.running);
      expect(model.toast, T.text('engineGitBeforePlayStart'));
      await until(() => !model.engine.git.running);
      expect(
        model.queue.contains(orbit().id) || model.progress.containsKey(orbit().id),
        isTrue,
        reason: 'unlocked again with the new build, to play after',
      );
      model.cancelUnlock(orbit());
    });

    test('a phone switching games: the check runs for the new one once the first has gone', () async {
      final starts = FakeGameStarts();
      model.startGame = starts.call;
      commands.results['git fetch'] = const FakeResult(code: 128, lines: ['fatal: unable to access']);
      final neon = model.games.firstWhere((game) => game.titleId == 'PPSA02002');
      final neonFolder = Installer.installedFolder(neon, model.root!);
      Directory(neonFolder).createSync(recursive: true);
      File(p.join(neonFolder, 'app.elf')).writeAsStringSync('#!/bin/sh\n');
      File(p.join(neonFolder, Installer.recordName)).writeAsStringSync(
        '{"date":"2026-10-24T12:00:00Z","source":"${neon.folder}","system":"linux","titleID":"PPSA02002",'
        '"toolkit":"${model.toolkitVersion}"}',
      );
      model.rescan();
      await model.startPhoneServer();
      addTearDown(model.stopPhoneServer);
      final phone = await FakePhone.connect(model.remote!.port!);
      phone.hello('phone-1', 'Pixel');
      await phone.next<Pairing>();
      await until(() => model.pairing != null);
      model.answerPairing(true);
      await phone.next<Welcome>();
      await until(() => model.remote!.connectedDevices.isNotEmpty);
      phone.send(Launch(orbit().id));
      await until(() => model.running?.$1 == orbit());
      final fetches = commands.lines.where((line) => line.startsWith('git fetch')).length;
      phone.send(Launch(neon.id));
      await until(() => model.running?.$1 == neon);
      expect(starts.started, hasLength(2));
      expect(starts.processes.first.ended, isTrue);
      expect(
        commands.lines.where((line) => line.startsWith('git fetch')).length,
        greaterThan(fetches),
        reason: 'the new game goes through Update from Git Before Playing',
      );
      await phone.close();
      model.stopGame();
      await until(() => model.running == null);
    });

    test('offline: nothing is said and the game starts', () async {
      commands.results['git fetch'] = const FakeResult(code: 128, lines: ['fatal: unable to access']);
      model.primaryAction(orbit());
      await until(() => model.running != null);
      expect(commands.lines.where((line) => line.startsWith('git pull')), isEmpty);
      expect(model.toast, isNull);
      await stop();
    });

    test('up to date: the game starts without a build', () async {
      commands.results['git rev-list'] = const FakeResult(lines: ['0']);
      model.primaryAction(orbit());
      await until(() => model.running != null);
      expect(commands.lines.where((line) => line.contains('--build')), isEmpty);
      await stop();
    });

    test('a tree with changes: the current build plays, and it is said', () async {
      commands.results['git rev-list'] = const FakeResult(lines: ['1']);
      commands.results['git status'] = const FakeResult(lines: [' M README.md']);
      model.primaryAction(orbit());
      await until(() => model.running != null);
      expect(model.toast, T.format('engineGitPlayAnyway', [T.text('engineGitDirty')]));
      await stop();
    });

    test('a failed build starts nothing', () async {
      commands.results['git rev-list'] = const FakeResult(lines: ['1']);
      commands.results['cmake --build'] = const FakeResult(code: 2, lines: ['ninja: build stopped']);
      model.primaryAction(orbit());
      await until(() => model.engine.git.failure != null);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(model.starting, isNull);
      expect(model.running, isNull);
      expect(model.toast, T.format('engineGitFailed', [T.text('engineGitBuildFailed')]));
    });
  });

  test('Turkish texts', () {
    T.language = Language.byCode('tr');
    expect(row('engineGitUpdate')?.title, "Git'ten güncelle");
    expect(row('engineGitBeforePlay')?.title, "Oynamadan önce Git'ten güncelle");
  });
}
