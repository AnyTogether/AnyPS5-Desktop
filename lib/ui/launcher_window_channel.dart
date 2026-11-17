import 'package:flutter/services.dart';

import '../core/desktop/launcher_window.dart';

/// The launcher's window through the runner's "anyps5/window" channel (windows/runner/
/// flutter_window.cpp, linux/runner/my_application.cc).
class ChannelLauncherWindow implements LauncherWindow {
  const ChannelLauncherWindow();

  static const _channel = MethodChannel('anyps5/window');

  @override
  Future<bool> setFullscreen(bool on) => _call('setFullscreen', on);

  @override
  Future<bool> minimize() => _call('minimize');

  @override
  Future<bool> restore() => _call('restore');

  @override
  Future<bool> close() => _call('close');

  @override
  Future<bool> removeAfterClose(String path) => _call('removeAfterClose', path);

  /// The exit was approved and the child programs are ended: the Windows runner ends the process
  /// after five seconds if its shutdown has not by then (windows/runner/utils.cpp). Not part of
  /// [LauncherWindow]: only the Windows runner answers it, elsewhere it is false.
  Future<bool> armExitWatchdog() => _call('armExitWatchdog');

  @override
  void listen({required void Function(bool fullscreen) fullscreenChanged}) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'fullscreenChanged' && call.arguments is bool) fullscreenChanged(call.arguments as bool);
      return null;
    });
  }

  Future<bool> _call(String method, [Object? argument]) async {
    try {
      return await _channel.invokeMethod<bool>(method, argument) ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
