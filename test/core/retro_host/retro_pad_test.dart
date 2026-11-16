import 'package:anyps5_desktop/core/controllers/pad_info.dart';
import 'package:anyps5_desktop/core/gamepad/pad_navigation.dart';
import 'package:anyps5_desktop/core/retro_host/retro_pad.dart';
import 'package:test/test.dart';

void main() {
  test('each pad button presses the bit of anyps5-retro-host docs/protocol.md "input"', () {
    const table = {
      PadButton.south: 0,
      PadButton.west: 1,
      PadButton.select: 2,
      PadButton.start: 3,
      PadButton.dpadUp: 4,
      PadButton.dpadDown: 5,
      PadButton.dpadLeft: 6,
      PadButton.dpadRight: 7,
      PadButton.east: 8,
      PadButton.north: 9,
      PadButton.l1: 10,
      PadButton.r1: 11,
      PadButton.l2: 12,
      PadButton.r2: 13,
      PadButton.l3: 14,
      PadButton.r3: 15,
    };
    for (final MapEntry(key: button, value: bit) in table.entries) {
      expect(RetroPadInput.fromPad(PadState(pressed: {button})).buttons, 1 << bit, reason: '$button');
    }
    final all = RetroPadInput.fromPad(PadState(pressed: table.keys.toSet()));
    expect(all.buttons, 0xFFFF);
  });

  test('PS, the touchpad and the extra button stay the launcher\'s', () {
    final input = RetroPadInput.fromPad(const PadState(pressed: {PadButton.guide, PadButton.touchpad, PadButton.misc}));
    expect(input, RetroPadInput.idle);
  });

  test('a trigger pulled past the reader\'s press point presses L2 or R2', () {
    expect(RetroPadInput.fromPad(const PadState(l2: 0.34)).buttons, 0);
    expect(RetroPadInput.fromPad(const PadState(l2: 0.35)).buttons, RetroPadButton.l2.mask);
    expect(RetroPadInput.fromPad(const PadState(r2: 1)).buttons, RetroPadButton.r2.mask);
  });

  test('the sticks reach both ends of the protocol\'s range, up and left negative', () {
    final input = RetroPadInput.fromPad(const PadState(leftX: -1, leftY: 1, rightX: 1, rightY: -1));
    expect(input, const RetroPadInput(leftX: -32768, leftY: 32767, rightX: 32767, rightY: -32768));
    expect(RetroPadInput.axis(0), 0);
    expect(RetroPadInput.axis(0.5), 16384);
    expect(RetroPadInput.axis(-0.5), -16384);
    expect(RetroPadInput.axis(2), 32767);
    expect(RetroPadInput.axis(double.nan), 0);
  });

  test('the stick dead zone centres each stick on its own', () {
    final input = RetroPadInput.fromPad(const PadState(leftX: 0.1, rightY: 1), deadzonePercent: 20);
    expect(input.leftX, 0);
    expect(input.rightY, 32767);
  });
}
