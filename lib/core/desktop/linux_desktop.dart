import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'desktop.dart';
import 'window_backdrop.dart';

/// Which kind of Linux desktop session this is.
enum LinuxSession { x11, wayland, none }

LinuxSession linuxSession(Map<String, String> environment) {
  final type = (environment['XDG_SESSION_TYPE'] ?? '').toLowerCase();
  if (type == 'wayland' || (type.isEmpty && (environment['WAYLAND_DISPLAY'] ?? '').isNotEmpty)) {
    return LinuxSession.wayland;
  }
  if ((environment['DISPLAY'] ?? '').isNotEmpty) return LinuxSession.x11;
  return LinuxSession.none;
}

/// Xlib, as far as the launcher needs it: the game's window by its _NET_WM_PID, its picture
/// (XGetImage), and an override-redirect 32-bit window for the trophy card.
final class _Xlib {
  _Xlib(DynamicLibrary x11, DynamicLibrary? xext) {
    openDisplay = x11.lookupFunction<Pointer<Void> Function(Pointer<Utf8>), Pointer<Void> Function(Pointer<Utf8>)>(
      'XOpenDisplay',
    );
    closeDisplay = x11.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('XCloseDisplay');
    defaultScreen = x11.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('XDefaultScreen');
    rootWindow = x11.lookupFunction<UnsignedLong Function(Pointer<Void>, Int32), int Function(Pointer<Void>, int)>(
      'XRootWindow',
    );
    displayWidth = x11.lookupFunction<Int32 Function(Pointer<Void>, Int32), int Function(Pointer<Void>, int)>(
      'XDisplayWidth',
    );
    internAtom = x11
        .lookupFunction<
          UnsignedLong Function(Pointer<Void>, Pointer<Utf8>, Int32),
          int Function(Pointer<Void>, Pointer<Utf8>, int)
        >('XInternAtom');
    getWindowProperty = x11
        .lookupFunction<
          Int32 Function(
            Pointer<Void>,
            UnsignedLong,
            UnsignedLong,
            Long,
            Long,
            Int32,
            UnsignedLong,
            Pointer<UnsignedLong>,
            Pointer<Int32>,
            Pointer<UnsignedLong>,
            Pointer<UnsignedLong>,
            Pointer<Pointer<Uint8>>,
          ),
          int Function(
            Pointer<Void>,
            int,
            int,
            int,
            int,
            int,
            int,
            Pointer<UnsignedLong>,
            Pointer<Int32>,
            Pointer<UnsignedLong>,
            Pointer<UnsignedLong>,
            Pointer<Pointer<Uint8>>,
          )
        >('XGetWindowProperty');
    free = x11.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('XFree');
    getWindowAttributes = x11
        .lookupFunction<
          Int32 Function(Pointer<Void>, UnsignedLong, Pointer<Uint8>),
          int Function(Pointer<Void>, int, Pointer<Uint8>)
        >('XGetWindowAttributes');
    getImage = x11
        .lookupFunction<
          Pointer<Uint8> Function(Pointer<Void>, UnsignedLong, Int32, Int32, Uint32, Uint32, UnsignedLong, Int32),
          Pointer<Uint8> Function(Pointer<Void>, int, int, int, int, int, int, int)
        >('XGetImage');
    matchVisualInfo = x11
        .lookupFunction<
          Int32 Function(Pointer<Void>, Int32, Int32, Int32, Pointer<Uint8>),
          int Function(Pointer<Void>, int, int, int, Pointer<Uint8>)
        >('XMatchVisualInfo');
    createColormap = x11
        .lookupFunction<
          UnsignedLong Function(Pointer<Void>, UnsignedLong, Pointer<Void>, Int32),
          int Function(Pointer<Void>, int, Pointer<Void>, int)
        >('XCreateColormap');
    createWindow = x11
        .lookupFunction<
          UnsignedLong Function(
            Pointer<Void>,
            UnsignedLong,
            Int32,
            Int32,
            Uint32,
            Uint32,
            Uint32,
            Int32,
            Uint32,
            Pointer<Void>,
            UnsignedLong,
            Pointer<Uint8>,
          ),
          int Function(Pointer<Void>, int, int, int, int, int, int, int, int, Pointer<Void>, int, Pointer<Uint8>)
        >('XCreateWindow');
    mapRaised = x11.lookupFunction<Int32 Function(Pointer<Void>, UnsignedLong), int Function(Pointer<Void>, int)>(
      'XMapRaised',
    );
    raiseWindow = x11.lookupFunction<Int32 Function(Pointer<Void>, UnsignedLong), int Function(Pointer<Void>, int)>(
      'XRaiseWindow',
    );
    moveWindow = x11
        .lookupFunction<
          Int32 Function(Pointer<Void>, UnsignedLong, Int32, Int32),
          int Function(Pointer<Void>, int, int, int)
        >('XMoveWindow');
    destroyWindow = x11.lookupFunction<Int32 Function(Pointer<Void>, UnsignedLong), int Function(Pointer<Void>, int)>(
      'XDestroyWindow',
    );
    createGC = x11
        .lookupFunction<
          Pointer<Void> Function(Pointer<Void>, UnsignedLong, UnsignedLong, Pointer<Void>),
          Pointer<Void> Function(Pointer<Void>, int, int, Pointer<Void>)
        >('XCreateGC');
    freeGC = x11
        .lookupFunction<Int32 Function(Pointer<Void>, Pointer<Void>), int Function(Pointer<Void>, Pointer<Void>)>(
          'XFreeGC',
        );
    createImage = x11
        .lookupFunction<
          Pointer<Uint8> Function(
            Pointer<Void>,
            Pointer<Void>,
            Uint32,
            Int32,
            Int32,
            Pointer<Uint8>,
            Uint32,
            Uint32,
            Int32,
            Int32,
          ),
          Pointer<Uint8> Function(Pointer<Void>, Pointer<Void>, int, int, int, Pointer<Uint8>, int, int, int, int)
        >('XCreateImage');
    putImage = x11
        .lookupFunction<
          Int32 Function(
            Pointer<Void>,
            UnsignedLong,
            Pointer<Void>,
            Pointer<Uint8>,
            Int32,
            Int32,
            Int32,
            Int32,
            Uint32,
            Uint32,
          ),
          int Function(Pointer<Void>, int, Pointer<Void>, Pointer<Uint8>, int, int, int, int, int, int)
        >('XPutImage');
    flush = x11.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('XFlush');
    translateCoordinates = x11
        .lookupFunction<
          Int32 Function(
            Pointer<Void>,
            UnsignedLong,
            UnsignedLong,
            Int32,
            Int32,
            Pointer<Int32>,
            Pointer<Int32>,
            Pointer<UnsignedLong>,
          ),
          int Function(Pointer<Void>, int, int, int, int, Pointer<Int32>, Pointer<Int32>, Pointer<UnsignedLong>)
        >('XTranslateCoordinates');
    getSelectionOwner = x11
        .lookupFunction<UnsignedLong Function(Pointer<Void>, UnsignedLong), int Function(Pointer<Void>, int)>(
          'XGetSelectionOwner',
        );
    changeProperty = x11
        .lookupFunction<
          Int32 Function(Pointer<Void>, UnsignedLong, UnsignedLong, UnsignedLong, Int32, Int32, Pointer<Uint8>, Int32),
          int Function(Pointer<Void>, int, int, int, int, int, Pointer<Uint8>, int)
        >('XChangeProperty');
    deleteProperty = x11
        .lookupFunction<
          Int32 Function(Pointer<Void>, UnsignedLong, UnsignedLong),
          int Function(Pointer<Void>, int, int)
        >('XDeleteProperty');
    if (xext != null) {
      try {
        shapeCombineRectangles = xext
            .lookupFunction<
              Void Function(Pointer<Void>, UnsignedLong, Int32, Int32, Int32, Pointer<Void>, Int32, Int32, Int32),
              void Function(Pointer<Void>, int, int, int, int, Pointer<Void>, int, int, int)
            >('XShapeCombineRectangles');
      } on ArgumentError {
        shapeCombineRectangles = null;
      }
    }
  }

