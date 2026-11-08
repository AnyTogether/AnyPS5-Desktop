import 'dart:async';

import 'feel.dart';
import 'shortcuts.dart';

/// A controller's buttons, by place on the pad (Cross is south, Triangle north; on an Xbox pad
/// A is south, Y north). The system readers (Windows XInput and winmm, Linux evdev) turn their
/// own numbers into these.
enum PadButton {
  south,
  east,
  west,
  north,
  l1,
  r1,
  l2,
  r2,
  select,
  start,
  guide,
  l3,
  r3,
  dpadUp,
  dpadDown,
  dpadLeft,
  dpadRight,

  /// The touchpad's click (DualSense, DualShock 4) and the extra button (Xbox Share, DualSense
  /// microphone, Switch capture): only the controller test shows them.
  touchpad,
  misc,
}

/// The two axes the launcher reads: the left stick, -1 (left, up) to 1 (right, down).
enum PadAxis { leftX, leftY }

/// What a controller did, from a system reader.
sealed class PadEvent {
  const PadEvent(this.pad);

  /// Which controller (a reader's own id, kept while it stays connected).
  final String pad;
}

class PadButtonEvent extends PadEvent {
  const PadButtonEvent(super.pad, this.button, {required this.down});
  final PadButton button;
  final bool down;

  @override
  String toString() => 'PadButtonEvent($pad, $button, ${down ? 'down' : 'up'})';
}

class PadAxisEvent extends PadEvent {
  const PadAxisEvent(super.pad, this.axis, this.value);
  final PadAxis axis;
  final double value;

  @override
  String toString() => 'PadAxisEvent($pad, $axis, $value)';
}

/// A controller left (unplugged, turned off): what it held is let go.
class PadGone extends PadEvent {
  const PadGone(super.pad);
}

/// What the launcher's screens act on, as a controller gives it.
enum PadCommand {
  left,
  right,
  up,
  down,
  select,
  back,
  options,

  /// Options/Start (Triangle is [options]): on Home the menu with Switch Profile and online or
  /// offline; elsewhere the same as [options].
  menu,
  previousGame,
  nextGame,
  home,

  /// PS held ([ShortcutTiming.hold]): the home menu in the launcher, "Close game?" in a game.
  homeHold,
  quickMenu,
  screenshot,
  saveClip,
  fullscreen,
}

/// Controller input as launcher commands, the way the macOS launcher's Input.swift reads a pad:
/// the D-pad and the left stick move (a held direction repeats on [KeyRepeat]'s pace, the same
/// as the arrow keys; the stick has hysteresis and keeps up and down harder to reach,
/// [StickGate]), Cross/A selects, Circle/B goes
/// back, Triangle/Y and Options open the options. Any number of pads at once; a pad that goes
/// away lets go of what it held.
///
/// The shortcuts ([ShortcutMap], Settings › Shortcuts) come on top: PS (Home), L1 and R1 (the
/// sections), Share (a clip, held a screenshot) and whatever the user bound, a button or several
/// held together. The buttons pressed must be exactly a binding's; one with a held partner (PS,
/// Share) acts when it is let go, or when it has been held [ShortcutTiming.hold]; one without
/// acts at once. A button that completes a chord of several does not also do its own move.
class PadNavigator {
  PadNavigator(this.onCommand, {ShortcutMap? shortcuts, this.isPlayStation}) {
    _repeater = HoldRepeater<PadCommand>(_send);
    this.shortcuts = shortcuts ?? ShortcutMap();
  }

  final void Function(PadCommand command) onCommand;

  /// Whether [pad] is a PlayStation controller: its Create button (SDL's Back, which the engine
  /// never gives a game on a PlayStation pad) is Share there, as the Xbox pad's own Share is.
  bool Function(String pad)? isPlayStation;
  bool Function()? reservesGuide;

  /// The face buttons and Options: the launcher's own moves, which no shortcut takes alone.
  static const buttons = {
    PadButton.south: PadCommand.select,
    PadButton.east: PadCommand.back,
    PadButton.north: PadCommand.options,
    PadButton.start: PadCommand.menu,
  };

  /// What a shortcut's action is as a command.
  static PadCommand commandFor(LauncherAction action) => switch (action) {
    LauncherAction.home => PadCommand.home,
    LauncherAction.quickMenu => PadCommand.quickMenu,
    LauncherAction.screenshot => PadCommand.screenshot,
    LauncherAction.saveClip => PadCommand.saveClip,
    LauncherAction.toggleFullscreen => PadCommand.fullscreen,
    LauncherAction.previousSection => PadCommand.previousGame,
    LauncherAction.nextSection => PadCommand.nextGame,
  };

