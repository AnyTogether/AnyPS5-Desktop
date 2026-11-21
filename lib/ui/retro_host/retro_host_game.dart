import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/retro_host/retro_host_client.dart';
import '../../core/retro_host/retro_host_protocol.dart';
import '../../core/retro_host/retro_host_session.dart';
import '../../core/retro_host/retro_resolution.dart';
import '../../core/retro_host/retro_state_slots.dart';
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

  /// The game was a PS2 one and its host does not list `ps2`, so it was never started: that host
  /// plays PS1 games only and needs updating for PS2.
  bool get consoleRefused => _consoleRefused;
  bool _consoleRefused = false;

  /// Whether the host limits a PS2 game's internal resolution (`ps2ResolutionLimits`), so the menu
  /// may offer it. False until the host has greeted the launcher.
  bool get limitsPs2Resolution => session.limitsPs2Resolution;

  /// Whether the game was started with a states folder on a host that lists `saveStates`, so
  /// [saveState] and [loadState] can be asked for. A start with a folder on an older host leaves the
  /// folder out, and the game plays without save states.
  bool get savesStates => _savesStates;
  bool _savesStates = false;

  /// How the host's connection ended; null while it is open. [RetroHostEnd.unsupported] means
  /// the host speaks no protocol version this launcher does: the emulator needs updating.
  RetroHostEnd? get hostEnd => _hostEnd;
  RetroHostEnd? _hostEnd;

  Timer? _poll;
  Future<void>? _polling;
  bool _pollAgain = false;
  bool _disposed = false;
  bool _hostEnded = false;
  bool _detached = false;

  /// [stop] has begun: the client's `stop` asks `status` until the game has ended, without waiting
  /// for a state call, so no `saveState` or `loadState` is sent from then on.
  bool _stopping = false;
  Future<void>? _closing;
  Future<bool>? _detaching;
  Future<void>? _starting;

  /// A `saveState` or `loadState` under way, until its reply: protocol.md "saveState and
  /// loadState" says a launcher MUST NOT send another call after one until that reply has come, as
  /// a call queued behind it in the host could otherwise be answered more than 5 seconds after it
  /// was sent. Every other call of this game waits for it ([_afterStateCall]); pings go on.
  Future<void>? _stateCallDone;

  /// Sends [send] once no `saveState` or `loadState` is under way. The last check and the send are
  /// one step, with no wait between them, so a state call that started meanwhile, even one asked
  /// after this call, is always seen and waited for too.
  Future<T> _afterStateCall<T>(Future<T> Function() send) async {
    for (var done = _stateCallDone; done != null; done = _stateCallDone) {
      await done;
    }
    return send();
  }

  /// How many `saveState` and `loadState` calls have been answered.
  int get stateReplies => _stateReplies;
  int _stateReplies = 0;

  /// Whether a status asked once [replies] state calls had been answered said the game had not
  /// ended. A load that the core began but did not finish ends the game before the host replies
  /// `false` (the host's `Game::AwaitStateWork`), so after a `loadState` answered `false` this says
  /// the load left the game untouched and it plays on.
  bool playingAfter(int replies) => _playingAfterReplies >= replies;
  int _playingAfterReplies = -1;

  bool get _gameLive => _phase == RetroHostGamePhase.loading || _phase == RetroHostGamePhase.playing;

  /// Whether the host lists `gamePerformance`, so its statuses say how fast the game runs and the
  /// Auto Optimizer can judge a PS1 game's internal resolution. False until the host has greeted
  /// the launcher.
  bool get reportsPerformance => session.reportsPerformance;

  /// The host's version (`welcome.hostVersion`); empty until it has greeted the launcher.
  String get hostVersion => session.hostVersion;

  /// Waits for the host's greeting, then starts the game. Throws [StateError] when a game was
  /// already started on this host. A PS2 game's internal resolution goes only to a host that
  /// limits it ([limitsPs2Resolution]); an older host starts the game at LRPS2's own default.
  /// [autoResolution] gives the PS1 internal resolution the Auto Optimizer starts at, asked once
  /// the host has greeted the launcher (so it can use [hostVersion]), and only of a host that
  /// measures how the game runs ([reportsPerformance]); without one the optimizer cannot judge it,
  /// and the game starts at SwanStation's own default as before.
  Future<void> start(RetroHostStartRequest request, {String Function()? autoResolution}) {
    if (_phase != RetroHostGamePhase.idle) throw StateError('A game was already started on this host.');
    _setPhase(RetroHostGamePhase.starting);
    return _starting = _startNow(request, autoResolution);
  }

  Future<void> _startNow(RetroHostStartRequest request, String Function()? autoResolution) async {
    try {
      await session.ready;
      if (_phase != RetroHostGamePhase.starting) return;
      if (request.console == RetroConsole.ps2 && !session.canPlayPs2) {
        _consoleRefused = true;
        _end(failure: 'The host does not list the $retroCapabilityPs2 capability.');
        return;
      }
      final resolution = switch (request) {
        _ when request.console == RetroConsole.ps2 && !session.limitsPs2Resolution => request.withoutOption(
          retroResolutionKeyPs2,
        ),
        _ when autoResolution != null && request.console == null && session.reportsPerformance => request.withOption(
          retroResolutionKeyPs1,
          autoResolution(),
        ),
        _ => request,
      };
      final states = request.states != null && session.canSaveStates;
      await session.startGame((states ? resolution : resolution.withoutStates()).toArgs());
      _savesStates = states;
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

  /// Asks `status` and follows it: the aspect ratio, the first frame, and the game's end.
  /// Listeners hear of it only when the status says something new: a game that plays on with the
  /// same status, asked twice a second, rebuilds nothing. One `status` is asked at a time; asked
  /// while one is on its way, it is asked once more after it, and the call completes only then, so
  /// what follows sees a status asked after the call (an `option` the host just took shows).
  Future<void> refresh() {
    if (!_gameLive) return Future.value();
    final polling = _polling;
    if (polling != null) {
      _pollAgain = true;
      return polling;
    }
    return _polling = _pollUntilCurrent();
  }

  Future<void> _pollUntilCurrent() async {
    try {
      do {
        _pollAgain = false;
        await _pollOnce();
      } while (_pollAgain && _gameLive);
    } finally {
      _polling = null;
    }
  }

  Future<void> _pollOnce() async {
    try {
      var asked = 0;
      final current = await _afterStateCall(() {
        asked = _stateReplies;
        return session.status();
      });
      if (!_gameLive) return;
      if (current == null) {
        _end(failure: 'The host has no game loaded.');
        return;
      }
      final changed = !(_status?.sameAs(current) ?? false);
      _status = current;
      _aspect = current.aspect;
      if (current.ended) {
        _end();
        return;
      }
      if (asked > _playingAfterReplies) _playingAfterReplies = asked;
      if (current.ready && _phase == RetroHostGamePhase.loading) {
        _setPhase(RetroHostGamePhase.playing);
      } else if (changed) {
        _notify();
      }
    } on Object catch (error) {
      if (_gameLive) _end(failure: '$error');
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

  /// `saveState`: saves the game's state into [slot], 0 to 7, of the states folder it was started
  /// with ([savesStates]). The host writes it between two frames, also while paused.
  Future<RetroStateOutcome> saveState(int slot) => _stateCall('saveState', slot);

  /// `loadState`: loads the state in [slot], 0 to 7, back into the game; a paused game shows it
  /// with its next frame once resumed. A state of another game or core build is refused
  /// ([RetroStateOutcome.otherGame], [RetroStateOutcome.otherCore]) and the game runs on.
  Future<RetroStateOutcome> loadState(int slot) => _stateCall('loadState', slot);

  Future<RetroStateOutcome> _stateCall(String method, int slot) async {
    if (slot < 0 || slot >= RetroStateFolder.slots) throw RangeError.range(slot, 0, RetroStateFolder.slots - 1, 'slot');
    if (!_gameLive || !_savesStates || _stopping) return RetroStateOutcome.notNow;
    return _afterStateCall(() async {
      if (!_gameLive || _stopping) return RetroStateOutcome.notNow;
      final done = Completer<void>();
      _stateCallDone = done.future;
      try {
        final result = await session.call(method, {'slot': slot});
        return result is Map ? RetroStateOutcome.done : RetroStateOutcome.notNow;
      } on RetroCallError catch (error) {
        return RetroStateOutcome.ofError(error.code);
      } on Object {
        return RetroStateOutcome.failed;
      } finally {
        _stateReplies++;
        _stateCallDone = null;
        done.complete();
      }
    });
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
      await _afterStateCall(() => session.call('volume', {'level': _level, 'muted': _isMuted}));
    } on Object {
      return;
    }
  }

  Future<bool> _gameCall(String method, Object? args) async {
    if (!_gameLive) return false;
    try {
      return await _afterStateCall(() => session.call(method, args)) == true;
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
      await _afterStateCall(() => session.call('pause', now));
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
    _stopping = true;
    final ended = await _stopAndRelease();
    if (_phase == RetroHostGamePhase.closed) return ended;
    if (ended != null) _status = ended;
    _end();
    return ended;
  }

  Future<RetroStatus?> _stopAndRelease() async {
    try {
      final ended = await _afterStateCall(session.stopGame);
      await _afterStateCall(() => session.call('release'));
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
        await _afterStateCall(() => session.call('release'));
        free = await _afterStateCall(session.status) == null && !_hostEnded && _closing == null;
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