  late final Pointer<Void> Function(Pointer<Utf8>) openDisplay;
  late final int Function(Pointer<Void>) closeDisplay;
  late final int Function(Pointer<Void>) defaultScreen;
  late final int Function(Pointer<Void>, int) rootWindow;
  late final int Function(Pointer<Void>, int) displayWidth;
  late final int Function(Pointer<Void>, Pointer<Utf8>, int) internAtom;
  late final int Function(
    Pointer<Void>,
    int,
    int,
    int,
    int,
    int,
    int,
    Pointer<UnsignedLong>,
    Pointer<Int32>,
    Pointer<UnsignedLong>,
    Pointer<UnsignedLong>,
    Pointer<Pointer<Uint8>>,
  )
  getWindowProperty;
  late final int Function(Pointer<Void>) free;
  late final int Function(Pointer<Void>, int, Pointer<Uint8>) getWindowAttributes;
  late final Pointer<Uint8> Function(Pointer<Void>, int, int, int, int, int, int, int) getImage;
  late final int Function(Pointer<Void>, int, int, int, Pointer<Uint8>) matchVisualInfo;
  late final int Function(Pointer<Void>, int, Pointer<Void>, int) createColormap;
  late final int Function(Pointer<Void>, int, int, int, int, int, int, int, int, Pointer<Void>, int, Pointer<Uint8>)
  createWindow;
  late final int Function(Pointer<Void>, int) mapRaised;
  late final int Function(Pointer<Void>, int) raiseWindow;
  late final int Function(Pointer<Void>, int, int, int) moveWindow;
  late final int Function(Pointer<Void>, int) destroyWindow;
  late final Pointer<Void> Function(Pointer<Void>, int, int, Pointer<Void>) createGC;
  late final int Function(Pointer<Void>, Pointer<Void>) freeGC;
  late final Pointer<Uint8> Function(Pointer<Void>, Pointer<Void>, int, int, int, Pointer<Uint8>, int, int, int, int)
  createImage;
  late final int Function(Pointer<Void>, int, Pointer<Void>, Pointer<Uint8>, int, int, int, int, int, int) putImage;
  late final int Function(Pointer<Void>) flush;
  late final int Function(Pointer<Void>, int, int, int, int, Pointer<Int32>, Pointer<Int32>, Pointer<UnsignedLong>)
  translateCoordinates;
  late final int Function(Pointer<Void>, int) getSelectionOwner;
  late final int Function(Pointer<Void>, int, int, int, int, int, Pointer<Uint8>, int) changeProperty;
  late final int Function(Pointer<Void>, int, int) deleteProperty;
  void Function(Pointer<Void>, int, int, int, int, Pointer<Void>, int, int, int)? shapeCombineRectangles;

