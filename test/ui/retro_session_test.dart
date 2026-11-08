import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/desktop/desktop.dart';
import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/gamepad/pad_navigation.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/retro_settings.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/game_action.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_process.dart';
import '../support/ui_support.dart';
import 'desktop_features_test.dart' show FakePads;

class _RetroDesktop extends NoDesktop {
  final calls = <String>[];
  bool inLauncher = false;
  bool canFocus = true;

  @override
  bool launcherFocused() => inLauncher;

  @override
  Future<bool> raiseLauncher() async {
    calls.add('raise');
    return inLauncher = true;
  }

  @override
  Future<bool> focusGame(int pid) async {
    calls.add('focus $pid');
    if (canFocus) inLauncher = false;
    return canFocus;
  }

  @override
  Future<bool> pressKey(int pid, String key, {Duration hold = const Duration(milliseconds: 100)}) async {
    calls.add('key $key');
    return true;
  }
}

void main() {
  for (final (platform, filename) in [(RetroPlatform.ps1, 'disc.cue'), (RetroPlatform.ps2, 'disc.iso')]) {
    test('${platform.name} uses Play, the PS quick menu and Resume for the same emulator process', () async {
      final environment = <String, String>{};
      final desktop = _RetroDesktop();
      final pads = FakePads();
      final fixture = makeFixture(
        desktop: desktop,
        environment: environment,
        system: HostSystem.windows,
        pads: () => pads,
      );
      final model = fixture.model..startPads();
      addTearDown(() {
        model.dispose();
        fixture.dispose();
      });

      final program = File(p.join(fixture.temp.path, '${platform.name}.exe'))..createSync();
      environment[platform.executableVariable] = program.path;
      final folder = Directory(p.join(model.root!, 'Retro'))..createSync();
      final disc = File(p.join(folder.path, filename))..createSync();
      File(p.join(folder.path, 'retro.json')).writeAsStringSync(
        jsonEncode({'platform': platform.name, 'titleId': 'TEST12345', 'name': 'Retro game', 'disc': filename}),
      );
      model.rescan();

      final process = FakeGameProcess();
      addTearDown(process.quit);
      final run = runningFor(process);
      model.startRetroGame = ({required installed, required program, required arguments, required logFile}) async {
        expect(program, environment[platform.executableVariable]);
        expect(installed, fixture.temp.path);
        expect(arguments, ['-nogui', '--', disc.path]);
        expect(p.basename(logFile), '${platform.name.toUpperCase()}-TEST12345.log');
        return run;
      };

      final game = model.games.singleWhere((game) => game.retro != null);
      model.select(model.games.indexOf(game));
      expect(GameAction.of(model.stateOf(game)).title, 'Play');
      model.primaryAction(game);
      await pumpEventQueue();
      expect(model.running, (game, run));
      expect(model.stateOf(game), isA<Running>());
      expect(desktop.calls, ['focus ${process.pid}']);
      desktop.calls.clear();

      pads.press(PadButton.south);
      expect(model.overlay, isNull, reason: 'the controller confirm belongs to the game until PS opens the menu');
      pads.press(PadButton.guide);
      await pumpEventQueue();
      expect(desktop.calls, ['raise'], reason: 'the emulator pauses on focus loss without a PS5 key press');
      expect(model.overlay, Layer.quickMenu);
      final panel = model.panelCategories().single;
      expect(panel.id, 'quickMenu');
      expect(panel.title, game.name);
      expect(panel.rows.map((row) => row.id), containsAllInOrder(['resume', 'gameSettings', 'closeGame']));

      desktop.canFocus = false;
      pads.press(PadButton.south);
      await pumpEventQueue();
      expect(model.overlay, Layer.quickMenu);
      expect(desktop.inLauncher, isTrue);

      desktop.canFocus = true;
      pads.press(PadButton.south);
      await pumpEventQueue();
      expect(desktop.calls, ['raise', 'focus ${process.pid}', 'raise', 'focus ${process.pid}']);
      expect(model.overlay, isNull);
      expect(desktop.inLauncher, isFalse);
      expect(model.running, (game, run));
      expect(process.ended, isFalse);

      await model.openQuickMenu();
      final graphics = model.panelCategories().single.rows.singleWhere((row) => row.id == 'retroGraphics');
      (graphics.kind as ActionRow).run();
      final resolution = model.panelCategories().single.rows.singleWhere((row) => row.title == 'Internal Resolution');
      final choice = resolution.kind as ChoiceRow;
      choice.set(choice.options.indexWhere((label) => label.startsWith('3×')));
      final profile = RetroSettings.configFile(program.path, platform);
      expect(profile.existsSync(), isFalse, reason: 'The emulator still owns the profile.');
      final restored = Preferences.fromJson(jsonDecode(jsonEncode(model.preferences.toJson())) as Map<String, dynamic>);
      expect(restored.pendingRetroGraphics[profile.path]?.values, ['3']);

      model.closeOverlay();
      await pumpEventQueue();
      expect(model.overlay, isNull);
      expect(desktop.inLauncher, isFalse);
      expect(model.running, (game, run));

      process.quit();
      await pumpEventQueue();
      expect(model.running, isNull);
      expect(model.overlay, isNull);
      expect(model.stateOf(game), isA<Installed>());
      expect(
        model.retroSettings.categories(platform).map((category) => category.id),
        isNot(contains('retro-${platform.name}-optimize')),
      );
      final nextProcess = FakeGameProcess();
      addTearDown(nextProcess.quit);
      model.startRetroGame = ({required installed, required program, required arguments, required logFile}) async {
        expect(RetroSettings.read(profile).options.single.value, '3');
        return runningFor(nextProcess);
      };
      final nextLaunch = model.play(game);
      await pumpEventQueue();
      expect(model.running?.$1, game);
      expect(model.preferences.pendingRetroGraphics, isEmpty);
      nextProcess.quit();
      await nextLaunch;
    });
  }
}
