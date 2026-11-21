import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../controllers/pad_info.dart';
import '../controllers/pad_inventory.dart';
import 'feel.dart';
import 'linux_input_class.dart';
import 'pad_navigation.dart';

typedef _OpenNative = Int32 Function(Pointer<Utf8> path, Int32 flags);
typedef _Open = int Function(Pointer<Utf8> path, int flags);
typedef _IoctlNative = Int32 Function(Int32 fd, UnsignedLong request, VarArgs<(Pointer<Void>,)>);
typedef _Ioctl = int Function(int fd, int request, Pointer<Void> argument);
typedef _CloseNative = Int32 Function(Int32 fd);
typedef _Close = int Function(int fd);
typedef _WriteNative = IntPtr Function(Int32 fd, Pointer<Uint8> buffer, IntPtr count);
typedef _Write = int Function(int fd, Pointer<Uint8> buffer, int count);

/// A controller the kernel lists: its event node and what it is.
class LinuxPadDevice {
  const LinuxPadDevice({
    required this.event,
    required this.name,
    required this.vendor,
    this.product = 0,
    this.bus = 0,
    this.properties = '',
    this.keys = '',
    this.axes = '',
  });

  /// event5 for /dev/input/event5.
  final String event;
  final String name;
  final int vendor;
  final int product;

  /// The kernel's bus number: 0x03 USB, 0x05 Bluetooth.
  final int bus;

  /// Its B: PROP=, KEY= and ABS= bitmaps, for [LinuxInputClass] (empty where the block has none).
  final String properties;
  final String keys;
  final String axes;

  /// Microsoft's pads, whose X and Y the xpad driver reports swapped.
  bool get xbox => vendor == 0x045E;

  /// Why this is no controller (an accelerometer, say), null when it is one; [udev] is its udev
  /// database entry.
  String? skipReason({String? udev}) =>
      LinuxInputClass.skipReason(name: name, properties: properties, keys: keys, axes: axes, udev: udev);
}

/// What opening a node found, from its own isolate ([EvdevProbe.run]).
class EvdevProbe {
  const EvdevProbe({required this.readable, this.ranges, this.rumbleFd = -1, this.rumbleId = -1});

  /// The node opened for reading.
  final bool readable;

  /// The left stick's range (EVIOCGABS), null when the kernel could not be asked.
  final Map<int, (int, int)>? ranges;

  /// The node opened for writing with a silent rumble uploaded; -1 when it has no rumble or the
  /// user may not write it.
  final int rumbleFd;
  final int rumbleId;

  /// Opens [path] (and closes it again), asks its stick range and opens it for its motors. Runs
  /// in an isolate of its own: an open the driver never returns from (issue #195) then holds
  /// that isolate's thread, never the launcher's.
  static EvdevProbe run(String path) {
    final ranges = LinuxPadSource._ranges(path);
    if (ranges == null) return const EvdevProbe(readable: false);
    final rumble = EvdevRumbler.openFd(path);
    return EvdevProbe(readable: true, ranges: ranges, rumbleFd: rumble?.$1 ?? -1, rumbleId: rumble?.$2 ?? -1);
  }
}

/// Controllers on Linux through evdev: every input device the kernel gives a joystick handler
/// (js*) is read from its /dev/input/event* node (the logged-in user may read them on desktop
/// systems), one found later is picked up within two seconds, one unplugged is let go. A pad
/// with force feedback (FF_RUMBLE) gives the launcher's pulses through the same node opened for
/// writing; one without, or a node the user may not write, stays still.
///
/// A device that is no controller (an accelerometer with a js node, as HP's lis3lv02d) is left
/// alone, told from what the kernel and udev list ([LinuxInputClass]). Every other node is first
/// opened in an isolate of its own ([EvdevProbe]): one whose open does not come back within
/// [probeTimeout] is "not answering", and is not tried again while that open is still out.
class LinuxPadSource implements PadSource, PadRumble, PadInventory {
  LinuxPadSource({
    this.devicesFile = '/proc/bus/input/devices',
    this.inputFolder = '/dev/input',
    this.sysClass = '/sys/class/input',
    this.udevData = '/run/udev/data',
    Future<EvdevProbe> Function(String path)? probe,
    this.probeTimeout = const Duration(seconds: 3),
  }) : _probe = probe ?? ((path) => Isolate.run(() => EvdevProbe.run(path)));

  final String devicesFile;
  final String inputFolder;
  final String sysClass;
  final String udevData;
  final Future<EvdevProbe> Function(String path) _probe;
  final Duration probeTimeout;

