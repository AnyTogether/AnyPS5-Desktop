import 'dart:async';
import 'dart:math' as math;

// How the launcher feels under a thumb, a finger and a pointer: one repeat for the pad and the
// keys, a stick that does not flutter, a bump at the end of a row, a tick when the pointer
// arrives on something and soft pulses in the controller. The macOS launcher
// (Sources/AnyPS5Core/Feel.swift) uses the same numbers, but for the stick's up and down
// ([StickGate]), made harder to reach here after a player found them too sensitive.

/// A held direction, keyboard or controller alike: it moves at once, again after 0.40 s, then
/// every 0.08 s and, after six repeats, every 0.06 s.
abstract final class KeyRepeat {
  static const firstDelay = Duration(milliseconds: 400);
  static const interval = Duration(milliseconds: 80);
  static const fastInterval = Duration(milliseconds: 60);

  /// Repeats at [interval] before the pace picks up.
  static const fastAfter = 6;

  /// How late a repeat may fire before it is taken for a stall of the interface and dropped. A
  /// frozen interface cannot read the key's release (or the stick's return) queued behind it, so
  /// the timer ran out first and moved the selection once more for a press that had ended.
  static const stall = Duration(milliseconds: 200);

  /// The wait before repeat number [repeat] (1 is the first) since the move before it.
  static Duration delayBefore(int repeat) => repeat <= 1 ? firstDelay : (repeat <= fastAfter ? interval : fastInterval);

  /// When a hold of [duration] moves: zero for the press, then each repeat.
  static List<Duration> times(Duration duration) {
    final times = <Duration>[Duration.zero];
    var time = Duration.zero;
    for (var repeat = 1; ; repeat++) {
      time += delayBefore(repeat);
      if (time > duration) return times;
      times.add(time);
    }
  }
}

/// Repeats a held command on [KeyRepeat]'s pace; the pad's navigator and the keyboard each hold
/// one. [repeating] is true while a repeat is being handed on.
class HoldRepeater<C extends Object> {
  HoldRepeater(this.onCommand, {Duration Function()? now}) : _now = now ?? _monotonic;

  final void Function(C command) onCommand;

  /// A clock that only goes forward, which tests replace; fake timers do not move the real one.
  final Duration Function() _now;
  static final Stopwatch _clock = Stopwatch()..start();
  static Duration _monotonic() => _clock.elapsed;

  C? _held;
  Object? _by;
  Timer? _timer;
  int _repeats = 0;
  bool _repeating = false;
  Duration? _firstDelay;

  C? get held => _held;
  Object? get heldBy => _by;
  bool get repeating => _repeating;

  /// Starts holding [command] for [by] (a pad, a key): it is handed on at once, then repeated;
  /// [firstDelay] in place of [KeyRepeat.firstDelay] before the first repeat.
  void hold(C command, {Object? by, Duration? firstDelay}) {
    stop();
    _held = command;
    _by = by;
    _firstDelay = firstDelay;
    onCommand(command);
    _schedule();
  }

  /// Holds [command] without handing it on now (the press was handled already).
  void holdQuietly(C command, {Object? by}) {
    stop();
    _held = command;
    _by = by;
    _schedule();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _held = null;
    _by = null;
    _repeats = 0;
    _firstDelay = null;
  }

  void _schedule() {
    final wait = _repeats == 0 && _firstDelay != null ? _firstDelay! : KeyRepeat.delayBefore(_repeats + 1);
    final due = _now() + wait;
    _timer = Timer(wait, () {
      final held = _held;
      if (held == null) return;
      // The interface stalled (a freeze, a long frame) and this fired long after it was due: the
      // release that ended the hold may be waiting just behind it. Nothing moves; the wait
      // starts over, and a direction really still held goes on repeating after it.
      if (_now() - due > KeyRepeat.stall) {
        _schedule();
        return;
      }
      _repeats++;
      _repeating = true;
      try {
        onCommand(held);
      } finally {
        _repeating = false;
      }
      if (_held != null) _schedule();
    });
  }
}

/// The four directions a stick or a D-pad gives.
enum Direction { left, right, up, down }

/// The left stick as a direction with hysteresis: left and right engage past 0.5 and let go
/// below 0.3, so a stick resting near the line does not flutter; a flick through the middle
/// turns at once.
///
/// Up and down are harder to reach, as on Home one of them leaves the tiles for the top bar or
/// the buttons: they engage only past 0.65 and with the stick clearly upright (Y at least 1.2
/// times X; a diagonal goes sideways), let go below 0.4, take over from a held left or right
/// only when Y leads by half again, and repeat first after [verticalFirstDelay]. A thumb
/// sweeping in an arc on its way to the side, a light push or a wobble moved up or down before.
///
/// A reader sends a sample as two events, X then Y, so the gate also sees the new X with the
/// old Y: a stick snapping back from a diagonal looks upright for that moment. Letting go of
/// one axis, the other therefore engages only from the next sample.
class StickGate {
  static const engage = 0.5;
  static const release = 0.3;
  static const verticalEngage = 0.65;
  static const verticalRelease = 0.4;

