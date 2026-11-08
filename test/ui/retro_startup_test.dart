import 'dart:io';

import 'package:anyps5_desktop/core/desktop/desktop.dart';
import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/game_process.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_process.dart';
import '../support/ui_support.dart';

class _WindowDesktop extends NoDesktop implements GameAreas {
  ScreenArea? area;
  final queried = <int>[];
  final focused = <int>[];

  @override
  Future<bool> focusGame(int pid) async {
    focused.add(pid);
    return true;
  }

  @override
  ScreenArea? gameArea(int pid) {
    queried.add(pid);
    return area;
  }

  @override
  String? gameTitle(int pid) => area == null ? null : 'Game';
}

class _StartingGame extends RunningGame {
  _StartingGame(FakeGameProcess process) : super(process, process.exitCode, DateTime.now());

  int closeRequests = 0;

  @override
  Future<void> close() async => closeRequests++;
}

void main() {
  for (final platform in RetroPlatform.ps1AndPs2) {
    group('${platform.name} startup', () {
      late Fixture fixture;
      late AppModel model;
      late _WindowDesktop desktop;
      late FakeGameProcess process;
      late _StartingGame run;
      late Game game;

      setUp(() {
        final environment = <String, String>{};
        desktop = _WindowDesktop();
        fixture = makeFixture(desktop: desktop, environment: environment);
        model = fixture.model;
        final program = File(p.join(fixture.temp.path, 'emulator.exe'))..createSync();
        environment[platform.executableVariable] = program.path;
        final disc = File(p.join(fixture.temp.path, 'disc.iso'))..createSync();
        game = Game(
          folder: fixture.temp.path,
          titleId: 'RETRO-STARTUP',
          name: 'Retro game',
          names: const {'en-US': 'Retro game'},
          defaultLanguage: 'en-US',
          version: '',
          executable: ExecutableKind.disc,
          retro: (platform: platform, path: disc.path),
        );
        process = FakeGameProcess(ignoresTerm: true);
        run = _StartingGame(process);
        model.startRetroGame = ({required installed, required program, required arguments, required logFile}) async =>
            run;
      });

      tearDown(() async {
        process.quit();
        await pumpEventQueue();
        model.dispose();
        fixture.dispose();
      });

      test('stays Starting until the tracked emulator has a visible game area', () async {
        final playing = model.play(game);
        await pumpEventQueue();
        expect(model.running, (game, run), reason: 'the PS menu can close a tracked process during startup');
        expect(model.starting, game);
        expect(model.stateOf(game), isA<Starting>());
        expect(desktop.queried, contains(process.pid));
        expect(desktop.focused, isEmpty);

        desktop.area = const ScreenArea(0, 0, 1920, 1080);
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(model.starting, isNull);
        expect(model.stateOf(game), isA<Running>());
        expect(process.ended, isFalse);
        expect(desktop.focused, [process.pid]);

        process.quit();
        await playing;
      });

      test('exit before a game window clears Starting and the tracked session', () async {
        final playing = model.play(game);
        await pumpEventQueue();
        expect(model.starting, game);
        process.quit(1);
        await playing;
        expect(model.starting, isNull);
        expect(model.running, isNull);
        expect(model.stateOf(game), isA<Installed>());
        expect(desktop.focused, isEmpty);
      });

      test('readiness keeps a Quick Menu opened during startup in front', () async {
        final playing = model.play(game);
        await pumpEventQueue();
        await model.openQuickMenu();
        expect(model.overlay, Layer.quickMenu);

        desktop.area = const ScreenArea(0, 0, 1920, 1080);
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(model.starting, isNull);
        expect(model.overlay, Layer.quickMenu);
        expect(desktop.focused, isEmpty);

        process.quit();
        await playing;
      });

      test('window timeout requests graceful close and ends an unresponsive emulator after its grace', () async {
        model.retroStartTimeout = const Duration(milliseconds: 30);
        model.stopGrace = const Duration(milliseconds: 20);
        await model.play(game);
        expect(run.closeRequests, 1);
        expect(process.signals, [ProcessSignal.sigkill]);
        expect(process.ended, isTrue);
        expect(model.starting, isNull);
        expect(model.running, isNull);
        expect(model.stateOf(game), isA<Installed>());
      });
    });
  }
}