  final Map<String, StreamSubscription<List<int>>> _reading = {};
  final Set<String> _refused = {};
  final Map<String, LinuxPadDevice> _devices = {};

  /// Devices with a js node that are no controller, by event node: why ("accelerometer").
  final Map<String, String> _skipped = {};

  /// Nodes whose open (in its isolate) has not come back yet, and those of them past
  /// [probeTimeout].
  final Set<String> _probing = {};
  final Set<String> _stuck = {};
  bool _stopped = false;
  final PadEventStates _states = PadEventStates();
  void Function()? _changed;
  Timer? _timer;
  void Function(PadEvent)? _onEvent;
  String _description = 'not started';

  @override
  String get description => _description;

  /// The controllers in /proc/bus/input/devices' text: blocks whose handlers have a js node.
  static List<LinuxPadDevice> parseDevices(String text) {
    final found = <LinuxPadDevice>[];
    for (final block in text.split(RegExp(r'\n\s*\n'))) {
      final handlers = RegExp(r'^H: Handlers=(.*)$', multiLine: true).firstMatch(block)?.group(1) ?? '';
      final names = handlers.split(RegExp(r'\s+'));
      final event = names.where((name) => RegExp(r'^event\d+$').hasMatch(name)).firstOrNull;
      if (event == null || !names.any((name) => RegExp(r'^js\d+$').hasMatch(name))) continue;
      final name = RegExp(r'^N: Name="(.*)"$', multiLine: true).firstMatch(block)?.group(1) ?? event;
      int number(String field) => int.tryParse(RegExp('$field=([0-9a-fA-F]{4})').firstMatch(block)?.group(1) ?? '', radix: 16) ?? 0;
      String bitmap(String field) => RegExp('^B: $field=(.*)\$', multiLine: true).firstMatch(block)?.group(1)?.trim() ?? '';
      found.add(LinuxPadDevice(
        event: event,
        name: name,
        vendor: number('Vendor'),
        product: number('Product'),
        bus: number('Bus'),
        properties: bitmap('PROP'),
        keys: bitmap('KEY'),
        axes: bitmap('ABS'),
      ));
    }
    return found;
  }

  /// The devices with a js node in [devicesFile], split into controllers and the rest (by event
  /// node, why each is left out). Nothing here opens a device.
  static (List<LinuxPadDevice>, Map<String, String>) controllers({
    String devicesFile = '/proc/bus/input/devices',
    String sysClass = '/sys/class/input',
    String udevData = '/run/udev/data',
  }) {
    final pads = <LinuxPadDevice>[];
    final skipped = <String, String>{};
    for (final device in parseDevices(File(devicesFile).readAsStringSync())) {
      final reason = device.skipReason(udev: LinuxInputClass.udevEntry(device.event, sysClass: sysClass, udevData: udevData));
      reason == null ? pads.add(device) : skipped[device.event] = '${device.name} ($reason)';
    }
    return (pads, skipped);
  }

