import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/retro_host/retro_host_client.dart';
import '../../core/retro_host/retro_host_protocol.dart';
import '../../core/retro_host/retro_host_session.dart';
import 'retro_frame_image.dart';

/// Where one game in an emulator host stands.
enum RetroHostGamePhase {
  /// No game was started yet.
  idle,

  /// Waiting for the host to greet the launcher and accept `start`.
  starting,

  /// The game is loading; no frame was published yet.
  loading,

  /// The game is running and its frames are shown.
  playing,

  /// The game ended: stopped, failed, or `start` was refused. [RetroHostGame.endStatus] or
  /// [RetroHostGame.failure] says why.
  ended,

  /// The host was shut down; nothing more can be done with it.
  closed,
}

/// One game in one emulator host: starting it, forwarding input, pausing while the launcher has no
/// input focus, following its `status`, stopping it, and shutting the host down. It owns its
/// [session] and the [picture] of its frames.
class RetroHostGame extends ChangeNotifier {
  RetroHostGame(
    this.session, {
    this.statusEvery = const Duration(milliseconds: 500),
    double volume = 1,
    bool muted = false,
  }) : picture = RetroFrameImage(session.frames)..accepting = false,
       _level = volume,
       _isMuted = muted {
    session.ready.ignore();
    unawaited(
      session.ended.then((end) {
        _hostEnded = true;
        _hostEnd = end;
        _onHostEnded();
        _notify();
      }),
    );
  }

  /// Starts a real host from [command] and takes it over. [environment] is added to the
  /// launcher's, or with [inheritEnvironment] false is the host's whole environment
  /// ([RetroHostClient.start]).
  factory RetroHostGame.launch({
    required List<String> command,
    Map<String, String>? environment,
    bool inheritEnvironment = true,
    double volume = 1,
    bool muted = false,
  }) => RetroHostGame(
    RetroHostClient.start(
      command: command,
      environment: environment,
      inheritEnvironment: inheritEnvironment,
      volume: volume,
      muted: muted,
    ),
    volume: volume,
    muted: muted,
  );

  final RetroHostSession session;

  /// How often `status` is asked while a game is loaded.
  final Duration statusEvery;

  /// The picture of the newest frame of this game.
  final RetroFrameImage picture;

  RetroHostGamePhase get phase => _phase;
  RetroHostGamePhase _phase = RetroHostGamePhase.idle;

  /// The display aspect ratio the core reports.
  double get aspect => _aspect;
  double _aspect = 4 / 3;

  /// Whether the game is paused, by the player or by losing input focus.
  bool get paused => _pausedByPlayer || _pausedByFocus;
  bool _pausedByPlayer = false;
  bool _pausedByFocus = false;

  /// Whether the launcher's window has input focus.
  bool get focused => _focused;
  bool _focused = true;

  /// The last `status` of the game, which after it ended says why.
  RetroStatus? get status => _status;
  RetroStatus? _status;

  /// The status the game ended with, once [phase] is [RetroHostGamePhase.ended].
  RetroStatus? get endStatus => _phase == RetroHostGamePhase.ended ? _status : null;

  /// The host's output volume, 0 to 1, as the player set it.
  double get volume => _level;
  double _level;

  /// Whether the host's output is muted.
  bool get muted => _isMuted;
  bool _isMuted;

  /// The core's vibration for each controller port (protocol.md "rumble"). The client gives
  /// nothing while the game is paused or the window has no focus, and gives zeros for both ports
  /// when the game starts, pauses, ends or loses focus.
  Stream<RetroRumble> get rumble => session.rumble;

  /// Whether a game is loaded: [phase] is [RetroHostGamePhase.loading] or
  /// [RetroHostGamePhase.playing].
  bool get loaded => _gameLive;

  /// Whether [input] reaches the host now: a game is loaded and the window has input focus.
  bool get acceptsInput => _gameLive && _focused;

  /// Why the game could not be started or followed, for logs, when no status says it.
  String? get failure => _failure;
  String? _failure;

  /// How the host's connection ended; null while it is open. [RetroHostEnd.unsupported] means
  /// the host speaks no protocol version this launcher does: the emulator needs updating.
  RetroHostEnd? get hostEnd => _hostEnd;
  RetroHostEnd? _hostEnd;

  Timer? _poll;
  bool _polling = false;
  bool _disposed = false;
  bool _hostEnded = false;
  bool _detached = false;
  Future<void>? _closing;
  Future<bool>? _detaching;
  Future<void>? _starting;

  bool get _gameLive => _phase == RetroHostGamePhase.loading || _phase == RetroHostGamePhase.playing;

