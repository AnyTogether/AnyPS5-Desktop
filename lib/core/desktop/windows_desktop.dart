import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'desktop.dart';
import 'window_backdrop.dart';

// user32, gdi32 and kernel32, as far as the launcher needs them. Every handle is an IntPtr.
typedef _H = IntPtr;

final class _Win32 {
  _Win32() {
    final user = DynamicLibrary.open('user32.dll');
    final gdi = DynamicLibrary.open('gdi32.dll');
    final kernel = DynamicLibrary.open('kernel32.dll');
    findWindowEx = user
        .lookupFunction<
          _H Function(_H, _H, Pointer<Utf16>, Pointer<Utf16>),
          int Function(int, int, Pointer<Utf16>, Pointer<Utf16>)
        >('FindWindowExW');
    getWindowThreadProcessId = user
        .lookupFunction<Uint32 Function(_H, Pointer<Uint32>), int Function(int, Pointer<Uint32>)>(
          'GetWindowThreadProcessId',
        );
    isWindowVisible = user.lookupFunction<Int32 Function(_H), int Function(int)>('IsWindowVisible');
    isIconic = user.lookupFunction<Int32 Function(_H), int Function(int)>('IsIconic');
    getWindow = user.lookupFunction<_H Function(_H, Uint32), int Function(int, int)>('GetWindow');
    getWindowRect = user.lookupFunction<Int32 Function(_H, Pointer<Int32>), int Function(int, Pointer<Int32>)>(
      'GetWindowRect',
    );
    getClientRect = user.lookupFunction<Int32 Function(_H, Pointer<Int32>), int Function(int, Pointer<Int32>)>(
      'GetClientRect',
    );
    clientToScreen = user.lookupFunction<Int32 Function(_H, Pointer<Int32>), int Function(int, Pointer<Int32>)>(
      'ClientToScreen',
    );
    getClassName = user
        .lookupFunction<Int32 Function(_H, Pointer<Utf16>, Int32), int Function(int, Pointer<Utf16>, int)>(
          'GetClassNameW',
        );
    getForegroundWindow = user.lookupFunction<_H Function(), int Function()>('GetForegroundWindow');
    getWindowText = user
        .lookupFunction<Int32 Function(_H, Pointer<Utf16>, Int32), int Function(int, Pointer<Utf16>, int)>(
          'GetWindowTextW',
        );
    setForegroundWindow = user.lookupFunction<Int32 Function(_H), int Function(int)>('SetForegroundWindow');
    bringWindowToTop = user.lookupFunction<Int32 Function(_H), int Function(int)>('BringWindowToTop');
    showWindow = user.lookupFunction<Int32 Function(_H, Int32), int Function(int, int)>('ShowWindow');
    setWindowPos = user
        .lookupFunction<
          Int32 Function(_H, _H, Int32, Int32, Int32, Int32, Uint32),
          int Function(int, int, int, int, int, int, int)
        >('SetWindowPos');
    switchToThisWindow = user.lookupFunction<Void Function(_H, Int32), void Function(int, int)>('SwitchToThisWindow');
    attachThreadInput = user.lookupFunction<Int32 Function(Uint32, Uint32, Int32), int Function(int, int, int)>(
      'AttachThreadInput',
    );
    sendInput = user
        .lookupFunction<Uint32 Function(Uint32, Pointer<Uint8>, Int32), int Function(int, Pointer<Uint8>, int)>(
          'SendInput',
        );
    mapVirtualKey = user.lookupFunction<Uint32 Function(Uint32, Uint32), int Function(int, int)>('MapVirtualKeyW');
    postMessage = user.lookupFunction<Int32 Function(_H, Uint32, IntPtr, IntPtr), int Function(int, int, int, int)>(
      'PostMessageW',
    );
    monitorFromWindow = user.lookupFunction<_H Function(_H, Uint32), int Function(int, int)>('MonitorFromWindow');
    getMonitorInfo = user.lookupFunction<Int32 Function(_H, Pointer<Uint32>), int Function(int, Pointer<Uint32>)>(
      'GetMonitorInfoW',
    );
    getDC = user.lookupFunction<_H Function(_H), int Function(int)>('GetDC');
    releaseDC = user.lookupFunction<Int32 Function(_H, _H), int Function(int, int)>('ReleaseDC');
    printWindow = user.lookupFunction<Int32 Function(_H, _H, Uint32), int Function(int, int, int)>('PrintWindow');
    registerClassEx = user.lookupFunction<Uint16 Function(Pointer<Uint8>), int Function(Pointer<Uint8>)>(
      'RegisterClassExW',
    );
    createWindowEx = user
        .lookupFunction<
          _H Function(
            Uint32,
            Pointer<Utf16>,
            Pointer<Utf16>,
            Uint32,
            Int32,
            Int32,
            Int32,
            Int32,
            _H,
            _H,
            _H,
            Pointer<Void>,
          ),
          int Function(int, Pointer<Utf16>, Pointer<Utf16>, int, int, int, int, int, int, int, int, Pointer<Void>)
        >('CreateWindowExW');
    destroyWindow = user.lookupFunction<Int32 Function(_H), int Function(int)>('DestroyWindow');
    updateLayeredWindow = user
        .lookupFunction<
          Int32 Function(_H, _H, Pointer<Int32>, Pointer<Int32>, _H, Pointer<Int32>, Uint32, Pointer<Uint8>, Uint32),
          int Function(int, int, Pointer<Int32>, Pointer<Int32>, int, Pointer<Int32>, int, Pointer<Uint8>, int)
        >('UpdateLayeredWindow');
    peekMessage = user
        .lookupFunction<
          Int32 Function(Pointer<Uint8>, _H, Uint32, Uint32, Uint32),
          int Function(Pointer<Uint8>, int, int, int, int)
        >('PeekMessageW');
    translateMessage = user.lookupFunction<Int32 Function(Pointer<Uint8>), int Function(Pointer<Uint8>)>(
      'TranslateMessage',
    );
    dispatchMessage = user.lookupFunction<IntPtr Function(Pointer<Uint8>), int Function(Pointer<Uint8>)>(
      'DispatchMessageW',
    );
    defWindowProc = user.lookup<Void>('DefWindowProcW');
    getDpiForWindow = _optional(() => user.lookupFunction<Uint32 Function(_H), int Function(int)>('GetDpiForWindow'));
    setWindowDisplayAffinity = _optional(
      () => user.lookupFunction<Int32 Function(_H, Uint32), int Function(int, int)>('SetWindowDisplayAffinity'),
    );
    createCompatibleDC = gdi.lookupFunction<_H Function(_H), int Function(int)>('CreateCompatibleDC');
    deleteDC = gdi.lookupFunction<Int32 Function(_H), int Function(int)>('DeleteDC');
    createDIBSection = gdi
        .lookupFunction<
          _H Function(_H, Pointer<Uint8>, Uint32, Pointer<Pointer<Uint8>>, _H, Uint32),
          int Function(int, Pointer<Uint8>, int, Pointer<Pointer<Uint8>>, int, int)
        >('CreateDIBSection');
    selectObject = gdi.lookupFunction<_H Function(_H, _H), int Function(int, int)>('SelectObject');
    deleteObject = gdi.lookupFunction<Int32 Function(_H), int Function(int)>('DeleteObject');
    bitBlt = gdi
        .lookupFunction<
          Int32 Function(_H, Int32, Int32, Int32, Int32, _H, Int32, Int32, Uint32),
          int Function(int, int, int, int, int, int, int, int, int)
        >('BitBlt');
    getCurrentThreadId = kernel.lookupFunction<Uint32 Function(), int Function()>('GetCurrentThreadId');
    getCurrentProcessId = kernel.lookupFunction<Uint32 Function(), int Function()>('GetCurrentProcessId');
    getModuleHandle = kernel.lookupFunction<_H Function(Pointer<Utf16>), int Function(Pointer<Utf16>)>(
      'GetModuleHandleW',
    );
  }

