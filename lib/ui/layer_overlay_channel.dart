import 'package:flutter/services.dart';

import '../core/desktop/desktop.dart' show RgbaImage;
import '../core/desktop/layer_overlay.dart';

/// The runner's layer-shell surfaces through its "anyps5/overlay" channel
/// (linux/runner/layer_overlay.cc).
class ChannelLayerOverlay implements LayerOverlay {
  const ChannelLayerOverlay();

  static const _channel = MethodChannel('anyps5/overlay');

  @override
  Future<bool> show(
    String name,
    RgbaImage image, {
    required LayerAnchor anchor,
    int left = 0,
    int top = 0,
    double scale = 1,
    double opacity = 1,
  }) => _call('show', {
    'name': name,
    'width': image.width,
    'height': image.height,
    'scale': scale,
    // Cairo's ARGB32 on a little-endian computer, as the runner draws it.
    'pixels': image.premultipliedBgra(),
    'anchor': anchor.name,
    'left': left,
    'top': top,
    'opacity': opacity,
  });

  @override
  Future<bool> update(String name, {required double opacity, required int top}) =>
      _call('update', {'name': name, 'opacity': opacity, 'top': top});

  @override
  Future<bool> hide(String name) => _call('hide', {'name': name});

  Future<bool> _call(String method, Map<String, Object> arguments) async {
    try {
      return await _channel.invokeMethod<bool>(method, arguments) ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
