import 'frame_ring.dart';
import 'retro_host_client.dart';
import 'retro_host_protocol.dart';

/// The frames one emulator host shows: [RetroHostClient.frames] and [RetroHostClient.frame].
abstract interface class RetroFrameSource {
  /// Each `frame` message, after its frame was pinned and checked.
  Stream<RetroFrameEvent> get frames;

  /// The newest frame of the current game, pinned; null before one came.
  PinnedFrame? get frame;
}

/// What the launcher's UI uses of one emulator host connection. [RetroHostClient] is the real one;
/// tests give a fake, so the UI is tested without starting a host.
abstract interface class RetroHostSession implements RetroFrameSource {
  /// Completes once the host greeted the launcher; fails with [RetroHostGone] when it never did.
  Future<void> get ready;

  /// How the connection ended.
  Future<RetroHostEnd> get ended;

  /// Vibration to forward to the controller at a port.
  Stream<RetroRumble> get rumble;

  /// Whether the launcher's window has input focus; losing it zeroes input and motors.
  set inputFocus(bool focused);

  /// `start`: loads a game and gives its epoch.
  Future<int> startGame(Map<String, Object?> args);

  /// Any call but `stop`; `error` replies throw [RetroCallError].
  Future<Object?> call(String method, [Object? args]);

  /// `status`: null with no game loaded.
  Future<RetroStatus?> status();

  /// `stop`, then `status` until the game has ended, which it gives.
  Future<RetroStatus?> stopGame();

  /// The controller state of one port.
  void input(int port, int buttons, {int leftX = 0, int leftY = 0, int rightX = 0, int rightY = 0});

  /// Whether the host lists `ps2`, so a PS2 game can be started on it ([RetroHostStartRequest.console]).
  bool get canPlayPs2;

  /// Whether the host lists `ps2ResolutionLimits`, so a PS2 game's internal resolution is limited
  /// by the host and may be sent to it.
  bool get limitsPs2Resolution;

  /// Asks the host to stop its game and exit.
  void shutdown();

  /// Kills the host if it still runs and frees the connection.
  Future<void> close();
}

/// The `start` call's argument (anyps5-retro-host docs/protocol.md "start").
class RetroHostStartRequest {
  const RetroHostStartRequest({
    required this.core,
    required this.disc,
    required this.system,
    required this.saves,
    this.options = const {},
    this.initialDisc,
    this.console,
  });

  /// The SwanStation library the launcher checked, or for a PS2 game the LRPS2 library.
  final String core;

  /// A `.cue`, `.chd`, `.pbp` or `.m3u` file; for a PS2 game a `.iso`, `.chd`, `.cso`, `.zso`,
  /// `.cue` or `.elf` file.
  final String disc;

  /// The core's system directory (BIOS files).
  final String system;

  /// Where memory cards are kept.
  final String saves;

  /// Core option values saved by the player, by key.
  final Map<String, String> options;

  /// Only for an `.m3u`: the playlist entry to insert at boot, 0 to 127.
  final int? initialDisc;

  /// [RetroConsole.ps2] for a PS2 game, which only a host that lists `ps2` takes; null for a PS1
  /// game, the host's default, so a PS1 start is the same on every host.
  final String? console;

  /// This request without the option at [key], for a host that must not be sent it.
  RetroHostStartRequest withoutOption(String key) => RetroHostStartRequest(
    core: core,
    disc: disc,
    system: system,
    saves: saves,
    options: {...options}..remove(key),
    initialDisc: initialDisc,
    console: console,
  );

  Map<String, Object?> toArgs() => {
    'console': ?console,
    'core': core,
    'disc': disc,
    'system': system,
    'saves': saves,
    if (options.isNotEmpty) 'options': options,
    'initialDisc': ?initialDisc,
  };
}
