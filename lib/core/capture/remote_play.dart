import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../desktop/desktop.dart';
import '../host.dart';
import '../replay_buffer.dart' show ProcessStarter;
import 'flv_video.dart';
import 'game_sound.dart';
import 'stream_packet.dart';
import 'video_encoders.dart';
import 'wayland_capture.dart';

/// How a Remote Play start went, as the phone is told (RemoteStreaming's states).
enum RemotePlayStart {
  on,

  /// No game window to send (it is not open yet, or minimised), or nothing could encode it.
  noGame,
}

/// Remote Play: the game's window and sound sent to the phones that asked, as they come, in the
/// macOS launcher's packets (StreamPacket) so the phone app needs nothing new. ffmpeg records
/// the game's area of the screen and encodes it at once (the graphics card's encoder when one
/// works, x264's zero-latency mode otherwise) as FLV on a pipe, which says where each frame
/// ends; the sound comes from [GameSound] as 5 ms of 16-bit stereo.
///
/// A phone that lost part of a frame asks for a key frame, as on the Mac. ffmpeg has no direct way
/// to be told, so the ask goes through its standard input to a filter that marks the next frame
/// ([KeyRequest]): the key frame follows within about a tenth of a second. A key frame comes
/// every second anyway, which is all an older ffmpeg (or an encoder that refuses) gets.
class RemotePlayStream {
  RemotePlayStream({
    required this.ffmpeg,
    required this.system,
    required this.encoders,
    required this.areaOf,
    required this.soundOf,
    this.environment = const {},
    this.followEvery = const Duration(seconds: 2),
    this.keyGap = const Duration(milliseconds: 200),
    this.wayland,
    ProcessStarter? start,
    this.log,
  }) : _start = start ?? ((executable, arguments) => Process.start(executable, arguments));

  final String ffmpeg;
  final HostSystem system;
  final Map<String, String> environment;
  final EncoderChoice encoders;
  final ScreenArea? Function(int pid) areaOf;
  final GameSound Function(int pid) soundOf;
  final Duration followEvery;

  /// At most one key frame request to ffmpeg in this time; each takes it 100 ms or so to read.
  final Duration keyGap;

  /// Under Wayland, where the picture comes from; null on X11 and Windows.
  final WaylandCapture? wayland;
  final ProcessStarter _start;

  /// A line for the game log.
  final void Function(String line)? log;

  static const framesPerSecond = 60;

  int? _pid;
  (int, int)? _wanted;
  ScreenArea? _area;
  Process? _video;
  GameSound? _sound;
  Timer? _follow;
  void Function(List<Uint8List> packets)? _send;
  final _clock = Stopwatch();
  int _frame = 0;
  var _chunker = SoundChunker();
  int _restarts = 0;
  bool _keyRequests = false;
  Timer? _keyTimer;
  bool _keyAgain = false;

  int? get pid => _pid;
  bool get running => _video != null;

  /// The bit rate for a picture of [width] by [height]: about 0.2 bit a pixel at 60 frames a
  /// second (11 Mbit/s for 1280 x 720), as the Mac sends.
  static int bitRateFor(int width, int height) => max(2000000, (width * height * framesPerSecond * 0.2).round());

  /// ffmpeg's arguments for the game in [area], made [width] by [height].
  List<String> arguments(
    VideoEncoder encoder,
    ScreenArea area,
    int width,
    int height, {
    WaylandFeed? feed,
    bool keyRequests = false,
  }) => [
    '-hide_banner',
    '-loglevel',
    'error',
    // Key frame requests come in on the standard input (KeyRequest).
    if (keyRequests) ...KeyRequest.globalArguments else '-nostdin',
    ...encoder.deviceArguments,
    ...ScreenGrab.input(
      system: system,
      environment: environment,
      framesPerSecond: framesPerSecond,
      area: area,
      wayland: feed,
    ),
    '-an',
    '-vf',
    '${keyRequests ? '${KeyRequest.filter},' : ''}scale=$width:$height:flags=bilinear,${encoder.filterTail}',
    ...encoder.arguments(use: EncodeUse.live, bitRate: bitRateFor(width, height), keyEvery: framesPerSecond),
    if (keyRequests) ...encoder.keyRequestArguments,
    '-flush_packets',
    '1',
    '-flvflags',
    'no_duration_filesize',
    '-f',
    'flv',
    'pipe:1',
  ];