  static T? _optional<T>(T Function() lookup) {
    try {
      return lookup();
    } on ArgumentError {
      return null;
    }
  }

  late final int Function(int, int, Pointer<Utf16>, Pointer<Utf16>) findWindowEx;
  late final int Function(int, Pointer<Uint32>) getWindowThreadProcessId;
  late final int Function(int) isWindowVisible;
  late final int Function(int) isIconic;
  late final int Function(int, int) getWindow;
  late final int Function(int, Pointer<Int32>) getWindowRect;
  late final int Function(int, Pointer<Int32>) getClientRect;
  late final int Function(int, Pointer<Utf16>, int) getWindowText;
  late final int Function(int, Pointer<Int32>) clientToScreen;
  late final int Function(int, Pointer<Utf16>, int) getClassName;
  late final int Function() getForegroundWindow;
  late final int Function(int) setForegroundWindow;
  late final int Function(int) bringWindowToTop;
  late final int Function(int, int) showWindow;
  late final int Function(int, int, int, int, int, int, int) setWindowPos;
  late final int Function(int, int, int) attachThreadInput;
  late final void Function(int, int) switchToThisWindow;
  late final int Function(int, Pointer<Uint8>, int) sendInput;
  late final int Function(int, int, int, int) postMessage;
  late final int Function(int, int) mapVirtualKey;
  late final int Function(int, int) monitorFromWindow;
  late final int Function(int, Pointer<Uint32>) getMonitorInfo;
  late final int Function(int) getDC;
  late final int Function(int, int) releaseDC;
  late final int Function(int, int, int) printWindow;
  late final int Function(Pointer<Uint8>) registerClassEx;
  late final int Function(int, Pointer<Utf16>, Pointer<Utf16>, int, int, int, int, int, int, int, int, Pointer<Void>)
  createWindowEx;
  late final int Function(int) destroyWindow;
  late final int Function(int, int, Pointer<Int32>, Pointer<Int32>, int, Pointer<Int32>, int, Pointer<Uint8>, int)
  updateLayeredWindow;
  late final int Function(Pointer<Uint8>, int, int, int, int) peekMessage;
  late final int Function(Pointer<Uint8>) translateMessage;
  late final int Function(Pointer<Uint8>) dispatchMessage;
  late final Pointer<Void> defWindowProc;
  late final int Function(int)? getDpiForWindow;
  late final int Function(int, int)? setWindowDisplayAffinity;
  late final int Function(int) createCompatibleDC;
  late final int Function(int) deleteDC;
  late final int Function(int, Pointer<Uint8>, int, Pointer<Pointer<Uint8>>, int, int) createDIBSection;
  late final int Function(int, int) selectObject;
  late final int Function(int) deleteObject;
  late final int Function(int, int, int, int, int, int, int, int, int) bitBlt;
  late final int Function() getCurrentThreadId;
  late final int Function() getCurrentProcessId;
  late final int Function(Pointer<Utf16>) getModuleHandle;
}

