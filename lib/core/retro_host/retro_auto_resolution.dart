/// The Auto Optimizer's choice of a PS1 game's internal resolution: the highest scale the game
/// keeps full speed at on this PC, judged from the host's `status.performance` (anyps5-retro-host
/// docs/protocol.md "status"). SwanStation applies its resolution while the game runs, so a wrong
/// scale is undone within seconds of play. A PS2 game is not chosen for: LRPS2 reads its
/// resolution only when the game starts.
library;

import 'retro_host_protocol.dart';

/// The thresholds the optimizer judges by. Measured on full-speed games, one 5-second window reads
/// 0.994 to 1.004 (a frame either way), so a step down needs two slow windows in a row or a slow
/// half minute, never one window. A game also slows for a moment for reasons no resolution
/// changes (a new scene's shaders, a disc read): Spyro the Dragon at 2x on an RTX 4080 SUPER read
/// 0.983 then 0.836 once, with each frame taking 78% of its time at the median. So a step down
/// needs the slowness to be steady, or the frames themselves to take longer than their time.
abstract final class RetroAutoRules {
  /// The time measured by each reading the optimizer takes, as the host measures it.
  static const window = Duration(seconds: 5);

  /// How much sooner than [window] after the last reading the next may come: `Timer.periodic`'s
  /// callbacks can come a little sooner or later than its duration, and a reading thrown away for
  /// being a few milliseconds early would drop about every other one. With the status itself up to
  /// a poll (half a second) old, two readings may share up to about a second of the host's
  /// measurement; the rules judge several readings, never one.
  static const early = Duration(milliseconds: 500);

  /// The time after the game starts or its resolution changes before readings count: loading,
  /// shader compiles and the redraw at the new scale.
  static const settle = Duration(seconds: 20);

  /// Two readings in a row below this, each with a frame taking at least [slowWork] of its time at
  /// the median, step down at once: the PC cannot keep up with the game at this scale.
  static const slow = 0.95;
  static const slowWork = 1.0;

  /// Six readings (30 seconds) in a row, each below this, step down: a small but steady loss, as
  /// Jak and Daxter at a scale just too high read 0.956 to 0.990 in every window. One slow moment
  /// among full-speed readings is not steady.
  static const steady = 0.995;
  static const steadyReadings = 6;

  /// Twelve readings (a minute) at full speed, each with a frame taking at most half its time,
  /// step up one scale.
  static const headroomReadings = 12;
  static const headroomWork = 0.5;

  /// The scale a game starts at when nothing is remembered for it: low enough to start quickly on
  /// most graphics cards, and the optimizer climbs from there.
  static const firstScale = 2;
}

/// What the optimizer remembers of one game on this PC: the scale it last used, and the scales
/// that ran slow, which it never chooses again. It is measured with one graphics card, host build
/// and set of the game's other graphics settings; when any of them changes, it starts again.
class RetroAutoMemory {
  RetroAutoMemory({required this.gpu, required this.host, required this.config, this.scale, Set<int>? slow})
    : slow = slow ?? {};

  /// The renderer that drew the game (`status.gpu.renderer`), or empty before one was seen.
  final String gpu;

  /// The host's version (`welcome.hostVersion`), which names the core build it ships.
  final String host;

  /// The game's other graphics settings it was measured with ([retroAutoConfig]), or empty before
  /// a status was seen.
  final String config;

  /// The scale last used, or null before any.
  int? scale;

  /// The scales that ran slow.
  final Set<int> slow;

  /// Whether this memory was measured with [gpu], [host] and [config]. An empty [gpu] or [config]
  /// of this memory or of the question matches any, since it was not known.
  bool measuredWith({required String gpu, required String host, required String config}) =>
      this.host == host &&
      (this.gpu.isEmpty || gpu.isEmpty || this.gpu == gpu) &&
      (this.config.isEmpty || config.isEmpty || this.config == config);

  Map<String, Object?> toJson() => {
    'gpu': gpu,
    'host': host,
    'config': config,
    'scale': ?scale,
    if (slow.isNotEmpty) 'slow': (slow.toList()..sort()),
  };

  /// The memory [json] holds, or null when it is not one.
  static RetroAutoMemory? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final gpu = json['gpu'];
    final host = json['host'];
    final config = json['config'];
    final scale = json['scale'];
    final slow = json['slow'];
    if (gpu is! String || host is! String || config is! String) return null;
    if (scale != null && scale is! int) return null;
    if (slow != null && (slow is! List<Object?> || slow.any((item) => item is! int))) return null;
    return RetroAutoMemory(
      gpu: gpu,
      host: host,
      config: config,
      scale: scale as int?,
      slow: {...?(slow as List<Object?>?)?.cast<int>()},
    );
  }
}