  static const _dpad = {PadButton.dpadUp, PadButton.dpadDown, PadButton.dpadLeft, PadButton.dpadRight};

  ShortcutMap _shortcuts = ShortcutMap();
  Map<PadChord, LauncherAction> _chords = const {};
  Set<PadButton> _gameButtons = const {};

  ShortcutMap get shortcuts => _shortcuts;
  set shortcuts(ShortcutMap value) {
    _shortcuts = value;
    _chords = value.padActions;
    _gameButtons = {
      for (final entry in _chords.entries)
        if (entry.value.inGame) ...entry.key.buttons,
    };
  }

  final Map<String, _PadState> _pads = {};
  late final HoldRepeater<PadCommand> _repeater;

  /// The pad that gave the last command: the one the launcher's pulses go to.
  String? lastPad;

  /// Settings › Controllers › Confirm Button: Circle (east) selects and Cross (south) goes back.
  bool circleConfirms = false;
  String? _sending;

  /// The direction being repeated, for tests.
  PadCommand? get held => _repeater.held;

  /// Whether the command being handed on is a repeat of a held direction.
  bool get repeating => _repeater.repeating;

  /// [button] as the shortcuts name it: a PlayStation pad's Create is Share ([PadButton.misc]).
  PadButton normalize(String pad, PadButton button) =>
      button == PadButton.select && (isPlayStation?.call(pad) ?? false) ? PadButton.misc : button;

  /// Whether [button] of [pad] belongs to a shortcut that acts in a game, so it must reach the
  /// navigator while a game is in front ([PadGate]).
  bool passesInGame(String pad, PadButton button) =>
      (button == PadButton.guide && (reservesGuide?.call() ?? false)) || _gameButtons.contains(normalize(pad, button));

  void _send(PadCommand command) {
    lastPad = _sending ?? _repeater.heldBy as String? ?? lastPad;
    onCommand(command);
  }

  void _sendFrom(String pad, PadCommand command) {
    _sending = pad;
    _send(command);
    _sending = null;
  }

  void handle(PadEvent event) {
    final state = _pads.putIfAbsent(event.pad, _PadState.new);
    switch (event) {
      case PadButtonEvent(:final down):
        final button = normalize(event.pad, event.button);
        if (state.pressed.contains(button) == down) return;
        down ? state.pressed.add(button) : state.pressed.remove(button);
        if (down) {
          _pressed(event.pad, state, button);
        } else {
          _released(event.pad, state, button);
        }
      case PadAxisEvent(:final axis, :final value):
        if (axis == PadAxis.leftX) {
          state.x = value;
        } else {
          state.y = value;
        }
        state.stick.update(state.x, state.y);
      case PadGone():
        _pads.remove(event.pad)?.disarm();
        if (_repeater.heldBy == event.pad) _repeater.stop();
        return;
    }
    _direction(event.pad, state);
  }

  void _pressed(String pad, _PadState state, PadButton button) {
    state.disarm();
    if (button == PadButton.guide && (reservesGuide?.call() ?? false)) {
      _armShortcut(pad, state, {button}, PadCommand.home, PadCommand.homeHold);
      return;
    }
    // A direction held on the D-pad is not part of a chord unless the chord names it.
    var chord = state.pressed;
    if (!_chords.containsKey(PadChord(chord)) && !_chords.containsKey(PadChord(chord, hold: true))) {
      chord = {...state.pressed}..removeAll(_dpad);
    }
    final pressAction = _chords[PadChord(chord)];
    final holdAction = _chords[PadChord(chord, hold: true)];
    if (pressAction != null || holdAction != null) {
      final press = pressAction == null ? null : commandFor(pressAction);
      final hold = holdAction != null
          ? commandFor(holdAction)
          : (pressAction == LauncherAction.home ? PadCommand.homeHold : null);
      if (hold == null) {
        _sendFrom(pad, press!);
      } else {
        _armShortcut(pad, state, chord, press, hold);
      }
      // A chord of several: its last button does not also do its own move.
      if (chord.length > 1) return;
    }
    var command = buttons[button];
    if (circleConfirms) {
      command = switch (command) {
        PadCommand.select => PadCommand.back,
        PadCommand.back => PadCommand.select,
        _ => command,
      };
    }
    if (command != null) _sendFrom(pad, command);
  }