/// The desktop on Windows, through Win32 called from Dart (no code in the runner): windows
/// found by process, brought in front with the foreground lock worked around (the launcher's
/// input joined to the window in front's for the moment), the game's picture copied from the
/// screen (or asked of the window with PrintWindow when it is covered), and the trophy card as
/// a layered, click-through, never-activated topmost window drawn with UpdateLayeredWindow.
class WindowsDesktop implements DesktopWindows, GameAreas {
  WindowsDesktop({this.log});

  /// A line for the controller's debug log (ANYPS5_PAD_LOG): how a window was brought in front.
  final void Function(String line)? log;

  late final _Win32 _w = _Win32();

  static const _topmost = -1;
  static const _notTopmost = -2;
  static const _noSize = 0x0001;
  static const _noMove = 0x0002;
  static const _noZOrder = 0x0004;
  static const _noActivate = 0x0010;
  static const _showWindow = 0x0040;

  bool _launcherOnTop = false;

  /// The top-level, visible, unowned window of [pid] with the largest area (a game may open a
  /// small console or splash first), or 0. [except] skips one (the card).
  int windowOf(int pid, {int except = 0}) => using((arena) {
    final owner = arena<Uint32>();
    final rect = arena<Int32>(4);
    var best = 0;
    var bestArea = -1;
    var window = 0;
    for (var guard = 0; guard < 20000; guard++) {
      window = _w.findWindowEx(0, window, nullptr, nullptr);
      if (window == 0) break;
      if (window == except || window == _card) continue;
      _w.getWindowThreadProcessId(window, owner);
      if (owner.value != pid || _w.isWindowVisible(window) == 0 || _w.getWindow(window, 4 /* GW_OWNER */) != 0) {
        continue;
      }
      _w.getWindowRect(window, rect);
      final area = (rect[2] - rect[0]) * (rect[3] - rect[1]);
      if (area > bestArea) {
        best = window;
        bestArea = area;
      }
    }
    return best;
  });

  int get _launcher => windowOf(_w.getCurrentProcessId());

  /// Brings [window] in front and gives it the keyboard. Windows refuses SetForegroundWindow
  /// more often than its rules say: the launcher, in front itself, could not hand the front to
  /// the game (PS pressed in the launcher did nothing), because a controller press is no input
  /// event and the last one went elsewhere. So: our input joined to the window in front's and to
  /// the target's for the moment; if Windows still says no, a tap of Alt (which makes this the
  /// process that had the last input, and which no window acts on alone) and once more; then
  /// SwitchToThisWindow, Alt+Tab's own way. True when [window] is in front.
  bool _bringToFront(int window) {
    if (window == 0) return false;
    if (_w.isIconic(window) != 0) _w.showWindow(window, 9 /* SW_RESTORE */);
    final front = _w.getForegroundWindow();
    if (front == window) return true;
    final ours = _w.getCurrentThreadId();
    final threads = <int>{
      if (front != 0) _w.getWindowThreadProcessId(front, nullptr),
      _w.getWindowThreadProcessId(window, nullptr),
    }..removeWhere((thread) => thread == 0 || thread == ours);
    final joined = [
      for (final thread in threads)
        if (_w.attachThreadInput(ours, thread, 1) != 0) thread,
    ];
    var how = 'refused';
    try {
      _w.bringWindowToTop(window);
      if (_w.setForegroundWindow(window) != 0 && _w.getForegroundWindow() == window) {
        how = 'SetForegroundWindow';
      } else {
        _tapAlt();
        if (_w.setForegroundWindow(window) != 0 && _w.getForegroundWindow() == window) {
          how = 'SetForegroundWindow after Alt';
        } else {
          _w.switchToThisWindow(window, 1);
          if (_w.getForegroundWindow() == window) how = 'SwitchToThisWindow';
        }
      }
    } finally {
      for (final thread in joined) {
        _w.attachThreadInput(ours, thread, 0);
      }
    }
    log?.call('desktop: window $window in front: $how');
    return _w.getForegroundWindow() == window;
  }

  /// Alt down and up, as typed: unlocks SetForegroundWindow for this process.
  void _tapAlt() => using((arena) {
    final inputs = arena<Uint8>(80);
    for (final (index, flags) in [(0, 0), (1, 2 /* KEYEVENTF_KEYUP */)]) {
      final input = inputs + index * 40;
      input.cast<Uint32>().value = 1; // INPUT_KEYBOARD
      (input + 8).cast<Uint16>().value = 0x12; // VK_MENU
      (input + 12).cast<Uint32>().value = flags;
    }
    _w.sendInput(2, inputs, 40);
  });

