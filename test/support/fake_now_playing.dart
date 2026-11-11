import 'dart:async';

import 'package:anyps5_desktop/core/now_playing.dart';

/// A media session the tests drive: [play] is the player starting, pausing or changing its
/// song, [stop] the player closing. Nothing is read while the launcher does not watch.
class FakeNowPlaying implements NowPlayingSource {
  final _changes = StreamController<void>.broadcast(sync: true);

  /// What the system has, watched or not.
  NowPlayingTrack? system;
  bool watching = false;

  /// How often the launcher started or stopped watching.
  int watches = 0;

  /// previous, playPause and next, as they were sent.
  final List<String> commands = [];
  bool closed = false;

  void play(NowPlayingTrack? track) {
    system = track;
    if (watching) _changes.add(null);
  }

  void stop() => play(null);

  @override
  NowPlayingTrack? get current => watching ? system : null;

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<void> watch(bool on) async {
    watching = on;
    watches++;
  }

  @override
  Future<void> previous() async => commands.add('previous');

  @override
  Future<void> playPause() async => commands.add('playPause');

  @override
  Future<void> next() async => commands.add('next');

  @override
  Future<void> close() async {
    closed = true;
    watching = false;
    await _changes.close();
  }
}
