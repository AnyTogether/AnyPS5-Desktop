import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'frame_ring.dart';
import 'retro_host_native.dart';
import 'retro_host_protocol.dart';
import 'strict_json.dart';

/// How a connection to the emulator host ended (anyps5-retro-host docs/protocol.md "Fixtures",
/// `outcome`).
enum RetroHostEnd {
  /// The launcher shut the host down and it exited with code 0.
  clean,

  /// The host broke a rule; the launcher killed it.
  protocolError,

  /// The host speaks no version or pixel format this launcher offered: the emulator needs updating.
  unsupported,

  /// The host exited unasked or missed a time limit.
  hostFailure,
}

/// The host is gone and no game was loaded, so there is nothing to report for a call.
class RetroHostGone implements Exception {
  const RetroHostGone(this.end);

  final RetroHostEnd end;

  @override
  String toString() => 'RetroHostGone($end)';
}

/// A `frame` message, after the client pinned and checked the newest frame. [frame] is null when
/// the ring had no frame to pin; [drawn] says whether the frame belongs to the current game, which
/// is the only kind the renderer may show. A frame that is not drawn may be read only until the
/// next message; a drawn one stays readable as [RetroHostClient.frame] while that getter still
/// gives it.
class RetroFrameEvent {
  const RetroFrameEvent(this.frame, {required this.drawn});

  final PinnedFrame? frame;
  final bool drawn;
}

/// The core's vibration for one controller port.
class RetroRumble {
  const RetroRumble(this.port, this.strong, this.weak);

  final int port;
  final int strong;
  final int weak;
}

/// The host's environment as `NAME=value` entries: [base] with [added] on top. Windows treats
/// names that differ only in case as one variable, and `Platform.environment` gives them in upper
/// case there, so an added `Path` must replace the inherited `PATH` rather than sit beside it.
/// On Windows native/retro_host adds the hidden `=` entries and sorts the block.
List<String> retroHostEnvironment(Map<String, String> base, Map<String, String> added, {required bool windows}) {
  final merged = <String, MapEntry<String, String>>{};
  for (final entry in [...base.entries, ...added.entries]) {
    merged[windows ? entry.key.toUpperCase() : entry.key] = entry;
  }
  return [for (final entry in merged.values) '${entry.key}=${entry.value}'];
}

class _Pending {
  _Pending(this.id, this.method, this.args, this.deadline);

  final int id;
  final String method;
  final Object? args;
  final DateTime deadline;
  final completer = Completer<Object?>();
}

/// The launcher's side of one emulator host process: starting it with its control stream, the
/// hello/welcome exchange, calls and their replies in order, pings, time limits, the frame ring,
/// and what to report when the host fails. It reads and writes the stream only through the native
/// threads in native/retro_host, never on this isolate, so the UI thread never waits on the host
/// (protocol.md "Timeouts").
class RetroHostClient {
  RetroHostClient._(this._volume, this._muted, this._offeredFormats);

  static const welcomeLimit = Duration(seconds: 10);
  static const replyLimit = Duration(seconds: 5);
  static const pingEvery = Duration(seconds: 2);
  static const writeLimit = Duration(seconds: 5);
  static const stopLimit = Duration(seconds: 10);
  static const shutdownLimit = Duration(seconds: 15);
  static const _tick = Duration(milliseconds: 100);

  static int _nextToken = 1;

  final double _volume;
  final bool _muted;
  final List<String> _offeredFormats;
  late final NativeCallable<RetroHostCallbackNative> _callback;
  Pointer<Void> _connection = nullptr;
  late final int pid;
  Timer? _timer;

  final _ready = Completer<void>();
  final _ended = Completer<RetroHostEnd>();
  final _exited = Completer<int>();
  Timer? _unsupportedKill;
  final _frames = StreamController<RetroFrameEvent>.broadcast(sync: true);
  final _rumble = StreamController<RetroRumble>.broadcast();
  final _calls = Queue<_Pending>();
  final _pings = Queue<(int, DateTime)>();

