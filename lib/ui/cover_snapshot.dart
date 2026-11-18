import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart' show GlobalKey;

import '../core/desktop/desktop.dart';

/// The cover as it is on screen now, drawn at [width] x [height] pixels (its middle, when the
/// window it is in has another shape): the picture that fades over the game. Null when there is
/// no cover on screen or it cannot be read; the game then starts as it did without it.
Future<RgbaImage?> snapshotCover(GlobalKey boundary, int width, int height) async {
  try {
    final object = boundary.currentContext?.findRenderObject();
    if (object is! RenderRepaintBoundary || !object.hasSize || object.size.isEmpty) return null;
    final image = await object.toImage(pixelRatio: coverScale(object.size.width, object.size.height, width, height));
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (bytes == null) return null;
      final whole = RgbaImage(image.width, image.height, bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes));
      return cropCentered(whole, width, height);
    } finally {
      image.dispose();
    }
  } on Object {
    return null;
  }
}