  /// XDestroyImage is a macro: the image's own destroy function, at offset 96 of XImage.
  void destroyImage(Pointer<Uint8> image) {
    final destroy = (image + 96).cast<Pointer<NativeFunction<Int32 Function(Pointer<Uint8>)>>>().value;
    destroy.asFunction<int Function(Pointer<Uint8>)>()(image);
  }
}

/// The desktop on Linux. On X11: the game's window found by its _NET_WM_PID, its picture with
/// XGetImage, the trophy card as an override-redirect window (above the game, out of the window
/// manager's hands, its input shape empty so clicks go through). Windows are brought in front
/// with xdotool or wmctrl when one is installed. On Wayland, where no program may place a window
/// over another's or read it, the card is a desktop notification and no picture is taken.
class LinuxDesktop implements DesktopWindows, GameAreas {
  LinuxDesktop({Map<String, String>? environment}) : session = linuxSession(environment ?? Platform.environment);

  final LinuxSession session;

  _Xlib? _xlibCache;
  bool _xlibTried = false;

  _Xlib? get _x {
    if (_xlibTried) return _xlibCache;
    _xlibTried = true;
    if (session != LinuxSession.x11) return null;
    try {
      final x11 = DynamicLibrary.open('libX11.so.6');
      DynamicLibrary? xext;
      try {
        xext = DynamicLibrary.open('libXext.so.6');
      } on ArgumentError {
        xext = null;
      }
      _xlibCache = _Xlib(x11, xext);
    } on Object {
      _xlibCache = null;
    }
    return _xlibCache;
  }