  late DateTime _welcomeDeadline;
  DateTime? _nextPing;
  DateTime? _stopDeadline;
  int _stopId = 0;
  DateTime? _shutdownDeadline;
  int _nextCallId = 1;
  int _nextPingId = 1;
  bool _greeted = false;
  bool _unsupportedSeen = false;
  bool _shutdownSent = false;
  bool _closing = false;
  int? _exitCode;
  String? _pixelFormat;
  List<String> _capabilities = const [];
  String _hostVersion = '';

  bool _gameLoaded = false;
  bool _lastStatusEnded = false;
  bool _paused = false;
  bool _inputFocus = true;
  int _ports = 1;
  int? _epoch;
  RetroStatus? _failedStatus;

  FrameRing? _ring;
  FrameRing? _previousRing;
  PinnedFrame? _frame;
  FrameRing? _frameRing;

  /// Starts the host: [command] is the executable's absolute path and any arguments before the
  /// protocol's own; [environment] adds to the launcher's environment for the host. [volume] and
  /// [muted] are sent as the first call after `welcome`.
  static RetroHostClient start({
    required List<String> command,
    Map<String, String>? environment,
    double volume = 1,
    bool muted = false,
    List<String> pixelFormats = const [RetroPixelFormat.rgba8, RetroPixelFormat.bgra8],
  }) {
    if (command.isEmpty) throw ArgumentError.value(command, 'command', 'names no program');
    final client = RetroHostClient._(volume, muted, pixelFormats);
    final token = _nextToken++;
    client._callback = NativeCallable<RetroHostCallbackNative>.listener(client._onEvent);
    final env = environment == null
        ? const <String>[]
        : retroHostEnvironment(Platform.environment, environment, windows: Platform.isWindows);
    final error = calloc<Uint8>(512).cast<Utf8>();
    final argv = _strings(command);
    final envp = _strings(env);
    try {
      client._connection = retroHostStart(
        argv.$1,
        command.length,
        envp.$1,
        env.length,
        token,
        client._callback.nativeFunction,
        error,
        512,
      );
      if (client._connection == nullptr) {
        client._callback.close();
        throw ProcessException(command.first, command.skip(1).toList(), error.toDartString());
      }
    } finally {
      argv.$2();
      envp.$2();
      calloc.free(error);
    }
    client.pid = retroHostPid(client._connection);
    client._welcomeDeadline = DateTime.now().add(welcomeLimit);
    client._timer = Timer.periodic(_tick, (_) => client._checkTime());
    client._sendObject({
      'type': 'hello',
      'minVersion': retroProtocolVersion,
      'maxVersion': retroProtocolVersion,
      'pixelFormats': pixelFormats,
    });
    return client;
  }

  static (Pointer<Pointer<Utf8>>, void Function()) _strings(List<String> values) {
    final array = calloc<Pointer<Utf8>>(values.length + 1);
    for (var i = 0; i < values.length; i++) {
      array[i] = values[i].toNativeUtf8();
    }
    return (
      array,
      () {
        for (var i = 0; i < values.length; i++) {
          calloc.free(array[i]);
        }
        calloc.free(array);
      },
    );
  }

  /// Completes once `welcome` came and the first `volume` call was answered; fails with
  /// [RetroHostGone] when the connection ended first.
  Future<void> get ready => _ready.future;

  /// How the connection ended.
  Future<RetroHostEnd> get ended => _ended.future;

  /// The host's exit code, once it has exited.
  int? get exitCode => _exitCode;

  /// Completes with the host's exit code when its process has ended.
  Future<int> get exited => _exited.future;

  String get hostVersion => _hostVersion;
  List<String> get capabilities => _capabilities;
  String? get pixelFormat => _pixelFormat;

  /// Each `frame` message, after its frame was pinned and checked.
  Stream<RetroFrameEvent> get frames => _frames.stream;

  /// The newest frame of the current game, pinned; null before one came. Its ring stays mapped while
  /// it is the frame shown.
  PinnedFrame? get frame => _frame;

