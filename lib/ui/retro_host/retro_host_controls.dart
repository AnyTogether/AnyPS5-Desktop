import 'dart:async';

import '../../core/controllers/pad_info.dart';
import '../../core/controllers/pad_inventory.dart';
import '../../core/gamepad/feel.dart';
import '../../core/retro_host/retro_host_client.dart';
import '../../core/retro_host/retro_keyboard.dart';
import '../../core/retro_host/retro_pad.dart';
import '../../core/retro_host/retro_seats.dart';
import 'retro_host_game.dart';

/// The launcher's controllers as a game reads them: which are connected, in the launcher's order
/// (Player 1 first), and each one's whole state.
class RetroPadReader {
  const RetroPadReader({required this.pads, required this.state});

  /// The reader's own pads, in the reader's order.
  factory RetroPadReader.inventory(PadInventory inventory) =>
      RetroPadReader(pads: () => [for (final pad in inventory.pads) pad.id], state: inventory.state);

  /// The ids of the controllers connected now.
  final List<String> Function() pads;

  /// Everything a controller holds now; null for one the reader does not know.
  final PadState? Function(String id) state;
}

/// Plays a [RetroHostGame] with the launcher's controllers: their state becomes `input` for the
/// port each one sits at ([RetroSeats]), port 2 is connected while a second controller is there
/// (`connectedPorts`), and the core's vibration goes to the controller at its port.
///
/// The controllers are read every [every], as the launcher's reader polls them. A port's state is
/// sent when it changes, and again in full whenever the game starts taking input (a game that
/// loaded, focus that came back), because the client zeroes both ports when it starts a game or
/// loses focus. While [suspended] (an in-game menu is open) both ports are sent as idle, and a
/// button still held when it ends reaches the game only once it is let go and pressed again.
class RetroHostControls {
  RetroHostControls(
    this.game, {
    required this.pads,
    this.motors,
    this.keyboard,
    this.every = const Duration(milliseconds: 16),
    this.rumbleHold = const Duration(seconds: 2),
  }) {
    _portsSent = game.loaded ? null : 1;
    _rumble = game.rumble.listen(_onRumble);
    game.addListener(_onGameChanged);
    _poll = Timer.periodic(every, (_) => poll());
    _rumbleRefresh = Timer.periodic(rumbleHold ~/ 2, (_) => _refreshRumble());
  }

  final RetroHostGame game;
  final RetroPadReader pads;

  /// The controllers' motors; null where the reader cannot turn them.
  final PadRumble? motors;

  /// The keyboard's state now, joined to the controller at port 1 ([RetroKeyboard.merge]); null
  /// when the keyboard does not play.
  final PadState Function()? keyboard;

  final Duration every;

  /// How long one rumble order lasts. The protocol's `rumble` holds until the next one, but the
  /// launcher's readers stop the motors after the length they are given (SDL, evdev), so a level
  /// that is not zero is given again every half of this.
  final Duration rumbleHold;

  /// Settings › Controllers › Stick Dead Zone, in percent.
  int deadzonePercent = 0;

  /// Whether the core's vibration reaches the controllers.
  bool get vibration => _vibration;
  bool _vibration = true;
  set vibration(bool on) {
    if (_vibration == on) return;
    _vibration = on;
    if (!on) _stopMotors();
  }

  final RetroSeats seats = RetroSeats();

  late final StreamSubscription<RetroRumble> _rumble;
  late final Timer _poll;
  late final Timer _rumbleRefresh;
  final List<RetroPadInput?> _sent = List.filled(RetroSeats.portCount, null);
  final List<int> _swallowed = List.filled(RetroSeats.portCount, 0);
  final List<(int, int)> _levels = List.filled(RetroSeats.portCount, (0, 0));

  /// The `connectedPorts` the host has: 1 for a game that has not loaded yet ("A game starts
  /// with 1"), unknown (null) for one that was loaded before these controls, so it is sent.
  int? _portsSent;
  bool _suspended = false;
  bool _disposed = false;

  /// Whether the controllers' presses are kept from the game (an in-game menu is open): both
  /// ports are sent as idle until it is false again. The buttons held when it becomes false (the
  /// press that closed the menu) stay out of the game until they are let go.
  bool get suspended => _suspended;
  set suspended(bool value) {
    if (_suspended == value) return;
    _suspended = value;
    if (!value && !_disposed) {
      _syncSeats();
      for (var port = 0; port < RetroSeats.portCount; port++) {
        _swallowed[port] = _read(port)?.buttons ?? 0;
      }
    }
    poll();
  }

