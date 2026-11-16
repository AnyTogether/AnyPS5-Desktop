import 'package:anyps5_desktop/core/controllers/pad_info.dart';
import 'package:anyps5_desktop/core/gamepad/pad_navigation.dart';
import 'package:anyps5_desktop/core/retro_host/retro_pad.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_session.dart';
import 'package:anyps5_desktop/ui/retro_host/retro_host_controls.dart';
import 'package:anyps5_desktop/ui/retro_host/retro_host_game.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_retro_host_session.dart';

const _request = RetroHostStartRequest(core: 'c', disc: 'd.cue', system: 's', saves: 'v');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeRetroHostSession session;
  late RetroHostGame game;
  late FakePads pads;
  late FakeMotors motors;
  late RetroHostControls controls;

  setUp(() {
    session = FakeRetroHostSession();
    game = RetroHostGame(session, statusEvery: const Duration(hours: 1));
    pads = FakePads();
    motors = FakeMotors();
    controls = RetroHostControls(
      game,
      pads: pads.reader,
      motors: motors,
      every: const Duration(hours: 1),
      rumbleHold: const Duration(hours: 2),
    );
  });

  tearDown(() {
    controls.dispose();
    game.dispose();
  });

  Future<void> started() async {
    session.readyCompleter.complete();
    session.nextStatus = fakeStatus();
    session.callResults['connectedPorts'] = true;
    await game.start(_request);
  }

  test('nothing is sent before a game is loaded', () {
    pads.connect('a', const PadState(pressed: {PadButton.south}));
    controls.poll();
    expect(session.inputStates, isEmpty);
    expect(session.calls, isEmpty);
  });

  test('a seated controller\'s state is sent for its port once, then on each change', () async {
    await started();
    pads.connect('a', const PadState(pressed: {PadButton.south}, leftY: -1));
    controls.poll();
    controls.poll();
    pads.states['a'] = const PadState(pressed: {PadButton.start});
    controls.poll();
    expect(session.inputStates, [
      (0, RetroPadInput(buttons: RetroPadButton.cross.mask, leftY: -32768)),
      (1, RetroPadInput.idle),
      (0, RetroPadInput(buttons: RetroPadButton.start.mask)),
    ]);
  });

  test('the keyboard plays at port 1, with or without a controller there, and is kept out by the menu', () async {
    var keys = PadState.idle;
    controls.dispose();
    controls = RetroHostControls(
      game,
      pads: pads.reader,
      motors: motors,
      keyboard: () => keys,
      every: const Duration(hours: 1),
      rumbleHold: const Duration(hours: 2),
    );
    await started();
    keys = const PadState(pressed: {PadButton.south}, leftX: 1);
    controls.poll();
    pads.connect('a', const PadState(pressed: {PadButton.east}, leftY: 1));
    pads.connect('b', const PadState(pressed: {PadButton.west}));
    controls.poll();
    controls.suspended = true;
    controls.suspended = false;
    keys = PadState.idle;
    controls.poll();
    expect(session.inputStates, [
      (0, RetroPadInput(buttons: RetroPadButton.cross.mask, leftX: 32767)),
      (1, RetroPadInput.idle),
      (0, RetroPadInput(buttons: RetroPadButton.cross.mask | RetroPadButton.circle.mask, leftX: 32767)),
      (1, RetroPadInput(buttons: RetroPadButton.square.mask)),
      (0, RetroPadInput.idle),
      (1, RetroPadInput.idle),
      (0, const RetroPadInput(leftX: 32767)),
      (0, const RetroPadInput(leftY: 32767)),
    ], reason: 'keys held when the menu closes stay out until let go; the sticks come back at once');
  });

  test('a second controller connects port 2, and port 2 is let go when it leaves', () async {
    await started();
    pads.connect('a');
    controls.poll();
    pads.connect('b', const PadState(pressed: {PadButton.east}));
    controls.poll();
    expect(session.calls, [('connectedPorts', 2)]);
    expect(session.inputStates.last, (1, RetroPadInput(buttons: RetroPadButton.circle.mask)));
    pads.disconnect('b');
    controls.poll();
    expect(session.calls, [('connectedPorts', 2), ('connectedPorts', 1)]);
    expect(session.inputStates.last, (1, RetroPadInput.idle));
  });

  test('a game started with two controllers connects port 2 as soon as it loads', () async {
    pads
      ..connect('a')
      ..connect('b');
    controls.poll();
    expect(session.calls, isEmpty);
    await started();
    controls.poll();
    expect(session.calls, [('connectedPorts', 2)]);
  });

  test('after focus comes back every port is sent again', () async {
    await started();
    pads.connect('a', const PadState(pressed: {PadButton.north}));
    controls.poll();
    await game.setFocused(false);
    controls.poll();
    expect(session.inputStates, hasLength(2));
    await game.setFocused(true);
    controls.poll();
    expect(session.inputStates.skip(2), [
      (0, RetroPadInput(buttons: RetroPadButton.triangle.mask)),
      (1, RetroPadInput.idle),
    ]);
  });

  test('focus lost and back between two reads still sends the held state again', () async {
    await started();
    pads.connect('a', const PadState(pressed: {PadButton.south}));
    controls.poll();
    await game.setFocused(false);
    await game.setFocused(true);
    controls.poll();
    expect(session.inputStates.skip(2), [
      (0, RetroPadInput(buttons: RetroPadButton.cross.mask)),
      (1, RetroPadInput.idle),
    ]);
  });

  test('a button held when the suspension ends reaches the game only once pressed again', () async {
    await started();
    pads.connect('a');
    controls.poll();
    controls.suspended = true;
    pads.states['a'] = const PadState(pressed: {PadButton.south}, leftX: 1);
    controls.suspended = false;
    expect(session.inputStates.last, (0, const RetroPadInput(leftX: 32767)));
    pads.states['a'] = const PadState(pressed: {PadButton.south, PadButton.east});
    controls.poll();
    expect(session.inputStates.last, (0, RetroPadInput(buttons: RetroPadButton.circle.mask)));
    pads.states['a'] = PadState.idle;
    controls.poll();
    pads.states['a'] = const PadState(pressed: {PadButton.south});
    controls.poll();
    expect(session.inputStates.last, (0, RetroPadInput(buttons: RetroPadButton.cross.mask)));
  });

  test('while suspended both ports are idle; after it the sticks come back at once', () async {
    await started();
    pads.connect('a', const PadState(pressed: {PadButton.l1}, leftY: -1));
    controls.poll();
    controls.suspended = true;
    expect(session.inputStates.last, (0, RetroPadInput.idle));
    controls.suspended = false;
    expect(session.inputStates.last, (0, const RetroPadInput(leftY: -32768)));
  });

  test('rumble goes to the controller at its port when it can vibrate', () async {
    await started();
    pads
      ..connect('a')
      ..connect('b');
    motors.vibrating.add('b');
    controls.poll();
    session.sendRumble(0, 0xFFFF, 0);
    session.sendRumble(1, 0xFFFF, 0x8000);
    session.sendRumble(1, 0, 0);
    expect(motors.orders, [('b', 1.0, 0x8000 / 0xFFFF, const Duration(hours: 2)), ('b', 0.0, 0.0, Duration.zero)]);
  });

  test('a controller that leaves its port has its motors stopped', () async {
    await started();
    pads
      ..connect('a')
      ..connect('b');
    motors.vibrating.addAll(['a', 'b']);
    controls.poll();
    session.sendRumble(1, 0, 0xFFFF);
    motors.orders.clear();
    pads.disconnect('b');
    pads.connect('c');
    motors.vibrating.add('c');
    controls.poll();
    expect(motors.orders, [('b', 0.0, 0.0, Duration.zero)]);
    expect(controls.seats.at(1), 'c');
  });

  test('turning vibration off stops the motors and keeps later rumble away', () async {
    await started();
    pads.connect('a');
    motors.vibrating.add('a');
    controls.poll();
    session.sendRumble(0, 0xFFFF, 0);
    controls.vibration = false;
    session.sendRumble(0, 0x4000, 0);
    expect(motors.orders, [('a', 1.0, 0.0, const Duration(hours: 2)), ('a', 0.0, 0.0, Duration.zero)]);
  });

  test('a controller that sat down holding a button just before the suspension ends is kept out too', () async {
    await started();
    pads.connect('a');
    controls.poll();
    controls.suspended = true;
    pads.disconnect('a');
    pads.connect('b', const PadState(pressed: {PadButton.south}));
    controls.suspended = false;
    expect(controls.seats.at(0), 'b');
    expect(session.inputStates.where((sent) => sent.$1 == 0).last.$2, RetroPadInput.idle);
  });

  test('a held button let go and pressed again while the window has no focus reaches the game', () async {
    await started();
    pads.connect('a');
    controls.poll();
    controls.suspended = true;
    pads.states['a'] = const PadState(pressed: {PadButton.south});
    controls.suspended = false;
    await game.setFocused(false);
    pads.states['a'] = PadState.idle;
    controls.poll();
    pads.states['a'] = const PadState(pressed: {PadButton.south});
    controls.poll();
    await game.setFocused(true);
    controls.poll();
    expect(
      session.inputStates.where((sent) => sent.$1 == 0).last.$2,
      RetroPadInput(buttons: RetroPadButton.cross.mask),
    );
  });

  test('shutting the host down stops a motor the game left running', () async {
    await started();
    pads.connect('a');
    motors.vibrating.add('a');
    controls.poll();
    session.sendRumble(0, 0xFFFF, 0);
    final shutting = game.shutdown();
    expect(motors.orders.last, ('a', 0.0, 0.0, Duration.zero));
    session.sendRumble(0, 0xFFFF, 0);
    await shutting;
    expect(motors.orders.last, ('a', 0.0, 0.0, Duration.zero));
  });

  test('dispose lets go of what the controllers held in a game that goes on', () async {
    await started();
    pads.connect('a', const PadState(pressed: {PadButton.south}, leftX: 1));
    controls.poll();
    controls.dispose();
    expect(session.inputStates.where((sent) => sent.$1 == 0).last.$2, RetroPadInput.idle);
  });

  test('rumble that comes as one controller takes the port of another goes to the new one', () async {
    await started();
    pads
      ..connect('a')
      ..connect('b')
      ..connect('c');
    motors.vibrating.addAll(['a', 'b', 'c']);
    controls.poll();
    pads.disconnect('a');
    session.sendRumble(0, 0xFFFF, 0);
    expect(controls.seats.at(0), 'c');
    expect(motors.orders, [('c', 1.0, 0.0, const Duration(hours: 2))]);
  });

  test('controls made for a game already loaded tell the host how many ports are connected', () async {
    await started();
    pads
      ..connect('a')
      ..connect('b');
    controls.poll();
    controls.dispose();
    pads.disconnect('b');
    final again = RetroHostControls(game, pads: pads.reader, every: const Duration(hours: 1));
    addTearDown(again.dispose);
    again.poll();
    expect(session.calls, [('connectedPorts', 2), ('connectedPorts', 1)]);
  });

  test('dispose stops a motor the game left running', () async {
    await started();
    pads.connect('a');
    motors.vibrating.add('a');
    controls.poll();
    session.sendRumble(0, 0xFFFF, 0);
    controls.dispose();
    expect(motors.orders.last, ('a', 0.0, 0.0, Duration.zero));
    session.sendRumble(0, 0xFFFF, 0);
    expect(motors.orders, hasLength(2));
  });
}
