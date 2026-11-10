import 'dart:typed_data';

/// Pixels, top row first, four bytes each: red, green, blue, alpha (not premultiplied).
class RgbaImage {
  RgbaImage(this.width, this.height, this.pixels) {
    if (pixels.length != width * height * 4) {
      throw ArgumentError('${width}x$height RGBA needs ${width * height * 4} bytes, not ${pixels.length}');
    }
  }

  final int width;
  final int height;
  final Uint8List pixels;

  /// Premultiplied BGRA, as Windows' layered windows and X11's 32-bit visuals take it, with
  /// every alpha scaled by [opacity] (0 to 1).
  Uint8List premultipliedBgra([double opacity = 1]) {
    final out = Uint8List(pixels.length);
    final level = (opacity.clamp(0.0, 1.0) * 255).round();
    for (var index = 0; index < pixels.length; index += 4) {
      final alpha = pixels[index + 3] * level ~/ 255;
      out[index] = pixels[index + 2] * alpha ~/ 255;
      out[index + 1] = pixels[index + 1] * alpha ~/ 255;
      out[index + 2] = pixels[index] * alpha ~/ 255;
      out[index + 3] = alpha;
    }
    return out;
  }

  /// BGRA or BGRX rows from a capture ([stride] bytes each) as opaque RGBA.
  static RgbaImage fromBgra(int width, int height, Uint8List bgra, {int? stride}) {
    final rowBytes = stride ?? width * 4;
    final out = Uint8List(width * height * 4);
    var target = 0;
    for (var y = 0; y < height; y++) {
      var source = y * rowBytes;
      for (var x = 0; x < width; x++) {
        out[target] = bgra[source + 2];
        out[target + 1] = bgra[source + 1];
        out[target + 2] = bgra[source];
        out[target + 3] = 255;
        target += 4;
        source += 4;
      }
    }
    return RgbaImage(width, height, out);
  }
}

/// What the launcher does with windows on the desktop, beside its own: the game's (in front, full
/// screen, its picture) and a card over it that never takes the keyboard or the mouse from it.
abstract class DesktopWindows {
  /// The launcher's window in front of everything, the game's included (PS on a controller).
  Future<bool> raiseLauncher();

  /// The game's window in front again, with the keyboard.
  Future<bool> focusGame(int pid);

  /// Whether one of the launcher's own windows is the one in front (has the keyboard): false
  /// while a game's window or any other program's is, and for the trophy card, which never takes
  /// input. Asked at each controller event, so it is quick. Null where this desktop cannot tell
  /// (Wayland, tests): then the window focus Flutter reports is all there is.
  bool? launcherFocused();

  /// For an engine that does not read ANYPS5_FULLSCREEN and ANYPS5_WINDOW_SIZE (upstream's):
  /// once the game's window opens, sizes it to [windowSize] percent of its screen, or presses
  /// F11 for it (upstream's own full-screen key). Returns whether it could.
  Future<bool> applyDisplay(int pid, {required bool fullscreen, required int windowSize});

  /// Presses the key [key] (as the controls name it: 'Escape', 'Return', 'P') in the game's
  /// window and lets go of it [hold] later: the game's Options, so it pauses before the quick menu
  /// covers it. Returns whether it could.
  Future<bool> pressKey(int pid, String key, {Duration hold = const Duration(milliseconds: 100)});

  /// The game's window as it is on screen now, null when it cannot be read.
  Future<RgbaImage?> captureGame(int pid);

  /// The size a card's pixels should be drawn at for the screen the game is on (1 at 96 dpi).
  double cardScale(int? pid);

  /// Whether a card can be drawn over the game here (Wayland gives a client no way to place a
  /// window above another program's but the compositor's layer shell, which GNOME does not have:
  /// [notify] is the way there).
  bool get canShowCard;

  /// Shows [card] at the top of the game's screen for a few seconds, above the game, never taking
  /// its input; completes when it has gone. False when this desktop cannot (then
  /// [notify] is the way).
  Future<bool> showCard(RgbaImage card, {int? pid});

  /// The small badge over the game (the top left of its screen, clicks passing through), drawn
  /// over and over as it changes; null takes it away. False where there is no such window, or
  /// where it would be in the picture now (X11 without a compositing manager).
  Future<bool> showBadge(RgbaImage? badge, {int? pid});

  /// How the badge stays out of what is recorded here.
  BadgeReach get badgeReach;

  /// A system notification, where a card cannot be shown (GNOME under Wayland); [icon] is a PNG
  /// file.
  Future<bool> notify(String title, String body, {String? icon});

  void dispose();
}

/// How the LIVE badge over the game stays out of the picture viewers see.
enum BadgeReach {
  /// No badge here: nothing can be drawn over the game (GNOME under Wayland, no display, tests).
  none,

  /// Out of every picture recorded: Windows leaves it out of every capture
  /// (WDA_EXCLUDEFROMCAPTURE), as the Mac's does, and under Wayland the portal shares the game's
  /// window alone, the badge a layer-shell surface over it.
  excluded,

  /// X11: out of a recording of the game's window by itself (x11grab's window_id under a
  /// compositing manager, which keeps each window's picture apart), in one of the screen.
  windowRecordingOnly,
}

/// Where a window's picture is on the screen, in pixels: what Remote Play and broadcasting
/// record.
class ScreenArea {
  const ScreenArea(this.x, this.y, this.width, this.height, {this.window});
  final int x;
  final int y;
  final int width;
  final int height;