  /// The game stopped taking input: the client zeroed both ports (a game that started, focus that
  /// was lost), so what was sent is forgotten and sent again once it takes input. Told at each
  /// change, so focus lost and back between two reads is not missed. Once no game is loaded (it
  /// ended, or the host was shut down, which sends no `rumble`), the motors stop too.
  void _onGameChanged() {
    if (game.acceptsInput) return;
    _sent.fillRange(0, _sent.length, null);
    if (game.loaded) return;
    _portsSent = 1;
    _stopMotors();
    _levels.fillRange(0, _levels.length, (0, 0));
  }

  /// What the controller at [port] holds now, with the keyboard at port 1, or null for a port
  /// without either.
  RetroPadInput? _read(int port) {
    final pad = seats.at(port);
    final padState = pad == null ? null : pads.state(pad);
    final keys = port == 0 ? keyboard?.call() : null;
    final state = keys == null ? padState : RetroKeyboard.merge(padState, keys);
    return state == null ? null : RetroPadInput.fromPad(state, deadzonePercent: deadzonePercent);
  }

  /// Reads the controllers and sends what changed (tests drive this; the timer calls it).
  void poll() {
    if (_disposed) return;
    _syncSeats();
    final held = [for (var port = 0; port < RetroSeats.portCount; port++) _suspended ? null : _read(port)];
    for (var port = 0; port < RetroSeats.portCount; port++) {
      _swallowed[port] &= held[port]?.buttons ?? 0;
    }
    if (!game.acceptsInput) {
      _onGameChanged();
      return;
    }
    final count = seats.connectedPorts;
    if (count != _portsSent) {
      _portsSent = count;
      unawaited(game.connectedPorts(count));
    }
    for (var port = 0; port < RetroSeats.portCount; port++) {
      final now = held[port];
      final input = now == null ? RetroPadInput.idle : now.withButtons(now.buttons & ~_swallowed[port]);
      if (input == _sent[port]) continue;
      _sent[port] = input;
      game.input(
        port,
        input.buttons,
        leftX: input.leftX,
        leftY: input.leftY,
        rightX: input.rightX,
        rightY: input.rightY,
      );
    }
  }

  /// Seats the controllers connected now, and lets go of what a leaving one had.
  void _syncSeats() {
    for (final change in seats.sync(pads.pads())) {
      if (!change.joined) _left(change);
    }
  }

  /// A controller left [change.port]: its motors stop (protocol.md "rumble": "when a controller
  /// leaves its port"), and the port is sent as idle by the next state that is sent.
  void _left(RetroSeatChange change) {
    _swallowed[change.port] = 0;
    if (_levels[change.port] != (0, 0)) {
      _levels[change.port] = (0, 0);
      _setMotors(change.pad, 0, 0);
    }
  }

  /// The core's vibration for a port, kept and given to the controller there. Nothing once no
  /// game is loaded: a `rumble` still coming while the host shuts down must not start the motors
  /// that stopped with the game.
  void _onRumble(RetroRumble event) {
    if (_disposed || !game.loaded) return;
    _syncSeats();
    _levels[event.port] = (event.strong, event.weak);
    final pad = seats.at(event.port);
    if (pad != null) _setMotors(pad, event.strong, event.weak);
  }

  void _refreshRumble() {
    for (var port = 0; port < RetroSeats.portCount; port++) {
      final (strong, weak) = _levels[port];
      final pad = seats.at(port);
      if (pad != null && (strong != 0 || weak != 0)) _setMotors(pad, strong, weak);
    }
  }

  void _setMotors(String pad, int strong, int weak) {
    final rumble = motors;
    final on = strong != 0 || weak != 0;
    if (rumble == null || (on && !_vibration) || !rumble.canRumble(pad)) return;
    rumble.rumble(pad, strong / 0xFFFF, weak / 0xFFFF, on ? rumbleHold : Duration.zero);
  }

  void _stopMotors() {
    final rumble = motors;
    if (rumble == null) return;
    for (var port = 0; port < RetroSeats.portCount; port++) {
      final pad = seats.at(port);
      if (pad != null && _levels[port] != (0, 0) && rumble.canRumble(pad)) rumble.rumble(pad, 0, 0, Duration.zero);
    }
  }

  /// Stops reading the controllers, lets go of what they held in a game that goes on, and stops
  /// any motor the game left running.
  void dispose() {
    if (_disposed) return;
    for (var port = 0; port < RetroSeats.portCount; port++) {
      final sent = _sent[port];
      if (sent != null && sent != RetroPadInput.idle) game.input(port, 0);
    }
    _poll.cancel();
    _rumbleRefresh.cancel();
    game.removeListener(_onGameChanged);
    unawaited(_rumble.cancel());
    _stopMotors();
    _disposed = true;
  }
}