  /// Vibration to forward to the controller at a port; nothing while paused, without input focus, or
  /// for a port that `connectedPorts` left without a controller.
  /// Events come asynchronously, so a listener may call anything on the client, [close] included.
  Stream<RetroRumble> get rumble => _rumble.stream;

  /// Whether the launcher's window has input focus; losing it zeroes the controllers' input and
  /// their motors (protocol.md "input" and "rumble"). Once the connection has ended there is no
  /// input to zero and no rumble to forward, so a change is ignored.
  set inputFocus(bool focused) {
    if (_ended.isCompleted || _inputFocus == focused) return;
    _inputFocus = focused;
    if (!focused) {
      _zeroInput();
      _zeroRumble();
    }
  }

  void _zeroInput() {
    for (final port in const [0, 1]) {
      input(port, 0);
    }
  }

  /// Sends a call and gives its result; `error` replies throw [RetroCallError]. After a host
  /// failure with a game loaded this gives what protocol.md "Host failure" lists, until `release`.
  ///
  /// `stop` goes through [stopGame], which enforces its time limit.
  Future<Object?> call(String method, [Object? args]) {
    if (method == 'stop') throw ArgumentError.value(method, 'method', 'use stopGame');
    return _send(method, args);
  }

  Future<Object?> _send(String method, Object? args) {
    if (_ended.isCompleted) return Future.value(_afterFailure(method));
    if (!_greeted) throw StateError('No call may be sent before welcome.');
    if (method != 'volume' && !_capabilities.contains(retroCapabilityPs1)) {
      throw StateError('The host does not list the ps1 capability.');
    }
    if (StrictJson.hasLoneSurrogate(args)) {
      return Future.error(const RetroCallError(RetroCallError.argument, 'A string cannot be sent as UTF-8.'));
    }
    if (_nextCallId > RetroFields.maxId) throw StateError('This host has used every call id.');
    final Uint8List body;
    try {
      body = _encode({'type': 'call', 'id': _nextCallId, 'method': method, 'args': args});
    } on Object catch (error) {
      return Future.error(RetroCallError(RetroCallError.argument, 'The call cannot be sent: $error'));
    }
    final pending = _Pending(_nextCallId++, method, args, DateTime.now().add(replyLimit));
    final before = _expectedRumble();
    _calls.add(pending);
    if (method == 'start' || method == 'release') {
      _zeroRumble();
    } else {
      _zeroIfStricter(before);
    }
    _write(body);
    return pending.completer.future;
  }

  /// `start`: loads a game and gives its epoch.
  Future<int> startGame(Map<String, Object?> args) async => ((await call('start', args))! as Map)['epoch'] as int;

  /// `status`: null with no game loaded, and the short report of protocol.md "Host failure" after
  /// one.
  Future<RetroStatus?> status() async {
    final result = await call('status');
    if (result == null) return null;
    final map = result as Map<String, Object?>;
    if (RetroStatus.isFailureReport(map)) {
      return RetroStatus.failed(error: map['error']! as String, errorCode: map['errorCode']! as String);
    }
    return RetroStatus.parse(map);
  }

  static const _stopPoll = Duration(milliseconds: 250);

  /// `stop`, then `status` until the game has ended, which it gives. The host is killed if the
  /// game has not ended 10 seconds after `stop` (protocol.md "Timeouts"), and the status then is the
  /// failure report. Null when no game was loaded.
  Future<RetroStatus?> stopGame() async {
    if (!_ended.isCompleted) {
      if (!_greeted) throw StateError('No call may be sent before welcome.');
      if (_stopDeadline == null) {
        _stopDeadline = DateTime.now().add(stopLimit);
        _stopId = _nextCallId;
      }
    }
    await _send('stop', null);
    while (true) {
      final current = await status();
      if (current == null || current.ended) {
        _stopDeadline = null;
        return current;
      }
      await Future<void>.delayed(_stopPoll);
    }
  }