  /// Waits for the host's greeting, then starts the game. Throws [StateError] when a game was
  /// already started on this host.
  Future<void> start(RetroHostStartRequest request) {
    if (_phase != RetroHostGamePhase.idle) throw StateError('A game was already started on this host.');
    _setPhase(RetroHostGamePhase.starting);
    return _starting = _startNow(request);
  }

  Future<void> _startNow(RetroHostStartRequest request) async {
    try {
      await session.ready;
      if (_phase != RetroHostGamePhase.starting) return;
      await session.startGame(request.toArgs());
    } on Object catch (error) {
      if (_phase == RetroHostGamePhase.starting) _end(failure: '$error');
      return;
    }
    if (_phase == RetroHostGamePhase.ended) {
      await _stopAndRelease();
      return;
    }
    if (_phase != RetroHostGamePhase.starting) return;
    picture.clear();
    picture.accepting = true;
    _setPhase(RetroHostGamePhase.loading);
    if (!_focused) await _pauseForFocus();
    if (!_gameLive) return;
    _poll = Timer.periodic(statusEvery, (_) => unawaited(refresh()));
    await refresh();
  }

  /// Asks `status` once and follows it: the aspect ratio, the first frame, and the game's end.
  Future<void> refresh() async {
    if (!_gameLive || _polling) return;
    _polling = true;
    try {
      final current = await session.status();
      if (!_gameLive) return;
      if (current == null) {
        _end(failure: 'The host has no game loaded.');
        return;
      }
      _status = current;
      _aspect = current.aspect;
      if (current.ended) {
        _end();
        return;
      }
      if (current.ready && _phase == RetroHostGamePhase.loading) {
        _setPhase(RetroHostGamePhase.playing);
      } else {
        _notify();
      }
    } on Object catch (error) {
      if (_gameLive) _end(failure: '$error');
    } finally {
      _polling = false;
    }
  }

  /// The controller state of one port, forwarded while a game is loaded and the launcher has input
  /// focus; the host keeps it until the next state.
  void input(int port, int buttons, {int leftX = 0, int leftY = 0, int rightX = 0, int rightY = 0}) {
    if (!_gameLive || !_focused) return;
    session.input(port, buttons, leftX: leftX, leftY: leftY, rightX: rightX, rightY: rightY);
  }

  /// `connectedPorts`: how many controller ports, from port 1, have a controller in (1 or 2).
  /// False when no game is loaded, the host did not take it, or the call failed; a host failure
  /// is then seen by the next status.
  Future<bool> connectedPorts(int count) {
    if (count < 1 || count > 2) throw RangeError.range(count, 1, 2, 'count');
    return _gameCall('connectedPorts', count);
  }

  /// `changeDisc`: inserts the disc at [index] of `status.discs.labels`. True when the change
  /// started; the next status shows its progress, and it is asked at once.
  Future<bool> changeDisc(int index) async {
    if (index < 0 || index > 127) throw RangeError.range(index, 0, 127, 'index');
    final started = await _gameCall('changeDisc', index);
    if (started) await refresh();
    return started;
  }

  /// `option`: sets a core option the status lists to one of its values. True when the host
  /// took it; the status is asked at once, so the option shows its new choice.
  Future<bool> setOption(String key, String value) async {
    final taken = await _gameCall('option', {'key': key, 'value': value});
    if (taken) await refresh();
    return taken;
  }

  /// `volume`: the host's output volume for this and every later game. Sent once the host has
  /// greeted the launcher; only kept when the host has ended or never greeted it.
  Future<void> setVolume({double? level, bool? muted}) async {
    if (level != null && (level.isNaN || level < 0 || level > 1)) throw RangeError.value(level, 'level');
    _level = level ?? _level;
    _isMuted = muted ?? _isMuted;
    _notify();
    try {
      await session.ready;
      if (_hostEnded || _phase == RetroHostGamePhase.closed) return;
      await session.call('volume', {'level': _level, 'muted': _isMuted});
    } on Object {
      return;
    }
  }

  Future<bool> _gameCall(String method, Object? args) async {
    if (!_gameLive) return false;
    try {
      return await session.call(method, args) == true;
    } on Object {
      return false;
    }
  }

  /// Pauses or resumes the game for the player. A game paused by losing focus stays paused until
  /// focus comes back.
  Future<void> pause(bool pause) async {
    if (!_gameLive || _pausedByPlayer == pause) return;
    final wasPaused = paused;
    _pausedByPlayer = pause;
    await _sendPause(wasPaused);
  }

