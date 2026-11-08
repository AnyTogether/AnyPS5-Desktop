import 'dart:async';
import 'dart:io';

import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/game_process.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_process.dart';
import '../support/ui_support.dart';

class _ClosingGame extends RunningGame {
  _ClosingGame(FakeGameProcess process, {this.closeBarrier}) : super(process, process.exitCode, DateTime.now());

  final requested = Completer<void>();
  final Completer<void>? closeBarrier;
  int closeRequests = 0;

  @override
  Future<void> close() async {
    closeRequests++;
    if (!requested.isCompleted) requested.complete();
    await closeBarrier?.future;
  }
}

Game _discGame(RetroPlatform platform) => Game(
  folder: 'retro',
  titleId: 'TEST12345',
  name: 'Retro game',
  names: const {'en-US': 'Retro game'},
  defaultLanguage: 'en-US',
  version: '',
  executable: ExecutableKind.disc,
  retro: (platform: platform, path: 'disc'),
);

void main() {
  for (final platform in RetroPlatform.ps1AndPs2) {
    test('${platform.name} Quit waits for the emulator to flush its saves and exit', () async {
      final quits = <int>[];
      final fixture = makeFixture(quit: quits.add);
      final process = FakeGameProcess();
      final run = _ClosingGame(process);
      final model = fixture.model..running = (_discGame(platform), run);
      addTearDown(() {
        process.quit();
        model.dispose();
        fixture.dispose();
      });

      model.quitLauncher();
      await run.requested.future;
      model.quitLauncher();
      await pumpEventQueue();
      expect(run.closeRequests, 1, reason: 'repeated Quit keeps the same shutdown attempt');
      expect(quits, isEmpty);
      expect(process.ended, isFalse);
      expect(process.signals, isEmpty);

      process.quit();
      await pumpEventQueue();
      expect(quits, [0]);
      expect(process.signals, isEmpty, reason: 'a normal emulator exit needs no forced termination');
    });
  }

  test('window-close preparation ends an unresponsive emulator after the grace period', () async {
    final fixture = makeFixture();
    final process = FakeGameProcess();
    final run = _ClosingGame(process);
    final model = fixture.model
      ..running = (_discGame(RetroPlatform.ps2), run)
      ..stopGrace = const Duration(milliseconds: 20);
    addTearDown(() {
      process.quit();
      model.dispose();
      fixture.dispose();
    });

    expect(await model.prepareToQuit(), isTrue);
    expect(run.closeRequests, 1);
    expect(process.signals, [ProcessSignal.sigkill]);
    expect(process.ended, isTrue);
  });

  test('a stuck close request does not prevent the bounded emulator shutdown', () async {
    final fixture = makeFixture();
    final process = FakeGameProcess();
    final barrier = Completer<void>();
    final run = _ClosingGame(process, closeBarrier: barrier);
    final model = fixture.model
      ..running = (_discGame(RetroPlatform.ps1), run)
      ..stopGrace = const Duration(milliseconds: 20);
    addTearDown(() {
      barrier.complete();
      process.quit();
      model.dispose();
      fixture.dispose();
    });

    expect(await model.prepareToQuit(), isTrue);
    expect(run.closeRequests, 1);
    expect(process.signals, [ProcessSignal.sigkill]);
    expect(process.ended, isTrue);
  });

  test('PS5 Quit retains its immediate process stop and launcher exit', () {
    final quits = <int>[];
    final fixture = makeFixture(quit: quits.add);
    final process = FakeGameProcess();
    final run = _ClosingGame(process);
    final model = fixture.model..running = (fixture.model.games.first, run);
    addTearDown(() {
      process.quit();
      model.dispose();
      fixture.dispose();
    });

    model.quitLauncher();
    expect(quits, [0]);
    expect(process.signals, [ProcessSignal.sigterm]);
    expect(run.closeRequests, 0);
  });

  test('Quit and window close wait while an emulator launch is pending', () async {
    final quits = <int>[];
    final fixture = makeFixture(quit: quits.add);
    final model = fixture.model..starting = _discGame(RetroPlatform.ps2);
    addTearDown(() {
      model.dispose();
      fixture.dispose();
    });

    expect(await model.prepareToQuit(), isFalse);
    model.quitLauncher();
    await pumpEventQueue();
    expect(quits, isEmpty);
    expect(model.starting, isNotNull);

    model.starting = null;
    model.quitLauncher();
    expect(quits, [0]);
  });
}