  /// The X11 window this is the picture of, for recording it by itself; null elsewhere.
  final int? window;

  @override
  bool operator ==(Object other) =>
      other is ScreenArea &&
      other.x == x &&
      other.y == y &&
      other.width == width &&
      other.height == height &&
      other.window == window;

  @override
  int get hashCode => Object.hash(x, y, width, height, window);

  @override
  String toString() => '${width}x$height at $x,$y';
}

/// A desktop that can say where the game's window is (Windows, X11), for recording it.
abstract interface class GameAreas {
  /// The game's window inside its frame, on the screen in pixels; null when it has none open
  /// or it is minimised.
  ScreenArea? gameArea(int pid);

  /// The game's window title, as a window capturer lists it (share play picks its window by it).
  String? gameTitle(int pid);
}

/// A desktop the launcher does nothing with (tests, unknown systems).
class NoDesktop implements DesktopWindows {
  const NoDesktop();

  @override
  Future<bool> raiseLauncher() async => false;
  @override
  Future<bool> focusGame(int pid) async => false;
  @override
  bool? launcherFocused() => null;
  @override
  Future<bool> applyDisplay(int pid, {required bool fullscreen, required int windowSize}) async => false;
  @override
  Future<bool> pressKey(int pid, String key, {Duration hold = const Duration(milliseconds: 100)}) async => false;
  @override
  Future<RgbaImage?> captureGame(int pid) async => null;
  @override
  double cardScale(int? pid) => 1;
  @override
  bool get canShowCard => false;
  @override
  Future<bool> showCard(RgbaImage card, {int? pid}) async => false;
  @override
  Future<bool> showBadge(RgbaImage? badge, {int? pid}) async => false;
  @override
  BadgeReach get badgeReach => BadgeReach.none;
  @override
  Future<bool> notify(String title, String body, {String? icon}) async => false;
  @override
  void dispose() {}
}

/// Where a card goes: centred at the top of a screen, below its edge by [margin] (in pixels
/// already scaled), sliding down by [slide] as it comes in ([t] from 0 to 1).
({int x, int y}) cardPosition({
  required int screenLeft,
  required int screenTop,
  required int screenWidth,
  required int cardWidth,
  required int margin,
  required int slide,
  required double t,
}) {
  final eased = 1 - (1 - t.clamp(0.0, 1.0)) * (1 - t.clamp(0.0, 1.0)) * (1 - t.clamp(0.0, 1.0));
  return (x: screenLeft + (screenWidth - cardWidth) ~/ 2, y: screenTop + margin - (slide * (1 - eased)).round());
}

/// A card's life: comes in, stays, goes; its opacity and slide at [elapsed].
({double opacity, double t, bool done}) cardPhase(
  Duration elapsed, {
  Duration enter = const Duration(milliseconds: 200),
  Duration stay = const Duration(milliseconds: 4600),
  Duration leave = const Duration(milliseconds: 260),
}) {
  final ms = elapsed.inMicroseconds / 1000;
  final enterMs = enter.inMilliseconds;
  final stayMs = stay.inMilliseconds;
  final leaveMs = leave.inMilliseconds;
  if (ms < enterMs) {
    final t = ms / enterMs;
    return (opacity: t, t: t, done: false);
  }
  if (ms < enterMs + stayMs) return (opacity: 1, t: 1, done: false);
  final out = (ms - enterMs - stayMs) / leaveMs;
  if (out >= 1) return (opacity: 0, t: 1, done: true);
  return (opacity: 1 - out, t: 1, done: false);
}

/// The keys the controls name ([Controls.keyName]) as each desktop's own key codes.
abstract final class KeyCodes {
  /// A Windows virtual-key code, or null for a key this does not know.
  static int? windowsVirtualKey(String name) {
    if (RegExp(r'^[A-Z0-9]$').hasMatch(name)) return name.codeUnitAt(0);
    final function = RegExp(r'^F([1-9]|1[0-2])$').firstMatch(name);
    if (function != null) return 0x6F + int.parse(function.group(1)!);
    return switch (name) {
      'Return' => 0x0D,
      'Escape' => 0x1B,
      'Backspace' => 0x08,
      'Tab' => 0x09,
      'Space' => 0x20,
      'Home' => 0x24,
      'End' => 0x23,
      'PageUp' => 0x21,
      'PageDown' => 0x22,
      'Delete' => 0x2E,
      'Left' => 0x25,
      'Up' => 0x26,
      'Right' => 0x27,
      'Down' => 0x28,
      _ => null,
    };
  }

  /// An X11 keysym name, as xdotool takes it, or null.
  static String? x11Keysym(String name) {
    if (RegExp(r'^[A-Z]$').hasMatch(name)) return name.toLowerCase();
    if (RegExp(r'^[0-9]$').hasMatch(name)) return name;
    if (RegExp(r'^F([1-9]|1[0-2])$').hasMatch(name)) return name;
    return switch (name) {
      'Return' => 'Return',
      'Escape' => 'Escape',
      'Backspace' => 'BackSpace',
      'Tab' => 'Tab',
      'Space' => 'space',
      'Home' => 'Home',
      'End' => 'End',
      'PageUp' => 'Prior',
      'PageDown' => 'Next',
      'Delete' => 'Delete',
      'Left' => 'Left',
      'Up' => 'Up',
      'Right' => 'Right',
      'Down' => 'Down',
      _ => null,
    };
  }
}
