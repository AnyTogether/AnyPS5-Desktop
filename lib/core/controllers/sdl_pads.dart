import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../gamepad/feel.dart';
import '../gamepad/pad_navigation.dart';
import 'pad_batteries.dart';
import 'pad_info.dart';
import 'pad_inventory.dart';
import 'sdl_maps.dart';

/// One joystick SDL lists, before it is opened.
class SdlDevice {
  const SdlDevice({
    required this.instance,
    required this.index,
    required this.gameController,
    required this.name,
    this.type = 0,
    this.guid = const [],
    this.vendor = 0,
    this.product = 0,
    this.virtual = false,
  });

  /// SDL's instance id: stays with the device while it is connected.
  final int instance;

  /// Its place in SDL's list now (for opening it).
  final int index;

  /// SDL has a game controller mapping for it (else it is a plain joystick the launcher lists
  /// but cannot read as a pad).
  final bool gameController;
  final String name;
  final int type;
  final List<int> guid;
  final int vendor;
  final int product;
  final bool virtual;
}

/// One opened controller's reading: the SDL buttons held, the six axes, the power level.
class SdlReading {
  const SdlReading({required this.held, required this.axes, this.powerLevel = -1});
  final Set<int> held;
  final List<int> axes;
  final int powerLevel;
}

/// The calls the reader makes into SDL2: the library itself (SdlLibrary) or a fake in tests.
abstract class SdlBackend {
  /// "2.32.10".
  String get version;

  /// Lets SDL look for devices and read the opened ones (SDL_GameControllerUpdate).
  void update();
  List<SdlDevice> devices();
  bool open(SdlDevice device);
  void close(int instance);
  SdlReading? read(int instance);
  bool hasRumble(int instance);
  bool rumble(int instance, int low, int high, int milliseconds);
  bool hasLed(int instance);
  bool setLed(int instance, int red, int green, int blue);
  void setPlayerIndex(int instance, int player);

  /// The opened pad's serial (a PlayStation pad's Bluetooth address), null when SDL has none.
  String? serial(int instance);
  void quit();
}

/// Controllers through SDL2's game controller API, the library the engine reads pads with too:
/// DualSense and DualShock 4 over USB and Bluetooth through HIDAPI (with their motors, light
/// bars and player lights), Xbox pads through XInput or Windows.Gaming.Input, Switch Pro, 8BitDo
/// and every pad SDL's mapping database knows, DualShock 3 on Linux (and on Windows where a
/// driver such as DsHidMini shows it). Polled 60 times a second; a pad plugged in or paired at
/// any time is opened within a frame or two, one that goes is let go (PadGone). Launched from
/// Steam, Steam's virtual pad stands for the real one; with DS4Windows or DualSenseX running, the
/// real PlayStation pad wins over the virtual Xbox pad made of it ([PadDuplicates]).
class SdlPadSource implements PadSource, PadRumble, PadInventory {
  SdlPadSource(
    this.backend, {
    this.every = const Duration(milliseconds: 16),
    this.steam = false,
    bool Function()? remapperRunning,
    this.platformDriver = 'SDL',
    this.steamTookOver,
    this.batteries,
  }) : _remapper = remapperRunning ?? (() => false);

  /// The system's battery percentages, where SDL2 gives only four levels; null: the levels.
  final PadBatteryProbe? batteries;

  /// A pad's battery: the system's percentage where it has one, else SDL2's level.
  PadBattery? _battery(int instance, int level, {int? vendor, int? product}) {
    try {
      final measured = batteries?.battery(vendor: vendor, product: product, serial: backend.serial(instance));
      if (measured != null) return measured;
    } on Object {
      // The level, then.
    }
    return SdlMaps.battery(level);
  }

  /// The controllers Steam Input took over, left to its virtual pad (SteamLaunch.skipPhysicalPad).
  final bool Function(int vendor, int product)? steamTookOver;

  final SdlBackend backend;
  final Duration every;

  /// Launched from Steam: its virtual pads stand for the real ones.
  final bool steam;
  final bool Function() _remapper;

  /// The driver name for a pad SDL reads through the system's joystick API ('SDL evdev').
  final String platformDriver;

  Timer? _timer;
  void Function(PadEvent)? _onEvent;
  void Function()? _changed;