  /// Runs [body] with a display connection of its own, closed after.
  T? _withDisplay<T>(T? Function(_Xlib x, Pointer<Void> display) body) {
    final x = _x;
    if (x == null) return null;
    final display = x.openDisplay(nullptr);
    if (display == nullptr) return null;
    try {
      return body(x, display);
    } finally {
      x.closeDisplay(display);
    }
  }

  /// The window of [pid] the window manager lists (_NET_CLIENT_LIST), the largest one, or 0.
  int _windowOf(_Xlib x, Pointer<Void> display, int pid) => using((arena) {
    final root = x.rootWindow(display, x.defaultScreen(display));
    final clients = _property(x, display, arena, root, '_NET_CLIENT_LIST');
    if (clients == null) return 0;
    var best = 0;
    var bestArea = -1;
    final attributes = arena<Uint8>(136);
    for (final window in clients) {
      final pids = _property(x, display, arena, window, '_NET_WM_PID');
      if (pids == null || pids.isEmpty || pids.first != pid) continue;
      if (x.getWindowAttributes(display, window, attributes) == 0) continue;
      final data = attributes.cast<Int32>();
      final area = data[2] * data[3];
      if (data[23] == 2 /* IsViewable */ && area > bestArea) {
        best = window;
        bestArea = area;
      }
    }
    return best;
  });

  /// A 32-bit-format property (longs in Xlib's API) as numbers.
  List<int>? _property(_Xlib x, Pointer<Void> display, Arena arena, int window, String name) {
    final atom = x.internAtom(display, name.toNativeUtf8(allocator: arena), 1);
    if (atom == 0) return null;
    final type = arena<UnsignedLong>();
    final format = arena<Int32>();
    final count = arena<UnsignedLong>();
    final after = arena<UnsignedLong>();
    final data = arena<Pointer<Uint8>>();
    if (x.getWindowProperty(
          display,
          window,
          atom,
          0,
          4096,
          0,
          0 /* AnyPropertyType */,
          type,
          format,
          count,
          after,
          data,
        ) !=
        0) {
      return null;
    }
    if (data.value == nullptr) return null;
    try {
      if (format.value != 32) return null;
      final longs = data.value.cast<UnsignedLong>();
      return [for (var index = 0; index < count.value; index++) longs[index]];
    } finally {
      x.free(data.value.cast());
    }
  }

