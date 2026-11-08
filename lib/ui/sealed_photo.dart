import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:path/path.dart' as p;

/// A photo made ready to be sealed: decoded and drawn again as a new PNG, so nothing of the
/// original file goes along: no location, no camera, no EXIF or XMP at all. (The server strips
/// plain uploads itself, but it cannot open a sealed one.)
class SealedPhoto {
  const SealedPhoto(this.bytes, this.width, this.height);

  final Uint8List bytes;
  final int width;
  final int height;

  String get type => 'image/png';

  /// The longest side kept: sharp on any screen the launcher runs on.
  static const maxSide = 2560;

  /// The server's limit for a photo (10 MB): the sealed file is 16 bytes more.
  static const maxBytes = 10 * 1024 * 1024 - 16;

  /// A bigger picture is refused before it is decoded, as the server does.
  static const maxPixels = 40000000;

  /// Larger files are not read at all.
  static const maxSourceBytes = 50 * 1024 * 1024;

  /// Picture files that can be chosen or dropped into a chat: the kinds the launcher can decode.
  static const extensions = ['png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp'];

  /// Whether [path] names one of [extensions].
  static bool isPictureFile(String path) => extensions.contains(p.extension(path).replaceFirst('.', '').toLowerCase());

  /// [source] decoded and written again at most [maxSide] a side, smaller still until the PNG
  /// fits [maxBytes]; throws FormatException on bytes that are no picture.
  static Future<SealedPhoto> clean(Uint8List source, {int side = maxSide, int limit = maxBytes}) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(source);
    final ui.ImageDescriptor descriptor;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
    } on Object {
      buffer.dispose();
      throw const FormatException('not a picture');
    }
    try {
      final width = descriptor.width;
      final height = descriptor.height;
      if (width <= 0 || height <= 0 || width * height > maxPixels) throw const FormatException('not a picture we take');
      var longest = side;
      while (true) {
        final scale = (width > height ? width : height) > longest ? longest / (width > height ? width : height) : 1.0;
        final outWidth = (width * scale).round().clamp(1, width);
        final outHeight = (height * scale).round().clamp(1, height);
        final png = await _draw(descriptor, outWidth, outHeight);
        if (png.length <= limit || longest <= 256) {
          if (png.length > limit) throw const FormatException('too big');
          return SealedPhoto(png, outWidth, outHeight);
        }
        longest = (longest * 0.75).round();
      }
    } finally {
      descriptor.dispose();
      buffer.dispose();
    }
  }

  static Future<Uint8List> _draw(ui.ImageDescriptor descriptor, int width, int height) async {
    final codec = await descriptor.instantiateCodec(targetWidth: width, targetHeight: height);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    // Drawn onto a new picture: only the pixels come across.
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawImageRect(
      image,
      ui.Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      ui.Paint()..filterQuality = ui.FilterQuality.medium,
    );
    final picture = recorder.endRecording();
    final redrawn = await picture.toImage(width, height);
    final png = await redrawn.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    redrawn.dispose();
    picture.dispose();
    codec.dispose();
    if (png == null) throw const FormatException('the picture could not be written');
    return png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
  }
}
