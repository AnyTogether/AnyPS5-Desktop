import 'package:anyps5_desktop/core/desktop/desktop.dart';
import 'package:flutter_test/flutter_test.dart';

/// When the launcher must not press F11: the game's window is full screen already.
void main() {
  const screen = [0, 0, 1920, 1080];

  test('a frameless window over the whole monitor is full screen', () {
    expect(windowIsFullscreen(window: screen, screen: screen, clientWidth: 1920, clientHeight: 1080), isTrue);
  });

  test('a window with a frame, or smaller, or on another monitor is not', () {
    expect(windowIsFullscreen(window: screen, screen: screen, clientWidth: 1904, clientHeight: 1041), isFalse);
    expect(windowIsFullscreen(window: [-8, -8, 1928, 1088], screen: screen, clientWidth: 1920, clientHeight: 1080), isFalse);
    expect(windowIsFullscreen(window: [240, 135, 1680, 945], screen: screen, clientWidth: 1440, clientHeight: 810), isFalse);
    expect(windowIsFullscreen(window: [1920, 0, 3840, 1080], screen: screen, clientWidth: 1920, clientHeight: 1080), isFalse);
  });

  test('a rectangle that cannot be read is not full screen: the key is pressed as before', () {
    expect(windowIsFullscreen(window: const [], screen: screen, clientWidth: 0, clientHeight: 0), isFalse);
  });
}
