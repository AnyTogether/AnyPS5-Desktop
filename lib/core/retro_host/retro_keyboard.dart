import '../controllers/pad_info.dart';
import '../controls.dart';
import '../gamepad/pad_navigation.dart';

/// The keyboard as a PS1 controller, by the keys a game's Controls give each [PadAction]
/// ([Controls.sources]: the launcher's layout with the keys the player moved). Its state joins
/// the controller at port 1, as a libretro frontend binds the keyboard to player 1.
///
/// Only keys count: mouse buttons and the wheel are not read. The touchpad's two halves are the
/// PS1's Select, as on the PS4 and PS5's own PS1 releases. The stick modifier tilts the
/// keyboard's sticks only by [modifierScale].
class RetroKeyboard {
  RetroKeyboard(Map<String, List<String>> changes, {this.modifierScale = 0.5}) : _actions = _byUsage(changes);

  /// How far the keyboard's sticks tilt while the stick modifier is held, 0 to 1.
  final double modifierScale;

  final Map<int, List<PadAction>> _actions;

  /// The actions each key presses, by the key's USB HID usage on the keyboard page.
  static Map<int, List<PadAction>> _byUsage(Map<String, List<String>> changes) {
    final usageOf = <String, int>{};
    for (var usage = 0; usage <= 0xFF; usage++) {
      final name = Controls.keyName(usage);
      if (name != null) usageOf.putIfAbsent(name, () => usage);
    }
    final actions = <int, List<PadAction>>{};
    for (final action in PadAction.values) {
      for (final source in Controls.sources(action, changes)) {
        if (!source.startsWith('KEY:')) continue;
        final usage = usageOf[source.substring(4)];
        if (usage != null) (actions[usage] ??= []).add(action);
      }
    }
    return actions;
  }

  /// The keyboard's whole state while [held] are down: Flutter's PhysicalKeyboardKey.usbHidUsage
  /// of each key, page and usage.
  PadState state(Iterable<int> held) {
    final down = <PadAction>{};
    for (final usage in held) {
      if (usage >> 16 != 0x07) continue;
      down.addAll(_actions[usage & 0xFFFF] ?? const []);
    }
    final pressed = <PadButton>{
      for (final action in down)
        if (_button(action) case final PadButton button) button,
    };
    final tilt = down.contains(PadAction.stickModifier) ? modifierScale : 1.0;
    double axis(PadAction negative, PadAction positive) =>
        ((down.contains(positive) ? 1 : 0) - (down.contains(negative) ? 1 : 0)) * tilt;
    return PadState(
      pressed: pressed,
      leftX: axis(PadAction.leftStickLeft, PadAction.leftStickRight),
      leftY: axis(PadAction.leftStickUp, PadAction.leftStickDown),
      rightX: axis(PadAction.rightStickLeft, PadAction.rightStickRight),
      rightY: axis(PadAction.rightStickUp, PadAction.rightStickDown),
      l2: down.contains(PadAction.l2) ? 1 : 0,
      r2: down.contains(PadAction.r2) ? 1 : 0,
    );
  }

  static PadButton? _button(PadAction action) => switch (action) {
    PadAction.cross => PadButton.south,
    PadAction.circle => PadButton.east,
    PadAction.square => PadButton.west,
    PadAction.triangle => PadButton.north,
    PadAction.l1 => PadButton.l1,
    PadAction.r1 => PadButton.r1,
    PadAction.l2 => PadButton.l2,
    PadAction.r2 => PadButton.r2,
    PadAction.l3 => PadButton.l3,
    PadAction.r3 => PadButton.r3,
    PadAction.options => PadButton.start,
    PadAction.touchLeft || PadAction.touchRight => PadButton.select,
    PadAction.up => PadButton.dpadUp,
    PadAction.down => PadButton.dpadDown,
    PadAction.left => PadButton.dpadLeft,
    PadAction.right => PadButton.dpadRight,
    PadAction.leftStickUp ||
    PadAction.leftStickDown ||
    PadAction.leftStickLeft ||
    PadAction.leftStickRight ||
    PadAction.rightStickUp ||
    PadAction.rightStickDown ||
    PadAction.rightStickLeft ||
    PadAction.rightStickRight ||
    PadAction.stickModifier => null,
  };

  /// [pad] and [keys] held together: every button of either, and each stick from the keys while
  /// they tilt it, from the controller otherwise.
  static PadState merge(PadState? pad, PadState keys) {
    if (pad == null) return keys;
    final keysLeft = keys.leftX != 0 || keys.leftY != 0;
    final keysRight = keys.rightX != 0 || keys.rightY != 0;
    return PadState(
      pressed: {...pad.pressed, ...keys.pressed},
      leftX: keysLeft ? keys.leftX : pad.leftX,
      leftY: keysLeft ? keys.leftY : pad.leftY,
      rightX: keysRight ? keys.rightX : pad.rightX,
      rightY: keysRight ? keys.rightY : pad.rightY,
      l2: pad.l2 > keys.l2 ? pad.l2 : keys.l2,
      r2: pad.r2 > keys.r2 ? pad.r2 : keys.r2,
    );
  }
}
