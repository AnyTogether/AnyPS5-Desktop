import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/retro_host/retro_auto_resolution.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Auto Optimizer's PS1 resolution, fed statuses the real host sent with `gamePerformance`:
/// Spyro the Dragon at full speed (test/fixtures/retro-host-performance-status.json) and Jak and
/// Daxter at 8x, which did not keep up (test/fixtures/retro-host-ps2-performance-status.json), both
/// copied from anyps5-retro-host fixtures/v1/messages. Each reading's speed and work is the
/// recording's, or one measured in the host's real-game runs (Jak at 4x read 0.956 to 0.990).
void main() {
  Map<String, Object?> recorded(String name) =>
      ((jsonDecode(File('test/fixtures/$name').readAsStringSync()) as Map)['status'] as Map).cast<String, Object?>();

  final spyro = recorded('retro-host-performance-status.json');
  final jak = recorded('retro-host-ps2-performance-status.json');

  RetroStatus status({double? speed, double? work = 0.08, Map<String, Object?> fields = const {}}) =>
      RetroStatus.parse({
        ...spyro,
        if (speed != null) 'performance': {'speed': speed, 'work': work, 'seconds': 5} else 'performance': null,
        ...fields,
      }, performance: true);

  Duration s(int seconds) => Duration(seconds: seconds);

  RetroAutoMemory memory() => RetroAutoMemory(gpu: '', host: '1.2.0', config: '');

  RetroAutoResolution optimizer({int scale = 4, int need = 8, RetroAutoMemory? remembered}) =>
      RetroAutoResolution(scales: [1, 2, 3, 4, 6, 8], need: need, memory: remembered ?? memory(), scale: scale);

  /// Feeds one reading every 5 seconds from [from], returning the first change asked and when.
  (int, Duration)? feed(RetroAutoResolution auto, List<RetroStatus> readings, {required Duration from}) {
    for (final (index, reading) in readings.indexed) {
      final at = from + RetroAutoRules.window * index;
      final change = auto.observe(at, reading);
      if (change != null) return (change, at);
    }
    return null;
  }

  test("the host's statuses read: performance and gpu with gamePerformance, ignored without", () {
    final ps1 = RetroStatus.parse(spyro, performance: true);
    expect(ps1.performance!.speed, 0.9997);
    expect(ps1.performance!.work, 0.0808);
    expect(ps1.performance!.seconds, 5);
    expect(ps1.gpu!.renderer, 'NVIDIA GeForce RTX 4080 SUPER/PCIe/SSE2');
    expect(ps1.gpu!.vendor, 'NVIDIA Corporation');
    expect(ps1.gpu!.maxTexture, 32768);
    final ps2 = RetroStatus.parse(jak, ps2: true, performance: true);
    expect((ps2.performance!.speed, ps2.performance!.work), (0.6273, 1.5752));
    final older = RetroStatus.parse(spyro);
    expect((older.performance, older.gpu), (null, null));
    expect(RetroStatus.parse({...spyro, 'performance': null, 'gpu': null}, performance: true).performance, isNull);
    expect(
      RetroStatus.parse({
        ...spyro,
        'performance': {'speed': 1, 'work': null, 'seconds': 5},
      }, performance: true).performance!.work,
      isNull,
      reason: 'no frame ended in the window',
    );
    for (final bad in [
      {
        'performance': {'speed': -1, 'work': 0.1, 'seconds': 5},
      },
      {
        'performance': {'speed': 1, 'seconds': 5},
      },
      {
        'performance': {'speed': 1, 'work': 0.1, 'seconds': 0},
      },
      {
        'gpu': {'renderer': 'x', 'vendor': 'y', 'maxTexture': -1},
      },
      {'gpu': 'x'},
    ]) {
      expect(() => RetroStatus.parse({...spyro, ...bad}, performance: true), throwsA(isA<RetroProtocolError>()));
    }
    final missing = {...spyro}..remove('performance');
    expect(() => RetroStatus.parse(missing, performance: true), throwsA(isA<RetroProtocolError>()));
    expect(RetroStatus.parse(missing).performance, isNull, reason: 'a host without the capability');
  });

  test('a status that differs only in its performance says nothing new', () {
    final one = status(speed: 1);
    expect(one.sameAs(status(speed: 0.5)), isTrue, reason: 'measured every call; the launcher does not redraw');
    expect(one.sameAs(status(speed: 1, fields: {'graphicsPending': true})), isFalse);
    expect(one.toJson()['performance'], {'speed': 1.0, 'work': 0.08, 'seconds': 5.0});
  });

  test('the scale a game starts at: remembered, else 2x, never past the display or a slow one', () {
    const scales = [1, 2, 3, 4, 6, 8];
    expect(RetroAutoResolution.startScale(scales, need: 5), 2);
    expect(RetroAutoResolution.startScale(scales, need: 1), 1, reason: 'a 240-line display');
    expect(RetroAutoResolution.startScale(scales, need: 5, memory: memory()..scale = 4), 4);
    expect(RetroAutoResolution.startScale(scales, need: 3, memory: memory()..scale = 6), 3);
    expect(
      RetroAutoResolution.startScale(
        scales,
        need: 8,
        memory: memory()
          ..scale = 6
          ..slow.add(6),
      ),
      4,
      reason: 'a scale that ran slow is never chosen',
    );
    expect(RetroAutoResolution.startScale([1, 2], need: 8, memory: memory()..scale = 4), 2, reason: 'listed only');
    expect(RetroAutoResolution.startScale([3, 4], need: 2), 3, reason: 'the smallest the host lists');
    expect(retroAutoDisplayNeed(1080), 5);
    expect(retroAutoDisplayNeed(1440), 6);
    expect(retroAutoDisplayNeed(2160), 9);
    expect(retroAutoDisplayNeed(0), 1);
  });

  test('two slow readings in a row step down one scale and mark it slow, after the settle time', () {
    final auto = optimizer();
    final slow = status(speed: 0.6273, work: 1.5752);
    expect(auto.observe(s(0), slow), isNull);
    expect(auto.observe(s(10), slow), isNull);
    expect(auto.observe(s(15), slow), isNull, reason: 'loading and shader compiles: not judged');
    expect(auto.observe(s(20), slow), isNull, reason: 'one slow reading is not enough');
    expect(auto.observe(s(22), slow), isNull, reason: 'the next reading is about 5 seconds on, not overlapping');
    expect(auto.observe(s(25), slow), 3);
    expect(auto.memory.slow, {4});
    auto.changed(s(25), 3);
    expect((auto.scale, auto.memory.scale), (3, 3));
    expect(auto.observe(s(30), slow), isNull, reason: 'settling at the new scale');
    expect(feed(auto, [slow, slow], from: s(45)), (2, s(50)));
  });

  test('a slow half minute steps down: the Jak at 4x readings, never one window', () {
    final readings = [0.990, 0.983, 0.975, 0.956, 0.989, 0.988].map((speed) => status(speed: speed)).toList();
    final auto = optimizer();
    expect(feed(auto, readings.take(5).toList(), from: s(20)), isNull);
    expect(auto.observe(s(45), readings.last), 3, reason: 'six readings in a row, each under 0.995');
    final steady = optimizer();
    expect(
      feed(
        steady,
        [0.9964, 1.0031, 0.9970, 1.0012, 0.9997, 0.9980, 1.0004].map((speed) => status(speed: speed)).toList(),
        from: s(20),
      ),
      isNull,
      reason: "Spyro's full-speed readings, a frame either way",
    );
  });

  test('a slow moment is not a slow scale: the live Spyro readings, and slow frames that took little time', () {
    final dip = [
      (1.0031, 0.1595),
      (0.9997, 0.1673),
      (0.9997, 0.2128),
      (0.9997, 0.216),
      (0.983, 0.2555),
      (0.8359, 0.7844),
      (0.9997, 0.17),
      (0.9997, 0.17),
    ].map((reading) => status(speed: reading.$1, work: reading.$2)).toList();
    expect(
      feed(optimizer(scale: 2), dip, from: s(55)),
      isNull,
      reason: 'Spyro at 2x on an RTX 4080 SUPER dipped once for a scene: the scale was not the cause',
    );
    final stalled = [status(speed: 0.6, work: 0.3), status(speed: 0.6, work: 0.3)];
    expect(feed(optimizer(), stalled, from: s(20)), isNull, reason: 'frames that took little time: not the scale');
  });

  test("a timer's readings a few milliseconds early still count", () {
    final auto = optimizer();
    final slow = status(speed: 0.6, work: 1.5);
    expect(auto.observe(const Duration(milliseconds: 20001), slow), isNull);
    expect(auto.observe(const Duration(milliseconds: 24998), slow), 3, reason: 'a 5-second timer firing 3 ms early');
    final fast = optimizer();
    expect(fast.observe(s(20), slow), isNull);
    expect(fast.observe(s(23), slow), isNull, reason: 'well inside the last reading: it would overlap it');
  });

  test('anything but play breaks the run of readings', () {
    final slow = status(speed: 0.6, work: 1.5);
    for (final gap in [
      status(),
      status(speed: 0.6, work: 1.5, fields: {'graphicsPending': true}),
      status(speed: 0.6, work: 1.5, fields: {'progressLabel': 'Changing disc'}),
    ]) {
      final auto = optimizer();
      expect(auto.observe(s(20), slow), isNull);
      expect(auto.observe(s(25), gap), isNull);
      expect(auto.observe(s(30), slow), isNull, reason: 'the slow reading before $gap no longer counts');
      expect(auto.observe(s(35), slow), 3);
    }
  });

  test('a minute of headroom steps up one scale, never past the display or a slow scale', () {
    final fast = status(speed: 0.9997, work: 0.0808);
    final auto = optimizer(scale: 2, need: 5);
    expect(feed(auto, List.filled(11, fast), from: s(20)), isNull);
    expect(auto.observe(s(75), fast), 3);
    auto.changed(s(75), 3);
    expect(feed(auto, List.filled(12, fast), from: s(95)), (4, s(150)));
    auto.changed(s(150), 4);
    expect(feed(auto, List.filled(30, fast), from: s(170)), isNull, reason: '6x is past a 1080p display');

    final marked = optimizer(scale: 4, remembered: memory()..slow.add(6));
    expect(feed(marked, List.filled(30, fast), from: s(20)), isNull, reason: '6x ran slow: it caps the climb');
    final busy = optimizer(scale: 2);
    expect(
      feed(busy, List.filled(30, status(speed: 1, work: 0.7)), from: s(20)),
      isNull,
      reason: 'full speed with a frame taking most of its time is no headroom',
    );
    final unknown = optimizer(scale: 2);
    expect(feed(unknown, List.filled(30, status(speed: 1, work: null)), from: s(20)), isNull);
  });

  test('a pause between readings breaks their run', () {
    final auto = optimizer();
    final slow = status(speed: 0.6, work: 1.5);
    expect(auto.observe(s(20), slow), isNull);
    auto.interrupted();
    expect(auto.observe(s(300), slow), isNull, reason: 'one slow reading before the pause, one after');
    expect(auto.observe(s(305), slow), 3);
  });

  test('slow at the smallest scale: the floor, where the optimizer stops', () {
    final auto = optimizer(scale: 1);
    final slow = status(speed: 0.5, work: 1.5);
    expect(feed(auto, List.filled(10, slow), from: s(20)), isNull);
    expect(auto.atFloor, isTrue);
    expect(auto.memory.slow, isEmpty, reason: 'Native stays the scale to fall back to');
  });

  test('the memory: kept as JSON, and measured with one GPU, host and configuration', () {
    final kept = RetroAutoMemory(gpu: 'RTX', host: '1.2.0', config: 'a=1', scale: 4, slow: {8, 6});
    final json = kept.toJson();
    expect(json, {
      'gpu': 'RTX',
      'host': '1.2.0',
      'config': 'a=1',
      'scale': 4,
      'slow': [6, 8],
    });
    final back = RetroAutoMemory.fromJson(jsonDecode(jsonEncode(json)))!;
    expect((back.gpu, back.host, back.config, back.scale), ('RTX', '1.2.0', 'a=1', 4));
    expect(back.slow, {6, 8});
    expect(RetroAutoMemory.fromJson({'gpu': 'RTX'}), isNull);
    expect(
      RetroAutoMemory.fromJson({
        'gpu': '',
        'host': '',
        'config': '',
        'slow': ['8'],
      }),
      isNull,
    );
    expect(kept.measuredWith(gpu: 'RTX', host: '1.2.0', config: 'a=1'), isTrue);
    expect(
      kept.measuredWith(gpu: '', host: '1.2.0', config: ''),
      isTrue,
      reason: 'not known yet',
    );
    expect(kept.measuredWith(gpu: 'Radeon', host: '1.2.0', config: 'a=1'), isFalse);
    expect(kept.measuredWith(gpu: 'RTX', host: '1.3.0', config: 'a=1'), isFalse);
    expect(kept.measuredWith(gpu: 'RTX', host: '1.2.0', config: 'a=2'), isFalse);
    final config = retroAutoConfig(status(speed: 1), [
      'swanstation_GPU_TextureFilter',
      'swanstation_GPU_ResolutionScale',
    ]);
    expect(config, 'swanstation_GPU_ResolutionScale=1', reason: 'the options the status lists, in key order');
  });
}