  /// The controller state of one port (protocol.md "input").
  void input(int port, int buttons, {int leftX = 0, int leftY = 0, int rightX = 0, int rightY = 0}) {
    if (port < 0 || port > 1) throw RangeError.range(port, 0, 1, 'port');
    if (buttons < 0 || buttons > 0xFFFF) throw RangeError.range(buttons, 0, 0xFFFF, 'buttons');
    for (final stick in [leftX, leftY, rightX, rightY]) {
      if (stick < -32768 || stick > 32767) throw RangeError.range(stick, -32768, 32767, 'stick');
    }
    if (!_greeted || _ended.isCompleted) return;
    _sendObject({
      'type': 'input',
      'port': port,
      'buttons': buttons,
      'leftX': leftX,
      'leftY': leftY,
      'rightX': rightX,
      'rightY': rightY,
    });
  }

  /// Asks the host to stop its game and exit; it is killed if it has not exited 15 seconds later.
  /// Before `welcome` nothing may be sent, so the host is killed instead.
  void shutdown() {
    if (_shutdownSent || _ended.isCompleted || _connection == nullptr || _unsupportedSeen) return;
    if (!_greeted) {
      _finish(RetroHostEnd.hostFailure, kill: true, reason: 'Shut down before welcome.');
      return;
    }
    _shutdownSent = true;
    _shutdownDeadline = DateTime.now().add(shutdownLimit);
    _sendObject({'type': 'shutdown'});
  }

  /// Kills the host if it still runs and frees everything the connection holds.
  Future<void> close() async {
    _finish(RetroHostEnd.hostFailure, errorCode: RetroErrorCode.hostExited, kill: true);
    await _release();
  }

  Object? _afterFailure(String method) {
    final failed = _failedStatus;
    if (failed == null) throw RetroHostGone(_ended.isCompleted ? _endValue! : RetroHostEnd.hostFailure);
    switch (method) {
      case 'status':
        return failed.toFailureJson();
      case 'release':
        _failedStatus = null;
        _gameLoaded = false;
        return null;
      case 'connectedPorts' || 'changeDisc' || 'option':
        return false;
      default:
        return null;
    }
  }

  RetroHostEnd? _endValue;

  void _onEvent(int token, int kind, Pointer<Uint8> data, int length, int extra) {
    switch (kind) {
      case RetroHostEvent.message:
        final body = Uint8List.fromList(data.asTypedList(length));
        retroHostFree(data.cast());
        if (_closing || _ended.isCompleted) {
          retroHostCloseDescriptor(extra);
          return;
        }
        try {
          _onMessage(body, extra);
        } on RetroProtocolError catch (error) {
          _protocolError(error.message);
        } on StrictJsonError catch (error) {
          _protocolError(error.message);
        } on Object catch (error) {
          _finish(RetroHostEnd.hostFailure, errorCode: RetroErrorCode.hostExited, kill: true, reason: '$error');
        }
      case RetroHostEvent.framing:
        _protocolError('The control stream broke a framing rule (length $length).');
      case RetroHostEvent.end:
        if (!_ended.isCompleted && !_unsupportedSeen && !_shutdownSent) {
          _finish(RetroHostEnd.hostFailure, errorCode: RetroErrorCode.hostExited, kill: true);
        }
      case RetroHostEvent.exited:
        _exitCode = extra;
        _unsupportedKill?.cancel();
        if (!_exited.isCompleted) _exited.complete(extra);
        if (_unsupportedSeen) {
          _finish(RetroHostEnd.unsupported);
        } else if (_shutdownSent && (extra == 0 || extra == RetroHostEvent.exitUnknown) && _calls.isEmpty) {
          _finish(RetroHostEnd.clean);
        } else {
          _finish(RetroHostEnd.hostFailure, errorCode: RetroErrorCode.hostExited);
        }
        unawaited(_release());
    }
  }

