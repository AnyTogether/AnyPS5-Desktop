import 'dart:typed_data';

import 'package:anyps5_desktop/core/gamepad/feel.dart';
import 'package:anyps5_desktop/core/gamepad/linux_pads.dart';
import 'package:anyps5_desktop/core/gamepad/windows_pads.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

class FakeOutput implements HapticOutput {
  final List<List<HapticPulse>> played = [];
  int stops = 0;
  @override
  void play(List<HapticPulse> pulses) => played.add(pulses);
  @override
  void stop() => stops++;
}

class FakeRumble implements PadRumble {
  final List<String> calls = [];
  final Set<String> motors = {'xinput0'};
  @override
  bool canRumble(String pad) => motors.contains(pad);
  @override
  void rumble(String pad, double strong, double weak, Duration length) =>
      calls.add('$pad $strong $weak ${length.inMilliseconds}');
}

const ms = Duration(milliseconds: 1);

void main() {
  group('key repeat', () {
    test('a held direction waits, repeats, then speeds up a little', () {
      expect(KeyRepeat.delayBefore(1), ms * 400);
      for (var repeat = 2; repeat <= KeyRepeat.fastAfter; repeat++) {
        expect(KeyRepeat.delayBefore(repeat), ms * 80);
      }
      expect(KeyRepeat.delayBefore(KeyRepeat.fastAfter + 1), ms * 60);
      expect(KeyRepeat.delayBefore(40), ms * 60);
    });

    test('a one-second hold moves at a console menu\'s pace; a tap is one move', () {
      expect(KeyRepeat.times(const Duration(seconds: 1)), [
        Duration.zero,
        ms * 400,
        ms * 480,
        ms * 560,
        ms * 640,
        ms * 720,
        ms * 800,
        ms * 860,
        ms * 920,
        ms * 980,
      ]);
      expect(KeyRepeat.times(ms * 399), [Duration.zero]);
    });

    test('the repeater hands the command on at once, then on that pace, marking repeats', () {
      fakeAsync((async) {
        final seen = <(String, bool)>[];
        late HoldRepeater<String> repeater;
        repeater = HoldRepeater<String>((command) => seen.add((command, repeater.repeating)));
        repeater.hold('down', by: 'pad');
        expect(seen, [('down', false)]);
        async.elapse(ms * 399);
        expect(seen, hasLength(1));
        async.elapse(ms * (1 + 80 * 5 + 60 * 2));
        expect(seen, hasLength(1 + 1 + 5 + 2));
        expect(seen.skip(1).every((entry) => entry.$2), isTrue, reason: 'every one after the press is a repeat');
        repeater.stop();
        async.elapse(const Duration(seconds: 1));
        expect(seen, hasLength(9));
        repeater.holdQuietly('up');
        expect(seen, hasLength(9), reason: 'held without handing the press on again');
        async.elapse(ms * 400);
        expect(seen.last, ('up', true));
        repeater.stop();
      });
    });

    test('a repeat that fires after a stall of the interface is dropped, not handed on', () {
      fakeAsync((async) {
        var clock = Duration.zero;
        final seen = <String>[];
        final repeater = HoldRepeater<String>(seen.add, now: () => clock);
        // A tap: the press moves at once, then the interface freezes for a second before the
        // release (queued behind the freeze) is read.
        repeater.holdQuietly('right');
        clock += const Duration(seconds: 1);
        async.elapse(ms * 400);
        expect(seen, isEmpty, reason: 'the late repeat must not move the selection');
        repeater.stop();
        async.elapse(const Duration(seconds: 1));
        expect(seen, isEmpty);
      });
    });

    test('after a stall a direction really still held starts repeating again', () {
      fakeAsync((async) {
        var clock = Duration.zero;
        final seen = <String>[];
        final repeater = HoldRepeater<String>(seen.add, now: () => clock);
        repeater.holdQuietly('right');
        clock += const Duration(seconds: 1);
        async.elapse(ms * 400);
        expect(seen, isEmpty);
        // On time again: the wait began anew, so the first repeat comes 0.40 s later.
        clock += ms * 400;
        async.elapse(ms * 400);
        expect(seen, ['right']);
        repeater.stop();
      });
    });

    test('a repeat a little late (under the stall limit) is still handed on', () {
      fakeAsync((async) {
        var clock = Duration.zero;
        final seen = <String>[];
        final repeater = HoldRepeater<String>(seen.add, now: () => clock);
        repeater.holdQuietly('right');
        clock += ms * 550;
        async.elapse(ms * 400);
        expect(seen, ['right']);
        repeater.stop();
      });
    });
  });

  group('stick', () {
    test('engages past half and lets go only below a third', () {
      final stick = StickGate();
      expect(stick.update(0.45, 0), isNull);
      expect(stick.update(0.52, 0), Direction.right);
      for (final x in [0.48, 0.41, 0.35, 0.31, 0.44]) {
        expect(stick.update(x, 0), Direction.right, reason: 'x $x');
      }
      expect(stick.update(0.29, 0), isNull);
      expect(stick.update(0.45, 0), isNull, reason: 'below the engage line again after letting go');
    });

    test('down is positive; the bigger axis wins at first', () {
      expect(StickGate().update(0.3, -0.7), Direction.up);
      expect(StickGate().update(-0.7, 0.6), Direction.left);
      expect(StickGate().update(0.1, 0.9), Direction.down);
    });

    test('the other axis takes over only when it clearly leads', () {
      final stick = StickGate();
      expect(stick.update(0.7, 0), Direction.right);
      expect(stick.update(0.6, -0.7), Direction.right, reason: 'near the diagonal the held direction stays');
      expect(stick.update(0.4, -0.7), Direction.up, reason: '0.7 is more than 1.5 × 0.4');
      expect(stick.update(-0.6, -0.45), Direction.left, reason: 'and back: 0.6 is more than 1.25 × 0.45');
    });

    test('a flick through the middle turns at once', () {
      final stick = StickGate();
      expect(stick.update(0.9, 0), Direction.right);
      expect(stick.update(-0.8, 0), Direction.left);
      expect(stick.update(0, 0), isNull);
    });
  });

  group('edge bump', () {
    test('a move into the wall bumps once per hold', () {
      final edge = EdgeBump();
      expect(edge.handled(direction: true, repeat: false, changed: true), isFalse);
      expect(edge.handled(direction: true, repeat: true, changed: true), isFalse);
      expect(
        edge.handled(direction: true, repeat: true, changed: false),
        isTrue,
        reason: 'the hold reached the last tile',
      );
      expect(
        edge.handled(direction: true, repeat: true, changed: false),
        isFalse,
        reason: 'silent for the rest of the hold',
      );
      expect(
        edge.handled(direction: true, repeat: false, changed: false),
        isTrue,
        reason: 'a new press against the wall',
      );
    });

    test('only directions bump', () {
      expect(EdgeBump().handled(direction: false, repeat: false, changed: false), isFalse);
    });
  });

  group('hover tick', () {
    bool arrive(
      HoverGate gate,
      String id,
      double x,
      int at, {
      int? lastCue,
      bool buttons = false,
      bool allowed = true,
    }) => gate.arrive(
      id,
      x: x,
      y: 10,
      now: ms * at,
      lastCue: lastCue == null ? null : ms * lastCue,
      buttonsDown: buttons,
      allowed: allowed,
    );

    test('one tick per arrival on a new element', () {
      final gate = HoverGate();
      expect(arrive(gate, 'tile-1', 10, 1000), isTrue);
      expect(arrive(gate, 'tile-1', 30, 1500), isFalse, reason: 'still on the same tile');
      expect(arrive(gate, 'tile-2', 60, 2000), isTrue);
      gate.leave('tile-2');
      expect(arrive(gate, 'tile-2', 70, 2500), isTrue, reason: 'back on it after leaving it');
    });

    test('only real pointer movement ticks', () {
      final gate = HoverGate();
      expect(arrive(gate, 'row-1', 10, 1000), isTrue);
      expect(arrive(gate, 'row-2', 10, 1500), isFalse, reason: 'the list scrolled under a resting pointer');
      expect(arrive(gate, 'row-3', 14, 2000), isTrue);
    });

    test('rate limited and never late', () {
      final gate = HoverGate();
      expect(arrive(gate, 'a', 0, 1000), isTrue);
      expect(arrive(gate, 'b', 20, 1030), isFalse, reason: 'inside 60 ms');
      expect(arrive(gate, 'c', 40, 1070), isTrue);
      expect(arrive(gate, 'd', 60, 1200, lastCue: 1150), isFalse, reason: 'within 90 ms of another sound');
      expect(arrive(gate, 'e', 80, 1300, lastCue: 1150), isTrue);
    });

    test('quiet with a button held or when not allowed', () {
      final gate = HoverGate();
      expect(arrive(gate, 'a', 0, 1000, buttons: true), isFalse);
      expect(arrive(gate, 'b', 20, 2000, allowed: false), isFalse);
      expect(arrive(gate, 'c', 40, 3000), isTrue);
    });
  });

  group('haptics', () {
    double peak(HapticCue cue) =>
        HapticPatterns.pulses(cue).map((pulse) => pulse.intensity).reduce((a, b) => a > b ? a : b);

    test('the patterns are soft, short and ordered, as on the Mac', () {
      expect(peak(HapticCue.edge), lessThan(peak(HapticCue.back)));
      expect(peak(HapticCue.back), lessThan(peak(HapticCue.select)));
      expect(peak(HapticCue.select), lessThan(peak(HapticCue.error)));
      expect(HapticPatterns.pulses(HapticCue.error), hasLength(2));
      final trophy = HapticPatterns.pulses(HapticCue.trophy).map((pulse) => pulse.intensity).toList();
      expect(trophy, hasLength(3));
      expect(trophy, [...trophy]..sort(), reason: 'the trophy\'s taps swell');
      final ring = HapticPatterns.pulses(HapticCue.ring);
      expect(ring[0].strong, greaterThan(ring[1].strong), reason: 'a heavy beat, then a light one');
      for (final cue in HapticCue.values) {
        final pulses = HapticPatterns.pulses(cue);
        expect(pulses, isNotEmpty);
        expect(pulses.last.end, lessThanOrEqualTo(ms * 400), reason: '$cue is short');
        for (final pulse in pulses) {
          expect(pulse.intensity, inInclusiveRange(0.0, 0.75), reason: '$cue stays soft');
          expect(pulse.length, greaterThan(Duration.zero));
        }
        for (var index = 1; index < pulses.length; index++) {
          expect(pulses[index - 1].end, lessThanOrEqualTo(pulses[index].start), reason: '$cue pulses do not overlap');
        }
      }
      expect(HapticPatterns.pulses(HapticCue.edge).single.length, lessThanOrEqualTo(ms * 15), reason: 'barely there');
    });

    test('plays only for a pad in use with the launcher in front and the setting on', () {
      final output = FakeOutput();
      final haptics = HapticFeedback(output);
      expect(haptics.play(HapticCue.select, now: ms * 1000), isFalse, reason: 'the keyboard was used last');
      haptics.padInUse = true;
      expect(haptics.play(HapticCue.select, now: ms * 2000), isTrue);
      expect(output.played, [HapticPatterns.pulses(HapticCue.select)]);
      haptics.launcherInFront = false;
      expect(output.stops, 1, reason: 'a game came in front: the motors stop at once');
      expect(haptics.play(HapticCue.trophy, now: ms * 3000), isFalse, reason: 'the game owns the pad');
      haptics.launcherInFront = true;
      haptics.enabled = false;
      expect(output.stops, 2);
      expect(haptics.play(HapticCue.ring, now: ms * 4000), isFalse, reason: 'Controller Vibration is off');
      haptics.enabled = true;
      expect(haptics.play(HapticCue.ring, now: ms * 5000), isTrue);
      expect(output.played, hasLength(2));
    });

    test('the same cue twice in one step plays once', () {
      final haptics = HapticFeedback(FakeOutput())..padInUse = true;
      expect(haptics.play(HapticCue.select, now: ms * 1000), isTrue);
      expect(haptics.play(HapticCue.select, now: ms * 1010), isFalse);
      expect(haptics.play(HapticCue.back, now: ms * 1015), isTrue);
      expect(haptics.play(HapticCue.select, now: ms * 1100), isTrue);
    });

    test('the sound cues that vibrate', () {
      expect(HapticCue.forSound('select'), HapticCue.select);
      expect(HapticCue.forSound('back'), HapticCue.back);
      expect(HapticCue.forSound('bump'), HapticCue.edge);
      expect(HapticCue.forSound('move'), isNull);
      expect(HapticCue.forSound('hover'), isNull);
      expect(HapticCue.forSound('unlocked'), isNull, reason: 'a notice\'s chime is not a trophy');
    });

    test('the pulse player sets the motors at each pulse and stops them at its end', () {
      fakeAsync((async) {
        final rumble = FakeRumble();
        final player = PulsePlayer(rumble)..pad = 'xinput0';
        player.play(HapticPatterns.pulses(HapticCue.error));
        async.elapse(ms * 200);
        expect(rumble.calls, [
          'xinput0 0.45 0.35 35',
          'xinput0 0.0 0.0 0',
          'xinput0 0.45 0.35 35',
          'xinput0 0.0 0.0 0',
        ]);
        rumble.calls.clear();
        player.play(HapticPatterns.pulses(HapticCue.trophy));
        async.elapse(ms * 50);
        player.stop();
        async.elapse(ms * 500);
        expect(rumble.calls, [
          'xinput0 0.25 0.3 40',
          'xinput0 0.0 0.0 0',
          'xinput0 0.0 0.0 0',
        ], reason: 'stopped mid-pattern: zero, nothing after');
        rumble.calls.clear();
        player.pad = 'winmm1';
        player.play(HapticPatterns.pulses(HapticCue.select));
        async.elapse(ms * 100);
        expect(rumble.calls, isEmpty, reason: 'a pad without motors stays still');
      });
    });
  });

  group('motors', () {
    test('XInput: the slot from the pad id and the two motor speeds', () {
      expect(XInputRumble.index('xinput2'), 2);
      expect(XInputRumble.index('winmm0'), isNull);
      expect(XInputRumble.index('xinput9'), isNull);
      expect(XInputRumble.speeds(1, 0.5), (65535, 32768));
      expect(XInputRumble.speeds(-1, 2), (0, 65535));
    });

    test('evdev: struct ff_effect for a rumble and the event that plays it', () {
      expect(EvdevRumbler.uploadRequest, 0x40304580);
      final effect = ByteData.sublistView(EvdevRumbler.effect(-1, 0.5, 1, ms * 35));
      expect(effect.lengthInBytes, 48);
      expect(effect.getUint16(0, Endian.little), 0x50, reason: 'FF_RUMBLE');
      expect(effect.getInt16(2, Endian.little), -1, reason: 'a new effect');
      expect(effect.getUint16(10, Endian.little), 35, reason: 'the replay length in ms');
      expect(effect.getUint16(16, Endian.little), 32768);
      expect(effect.getUint16(18, Endian.little), 65535);
      final play = ByteData.sublistView(EvdevRumbler.playEvent(3, play: true));
      expect(play.lengthInBytes, 24);
      expect(
        [play.getUint16(16, Endian.little), play.getUint16(18, Endian.little), play.getInt32(20, Endian.little)],
        [0x15, 3, 1],
      );
      expect(ByteData.sublistView(EvdevRumbler.playEvent(3, play: false)).getInt32(20, Endian.little), 0);
    });
  });
}
