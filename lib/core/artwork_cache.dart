import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'screenshots.dart' show PngEncoder;

/// Makes one lighter copy of each game's wide background (pic0.png, often 3840x2160 and up to
/// 15 MB) the first time it is needed, away from the interface, and keeps it in a folder of the
/// launcher's cache. The background is then drawn from the copy: the engine never has to decode
/// the big picture while a frame waits for it (that decode showed as one frame of nearly a second
/// on the raster thread when the selection reached such a game).
///
/// Off until [folder] is set, and every picture it cannot read (not a PNG, interlaced, damaged)
/// is shown from the original, as before.
class ArtworkCache extends ChangeNotifier {
  ArtworkCache({this.folder, this.width = 1920, Future<String> Function(String source, String folder, int width)? lighten})
    : _lighten = lighten ?? _lightenAway;

  /// The cache of the running launcher (the launcher sets [folder] at start).
  static final ArtworkCache instance = ArtworkCache();

  /// Where the copies are kept; null leaves the cache off.
  String? folder;

  /// The width the copies are made at (what backgrounds are decoded at anyway).
  final int width;

  final Future<String> Function(String source, String folder, int width) _lighten;

  /// What to show for each picture: its copy, or itself when no copy was needed or possible.
  final Map<String, String> _ready = {};
  final Map<String, Completer<String>> _waiting = {};
  final Queue<String> _pending = Queue();
  bool _working = false;

  bool get active => folder != null;

  /// The file to draw for [source]: itself while the cache is off, the copy once it is made,
  /// null while it is still being made (see [ensure]).
  String? pathFor(String source) => active ? _ready[source] : source;

  /// Clears remembered paths and the queue. Tests use this so one case does not leave state
  /// for the next, and so they can drive [ensure] without spinning an isolate.
  @visibleForTesting
  void clearForTest() {
    _ready.clear();
    _waiting.clear();
    _pending.clear();
    _working = false;
  }

  /// Marks [source] as ready with [shown] without running the lighten isolate. For widget tests
  /// that only care about the fade-in path.
  @visibleForTesting
  void markReadyForTest(String source, String shown) {
    _ready[source] = shown;
    _waiting.remove(source)?.complete(shown);
    notifyListeners();
  }

  /// Makes sure the copy of [source] is being made, before the pictures that were only queued.
  /// Completes with the file to draw, whatever happens.
  Future<String> ensure(String source) {
    final done = _ready[source];
    if (!active || done != null) return Future.value(done ?? source);
    final waiting = _waiting.putIfAbsent(source, Completer<String>.new);
    _pending
      ..remove(source)
      ..addFirst(source);
    unawaited(_work());
    return waiting.future;
  }

  /// Queues the copies of [sources] (a game's background, or null) to be made one at a time
  /// while the launcher is idle, behind what [ensure] asked for.
  void queue(Iterable<String?> sources) {
    if (!active) return;
    for (final source in sources) {
      if (source == null || _ready.containsKey(source) || _pending.contains(source)) continue;
      _pending.addLast(source);
    }
    unawaited(_work());
  }

  /// Drops a remembered path when the file on disk no longer matches the one the copy was made
  /// from (size or modification time changed). A library scan calls this so a picture replaced
  /// while the launcher was running is re-copied instead of showing the old one until the next
  /// start.
  void forgetIfSourceChanged(String source) {
    final done = _ready[source];
    if (done == null || folder == null) return;
    try {
      final file = File(source);
      final stat = file.statSync();
      if (stat.type != FileSystemEntityType.file) {
        _ready.remove(source);
        return;
      }
      final key = _key(source, stat);
      final expected = p.join(folder!, 'bg-$key.png');
      if (done != source && done != expected) {
        _ready.remove(source);
        return;
      }
      // Was shown as itself (small enough then). If the header now says it needs a lighter copy,
      // drop the answer so the next ensure or queue makes one.
      if (done == source) {
        final raf = file.openSync();
        try {
          final header = raf.readSync(33);
          if (header.length < 33) return;
          for (var i = 0; i < 8; i++) {
            if (header[i] != PngReader.signature[i]) return;
          }
          final view = ByteData.sublistView(header);
          if (view.getUint32(8) != 13) return;
          if (String.fromCharCodes(header, 12, 16) != 'IHDR') return;
          final pngWidth = view.getUint32(16);
          final depth = header[24];
          final interlace = header[28];
          if (interlace != 0) return;
          if (pngWidth > width || depth != 8) _ready.remove(source);
        } finally {
          raf.closeSync();
        }
      }
    } on Object {
      // Leave the remembered path if the file cannot be read.
    }
  }