  @override
  void start(void Function(PadEvent event) onEvent) {
    if (_timer != null) return;
    _onEvent = onEvent;
    _stopped = false;
    scanNow();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => scanNow());
  }

  /// Looks at the kernel's list now (the timer does every two seconds; tests call it).
  void scanNow() {
    List<LinuxPadDevice> devices;
    try {
      final (pads, skipped) = controllers(devicesFile: devicesFile, sysClass: sysClass, udevData: udevData);
      devices = pads;
      _skipped
        ..clear()
        ..addAll(skipped);
    } on FileSystemException {
      devices = const [];
    }
    final listed = {for (final device in devices) device.event};
    // A node refused and gone: tried again when it comes back. One not answering stays so
    // while its open is still out, gone or not: a second open would hang the same way.
    _refused.retainWhere(listed.contains);
    _stuck.retainWhere((event) => listed.contains(event) || _probing.contains(event));
    _devices
      ..removeWhere((event, _) => !listed.contains(event))
      ..addAll({for (final device in devices) device.event: device});
    for (final device in devices) {
      final event = device.event;
      if (_reading.containsKey(event) || _refused.contains(event) || _probing.contains(event) || _stuck.contains(event)) {
        continue;
      }
      unawaited(_open(device));
    }
    _describe();
  }

  void _describe() {
    _description = [
      for (final device in _devices.values)
        '${device.name} (${_reading.containsKey(device.event) ? 'read' : _stuck.contains(device.event) ? 'not answering' : _probing.contains(device.event) ? 'opening' : 'no permission'})',
      for (final skipped in _skipped.values) '$skipped: left alone',
    ].join(', ');
  }

  Future<void> _open(LinuxPadDevice device) async {
    final event = device.event;
    final path = '$inputFolder/$event';
    _probing.add(event);
    final opening = _probe(path);
    EvdevProbe probe;
    try {
      probe = await opening.timeout(probeTimeout);
    } on TimeoutException {
      // The open hangs in the kernel: this node is not tried again while it does.
      _stuck.add(event);
      _describe();
      _changed?.call();
      unawaited(opening.then((result) {
        _probing.remove(event);
        _release(result);
      }, onError: (Object _) => _probing.remove(event)));
      return;
    } on Object {
      probe = const EvdevProbe(readable: false);
    }
    _probing.remove(event);
    if (_stopped || !_devices.containsKey(event) || _reading.containsKey(event)) {
      _release(probe);
      return;
    }
    if (!probe.readable) {
      _refused.add(event);
      _describe();
      _changed?.call();
      return;
    }
    final decoder = EvdevDecoder(event, xbox: device.xbox, ranges: probe.ranges);
    try {
      _reading[event] = File(path).openRead().listen(
        (chunk) {
          for (final padEvent in decoder.add(chunk)) {
            _states.add(padEvent);
            _onEvent?.call(padEvent);
          }
        },
        onError: (Object _) => _close(event, refused: true),
        onDone: () => _close(event),
        cancelOnError: true,
      );
      if (probe.rumbleFd >= 0) _rumblers[event] = EvdevRumbler.adopt(probe.rumbleFd, probe.rumbleId);
    } on FileSystemException {
      _release(probe);
      _refused.add(event);
    }
    _describe();
    _changed?.call();
  }

  /// A probe's motors node no one will use: closed, in an isolate of its own as it was opened.
  static void _release(EvdevProbe probe) {
    final fd = probe.rumbleFd;
    if (fd >= 0) unawaited(Isolate.run(() => EvdevRumbler.closeFd(fd)).then((_) {}, onError: (Object _) {}));
  }

  void _close(String event, {bool refused = false}) {
    unawaited(_reading.remove(event)?.cancel());
    _rumblers.remove(event)?.close();
    // A node that could not be read is not tried again until it goes away and comes back.
    if (refused && File('$inputFolder/$event').existsSync()) _refused.add(event);
    _states.add(PadGone(event));
    _onEvent?.call(PadGone(event));
    _describe();
    _changed?.call();
  }

  // PadInventory: what evdev can tell.

  @override
  List<PadInfo> get pads => [
    for (final event in _reading.keys)
      if (_devices[event] case final device?)
        PadInfo(
          id: event,
          name: device.name,
          kind: PadKind.classify(vendor: device.vendor, product: device.product, name: device.name),
          connection: device.bus == 0x05 ? PadConnection.bluetooth : device.bus == 0x03 ? PadConnection.usb : PadConnection.unknown,
          driver: 'evdev',
          vendor: device.vendor,
          product: device.product,
        ),
  ];

  @override
  set onPadsChanged(void Function()? listener) => _changed = listener;

  @override
  PadState? state(String id) => _states[id] ?? (_reading.containsKey(id) ? PadState.idle : null);

  @override
  bool setLight(String id, int red, int green, int blue) => false;

  @override
  void setPlayerLights(List<String> ordered) {}

  @override
  String get readerName => 'evdev';

  @override
  List<String> get refused => [for (final event in _refused) _devices[event]?.name ?? event];

  /// Devices left alone because they are no controller: "ST LIS3LV02DL Accelerometer (accelerometer)".
  List<String> get skipped => _skipped.values.toList();

  /// Controllers whose open has not come back: their names.
  List<String> get notAnswering => [for (final event in _stuck) _devices[event]?.name ?? event];

  /// The left stick's range (EVIOCGABS on ABS_X and ABS_Y), null when the node cannot be opened.
  /// Opens the device: called from [EvdevProbe.run]'s isolate only.
  static Map<int, (int, int)>? _ranges(String path) {
    try {
      final libc = DynamicLibrary.process();
      final open = libc.lookupFunction<_OpenNative, _Open>('open');
      final ioctl = libc.lookupFunction<_IoctlNative, _Ioctl>('ioctl');
      final close = libc.lookupFunction<_CloseNative, _Close>('close');
      return using((arena) {
        final fd = open(path.toNativeUtf8(allocator: arena), 0x80000 /* O_RDONLY | O_CLOEXEC */);
        if (fd < 0) return null;
        try {
          final info = arena<Int32>(6);
          final ranges = <int, (int, int)>{};
          for (final axis in [0, 1]) {
            // EVIOCGABS(axis) = _IOR('E', 0x40 + axis, struct input_absinfo): value, minimum, maximum...
            if (ioctl(fd, 0x80184540 + axis, info.cast()) == 0) ranges[axis] = (info[1], info[2]);
          }
          return ranges;
        } finally {
          close(fd);
        }
      });
    } on Object {
      return null;
    }
  }

  /// Each pad's force feedback, opened with the pad ([EvdevProbe]); absent where it has none.
  final Map<String, EvdevRumbler> _rumblers = {};

  @override
  PadRumble? get motors => this;

  @override
  bool canRumble(String pad) => _reading.containsKey(pad) && _rumblers.containsKey(pad);

  @override
  void rumble(String pad, double strong, double weak, Duration length) {
    if (!canRumble(pad)) return;
    _rumblers[pad]?.rumble(strong, weak, length);
  }

  @override
  void stop() {
    // Opens still out are not waited for: what they bring back is let go ([_open]).
    _stopped = true;
    _timer?.cancel();
    _timer = null;
    for (final rumbler in _rumblers.values) {
      rumbler.close();
    }
    _rumblers.clear();
    for (final subscription in _reading.values) {
      unawaited(subscription.cancel());
    }
    _reading.clear();
  }
}

