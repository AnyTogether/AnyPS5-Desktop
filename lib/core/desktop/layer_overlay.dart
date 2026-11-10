import 'desktop.dart' show RgbaImage;

/// Where a surface of the [LayerOverlay] sits on the screen.
enum LayerAnchor {
  /// Centred at the top edge (a card).
  top,

  /// The top left corner (the LIVE badge).
  topLeft,
}

/// Surfaces over the game under Wayland: the runner's wlr-layer-shell surfaces on the overlay
/// layer, above full-screen windows, never taking the keyboard or the mouse (linux/runner/
/// layer_overlay.cc, its "anyps5/overlay" channel). Each has a name ("card", "badge"); showing one
/// again replaces its picture.
abstract class LayerOverlay {
  /// Shows [image] as the surface [name], [left] and [top] from its corner in the desktop's own
  /// units, its pixels drawn at [scale] (2: two pixels to a unit) and [opacity].
  Future<bool> show(
    String name,
    RgbaImage image, {
    required LayerAnchor anchor,
    int left = 0,
    int top = 0,
    double scale = 1,
    double opacity = 1,
  });

  /// The surface [name] at [opacity], [top] from the top edge: a card coming in or going.
  Future<bool> update(String name, {required double opacity, required int top});

  /// Takes the surface [name] away.
  Future<bool> hide(String name);
}

/// What the runner said about layer shell before the launcher started (ANYPS5_LAYER_SHELL): the
/// first monitor's scale factor when the compositor has it and gtk-layer-shell is installed,
/// null otherwise.
int? layerShellScale(Map<String, String> environment) {
  final scale = int.tryParse(environment['ANYPS5_LAYER_SHELL'] ?? '');
  return scale != null && scale > 0 ? scale : null;
}
