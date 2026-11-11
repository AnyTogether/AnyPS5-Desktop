import 'dart:async';

import 'package:flutter/services.dart';

import '../core/now_playing.dart';

/// Now playing on Windows, through the runner's "anyps5/now_playing" channel
/// (windows/runner/now_playing.cpp): the session Windows' system media transport controls call
/// the current one, whichever player it belongs to. The runner follows Windows' own events and
/// says "changed" with the track; nothing is polled. A Windows without media sessions answers
/// as one where nothing plays.
class ChannelNowPlaying implements NowPlayingSource {
  ChannelNowPlaying() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'changed' && _watching) _take(parse(call.arguments));
      return null;
    });
  }

  static const _channel = MethodChannel('anyps5/now_playing');

  final _changes = StreamController<void>.broadcast();
  NowPlayingTrack? _current;
  bool _watching = false;

  /// The track as the runner sends it: null, or a map of title, artist, player, playing and
  /// artwork. Empty texts are none, and a track with no title is no track.
  static NowPlayingTrack? parse(Object? value) {
    if (value is! Map) return null;
    String? text(String key) {
      final found = value[key];
      return found is String && found.trim().isNotEmpty ? found.trim() : null;
    }

    final title = text('title');
    if (title == null) return null;
    return NowPlayingTrack(
      title: title,
      artist: text('artist'),
      player: text('player'),
      playing: value['playing'] != false,
      artwork: NowPlayingTrack.cover(value['artwork']),
    );
  }

  @override
  NowPlayingTrack? get current => _current;

  @override
  Stream<void> get changes => _changes.stream;

  void _take(NowPlayingTrack? next) {
    if (next == _current) return;
    _current = next;
    if (!_changes.isClosed) _changes.add(null);
  }

  @override
  Future<void> watch(bool on) async {
    if (on == _watching) return;
    _watching = on;
    await _call('watch', on);
    if (!on) {
      _take(null);
      return;
    }
    // What it had read by now; the first reading after a start comes as "changed".
    final now = parse(await _call('get'));
    if (_watching) _take(now);
  }

  @override
  Future<void> previous() => _call('command', 'previous');

  @override
  Future<void> playPause() => _call('command', 'playPause');

  @override
  Future<void> next() => _call('command', 'next');

  @override
  Future<void> close() async {
    if (_watching) {
      _watching = false;
      await _call('watch', false);
    }
    _current = null;
    await _changes.close();
  }

  Future<Object?> _call(String method, [Object? argument]) async {
    try {
      return await _channel.invokeMethod<Object?>(method, argument);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
