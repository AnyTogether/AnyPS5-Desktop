import 'dart:typed_data';

import 'package:anyps5_desktop/core/desktop/desktop.dart';
import 'package:flutter_test/flutter_test.dart';

/// The pure parts of the game's start cover: its fade and how its picture is cut to a screen.
void main() {
  group('coverOpacity', () {
    const fade = Duration(milliseconds: 700);

    test('opaque until the window has settled', () {
      expect(coverOpacity(const Duration(milliseconds: -300), fade), 1);
      expect(coverOpacity(const Duration(milliseconds: -1), fade), 1);
    });

    test('starts at 1, ends at 0, never rises', () {
      expect(coverOpacity(Duration.zero, fade), 1);
      expect(coverOpacity(fade, fade), 0);
      expect(coverOpacity(fade * 2, fade), 0);
      var last = 1.0;
      for (var ms = 0; ms <= 700; ms += 20) {
        final now = coverOpacity(Duration(milliseconds: ms), fade);
        expect(now, lessThanOrEqualTo(last));
        last = now;
      }
    });

    test('is half way in the middle (an ease in and out)', () {
      expect(coverOpacity(const Duration(milliseconds: 350), fade), closeTo(0.5, 1e-9));
    });

    test('a zero fade goes at once', () {
      expect(coverOpacity(Duration.zero, Duration.zero), 0);
      expect(coverOpacity(const Duration(milliseconds: -1), Duration.zero), 1);
    });

    test('the times are the ones the start is tuned for', () {
      expect(coverFade, const Duration(milliseconds: 700), reason: '600-800 ms, as the console');
      expect(coverHoldLimit, greaterThan(coverSettle));
      expect(coverWindowWait, lessThan(const Duration(minutes: 3)), reason: 'under the engine window wait');
    });
  });

  group('coverScale', () {
    test('covers the screen: the larger ratio, a hair more', () {
      expect(coverScale(1000, 500, 2000, 1000), closeTo(2.004, 1e-9));
      expect(coverScale(1000, 1000, 1920, 1080), closeTo(1.92 * 1.002, 1e-9));
      expect(coverScale(1000, 500, 1000, 1000), closeTo(2.004, 1e-9));
    });

    test('an empty size changes nothing', () {
      expect(coverScale(0, 0, 1920, 1080), 1);
    });
  });

  group('cropCentered', () {
    // A 4 x 2 picture whose pixel at (x, y) has red = x, green = y.
    RgbaImage grid(int width, int height) {
      final pixels = Uint8List(width * height * 4);
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          final at = (y * width + x) * 4;
          pixels[at] = x;
          pixels[at + 1] = y;
          pixels[at + 3] = 255;
        }
      }
      return RgbaImage(width, height, pixels);
    }

    test('the same size is the same picture', () {
      final image = grid(4, 2);
      expect(identical(cropCentered(image, 4, 2), image), isTrue);
    });

    test('takes the middle of a larger picture', () {
      final out = cropCentered(grid(6, 4), 2, 2);
      expect([out.width, out.height], [2, 2]);
      // Columns 2 and 3, rows 1 and 2 of the source.
      expect(out.pixels.sublist(0, 4), [2, 1, 0, 255]);
      expect(out.pixels.sublist(4, 8), [3, 1, 0, 255]);
      expect(out.pixels.sublist(8, 12), [2, 2, 0, 255]);
      expect(out.pixels.sublist(12, 16), [3, 2, 0, 255]);
    });

    test('a picture that is wider only is cut at the sides', () {
      final out = cropCentered(grid(6, 2), 2, 2);
      expect(out.pixels.sublist(0, 4), [2, 0, 0, 255]);
      expect(out.pixels.sublist(12, 16), [3, 1, 0, 255]);
    });

    test('what a smaller picture does not reach is opaque black', () {
      final out = cropCentered(grid(2, 2), 4, 4);
      expect([out.width, out.height], [4, 4]);
      // The corner outside the picture.
      expect(out.pixels.sublist(0, 4), [0, 0, 0, 255]);
      // The picture's first pixel lands at (1, 1).
      expect(out.pixels.sublist((1 * 4 + 1) * 4, (1 * 4 + 1) * 4 + 4), [0, 0, 0, 255]);
      expect(out.pixels.sublist((1 * 4 + 2) * 4, (1 * 4 + 2) * 4 + 4), [1, 0, 0, 255]);
      expect(out.pixels.sublist((2 * 4 + 2) * 4, (2 * 4 + 2) * 4 + 4), [1, 1, 0, 255]);
      for (var index = 3; index < out.pixels.length; index += 4) {
        expect(out.pixels[index], 255);
      }
    });
  });
}