  @override
  Future<bool> raiseLauncher() async {
    final launcher = _launcher;
    if (launcher == 0) return false;
    // A full-screen SDL window is topmost: the launcher goes above it until the game is back.
    _w.setWindowPos(launcher, _topmost, 0, 0, 0, 0, _noMove | _noSize);
    _launcherOnTop = true;
    return _bringToFront(launcher);
  }

  /// The game in front again and the launcher just behind it (not topmost any more).
  @override
  Future<bool> focusGame(int pid) async {
    final launcher = _launcher;
    if (_launcherOnTop && launcher != 0) {
      _w.setWindowPos(launcher, _notTopmost, 0, 0, 0, 0, _noMove | _noSize | _noActivate);
      _launcherOnTop = false;
    }
    final game = windowOf(pid);
    if (game == 0) {
      log?.call('desktop: game $pid has no window to bring in front');
      return false;
    }
    final shown = _bringToFront(game);
    if (shown && launcher != 0) {
      _w.setWindowPos(launcher, game, 0, 0, 0, 0, _noMove | _noSize | _noActivate);
    }
    return shown;
  }

  late final Pointer<Uint32> _frontOwner = calloc<Uint32>();

  /// The window in front belongs to this process (and is not the card, which never takes input).
  /// A few microseconds: asked at every controller event.
  @override
  bool? launcherFocused() {
    final front = _w.getForegroundWindow();
    // No window in front (a switch going on, the lock screen): not the launcher.
    if (front == 0 || (front == _card && _card != 0)) return false;
    _w.getWindowThreadProcessId(front, _frontOwner);
    final ours = _frontOwner.value == _w.getCurrentProcessId();
    // Another window took the front (the game clicked, Alt+Tab): the launcher no longer stays
    // above everything, or it would cover the game it was raised over.
    if (!ours && _launcherOnTop) {
      final launcher = _launcher;
      if (launcher != 0) _w.setWindowPos(launcher, _notTopmost, 0, 0, 0, 0, _noMove | _noSize | _noActivate);
      _launcherOnTop = false;
    }
    return ours;
  }