  /// Sends the game with process [pid] at about [width] by [height] through [send].
  Future<RemotePlayStart> start({
    required int pid,
    required int width,
    required int height,
    required void Function(List<Uint8List> packets) send,
  }) async {
    if (_pid == pid && _wanted == (width, height) && _video != null) {
      _send = send;
      return RemotePlayStart.on;
    }
    await stop();
    final area = areaOf(pid);
    if (area == null) return RemotePlayStart.noGame;
    final encoder = await encoders.encoder;
    if (encoder == null) {
      log?.call('remote play: no encoder works (${encoders.tried.join(', ')})');
      return RemotePlayStart.noGame;
    }
    _keyRequests = await encoders.keyRequests;
    _pid = pid;
    _wanted = (width, height);
    _send = send;
    _frame = 0;
    _restarts = 0;
    _chunker = SoundChunker();
    _clock
      ..reset()
      ..start();
    if (!await _startVideo(encoder, area)) {
      await stop();
      return RemotePlayStart.noGame;
    }
    final sound = soundOf(pid);
    _sound = sound;
    await sound.start((samples) {
      final packets = _chunker.add(samples, _clock.elapsedMilliseconds);
      if (packets.isNotEmpty) _send?.call(packets);
    });
    log?.call(
      'remote play: ${encoder.codec}, $area made ${ScreenGrab.fit(area, width, height)}, sound ${sound.reach.name}, '
      'key frames ${_keyRequests ? 'on request and every second' : 'every second only'}',
    );
    // The window moved or changed size (full screen and back): recorded again where it is now.
    _follow = Timer.periodic(followEvery, (_) {
      final now = areaOf(pid);
      if (now != null && now != _area && _video != null) unawaited(_startVideo(encoder, now));
    });
    return RemotePlayStart.on;
  }

  Future<bool> _startVideo(VideoEncoder encoder, ScreenArea area) async {
    final wanted = _wanted;
    if (wanted == null) return false;
    final old = _video;
    _video = null;
    old?.kill();
    final (width, height) = ScreenGrab.fit(area, wanted.$1, wanted.$2);
    WaylandFeed? feed;
    if (wayland case final capture?) {
      feed = await capture.openFeed(maxWidth: wanted.$1, maxHeight: wanted.$2, framesPerSecond: framesPerSecond);
      if (feed == null) {
        log?.call('remote play: no picture from the desktop (${capture.problem?.name})');
        return false;
      }
    }
    final Process process;
    try {
      process = await _start(ffmpeg, arguments(encoder, area, width, height, feed: feed, keyRequests: _keyRequests));
    } on Object catch (error) {
      log?.call('remote play: ffmpeg did not start: $error');
      await feed?.close();
      return false;
    }
    final picture = feed;
    // GStreamer gone: ffmpeg would wait on the pipe for ever.
    if (picture != null) {
      unawaited(picture.ended.then((_) => process.kill()));
    }
    _video = process;
    _area = area;
    final reader = FlvVideoReader((frame) {
      if (_video != process) return;
      _frame = (_frame + 1) & 0xFFFFFFFF;
      _send?.call(
        StreamPacket.video(frame.data, number: _frame, key: frame.key, milliseconds: _clock.elapsedMilliseconds),
      );
    });
    process.stdout.listen((data) {
      try {
        reader.add(data);
      } on FormatException {
        process.kill();
      }
    }, onError: (_) {});
    // A closed pipe (ffmpeg gone) is no error for whoever asked for a key frame.
    if (_keyRequests) unawaited(process.stdin.done.catchError((Object _) {}));
    final errors = StringBuffer();
    process.stderr.listen((data) {
      if (errors.length < 2000) errors.write(KeyRequest.withoutEcho(String.fromCharCodes(data)));
    }, onError: (_) {});
    unawaited(
      process.exitCode.then((code) async {
        await picture?.close();
        if (_video != process) return;
        _video = null;
        log?.call('remote play: ffmpeg ended ($code) ${errors.toString().trim()}');
        // Once more after a moment (the window was changing); then the phone is told.
        if (_restarts++ < 3 && _pid != null) {
          await Future<void>.delayed(const Duration(seconds: 1));
          final now = _pid == null ? null : areaOf(_pid!);
          if (now != null && _video == null && _pid != null) await _startVideo(encoder, now);
        }
      }),
    );
    return true;
  }

  /// The phone lost part of the picture: ffmpeg is asked for a key frame, and asked once more
  /// after [keyGap] if the phone asks again meanwhile (that later ask is about later damage).
  void wantKey() {
    if (_keyTimer != null) {
      _keyAgain = true;
      return;
    }
    final video = _video;
    if (video == null || !_keyRequests) return;
    video.stdin.write(KeyRequest.command);
    _keyTimer = Timer(keyGap, () {
      _keyTimer = null;
      if (_keyAgain) {
        _keyAgain = false;
        wantKey();
      }
    });
  }

  Future<void> stop() async {
    _follow?.cancel();
    _follow = null;
    _keyTimer?.cancel();
    _keyTimer = null;
    _keyAgain = false;
    _pid = null;
    _wanted = null;
    _area = null;
    final video = _video;
    _video = null;
    video?.kill();
    final sound = _sound;
    _sound = null;
    await sound?.stop();
  }
}
