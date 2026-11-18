import 'dart:typed_data';
import 'dart:ui' as ui;

/// A small PNG of a game's [image] for its save state slot: [width] pixels wide, at the game's
/// display [aspect], as its picture is shown. Null when the image could not be drawn or encoded.
Future<Uint8List?> retroStatePicture(ui.Image image, {required double aspect, int width = 240}) async {
  if (!(aspect > 0)) return null;
  final height = (width / aspect).round().clamp(1, width * 4);
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawImageRect(
    image,
    ui.Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..filterQuality = ui.FilterQuality.medium,
  );
  final drawing = recorder.endRecording();
  final small = await drawing.toImage(width, height);
  drawing.dispose();
  try {
    final png = await small.toByteData(format: ui.ImageByteFormat.png);
    return png?.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
  } finally {
    small.dispose();
  }
}
