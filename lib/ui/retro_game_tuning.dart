import 'dart:async';
import 'dart:math' as math;

import '../core/game_library.dart';

typedef EmbeddedOption = ({List<String> values, List<String> labels, String title, bool restart, int selected});
typedef RetroTuningWrite = Future<bool> Function(Map<String, String> expected, Map<String, String> values);
typedef RetroTuningPersist = void Function(
  Map<String, String> previous,
  Map<String, String> values, {
  required bool undo,
});

class RetroTuningSample {
  const RetroTuningSample({
    required this.videoFps,
    required this.stepRatio,
    required this.frameTime95,
    required this.audioRatio,
    required this.droppedAudio,
  });

  final double videoFps;
  final double stepRatio;
  final int frameTime95;
  final double? audioRatio;
  final int droppedAudio;

  bool get needsHeadroom => stepRatio < 0.97 || (audioRatio ?? 1) < 0.94 || droppedAudio > 0;

  bool holdsBaseline(RetroTuningSample before) {
    if (videoFps < before.videoFps * 0.96 ||
        stepRatio < before.stepRatio - 0.03 ||
        frameTime95 > before.frameTime95 * 1.2 + 2 ||
        droppedAudio > before.droppedAudio + 512) {
      return false;
    }
    final previousAudio = before.audioRatio;
    return previousAudio == null || (audioRatio != null && audioRatio! >= previousAudio - 0.03);
  }

  bool improvesHeadroom(RetroTuningSample before) =>
      stepRatio > before.stepRatio + 0.025 ||
      videoFps > before.videoFps * 1.06 ||
      frameTime95 < before.frameTime95 * 0.82 ||
      (audioRatio ?? 0) > (before.audioRatio ?? 0) + 0.04 ||
      droppedAudio + 512 < before.droppedAudio;

  String get summary {
    final audio = audioRatio;
    final frameTime = frameTime95 == 1000 ? 'over 500 ms' : 'up to $frameTime95 ms';
    return '${videoFps.toStringAsFixed(1)} core output FPS · p95 frame interval $frameTime'
        '${audio == null ? '' : ' · ${(audio * 100).round()}% audio rate'}'
        '${droppedAudio == 0 ? '' : ' · $droppedAudio dropped audio frames'}';
  }
}

class _Snapshot {
  _Snapshot(Map<Object?, Object?> data)
    : clockMs = data['clockMs'] as int,
      frames = data['frames'] as int,
      steps = data['steps'] as int,
      audioFrames = data['audioFrames'] as int,
      droppedAudio = data['droppedAudioFrames'] as int,
      intervals = (data['frameIntervals'] as List).cast<int>(),
      targetFps = (data['targetFps'] as num).toDouble(),
      audioRate = (data['audioRate'] as num).toDouble();

  final int clockMs;
  final int frames;
  final int steps;
  final int audioFrames;
  final int droppedAudio;
  final List<int> intervals;
  final double targetFps;
  final double audioRate;

  // Upper bounds of the native frame interval histogram.
  static const intervalLimits = [8, 12, 16, 20, 25, 35, 50, 75, 100, 150, 250, 500, 1000];

  RetroTuningSample? since(_Snapshot before) {
    final seconds = (clockMs - before.clockMs) / 1000;
    final delivered = frames - before.frames;
    final stepCount = steps - before.steps;
    final audioCount = audioFrames - before.audioFrames;
    final droppedCount = droppedAudio - before.droppedAudio;
    if (seconds < 10 ||
        audioCount < 0 ||
        droppedCount < 0 ||
        delivered < 10 ||
        stepCount <= 0 ||
        targetFps <= 0 ||
        targetFps != before.targetFps ||
        audioRate != before.audioRate ||
        intervals.length != intervalLimits.length ||
        before.intervals.length != intervals.length) {
      return null;
    }
    final buckets = List.generate(intervals.length, (index) => intervals[index] - before.intervals[index]);
    final total = buckets.fold(0, (sum, count) => sum + count);
    if (buckets.any((count) => count < 0) || total < 10) return null;
    final percentile = (total * 0.95).ceil();
    var cumulative = 0;
    var p95 = intervalLimits.last;
    for (var index = 0; index < buckets.length; index++) {
      cumulative += buckets[index];
      if (cumulative >= percentile) {
        p95 = intervalLimits[index];
        break;
      }
    }
    return RetroTuningSample(
      videoFps: delivered / seconds,
      stepRatio: stepCount / (seconds * targetFps),
      frameTime95: p95,
      audioRatio: audioRate <= 0 ? null : math.min(1.0, audioCount / (seconds * audioRate)),
      droppedAudio: droppedCount,
    );
  }
}

enum _Trial { baseline, candidate, restartSample }

class RetroGameTuning {
  RetroGameTuning({
    required this.platform,
    required this.options,
    required this.ready,
    required this.writeOptions,
    required this.persist,
    required this.changed,
  });

  final RetroPlatform platform;
  final Map<String, EmbeddedOption> options;
  final bool Function() ready;
  final RetroTuningWrite writeOptions;
  final RetroTuningPersist persist;
  final void Function() changed;