  Future<bool> _activate(int pid) async {
    for (final tool in [
      ['xdotool', 'search', '--onlyvisible', '--pid', '$pid', 'windowactivate'],
    ]) {
      try {
        final result = await Process.run(tool.first, tool.sublist(1));
        if (result.exitCode == 0) return true;
      } on ProcessException {
        // Not installed.
      }
    }
    final window = _withDisplay((x, display) => _windowOf(x, display, pid)) ?? 0;
    if (window == 0) return false;
    try {
      final result = await Process.run('wmctrl', ['-i', '-a', '0x${window.toRadixString(16)}']);
      return result.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  @override
  Future<bool> raiseLauncher() => _activate(pid);

  /// A display connection kept for [launcherFocused], which is asked at every controller event.
  Pointer<Void>? _focusDisplay;

  /// On X11, whether the window the window manager says is active (_NET_ACTIVE_WINDOW) is this
  /// process's (its _NET_WM_PID); the trophy card is override-redirect and never active. Null on
  /// Wayland or without a window manager that says.
  @override
  bool? launcherFocused() {
    final x = _x;
    if (x == null) return null;
    final display = _focusDisplay ??= x.openDisplay(nullptr);
    if (display == nullptr) return null;
    return using((arena) {
      final root = x.rootWindow(display, x.defaultScreen(display));
      final active = _property(x, display, arena, root, '_NET_ACTIVE_WINDOW');
      if (active == null) return null;
      if (active.isEmpty || active.first == 0) return false;
      final pids = _property(x, display, arena, active.first, '_NET_WM_PID');
      if (pids == null || pids.isEmpty) return false;
      return pids.first == pid;
    });
  }

  @override
  Future<bool> focusGame(int pid) => _activate(pid);

  /// On X11, the key typed with xdotool (XTEST) while the game's window is the one in front
  /// (its own events, which SDL takes; a synthetic event sent to a window it would ignore).
  @override
  Future<bool> pressKey(int pid, String key, {Duration hold = const Duration(milliseconds: 100)}) async {
    final keysym = KeyCodes.x11Keysym(key);
    if (session != LinuxSession.x11 || keysym == null) return false;
    try {
      if ((await Process.run('xdotool', ['keydown', keysym])).exitCode != 0) return false;
      await Future<void>.delayed(hold);
      return (await Process.run('xdotool', ['keyup', keysym])).exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  @override
  Future<bool> applyDisplay(int pid, {required bool fullscreen, required int windowSize}) async {
    if (session != LinuxSession.x11) return false;
    try {
      final found = await Process.run('xdotool', [
        'search',
        '--sync',
        '--onlyvisible',
        '--pid',
        '$pid',
      ]).timeout(const Duration(minutes: 3));
      final window = (found.stdout as String).trim().split('\n').where((line) => line.isNotEmpty).lastOrNull;
      if (found.exitCode != 0 || window == null) return false;
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      if (fullscreen) {
        final result = await Process.run('xdotool', [
          'windowactivate',
          '--sync',
          window,
          'key',
          '--clearmodifiers',
          'F11',
        ]);
        return result.exitCode == 0;
      }
      final geometry = await Process.run('xdotool', ['getdisplaygeometry']);
      final parts = (geometry.stdout as String).trim().split(RegExp(r'\s+')).map(int.tryParse).toList();
      if (parts.length < 2 || parts[0] == null || parts[1] == null) return false;
      final width = parts[0]!;
      final height = parts[1]!;
      final share = windowSize.clamp(30, 100) / 100;
      var w = width * share;
      var h = w * 9 / 16;
      if (h > height * share) {
        h = height * share;
        w = h * 16 / 9;
      }
      final result = await Process.run('xdotool', [
        'windowsize',
        window,
        '${w.round()}',
        '${h.round()}',
        'windowmove',
        window,
        '${((width - w) / 2).round()}',
        '${((height - h) / 2).round()}',
      ]);
      return result.exitCode == 0;
    } on Object {
      return false;
    }
  }

  /// The window's corner on the root window (XTranslateCoordinates: its parent is the window
  /// manager's frame) and its size.
  @override
  ScreenArea? gameArea(int pid) => _withDisplay((x, display) {
    final window = _windowOf(x, display, pid);
    if (window == 0) return null;
    return using((arena) {
      final attributes = arena<Uint8>(136);
      if (x.getWindowAttributes(display, window, attributes) == 0) return null;
      final width = attributes.cast<Int32>()[2];
      final height = attributes.cast<Int32>()[3];
      if (width <= 0 || height <= 0) return null;
      final root = x.rootWindow(display, x.defaultScreen(display));
      final left = arena<Int32>();
      final top = arena<Int32>();
      final child = arena<UnsignedLong>();
      if (x.translateCoordinates(display, window, root, 0, 0, left, top, child) == 0) return null;
      return ScreenArea(left.value, top.value, width, height);
    });
  });

  /// _NET_WM_NAME (UTF-8), else WM_NAME.
  @override
  String? gameTitle(int pid) => _withDisplay((x, display) {
    final window = _windowOf(x, display, pid);
    if (window == 0) return null;
    return using((arena) {
      for (final name in const ['_NET_WM_NAME', 'WM_NAME']) {
        final atom = x.internAtom(display, name.toNativeUtf8(allocator: arena), 1);
        if (atom == 0) continue;
        final type = arena<UnsignedLong>();
        final format = arena<Int32>();
        final count = arena<UnsignedLong>();
        final after = arena<UnsignedLong>();
        final data = arena<Pointer<Uint8>>();
        if (x.getWindowProperty(display, window, atom, 0, 1024, 0, 0, type, format, count, after, data) != 0 ||
            data.value == nullptr) {
          continue;
        }
        try {
          if (format.value != 8 || count.value == 0) continue;
          return utf8.decode(data.value.asTypedList(count.value), allowMalformed: true);
        } finally {
          x.free(data.value.cast());
        }
      }
      return null;
    });
  });

  @override
  Future<RgbaImage?> captureGame(int pid) async => _withDisplay((x, display) {
    final window = _windowOf(x, display, pid);
    if (window == 0) return null;
    return using((arena) {
      final attributes = arena<Uint8>(136);
      if (x.getWindowAttributes(display, window, attributes) == 0) return null;
      final width = attributes.cast<Int32>()[2];
      final height = attributes.cast<Int32>()[3];
      if (width <= 0 || height <= 0 || width > 16384 || height > 16384) return null;
      final image = x.getImage(display, window, 0, 0, width, height, -1 /* AllPlanes */, 2 /* ZPixmap */);
      if (image == nullptr) return null;
      try {
        final ints = image.cast<Int32>();
        final data = (image + 16).cast<Pointer<Uint8>>().value;
        final stride = ints[11];
        final bits = ints[12];
        if (bits != 32 || data == nullptr) return null;
        return RgbaImage.fromBgra(width, height, Uint8List.fromList(data.asTypedList(stride * height)), stride: stride);
      } finally {
        x.destroyImage(image);
      }
    });
  });

  @override
  double cardScale(int? pid) {
    final scale = double.tryParse(Platform.environment['GDK_SCALE'] ?? '');
    return scale != null && scale > 0 ? scale : 1;
  }

  bool _showing = false;

  // X11's grab records what is on the screen, this badge too: none, as the rows say.
  @override
  Future<bool> showBadge(RgbaImage? badge, {int? pid}) async => false;

  @override
  Future<bool> showCard(RgbaImage card, {int? pid}) async {
    if (_showing) return false;
    final x = _x;
    if (x == null) return false;
    final display = x.openDisplay(nullptr);
    if (display == nullptr) return false;
    _showing = true;
    final arena = Arena();
    var window = 0;
    Pointer<Void> gc = nullptr;
    try {
      final screen = x.defaultScreen(display);
      final root = x.rootWindow(display, screen);
      final info = arena<Uint8>(64); // XVisualInfo
      if (x.matchVisualInfo(display, screen, 32, 4 /* TrueColor */, info) == 0) return false;
      final visual = info.cast<Pointer<Void>>().value;
      final colormap = x.createColormap(display, root, visual, 0);
      final attributes = arena<Uint8>(112); // XSetWindowAttributes
      (attributes + 8).cast<UnsignedLong>().value = 0; // background_pixel
      (attributes + 24).cast<UnsignedLong>().value = 0; // border_pixel
      (attributes + 88).cast<Int32>().value = 1; // override_redirect
      (attributes + 96).cast<UnsignedLong>().value = colormap;
      const mask = 1 << 1 | 1 << 3 | 1 << 9 | 1 << 13; // CWBackPixel | CWBorderPixel | CWOverrideRedirect | CWColormap
      final screenWidth = x.displayWidth(display, screen);
      final start = cardPosition(
        screenLeft: 0,
        screenTop: 0,
        screenWidth: screenWidth,
        cardWidth: card.width,
        margin: 18,
        slide: 22,
        t: 0,
      );
      window = x.createWindow(
        display,
        root,
        start.x,
        start.y,
        card.width,
        card.height,
        0,
        32,
        1 /* InputOutput */,
        visual,
        mask,
        attributes,
      );
      if (window == 0) return false;
      // An empty input shape: every click goes to the window below.
      x.shapeCombineRectangles?.call(display, window, 2 /* ShapeInput */, 0, 0, nullptr, 0, 0 /* ShapeSet */, 0);
      x.mapRaised(display, window);
      gc = x.createGC(display, window, 0, nullptr);
      final pixels = calloc<Uint8>(card.pixels.length);
      // XCreateImage takes the pixels and frees them with the image.
      final image = x.createImage(display, visual, 32, 2 /* ZPixmap */, 0, pixels, card.width, card.height, 32, 0);
      if (image == nullptr) {
        calloc.free(pixels);
        return false;
      }
      try {
        final started = DateTime.now();
        var lastOpacity = -1.0;
        while (true) {
          final phase = cardPhase(DateTime.now().difference(started));
          if (phase.done) break;
          final place = cardPosition(
            screenLeft: 0,
            screenTop: 0,
            screenWidth: screenWidth,
            cardWidth: card.width,
            margin: 18,
            slide: 22,
            t: phase.t,
          );
          x.moveWindow(display, window, place.x, place.y);
          final opacity = (phase.opacity * 20).round() / 20;
          if (opacity != lastOpacity) {
            pixels.asTypedList(card.pixels.length).setAll(0, card.premultipliedBgra(opacity));
            lastOpacity = opacity;
          }
          // Drawn every frame: without reading events there is no Expose to wait for.
          x.putImage(display, window, gc, image, 0, 0, 0, 0, card.width, card.height);
          x.raiseWindow(display, window);
          x.flush(display);
          await Future<void>.delayed(const Duration(milliseconds: 33));
        }
      } finally {
        x.destroyImage(image);
      }
      return true;
    } on Object {
      return false;
    } finally {
      if (gc != nullptr) x.freeGC(display, gc);
      if (window != 0) x.destroyWindow(display, window);
      x.flush(display);
      x.closeDisplay(display);
      arena.releaseAll();
      _showing = false;
    }
  }

  @override
  Future<bool> notify(String title, String body, {String? icon}) async {
    try {
      final result = await Process.run('notify-send', [
        '--app-name=AnyPS5',
        if (icon != null) '--icon=$icon',
        title,
        body,
      ]);
      return result.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  @override
  void dispose() {
    final display = _focusDisplay;
    _focusDisplay = null;
    if (display != null && display != nullptr) _x?.closeDisplay(display);
  }
}

/// The launcher window's see-through backdrop on Linux. The runner gives the window an RGBA
/// visual where the screen composites (and says so in ANYPS5_RGBA_VISUAL), so the pixels Flutter
/// leaves transparent show the desktop. On X11 a compositing manager must own _NET_WM_CM_Sn; KWin
/// (KDE Plasma) also blurs behind the window when it carries _KDE_NET_WM_BLUR_BEHIND_REGION
/// (empty: the whole window). GNOME, other compositors and Wayland show the desktop unblurred.
class LinuxBackdrop implements WindowBackdrop {
  LinuxBackdrop(this._desktop, {Map<String, String>? environment}) : _environment = environment ?? Platform.environment;

  final LinuxDesktop _desktop;
  final Map<String, String> _environment;

  @override
  late final BackdropKind kind = () {
    final session = _desktop.session;
    var compositor = false;
    var kwinBlur = false;
    if (session == LinuxSession.x11) {
      _desktop._withDisplay(
        (x, display) => using((arena) {
          final screen = x.defaultScreen(display);
          final selection = x.internAtom(display, '_NET_WM_CM_S$screen'.toNativeUtf8(allocator: arena), 0);
          compositor = selection != 0 && x.getSelectionOwner(display, selection) != 0;
          final blur = x.internAtom(display, _blurAtom.toNativeUtf8(allocator: arena), 1);
          final supported = _desktop._property(x, display, arena, x.rootWindow(display, screen), '_NET_SUPPORTED');
          kwinBlur = blur != 0 && (supported?.contains(blur) ?? false);
          return true;
        }),
      );
    }
    return linuxBackdropKind(
      wayland: session == LinuxSession.wayland,
      x11: session == LinuxSession.x11,
      rgbaVisual: _environment['ANYPS5_RGBA_VISUAL'] == '1',
      compositor: compositor,
      kwinBlur: kwinBlur,
      override: _environment['ANYPS5_BACKDROP'],
    );
  }();

  static const _blurAtom = '_KDE_NET_WM_BLUR_BEHIND_REGION';

  @override
  bool apply({required bool seeThrough}) {
    // Transparency alone needs nothing from the window: Flutter leaves its pixels clear.
    if (kind != BackdropKind.kwinBlur) return true;
    return _desktop._withDisplay(
          (x, display) => using((arena) {
            final window = _desktop._windowOf(x, display, pid);
            if (window == 0) return false;
            final atom = x.internAtom(display, _blurAtom.toNativeUtf8(allocator: arena), 0);
            if (seeThrough) {
              // No rectangles: blur behind the whole window. XA_CARDINAL, 32-bit, replace.
              x.changeProperty(display, window, atom, 6, 32, 0, arena<Uint8>(4), 0);
            } else {
              x.deleteProperty(display, window, atom);
            }
            x.flush(display);
            return true;
          }),
        ) ??
        false;
  }
}
