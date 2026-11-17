import '../controllers/pad_info.dart';
import '../controllers/sdl_maps.dart';
import '../gamepad/pad_navigation.dart';

/// The RetroPad buttons by their bit in the `input` message's `buttons` (anyps5-retro-host
/// docs/protocol.md "input"): the libretro `RETRO_DEVICE_ID_JOYPAD_*` numbers as SwanStation maps
/// them.
enum RetroPadButton {
  cross(0),
  square(1),
  select(2),
  start(3),
  up(4),
  down(5),
  left(6),
  right(7),
  circle(8),
  triangle(9),
  l1(10),
  r1(11),
  l2(12),
  r2(13),
  l3(14),
  r3(15);

  const RetroPadButton(this.bit);

  final int bit;

  int get mask => 1 << bit;

  /// The RetroPad button a launcher pad button presses, by its place on the pad: south is Cross
  /// on every controller, as on a PS1 pad. PS/Guide, the touchpad and the extra button have none:
  /// PS stays the launcher's.
  static RetroPadButton? of(PadButton button) => switch (button) {
    PadButton.south => cross,
    PadButton.east => circle,
    PadButton.west => square,
    PadButton.north => triangle,
    PadButton.l1 => l1,
    PadButton.r1 => r1,
    PadButton.l2 => l2,
    PadButton.r2 => r2,
    PadButton.l3 => l3,
    PadButton.r3 => r3,
    PadButton.select => select,
    PadButton.start => start,
    PadButton.dpadUp => up,
    PadButton.dpadDown => down,
    PadButton.dpadLeft => left,
    PadButton.dpadRight => right,
    PadButton.guide || PadButton.touchpad || PadButton.misc => null,
  };
}

/// One controller port's state as an `input` message carries it: the sixteen button bits and both
/// sticks from -32768 (fully left or up) to 32767.
class RetroPadInput {
  const RetroPadInput({this.buttons = 0, this.leftX = 0, this.leftY = 0, this.rightX = 0, this.rightY = 0});

  /// Nothing held, both sticks centred: what a port with no controller sends.
  static const idle = RetroPadInput();

  final int buttons;
  final int leftX;
  final int leftY;
  final int rightX;
  final int rightY;

  /// A launcher pad's state. A trigger counts as pressed from the point where the launcher's
  /// reader counts it ([SdlMaps.triggerPressed]), also for readers that give only its button. The
  /// sticks go through Settings › Controllers › Stick Dead Zone ([StickDeadzone]), each stick on
  /// its own.
  factory RetroPadInput.fromPad(PadState state, {int deadzonePercent = 0}) {
    var buttons = 0;
    for (final button in state.pressed) {
      final retro = RetroPadButton.of(button);
      if (retro != null) buttons |= retro.mask;
    }
    if (state.l2 >= SdlMaps.triggerPressed) buttons |= RetroPadButton.l2.mask;
    if (state.r2 >= SdlMaps.triggerPressed) buttons |= RetroPadButton.r2.mask;
    final (leftX, leftY) = StickDeadzone.apply(state.leftX, state.leftY, deadzonePercent);
    final (rightX, rightY) = StickDeadzone.apply(state.rightX, state.rightY, deadzonePercent);
    return RetroPadInput(
      buttons: buttons,
      leftX: axis(leftX),
      leftY: axis(leftY),
      rightX: axis(rightX),
      rightY: axis(rightY),
    );
  }

  /// A stick axis from -1 (left, up) to 1 (right, down) as the protocol's -32768 to 32767, so
  /// both ends reach the end of the range.
  static int axis(double value) {
    if (value.isNaN) return 0;
    final unit = value.clamp(-1.0, 1.0);
    return unit < 0 ? (unit * 32768).round() : (unit * 32767).round();
  }

  /// The same sticks with [buttons] held.
  RetroPadInput withButtons(int buttons) =>
      RetroPadInput(buttons: buttons, leftX: leftX, leftY: leftY, rightX: rightX, rightY: rightY);

  @override
  bool operator ==(Object other) =>
      other is RetroPadInput &&
      other.buttons == buttons &&
      other.leftX == leftX &&
      other.leftY == leftY &&
      other.rightX == rightX &&
      other.rightY == rightY;

  @override
  int get hashCode => Object.hash(buttons, leftX, leftY, rightX, rightY);

  @override
  String toString() => 'RetroPadInput($buttons, $leftX, $leftY, $rightX, $rightY)';
}
