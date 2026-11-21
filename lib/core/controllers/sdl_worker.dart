import 'dart:async';
import 'dart:isolate';

import 'sdl_pads.dart';

/// One pad SDL has open in the worker: its last reading and what it can do.
class SdlOpenPad {
  const SdlOpenPad({required this.reading, this.hasRumble = false, this.hasLed = false, this.serial});
  final SdlReading? reading;
  final bool hasRumble;
  final bool hasLed;
  final String? serial;
}

/// What SDL saw at one moment in the worker: the devices it lists and the pads it has open.
class SdlFrame {
  const SdlFrame({this.devices = const [], this.open = const {}});
  static const empty = SdlFrame();
  final List<SdlDevice> devices;
  final Map<int, SdlOpenPad> open;

  /// A short text that changes whenever anything the launcher reads changes.
  String get signature => [
    for (final device in devices) '${device.instance}${device.gameController ? 'g' : 'j'}',
    for (final MapEntry(key: instance, value: pad) in open.entries)
      '$instance:${(pad.reading?.held.toList() ?? <int>[])..sort()}:${pad.reading?.axes}:${pad.reading?.powerLevel}',
  ].join('|');
}

/// The worker started SDL2 (its version) or could not (why).
class SdlWorkerStarted {
  const SdlWorkerStarted(this.version);
  final String version;
}

class SdlWorkerFailed {
  const SdlWorkerFailed(this.why);
  final String why;
}

/// What the worker does each tick, apart from the isolate around it (tests run it on a fake):
/// lets SDL look for devices (SDL_GameControllerUpdate: on Linux this is where SDL opens a new
/// /dev/input node, and where an open the driver never returns from would hang), opens every game
/// controller it lists, lets go of the ones gone, and reads the open ones.
class SdlWorkerLoop {
  SdlWorkerLoop(this.sdl);

  final SdlBackend sdl;
  final Map<int, SdlOpenPad> _pads = {};
  String? _sent;
  int _quietTicks = 0;

  /// One look: what SDL lists and what the open pads hold now.
  SdlFrame tick() {
    sdl.update();
    final devices = sdl.devices();
    final present = {for (final device in devices) device.instance};
    for (final instance in [..._pads.keys]) {
      if (present.contains(instance)) continue;
      _pads.remove(instance);
      sdl.close(instance);
    }
    for (final device in devices) {
      if (!device.gameController || _pads.containsKey(device.instance)) continue;
      if (!sdl.open(device)) continue;
      _pads[device.instance] = SdlOpenPad(
        reading: null,
        hasRumble: sdl.hasRumble(device.instance),
        hasLed: sdl.hasLed(device.instance),
        serial: sdl.serial(device.instance),
      );
    }
    for (final MapEntry(key: instance, value: pad) in _pads.entries.toList()) {
      _pads[instance] = SdlOpenPad(reading: sdl.read(instance), hasRumble: pad.hasRumble, hasLed: pad.hasLed, serial: pad.serial);
    }
    return SdlFrame(devices: devices, open: Map.unmodifiable(_pads));
  }

  /// Whether [frame] goes to the launcher: when something changed, and at least every
  /// [heartbeat] ticks regardless, which tells the launcher the worker still answers.
  bool shouldSend(SdlFrame frame, {int heartbeat = 60}) {
    final signature = frame.signature;
    if (signature != _sent || ++_quietTicks >= heartbeat) {
      _sent = signature;
      _quietTicks = 0;
      return true;
    }
    return false;
  }

  /// A command from the launcher: (what, instance, values).
  void command((String, int, List<int>) message) {
    final (what, instance, values) = message;
    switch (what) {
      case 'rumble':
        sdl.rumble(instance, values[0], values[1], values[2]);
      case 'led':
        sdl.setLed(instance, values[0], values[1], values[2]);
      case 'player':
        sdl.setPlayerIndex(instance, values[0]);
    }
  }

  void quit() {
    for (final instance in _pads.keys) {
      sdl.rumble(instance, 0, 0, 0);
    }
    _pads.clear();
    sdl.quit();
  }
}

/// The worker isolate: SDL2 started and polled 60 times a second, every frame that changed sent
/// back, the launcher's commands carried out.
void _sdlWorkerMain((SendPort, List<String>?) start) {
  final (reply, paths) = start;
  final commands = ReceivePort();
  reply.send(commands.sendPort);
  String? failure;
  final sdl = SdlLibrary.load(paths: paths, failure: (why) => failure = why);
  if (sdl == null) {
    reply.send(SdlWorkerFailed(failure ?? 'SDL2 did not start'));
    commands.close();
    return;
  }
  reply.send(SdlWorkerStarted(sdl.version));
  final loop = SdlWorkerLoop(sdl);
  final timer = Timer.periodic(const Duration(milliseconds: 16), (_) {
    try {
      final frame = loop.tick();
      if (loop.shouldSend(frame)) reply.send(frame);
    } on Object {
      // A tick that fails is tried again next time; the heartbeat says the worker lives.
    }
  });
  commands.listen((message) {
    if (message == 'quit') {
      timer.cancel();
      commands.close();
      try {
        loop.quit();
      } on Object {
        // Going anyway.
      }
      Isolate.exit();
    }
    if (message is (String, int, List<int>)) {
      try {
        loop.command(message);
      } on Object {
        // A pad gone between the command and now.
      }
    }
  });
}

