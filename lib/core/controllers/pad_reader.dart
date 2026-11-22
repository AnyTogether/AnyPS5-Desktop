import 'dart:io';

import '../gamepad/feel.dart';
import '../gamepad/linux_pads.dart';
import '../gamepad/pad_navigation.dart';
import '../gamepad/windows_pads.dart';
import '../steam/steam_launch.dart';
import 'pad_batteries.dart';
import 'pad_info.dart';
import 'pad_inventory.dart';
import 'sdl_pads.dart';
import 'sdl_worker.dart';

/// Picks the launcher's controller reader: SDL2 when it loads (shipped beside the launcher on
/// Windows, the system's on Linux), else the older readers (XInput and winmm, evdev). What
/// happened is kept for the troubleshooter and the log.
///
/// On Linux SDL2 runs in an isolate of its own ([SdlIsolateBackend]): looking for controllers it
/// opens /dev/input nodes, and an open can hang in the kernel for good (issue #195), which on the
/// launcher's isolate froze the whole interface. A worker that does not start or stops answering
/// gives way to the evdev reader, which leaves devices that are no controller alone and opens the
/// rest in isolates of their own too.
abstract final class PadReader {
  /// Why SDL2 was not used; null when it is (or nothing was tried yet).
  static String? sdlFailure;

  /// DS4Windows or DualSenseX runs (the troubleshooter's last look): their virtual Xbox pad is
  /// then left out while the real PlayStation pad is read.
  static bool remapperRunning = false;

  /// The reader for this launch; [arguments] and [environment] tell a launch from Steam.
  static PadSource open({required List<String> arguments, Map<String, String>? environment}) {
    final steam = SteamLaunch.detect(arguments, environment ?? Platform.environment);
    SdlPadSource sdlSource(SdlBackend sdl) => SdlPadSource(
      sdl,
      steam: steam.fromSteam,
      steamTookOver: steam.skipPhysicalPad,
      remapperRunning: () => remapperRunning,
      platformDriver: Platform.isWindows ? 'SDL DirectInput' : 'SDL evdev',
      // A percentage where the system measures one (SDL2 gives four levels), as on the Mac.
      batteries: PadBatteryProbe.forSystem(),
    );
    if (Platform.isLinux) {
      final library = SdlLibrary.locate(failure: (why) => sdlFailure = why);
      if (library == null) return LinuxPadSource();
      sdlFailure = null;
      final worker = SdlIsolateBackend(paths: [library]);
      final reader = FallbackPadSource(sdlSource(worker), LinuxPadSource.new);
      worker.onFailed = (why, {required stalled}) {
        // Stuck is not missing: the troubleshooter's "install SDL2" is no answer to it.
        if (!stalled) sdlFailure = why;
        reader.fallBack(why, stalled: stalled);
      };
      return reader;
    }
    final sdl = SdlLibrary.load(failure: (why) => sdlFailure = why);
    if (sdl != null) {
      sdlFailure = null;
      return sdlSource(sdl);
    }
    return Platform.isWindows ? WindowsPadSource(steam: steam.fromSteam) : LinuxPadSource();
  }

  /// The reader behind [inventory] now ([FallbackPadSource]'s current one).
  static PadInventory? current(PadInventory? inventory) => inventory is FallbackPadSource ? inventory.current : inventory;

  /// SDL2 is loaded, reading or stuck: not missing.
  static bool sdlLoaded(PadInventory? inventory) =>
      current(inventory) is SdlPadSource ||
      inventory is FallbackPadSource && inventory.stalled ||
      inventory == null && sdlFailure == null;
}

/// A reader that hands over to another when it fails: SDL2's worker to evdev on Linux. The pads
/// the first one had are let go (PadGone) and the second is started with the same listeners.
class FallbackPadSource implements PadSource, PadRumble, PadInventory {
  FallbackPadSource(PadSource first, this._fallback) : _current = first;

  final PadSource Function() _fallback;
  PadSource _current;
  void Function(PadEvent)? _onEvent;
  void Function()? _changed;
  String? _why;
  bool _stalled = false;
  bool _stopped = false;

  /// The reader in use now.
  PadInventory? get current => _current is PadInventory ? _current as PadInventory : null;

  /// The first reader got stuck (rather than failing to start).
  bool get stalled => _stalled;

  /// Why the first reader gave way; null while it is in use.
  String? get why => _why;

  /// Hands over to the fallback reader, once.
  void fallBack(String why, {bool stalled = false}) {
    if (_why != null || _stopped) return;
    _why = why;
    _stalled = stalled;
    final before = _current;
    final held = current?.pads ?? const <PadInfo>[];
    before.stop();
    for (final pad in held) {
      _onEvent?.call(PadGone(pad.id));
    }
    final next = _fallback();
    _current = next;
    if (next is PadInventory) (next as PadInventory).onPadsChanged = _changed;
    if (_onEvent case final onEvent?) next.start(onEvent);
    _changed?.call();
  }

  @override
  void start(void Function(PadEvent event) onEvent) {
    _onEvent = onEvent;
    _stopped = false;
    _current.start(onEvent);
  }

  @override
  void stop() {
    _stopped = true;
    _current.stop();
  }

  @override
  String get description => _why == null ? _current.description : '$_why; ${_current.description}';

  @override
  PadRumble? get motors => this;

  @override
  bool canRumble(String pad) => _current.motors?.canRumble(pad) ?? false;

  @override
  void rumble(String pad, double strong, double weak, Duration length) => _current.motors?.rumble(pad, strong, weak, length);

  @override
  List<PadInfo> get pads => current?.pads ?? const [];

  @override
  set onPadsChanged(void Function()? listener) {
    _changed = listener;
    current?.onPadsChanged = listener;
  }

  @override
  PadState? state(String id) => current?.state(id);

  @override
  bool setLight(String id, int red, int green, int blue) => current?.setLight(id, red, green, blue) ?? false;

  @override
  void setPlayerLights(List<String> ordered) => current?.setPlayerLights(ordered);

  @override
  String get readerName => '${current?.readerName ?? 'none'}${_stalled ? ' (SDL2 stuck)' : ''}';

  @override
  List<String> get refused => current?.refused ?? const [];
}