/// The game's graphics settings other than the resolution that change what a frame costs, as
/// [status] has them chosen: the values of [keys] the host lists, in key order. Empty before a
/// status lists any.
String retroAutoConfig(RetroStatus status, Iterable<String> keys) => [
  for (final key in keys.toList()..sort())
    if (status.options[key] case final option?) '$key=${option.values[option.selected]}',
].join(';');

/// The largest scale the display needs: a PS1 game is 240 lines high, so a scale past the display's
/// height over 240 draws pixels it cannot show.
int retroAutoDisplayNeed(double displayHeight) => displayHeight <= 0 ? 1 : (displayHeight / 240).ceil();

/// The optimizer of one game while it plays.
class RetroAutoResolution {
  RetroAutoResolution({required List<int> scales, required this.need, required this.memory, required this.scale})
    : scales = (scales.toSet().toList()..sort());

  /// The scales the host lists and the launcher offers, smallest first.
  final List<int> scales;

  /// The largest scale worth choosing ([retroAutoDisplayNeed]); it follows the view.
  int need;

  final RetroAutoMemory memory;

  /// The scale the game draws at now; [changed] sets it.
  int scale;

  /// The game runs slow at the smallest scale: no resolution helps it, so the optimizer stops.
  bool get atFloor => _atFloor;
  bool _atFloor = false;

  final _readings = <RetroPerformance>[];
  Duration _settledAt = RetroAutoRules.settle;
  Duration? _lastReading;

  /// The scale a game starts at: the one [memory] last used, or [RetroAutoRules.firstScale], at
  /// most [need], never one that ran slow, and one of [scales] (the smallest when none fits).
  static int startScale(List<int> scales, {required int need, RetroAutoMemory? memory}) {
    final listed = scales.toSet().toList()..sort();
    if (listed.isEmpty) return 1;
    final wanted = memory?.scale ?? RetroAutoRules.firstScale;
    final allowed = [
      for (final listedScale in listed)
        if (listedScale <= wanted && listedScale <= need && !(memory?.slow.contains(listedScale) ?? false)) listedScale,
    ];
    return allowed.isEmpty ? listed.first : allowed.last;
  }

  /// Takes [status] at [at] (the time since the game started) and returns the scale to change to,
  /// or null to keep this one. A reading counts only while the game plays and nothing is being
  /// applied, [RetroAutoRules.settle] after the start or the last change, and about once per
  /// [RetroAutoRules.window] (no sooner than [RetroAutoRules.early] before it); anything else
  /// breaks the run of readings.
  int? observe(Duration at, RetroStatus status) {
    final performance = status.performance;
    if (_atFloor) return null;
    if (performance == null ||
        !status.ready ||
        status.ended ||
        status.graphicsPending ||
        status.progressLabel != null ||
        at < _settledAt) {
      if (performance == null || status.graphicsPending || status.progressLabel != null) _readings.clear();
      return null;
    }
    final last = _lastReading;
    if (last != null && at - last < RetroAutoRules.window - RetroAutoRules.early) return null;
    _lastReading = at;
    _readings.add(performance);
    if (_slow()) return _down();
    if (_headroom()) return _up();
    return null;
  }

  /// The game was paused (the menu opened) or was otherwise not played: the readings before do not
  /// count with those after.
  void interrupted() {
    _readings.clear();
    _lastReading = null;
  }

  /// The game now draws at [now] (the change asked was taken, or the player's), from [at]: the
  /// readings start again after [RetroAutoRules.settle].
  void changed(Duration at, int now) {
    scale = now;
    memory.scale = now;
    _readings.clear();
    _lastReading = null;
    _settledAt = at + RetroAutoRules.settle;
  }

  bool _slow() {
    final count = _readings.length;
    bool overloaded(RetroPerformance reading) =>
        reading.speed < RetroAutoRules.slow && (reading.work ?? 0) >= RetroAutoRules.slowWork;
    if (count >= 2 && overloaded(_readings[count - 1]) && overloaded(_readings[count - 2])) return true;
    if (count < RetroAutoRules.steadyReadings) return false;
    return _readings
        .sublist(count - RetroAutoRules.steadyReadings)
        .every((reading) => reading.speed < RetroAutoRules.steady);
  }

  bool _headroom() {
    final count = _readings.length;
    if (count < RetroAutoRules.headroomReadings) return false;
    return _readings
        .sublist(count - RetroAutoRules.headroomReadings)
        .every(
          (reading) =>
              reading.speed >= RetroAutoRules.steady &&
              reading.work != null &&
              reading.work! <= RetroAutoRules.headroomWork,
        );
  }

  int? _down() {
    _readings.clear();
    final lower = [
      for (final other in scales)
        if (other < scale && !memory.slow.contains(other)) other,
    ];
    if (lower.isEmpty) {
      _atFloor = true;
      return null;
    }
    memory.slow.add(scale);
    return lower.last;
  }

  int? _up() {
    _readings.clear();
    final next = scales.where((other) => other > scale).firstOrNull;
    if (next == null || next > need || memory.slow.contains(next)) return null;
    return next;
  }
}