  /// Opened pads by SDL instance id, with what the launcher knows of each.
  final Map<int, PadInfo> _open = {};
  final Map<int, PadState> _states = {};
  final Map<int, PadSnapshot> _last = {};

  /// Devices SDL lists that it has no mapping for, by instance: listed in the troubleshooter.
  final Map<int, String> _unmapped = {};
  List<PadInfo> _visible = const [];
  int _batteryTick = 0;

  /// Reads the pads now (tests drive this; the timer calls it 60 times a second).
  void poll() {
    try {
      backend.update();
      _sync();
      _read();
    } on Object {
      // A reader that fails stays quiet; the keyboard still works.
    }
  }

  @override
  void start(void Function(PadEvent event) onEvent) {
    if (_timer != null) return;
    _onEvent = onEvent;
    poll();
    _timer = Timer.periodic(every, (_) => poll());
  }

  static String _id(int instance) => 'sdl$instance';

  static int? _instance(String id) => id.startsWith('sdl') ? int.tryParse(id.substring(3)) : null;

  void _sync() {
    final devices = backend.devices();
    final present = {for (final device in devices) device.instance};
    var changed = false;
    for (final instance in [..._open.keys]) {
      if (present.contains(instance)) continue;
      _gone(instance);
      changed = true;
    }
    _unmapped.removeWhere((instance, _) => !present.contains(instance));
    for (final device in devices) {
      if (_open.containsKey(device.instance)) continue;
      if (!device.gameController) {
        _unmapped[device.instance] = device.name;
        continue;
      }
      if (!backend.open(device)) continue;
      final numbers = SdlMaps.usbNumbers(device.guid);
      final vendor = device.vendor != 0 ? device.vendor : numbers?.$1;
      final product = device.product != 0 ? device.product : numbers?.$2;
      final reading = backend.read(device.instance);
      final driver = SdlMaps.driver(device.guid);
      _open[device.instance] = PadInfo(
        id: _id(device.instance),
        name: device.name,
        kind: SdlMaps.kind(device.type, vendor: vendor, product: product, name: device.name),
        connection: SdlMaps.connection(device.guid, powerLevel: reading?.powerLevel ?? -1),
        battery: _battery(device.instance, reading?.powerLevel ?? -1, vendor: vendor, product: product),
        driver: driver == 'SDL' ? platformDriver : driver,
        vendor: vendor,
        product: product,
        hasRumble: backend.hasRumble(device.instance),
        hasLight: backend.hasLed(device.instance),
        virtual: device.virtual || driver == 'SDL virtual' || PadDuplicates.isSteamVirtual(
          PadInfo(id: '', name: device.name, kind: PadKind.xbox, driver: '', vendor: vendor, product: product),
        ),
      );
      changed = true;
    }
    // Batteries move slowly: asked about once a second.
    if (++_batteryTick >= 60) {
      _batteryTick = 0;
      for (final entry in _open.entries.toList()) {
        final level = backend.read(entry.key)?.powerLevel ?? -1;
        final battery = _battery(entry.key, level, vendor: entry.value.vendor, product: entry.value.product);
        final connection = entry.value.connection == PadConnection.unknown && level == 4 ? PadConnection.usb : entry.value.connection;
        if (battery != entry.value.battery || connection != entry.value.connection) {
          _open[entry.key] = entry.value.copyWith(battery: battery, clearBattery: battery == null, connection: connection);
          changed = true;
        }
      }
    }
    final visible = PadDuplicates.visible(_open.values.toList(), steam: steam, remapper: _remapper(), steamTookOver: steamTookOver);
    if (changed || visible.length != _visible.length) {
      // A pad hidden as a duplicate lets go of what it held.
      for (final pad in _visible) {
        if (!visible.any((shown) => shown.id == pad.id)) _release(pad.id);
      }
      _visible = visible;
      _changed?.call();
    }
  }

  void _read() {
    for (final pad in _visible) {
      final instance = _instance(pad.id)!;
      final reading = backend.read(instance);
      if (reading == null) continue;
      final state = SdlMaps.state(reading.held, reading.axes);
      _states[instance] = state;
      final now = PadSnapshot(state.pressed, x: _dead(state.leftX), y: _dead(state.leftY));
      final before = _last[instance] ?? PadSnapshot.idle;
      _last[instance] = now;
      for (final event in PadSnapshot.diff(pad.id, before, now)) {
        _onEvent?.call(event);
      }
    }
  }

