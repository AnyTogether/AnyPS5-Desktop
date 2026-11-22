import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/retro_host/retro_auto_resolution.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_protocol.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_session.dart';
import 'package:anyps5_desktop/ui/retro_host/retro_auto_controller.dart';
import 'package:anyps5_desktop/ui/retro_host/retro_game_menu.dart';
import 'package:anyps5_desktop/ui/retro_host/retro_host_game.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_retro_host_session.dart';

const _request = RetroHostStartRequest(core: 'c', disc: 'd.cue', system: 's', saves: 'v');

/// A clock the test moves by hand.
class _Clock implements Stopwatch {
  @override
  Duration elapsed = Duration.zero;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The Auto Optimizer of a PS1 game on a fake host whose statuses are the real host's recorded
/// Spyro the Dragon status with `gamePerformance` (test/fixtures/retro-host-performance-status.json,
/// anyps5-retro-host fixtures/v1/messages/call-status-performance.json), at the scale and speed
/// each step needs.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final spyro =
      ((jsonDecode(File('test/fixtures/retro-host-performance-status.json').readAsStringSync()) as Map)['status']
              as Map)
          .cast<String, Object?>();

  RetroStatus status({int scale = 2, double? speed = 1, double work = 0.08, String gpu = 'RTX', bool pending = false}) {
    final options = (spyro['options']! as Map).cast<String, Object?>();
    final resolution = (options['swanstation_GPU_ResolutionScale']! as Map).cast<String, Object?>();
    return RetroStatus.parse({
      ...spyro,
      'graphicsPending': pending,
      'options': {
        ...options,
        'swanstation_GPU_ResolutionScale': {...resolution, 'selected': scale - 1, 'activeValue': '$scale'},
      },
      'performance': speed == null ? null : {'speed': speed, 'work': work, 'seconds': 5},
      'gpu': {'renderer': gpu, 'vendor': 'v', 'maxTexture': 16384},
    }, performance: true);
  }

  late FakeRetroHostSession session;
  late RetroHostGame game;
  late RetroGameMenu menu;
  late _Clock clock;
  late Map<String, RetroAutoMemory> memories;
  late int saves;
  late List<String> log;

  setUp(() {
    session = FakeRetroHostSession()..reportsPerformance = true;
    game = RetroHostGame(session, statusEvery: const Duration(hours: 1), volume: 0.5);
    menu = RetroGameMenu(game);
    clock = _Clock();
    memories = {};
    saves = 0;
    log = [];
  });

  tearDown(() {
    menu.dispose();
    game.dispose();
  });

  RetroAutoController controller({int need = 5}) => RetroAutoController(
    menu: menu,
    titleId: 'PS1-SCUS94228',
    memories: memories,
    need: () => need,
    saved: () => saves++,
    log: log.add,
    clock: clock,
  );

  Future<void> started(RetroStatus first) async {
    session.readyCompleter.complete();
    session.nextStatus = first;
    await game.start(_request);
  }

  /// Moves the clock to [seconds], the host's next status to [next], and judges it.
  Future<void> at(RetroAutoController auto, int seconds, RetroStatus next) async {
    clock.elapsed = Duration(seconds: seconds);
    session.nextStatus = next;
    await game.refresh();
    await auto.tick();
  }

  List<Object?> options() => [for (final call in session.calls.where((call) => call.$1 == 'option')) call.$2];

  test('a slow game is lowered one scale, and the slow scale is remembered for the game', () async {
    await started(status(scale: 4, speed: null));
    session.callResults['option'] = true;
    final auto = controller();
    await at(auto, 0, status(scale: 4, speed: null));
    expect(memories['PS1-SCUS94228']!.toJson(), {'gpu': 'RTX', 'host': '1.2.0', 'config': '', 'scale': 4});
    await at(auto, 20, status(scale: 4, speed: 0.6, work: 1.5));
    expect(options(), isEmpty, reason: 'one slow reading is not enough, and the first 20 seconds are not judged');
    await at(auto, 25, status(scale: 4, speed: 0.6, work: 1.5));
    expect(options(), [
      {'key': 'swanstation_GPU_ResolutionScale', 'value': '3'},
    ]);
    expect(memories['PS1-SCUS94228']!.slow, {4});
    expect(memories['PS1-SCUS94228']!.scale, 3);
    expect(saves, greaterThanOrEqualTo(2));
    expect(log.single, 'auto resolution: 4x to 3x for PS1-SCUS94228 (speed 0.6, work 1.5)');

    await at(auto, 30, status(scale: 3, pending: true));
    await at(auto, 50, status(scale: 3, speed: 1));
    expect(options(), hasLength(1), reason: 'settling at 3x');
  });

