import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import '../core/libmpv.dart';
import 'clip_player.dart' show MediaKitClipPlayback;

/// How a voice note is playing: from [VoicePlayback]'s player.
@immutable
class VoiceTrack {
  const VoiceTrack({
    this.playing = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.ended = false,
    this.failed = false,
  });

  final bool playing;
  final Duration position;
  final Duration duration;
  final bool ended;
  final bool failed;

  VoiceTrack copyWith({bool? playing, Duration? position, Duration? duration, bool? ended, bool? failed}) => VoiceTrack(
    playing: playing ?? this.playing,
    position: position ?? this.position,
    duration: duration ?? this.duration,
    ended: ended ?? this.ended,
    failed: failed ?? this.failed,
  );
}

/// A voice note playing inside the launcher, from the start and once, as the macOS launcher's
/// VoicePlayer (AVPlayer) does. LauncherServices.voicePlayback makes one; a fake in tests.
abstract class VoicePlayback {
  ValueListenable<VoiceTrack> get state;

  /// Opens [source] (a file's path or a link) and plays it from the start, once.
  Future<void> open(String source);

  Future<void> playOrPause();

  Future<void> stop();

  Future<void> dispose();
}

/// The voice note player on Windows and Linux: libmpv through media_kit, as the clip player.
/// Throws LibmpvMissing when Linux has none, anything else when libmpv cannot be loaded.
class MediaKitVoicePlayback implements VoicePlayback {
  MediaKitVoicePlayback() {
    if (SystemLibmpv.missing) throw SystemLibmpv.missingError();
    MediaKit.ensureInitialized(libmpv: MediaKitClipPlayback.loadedLibmpv());
    _player = Player(configuration: const PlayerConfiguration(title: 'AnyPS5'));
    final stream = _player.stream;
    _subscriptions.addAll([
      stream.playing.listen((playing) => _state.value = _state.value.copyWith(playing: playing)),
      stream.position.listen((position) => _state.value = _state.value.copyWith(position: position)),
      stream.duration.listen((duration) => _state.value = _state.value.copyWith(duration: duration)),
      stream.completed.listen((completed) {
        if (completed) _state.value = _state.value.copyWith(ended: true, playing: false);
      }),
      stream.error.listen((_) {
        if (_state.value.duration == Duration.zero) _state.value = _state.value.copyWith(failed: true);
      }),
    ]);
  }

  late final Player _player;
  final _state = ValueNotifier(const VoiceTrack());
  final List<StreamSubscription<Object?>> _subscriptions = [];

  @override
  ValueListenable<VoiceTrack> get state => _state;

  @override
  Future<void> open(String source) async {
    _state.value = const VoiceTrack();
    try {
      await _player.open(Media(source));
    } on Object {
      _state.value = _state.value.copyWith(failed: true);
    }
  }

  @override
  Future<void> playOrPause() => _player.playOrPause();

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _player.dispose();
    _state.dispose();
  }
}

/// Which voice note is at hand and how far it has got, for the bubbles to draw.
@immutable
class VoiceNoteState {
  const VoiceNoteState({this.id, this.playing = false, this.progress = 0});

  /// The note playing or paused; null for none.
  final String? id;
  final bool playing;

  /// 0 to 1.
  final double progress;
}

/// The voice notes in chats, one at a time, as the Mac's VoicePlayer: a press plays a note and
/// stops whichever played before it, the next pauses it; its end takes it back to the start.
/// Without the launcher's player, or when it cannot open a note, the note goes to the system's
/// player, as clips do. On Linux without libmpv [onMissing] says how to install it, once.
class VoiceNotes {
  VoiceNotes({required this.create, required this.onSystemPlayer, required this.onFailed, this.onMissing});

  /// LauncherServices.voicePlayback; null where there is no player.
  final VoicePlayback Function()? create;

  /// The note goes to the system's player: a file's path or a link.
  final void Function(String source) onSystemPlayer;

  /// The sealed note could not be opened.
  final void Function(Object error) onFailed;

  /// libmpv is not installed (Linux): the first note that would have played says so; it and the
  /// rest still go to the system's player.
  final void Function(LibmpvMissing missing)? onMissing;
  bool _missingSaid = false;

  final state = ValueNotifier(const VoiceNoteState());

  VoicePlayback? _playback;
  VoidCallback? _listener;
  String? _source;
  bool _opening = false;
  bool _disposed = false;

  /// Plays note [id], or pauses it if it is the one playing. [source] gives the file or link.
  Future<void> toggle(String id, Future<String> Function() source) async {
    if (_opening) return;
    final playback = _playback;
    if (playback != null && state.value.id == id && !playback.state.value.ended && !playback.state.value.failed) {
      await playback.playOrPause();
      return;
    }
    _opening = true;
    state.value = VoiceNoteState(id: id, playing: true);
    try {
      final String path;
      try {
        path = await source();
      } on Object catch (error) {
        state.value = const VoiceNoteState();
        onFailed(error);
        return;
      }
      if (_disposed) return;
      final player = _player();
      if (player == null) {
        state.value = const VoiceNoteState();
        onSystemPlayer(path);
        return;
      }
      _source = path;
      await player.open(path);
    } finally {
      _opening = false;
    }
  }

  /// Note [id] left the screen: it stops if it is the one at hand.
  Future<void> stopNote(String id) async {
    if (state.value.id != id) return;
    state.value = const VoiceNoteState();
    await _playback?.stop();
  }

  /// The player, made once; null when there is none or libmpv cannot be loaded.
  VoicePlayback? _player() {
    final existing = _playback;
    if (existing != null) return existing;
    final make = create;
    if (make == null) return null;
    try {
      final made = make();
      _listener = _changed;
      made.state.addListener(_listener!);
      return _playback = made;
    } on LibmpvMissing catch (missing) {
      if (!_missingSaid) {
        _missingSaid = true;
        onMissing?.call(missing);
      }
      return null;
    } on Object {
      return null;
    }
  }

  void _changed() {
    final track = _playback?.state.value;
    final id = state.value.id;
    if (track == null || id == null) return;
    if (track.failed) {
      final source = _source;
      state.value = const VoiceNoteState();
      if (source != null) onSystemPlayer(source);
      return;
    }
    if (track.ended) {
      state.value = VoiceNoteState(id: id);
      return;
    }
    final total = track.duration.inMilliseconds;
    state.value = VoiceNoteState(
      id: id,
      playing: track.playing,
      progress: total <= 0 ? 0 : (track.position.inMilliseconds / total).clamp(0, 1).toDouble(),
    );
  }

  Future<void> dispose() async {
    _disposed = true;
    final playback = _playback;
    _playback = null;
    final listener = _listener;
    if (playback != null && listener != null) playback.state.removeListener(listener);
    state.dispose();
    await playback?.dispose();
  }
}