  /// A resting stick is rarely at exactly its middle.
  static double _dead(double value) => value.abs() < 0.12 ? 0 : value;

  void _release(String id) {
    final instance = _instance(id);
    if (instance != null && _last.remove(instance) != null) _onEvent?.call(PadGone(id));
  }

  void _gone(int instance) {
    _open.remove(instance);
    _states.remove(instance);
    backend.close(instance);
    _last.remove(instance);
    _onEvent?.call(PadGone(_id(instance)));
  }

  // PadSource

  @override
  String get description => 'SDL ${backend.version}: ${[for (final pad in _visible) pad.reportLine].join(', ')}';

  @override
  PadRumble? get motors => this;

  @override
  void stop() {
    _timer?.cancel();
    _timer = null;
    for (final instance in [..._open.keys]) {
      backend.rumble(instance, 0, 0, 0);
      backend.close(instance);
    }
    _open.clear();
    _visible = const [];
    batteries?.dispose();
    backend.quit();
  }

  // PadRumble

  @override
  bool canRumble(String pad) {
    final instance = _instance(pad);
    return instance != null && (_open[instance]?.hasRumble ?? false);
  }

  @override
  void rumble(String pad, double strong, double weak, Duration length) {
    final instance = _instance(pad);
    if (instance == null || !_open.containsKey(instance)) return;
    final (low, high) = XInputRumbleSpeeds.speeds(strong, weak);
    // SDL stops the motors itself after the length; a zero is "stop now".
    backend.rumble(instance, low, high, length == Duration.zero ? 0 : length.inMilliseconds + 20);
  }

  // PadInventory

  @override
  List<PadInfo> get pads => List.unmodifiable(_visible);

  @override
  set onPadsChanged(void Function()? listener) => _changed = listener;

  @override
  PadState? state(String id) {
    final instance = _instance(id);
    return instance == null ? null : _states[instance];
  }

  @override
  bool setLight(String id, int red, int green, int blue) {
    final instance = _instance(id);
    if (instance == null || !(_open[instance]?.hasLight ?? false)) return false;
    return backend.setLed(instance, red, green, blue);
  }

  @override
  void setPlayerLights(List<String> ordered) {
    for (final (index, id) in ordered.indexed) {
      final instance = _instance(id);
      if (instance != null && _open.containsKey(instance)) backend.setPlayerIndex(instance, index);
    }
  }

  @override
  String get readerName => 'SDL ${backend.version}';

  @override
  List<String> get refused => const [];

  /// Joysticks SDL lists without a game controller mapping.
  List<String> get unmapped => _unmapped.values.toList();
}

/// The motor speeds SDL and XInput take (0 to 65535): the heavy low motor, the light high one.
abstract final class XInputRumbleSpeeds {
  static (int, int) speeds(double strong, double weak) =>
      ((strong.clamp(0.0, 1.0) * 65535).round(), (weak.clamp(0.0, 1.0) * 65535).round());
}

// --- SDL2 through dart:ffi -------------------------------------------------------------------

final class _SdlGuid extends Struct {
  @Array(16)
  external Array<Uint8> data;
}

final class _SdlVersion extends Struct {
  @Uint8()
  external int major;
  @Uint8()
  external int minor;
  @Uint8()
  external int patch;
}

/// SDL2 loaded from the launcher's folder (SDL2.dll beside the executable on Windows, lib/ in
/// the Linux bundle) or, on Linux, the system's libSDL2-2.0.so.0. Only the game controller and
/// joystick subsystems: no window, no video, no sound, no signal handlers.
class SdlLibrary implements SdlBackend {
  SdlLibrary._(this._library);