  /// Waits for the game's first window: a game can take a while to open it.
  Future<int> _waitForWindow(int pid, {Duration timeout = const Duration(minutes: 3)}) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      final window = windowOf(pid);
      if (window != 0) return window;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    return 0;
  }

  /// The work area (without the taskbar) and the whole area of the screen [window] is on, as
  /// left, top, right, bottom.
  (List<int> work, List<int> screen)? _screenOf(int window) => using((arena) {
    final monitor = _w.monitorFromWindow(window, 2 /* MONITOR_DEFAULTTONEAREST */);
    final info = arena<Uint32>(10); // MONITORINFO: cbSize, rcMonitor, rcWork, dwFlags
    info[0] = 40;
    if (monitor == 0 || _w.getMonitorInfo(monitor, info) == 0) return null;
    final ints = info.cast<Int32>();
    return ([ints[5], ints[6], ints[7], ints[8]], [ints[1], ints[2], ints[3], ints[4]]);
  });

  @override
  Future<bool> applyDisplay(int pid, {required bool fullscreen, required int windowSize}) async {
    final window = await _waitForWindow(pid);
    if (window == 0) return false;
    // Let SDL finish creating its window and swapchain first.
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    if (windowOf(pid) != window) return false;
    if (fullscreen) return _pressF11(window);
    final screens = _screenOf(window);
    if (screens == null) return false;
    final (work, _) = screens;
    return using((arena) {
      final outer = arena<Int32>(4);
      final inner = arena<Int32>(4);
      _w.getWindowRect(window, outer);
      _w.getClientRect(window, inner);
      final frameWidth = (outer[2] - outer[0]) - inner[2];
      final frameHeight = (outer[3] - outer[1]) - inner[3];
      final size = windowArea(
        workWidth: work[2] - work[0],
        workHeight: work[3] - work[1],
        percent: windowSize,
        frameWidth: frameWidth,
        frameHeight: frameHeight,
      );
      final x = work[0] + (work[2] - work[0] - size.width) ~/ 2;
      final y = work[1] + (work[3] - work[1] - size.height) ~/ 2;
      return _w.setWindowPos(window, 0, x, y, size.width, size.height, _noZOrder | _noActivate) != 0;
    });
  }

  /// F11 in the game's window, as if typed: upstream's engine toggles full screen on it.
  bool _pressF11(int window) {
    _bringToFront(window);
    if (_w.getForegroundWindow() == window) {
      return using((arena) {
        // Two INPUTs (40 bytes each on 64-bit Windows): F11 down and up, by virtual key and scan code.
        final inputs = arena<Uint8>(80);
        for (final (index, flags) in [(0, 0), (1, 2 /* KEYEVENTF_KEYUP */)]) {
          final input = (inputs + index * 40);
          input.cast<Uint32>().value = 1; // INPUT_KEYBOARD
          (input + 8).cast<Uint16>().value = 0x7A; // VK_F11
          (input + 10).cast<Uint16>().value = 0x57; // scan code
          (input + 12).cast<Uint32>().value = flags;
        }
        return _w.sendInput(2, inputs, 40) == 2;
      });
    }
    // Not in front: the key goes to the window's queue, which SDL reads the same way.
    const keyDown = 1 | 0x57 << 16;
    const keyUp = keyDown | 1 << 30 | 1 << 31;
    return _w.postMessage(window, 0x0100, 0x7A, keyDown) != 0 && _w.postMessage(window, 0x0101, 0x7A, keyUp) != 0;
  }

  /// The key typed into the game's window: as input when it is in front (SDL reads its scan
  /// code), into its queue otherwise; held [hold] so a game reading the keyboard once a frame
  /// sees it down.
  @override
  Future<bool> pressKey(int pid, String key, {Duration hold = const Duration(milliseconds: 100)}) async {
    final virtualKey = KeyCodes.windowsVirtualKey(key);
    final window = windowOf(pid);
    if (virtualKey == null || window == 0) return false;
    final scan = _w.mapVirtualKey(virtualKey, 0 /* MAPVK_VK_TO_VSC */);
    // The arrows, Home, End, Page Up and Down, Delete: the extended keys.
    final extended = const {0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x2E}.contains(virtualKey);
    if (_w.getForegroundWindow() == window) {
      bool send(bool up) => using((arena) {
        final input = arena<Uint8>(40);
        input.cast<Uint32>().value = 1; // INPUT_KEYBOARD
        (input + 8).cast<Uint16>().value = virtualKey;
        (input + 10).cast<Uint16>().value = scan;
        (input + 12).cast<Uint32>().value = (up ? 2 /* KEYEVENTF_KEYUP */ : 0) | (extended ? 1 : 0);
        return _w.sendInput(1, input, 40) == 1;
      });
      if (!send(false)) return false;
      await Future<void>.delayed(hold);
      return send(true);
    }
    final lParam = 1 | scan << 16 | (extended ? 1 << 24 : 0);
    if (_w.postMessage(window, 0x0100 /* WM_KEYDOWN */, virtualKey, lParam) == 0) return false;
    await Future<void>.delayed(hold);
    return _w.postMessage(window, 0x0101 /* WM_KEYUP */, virtualKey, lParam | 1 << 30 | 1 << 31) != 0;
  }

  /// The client area on the screen. The launcher is aware of each monitor's scale, so these are
  /// physical pixels, as ffmpeg's gdigrab takes them.
  @override
  ScreenArea? gameArea(int pid) {
    final window = windowOf(pid);
    if (window == 0 || _w.isIconic(window) != 0) return null;
    return using((arena) {
      final rect = arena<Int32>(4);
      final corner = arena<Int32>(2);
      if (_w.getClientRect(window, rect) == 0 || _w.clientToScreen(window, corner) == 0) return null;
      final width = rect[2];
      final height = rect[3];
      if (width <= 0 || height <= 0) return null;
      return ScreenArea(corner[0], corner[1], width, height);
    });
  }

  @override
  String? gameTitle(int pid) {
    final window = windowOf(pid);
    if (window == 0) return null;
    return using((arena) {
      final text = arena<Uint16>(512).cast<Utf16>();
      final length = _w.getWindowText(window, text, 512);
      return length <= 0 ? null : text.toDartString(length: length);
    });
  }

  @override
  Future<RgbaImage?> captureGame(int pid) async {
    final window = windowOf(pid);
    if (window == 0 || _w.isIconic(window) != 0) return null;
    return using((arena) {
      final rect = arena<Int32>(4);
      final corner = arena<Int32>(2);
      _w.getClientRect(window, rect);
      _w.clientToScreen(window, corner);
      final width = rect[2];
      final height = rect[3];
      if (width <= 0 || height <= 0 || width > 16384 || height > 16384) return null;
      final screen = _w.getDC(0);
      final memory = _w.createCompatibleDC(screen);
      final bits = arena<Pointer<Uint8>>();
      final bitmap = _w.createDIBSection(memory, _bitmapInfo(arena, width, height), 0, bits, 0, 0);
      if (bitmap == 0) {
        _w.deleteDC(memory);
        _w.releaseDC(0, screen);
        return null;
      }
      final previous = _w.selectObject(memory, bitmap);
      try {
        // In front, the screen has the game as the player sees it; covered, the window is asked
        // to draw itself (PW_CLIENTONLY | PW_RENDERFULLCONTENT).
        final copied = _w.getForegroundWindow() == window
            ? _w.bitBlt(memory, 0, 0, width, height, screen, corner[0], corner[1], 0x00CC0020 /* SRCCOPY */)
            : _w.printWindow(window, memory, 3);
        if (copied == 0) return null;
        final pixels = Uint8List.fromList(bits.value.asTypedList(width * height * 4));
        return RgbaImage.fromBgra(width, height, pixels);
      } finally {
        _w.selectObject(memory, previous);
        _w.deleteObject(bitmap);
        _w.deleteDC(memory);
        _w.releaseDC(0, screen);
      }
    });
  }

  /// A BITMAPINFOHEADER for a top-down 32-bit picture.
  static Pointer<Uint8> _bitmapInfo(Arena arena, int width, int height) {
    final header = arena<Uint8>(44);
    final ints = header.cast<Int32>();
    ints[0] = 40; // biSize
    ints[1] = width;
    ints[2] = -height; // top-down
    (header + 12).cast<Uint16>().value = 1; // biPlanes
    (header + 14).cast<Uint16>().value = 32; // biBitCount
    return header;
  }

  @override
  double cardScale(int? pid) {
    final window = pid == null ? _w.getForegroundWindow() : windowOf(pid);
    final dpi = window == 0 ? 0 : (_w.getDpiForWindow?.call(window) ?? 0);
    return dpi <= 0 ? 1 : dpi / 96;
  }

  int _card = 0;
  bool _registered = false;
  static const _className = 'AnyPS5TrophyCard';

  int _makeCardWindow(int width, int height) {
    final instance = _w.getModuleHandle(nullptr);
    final className = _className.toNativeUtf16();
    if (!_registered) {
      using((arena) {
        // WNDCLASSEXW (80 bytes); messages go straight to DefWindowProcW: nothing to draw on
        // request, the layered window keeps its own picture.
        final type = arena<Uint8>(80);
        type.cast<Uint32>().value = 80;
        (type + 8).cast<IntPtr>().value = _w.defWindowProc.address;
        (type + 24).cast<IntPtr>().value = instance;
        (type + 64).cast<Pointer<Utf16>>().value = className;
        _registered = _w.registerClassEx(type) != 0;
      });
    }
    // WS_EX_LAYERED | WS_EX_TRANSPARENT (clicks pass through) | WS_EX_TOPMOST | WS_EX_TOOLWINDOW
    // (not in the taskbar or Alt-Tab) | WS_EX_NOACTIVATE; WS_POPUP.
    const exStyle = 0x80000 | 0x20 | 0x8 | 0x80 | 0x8000000;
    final title = 'AnyPS5'.toNativeUtf16();
    try {
      return _w.createWindowEx(exStyle, className, title, 0x80000000, 0, 0, width, height, 0, 0, instance, nullptr);
    } finally {
      calloc.free(title);
    }
  }

  /// Takes the messages Windows posts to the card (it is the launcher's thread's), so it is
  /// never seen as not responding.
  void _pumpCard(Pointer<Uint8> message) {
    for (var guard = 0; guard < 32 && _w.peekMessage(message, _card, 0, 0, 1 /* PM_REMOVE */) != 0; guard++) {
      _w.translateMessage(message);
      _w.dispatchMessage(message);
    }
  }

  @override
  bool get canShowCard => true;

  @override
  Future<bool> showCard(RgbaImage card, {int? pid}) async {
    if (_card != 0) return false;
    final game = pid == null ? 0 : windowOf(pid);
    final anchor = game != 0 ? game : _w.getForegroundWindow();
    final screens = _screenOf(anchor);
    if (screens == null) return false;
    final (_, screen) = screens;
    final window = _makeCardWindow(card.width, card.height);
    if (window == 0) return false;
    _card = window;
    final screenDc = _w.getDC(0);
    final memory = _w.createCompatibleDC(screenDc);
    final bitsOut = calloc<Pointer<Uint8>>();
    final header = calloc<Uint8>(44);
    final ints = header.cast<Int32>();
    ints[0] = 40;
    ints[1] = card.width;
    ints[2] = -card.height;
    (header + 12).cast<Uint16>().value = 1;
    (header + 14).cast<Uint16>().value = 32;
    final bitmap = _w.createDIBSection(memory, header, 0, bitsOut, 0, 0);
    final previous = bitmap == 0 ? 0 : _w.selectObject(memory, bitmap);
    final point = calloc<Int32>(2);
    final size = calloc<Int32>(2)
      ..[0] = card.width
      ..[1] = card.height;
    final source = calloc<Int32>(2);
    final blend = calloc<Uint8>(4);
    final message = calloc<Uint8>(48);
    final scale = cardScale(pid);
    try {
      if (bitmap == 0) return false;
      bitsOut.value.asTypedList(card.pixels.length).setAll(0, card.premultipliedBgra());
      final started = DateTime.now();
      var shown = false;
      while (true) {
        final phase = cardPhase(DateTime.now().difference(started));
        if (phase.done) break;
        final place = cardPosition(
          screenLeft: screen[0],
          screenTop: screen[1],
          screenWidth: screen[2] - screen[0],
          cardWidth: card.width,
          margin: (18 * scale).round(),
          slide: (22 * scale).round(),
          t: phase.t,
        );
        point
          ..[0] = place.x
          ..[1] = place.y;
        blend
          ..[0] =
              0 // AC_SRC_OVER
          ..[1] = 0
          ..[2] = (phase.opacity * 255).round().clamp(0, 255)
          ..[3] = 1; // AC_SRC_ALPHA
        _w.updateLayeredWindow(window, screenDc, point, size, memory, source, 0, blend, 2 /* ULW_ALPHA */);
        if (!shown) {
          shown = true;
          _w.showWindow(window, 4 /* SW_SHOWNOACTIVATE */);
          _w.setWindowPos(window, _topmost, 0, 0, 0, 0, _noMove | _noSize | _noActivate | _showWindow);
        }
        _pumpCard(message);
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
      return true;
    } finally {
      _w.destroyWindow(window);
      _card = 0;
      if (bitmap != 0) {
        _w.selectObject(memory, previous);
        _w.deleteObject(bitmap);
      }
      _w.deleteDC(memory);
      _w.releaseDC(0, screenDc);
      for (final pointer in [bitsOut, header, point, size, source, blend, message]) {
        calloc.free(pointer);
      }
    }
  }

  int _badge = 0;

  // The badge's window is left out of every capture (WDA_EXCLUDEFROMCAPTURE, below).
  @override
  BadgeReach get badgeReach => BadgeReach.excluded;

  @override
  Future<bool> showBadge(RgbaImage? badge, {int? pid}) async {
    if (badge == null) {
      if (_badge != 0) _w.destroyWindow(_badge);
      _badge = 0;
      return true;
    }
    final game = pid == null ? 0 : windowOf(pid);
    final anchor = game != 0 ? game : _w.getForegroundWindow();
    final screens = _screenOf(anchor);
    if (screens == null) return false;
    final (_, screen) = screens;
    final scale = cardScale(pid);
    var fresh = false;
    if (_badge == 0) {
      final window = _makeCardWindow(badge.width, badge.height);
      if (window == 0) return false;
      // Viewers must not see it. Windows before 10 version 2004 refuse the flag: no badge there,
      // since the broadcast's screen grab would record it.
      final affinity = _w.setWindowDisplayAffinity;
      if (affinity == null || affinity(window, 0x11 /* WDA_EXCLUDEFROMCAPTURE */) == 0) {
        _w.destroyWindow(window);
        return false;
      }
      _badge = window;
      fresh = true;
    }
    final screenDc = _w.getDC(0);
    final memory = _w.createCompatibleDC(screenDc);
    final bitsOut = calloc<Pointer<Uint8>>();
    final header = calloc<Uint8>(44);
    final ints = header.cast<Int32>();
    ints[0] = 40;
    ints[1] = badge.width;
    ints[2] = -badge.height;
    (header + 12).cast<Uint16>().value = 1;
    (header + 14).cast<Uint16>().value = 32;
    final bitmap = _w.createDIBSection(memory, header, 0, bitsOut, 0, 0);
    final previous = bitmap == 0 ? 0 : _w.selectObject(memory, bitmap);
    final point = calloc<Int32>(2)
      ..[0] = screen[0] + (18 * scale).round()
      ..[1] = screen[1] + (14 * scale).round();
    final size = calloc<Int32>(2)
      ..[0] = badge.width
      ..[1] = badge.height;
    final source = calloc<Int32>(2);
    final blend = calloc<Uint8>(4)
      ..[0] = 0
      ..[1] = 0
      ..[2] = 255
      ..[3] = 1; // AC_SRC_ALPHA
    final message = calloc<Uint8>(48);
    try {
      if (bitmap == 0) return false;
      bitsOut.value.asTypedList(badge.pixels.length).setAll(0, badge.premultipliedBgra());
      _w.updateLayeredWindow(_badge, screenDc, point, size, memory, source, 0, blend, 2 /* ULW_ALPHA */);
      if (fresh) {
        _w.showWindow(_badge, 4 /* SW_SHOWNOACTIVATE */);
        _w.setWindowPos(_badge, _topmost, 0, 0, 0, 0, _noMove | _noSize | _noActivate | _showWindow);
      }
      for (var guard = 0; guard < 32 && _w.peekMessage(message, _badge, 0, 0, 1 /* PM_REMOVE */) != 0; guard++) {
        _w.translateMessage(message);
        _w.dispatchMessage(message);
      }
      return true;
    } finally {
      if (bitmap != 0) {
        _w.selectObject(memory, previous);
        _w.deleteObject(bitmap);
      }
      _w.deleteDC(memory);
      _w.releaseDC(0, screenDc);
      for (final pointer in [bitsOut, header, point, size, source, blend, message]) {
        calloc.free(pointer);
      }
    }
  }

  @override
  Future<bool> notify(String title, String body, {String? icon}) async => false;

  @override
  void dispose() {
    if (_badge != 0) _w.destroyWindow(_badge);
    _badge = 0;
  }
}

