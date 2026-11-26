import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/artwork_cache.dart';
import 'package:anyps5_desktop/core/screenshots.dart' show PngEncoder;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A PNG made by hand (the reader does not check the CRC): [rows] are the unfiltered scanlines.
Uint8List _png(int width, int height, int depth, int colorType, List<List<int>> rows, {int interlace = 0}) {
  final raw = BytesBuilder();
  for (final row in rows) {
    raw
      ..addByte(0)
      ..add(row);
  }
  final file = BytesBuilder()..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  void chunk(String type, List<int> data) {
    file
      ..add([data.length >> 24 & 0xFF, data.length >> 16 & 0xFF, data.length >> 8 & 0xFF, data.length & 0xFF])
      ..add(type.codeUnits)
      ..add(data)
      ..add(const [0, 0, 0, 0]);
  }

  chunk('IHDR', [0, 0, width >> 8, width & 0xFF, 0, 0, height >> 8, height & 0xFF, depth, colorType, 0, 0, interlace]);
  chunk('IDAT', ZLibEncoder().convert(raw.takeBytes()));
  chunk('IEND', const []);
  return file.takeBytes();
}

Uint8List _rgba(int width, int height, List<int> Function(int x, int y) pixel) {
  final out = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      out.setAll((y * width + x) * 4, [...pixel(x, y), 255]);
    }
  }
  return out;
}

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('anyps5-artwork-test'));
  tearDown(() => temp.deleteSync(recursive: true));

  File picture(String name, Uint8List bytes) => File(p.join(temp.path, name))..writeAsBytesSync(bytes);

  test('a wide picture gets a copy at the target width, with the average of the pixels it covers', () {
    // Left half black, right half white: 40x20 down to 10x5.
    final source = picture('pic0.png', PngEncoder.rgba(40, 20, _rgba(40, 20, (x, y) => x < 20 ? [0, 0, 0] : [255, 255, 255])));
    final shown = ArtworkCache.lightenSync(source.path, p.join(temp.path, 'cache'), 10);
    expect(shown, isNot(source.path));
    final copy = PngReader.read(File(shown).readAsBytesSync())!;
    expect((copy.width, copy.height), (10, 5));
    final pixels = copy.scaled(10).rgba;
    expect(pixels[0], 0);
    expect(pixels[(0 * 10 + 9) * 4], 255);
    expect(File(shown).lengthSync(), lessThan(source.lengthSync()));
  });

  test('the copy is made once: a second call finds it', () {
    final source = picture('pic0.png', PngEncoder.rgba(40, 20, _rgba(40, 20, (x, y) => [x * 5, y * 10, 7])));
    final folder = p.join(temp.path, 'cache');
    final first = ArtworkCache.lightenSync(source.path, folder, 10);
    final stamp = File(first).lastModifiedSync();
    final second = ArtworkCache.lightenSync(source.path, folder, 10);
    expect(second, first);
    expect(File(second).lastModifiedSync(), stamp);
    expect(Directory(folder).listSync().whereType<File>().where((file) => file.path.endsWith('.part')), isEmpty);
  });

  test('a changed picture gets a new copy', () {
    final source = picture('pic0.png', PngEncoder.rgba(40, 20, _rgba(40, 20, (x, y) => [10, 10, 10])));
    final folder = p.join(temp.path, 'cache');
    final first = ArtworkCache.lightenSync(source.path, folder, 10);
    source.writeAsBytesSync(PngEncoder.rgba(40, 24, _rgba(40, 24, (x, y) => [200, 10, 10])));
    expect(ArtworkCache.lightenSync(source.path, folder, 10), isNot(first));
  });

  test('a picture no wider than the target, in 8 bits, is shown as it is', () {
    final source = picture('pic0.png', PngEncoder.rgba(8, 4, _rgba(8, 4, (x, y) => [x, y, 0])));
    expect(ArtworkCache.lightenSync(source.path, p.join(temp.path, 'cache'), 10), source.path);
    expect(Directory(p.join(temp.path, 'cache')).existsSync(), isFalse);
  });

  test('16-bit pictures are reduced to 8 bits even when narrow', () {
    // 2x1 RGB, 16 bits: (255,0,0) and (0,0,255), high bytes first.
    final source = picture('pic0.png', _png(2, 1, 16, 2, [
      [255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 0],
    ]));
    final shown = ArtworkCache.lightenSync(source.path, p.join(temp.path, 'cache'), 10);
    expect(shown, isNot(source.path));
    final copy = PngReader.read(File(shown).readAsBytesSync())!;
    expect(copy.depth, 8);
    expect(copy.scaled(10).rgba.sublist(0, 8), [255, 0, 0, 255, 0, 0, 255, 255]);
  });

  test('palette, grey and transparent pictures are read', () {
    final palette = PngReader.read(_png(4, 1, 2, 3, [[0x1B]]))?.scaled(4);
    // The palette chunk is missing: not readable, so not changed.
    expect(palette, isNull);
    final grey = PngReader.read(_png(2, 1, 8, 0, [[0, 255]]))!.scaled(2).rgba;
    expect(grey.sublist(0, 8), [0, 0, 0, 255, 255, 255, 255, 255]);
    final half = PngReader.read(_png(1, 1, 8, 6, [[200, 100, 50, 0]]))!.scaled(1).rgba;
    expect(half.sublist(0, 3), [0, 0, 0]);
  });

  test('pictures that cannot be read are shown as they are', () {
    final folder = p.join(temp.path, 'cache');
    final damaged = picture('damaged.png', Uint8List.fromList(const [1, 2, 3, 4, 5]));
    final interlaced = picture('interlaced.png', _png(40, 2, 8, 2, [List.filled(120, 0), List.filled(120, 0)], interlace: 1));
    final jpeg = picture('pic0.jpg', Uint8List.fromList(const [0xFF, 0xD8, 0xFF, 0xE0, 0, 16, 0x4A, 0x46, 0x49, 0x46, 0, 1, 1, 0, 0, 1, 0, 1, 0, 0, 0xFF, 0xD9, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]));
    for (final file in [damaged, interlaced, jpeg]) {
      expect(ArtworkCache.lightenSync(file.path, folder, 10), file.path);
    }
    expect(ArtworkCache.lightenSync(p.join(temp.path, 'missing.png'), folder, 10), p.join(temp.path, 'missing.png'));
  });

  group('the queue', () {
    test('is off without a folder: pictures are their own', () async {
      final cache = ArtworkCache(lighten: (source, folder, width) async => fail('not asked'));
      expect(cache.active, isFalse);
      expect(cache.pathFor('a.png'), 'a.png');
      cache.queue(['a.png']);
      expect(await cache.ensure('a.png'), 'a.png');
    });

    test('nothing is shown before a copy is made, then the copy', () async {
      final made = Completer<String>();
      final cache = ArtworkCache(folder: 'cache', lighten: (source, folder, width) => made.future);
      var notified = 0;
      cache.addListener(() => notified++);
      final shown = cache.ensure('a.png');
      expect(cache.pathFor('a.png'), isNull);
      made.complete('cache/a-small.png');
      expect(await shown, 'cache/a-small.png');
      expect(cache.pathFor('a.png'), 'cache/a-small.png');
      expect(notified, 1);
    });

    test('what is asked for jumps the queue, one copy at a time', () async {
      final order = <String>[];
      final gates = <String, Completer<String>>{};
      var running = 0;
      var most = 0;
      final cache = ArtworkCache(
        folder: 'cache',
        lighten: (source, folder, width) async {
          order.add(source);
          running++;
          most = running > most ? running : most;
          final result = await (gates[source] = Completer<String>()).future;
          running--;
          return result;
        },
      );
      cache.queue(['a.png', 'b.png', 'c.png']);
      await Future<void>.delayed(Duration.zero);
      expect(order, ['a.png']);
      final wanted = cache.ensure('c.png');
      gates['a.png']!.complete('a2');
      await Future<void>.delayed(Duration.zero);
      expect(order, ['a.png', 'c.png']);
      gates['c.png']!.complete('c2');
      expect(await wanted, 'c2');
      await Future<void>.delayed(Duration.zero);
      gates['b.png']!.complete('b2');
      await Future<void>.delayed(Duration.zero);
      expect(order, ['a.png', 'c.png', 'b.png']);
      expect(most, 1);
      expect([cache.pathFor('a.png'), cache.pathFor('b.png'), cache.pathFor('c.png')], ['a2', 'b2', 'c2']);
    });

    test('a failed copy leaves the picture as it is', () async {
      final cache = ArtworkCache(folder: 'cache', lighten: (source, folder, width) async => throw const FileSystemException('full'));
      expect(await cache.ensure('a.png'), 'a.png');
      expect(cache.pathFor('a.png'), 'a.png');
    });
  });
}