  final DynamicLibrary _library;
  final Map<int, Pointer<Void>> _controllers = {};
  late final String _version;
  late final int Function(int) _init;
  late final void Function() _quit;
  late final int Function(Pointer<Utf8>, Pointer<Utf8>) _setHint;
  late final void Function() _controllerUpdate;
  late final int Function() _numJoysticks;
  late final int Function(int) _instanceForIndex;
  late final int Function(int) _isGameController;
  late final Pointer<Utf8> Function(int) _nameForIndex;
  late final Pointer<Utf8> Function(int) _joystickNameForIndex;
  late final int Function(int) _typeForIndex;
  late final _SdlGuid Function(int) _guidForIndex;
  late final int Function(int) _vendorForIndex;
  late final int Function(int) _productForIndex;
  late final int Function(int) _isVirtual;
  late final Pointer<Void> Function(int) _open;
  late final void Function(Pointer<Void>) _close;
  late final int Function(Pointer<Void>, int) _button;
  late final int Function(Pointer<Void>, int) _axis;
  late final Pointer<Void> Function(Pointer<Void>) _joystick;
  late final int Function(Pointer<Void>) _power;
  late final int Function(Pointer<Void>, int, int, int) _rumble;
  late final int Function(Pointer<Void>)? _hasRumble;
  late final int Function(Pointer<Void>)? _hasLed;
  late final int Function(Pointer<Void>, int, int, int)? _setLed;
  late final void Function(Pointer<Void>, int) _setPlayer;
  late final Pointer<Utf8> Function(Pointer<Void>)? _serial;
  late final int Function(int) _eventState;
  late final int Function(int) _joystickEventState;

  static const _initJoystick = 0x00000200;
  static const _initGameController = 0x00002000;

  /// Where SDL2 is looked for, in order.
  static List<String> candidates({String? executable, bool? windows}) {
    final onWindows = windows ?? Platform.isWindows;
    final path = executable ?? Platform.resolvedExecutable;
    final separator = onWindows ? r'\' : '/';
    final cut = onWindows ? path.lastIndexOf(RegExp(r'[\\/]')) : path.lastIndexOf('/');
    final folder = cut < 0 ? '.' : path.substring(0, cut);
    return onWindows
        ? ['$folder${separator}SDL2.dll', 'SDL2.dll']
        : ['$folder${separator}lib${separator}libSDL2-2.0.so.0', 'libSDL2-2.0.so.0', 'libSDL2.so'];
  }

  /// The first of [paths] (else [candidates]) the system's loader opens, without starting
  /// anything in it: SDL2's subsystems, which look for devices, are then started where an open
  /// that hangs holds up nothing ([SdlIsolateBackend]). Null (and why, in [failure]) when none
  /// loads.
  static String? locate({List<String>? paths, void Function(String why)? failure}) {
    for (final path in paths ?? candidates()) {
      try {
        DynamicLibrary.open(path);
        return path;
      } on Object {
        continue;
      }
    }
    failure?.call('SDL2 not found: ${(paths ?? candidates()).join(', ')}');
    return null;
  }

  /// SDL2 loaded and its controller subsystem started; null (and why, in [failure]) when the
  /// library is missing or will not start: the launcher then reads pads its older way.
  static SdlLibrary? load({List<String>? paths, void Function(String why)? failure}) {
    DynamicLibrary? library;
    for (final path in paths ?? candidates()) {
      try {
        library = DynamicLibrary.open(path);
        break;
      } on Object {
        continue;
      }
    }
    if (library == null) {
      // The paths only: the system's loader errors are long and say the same.
      failure?.call('SDL2 not found: ${(paths ?? candidates()).join(', ')}');
      return null;
    }
    try {
      final sdl = SdlLibrary._(library).._bind();
      final started = sdl._start();
      if (started != null) {
        failure?.call(started);
        return null;
      }
      return sdl;
    } on Object catch (error) {
      failure?.call('SDL2 could not be used: $error');
      return null;
    }
  }