  /// How much Y must lead X for up or down to engage.
  static const verticalLead = 1.2;

  /// How much the other axis must lead to take over a held direction: left or right from up or
  /// down, up or down from left or right.
  static const switchRatio = 1.25;
  static const verticalSwitchRatio = 1.5;

  /// Up and down held on the stick repeat first after this (the D-pad and the keys, and left
  /// and right, after [KeyRepeat.firstDelay]).
  static const verticalFirstDelay = Duration(milliseconds: 550);

  Direction? held;

  static bool isVertical(Direction direction) => direction == Direction.up || direction == Direction.down;

  /// [x] right positive, [y] down positive (as the readers give the stick), both -1 to 1.
  Direction? update(double x, double y) {
    if (held case final Direction direction) {
      final vertical = isVertical(direction);
      final along = _along(direction, x, y);
      if (along >= (vertical ? verticalRelease : release)) {
        final other = vertical ? x : y;
        final takesOver = vertical
            ? other.abs() >= engage && other.abs() > along * switchRatio
            : other.abs() >= verticalEngage && other.abs() > along * verticalSwitchRatio;
        if (takesOver) {
          held = vertical
              ? (other > 0 ? Direction.right : Direction.left)
              : (other > 0 ? Direction.down : Direction.up);
        }
        return held;
      }
      held = null;
      final next = _engaged(x, y);
      if (next != null && isVertical(next) == vertical) held = next;
      return held;
    }
    return held = _engaged(x, y);
  }

  static Direction? _engaged(double x, double y) {
    if (y.abs() >= verticalEngage && y.abs() >= x.abs() * verticalLead) return y > 0 ? Direction.down : Direction.up;
    if (x.abs() >= engage && x.abs() >= y.abs()) return x > 0 ? Direction.right : Direction.left;
    return null;
  }

  static double _along(Direction direction, double x, double y) => switch (direction) {
    Direction.right => x,
    Direction.left => -x,
    Direction.down => y,
    Direction.up => -y,
  };
}

/// A direction with nowhere to go (the first or last tile, the end of a list) answers with a
/// bump: once per press, and once in a hold that reaches the end. Nothing wraps around that did
/// not wrap before.
class EdgeBump {
  bool _bumped = false;

  /// After a command was handled: whether it bumps. [direction] whether it was one;
  /// [repeat] for the repeats of a held direction; [changed] when it moved the focus or did
  /// anything else.
  bool handled({required bool direction, required bool repeat, required bool changed}) {
    if (!repeat) _bumped = false;
    if (!direction || changed || _bumped) return false;
    _bumped = true;
    return true;
  }
}

/// The soft tick when the pointer arrives on a control, tile, row or card: one per arrival on a
/// new element, only after the pointer itself moved (not when a list scrolls under it), at most
/// one every 60 ms (a dropped one is not told late), none within 90 ms of another sound or with
/// a mouse button held, and none when sounds are off, a game is in front or the launcher is
/// behind.
class HoverGate {
  static const minimumGap = Duration(milliseconds: 60);
  static const afterCue = Duration(milliseconds: 90);

  /// Logical pixels the pointer must have moved since the last arrival.
  static const movement = 2.0;

  Object? _current;
  (double, double)? _pointer;
  Duration? _lastTick;

  /// The pointer at ([x], [y]) arrived on [id].
  bool arrive(
    Object id, {
    required double x,
    required double y,
    required Duration now,
    Duration? lastCue,
    bool buttonsDown = false,
    bool allowed = true,
  }) {
    final previous = _pointer;
    final moved =
        previous == null || math.sqrt(math.pow(x - previous.$1, 2) + math.pow(y - previous.$2, 2)) >= movement;
    _pointer = (x, y);
    if (id == _current) return false;
    _current = id;
    if (!allowed || buttonsDown || !moved) return false;
    if (_lastTick case final Duration last when now - last < minimumGap) return false;
    if (lastCue != null && now - lastCue < afterCue) return false;
    _lastTick = now;
    return true;
  }

  /// The pointer left [id]: arriving on it again is an arrival.
  void leave(Object id) {
    if (_current == id) _current = null;
  }
}

/// What the controller's motors say.
enum HapticCue {
  select,
  back,
  error,
  trophy,
  ring,
  edge;

  /// The pulse an interface sound comes with: select, back and the bump; moving and hovering
  /// have none, and trophies, calls and errors are told on their own.
  static HapticCue? forSound(String sound) => switch (sound) {
    'select' => HapticCue.select,
    'back' => HapticCue.back,
    'bump' => HapticCue.edge,
    _ => null,
  };
}

/// One pulse: when it starts and how long it lasts, and how hard each motor turns, 0 to 1:
/// [strong] the heavy low motor, [weak] the light high one (a crisp tap).
class HapticPulse {
  const HapticPulse(this.start, this.length, {required this.strong, required this.weak});

  final Duration start;
  final Duration length;
  final double strong;
  final double weak;

  double get intensity => math.max(strong, weak);
  Duration get end => start + length;

