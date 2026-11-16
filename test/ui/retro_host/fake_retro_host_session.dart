import 'dart:async';
import 'dart:ffi';

import 'package:anyps5_desktop/core/controllers/pad_info.dart';
import 'package:anyps5_desktop/core/gamepad/feel.dart';
import 'package:anyps5_desktop/core/retro_host/frame_ring.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_client.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_protocol.dart';
import 'package:anyps5_desktop/core/retro_host/retro_pad.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_session.dart';
import 'package:anyps5_desktop/ui/retro_host/retro_host_controls.dart';
import 'package:ffi/ffi.dart';

/// Pixels in native memory, as a ring slot would hold them, freed by [free].
class FakeSlot {
  FakeSlot(this.width, this.height) : pixels = calloc<Uint8>(width * height * 4);

  final int width;
  final int height;
  final Pointer<Uint8> pixels;

  void fill(List<int> pixel) {
    final view = pixels.asTypedList(width * height * 4);
    for (var i = 0; i < view.length; i++) {
      view[i] = pixel[i % 4];
    }
  }

  PinnedFrame pin({int epoch = 1, String format = RetroPixelFormat.rgba8}) => PinnedFrame(
    slot: 0,
    width: width,
    height: height,
    epoch: epoch,
    visible: true,
    pixels: pixels,
    pixelFormat: format,
  );

  void free() => calloc.free(pixels);
}

/// A frame source the test drives by hand.
class FakeFrameSource implements RetroFrameSource {
  final _frames = StreamController<RetroFrameEvent>.broadcast(sync: true);
  PinnedFrame? _frame;

  @override
  Stream<RetroFrameEvent> get frames => _frames.stream;

  @override
  PinnedFrame? get frame => _frame;

  void send(PinnedFrame? frame, {bool drawn = true}) {
    if (drawn) _frame = frame;
    _frames.add(RetroFrameEvent(frame, drawn: drawn));
  }

  Future<void> close() => _frames.close();
}

/// A host session that records what the launcher asked and answers as the test says.
class FakeRetroHostSession extends FakeFrameSource implements RetroHostSession {
  final readyCompleter = Completer<void>();
  final endedCompleter = Completer<RetroHostEnd>();
  final calls = <(String, Object?)>[];
  final inputs = <(int, int)>[];

  /// Every `input`, with its sticks.
  final inputStates = <(int, RetroPadInput)>[];

  /// When set, every call is answered only once this completes.
  Completer<void>? callGate;

  /// What a call returns, by method; null for any other.
  final callResults = <String, Object?>{};
  final focusChanges = <bool>[];
  Map<String, Object?>? startArgs;
  Object? startError;

  /// When set, `start` is answered only once this completes.
  Completer<void>? startGate;
  RetroStatus? nextStatus;
  Object? statusError;
  RetroStatus? stopStatus = const RetroStatus(ready: true, ended: true, error: '', errorCode: '');
  bool shutdownAsked = false;
  bool closed = false;
  final _rumble = StreamController<RetroRumble>.broadcast(sync: true);

  @override
  Future<void> get ready => readyCompleter.future;

  @override
  Future<RetroHostEnd> get ended => endedCompleter.future;

  @override
  Stream<RetroRumble> get rumble => _rumble.stream;

  @override
  set inputFocus(bool focused) {
    if (closed) throw StateError('Focus was set on a closed session.');
    focusChanges.add(focused);
  }

  @override
  Future<int> startGame(Map<String, Object?> args) async {
    startArgs = args;
    await startGate?.future;
    final error = startError;
    if (error != null) throw error;
    return 1;
  }

  /// `release` forgets an ended game, as protocol.md "release" says: `status` is then null.
  @override
  Future<Object?> call(String method, [Object? args]) async {
    calls.add((method, args));
    await callGate?.future;
    if (method == 'release' && (nextStatus?.ended ?? true)) nextStatus = null;
    return callResults[method];
  }

  @override
  Future<RetroStatus?> status() async {
    final error = statusError;
    if (error != null) throw error;
    return nextStatus;
  }

  /// `stop`: the game has ended, and `status` says so until `release`.
  @override
  Future<RetroStatus?> stopGame() async {
    calls.add(('stop', null));
    if (nextStatus != null) nextStatus = stopStatus;
    return stopStatus;
  }

  @override
  void input(int port, int buttons, {int leftX = 0, int leftY = 0, int rightX = 0, int rightY = 0}) {
    inputs.add((port, buttons));
    inputStates.add((
      port,
      RetroPadInput(buttons: buttons, leftX: leftX, leftY: leftY, rightX: rightX, rightY: rightY),
    ));
  }

  /// A `rumble` message from the host.
  void sendRumble(int port, int strong, int weak) => _rumble.add(RetroRumble(port, strong, weak));

  @override
  void shutdown() {
    shutdownAsked = true;
    if (!endedCompleter.isCompleted) endedCompleter.complete(RetroHostEnd.clean);
  }

  @override
  Future<void> close() async {
    closed = true;
    await super.close();
    await _rumble.close();
  }
}

RetroStatus fakeStatus({bool ready = true, bool ended = false, double aspect = 4 / 3, String errorCode = ''}) =>
    RetroStatus(ready: ready, ended: ended, error: '', errorCode: errorCode, aspect: aspect);

/// Controllers the test holds by hand.
class FakePads {
  final List<String> order = [];
  final Map<String, PadState> states = {};

  RetroPadReader get reader => RetroPadReader(pads: () => List.of(order), state: (id) => states[id]);

  void connect(String id, [PadState state = PadState.idle]) {
    order.add(id);
    states[id] = state;
  }

  void disconnect(String id) {
    order.remove(id);
    states.remove(id);
  }
}

/// Motors that record what they were told.
class FakeMotors implements PadRumble {
  final Set<String> vibrating = {};
  final orders = <(String, double, double, Duration)>[];

  @override
  bool canRumble(String pad) => vibrating.contains(pad);

  @override
  void rumble(String pad, double strong, double weak, Duration length) => orders.add((pad, strong, weak, length));
}