  void _bind() {
    final l = _library;
    _init = l.lookupFunction<Int32 Function(Uint32), int Function(int)>('SDL_InitSubSystem');
    _quit = l.lookupFunction<Void Function(), void Function()>('SDL_Quit');
    _setHint = l.lookupFunction<Int32 Function(Pointer<Utf8>, Pointer<Utf8>), int Function(Pointer<Utf8>, Pointer<Utf8>)>('SDL_SetHint');
    _controllerUpdate = l.lookupFunction<Void Function(), void Function()>('SDL_GameControllerUpdate');
    _numJoysticks = l.lookupFunction<Int32 Function(), int Function()>('SDL_NumJoysticks');
    _instanceForIndex = l.lookupFunction<Int32 Function(Int32), int Function(int)>('SDL_JoystickGetDeviceInstanceID');
    _isGameController = l.lookupFunction<Int32 Function(Int32), int Function(int)>('SDL_IsGameController');
    _nameForIndex = l.lookupFunction<Pointer<Utf8> Function(Int32), Pointer<Utf8> Function(int)>('SDL_GameControllerNameForIndex');
    _joystickNameForIndex = l.lookupFunction<Pointer<Utf8> Function(Int32), Pointer<Utf8> Function(int)>('SDL_JoystickNameForIndex');
    _typeForIndex = l.lookupFunction<Int32 Function(Int32), int Function(int)>('SDL_GameControllerTypeForIndex');
    _guidForIndex = l.lookupFunction<_SdlGuid Function(Int32), _SdlGuid Function(int)>('SDL_JoystickGetDeviceGUID');
    _vendorForIndex = l.lookupFunction<Uint16 Function(Int32), int Function(int)>('SDL_JoystickGetDeviceVendor');
    _productForIndex = l.lookupFunction<Uint16 Function(Int32), int Function(int)>('SDL_JoystickGetDeviceProduct');
    _isVirtual = l.lookupFunction<Int32 Function(Int32), int Function(int)>('SDL_JoystickIsVirtual');
    _open = l.lookupFunction<Pointer<Void> Function(Int32), Pointer<Void> Function(int)>('SDL_GameControllerOpen');
    _close = l.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('SDL_GameControllerClose');
    _button = l.lookupFunction<Uint8 Function(Pointer<Void>, Int32), int Function(Pointer<Void>, int)>('SDL_GameControllerGetButton');
    _axis = l.lookupFunction<Int16 Function(Pointer<Void>, Int32), int Function(Pointer<Void>, int)>('SDL_GameControllerGetAxis');
    _joystick = l.lookupFunction<Pointer<Void> Function(Pointer<Void>), Pointer<Void> Function(Pointer<Void>)>('SDL_GameControllerGetJoystick');
    _power = l.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('SDL_JoystickCurrentPowerLevel');
    _rumble = l.lookupFunction<Int32 Function(Pointer<Void>, Uint16, Uint16, Uint32), int Function(Pointer<Void>, int, int, int)>(
      'SDL_GameControllerRumble',
    );
    _setPlayer = l.lookupFunction<Void Function(Pointer<Void>, Int32), void Function(Pointer<Void>, int)>('SDL_GameControllerSetPlayerIndex');
    _eventState = l.lookupFunction<Int32 Function(Int32), int Function(int)>('SDL_GameControllerEventState');
    _joystickEventState = l.lookupFunction<Int32 Function(Int32), int Function(int)>('SDL_JoystickEventState');
    // Newer than 2.0.14: looked up only if there.
    _hasRumble = l.providesSymbol('SDL_GameControllerHasRumble')
        ? l.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('SDL_GameControllerHasRumble')
        : null;
    _hasLed = l.providesSymbol('SDL_GameControllerHasLED')
        ? l.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('SDL_GameControllerHasLED')
        : null;
    _setLed = l.providesSymbol('SDL_GameControllerSetLED')
        ? l.lookupFunction<Int32 Function(Pointer<Void>, Uint8, Uint8, Uint8), int Function(Pointer<Void>, int, int, int)>(
            'SDL_GameControllerSetLED',
          )
        : null;
    // 2.0.14 and later.
    _serial = l.providesSymbol('SDL_JoystickGetSerial')
        ? l.lookupFunction<Pointer<Utf8> Function(Pointer<Void>), Pointer<Utf8> Function(Pointer<Void>)>('SDL_JoystickGetSerial')
        : null;
    final getVersion = l.lookupFunction<Void Function(Pointer<_SdlVersion>), void Function(Pointer<_SdlVersion>)>('SDL_GetVersion');
    _version = using((arena) {
      final version = arena<_SdlVersion>();
      getVersion(version);
      return '${version.ref.major}.${version.ref.minor}.${version.ref.patch}';
    });
  }

