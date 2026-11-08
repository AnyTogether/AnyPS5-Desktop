import 'dart:async';
import 'dart:collection';

import '../game_library.dart';
import 'atrac9.dart';
import 'audio_out.dart';

/// The selected game's theme song, the way the PS5 plays it (the macOS launcher's
/// ThemeMusic.swift): it comes in softly once the selection has rested on a game for a moment,
/// repeats, and fades out when the selection moves, a game starts or the launcher goes to the
/// background.
class ThemeMusic {
  ThemeMusic(
    this._out, {
    Future<PlayableSong?> Function(String path)? decode,
    this.settle = const Duration(milliseconds: 900),
    this.fadeIn = const Duration(milliseconds: 1400),
    this.fadeOut = const Duration(milliseconds: 450),
  }) : _decode = decode ?? ThemeSong.load;

  final AudioOut _out;
  final Future<PlayableSong?> Function(String path) _decode;
  final Duration settle;
  final Duration fadeIn;
  final Duration fadeOut;

  /// How often a fade sets the volume.
  static const tick = Duration(milliseconds: 16);

  /// A song is about 20 MB in memory: a few are kept for going back and forth.
  static const cached = 3;

  double _volume = 0.5;

  /// 0 to 1. The song playing takes it at once; one still fading in ends its fade there.
  double get volume => _volume;
  set volume(double value) {
    if (value == _volume) return;
    _volume = value;
    final voice = _voice;
    if (_current == null || voice == null) return;
    if (_fade == null) {
      _level = value;
      _out.setVolume(voice, value);
    } else {
      _ramp(value, fadeIn);
    }
  }

  String? _current;
  String? _wanted;
  Object? _voice;
  double _level = 0;
  int _generation = 0;
  Timer? _pending;
  Timer? _fade;
  final LinkedHashMap<String, (Object, Duration)> _cache = LinkedHashMap();

  /// The id of the song playing (or coming in), for tests and the phone.
  String? get playing => _current;

  /// A console cue plays once. Games and the fallback theme loop after the normal selection delay.
  void play(Game? game, {String? fallback, String? startupCue}) {
    final music = game?.music;
    final song = startupCue != null
        ? (id: 'startup:$startupCue', path: startupCue, atrac9: false, loop: false)
        : music != null
        ? (id: game!.id, path: music, atrac9: game.retro == null, loop: true)
        : (fallback == null ? null : (id: 'theme:$fallback', path: fallback, atrac9: false, loop: true));
    if (song?.id == _wanted) return;
    _wanted = song?.id;
    _pending?.cancel();
    final generation = ++_generation;
    _stop();
    if (song == null || _volume <= 0) return;
    final delay = song.loop ? settle : const Duration(milliseconds: 220);
    _pending = Timer(delay, () async {
      if (generation != _generation) return;
      var sound = _cache[song.id];
      if (sound == null) {
        final made = await _load(song.path, atrac9: song.atrac9);
        if (made == null) return;
        sound = made;
        _remember(song.id, made);
      }
      if (generation != _generation) return;
      _start(song.id, sound, loop: song.loop);
    });
  }

  Future<(Object, Duration)?> _load(String path, {required bool atrac9}) async {
    if (!await _out.start()) return null;
    if (!atrac9) {
      final sound = await _out.loadFile(path);
      return sound == null ? null : (sound, Duration.zero);
    }
    final song = await _decode(path);
    if (song == null) return null;
    final sound = await _out.loadWav('anyps5-song-${path.hashCode}.wav', song.wav);
    return sound == null ? null : (sound, song.loopStart);
  }

  void _start(String id, (Object, Duration) sound, {required bool loop}) {
    final previous = _voice;
    if (previous != null) _out.stop(previous);
    _voice = _out.play(sound.$1, volume: 0, loop: loop, loopStart: sound.$2);
    _current = id;
    _level = 0;
    _ramp(_volume, loop ? fadeIn : const Duration(milliseconds: 96));
  }

  void _stop() {
    if (_current == null) return;
    _current = null;
    _ramp(
      0,
      fadeOut,
      then: () {
        final voice = _voice;
        if (_current != null || voice == null) return;
        _out.stop(voice);
        _voice = null;
      },
    );
  }

  /// From the volume now to [target], eased at both ends.
  void _ramp(double target, Duration over, {void Function()? then}) {
    _fade?.cancel();
    final from = _level;
    var ticks = 0;
    _fade = Timer.periodic(tick, (timer) {
      ticks++;
      final t = over <= Duration.zero ? 1.0 : (ticks * tick.inMicroseconds / over.inMicroseconds).clamp(0.0, 1.0);
      final eased = t * t * (3 - 2 * t);
      _level = from + (target - from) * eased;
      final voice = _voice;
      if (voice != null) _out.setVolume(voice, _level);
      if (t >= 1) {
        timer.cancel();
        _fade = null;
        then?.call();
      }
    });
  }

  void _remember(String id, (Object, Duration) sound) {
    _cache.remove(id);
    _cache[id] = sound;
    while (_cache.length > cached) {
      final oldest = _cache.keys.first;
      _out.release(_cache.remove(oldest)!.$1);
    }
  }

  void dispose() {
    _generation++;
    _pending?.cancel();
    _fade?.cancel();
    final voice = _voice;
    if (voice != null) _out.stop(voice);
    _voice = null;
    _current = null;
    _wanted = null;
  }
}