/// A game window's outer size for [percent] of the screen's work area: the picture (16:9) as large
/// as fits in that share, plus the window's frame.
({int width, int height}) windowArea({
  required int workWidth,
  required int workHeight,
  required int percent,
  int frameWidth = 0,
  int frameHeight = 0,
}) {
  final share = percent.clamp(30, 100) / 100;
  final boundsWidth = workWidth * share - frameWidth;
  final boundsHeight = workHeight * share - frameHeight;
  var width = boundsWidth;
  var height = width * 9 / 16;
  if (height > boundsHeight) {
    height = boundsHeight;
    width = height * 16 / 9;
  }
  return (width: width.round() + frameWidth, height: height.round() + frameHeight);
}

/// The launcher window's see-through backdrop on Windows, through DWM called from Dart: on
/// Windows 11 22H2 and later the Acrylic system backdrop (what is behind the window, blurred and
/// tinted by DWM, the title bar included, with the frame extended over the client area), before
/// it the accent policy's acrylic blur behind. Either way the pixels Flutter leaves transparent
/// show the backdrop, and the window's frame is dark. DWM draws Acrylic only while
/// the window is active; an inactive window gets the system's solid fallback, as every Windows
/// app's acrylic does. (Both paths were checked on Windows 11 25H2, the accent one by
/// ANYPS5_BACKDROP=accent.)
class WindowsBackdrop implements WindowBackdrop {
  WindowsBackdrop({Map<String, String>? environment}) : _environment = environment ?? Platform.environment;