  /// The hints, then the subsystems; null when it started, else why not.
  String? _start() {
    final hints = {
      // No window of SDL's own has the focus: the pads are read regardless, and the launcher's
      // input gate decides what reaches it.
      'SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS': '1',
      // Device arrival on Windows on SDL's own thread: nothing depends on the launcher's message loop.
      'SDL_JOYSTICK_THREAD': '1',
      'SDL_JOYSTICK_RAWINPUT': '0',
      // Buttons by place: a Nintendo pad's B is south, as the launcher's Cross.
      'SDL_GAMECONTROLLER_USE_BUTTON_LABELS': '0',
      // The motors of PlayStation pads over Bluetooth (their full reports).
      'SDL_JOYSTICK_HIDAPI_PS4_RUMBLE': '1',
      'SDL_JOYSTICK_HIDAPI_PS5_RUMBLE': '1',
      'SDL_JOYSTICK_HIDAPI_PS5_PLAYER_LED': '1',
      // Ctrl+C and the like stay the launcher's.
      'SDL_NO_SIGNAL_HANDLERS': '1',
    };
    using((arena) {
      for (final MapEntry(:key, :value) in hints.entries) {
        _setHint(key.toNativeUtf8(allocator: arena), value.toNativeUtf8(allocator: arena));
      }
    });
    if (_init(_initJoystick | _initGameController) != 0) return 'SDL_InitSubSystem failed';
    // The state is asked each frame: no events queue up unread.
    _eventState(0);
    _joystickEventState(0);
    return null;
  }

  @override
  String get version => _version;

  @override
  void update() => _controllerUpdate();

  @override
  List<SdlDevice> devices() {
    final count = _numJoysticks();
    return [
      for (var index = 0; index < count; index++)
        () {
          final gameController = _isGameController(index) != 0;
          final namePointer = gameController ? _nameForIndex(index) : _joystickNameForIndex(index);
          final guid = _guidForIndex(index);
          return SdlDevice(
            instance: _instanceForIndex(index),
            index: index,
            gameController: gameController,
            name: namePointer == nullptr ? 'Controller' : namePointer.toDartString(),
            type: gameController ? _typeForIndex(index) : 0,
            guid: [for (var byte = 0; byte < 16; byte++) guid.data[byte]],
            vendor: _vendorForIndex(index),
            product: _productForIndex(index),
            virtual: _isVirtual(index) != 0,
          );
        }(),
    ];
  }

  @override
  bool open(SdlDevice device) {
    final controller = _open(device.index);
    if (controller == nullptr) return false;
    _controllers[device.instance] = controller;
    return true;
  }

  @override
  void close(int instance) {
    final controller = _controllers.remove(instance);
    if (controller != null) _close(controller);
  }

  @override
  SdlReading? read(int instance) {
    final controller = _controllers[instance];
    if (controller == null) return null;
    final held = <int>{
      for (var button = 0; button <= SdlMaps.lastButton; button++)
        if (_button(controller, button) != 0) button,
    };
    final joystick = _joystick(controller);
    return SdlReading(
      held: held,
      axes: [for (var axis = 0; axis < 6; axis++) _axis(controller, axis)],
      powerLevel: joystick == nullptr ? -1 : _power(joystick),
    );
  }

  @override
  bool hasRumble(int instance) {
    final controller = _controllers[instance];
    if (controller == null) return false;
    return _hasRumble == null ? true : _hasRumble(controller) != 0;
  }

  @override
  bool rumble(int instance, int low, int high, int milliseconds) {
    final controller = _controllers[instance];
    return controller != null && _rumble(controller, low, high, milliseconds) == 0;
  }

  @override
  bool hasLed(int instance) {
    final controller = _controllers[instance];
    return controller != null && _hasLed != null && _hasLed(controller) != 0;
  }

  @override
  bool setLed(int instance, int red, int green, int blue) {
    final controller = _controllers[instance];
    return controller != null && _setLed != null && _setLed(controller, red, green, blue) == 0;
  }

  @override
  void setPlayerIndex(int instance, int player) {
    final controller = _controllers[instance];
    if (controller != null) _setPlayer(controller, player);
  }

  @override
  String? serial(int instance) {
    final controller = _controllers[instance];
    final serial = _serial;
    if (controller == null || serial == null) return null;
    final joystick = _joystick(controller);
    if (joystick == nullptr) return null;
    final text = serial(joystick);
    return text == nullptr ? null : text.toDartString();
  }

  @override
  void quit() {
    for (final controller in _controllers.values) {
      _close(controller);
    }
    _controllers.clear();
    _quit();
  }
}
