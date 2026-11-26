import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_soloud/flutter_soloud.dart';

import '../core/audio/audio_out.dart';

/// The sound card through SoLoud (miniaudio: WASAPI on Windows, PulseAudio or ALSA on Linux).
/// Every call is guarded: a launcher without sound still works.
class SoloudAudio implements AudioOut {
  Future<bool>? _started;
  bool _ready = false;

  SoLoud get _soloud => SoLoud.instance;

  @override
  Future<bool> start() => _started ??= () async {
    try {
      // A small buffer: a tick follows the key press without a lag.
      await _soloud.init(bufferSize: 1024);
      _ready = _soloud.isInitialized;
    } on Object {
      _ready = false;
    }
    return _ready;
  }();

  /// A WAV this big is a decoded theme song (tens of MB), not an interface sound.
  static const _streamFrom = 1 << 20;

  /// Where the decoded songs are written to be streamed, made when the first one is.
  Directory? _songs;

  /// The songs streamed from a file, by sound, so the file goes when the sound does.
  final Map<AudioSource, File> _streamed = {};

  @override
  Future<Object?> loadWav(String name, Uint8List bytes) async {
    if (!await start()) return null;
    // A song loaded whole into memory is decoded by the engine on the interface's thread: it
    // froze the launcher for about a second the first time a game's song was needed. Streamed
    // from a file the engine only reads its header, so the interface keeps drawing.
    if (bytes.length >= _streamFrom) {
      final streamed = await _stream(name, bytes);
      if (streamed != null) return streamed;
    }
    try {
      return await _soloud.loadMem(name, bytes);
    } on Object {
      return null;
    }
  }

  /// [bytes] written to a temporary file and opened as a stream; null when it cannot be.
  Future<AudioSource?> _stream(String name, Uint8List bytes) async {
    File? file;
    try {
      var folder = _songs;
      if (folder == null) {
        // Songs a run before left behind (a crash) go; one still open elsewhere stays.
        final stale = Directory('${Directory.systemTemp.path}${Platform.pathSeparator}anyps5-songs');
        try {
          if (stale.existsSync()) await stale.delete(recursive: true);
        } on FileSystemException {
          // Another launcher is playing from it.
        }
        folder = _songs = await stale.create(recursive: true);
      }
      file = File('${folder.path}${Platform.pathSeparator}$name');
      await file.writeAsBytes(bytes);
      final source = await _soloud.loadFile(file.path, mode: LoadMode.disk);
      _streamed[source] = file;
      return source;
    } on Object {
      if (file != null) unawaited(_remove(file));
      return null;
    }
  }

  static Future<void> _remove(File file) async {
    try {
      await file.delete();
    } on FileSystemException {
      // Still open, or already gone: the next run clears the folder.
    }
  }

  @override
  Future<Object?> loadFile(String path) async {
    if (!await start()) return null;
    try {
      return await _soloud.loadFile(path);
    } on Object {
      return null;
    }
  }

  @override
  Object? play(Object sound, {double volume = 1, bool loop = false, Duration loopStart = Duration.zero}) {
    if (!_ready || sound is! AudioSource) return null;
    try {
      return _Voice(_soloud.play(sound, volume: volume, looping: loop, loopingStartAt: loopStart));
    } on Object {
      return null;
    }
  }

  @override
  void setVolume(Object voice, double volume) {
    if (!_ready || voice is! _Voice) return;
    try {
      if (_soloud.getIsValidVoiceHandle(voice.handle)) _soloud.setVolume(voice.handle, volume);
    } on Object {
      // The voice ended.
    }
  }

  @override
  void stop(Object voice) {
    if (!_ready || voice is! _Voice) return;
    try {
      if (_soloud.getIsValidVoiceHandle(voice.handle)) unawaited(_soloud.stop(voice.handle).catchError((Object _) {}));
    } on Object {
      // The voice ended.
    }
  }

  @override
  void release(Object sound) {
    if (!_ready || sound is! AudioSource) return;
    final file = _streamed.remove(sound);
    unawaited(
      _soloud.disposeSource(sound).catchError((Object _) {}).whenComplete(() {
        if (file != null) unawaited(_remove(file));
      }),
    );
  }
}

/// A playing sound's handle (an extension type, kept in a class to be told apart).
class _Voice {
  const _Voice(this.handle);
  final SoundHandle handle;
}