  RetroTuningSample? baseline;
  RetroTuningSample? candidate;
  _Trial? _trial;
  Completer<RetroTuningSample?>? _restartSample;
  _Snapshot? _first;
  int? _warmupFrom;
  bool _busy = false;
  bool _applied = false;
  bool _observed = false;
  String? _message;
  Map<String, String> _before = {};
  Map<String, String> _candidate = {};

  bool get canStartBaseline =>
      _observed &&
      ready() &&
      !_busy &&
      !_applied &&
      _trial == null &&
      (_plan(headroom: true).isNotEmpty || _plan(headroom: false).isNotEmpty);
  bool get canStartCandidate =>
      ready() && baseline != null && candidate == null && !_busy && _trial == null && _candidate.isNotEmpty;
  bool get canApply {
    final result = candidate;
    final before = baseline;
    return !_busy &&
        !_applied &&
        ready() &&
        _trial == null &&
        result != null &&
        before != null &&
        result.holdsBaseline(before) &&
        (!before.needsHeadroom || result.improvesHeadroom(before));
  }

  bool get recording => _trial != null;
  bool get updating => _busy;
  bool get canUndo => !_busy && _applied && ready() && _trial == null;
  bool get canCancel => !_busy && (_trial != null || (baseline != null && !_applied));

  List<String> get changes => [
    for (final entry in _candidate.entries)
      '${_name(entry.key)} · ${_label(entry.key, _before[entry.key]!)} → ${_label(entry.key, entry.value)}',
  ];

  String get status {
    if (_busy) return 'Updating this game’s settings…';
    if (_trial != null) {
      final stage = switch (_trial!) {
        _Trial.baseline => 'baseline',
        _Trial.candidate => 'candidate',
        _Trial.restartSample => 'restart trial',
      };
      return _warmupFrom == null
          ? 'Resume and play the same gameplay segment for the $stage sample.'
          : 'Recording the $stage gameplay sample. Keep playing until it finishes.';
    }
    if (_message case final message?) return message;
    if (!_observed || !ready()) return 'Wait until the game has finished starting.';
    if (!canStartBaseline) return 'No supported live tuning candidates are available for these settings.';
    return 'Play a repeatable segment to record your current performance.';
  }

  Future<RetroTuningSample?>? captureRestartSample() {
    if (!_observed || _busy || _trial != null) return null;
    final result = Completer<RetroTuningSample?>();
    _restartSample = result;
    _arm(_Trial.restartSample);
    return result.future;
  }

  void endSession() {
    _restartSample?.complete(null);
    _restartSample = null;
    _trial = null;
  }

  Future<bool> startBaseline() async {
    if (!canStartBaseline) return false;
    baseline = null;
    candidate = null;
    _before = {};
    _candidate = {};
    _message = null;
    _arm(_Trial.baseline);
    return true;
  }

  Future<bool> startCandidate() async {
    if (!canStartCandidate) return false;
    _busy = true;
    changed();
    final accepted = await _write(_before, _candidate);
    _busy = false;
    if (!accepted) {
      _message = 'The game or settings changed. Record a new baseline.';
      baseline = null;
      changed();
      return false;
    }
    _arm(_Trial.candidate);
    return true;
  }

  Future<void> observe(Map<Object?, Object?>? telemetry, {required bool playing}) async {
    if (telemetry == null) return;
    _Snapshot current;
    try {
      current = _Snapshot(telemetry);
    } on TypeError {
      return;
    }
    if (!_observed) {
      _observed = true;
      changed();
    }
    final trial = _trial;
    if (trial == null || _busy) return;
    if (!playing) {
      if (_warmupFrom != null) await _finish(trial, null);
      return;
    }
    final warmup = _warmupFrom;
    if (warmup == null) {
      _warmupFrom = current.clockMs;
      changed();
      return;
    }
    if (current.clockMs - warmup < 2000) return;
    final first = _first ??= current;
    if (current.clockMs - first.clockMs < 10000) return;
    await _finish(trial, current.since(first));
  }

  Future<void> _finish(_Trial trial, RetroTuningSample? sample) async {
    _trial = null;
    if (trial == _Trial.restartSample) {
      _restartSample?.complete(sample);
      _restartSample = null;
      changed();
      return;
    }
    if (trial == _Trial.candidate) {
      _busy = true;
      changed();
      final restored = await _write(_candidate, _before);
      _busy = false;
      if (!restored) {
        _message = 'The baseline could not be restored. Reopen the game to reload its saved settings.';
        baseline = null;
        changed();
        return;
      }
    }
    if (sample == null) {
      _message = 'Gameplay recording was interrupted or produced too few frames. Try the same segment again.';
    } else if (trial == _Trial.baseline) {
      baseline = sample;
      _candidate = _plan(headroom: sample.needsHeadroom);
      _before = {for (final key in _candidate.keys) key: _value(key)!};
      _message = _candidate.isEmpty
          ? 'Baseline recorded. No supported live changes match this sample.'
          : 'Baseline recorded. Repeat the same gameplay segment for the candidate.';
    } else {
      candidate = sample;
      _message = canApply
          ? 'The candidate passed the comparison. The original settings are restored until you apply.'
          : 'The candidate did not pass the comparison. The original settings were restored.';
    }
    changed();
  }