/// Force feedback through an evdev node: one FF_RUMBLE effect uploaded (EVIOCSFF) and played by
/// writing an EV_FF event; the kernel stops it after its own length, and a pulse of zero stops it
/// at once.
class EvdevRumbler {
  EvdevRumbler._(this._fd, this._id, this._write, this._ioctl, this._closeFd);

  final int _fd;
  int _id;
  final _Write _write;
  final _Ioctl _ioctl;
  final _Close _closeFd;
  bool _closed = false;

  /// EVIOCSFF: _IOW('E', 0x80, struct ff_effect), 48 bytes on 64-bit systems.
  static const uploadRequest = 0x40304580;
  static const effectSize = 48;
  static const _rumbleType = 0x50; // FF_RUMBLE
  static const _forceFeedback = 0x15; // EV_FF

  /// struct ff_effect for a rumble: type, id (-1 asks for a new one), the replay's length in
  /// ms, then the strong and weak magnitudes at offset 16.
  static Uint8List effect(int id, double strong, double weak, Duration length) {
    final bytes = ByteData(effectSize);
    bytes.setUint16(0, _rumbleType, Endian.little);
    bytes.setInt16(2, id, Endian.little);
    bytes.setUint16(10, length.inMilliseconds.clamp(0, 0xFFFF), Endian.little);
    bytes.setUint16(16, (strong.clamp(0.0, 1.0) * 0xFFFF).round(), Endian.little);
    bytes.setUint16(18, (weak.clamp(0.0, 1.0) * 0xFFFF).round(), Endian.little);
    return bytes.buffer.asUint8List();
  }

  /// struct input_event that plays (1) or stops (0) effect [id].
  static Uint8List playEvent(int id, {required bool play}) {
    final bytes = ByteData(EvdevDecoder.size);
    bytes.setUint16(16, _forceFeedback, Endian.little);
    bytes.setUint16(18, id, Endian.little);
    bytes.setInt32(20, play ? 1 : 0, Endian.little);
    return bytes.buffer.asUint8List();
  }

  /// Opens [path] for writing and uploads a silent rumble: the descriptor and the effect's id,
  /// null when the node cannot be written or the pad has no rumble. Opens the device: called from
  /// [EvdevProbe.run]'s isolate only.
  static (int, int)? openFd(String path) {
    try {
      final libc = DynamicLibrary.process();
      final openFd = libc.lookupFunction<_OpenNative, _Open>('open');
      final ioctl = libc.lookupFunction<_IoctlNative, _Ioctl>('ioctl');
      final close = libc.lookupFunction<_CloseNative, _Close>('close');
      final fd = using((arena) => openFd(path.toNativeUtf8(allocator: arena), 2 | 0x800 | 0x80000 /* O_RDWR | O_NONBLOCK | O_CLOEXEC */));
      if (fd < 0) return null;
      final id = _upload(ioctl, fd, -1, 0, 0, Duration.zero);
      if (id == null) {
        close(fd);
        return null;
      }
      return (fd, id);
    } on Object {
      return null;
    }
  }