  /// Tells the game whether the launcher's window has input focus. Losing it zeroes the controllers'
  /// input and motors, and pauses the game until focus comes back.
  Future<void> setFocused(bool focused) async {
    if (_focused == focused) return;
    _focused = focused;
    if (!_hostEnded && _phase != RetroHostGamePhase.closed) session.inputFocus = focused;
    if (!_gameLive) {
      _notify();
      return;
    }
    if (focused) {
      final wasPaused = paused;
      _pausedByFocus = false;
      await _sendPause(wasPaused);
    } else {
      await _pauseForFocus();
    }
  }

  Future<void> _pauseForFocus() async {
    final wasPaused = paused;
    _pausedByFocus = true;
    await _sendPause(wasPaused);
  }

  Future<void> _sendPause(bool wasPaused) async {
    final now = paused;
    _notify();
    if (now == wasPaused) return;
    try {
      await session.call('pause', now);
    } on Object catch (error) {
      if (_gameLive) _end(failure: '$error');
    }
  }

  /// Stops the game and forgets it in the host, giving the status it ended with. A game still
  /// starting is cancelled: if the host already accepted `start`, that game is stopped as soon as
  /// the reply comes.
  Future<RetroStatus?> stop() async {
    if (_phase == RetroHostGamePhase.starting) {
      _end(failure: 'Stopped before the game started.');
      await _starting;
      return null;
    }
    if (!_gameLive) return endStatus;
    _poll?.cancel();
    picture.accepting = false;
    final ended = await _stopAndRelease();
    if (_phase == RetroHostGamePhase.closed) return ended;
    if (ended != null) _status = ended;
    _end();
    return ended;
  }

  Future<RetroStatus?> _stopAndRelease() async {
    try {
      final ended = await session.stopGame();
      await session.call('release');
      return ended;
    } on Object catch (error) {
      _failure = '$error';
      return null;
    }
  }

  /// Lets go of the host without shutting it down, so a next game can start on it: protocol.md
  /// "Processes" says "One host runs games one after another until the launcher exits or the host
  /// fails." The game is stopped if it still runs, and an ended game is forgotten with `release`,
  /// since `start` is `busy` "if a game is loaded, running or ended". True when the host still runs
  /// and `status` then says no game is loaded; the caller may then start the next game on
  /// [session] and must shut it down itself. False when the host ended, was shut down, or still
  /// holds a game: the host is shut down as usual. The window's focus is given back to the host as
  /// a new host starts with it, since the next game tells it its own. Every caller waits for the
  /// same answer.
  Future<bool> detach() => _detaching ??= _detachNow();

  Future<bool> _detachNow() async {
    if (_closing != null) return false;
    await stop();
    _poll?.cancel();
    picture.accepting = false;
    picture.clear();
    var free = false;
    if (!_hostEnded && _closing == null) {
      try {
        await session.call('release');
        free = await session.status() == null && !_hostEnded && _closing == null;
      } on Object catch (error) {
        _failure ??= '$error';
      }
    }
    if (!free) {
      await shutdown();
      return false;
    }
    _detached = true;
    if (!_focused) session.inputFocus = true;
    _setPhase(RetroHostGamePhase.closed);
    return true;
  }

  /// Asks the host to exit and frees the connection once it has; the client kills a host that has
  /// not exited within its time limit. Every caller waits for the same shutdown. A host this game
  /// was [detach]ed from is no longer its own: nothing is done.
  Future<void> shutdown() => _closing ??= _detached ? Future.value() : _shutdownNow();

  Future<void> _shutdownNow() async {
    _poll?.cancel();
    _setPhase(RetroHostGamePhase.closed);
    picture.accepting = false;
    picture.clear();
    session.shutdown();
    await session.ended;
    await session.close();
  }

  void _onHostEnded() {
    if (_phase == RetroHostGamePhase.closed || _disposed) return;
    if (_gameLive) {
      unawaited(refresh());
    } else if (_phase == RetroHostGamePhase.starting) {
      _end(failure: 'The host ended before the game started.');
    }
  }

  void _end({String? failure}) {
    _poll?.cancel();
    if (failure != null) _failure = failure;
    _pausedByFocus = false;
    _pausedByPlayer = false;
    picture.accepting = false;
    picture.clear();
    _setPhase(RetroHostGamePhase.ended);
  }

  void _setPhase(RetroHostGamePhase phase) {
    _phase = phase;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Shuts the host down if nothing did yet, unless it was [detach]ed for the next game, and frees
  /// the picture.
  @override
  void dispose() {
    _disposed = true;
    if (_detaching == null) unawaited(shutdown());
    picture.dispose();
    super.dispose();
  }
}