  Future<void> interrupt() async {
    final trial = _trial;
    if (trial != null && _warmupFrom != null && !_busy) await _finish(trial, null);
  }

  Future<void> cancel() async {
    if (!canCancel) return;
    final trial = _trial;
    if (trial != null) await _finish(trial, null);
    if (trial == null) {
      baseline = null;
      candidate = null;
      _before = {};
      _candidate = {};
      _message = null;
      changed();
    }
  }

  Future<void> apply() async {
    if (!canApply) return;
    await _commit(_before, _candidate, applied: true);
  }

  Future<void> undo() async {
    if (!canUndo) return;
    await _commit(_candidate, _before, applied: false);
  }

  Future<void> _commit(Map<String, String> from, Map<String, String> to, {required bool applied}) async {
    _busy = true;
    changed();
    if (await _write(from, to)) {
      try {
        persist(from, to, undo: !applied);
        _applied = applied;
        _message = applied ? 'Applied to this game.' : 'Restored the previous settings for this game.';
      } on Exception {
        final restored = await _write(to, from);
        _message = restored
            ? 'The settings could not be saved. The previous values were restored.'
            : 'The settings could not be saved. Reopen the game to reload its saved settings.';
      }
    } else {
      _message = 'The live settings changed. No values were overwritten.';
    }
    _busy = false;
    changed();
  }

  Future<bool> _write(Map<String, String> from, Map<String, String> to) async {
    try {
      return await writeOptions(from, to);
    } on Exception {
      return false;
    }
  }

  void _arm(_Trial trial) {
    _trial = trial;
    _first = null;
    _warmupFrom = null;
    _message = null;
    changed();
  }

  String? _value(String key) {
    final option = options[key];
    if (option == null || option.restart || option.selected < 0 || option.selected >= option.values.length) {
      return null;
    }
    return option.values[option.selected];
  }

  String _label(String key, String value) {
    final option = options[key];
    final index = option?.values.indexOf(value) ?? -1;
    return option != null && index >= 0 && index < option.labels.length ? option.labels[index] : value;
  }

  String _name(String key) {
    final title = options[key]?.title ?? '';
    if (title.isNotEmpty) return title;
    return switch (key) {
      'swanstation_GPU_ResolutionScale' ||
      'pcsx2_upscale_multiplier' ||
      'rpcs3_resolution_scale' => 'Internal resolution',
      'swanstation_GPU_TextureFilter' => 'Texture filtering',
      'pcsx2_trilinear_filtering' => 'Trilinear filtering',
      _ => 'Anisotropic filtering',
    };
  }

  Map<String, String> _plan({required bool headroom}) {
    final plan = <String, String>{};
    void choose(String key, String desired) {
      final current = _value(key);
      if (current == null || current.toLowerCase() == desired.toLowerCase()) return;
      for (final value in options[key]!.values) {
        if (value.toLowerCase() == desired.toLowerCase()) {
          plan[key] = value;
          return;
        }
      }
    }

    void scale(String key, int maximum) {
      int? multiplier(String value) => int.tryParse(RegExp(r'^\d+').stringMatch(value) ?? '');
      final current = multiplier(_value(key) ?? '');
      if (current == null || current <= 0) return;
      final values = {
        for (final value in options[key]!.values)
          if (multiplier(value) case final int level) level: value,
      };
      final levels = values.keys.toList()..sort();
      final desired = headroom
          ? levels.where((value) => value > 0 && value < current).lastOrNull
          : levels.where((value) => value > current && value <= maximum).firstOrNull;
      if (desired != null) choose(key, values[desired]!);
    }

    void anisotropy(String key, String economy, String quality) {
      final current = _value(key);
      final level = int.tryParse(current?.replaceAll(RegExp('[^0-9]'), '') ?? '') ?? 0;
      if (headroom ? level > 2 : level < 4) choose(key, headroom ? economy : quality);
    }

    switch (platform) {
      case RetroPlatform.ps1:
        scale('swanstation_GPU_ResolutionScale', 4);
        final key = 'swanstation_GPU_TextureFilter';
        if (headroom || _value(key)?.toLowerCase() == 'nearest') {
          choose(key, headroom ? 'Nearest' : 'BilinearBinAlpha');
        }
      case RetroPlatform.ps2:
        scale('pcsx2_upscale_multiplier', 4);
        anisotropy('pcsx2_anisotropic_filtering', 'disabled', '4x');
        final key = 'pcsx2_trilinear_filtering';
        final current = _value(key);
        if (headroom && current == 'Trilinear (Forced)') choose(key, 'Automatic');
        if (!headroom && current == 'Automatic') choose(key, 'Trilinear (PS2)');
      case RetroPlatform.ps3:
        scale('rpcs3_resolution_scale', 175);
        anisotropy('rpcs3_anisotropic_filter', '2', '4');
    }
    return plan;
  }
}