  void _onMessage(Uint8List body, int descriptor) {
    final Map<String, Object?> message;
    try {
      message = StrictJson.decodeObject(body);
    } on Object {
      retroHostCloseDescriptor(descriptor);
      rethrow;
    }
    final type = message['type'];
    if (type is! String) {
      retroHostCloseDescriptor(descriptor);
      throw const RetroProtocolError('A message has no string type.');
    }
    if (descriptor >= 0 && type != 'ring') {
      retroHostCloseDescriptor(descriptor);
      throw RetroProtocolError('A descriptor came with a $type message.');
    }
    if (_unsupportedSeen) {
      retroHostCloseDescriptor(descriptor);
      throw RetroProtocolError('A $type message came after unsupported.');
    }
    if (!_greeted && type != 'welcome' && type != 'unsupported') {
      retroHostCloseDescriptor(descriptor);
      throw RetroProtocolError('The first message is $type, not welcome or unsupported.');
    }
    switch (type) {
      case 'welcome':
        _onWelcome(RetroFields(message, 'welcome'));
      case 'unsupported':
        _onUnsupported(RetroFields(message, 'unsupported'));
      case 'reply':
        _onReply(RetroFields(message, 'reply'));
      case 'pong':
        _onPong(RetroFields(message, 'pong'));
      case 'ring':
        _onRing(RetroFields(message, 'ring'), descriptor);
      case 'frame':
        _onFrame();
      case 'rumble':
        _onRumble(RetroFields(message, 'rumble'));
    }
  }

  void _onWelcome(RetroFields f) {
    if (_greeted) throw const RetroProtocolError('A second welcome came.');
    final version = f.integer('version', 1, RetroFields.maxUint32);
    final hostPid = f.integer('pid', 1, RetroFields.maxUint32);
    _hostVersion = f.string('hostVersion');
    _capabilities = f.strings('capabilities');
    final format = f.string('pixelFormat');
    if (version != retroProtocolVersion || !_offeredFormats.contains(format)) {
      _unsupportedSeen = true;
      _finish(RetroHostEnd.unsupported, kill: true);
      return;
    }
    if (hostPid != pid) throw RetroProtocolError('welcome.pid is $hostPid, not the host\'s process id $pid.');
    _greeted = true;
    _pixelFormat = format;
    _nextPing = DateTime.now().add(pingEvery);
    call('volume', {'level': _volume, 'muted': _muted}).then(
      (_) {
        if (!_ready.isCompleted) _ready.complete();
      },
      onError: (Object error) {
        if (!_ready.isCompleted) _ready.completeError(error);
      },
    );
  }

  void _onUnsupported(RetroFields f) {
    if (_greeted) throw const RetroProtocolError('unsupported came after welcome.');
    final min = f.integer('minVersion', 1, RetroFields.maxUint32);
    final max = f.integer('maxVersion', 1, RetroFields.maxUint32);
    if (min > max) throw const RetroProtocolError('unsupported.minVersion is above maxVersion.');
    f.strings('pixelFormats');
    _unsupportedSeen = true;
    _timer?.cancel();
    _unsupportedKill = Timer(welcomeLimit, () => _finish(RetroHostEnd.unsupported, kill: true));
  }

  void _onReply(RetroFields f) {
    final id = f.integer('id', 1, RetroFields.maxId);
    if (_calls.isEmpty || _calls.first.id != id) {
      throw RetroProtocolError('reply.id $id is not the oldest call still waiting.');
    }
    final hasResult = f.has('result');
    final hasError = f.has('error');
    if (hasResult == hasError) throw const RetroProtocolError('A reply needs exactly one of result and error.');
    final pending = _calls.first;
    final before = _expectedRumble();
    if (hasError) {
      final error = f.object('error');
      final failure = RetroCallError(error.string('code'), error.string('message'));
      _calls.removeFirst();
      _zeroIfStricter(before);
      pending.completer.completeError(failure);
      return;
    }
    final result = _checkResult(pending, f.map['result']);
    _calls.removeFirst();
    _zeroIfStricter(before);
    pending.completer.complete(result);
    if (pending.method == 'start') _zeroInput();
  }

