import 'dart:io';

import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/ui/retro_restart_tuning.dart';
import 'package:anyps5_desktop/ui/retro_game_tuning.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/ui_support.dart';

EmbeddedOption option(List<String> values, int selected, {bool restart = true}) =>
    (values: values, labels: values, title: 'Test option', restart: restart, selected: selected);

void main() {
  test('restart candidates use advertised alternatives and exclude unsupported renderers', () {
    final options = {
      'rpcs3_renderer': option(['vulkan', 'opengl'], 0),
      'rpcs3_preferred_spu_threads': option(['0', '1', '2'], 0),
      'rpcs3_limit_cache_size': option(['disabled', 'enabled'], 0),
    };
    final candidates = restartTuningChoices(RetroPlatform.ps3, options);
    expect(candidates.where((choice) => choice.key == 'rpcs3_renderer'), isEmpty);
    expect(candidates.where((choice) => choice.key == 'rpcs3_preferred_spu_threads').map((c) => c.value), ['2']);
  });

  test('I/O choices require a declared restart option and exclude the current value', () {
    const key = 'swanstation_CDROM_ReadThread';
    expect(
      restartTuningChoices(RetroPlatform.ps1, {
        key: option(['false', 'true'], 0, restart: false),
      }),
      isEmpty,
    );
    expect(
      restartTuningChoices(RetroPlatform.ps1, {
        key: option(['false', 'true'], 0),
      }).single.value,
      'true',
    );
  });

  test('a renderer fallback cannot pass as the requested renderer', () {
    final choice = restartTuningChoices(RetroPlatform.ps2, {
      'pcsx2_renderer': option(['D3D11', 'Software (SW)'], 1),
    }).single;
    expect(restartRendererMatches(choice, hardware: false), isFalse);
    expect(restartRendererMatches(choice, hardware: true), isTrue);
  });

  testWidgets('restart trial boots temporary settings, measures both runs and saves only on Apply', (tester) async {
    const key = 'swanstation_CPU_ExecutionMode';
    const original = 'Recompiler';
    const temporary = 'CachedInterpreter';
    const channel = MethodChannel('anyps5/retro_core');
    final environment = <String, String>{};
    final fixture = makeFixture(environment: environment);
    final app = fixture.model;
    final home = fixture.temp.path;
    environment['ANYPS5_LIBRETRO_HOME'] = home;
    File(p.join(home, 'swanstation_libretro.dll')).createSync();
    final disc = File(p.join(home, 'test.cue'))..createSync();
    final game = Game(
      folder: home,
      titleId: 'PS1-RESTART',
      name: 'Restart test',
      names: const {},
      defaultLanguage: 'en',
      version: '',
      executable: ExecutableKind.disc,
      retro: (platform: RetroPlatform.ps1, path: disc.path),
    );
    final starts = <Map<Object?, Object?>>[];
    var ended = false;
    var current = original;
    var clock = 0;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'start':
          final arguments = call.arguments as Map<Object?, Object?>;
          starts.add(arguments);
          current = (arguments['graphics'] as Map?)?[key] as String? ?? original;
          ended = false;
          clock = 0;
          return starts.length;
        case 'status':
          clock += 2000;
          final frames = clock * (current == original ? 50 : 60) ~/ 1000;
          return {
            'presented': true,
            'ended': ended,
            'hardware': true,
            'options': {
              key: {
                'title': 'CPU execution',
                'restart': true,
                'values': [original, temporary],
                'selected': current == original ? 0 : 1,
                'activeValue': current,
              },
            },
            'tuningTelemetry': {
              'clockMs': clock,
              'frames': frames,
              'steps': frames,
              'audioFrames': clock * 48,
              'droppedAudioFrames': 0,
              'frameIntervals': [0, 0, 0, frames, 0, 0, 0, 0, 0, 0, 0, 0, 0],
              'targetFps': 60.0,
              'audioRate': 48000.0,
            },
          };
        case 'stop':
          ended = true;
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      app.dispose();
      fixture.dispose();
    });
    void selectRow(String id) {
      final row = app.panelCategories().single.rows.singleWhere((row) => row.id == id);
      (row.kind as ActionRow).run();
    }

    Future<void> tick([int count = 1]) async {
      for (var i = 0; i < count; i++) {
        await tester.pump(const Duration(milliseconds: 150));
      }
    }

    app.games = [game];
    final baselineRun = app.play(game);
    await tick(2);
    app.open(Layer.retroGraphics);
    selectRow('emulator-tune-game');
    selectRow('tuning-restart-trials');
    selectRow('restart-record-baseline');
    await tick(9);
    app.open(Layer.retroGraphics);
    selectRow('emulator-tune-game');
    selectRow('tuning-restart-trials');
    selectRow('restart-start');
    await tick(4);
    await baselineRun;

    expect(starts, hasLength(2));
    expect(starts.last['graphics'], {key: temporary});
    expect(app.preferences.retroEmbeddedGraphics, isEmpty);
    app.open(Layer.retroGraphics);
    selectRow('emulator-tune-game');
    selectRow('restart-record-candidate');
    await tick(9);
    app.open(Layer.retroGraphics);
    selectRow('emulator-tune-game');
    selectRow('restart-apply');
    expect(app.preferences.retroEmbeddedGraphics, {
      game.id: {key: temporary},
    });
    selectRow('restart-undo');
    await tick(4);
    expect(starts, hasLength(3));
    expect(starts.last['graphics'], isNull);
    expect(app.preferences.retroEmbeddedGraphics, isEmpty);
    app.open(Layer.retroGraphics);
    selectRow('emulator-tune-game');
    selectRow('tuning-restart-trials');
    selectRow('restart-record-baseline');
    await tick(9);
    app.open(Layer.retroGraphics);
    selectRow('emulator-tune-game');
    selectRow('tuning-restart-trials');
    selectRow('restart-start');
    app.closeRunningGame();
    await tick(4);
    expect(starts, hasLength(3), reason: 'explicit Close must cancel the pending relaunch');
    expect(app.embeddedGame, isNull);
    await tester.pump(const Duration(seconds: 5));
  });
}
