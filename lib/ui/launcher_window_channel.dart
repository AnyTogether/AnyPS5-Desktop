import 'package:flutter/services.dart';

import '../core/desktop/launcher_window.dart';
import '../core/retro_optimizer.dart';

/// The launcher's window through the runner's "anyps5/window" channel (windows/runner/
/// flutter_window.cpp, linux/runner/my_application.cc).
class ChannelLauncherWindow implements LauncherWindow {
  const ChannelLauncherWindow();

  static const _channel = MethodChannel('anyps5/window');

  Future<List<LauncherDisplay>> displays() async {
    try {
      final result = await _channel.invokeMethod<Object?>('displays');
      if (result is! List<Object?>) return const [];
      final displays = <LauncherDisplay>[];
      for (final entry in result) {
        if (entry is! Map<Object?, Object?>) return const [];
        final id = entry['id'];
        final width = entry['width'];
        final height = entry['height'];
        final primary = entry['primary'];
        if (id is! String ||
            id.isEmpty ||
            width is! int ||
            width <= 0 ||
            height is! int ||
            height <= 0 ||
            primary is! bool) {
          return const [];
        }
        displays.add(LauncherDisplay(id: id, width: width, height: height, primary: primary));
      }
      return displays;
    } on PlatformException {
      return const [];
    } on MissingPluginException {
      return const [];
    }
  }

  Future<bool> moveToDisplay(String id, {int? pid}) => _call('moveToDisplay', {'id': id, 'pid': ?pid});

  Future<bool> gameWindowReady(int pid) => _call('gameWindowReady', pid);

  Future<bool> setRetroMenuRegion(int? pid, Rect? bounds) => _call(
    'retroMenuRegion',
    pid == null || bounds == null
        ? null
        : [pid, bounds.left.floor(), bounds.top.floor(), bounds.right.ceil(), bounds.bottom.ceil()],
  );

  Future<List<RetroAdapter>> retroAdapters() async {
    try {
      final result = await _channel.invokeMethod<Object?>('retroAdapters');
      if (result is! List<Object?>) return const [];
      final adapters = <RetroAdapter>[];
      for (final entry in result) {
        if (entry is! Map<Object?, Object?>) return const [];
        final name = entry['name'];
        final dedicatedBytes = entry['dedicatedBytes'];
        if (name is! String || name.isEmpty || dedicatedBytes is! int || dedicatedBytes < 0) return const [];
        adapters.add(RetroAdapter(name: name, dedicatedBytes: dedicatedBytes));
      }
      return adapters;
    } on PlatformException {
      return const [];
    } on MissingPluginException {
      return const [];
    }
  }

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