  /// Deletes lighter copies that no current game's background maps to, after a library scan.
  /// Copies of removed games, or of pictures that were replaced (new key), do not stay in the
  /// cache forever.
  void purgeUnused(Iterable<String?> sources) {
    final target = folder;
    if (target == null) return;
    final dir = Directory(target);
    if (!dir.existsSync()) return;
    final keep = <String>{};
    for (final source in sources) {
      if (source == null) continue;
      try {
        final file = File(source);
        final stat = file.statSync();
        if (stat.type != FileSystemEntityType.file) continue;
        keep.add('bg-${_key(source, stat)}.png');
      } on Object {
        // Skip a source that cannot be read.
      }
    }
    for (final entity in dir.listSync()) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (name.startsWith('bg-') && name.endsWith('.png') && !keep.contains(name)) {
        try {
          entity.deleteSync();
        } on Object {
          // Best-effort: a file still open or already gone is left.
        }
      }
    }
  }

  String _key(String source, FileStat stat) =>
      sha1.convert('v1|$source|${stat.size}|${stat.modified.millisecondsSinceEpoch}|$width'.codeUnits).toString();

  Future<void> _work() async {
    if (_working) return;
    _working = true;
    try {
      while (_pending.isNotEmpty) {
        final source = _pending.removeFirst();
        final target = folder;
        if (target == null || _ready.containsKey(source)) continue;
        String shown;
        try {
          shown = await _lighten(source, target, width);
        } on Object {
          shown = source;
        }
        _ready[source] = shown;
        _waiting.remove(source)?.complete(shown);
        notifyListeners();
      }
    } finally {
      _working = false;
    }
  }

  static Future<String> _lightenAway(String source, String folder, int width) =>
      Isolate.run(() => lightenSync(source, folder, width));

  /// The copy of [source] in [folder] at [width] (made when it is not there yet), or [source]
  /// itself when it is no bigger than that, is not an 8 or 16 bit PNG that can be read, or
  /// cannot be written. Slow: for another isolate.
  @visibleForTesting
  static String lightenSync(String source, String folder, int width) {
    try {
      final file = File(source);
      final stat = file.statSync();
      if (stat.type != FileSystemEntityType.file) return source;
      final key = sha1.convert('v1|$source|${stat.size}|${stat.modified.millisecondsSinceEpoch}|$width'.codeUnits);
      final copy = File(p.join(folder, 'bg-$key.png'));
      if (copy.existsSync() && copy.lengthSync() > 0) return copy.path;

      // Only the PNG signature and IHDR (33 bytes) are needed to know if the picture is already
      // small enough; a 4K file is not read in full only to be left alone.
      final raf = file.openSync();
      try {
        final header = raf.readSync(33);
        if (header.length < 33) return source;
        for (var i = 0; i < 8; i++) {
          if (header[i] != PngReader.signature[i]) return source;
        }
        final view = ByteData.sublistView(header);
        if (view.getUint32(8) != 13) return source; // IHDR data length
        if (String.fromCharCodes(header, 12, 16) != 'IHDR') return source;
        final pngWidth = view.getUint32(16);
        final depth = header[24];
        final interlace = header[28];
        if (interlace != 0) return source;
        // Small and plain enough to be decoded cheaply as it is.
        if (pngWidth <= width && depth == 8) return source;
      } finally {
        raf.closeSync();
      }

      final bytes = file.readAsBytesSync();
      final png = PngReader.read(bytes);
      if (png == null) return source;
      final scaled = png.scaled(width);
      final encoded = PngEncoder.rgba(scaled.width, scaled.height, scaled.rgba);
      Directory(folder).createSync(recursive: true);
      final partial = File('${copy.path}.$pid.part');
      partial.writeAsBytesSync(encoded, flush: true);
      partial.renameSync(copy.path);
      return copy.path;
    } on Object {
      return source;
    }
  }
}