  final Map<String, String> _environment;
  late final _Win32 _w = _Win32();

  @override
  late final BackdropKind kind = () {
    try {
      return windowsBackdropKind(_build(), override: _environment['ANYPS5_BACKDROP']);
    } on Object {
      return BackdropKind.none;
    }
  }();

  late final _Dwm? _dwm = () {
    try {
      return _Dwm();
    } on Object {
      return null;
    }
  }();

  /// The OS build (26200 is 11 25H2), from RtlGetVersion: GetVersionEx lies to unmanifested apps.
  static int _build() => using((arena) {
    final info = arena<Uint32>(276 ~/ 4); // RTL_OSVERSIONINFOW
    info[0] = 276;
    final rtlGetVersion = DynamicLibrary.open('ntdll.dll')
        .lookupFunction<Int32 Function(Pointer<Uint32>), int Function(Pointer<Uint32>)>('RtlGetVersion');
    return rtlGetVersion(info) == 0 ? info[3] : 0;
  });

  /// The runner's top-level window in this process, shown or not yet.
  int _window() => using((arena) {
    final owner = arena<Uint32>();
    final className = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16(allocator: arena);
    final pid = _w.getCurrentProcessId();
    var window = 0;
    for (var guard = 0; guard < 1000; guard++) {
      window = _w.findWindowEx(0, window, className, nullptr);
      if (window == 0) return 0;
      _w.getWindowThreadProcessId(window, owner);
      if (owner.value == pid) return window;
    }
    return 0;
  });