  /// A descriptor [openFd] gave, with its effect [id], driven from here on.
  factory EvdevRumbler.adopt(int fd, int id) {
    final libc = DynamicLibrary.process();
    return EvdevRumbler._(
      fd,
      id,
      libc.lookupFunction<_WriteNative, _Write>('write'),
      libc.lookupFunction<_IoctlNative, _Ioctl>('ioctl'),
      libc.lookupFunction<_CloseNative, _Close>('close'),
    );
  }

  /// Closes a descriptor [openFd] gave that no one took.
  static void closeFd(int fd) {
    try {
      DynamicLibrary.process().lookupFunction<_CloseNative, _Close>('close')(fd);
    } on Object {
      // Nothing more to do.
    }
  }

  static int? _upload(_Ioctl ioctl, int fd, int id, double strong, double weak, Duration length) => using((arena) {
    final buffer = arena<Uint8>(effectSize);
    buffer.asTypedList(effectSize).setAll(0, effect(id, strong, weak, length));
    if (ioctl(fd, uploadRequest, buffer.cast()) != 0) return null;
    return ByteData.sublistView(buffer.asTypedList(effectSize)).getInt16(2, Endian.little);
  });

  void rumble(double strong, double weak, Duration length) {
    if (_closed) return;
    final play = (strong > 0 || weak > 0) && length > Duration.zero;
    if (play) {
      final id = _upload(_ioctl, _fd, _id, strong, weak, length);
      if (id == null) return;
      _id = id;
    }
    using((arena) {
      final event = playEvent(_id, play: play);
      final buffer = arena<Uint8>(event.length);
      buffer.asTypedList(event.length).setAll(0, event);
      _write(_fd, buffer, event.length);
    });
  }

  void close() {
    if (_closed) return;
    rumble(0, 0, Duration.zero);
    _closed = true;
    _closeFd(_fd);
  }
}

/// struct input_event (64-bit: a 16-byte time, then type, code and value) as pad events.
class EvdevDecoder {
  EvdevDecoder(this.pad, {this.xbox = false, Map<int, (int, int)>? ranges}) : _ranges = {...?ranges};

  final String pad;
  final bool xbox;
  final Map<int, (int, int)> _ranges;
  final BytesBuilder _pending = BytesBuilder();

  static const size = 24;
  static const _key = 1;
  static const _absolute = 3;

  List<PadEvent> add(List<int> chunk) {
    _pending.add(chunk);
    final bytes = _pending.takeBytes();
    final whole = bytes.length - bytes.length % size;
    if (whole < bytes.length) _pending.add(bytes.sublist(whole));
    final data = ByteData.sublistView(bytes);
    final events = <PadEvent>[];
    for (var offset = 0; offset < whole; offset += size) {
      final type = data.getUint16(offset + 16, Endian.little);
      final code = data.getUint16(offset + 18, Endian.little);
      final value = data.getInt32(offset + 20, Endian.little);
      events.addAll(decode(type, code, value));
    }
    return events;
  }

  /// One event: a key (a value of 2 is the key repeating, not a press), or the left stick or the
  /// hat (a D-pad reported as an axis).
  List<PadEvent> decode(int type, int code, int value) {
    if (type == _key && value != 2) {
      final button = PadMaps.evdevKey(code, xbox: xbox);
      return button == null ? const [] : [PadButtonEvent(pad, button, down: value != 0)];
    }
    if (type != _absolute) return const [];
    switch (code) {
      case 0 || 1:
        final (minimum, maximum) = _ranges[code] ?? _guess(value);
        final scaled = PadMaps.scale(value, minimum, maximum);
        return [PadAxisEvent(pad, code == 0 ? PadAxis.leftX : PadAxis.leftY, scaled.abs() < 0.12 ? 0 : scaled)];
      case 0x10 || 0x11:
        final (negative, positive) = code == 0x10
            ? (PadButton.dpadLeft, PadButton.dpadRight)
            : (PadButton.dpadUp, PadButton.dpadDown);
        return [PadButtonEvent(pad, negative, down: value < 0), PadButtonEvent(pad, positive, down: value > 0)];
    }
    return const [];
  }

  bool _signed = false;

  /// Without the kernel's range: a stick seen outside 0 to 255 is signed 16-bit from then on.
  (int, int) _guess(int value) {
    if (value < 0 || value > 255) _signed = true;
    return _signed ? (-32768, 32767) : (0, 255);
  }
}
