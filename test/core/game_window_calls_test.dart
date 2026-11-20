import 'package:anyps5_desktop/core/desktop/desktop.dart';
import 'package:flutter_test/flutter_test.dart';

/// On Windows the launcher's Dart runs on its window's thread: a call that waits for a game's
/// window thread (still loading, or hung) stops the whole launcher until the game answers.
void main() {
  test('a game window is placed by a posted request, never one that waits for the game', () {
    const asyncWindowPos = 0x4000;
    const noZOrder = 0x0004;
    const noActivate = 0x0010;
    expect(gameWindowPlacement & asyncWindowPos, asyncWindowPos);
    expect(gameWindowPlacement & noZOrder, noZOrder);
    expect(gameWindowPlacement & noActivate, noActivate);
  });

  test('the input joined is the front window and the target, not the launcher itself', () {
    expect(threadsToJoin(ours: 1, windows: const [(thread: 7, answers: true), (thread: 9, answers: true)]), {7, 9});
    expect(threadsToJoin(ours: 1, windows: const [(thread: 1, answers: true), (thread: 9, answers: true)]), {9});
    expect(threadsToJoin(ours: 1, windows: const [(thread: 9, answers: true), (thread: 9, answers: true)]), {9});
  });

  test('a window that does not answer has its thread left alone', () {
    // The game in front is still loading: the launcher raises itself without joining the game.
    expect(threadsToJoin(ours: 1, windows: const [(thread: 7, answers: false), (thread: 1, answers: true)]), isEmpty);
    expect(threadsToJoin(ours: 1, windows: const [(thread: 7, answers: false), (thread: 9, answers: true)]), {9});
  });

  test('a window with no thread (gone meanwhile) joins nothing', () {
    expect(threadsToJoin(ours: 1, windows: const [(thread: 0, answers: true)]), isEmpty);
    expect(threadsToJoin(ours: 1, windows: const []), isEmpty);
  });
}