  @override
  bool apply({required bool seeThrough}) {
    final dwm = _dwm;
    if (dwm == null || kind == BackdropKind.none) return true;
    final window = _window();
    if (window == 0) return false;
    return using((arena) {
      final value = arena<Int32>();
      // The frame (title bar and borders) in its dark colors, over the dark glass.
      value.value = 1;
      dwm.setAttribute(window, 20 /* DWMWA_USE_IMMERSIVE_DARK_MODE */, value, 4);
      // The system backdrop shows where the frame is extended over the client area. The accent
      // policy's blur needs the frame left alone: extended, DWM paints its frame black over it.
      final margins = arena<Int32>(4);
      for (var i = 0; i < 4; i++) {
        margins[i] = seeThrough && kind == BackdropKind.acrylic ? -1 : 0;
      }
      dwm.extendFrame(window, margins);
      if (kind == BackdropKind.acrylic) {
        value.value = seeThrough ? 3 /* DWMSBT_TRANSIENTWINDOW */ : 1 /* DWMSBT_NONE */;
        return dwm.setAttribute(window, 38 /* DWMWA_SYSTEMBACKDROP_TYPE */, value, 4) == 0;
      }
      // ACCENT_POLICY: state, flags, gradient color (AABBGGRR), animation id.
      final accent = arena<Int32>(4);
      // (The plain blur, ACCENT_ENABLE_BLURBEHIND, draws black on Windows 11 25H2: not used.)
      accent[0] = seeThrough ? 4 /* ACCENT_ENABLE_ACRYLICBLURBEHIND */ : 0 /* ACCENT_DISABLED */;
      accent[1] = 2;
      // Barely any tint of its own: the launcher draws the Glass navy over it.
      accent[2] = 0x011C1004;
      accent[3] = 0;
      // WINDOWCOMPOSITIONATTRIBDATA: attribute, (padding), data pointer, data size.
      final data = arena<Uint8>(24);
      data.cast<Uint32>().value = 19; // WCA_ACCENT_POLICY
      (data + 8).cast<IntPtr>().value = accent.address;
      (data + 16).cast<IntPtr>().value = 16;
      return dwm.setComposition?.call(window, data) != 0;
    });
  }
}

/// dwmapi, and user32's SetWindowCompositionAttribute (undocumented, present since Windows 7).
final class _Dwm {
  _Dwm() {
    final dwm = DynamicLibrary.open('dwmapi.dll');
    setAttribute = dwm
        .lookupFunction<
          Int32 Function(IntPtr, Uint32, Pointer<Int32>, Uint32),
          int Function(int, int, Pointer<Int32>, int)
        >('DwmSetWindowAttribute');
    extendFrame = dwm.lookupFunction<Int32 Function(IntPtr, Pointer<Int32>), int Function(int, Pointer<Int32>)>(
      'DwmExtendFrameIntoClientArea',
    );
    try {
      setComposition = DynamicLibrary.open('user32.dll')
          .lookupFunction<Int32 Function(IntPtr, Pointer<Uint8>), int Function(int, Pointer<Uint8>)>(
            'SetWindowCompositionAttribute',
          );
    } on ArgumentError {
      setComposition = null;
    }
  }

  late final int Function(int, int, Pointer<Int32>, int) setAttribute;
  late final int Function(int, Pointer<Int32>) extendFrame;
  late final int Function(int, Pointer<Uint8>)? setComposition;
}
