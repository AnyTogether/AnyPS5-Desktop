import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// A game's pictures as a phone gets them, so a whole library fits through the control channel
/// in a moment: at most [iconSide] and [backgroundSide] pixels on the longest side, 160 for a
/// trophy's icon, as on the Mac. The Mac writes JPEG; Flutter's engine writes only PNG, and the
/// phone reads either. A picture that cannot be decoded goes as it is.
class PhoneArt {
  static const iconSide = 256;
  static const backgroundSide = 1280;
  static const trophySide = 160;

  /// The most kept in memory; a phone asks again only when a picture changed.
  static const keptBytes = 64 * 1024 * 1024;

  final LinkedHashMap<String, String> _kept = LinkedHashMap();
  var _keptSize = 0;
  Future<void> _turn = Future.value();

  /// The picture at [path] as base64, at most [side] pixels a side; null without a picture (a
  /// missing file, or an empty path).
  Future<String?> encoded(String? path, int side) {
    if (path == null) return Future.value();
    final result = _turn.then((_) => _encoded(path, side));
    // One at a time: a phone asks for a whole library at once.
    _turn = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  Future<String?> _encoded(String path, int side) async {
    final Uint8List source;
    final DateTime modified;
    try {
      final file = File(path);
      modified = await file.lastModified();
      source = await file.readAsBytes();
    } on FileSystemException {
      return null;
    }
    final key = '$path@${modified.millisecondsSinceEpoch}@$side';
    final known = _kept.remove(key);
    if (known != null) {
      _kept[key] = known;
      return known;
    }
    final text = base64.encode(await smaller(source, side));
    _kept[key] = text;
    _keptSize += text.length;
    while (_keptSize > keptBytes && _kept.length > 1) {
      final oldest = _kept.keys.first;
      _keptSize -= _kept.remove(oldest)!.length;
    }
    return text;
  }

  /// [source] at most [side] pixels on its longest side, or [source] itself when it is not larger
  /// than that, cannot be decoded, or would not get any smaller.
  static Future<Uint8List> smaller(Uint8List source, int side) async {
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(source);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final long = math.max(descriptor.width, descriptor.height);
      if (long <= side || long == 0) return source;
      final scale = side / long;
      final codec = await descriptor.instantiateCodec(
        targetWidth: math.max(1, (descriptor.width * scale).round()),
        targetHeight: math.max(1, (descriptor.height * scale).round()),
      );
      final frame = await codec.getNextFrame();
      codec.dispose();
      final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      frame.image.dispose();
      if (png == null || png.lengthInBytes >= source.length) return source;
      return png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
    } on Object {
      return source;
    } finally {
      descriptor?.dispose();
      buffer?.dispose();
    }
  }
}