  Object? _checkResult(_Pending pending, Object? result) {
    final method = pending.method;
    final args = pending.args;
    final afterStop = pending.id > _stopId;
    switch (method) {
      case 'start':
        final epoch = RetroFields(_object(result, 'start'), 'start').integer('epoch', 1, RetroFields.maxId);
        _epoch = epoch;
        _gameLoaded = true;
        _paused = false;
        _ports = 1;
        _lastStatusEnded = false;
        _setFrame(null, null);
      case 'status':
        if (result == null) {
          if (_gameLoaded) _zeroRumble();
          _gameLoaded = false;
          _epoch = null;
          _lastStatusEnded = false;
          if (afterStop) _stopDeadline = null;
        } else {
          final status = RetroStatus.parse(_object(result, 'status'));
          if (status.ended && !_lastStatusEnded) _zeroRumble();
          _lastStatusEnded = status.ended;
          if (status.ended && afterStop) _stopDeadline = null;
        }
      case 'release':
        _expectNull(method, result);
        if (_lastStatusEnded) {
          _gameLoaded = false;
          _epoch = null;
          if (afterStop) _stopDeadline = null;
        }
      case 'connectedPorts' || 'changeDisc' || 'option':
        if (result is! bool) throw RetroProtocolError('The result of $method must be a boolean.');
        if (method == 'connectedPorts' && result && args is int) _ports = args;
      case 'pause':
        _expectNull(method, result);
        if (_gameLoaded && args is bool) _paused = args;
      case 'volume' || 'stop':
        _expectNull(method, result);
    }
    return result;
  }

  static Map<String, Object?> _object(Object? value, String method) {
    if (value is! Map<String, Object?>) throw RetroProtocolError('The result of $method must be an object.');
    return value;
  }

  static void _expectNull(String method, Object? value) {
    if (value != null) throw RetroProtocolError('The result of $method must be null.');
  }

  void _onPong(RetroFields f) {
    final id = f.integer('id', 1, RetroFields.maxId);
    if (_pings.isEmpty || _pings.first.$1 != id) throw RetroProtocolError('pong.id $id is not the oldest ping.');
    _pings.removeFirst();
  }

  /// Maps a new ring. The oldest ring, and the frame shown from it, are let go first, so no more
  /// than two rings are ever mapped (protocol.md "Memory objects").
  void _onRing(RetroFields f, int descriptor) {
    final int bytes;
    final int memory;
    try {
      bytes = f.integer('bytes', 4108, 805310464);
      if (Platform.isWindows) {
        memory = f.integer('handle', 1, RetroFields.maxUint32);
      } else {
        if (descriptor < 0) throw const RetroProtocolError('A ring came without its descriptor.');
        memory = descriptor;
      }
    } on Object {
      retroHostCloseDescriptor(descriptor);
      rethrow;
    }
    final previous = _previousRing;
    if (previous != null) {
      if (identical(_frameRing, previous)) {
        _frame = null;
        _frameRing = null;
      }
      previous.unmap();
      _previousRing = null;
    }
    final error = calloc<Uint8>(256).cast<Utf8>();
    try {
      final base = retroHostMapRing(_connection, memory, bytes, error, 256);
      if (base == nullptr) throw RetroProtocolError(error.toDartString());
      final FrameRing ring;
      try {
        ring = FrameRing.check(base: base, bytes: bytes, pixelFormat: _pixelFormat!, current: _ring);
      } on Object {
        retroHostUnmapRing(base, bytes);
        rethrow;
      }
      _previousRing = _ring;
      _ring = ring;
    } finally {
      calloc.free(error);
    }
  }

  void _onFrame() {
    final ring = _ring;
    if (ring == null) throw const RetroProtocolError('A frame came before any ring.');
    final pinned = ring.pin();
    final drawn = pinned != null && _gameLoaded && pinned.epoch == _epoch;
    if (drawn) {
      _setFrame(pinned, ring);
    } else if (ring.gaveUpPin && identical(_frameRing, ring)) {
      _setFrame(null, null);
    }
    _frames.add(RetroFrameEvent(pinned, drawn: drawn));
  }

