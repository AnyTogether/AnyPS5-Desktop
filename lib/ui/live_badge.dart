import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../core/desktop/desktop.dart';
import 'strings.dart';
import 'theme.dart';

/// The small LIVE badge over the game while it is broadcast, as on the Mac: a red capsule with a
/// dot and LIVE (amber while it reconnects) and the time next to it, on a dark pill. Drawn straight
/// onto a canvas into pixels, for a window of the system's own above the game.
abstract final class LiveBadge {
  static const _height = 26.0;
  static const _tall = 44.0;

  static Future<RgbaImage> render(bool live, String time, double scale) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.scale(scale);
    final label = _painter(T.text('broadcastLiveBadge'), 13, FontWeight.w700, tracking: 1.2);
    final clock = _painter(time, 13, FontWeight.w600);
    const dot = 7.0;
    const dotGap = 7.0;
    const pad = 11.0;
    final pillWidth = pad + dot + dotGap + label.width + pad;
    final width = pillWidth + 9 + clock.width + pad;
    final track = RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, width, _height), const Radius.circular(_height / 2));
    canvas.drawRRect(track, Paint()..color = Colors.black.withValues(alpha: 0.55));
    final pill = RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, pillWidth, _height), const Radius.circular(_height / 2));
    canvas.drawRRect(pill, Paint()..color = live ? const Color(0xFFEB2933) : const Color(0xFFF29926));
    canvas.drawCircle(const Offset(pad + dot / 2, _height / 2), dot / 2, Paint()..color = Colors.white);
    label.paint(canvas, Offset(pad + dot + dotGap, (_height - label.height) / 2));
    clock.paint(canvas, Offset(pillWidth + 9, (_height - clock.height) / 2));
    label.dispose();
    clock.dispose();
    final image = await recorder.endRecording().toImage((width * scale).ceil(), (_tall * scale).ceil());
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
      return RgbaImage(image.width, image.height, Uint8List.view(bytes!.buffer));
    } finally {
      image.dispose();
    }
  }

  static TextPainter _painter(String text, double size, FontWeight weight, {double tracking = 0}) => TextPainter(
    text: TextSpan(
      text: text,
      style: AppText.display(size, weight: weight, color: Colors.white).copyWith(letterSpacing: tracking),
    ),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();
}