/// SDL2 run in an isolate of its own ([SdlWorkerLoop]), seen from the launcher's isolate as an
/// ordinary [SdlBackend]: devices, readings and what each pad can do are the worker's last frame,
/// rumble, lights and player lights go to the worker as messages. Nothing here waits for the
/// worker, so a device open that hangs in the kernel there (issue #195: HP's lis3lv02d
/// accelerometer, whose open reads ACPI and never returns) leaves the launcher's interface
/// running.
///
/// The worker sends a frame at least once a second. When it does not finish starting within
/// [startTicks] seconds, or goes quiet for [silentTicks] seconds once started, it is taken to be
/// stuck in such an open: [onFailed] is told (stalled), and the launcher reads pads its other way.
/// An open in uninterruptible sleep cannot be undone; the worker is left where it is, killed if
/// it ever comes back, and never waited for, so it holds up neither a rescan nor quitting.
class SdlIsolateBackend implements SdlBackend {
  SdlIsolateBackend({this.paths, this.startTicks = 10, this.silentTicks = 5, bool spawn = true}) {
    _replies.listen(receive);
    _watch = Timer.periodic(const Duration(seconds: 1), (_) => watchTick());
    if (spawn) {
      unawaited(
        Isolate.spawn(_sdlWorkerMain, (_replies.sendPort, paths), errorsAreFatal: false, debugName: 'sdl-pads').then(
          (isolate) {
            _isolate = isolate;
            if (_done) isolate.kill();
          },
          onError: (Object error) => _fail('SDL2 worker could not start: $error', stalled: false),
        ),
      );
    }
  }

  /// Where SDL2 is loaded from in the worker (null: [SdlLibrary.candidates]).
  final List<String>? paths;
  final int startTicks;
  final int silentTicks;

  /// The worker failed: why, and whether it is stuck (stalled) rather than without SDL2.
  void Function(String why, {required bool stalled})? onFailed;

  final ReceivePort _replies = ReceivePort();
  Isolate? _isolate;
  SendPort? _commands;
  Timer? _watch;
  String _version = '2';
  SdlFrame _frame = SdlFrame.empty;
  bool _started = false;
  bool _heard = false;
  int _quiet = 0;
  bool _done = false;

  /// Started and answering.
  bool get running => _started && !_done;

  /// A message from the worker (tests call it directly).
  void receive(Object? message) {
    if (_done) return;
    _heard = true;
    switch (message) {
      case SendPort port:
        _commands = port;
      case SdlWorkerStarted(:final version):
        _version = version;
        _started = true;
      case SdlWorkerFailed(:final why):
        _fail(why, stalled: false);
      case SdlFrame frame:
        _frame = frame;
    }
  }

  /// Once a second (tests call it directly): a worker that has not been heard from in too long
  /// is stuck.
  void watchTick() {
    if (_done) return;
    if (_heard) {
      _heard = false;
      _quiet = 0;
      return;
    }
    _quiet++;
    if (!_started && _quiet >= startTicks) {
      _fail('SDL2 did not finish starting within $startTicks s: a controller device it opened does not answer', stalled: true);
    } else if (_started && _quiet >= silentTicks) {
      _fail('SDL2 stopped answering for $silentTicks s: a controller device it opened does not answer', stalled: true);
    }
  }

  void _fail(String why, {required bool stalled}) {
    if (_done) return;
    _finish();
    onFailed?.call(why, stalled: stalled);
  }

  void _finish() {
    _done = true;
    _watch?.cancel();
    _replies.close();
    _frame = SdlFrame.empty;
    // Killed whenever it reaches its event loop again; if it never does, it is not waited for.
    _isolate?.kill(priority: Isolate.immediate);
  }

  void _send((String, int, List<int>) command) => _commands?.send(command);

  @override
  String get version => _version;

  @override
  void update() {}

  @override
  List<SdlDevice> devices() => _frame.devices;

  @override
  bool open(SdlDevice device) => _frame.open.containsKey(device.instance);

  @override
  void close(int instance) {}

  @override
  SdlReading? read(int instance) => _frame.open[instance]?.reading;

  @override
  bool hasRumble(int instance) => _frame.open[instance]?.hasRumble ?? false;

  @override
  bool rumble(int instance, int low, int high, int milliseconds) {
    if (!_frame.open.containsKey(instance)) return false;
    _send(('rumble', instance, [low, high, milliseconds]));
    return true;
  }

  @override
  bool hasLed(int instance) => _frame.open[instance]?.hasLed ?? false;

  @override
  bool setLed(int instance, int red, int green, int blue) {
    if (!hasLed(instance)) return false;
    _send(('led', instance, [red, green, blue]));
    return true;
  }

  @override
  void setPlayerIndex(int instance, int player) {
    if (_frame.open.containsKey(instance)) _send(('player', instance, [player]));
  }

  @override
  String? serial(int instance) => _frame.open[instance]?.serial;

  @override
  void quit() {
    if (_done) return;
    // The worker closes the pads and SDL, then ends; one stuck in an open never reads this,
    // and nothing waits for it.
    _commands?.send('quit');
    _done = true;
    _watch?.cancel();
    _replies.close();
    _frame = SdlFrame.empty;
  }
}