  /// Keeps [frame], in [ring], as the frame to show, and unmaps the older ring once nothing shown
  /// is in it: the launcher maps at most two rings (protocol.md "Memory objects").
  void _setFrame(PinnedFrame? frame, FrameRing? ring) {
    _frame = frame;
    _frameRing = ring;
    final previous = _previousRing;
    if (previous != null && !identical(_frameRing, previous)) {
      previous.unmap();
      _previousRing = null;
    }
  }

  void _onRumble(RetroFields f) {
    final event = RetroRumble(f.integer('port', 0, 1), f.integer('strong', 0, 0xFFFF), f.integer('weak', 0, 0xFFFF));
    final expected = _expectedRumble();
    if (!expected.live || expected.paused || !_inputFocus || event.port >= expected.ports) return;
    _rumble.add(event);
  }

  /// Zeroes the motors when the state rumble follows has become stricter than [before]: paused, or
  /// fewer ports with a controller. The end of a game zeroes them where a `status` shows it, since
  /// a next `start` still waiting would hide the end here.
  void _zeroIfStricter(({bool live, bool paused, int ports}) before) {
    final after = _expectedRumble();
    if ((after.paused && !before.paused) || after.ports < before.ports) _zeroRumble();
  }

  /// Whether a game runs (its `start` answered and its end not seen), whether it is paused and how
  /// many ports have a controller once the host has taken every call sent so far, as the host takes
  /// them in order: what the replies confirmed, then each call still waiting as if it succeeds,
  /// except a `start` while a game is loaded, which the host refuses with `busy`. A `start` still
  /// waiting makes no game run, since its game loads only after the reply. Rumble follows this, so
  /// it stops as soon as a pause or a controller leaving is sent, and a call sent before an earlier
  /// `start` was answered still counts.
  ({bool live, bool paused, int ports}) _expectedRumble() {
    var loaded = _gameLoaded;
    var live = _gameLoaded && !_lastStatusEnded;
    var paused = _paused;
    var ports = _ports;
    for (final call in _calls) {
      final args = call.args;
      switch (call.method) {
        case 'start' when !loaded:
          loaded = true;
          live = false;
          paused = false;
          ports = 1;
        case 'release' when _lastStatusEnded:
          loaded = false;
        case 'pause' when loaded && args is bool:
          paused = args;
        case 'connectedPorts' when loaded && args is int && (args == 1 || args == 2):
          ports = args;
      }
    }
    return (live: live, paused: paused, ports: ports);
  }

  void _zeroRumble() {
    for (final port in const [0, 1]) {
      _rumble.add(RetroRumble(port, 0, 0));
    }
  }

  void _checkTime() {
    if (_ended.isCompleted || _connection == nullptr) return;
    final now = DateTime.now();
    final writeAge = retroHostWriteAgeMs(_connection);
    if (writeAge < 0) {
      _finish(RetroHostEnd.hostFailure, errorCode: RetroErrorCode.hostExited, kill: true);
      return;
    }
    final missed = switch (now) {
      _ when writeAge > writeLimit.inMilliseconds => 'A write to the host took longer than ${writeLimit.inSeconds} s.',
      _ when !_greeted && !_unsupportedSeen && now.isAfter(_welcomeDeadline) =>
        'No welcome within ${welcomeLimit.inSeconds} s.',
      _ when _calls.isNotEmpty && now.isAfter(_calls.first.deadline) =>
        'No reply to ${_calls.first.method} within ${replyLimit.inSeconds} s.',
      _ when _pings.isNotEmpty && now.isAfter(_pings.first.$2) => 'No pong within ${replyLimit.inSeconds} s.',
      _ when _stopDeadline != null && now.isAfter(_stopDeadline!) =>
        'The game had not ended ${stopLimit.inSeconds} s after stop.',
      _ when _shutdownDeadline != null && now.isAfter(_shutdownDeadline!) =>
        'The host had not exited ${shutdownLimit.inSeconds} s after shutdown.',
      _ => null,
    };
    if (missed != null) {
      _finish(RetroHostEnd.hostFailure, errorCode: RetroErrorCode.hostHung, kill: true, reason: missed);
      return;
    }
    final next = _nextPing;
    if (next != null && !_shutdownSent && now.isAfter(next)) {
      if (_nextPingId > RetroFields.maxId) return;
      final id = _nextPingId++;
      _pings.add((id, now.add(replyLimit)));
      _nextPing = now.add(pingEvery);
      _sendObject({'type': 'ping', 'id': id});
    }
  }