  void _armShortcut(String pad, _PadState state, Set<PadButton> chord, PadCommand? press, PadCommand hold) {
    state.armed = {...chord};
    state.armedPress = press;
    state.timer = Timer(ShortcutTiming.hold, () {
      state.timer = null;
      state.armed = null;
      _sendFrom(pad, hold);
    });
  }

  void _released(String pad, _PadState state, PadButton button) {
    final armed = state.armed;
    if (armed == null || !armed.contains(button)) return;
    final press = state.armedPress;
    state.disarm();
    if (press != null) _sendFrom(pad, press);
  }

  void _direction(String pad, _PadState state) {
    var x = 0;
    var y = 0;
    if (state.pressed.contains(PadButton.dpadLeft)) x -= 1;
    if (state.pressed.contains(PadButton.dpadRight)) x += 1;
    if (state.pressed.contains(PadButton.dpadUp)) y -= 1;
    if (state.pressed.contains(PadButton.dpadDown)) y += 1;
    final Direction? direction;
    final fromStick = x == 0 && y == 0;
    if (!fromStick) {
      // The D-pad wins over the stick; a diagonal is its horizontal half.
      direction = x != 0 ? (x > 0 ? Direction.right : Direction.left) : (y > 0 ? Direction.down : Direction.up);
    } else {
      direction = state.stick.held;
    }
    final command = switch (direction) {
      Direction.left => PadCommand.left,
      Direction.right => PadCommand.right,
      Direction.up => PadCommand.up,
      Direction.down => PadCommand.down,
      null => null,
    };
    // Another pad's held direction is only let go by that pad.
    if (command == null && _repeater.heldBy != pad) return;
    if (command == _repeater.held && (_repeater.heldBy == pad || command == null)) return;
    if (command == null) return _repeater.stop();
    _sending = pad;
    // Up and down on the stick wait longer before repeating (StickGate).
    final vertical = fromStick && StickGate.isVertical(direction!);
    _repeater.hold(command, by: pad, firstDelay: vertical ? StickGate.verticalFirstDelay : null);
    _sending = null;
  }

  /// Forgets what every pad holds (Settings › Shortcuts takes the buttons for a while): the
  /// presses going on act no more, and their releases are nothing.
  void reset() {
    _repeater.stop();
    for (final state in _pads.values) {
      state.disarm();
    }
    _pads.clear();
  }

  void dispose() {
    _repeater.stop();
    for (final state in _pads.values) {
      state.disarm();
    }
    _pads.clear();
  }
}

class _PadState {
  final Set<PadButton> pressed = {};
  final StickGate stick = StickGate();
  double x = 0;
  double y = 0;

  /// The chord waiting to be let go or held long enough, and what letting it go does.
  Set<PadButton>? armed;
  PadCommand? armedPress;
  Timer? timer;

  void disarm() {
    timer?.cancel();
    timer = null;
    armed = null;
    armedPress = null;
  }
}

/// Where controller events come from on this system.
abstract class PadSource {
  /// Starts reading every controller there is and every one plugged in later.
  void start(void Function(PadEvent event) onEvent);
  void stop();

  /// What the reader found, for the log ("XInput 1, DualSense (winmm) 0").
  String get description;

  /// The controllers' motors, where this reader can turn them (XInput, evdev force feedback);
  /// null where it cannot.
  PadRumble? get motors;
}

/// No controllers (tests, systems without a reader).
class NoPadSource implements PadSource {
  const NoPadSource();
  @override
  void start(void Function(PadEvent event) onEvent) {}
  @override
  void stop() {}
  @override
  String get description => 'none';
  @override
  PadRumble? get motors => null;
}

/// One controller as a polling reader sees it at one moment: what is held, where the stick is.
class PadSnapshot {
  const PadSnapshot(this.pressed, {this.x = 0, this.y = 0});

  static const idle = PadSnapshot({});

  final Set<PadButton> pressed;
  final double x;
  final double y;

  /// The events that turn [before] into [after] for [pad].
  static List<PadEvent> diff(String pad, PadSnapshot before, PadSnapshot after) => [
    for (final button in PadButton.values)
      if (before.pressed.contains(button) != after.pressed.contains(button))
        PadButtonEvent(pad, button, down: after.pressed.contains(button)),
    if (before.x != after.x) PadAxisEvent(pad, PadAxis.leftX, after.x),
    if (before.y != after.y) PadAxisEvent(pad, PadAxis.leftY, after.y),
  ];
}

