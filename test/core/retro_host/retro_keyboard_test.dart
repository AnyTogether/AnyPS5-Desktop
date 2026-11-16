import 'package:anyps5_desktop/core/controllers/pad_info.dart';
import 'package:anyps5_desktop/core/controls.dart';
import 'package:anyps5_desktop/core/gamepad/pad_navigation.dart';
import 'package:anyps5_desktop/core/retro_host/retro_keyboard.dart';
import 'package:anyps5_desktop/core/retro_host/retro_pad.dart';
import 'package:test/test.dart';

/// A keyboard key as Flutter's PhysicalKeyboardKey.usbHidUsage gives it: page 7, the usage.
int key(int usage) => 0x00070000 | usage;

const k = 0x0E, l = 0x0F, j = 0x0D, i = 0x0C, w = 0x1A, a = 0x04, s = 0x16, d = 0x07, escape = 0x29;
const backspace = 0x2A, tab = 0x2B, up = 0x52, leftShift = 0xE1, f1 = 0x3A, u = 0x18;

void main() {
  test('the launcher\'s layout plays the PS1 pad: face buttons, Start, Select, the D-pad and the sticks', () {
    final keyboard = RetroKeyboard(const {});
    expect(keyboard.state(const []), PadState.idle);
    expect(keyboard.state([key(k), key(l), key(j), key(i)]).pressed, {
      PadButton.south,
      PadButton.east,
      PadButton.west,
      PadButton.north,
    });
    expect(keyboard.state([key(escape)]).pressed, {PadButton.start});
    expect(keyboard.state([key(backspace)]).pressed, {PadButton.select});
    expect(keyboard.state([key(tab)]).pressed, {PadButton.select});
    expect(keyboard.state([key(up)]).pressed, {PadButton.dpadUp});
    expect(keyboard.state([key(leftShift)]).pressed, {PadButton.l3});
    final walking = keyboard.state([key(w), key(d)]);
    expect((walking.leftX, walking.leftY), (1.0, -1.0));
    final both = keyboard.state([key(a), key(d), key(s)]);
    expect((both.leftX, both.leftY), (0.0, 1.0), reason: 'left and right together cancel');
    final l2 = keyboard.state([key(u)]);
    expect(l2.l2, 1.0);
    expect(l2.pressed, {PadButton.l2});
    expect(
      RetroPadInput.fromPad(keyboard.state([key(k), key(escape)])).buttons,
      RetroPadButton.cross.mask | RetroPadButton.start.mask,
    );
  });

  test('the keys a game\'s Controls moved, and only keyboard keys', () {
    final changes = Controls.assign('KEY:F1', PadAction.cross, const {});
    final keyboard = RetroKeyboard(changes);
    expect(keyboard.state([key(f1)]).pressed, {PadButton.south});
    expect(keyboard.state([key(k)]).pressed, isEmpty, reason: 'K no longer presses Cross');
    expect(keyboard.state([0x00010082]).pressed, isEmpty, reason: 'a key off the keyboard page');
  });

  test('the stick modifier tilts the keyboard sticks only part way', () {
    final keyboard = RetroKeyboard(
      Controls.assign('KEY:Left Alt', PadAction.stickModifier, const {}),
      modifierScale: 0.25,
    );
    final state = keyboard.state([key(w), key(0xE2)]);
    expect(state.leftY, -0.25);
  });

  test('keys join a controller: every button of both, a stick from the keys while they tilt it', () {
    const pad = PadState(pressed: {PadButton.east}, leftX: 0.5, rightY: 0.25, l2: 0.6);
    final keys = RetroKeyboard(const {}).state([key(k), key(w)]);
    final both = RetroKeyboard.merge(pad, keys);
    expect(both.pressed, {PadButton.east, PadButton.south});
    expect((both.leftX, both.leftY), (0.0, -1.0));
    expect((both.rightX, both.rightY), (0.0, 0.25));
    expect(both.l2, 0.6);
    expect(RetroKeyboard.merge(null, keys), keys);
  });
}
