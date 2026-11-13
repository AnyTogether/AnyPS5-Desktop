import 'dart:typed_data';

import 'package:anyps5_desktop/core/gamepad/linux_pads.dart';
import 'package:anyps5_desktop/core/gamepad/pad_navigation.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

void main() {
  group('navigator', () {
    late List<PadCommand> commands;
    late PadNavigator navigator;

    setUp(() {
      commands = [];
      navigator = PadNavigator(commands.add);
    });
    tearDown(() => navigator.dispose());

    PadButtonEvent down(PadButton button, [String pad = 'a']) => PadButtonEvent(pad, button, down: true);
    PadButtonEvent up(PadButton button, [String pad = 'a']) => PadButtonEvent(pad, button, down: false);

    test('the face buttons, shoulders and PS do what the Mac launcher has them do', () {
      for (final button in [
        PadButton.south,
        PadButton.east,
        PadButton.north,
        PadButton.start,
        PadButton.l1,
        PadButton.r1,
        PadButton.guide,
      ]) {
        navigator
          ..handle(down(button))
          ..handle(up(button));
      }
      expect(commands, [
        PadCommand.select,
        PadCommand.back,
        PadCommand.options,
        PadCommand.menu,
        PadCommand.previousGame,
        PadCommand.nextGame,
        PadCommand.home,
      ]);
    });

    test('a button counts once when pressed, not again while held or when let go', () {
      navigator
        ..handle(down(PadButton.south))
        ..handle(down(PadButton.south))
        ..handle(up(PadButton.south))
        ..handle(up(PadButton.south));
      expect(commands, [PadCommand.select]);
    });

    test('resuming a game clears held menu controls before the next PS press', () {
      navigator.dispose();
      navigator = PadNavigator((command) {
        commands.add(command);
        if (command == PadCommand.select) navigator.reset();
      });
      navigator
        ..handle(down(PadButton.dpadDown))
        ..handle(down(PadButton.south))
        ..handle(down(PadButton.guide))
        ..handle(up(PadButton.guide));

      expect(commands, [PadCommand.down, PadCommand.select, PadCommand.home]);
      expect(navigator.held, isNull);
    });

    test('buttons the launcher has no use for do nothing', () {
      for (final button in [PadButton.west, PadButton.l2, PadButton.r2, PadButton.select, PadButton.l3]) {
        navigator.handle(down(button));
      }
      expect(commands, isEmpty);
    });

    test('a held direction moves once, then repeats as a console menu does, until let go', () {
      fakeAsync((async) {
        navigator.handle(down(PadButton.dpadDown));
        expect(commands, [PadCommand.down]);
        async.elapse(const Duration(milliseconds: 399));
        expect(commands, hasLength(1), reason: 'nothing before the first repeat');
        async.elapse(const Duration(milliseconds: 1 + 80 * 2));
        expect(commands, List.filled(4, PadCommand.down));
        navigator.handle(up(PadButton.dpadDown));
        async.elapse(const Duration(seconds: 1));
        expect(commands, hasLength(4));
        expect(navigator.held, isNull);
      });
    });

    test('the left stick engages past half, lets go only below a third (no flutter at rest)', () {
      fakeAsync((async) {
        navigator.handle(const PadAxisEvent('a', PadAxis.leftX, 0.45));
        expect(commands, isEmpty, reason: 'not far enough');
        navigator.handle(const PadAxisEvent('a', PadAxis.leftX, 0.8));
        expect(commands, [PadCommand.right]);
        for (final value in [0.48, 0.35, 0.31, 0.44]) {
          navigator.handle(PadAxisEvent('a', PadAxis.leftX, value));
          expect(navigator.held, PadCommand.right, reason: 'between the two thresholds it still holds');
        }
        expect(commands, [PadCommand.right], reason: 'a resting stick near the line moves nothing more');
        navigator.handle(const PadAxisEvent('a', PadAxis.leftX, 0.29));
        expect(navigator.held, isNull);
        navigator.handle(const PadAxisEvent('a', PadAxis.leftY, -0.9));
        expect(commands.last, PadCommand.up, reason: 'up is negative, as the readers give it');
        navigator.handle(const PadAxisEvent('a', PadAxis.leftY, 0));
      });
    });

    test('the stronger lean of a diagonal wins; the D-pad wins over the stick', () {
      navigator
        ..handle(const PadAxisEvent('a', PadAxis.leftX, -0.6))
        ..handle(const PadAxisEvent('a', PadAxis.leftY, 0.95));
      expect(commands, [PadCommand.left, PadCommand.down]);
      navigator.handle(down(PadButton.dpadRight));
      expect(commands.last, PadCommand.right);
    });

    group('the stick up and down on Home (a player: "too sensitive up and down")', () {
      // As a reader sends a stick sample: X first, then Y (PadSnapshot.diff).
      void stick(double x, double y) => navigator
        ..handle(PadAxisEvent('a', PadAxis.leftX, x))
        ..handle(PadAxisEvent('a', PadAxis.leftY, y));

      test('a push right whose first sample is on the thumb\'s arc moves right only', () {
        // Pushed right with the thumb, the stick sweeps through up-and-right on its way out.
        stick(0.35, -0.55);
        stick(0.75, -0.5);
        stick(0.95, -0.2);
        stick(0, 0);
        expect(commands, [PadCommand.right]);
      });

      test('a small push up or down moves nothing', () {
        stick(0.05, 0.55);
        stick(0, 0);
        stick(-0.1, -0.6);
        stick(0, 0);
        expect(commands, isEmpty);
      });

      test('a stick wobbling near the line moves once at most', () {
        for (final y in [0.52, 0.28, 0.55, 0.25, 0.58, 0.27, 0.5]) {
          stick(0, y);
        }
        stick(0, 0);
        expect(commands, isEmpty, reason: 'it never went far enough down');
        for (final y in [0.7, 0.45, 0.72, 0.42, 0.75]) {
          stick(0, y);
        }
        stick(0, 0);
        expect(commands, [PadCommand.down], reason: 'pushed once, the wobble on top of it is not more');
      });

      test('browsing right, the thumb drifting up does not leave the tiles', () {
        fakeAsync((async) {
          stick(0.9, 0);
          stick(0.65, -0.75);
          stick(0.6, -0.8);
          async.elapse(const Duration(milliseconds: 200));
          stick(0, 0);
          expect(commands, [PadCommand.right]);
        });
      });

      test('a diagonal goes the way of the bigger lean, and sideways when it is even', () {
        stick(0.7, 0.7);
        stick(0, 0);
        stick(0.45, 0.8);
        stick(0, 0);
        expect(commands, [PadCommand.right, PadCommand.down]);
      });

      test('a push up held a little longer than a flick moves once; a long hold repeats', () {
        fakeAsync((async) {
          stick(0, -0.9);
          async.elapse(const Duration(milliseconds: 450));
          expect(commands, [PadCommand.up], reason: 'a short hold is one move (Home: one area)');
          async.elapse(const Duration(milliseconds: 150));
          expect(commands, [PadCommand.up, PadCommand.up], reason: 'held on, it repeats');
          stick(0, 0);
        });
      });

      test('right and left feel as before: half way engages, the first repeat after 0.40 s', () {
        fakeAsync((async) {
          stick(0.52, 0);
          expect(commands, [PadCommand.right]);
          async.elapse(const Duration(milliseconds: 401));
          expect(commands, [PadCommand.right, PadCommand.right]);
          stick(0, 0);
          stick(-0.52, 0.3);
          expect(commands.last, PadCommand.left);
        });
      });

      test('the D-pad keeps its pace up and down', () {
        fakeAsync((async) {
          navigator.handle(down(PadButton.dpadUp));
          async.elapse(const Duration(milliseconds: 401));
          expect(commands, [PadCommand.up, PadCommand.up]);
          navigator.handle(up(PadButton.dpadUp));
        });
      });
    });

    test('several pads at once: one letting go does not stop another holding', () {
      fakeAsync((async) {
        navigator.handle(down(PadButton.dpadUp, 'one'));
        navigator.handle(down(PadButton.south, 'two'));
        navigator.handle(up(PadButton.dpadLeft, 'two'));
        expect(navigator.held, PadCommand.up);
        async.elapse(const Duration(milliseconds: 500));
        expect(commands.where((command) => command == PadCommand.up).length, greaterThan(1));
        expect(commands, contains(PadCommand.select));
      });
    });

    test('a pad that goes away while holding a direction lets go of it', () {
      fakeAsync((async) {
        navigator.handle(down(PadButton.dpadLeft, 'gone'));
        navigator.handle(const PadGone('gone'));
        final count = commands.length;
        async.elapse(const Duration(seconds: 2));
        expect(commands, hasLength(count));
        // Plugged in again it starts fresh: the same button counts again.
        navigator.handle(down(PadButton.dpadLeft, 'gone'));
        expect(commands.last, PadCommand.left);
      });
    });
  });

  group('system maps', () {
    test('snapshots turn into the events between them', () {
      final before = PadSnapshot.idle;
      const after = PadSnapshot({PadButton.south, PadButton.dpadUp}, x: 1);
      final events = PadSnapshot.diff('p', before, after);
      expect(events.whereType<PadButtonEvent>().map((event) => (event.button, event.down)), {
        (PadButton.south, true),
        (PadButton.dpadUp, true),
      });
      expect(events.whereType<PadAxisEvent>().single.value, 1);
      expect(PadSnapshot.diff('p', after, after), isEmpty);
    });

    test('XInput: A B X Y, the shoulders, Guide, the D-pad; its stick has up positive', () {
      final pad = PadMaps.xinput(0x1000 | 0x2000 | 0x8000 | 0x0100 | 0x0400 | 0x0001, 32767, 32767);
      expect(pad.pressed, {
        PadButton.south,
        PadButton.east,
        PadButton.north,
        PadButton.l1,
        PadButton.guide,
        PadButton.dpadUp,
      });
      expect(pad.x, 1);
      expect(pad.y, -1);
      expect(PadMaps.xinput(0x4000 | 0x0010, -32768, -32768).pressed, {PadButton.west, PadButton.start});
    });

    test('a DualSense through winmm: Square, Cross, Circle, Triangle, L1, R1, Create, Options, PS', () {
      expect(PadMaps.sonyWinmm(1 << 1, 0xFFFF, 0, 0).pressed, {PadButton.south});
      expect(PadMaps.sonyWinmm(1 << 2, 0xFFFF, 0, 0).pressed, {PadButton.east});
      expect(PadMaps.sonyWinmm(1 << 3, 0xFFFF, 0, 0).pressed, {PadButton.north});
      expect(PadMaps.sonyWinmm(1 << 0, 0xFFFF, 0, 0).pressed, {PadButton.west});
      expect(PadMaps.sonyWinmm(1 << 4 | 1 << 5, 0xFFFF, 0, 0).pressed, {PadButton.l1, PadButton.r1});
      expect(PadMaps.sonyWinmm(1 << 9, 0xFFFF, 0, 0).pressed, {PadButton.start});
      expect(PadMaps.sonyWinmm(1 << 12, 0xFFFF, 0, 0).pressed, {PadButton.guide});
    });

    test('a POV hat as the D-pad, diagonals holding two, centred holding none', () {
      expect(PadMaps.hat(0), {PadButton.dpadUp});
      expect(PadMaps.hat(9000), {PadButton.dpadRight});
      expect(PadMaps.hat(18000), {PadButton.dpadDown});
      expect(PadMaps.hat(27000), {PadButton.dpadLeft});
      expect(PadMaps.hat(4500), {PadButton.dpadUp, PadButton.dpadRight});
      expect(PadMaps.hat(31500), {PadButton.dpadUp, PadButton.dpadLeft});
      expect(PadMaps.hat(0xFFFF), isEmpty);
    });

    test('axis ranges scale to -1..1', () {
      expect(PadMaps.scale(0, 0, 65535), -1);
      expect(PadMaps.scale(65535, 0, 65535), 1);
      expect(PadMaps.scale(128, 0, 255), closeTo(0, 0.01));
      expect(PadMaps.scale(5, 5, 5), 0);
    });

    test('evdev: the gamepad codes, with an Xbox pad\'s X and Y put back where they sit', () {
      expect(PadMaps.evdevKey(0x130), PadButton.south);
      expect(PadMaps.evdevKey(0x131), PadButton.east);
      expect(PadMaps.evdevKey(0x133), PadButton.north);
      expect(PadMaps.evdevKey(0x133, xbox: true), PadButton.west);
      expect(PadMaps.evdevKey(0x134, xbox: true), PadButton.north);
      expect(PadMaps.evdevKey(0x13c), PadButton.guide);
      expect(PadMaps.evdevKey(0x220), PadButton.dpadUp);
      expect(PadMaps.evdevKey(0x1), isNull);
    });
  });

  group('linux evdev', () {
    Uint8List event(int type, int code, int value) {
      final data = ByteData(24)
        ..setUint16(16, type, Endian.little)
        ..setUint16(18, code, Endian.little)
        ..setInt32(20, value, Endian.little);
      return data.buffer.asUint8List();
    }

    test('events split across reads are put back together', () {
      final decoder = EvdevDecoder('event5', ranges: {0: (0, 255), 1: (0, 255)});
      final bytes = [...event(1, 0x130, 1), ...event(3, 0, 255), ...event(1, 0x130, 0)];
      final events = [
        ...decoder.add(bytes.sublist(0, 30)),
        ...decoder.add(bytes.sublist(30, 50)),
        ...decoder.add(bytes.sublist(50)),
      ];
      expect(events, hasLength(3));
      expect((events[0] as PadButtonEvent).down, isTrue);
      expect((events[1] as PadAxisEvent).value, 1);
      expect((events[2] as PadButtonEvent).down, isFalse);
    });

    test('a key repeating is not a new press; the hat is the D-pad', () {
      final decoder = EvdevDecoder('event5');
      expect(decoder.decode(1, 0x130, 2), isEmpty);
      final left = decoder.decode(3, 0x10, -1);
      expect(left.whereType<PadButtonEvent>().where((event) => event.down).single.button, PadButton.dpadLeft);
      final centred = decoder.decode(3, 0x11, 0);
      expect(centred.whereType<PadButtonEvent>().every((event) => !event.down), isTrue);
    });

    test('without the kernel\'s ranges, a stick seen below zero is signed from then on', () {
      final decoder = EvdevDecoder('event5');
      expect((decoder.decode(3, 0, 255).single as PadAxisEvent).value, 1);
      expect((decoder.decode(3, 0, -32768).single as PadAxisEvent).value, -1);
      expect(
        (decoder.decode(3, 0, 200).single as PadAxisEvent).value,
        0,
        reason: 'near the middle of the signed range',
      );
    });

    test('the controllers are the input devices with a joystick handler', () {
      const devices = '''
I: Bus=0003 Vendor=054c Product=0ce6 Version=8111
N: Name="Sony Interactive Entertainment DualSense Wireless Controller"
H: Handlers=event21 js0

I: Bus=0003 Vendor=054c Product=0ce6 Version=8111
N: Name="Sony Interactive Entertainment DualSense Wireless Controller Motion Sensors"
H: Handlers=event22

I: Bus=0003 Vendor=045e Product=028e Version=0114
N: Name="Microsoft X-Box 360 pad"
H: Handlers=js1 event23

I: Bus=0011 Vendor=0001 Product=0001 Version=ab41
N: Name="AT Translated Set 2 keyboard"
H: Handlers=sysrq kbd event3 leds
''';
      final pads = LinuxPadSource.parseDevices(devices);
      expect(pads.map((pad) => pad.event), ['event21', 'event23']);
      expect(pads.first.xbox, isFalse);
      expect(pads.last.xbox, isTrue);
      expect(pads.first.name, contains('DualSense'));
    });
  });
}