/// The system readers' numbers as pad buttons.
abstract final class PadMaps {
  /// XInput's wButtons (XINPUT_GAMEPAD_*; Guide is 0x0400, given by XInputGetStateEx) and its
  /// left stick (up is positive there).
  static PadSnapshot xinput(int buttons, int thumbX, int thumbY) {
    const bits = {
      0x0001: PadButton.dpadUp,
      0x0002: PadButton.dpadDown,
      0x0004: PadButton.dpadLeft,
      0x0008: PadButton.dpadRight,
      0x0010: PadButton.start,
      0x0020: PadButton.select,
      0x0040: PadButton.l3,
      0x0080: PadButton.r3,
      0x0100: PadButton.l1,
      0x0200: PadButton.r1,
      0x0400: PadButton.guide,
      0x1000: PadButton.south,
      0x2000: PadButton.east,
      0x4000: PadButton.west,
      0x8000: PadButton.north,
    };
    return PadSnapshot(
      {
        for (final entry in bits.entries)
          if (buttons & entry.key != 0) entry.value,
      },
      x: _unit(thumbX / 32767),
      y: _unit(-thumbY / 32767),
    );
  }

  /// A PlayStation controller (DualSense, DualShock 4) through winmm's joyGetPosEx, which numbers
  /// its buttons as DirectInput does: Square, Cross, Circle, Triangle, L1, R1, L2, R2, Create,
  /// Options, L3, R3, PS, touchpad. [pov] is the hat in hundredths of a degree (0 up, 9000 right),
  /// 0xFFFF when centred; [x] and [y] the left stick already as -1 to 1.
  static PadSnapshot sonyWinmm(int buttons, int pov, double x, double y) {
    const order = [
      PadButton.west,
      PadButton.south,
      PadButton.east,
      PadButton.north,
      PadButton.l1,
      PadButton.r1,
      PadButton.l2,
      PadButton.r2,
      PadButton.select,
      PadButton.start,
      PadButton.l3,
      PadButton.r3,
      PadButton.guide,
    ];
    return PadSnapshot(
      {
        for (var bit = 0; bit < order.length; bit++)
          if (buttons & (1 << bit) != 0) order[bit],
        ...hat(pov),
      },
      x: _unit(x),
      y: _unit(y),
    );
  }

  /// A POV hat (hundredths of a degree clockwise from up; anything above 36000 is centred) as
  /// D-pad buttons; the diagonals hold two.
  static Set<PadButton> hat(int pov) {
    if (pov < 0 || pov >= 36000) return const {};
    final degrees = pov / 100;
    bool near(double target) {
      final distance = ((degrees - target + 540) % 360 - 180).abs();
      return distance < 67.5;
    }

    return {
      if (near(0)) PadButton.dpadUp,
      if (near(90)) PadButton.dpadRight,
      if (near(180)) PadButton.dpadDown,
      if (near(270)) PadButton.dpadLeft,
    };
  }

  /// A Linux evdev key code (BTN_SOUTH and on, BTN_DPAD_*) as a pad button. The xpad driver
  /// reports an Xbox pad's X as BTN_X (BTN_NORTH) and Y as BTN_Y (BTN_WEST), the other way round
  /// from where they sit; [xbox] puts them back.
  static PadButton? evdevKey(int code, {bool xbox = false}) => switch (code) {
    0x130 => PadButton.south,
    0x131 => PadButton.east,
    0x133 => xbox ? PadButton.west : PadButton.north,
    0x134 => xbox ? PadButton.north : PadButton.west,
    0x136 => PadButton.l1,
    0x137 => PadButton.r1,
    0x138 => PadButton.l2,
    0x139 => PadButton.r2,
    0x13a => PadButton.select,
    0x13b => PadButton.start,
    0x13c => PadButton.guide,
    0x13d => PadButton.l3,
    0x13e => PadButton.r3,
    0x220 => PadButton.dpadUp,
    0x221 => PadButton.dpadDown,
    0x222 => PadButton.dpadLeft,
    0x223 => PadButton.dpadRight,
    _ => null,
  };

  /// An axis value from [minimum] to [maximum] as -1 to 1.
  static double scale(int value, int minimum, int maximum) {
    if (maximum <= minimum) return 0;
    return _unit((value - minimum) / (maximum - minimum) * 2 - 1);
  }

  static double _unit(double value) => value.clamp(-1.0, 1.0);
}
