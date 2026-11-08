import 'dart:ui';

typedef RetroMenuRegion = Future<bool> Function(int? pid, Rect? bounds);

class LauncherDisplay {
  const LauncherDisplay({required this.id, required this.width, required this.height, required this.primary});

  final String id;
  final int width;
  final int height;
  final bool primary;
}

/// The launcher's own window, as far as the launcher changes it: full screen or not, minimized,
/// closed (the runner's "anyps5/window" channel on Windows and Linux).
abstract class LauncherWindow {
  /// Full screen ([on]) or back to the window it was; whether it could.
  Future<bool> setFullscreen(bool on);

  /// Minimized to the taskbar or dock; whether it could.
  Future<bool> minimize();

  /// Back from minimized (Settings › Behaviour › Hide the launcher while a game runs), in front
  /// and with the keyboard; whether it could.
  Future<bool> restore();

  /// Closes the window the way its title bar's close does (the runner posts the close, Flutter
  /// asks the launcher, shuts down and the process ends from its message loop): no exit() with
  /// the engine still drawing. Whether the close was asked.
  Future<bool> close();

  /// [path] (this run's marker) is taken away by the runner once the window has closed and
  /// Flutter has shut down: a crash anywhere in shutting down still leaves it. Whether the
  /// runner will.
  Future<bool> removeAfterClose(String path);

  /// [fullscreenChanged] hears of full screen the system made or ended (the title bar's
  /// Maximize, a double click on it, Win+Up; the window manager's own key on Linux).
  void listen({required void Function(bool fullscreen) fullscreenChanged});
}