/// A picture made smaller: RGBA pixels, opaque.
class ScaledPicture {
  const ScaledPicture(this.width, this.height, this.rgba);

  final int width;
  final int height;
  final Uint8List rgba;
}

/// A PNG read in pieces: the header, and its scanlines unfiltered one at a time.
///
/// Reads the files a game's artwork comes in: not interlaced, 1 to 16 bits, any colour type.
/// ICC profiles and gamma are ignored, and transparency is drawn over black (backgrounds are
/// opaque).
class PngReader {
  PngReader._(this.width, this.height, this.depth, this.colorType, this._palette, this._data);

  final int width;
  final int height;
  final int depth;
  final int colorType;
  final Uint8List? _palette;
  final Uint8List _data;

  static const signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

  /// The PNG in [bytes], or null when it is not one this reads.
  static PngReader? read(Uint8List bytes) {
    if (bytes.length < 33) return null;
    for (var i = 0; i < 8; i++) {
      if (bytes[i] != signature[i]) return null;
    }
    final view = ByteData.sublistView(bytes);
    var offset = 8;
    int? width, height, depth, colorType;
    Uint8List? palette;
    final data = BytesBuilder(copy: false);
    while (offset + 12 <= bytes.length) {
      final length = view.getUint32(offset);
      final type = String.fromCharCodes(bytes, offset + 4, offset + 8);
      final start = offset + 8;
      if (start + length > bytes.length) return null;
      switch (type) {
        case 'IHDR':
          if (length < 13) return null;
          width = view.getUint32(start);
          height = view.getUint32(start + 4);
          depth = bytes[start + 8];
          colorType = bytes[start + 9];
          // Interlaced (Adam7), or a method this does not know.
          if (bytes[start + 10] != 0 || bytes[start + 11] != 0 || bytes[start + 12] != 0) return null;
        case 'PLTE':
          palette = Uint8List.sublistView(bytes, start, start + length);
        case 'IDAT':
          data.add(Uint8List.sublistView(bytes, start, start + length));
      }
      if (type == 'IEND') break;
      offset = start + length + 4;
    }
    if (width == null || height == null || depth == null || colorType == null) return null;
    if (width <= 0 || height <= 0 || width > 16384 || height > 16384) return null;
    final allowed = switch (colorType) {
      0 => const [1, 2, 4, 8, 16],
      3 => const [1, 2, 4, 8],
      2 || 4 || 6 => const [8, 16],
      _ => const <int>[],
    };
    if (!allowed.contains(depth)) return null;
    if (colorType == 3 && (palette == null || palette.length < 3)) return null;
    final inflated = Uint8List.fromList(ZLibDecoder().convert(data.takeBytes()));
    final reader = PngReader._(width, height, depth, colorType, palette, inflated);
    if (inflated.length < reader._stride * height) return null;
    return reader;
  }

  int get _channels => switch (colorType) {
    2 => 3,
    4 => 2,
    6 => 4,
    _ => 1,
  };

  /// Bytes of one scanline, without its filter byte.
  int get _row => (width * _channels * depth + 7) >> 3;

  int get _stride => _row + 1;

  /// Bytes from one pixel to the next for the filters (1 below 8 bits).
  int get _step => depth < 8 ? 1 : _channels * (depth >> 3);