  void _protocolError(String message) {
    _finish(RetroHostEnd.protocolError, errorCode: RetroErrorCode.hostExited, kill: true, reason: message);
  }

  /// The reason the client gave up on the host, for logs.
  String? failureReason;

  void _finish(RetroHostEnd end, {String? errorCode, bool kill = false, String? reason}) {
    if (_ended.isCompleted) return;
    _endValue = end;
    failureReason = reason;
    _timer?.cancel();
    if (kill && _connection != nullptr) retroHostKill(_connection);
    if (_gameLoaded) _zeroRumble();
    if (end != RetroHostEnd.clean && end != RetroHostEnd.unsupported && _gameLoaded && errorCode != null) {
      _failedStatus = RetroStatus.failed(
        error: errorCode == RetroErrorCode.hostHung
            ? 'The emulator stopped responding and was closed.'
            : 'The emulator closed unexpectedly.',
        errorCode: errorCode,
      );
    }
    while (_calls.isNotEmpty) {
      final pending = _calls.removeFirst();
      try {
        pending.completer.complete(_afterFailure(pending.method));
      } on RetroHostGone catch (error) {
        pending.completer.completeError(error);
      }
    }
    if (!_ready.isCompleted) _ready.completeError(RetroHostGone(end));
    _ended.complete(end);
    if (kill) unawaited(_release());
  }

  Future<void>? _releasing;

  /// Frees the connection once; every caller waits for the same release to finish.
  Future<void> _release() => _releasing ??= _releaseNow();

  Future<void> _releaseNow() async {
    if (_connection == nullptr) return;
    _closing = true;
    final address = _connection.address;
    final code = await Isolate.run(() => retroHostClose(Pointer<Void>.fromAddress(address)));
    _connection = nullptr;
    if (!_exited.isCompleted) {
      _exitCode = code;
      _exited.complete(code);
    }
    _callback.close();
    _previousRing?.unmap();
    _ring?.unmap();
    _previousRing = null;
    _ring = null;
    _frame = null;
    await _frames.close();
    await _rumble.close();
  }

  void _sendObject(Map<String, Object?> message) => _write(_encode(message));

  /// A message's body, or throws when it cannot be sent: not JSON, or larger than 1 MiB.
  static Uint8List _encode(Map<String, Object?> message) {
    final body = utf8.encode(jsonEncode(message));
    if (body.length > 1048576) throw ArgumentError('A message is larger than 1 MiB.');
    return body;
  }

  void _write(Uint8List body) {
    if (_connection == nullptr || _closing) return;
    final framed = calloc<Uint8>(body.length + 4);
    try {
      final view = framed.asTypedList(body.length + 4);
      view[0] = body.length & 0xFF;
      view[1] = (body.length >> 8) & 0xFF;
      view[2] = (body.length >> 16) & 0xFF;
      view[3] = (body.length >> 24) & 0xFF;
      view.setRange(4, body.length + 4, body);
      if (retroHostSend(_connection, framed, body.length + 4) == 0) {
        _finish(RetroHostEnd.hostFailure, errorCode: RetroErrorCode.hostExited, kill: true);
      }
    } finally {
      calloc.free(framed);
    }
  }
}