  @override
  bool operator ==(Object other) =>
      other is HapticPulse &&
      other.start == start &&
      other.length == length &&
      other.strong == strong &&
      other.weak == weak;

  @override
  int get hashCode => Object.hash(start, length, strong, weak);

  @override
  String toString() => 'HapticPulse(${start.inMilliseconds} ms, ${length.inMilliseconds} ms, $strong, $weak)';
}

/// The pulses: select one very light tap, back a lighter one, an error two short taps, a trophy
/// three that swell, a call a heavy beat then a light one, the edge bump barely there.
abstract final class HapticPatterns {
  static const _ms = Duration(milliseconds: 1);

  static List<HapticPulse> pulses(HapticCue cue) => switch (cue) {
    HapticCue.select => const [HapticPulse(Duration.zero, Duration(milliseconds: 18), strong: 0, weak: 0.42)],
    HapticCue.back => const [HapticPulse(Duration.zero, Duration(milliseconds: 14), strong: 0, weak: 0.30)],
    HapticCue.edge => const [HapticPulse(Duration.zero, Duration(milliseconds: 12), strong: 0, weak: 0.20)],
    HapticCue.error => [
      const HapticPulse(Duration.zero, Duration(milliseconds: 35), strong: 0.45, weak: 0.35),
      HapticPulse(_ms * 90, _ms * 35, strong: 0.45, weak: 0.35),
    ],
    HapticCue.trophy => [
      const HapticPulse(Duration.zero, Duration(milliseconds: 40), strong: 0.25, weak: 0.30),
      HapticPulse(_ms * 110, _ms * 45, strong: 0.40, weak: 0.40),
      HapticPulse(_ms * 230, _ms * 70, strong: 0.60, weak: 0.50),
    ],
    HapticCue.ring => [
      const HapticPulse(Duration.zero, Duration(milliseconds: 80), strong: 0.70, weak: 0.30),
      HapticPulse(_ms * 160, _ms * 50, strong: 0.25, weak: 0.35),
    ],
  };
}

/// Where pulses go: a controller's motors, or a fake in tests. [stop] sets every motor to zero.
abstract class HapticOutput {
  void play(List<HapticPulse> pulses);
  void stop();
}

/// Decides whether a pulse plays: the setting on, the launcher in front (never while a game is:
/// the game owns the pad) and the controller the device in use (no buzz on the desk while the
/// keyboard and mouse are used). The same cue twice within 30 ms plays once.
class HapticFeedback {
  // ignore: prefer_initializing_formals
  HapticFeedback(this.output, {bool enabled = true}) : _enabled = enabled;

  static const sameCueGap = Duration(milliseconds: 30);

  final HapticOutput output;
  bool _enabled;
  bool _inFront = true;

  /// The controller sent the last input (not the keyboard or the mouse).
  bool padInUse = false;

  HapticCue? _lastCue;
  Duration? _lastTime;

  bool get enabled => _enabled;
  set enabled(bool value) {
    if (_enabled && !value) output.stop();
    _enabled = value;
  }

  /// The launcher's window is in front; false while a game or another window is.
  bool get launcherInFront => _inFront;
  set launcherInFront(bool value) {
    if (_inFront && !value) output.stop();
    _inFront = value;
  }

  bool play(HapticCue cue, {required Duration now}) {
    if (!_enabled || !_inFront || !padInUse) return false;
    if (_lastCue == cue && _lastTime != null && now - _lastTime! < sameCueGap) return false;
    _lastCue = cue;
    _lastTime = now;
    output.play(HapticPatterns.pulses(cue));
    return true;
  }

  void stop() => output.stop();
}

/// A controller's two motors, set at once; the readers (XInput, evdev) give one.
abstract class PadRumble {
  /// Whether [pad] has motors this launcher can turn.
  bool canRumble(String pad);

  /// Sets [pad]'s motors (0 to 1) for at most [length]; zero stops them.
  void rumble(String pad, double strong, double weak, Duration length);
}

/// Plays pulses on the pad used last through [PadRumble]: each pulse's motors at its start,
/// both at zero at its end. A new pattern stops the one before; a pad without motors is skipped.
class PulsePlayer implements HapticOutput {
  PulsePlayer(this.rumble);

  final PadRumble rumble;

  /// The pad the pulses go to (the one used last).
  String? pad;

  final List<Timer> _timers = [];
  String? _playingOn;

  @override
  void play(List<HapticPulse> pulses) {
    final target = pad;
    if (target == null || !rumble.canRumble(target)) return;
    stop();
    _playingOn = target;
    for (final pulse in pulses) {
      _timers.add(Timer(pulse.start, () => rumble.rumble(target, pulse.strong, pulse.weak, pulse.length)));
      _timers.add(Timer(pulse.end, () => rumble.rumble(target, 0, 0, Duration.zero)));
    }
  }

  @override
  void stop() {
    // Motors are set to zero only when a pattern was still playing.
    final unfinished = _timers.any((timer) => timer.isActive);
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
    final playing = _playingOn;
    _playingOn = null;
    if (playing != null && unfinished) rumble.rumble(playing, 0, 0, Duration.zero);
  }
}
