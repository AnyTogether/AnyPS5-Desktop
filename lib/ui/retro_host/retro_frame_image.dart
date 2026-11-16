import 'dart:async';
import 'dart:ffi';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../../core/retro_host/frame_ring.dart';
import '../../core/retro_host/retro_host_client.dart';
import '../../core/retro_host/retro_host_protocol.dart';

/// The launcher's own copy of one pinned frame. The copy is taken as soon as the frame message
/// arrives, because the host may write the pinned slot again after the next message.
class RetroFramePixels {
  const RetroFramePixels(this.bytes, this.width, this.height, this.format);

  /// Copies [frame]'s `height` rows of `width` × 4 bytes out of the ring.
  factory RetroFramePixels.copy(PinnedFrame frame) => RetroFramePixels(
    Uint8List.fromList(frame.pixels.asTypedList(frame.width * frame.height * 4)),
    frame.width,
    frame.height,
    frame.pixelFormat == RetroPixelFormat.bgra8 ? ui.PixelFormat.bgra8888 : ui.PixelFormat.rgba8888,
  );

  final Uint8List bytes;
  final int width;
  final int height;
  final ui.PixelFormat format;

  /// Uploads the copy as an image.
  Future<ui.Image> toImage() {
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(bytes, width, height, format, done.complete);
    return done.future;
  }
}

/// The picture of the newest drawn frame of a [frames] stream, as an image the UI can paint. Only
/// frames of the current game are shown; frames can be skipped, so while one image is being made
/// only the newest frame that arrived meanwhile is kept for the next.
class RetroFrameImage extends ChangeNotifier implements ValueListenable<ui.Image?> {
  RetroFrameImage(Stream<RetroFrameEvent> frames) {
    _subscription = frames.listen(_onFrame);
  }

  late final StreamSubscription<RetroFrameEvent> _subscription;
  ui.Image? _image;
  RetroFramePixels? _next;
  bool _uploading = false;
  bool _disposed = false;
  int _generation = 0;

  /// The image shown now; null before the first frame of the current game. It belongs to this
  /// object: a painter that keeps it past the next change must keep a clone.
  @override
  ui.Image? get value => _image;

  /// How many frames were turned into images; a frame skipped for a newer one is not counted.
  int get shown => _shown;
  int _shown = 0;

  /// Whether frames are shown. While false, frames are ignored, so a game that has ended or is
  /// being shut down cannot bring a picture back after [clear].
  bool accepting = true;

  void _onFrame(RetroFrameEvent event) {
    final frame = event.frame;
    if (!event.drawn || frame == null || _disposed || !accepting) return;
    _next = RetroFramePixels.copy(frame);
    if (!_uploading) unawaited(_upload());
  }

  Future<void> _upload() async {
    _uploading = true;
    while (_next != null && !_disposed) {
      final pixels = _next!;
      _next = null;
      final generation = _generation;
      final image = await pixels.toImage();
      if (_disposed || !accepting || generation != _generation) {
        image.dispose();
        continue;
      }
      _image?.dispose();
      _image = image;
      _shown++;
      notifyListeners();
    }
    _uploading = false;
  }

  /// Stops showing the last picture, for a game that ended or a new game that has no frame yet.
  void clear() {
    _generation++;
    _next = null;
    if (_image == null) return;
    _image!.dispose();
    _image = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _next = null;
    unawaited(_subscription.cancel());
    _image?.dispose();
    _image = null;
    super.dispose();
  }
}