  /// This picture at [target] pixels wide (as it is when it is narrower), each output pixel the
  /// average of the source pixels that fall in it.
  ScaledPicture scaled(int target) {
    final outWidth = width < target ? width : target;
    final outHeight = height * outWidth ~/ width < 1 ? 1 : height * outWidth ~/ width;
    final sums = Uint32List(outWidth * outHeight * 3);
    final counts = Uint16List(outWidth * outHeight);
    final column = Uint16List(width);
    for (var x = 0; x < width; x++) {
      column[x] = x * outWidth ~/ width;
    }
    final row = _row;
    final step = _step;
    var previous = Uint8List(row);
    var current = Uint8List(row);
    for (var y = 0; y < height; y++) {
      final start = y * _stride;
      final filter = _data[start];
      for (var i = 0; i < row; i++) {
        final raw = _data[start + 1 + i];
        final a = i >= step ? current[i - step] : 0;
        final b = previous[i];
        final c = i >= step ? previous[i - step] : 0;
        current[i] = switch (filter) {
          0 => raw,
          1 => (raw + a) & 0xFF,
          2 => (raw + b) & 0xFF,
          3 => (raw + ((a + b) >> 1)) & 0xFF,
          4 => (raw + _paeth(a, b, c)) & 0xFF,
          _ => raw,
        };
      }
      final base = (y * outHeight ~/ height) * outWidth;
      for (var x = 0; x < width; x++) {
        final cell = base + column[x];
        var r = 0, g = 0, b = 0;
        switch (colorType) {
          case 0:
            r = g = b = _gray(current, x);
          case 2:
            final each = depth >> 3;
            r = current[x * 3 * each];
            g = current[x * 3 * each + each];
            b = current[x * 3 * each + 2 * each];
          case 3:
            final index = _bits(current, x);
            final palette = _palette!;
            if (index * 3 + 2 < palette.length) {
              r = palette[index * 3];
              g = palette[index * 3 + 1];
              b = palette[index * 3 + 2];
            }
          case 4:
            final opacity = current[x * 2 * (depth >> 3) + (depth >> 3)];
            r = g = b = (_gray(current, x) * opacity + 127) ~/ 255;
          case 6:
            final jump = depth >> 3;
            final at = x * 4 * jump;
            final alpha = current[at + 3 * jump];
            r = (current[at] * alpha + 127) ~/ 255;
            g = (current[at + jump] * alpha + 127) ~/ 255;
            b = (current[at + 2 * jump] * alpha + 127) ~/ 255;
        }
        sums[cell * 3] += r;
        sums[cell * 3 + 1] += g;
        sums[cell * 3 + 2] += b;
        counts[cell]++;
      }
      final swap = previous;
      previous = current;
      current = swap;
    }
    final rgba = Uint8List(outWidth * outHeight * 4);
    for (var cell = 0; cell < outWidth * outHeight; cell++) {
      final count = counts[cell] == 0 ? 1 : counts[cell];
      rgba[cell * 4] = (sums[cell * 3] + count ~/ 2) ~/ count;
      rgba[cell * 4 + 1] = (sums[cell * 3 + 1] + count ~/ 2) ~/ count;
      rgba[cell * 4 + 2] = (sums[cell * 3 + 2] + count ~/ 2) ~/ count;
      rgba[cell * 4 + 3] = 255;
    }
    return ScaledPicture(outWidth, outHeight, rgba);
  }

  /// A grey pixel as 0 to 255, at any depth (16 bits keep the high byte).
  int _gray(Uint8List line, int x) {
    if (depth == 16) return line[x * _channels * 2];
    if (depth == 8) return line[x * _channels];
    return _bits(line, x) * 255 ~/ ((1 << depth) - 1);
  }

  /// The sample at pixel [x] of a line of 1, 2, 4 or 8 bits per pixel.
  int _bits(Uint8List line, int x) {
    if (depth == 8) return line[x];
    final perByte = 8 ~/ depth;
    final shift = 8 - depth * (x % perByte + 1);
    return (line[x ~/ perByte] >> shift) & ((1 << depth) - 1);
  }

  static int _paeth(int a, int b, int c) {
    final estimate = a + b - c;
    final pa = (estimate - a).abs();
    final pb = (estimate - b).abs();
    final pc = (estimate - c).abs();
    if (pa <= pb && pa <= pc) return a;
    return pb <= pc ? b : c;
  }
}