  test('a minute of headroom raises it one scale, up to what the display needs', () async {
    await started(status(scale: 2));
    session.callResults['option'] = true;
    final auto = controller(need: 3);
    for (var seconds = 0; seconds <= 75; seconds += 5) {
      await at(auto, seconds, status(scale: 2));
    }
    expect(options(), [
      {'key': 'swanstation_GPU_ResolutionScale', 'value': '3'},
    ]);
    for (var seconds = 80; seconds <= 300; seconds += 5) {
      await at(auto, seconds, status(scale: 3));
    }
    expect(options(), hasLength(1), reason: '4x is past a 720-line display');
  });

  test('a refused change is not counted as made, and nothing is judged while the menu is open', () async {
    await started(status(scale: 4));
    session.callResults['option'] = false;
    final auto = controller();
    await at(auto, 20, status(scale: 4, speed: 0.6, work: 1.5));
    await at(auto, 25, status(scale: 4, speed: 0.6, work: 1.5));
    expect(options(), hasLength(1));
    expect(memories['PS1-SCUS94228']!.scale, 4, reason: 'the host kept 4x');
    await menu.open();
    session.callResults['option'] = true;
    await at(auto, 30, status(scale: 4, speed: 0.6, work: 1.5));
    await at(auto, 35, status(scale: 4, speed: 0.6, work: 1.5));
    expect(options(), hasLength(1), reason: 'the menu is open: the game is paused');
  });

  test('another GPU or graphics setting starts the memory again; the same keeps its slow scales', () async {
    memories['PS1-SCUS94228'] = RetroAutoMemory(gpu: 'RTX', host: '1.2.0', config: '', scale: 4, slow: {6});
    await started(status(scale: 4));
    final auto = controller(need: 8);
    await at(auto, 0, status(scale: 4));
    expect(memories['PS1-SCUS94228']!.slow, {6}, reason: 'measured on this GPU and host');
    await at(auto, 5, status(scale: 4, gpu: 'Radeon'));
    expect(memories['PS1-SCUS94228']!.slow, isEmpty, reason: 'another GPU: what was learned does not hold');
    expect(memories['PS1-SCUS94228']!.gpu, 'Radeon');
  });

  test('the menu opening breaks the run of readings', () async {
    await started(status(scale: 4));
    session.callResults['option'] = true;
    final auto = controller();
    await at(auto, 20, status(scale: 4, speed: 0.6, work: 1.5));
    await menu.open();
    await at(auto, 25, status(scale: 4, speed: null));
    await menu.close();
    await at(auto, 300, status(scale: 4, speed: 0.6, work: 1.5));
    expect(options(), isEmpty, reason: 'one slow reading before the pause and one after');
    await at(auto, 305, status(scale: 4, speed: 0.6, work: 1.5));
    expect(options(), hasLength(1));
  });

  test('the menu opening between two judgements breaks the run of readings too', () async {
    await started(status(scale: 4));
    session.callResults['option'] = true;
    final auto = RetroAutoController(
      menu: menu,
      titleId: 'PS1-SCUS94228',
      memories: memories,
      need: () => 5,
      saved: () => saves++,
      every: const Duration(hours: 1),
      clock: clock,
    )..start();
    addTearDown(auto.dispose);
    await at(auto, 20, status(scale: 4, speed: 0.6, work: 1.5));
    await menu.open();
    await menu.close();
    await at(auto, 300, status(scale: 4, speed: 0.6, work: 1.5));
    expect(options(), isEmpty, reason: 'no judgement saw the menu open, yet it broke the run');
    await at(auto, 305, status(scale: 4, speed: 0.6, work: 1.5));
    expect(options(), hasLength(1));
  });

  test('stopping waits for a change already asked, and does not count it', () async {
    await started(status(scale: 4));
    session.callResults['option'] = true;
    final auto = controller();
    await at(auto, 20, status(scale: 4, speed: 0.6, work: 1.5));
    clock.elapsed = const Duration(seconds: 25);
    session.nextStatus = status(scale: 4, speed: 0.6, work: 1.5);
    await game.refresh();
    final gate = session.callGate = Completer<void>();
    final ticking = auto.tick();
    await pumpEventQueue();
    var stopped = false;
    final stopping = auto.stop().then((_) => stopped = true);
    await pumpEventQueue();
    expect(stopped, isFalse, reason: 'the change asked is not answered yet');
    session.callGate = null;
    gate.complete();
    await stopping;
    await ticking;
    expect(memories['PS1-SCUS94228']!.scale, 4, reason: 'stopped: the change is not counted');
    expect(log, isEmpty);
  });

  test('a host without gamePerformance is not judged', () async {
    session.reportsPerformance = false;
    await started(status(scale: 4));
    final auto = controller();
    await at(auto, 20, status(scale: 4, speed: 0.5, work: 1.5));
    await at(auto, 25, status(scale: 4, speed: 0.5, work: 1.5));
    expect(options(), isEmpty);
    expect(memories, isEmpty);
  });
}
