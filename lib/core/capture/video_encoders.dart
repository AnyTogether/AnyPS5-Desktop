import 'dart:async';

import '../desktop/desktop.dart';
import '../host.dart';
import '../replay_buffer.dart' show ProcessRunner;
import 'wayland_capture.dart' show WaylandFeed;

/// What the picture is encoded for: each wants its own trade between delay and quality.
enum EncodeUse {
  /// Remote Play: every frame out at once, nothing held back or reordered.
  live,

  /// Twitch, YouTube or an RTMP server: steady bit rate, a key frame every two seconds.
  broadcast,

  /// The replay buffer: as little of the computer as possible while a game plays.
  replay,
}

/// The H.264 encoders the launcher tries, hardware first. All go through ffmpeg, which the
/// replay buffer already needs: one tool for clips, Remote Play and broadcasting, with the
/// graphics card's encoder where ffmpeg has one that works on this computer.
enum VideoEncoder {
  /// NVIDIA (NVENC).
  nvenc('h264_nvenc'),

  /// Intel Quick Sync.
  qsv('h264_qsv'),

  /// AMD (AMF), Windows only.
  amf('h264_amf'),

  /// VA-API (Intel and AMD on Linux).
  vaapi('h264_vaapi'),

  /// x264 on the processor: everywhere ffmpeg was built with it.
  x264('libx264'),

  /// Windows' own Media Foundation encoder, for an ffmpeg without x264.
  mediaFoundation('h264_mf');

  const VideoEncoder(this.codec);

  /// ffmpeg's name for it.
  final String codec;

  bool get hardware => this != x264 && this != mediaFoundation;

  /// The order they are tried on [system].
  static List<VideoEncoder> candidates(HostSystem system) => switch (system) {
    HostSystem.windows => const [nvenc, qsv, amf, x264, mediaFoundation],
    HostSystem.linux => const [nvenc, vaapi, qsv, x264],
  };

  /// The render node VA-API encodes on.
  static const vaapiDevice = '/dev/dri/renderD128';

  /// Arguments before the inputs (VA-API's device).
  List<String> get deviceArguments =>
      this == vaapi ? const ['-vaapi_device', vaapiDevice] : const [];

  /// The end of the filter chain: the pixel format the encoder takes, uploaded to the graphics
  /// card for VA-API.
  String get filterTail => switch (this) {
    vaapi => 'format=nv12,hwupload',
    x264 => 'format=yuv420p',
    _ => 'format=nv12',
  };

  /// The encoder's arguments: [bitRate] in bit/s, a key frame every [keyEvery] frames.
  List<String> arguments({
    required EncodeUse use,
    required int bitRate,
    required int keyEvery,
  }) {
    final live = use == EncodeUse.live;
    final buffer = switch (use) {
      // Half a second: frames stay even in size, so none waits behind a large one.
      EncodeUse.live => bitRate ~/ 2,
      EncodeUse.broadcast => bitRate * 2,
      EncodeUse.replay => bitRate * 2,
    };
    final rate = [
      '-b:v',
      '$bitRate',
      '-maxrate',
      '$bitRate',
      '-bufsize',
      '$buffer',
      '-g',
      '$keyEvery',
    ];
    return switch (this) {
      nvenc => [
        '-c:v',
        codec,
        '-preset',
        live ? 'p1' : (use == EncodeUse.broadcast ? 'p4' : 'p2'),
        '-tune',
        live ? 'ull' : 'hq',
        if (live) ...['-zerolatency', '1', '-delay', '0'],
        '-rc',
        'cbr',
        '-bf',
        '0',
        ...rate,
      ],
      qsv => [
        '-c:v',
        codec,
        '-preset',
        'veryfast',
        '-bf',
        '0',
        if (live) ...['-async_depth', '1'],
        ...rate,
      ],
      amf => [
        '-c:v',
        codec,
        '-usage',
        live ? 'ultralowlatency' : 'transcoding',
        '-quality',
        live ? 'speed' : 'balanced',
        '-rc',
        'cbr',
        '-bf',
        '0',
        ...rate,
      ],
      vaapi => ['-c:v', codec, '-bf', '0', ...rate],
      x264 => [
        '-c:v',
        codec,
        '-preset',
        use == EncodeUse.broadcast ? 'veryfast' : 'ultrafast',
        if (live) ...['-tune', 'zerolatency'],
        '-bf',
        '0',
        ...rate,
      ],
      mediaFoundation => [
        '-c:v',
        codec,
        '-rate_control',
        'cbr',
        '-scenario',
        live ? 'display_remoting' : 'live_streaming',
        '-bf',
        '0',
        ...rate,
      ],
    };
  }

  /// A tiny encode that tells whether this encoder works here: ffmpeg lists NVENC and Quick
  /// Sync in builds for every computer, and they fail at once where the card is missing.
  List<String> probeArguments() => [
    '-hide_banner',
    '-loglevel',
    'error',
    '-nostdin',
    ...deviceArguments,
    '-f',
    'lavfi',
    '-i',
    'color=c=black:s=320x180:r=30',
    '-frames:v',
    '3',
    '-an',
    '-vf',
    filterTail,
    ...arguments(use: EncodeUse.live, bitRate: 1000000, keyEvery: 30),
    '-f',
    'null',
    '-',
  ];
}

/// The first encoder that works with this ffmpeg on this computer, asked once and kept.
class EncoderChoice {
  EncoderChoice({
    required this.ffmpeg,
    required this.system,
    required this.run,
  });

  final String ffmpeg;
  final HostSystem system;
  final ProcessRunner run;
  Future<VideoEncoder?>? _chosen;

  /// What was tried and how it went, for the game log.
  final tried = <String>[];

  Future<VideoEncoder?> get encoder => _chosen ??= _choose();

  Future<VideoEncoder?> _choose() async {
    for (final candidate in VideoEncoder.candidates(system)) {
      try {
        final result = await run(
          ffmpeg,
          candidate.probeArguments(),
        ).timeout(const Duration(seconds: 10));
        tried.add(
          '${candidate.codec}: ${result.exitCode == 0 ? 'works' : 'exit ${result.exitCode}'}',
        );
        if (result.exitCode == 0) return candidate;
      } on Object catch (error) {
        tried.add('${candidate.codec}: $error');
      }
    }
    return null;
  }
}

/// ffmpeg's screen input for the game's picture: gdigrab on Windows (the desktop's pixels in the
/// game's area, the composited picture whatever draws it), x11grab on X11. Wayland has no such
/// input: its picture comes through [WaylandCapture] as a [WaylandFeed].
abstract final class ScreenGrab {
  static bool supported(HostSystem system, Map<String, String> environment) {
    if (system == HostSystem.windows) return true;
    if (system != HostSystem.linux) return false;
    final session = (environment['XDG_SESSION_TYPE'] ?? '').toLowerCase();
    if (session == 'wayland') return false;
    return (environment['DISPLAY'] ?? '').isNotEmpty;
  }

  /// The input arguments for [area] (the whole screen when null) at [framesPerSecond].
  static List<String> input({
    required HostSystem system,
    required Map<String, String> environment,
    required int framesPerSecond,
    ScreenArea? area,
    WaylandFeed? wayland,
  }) {
    if (wayland != null) return wayland.input;
    // Even sizes: the encoders take nothing else, and the filter keeps them so after scaling.
    final width = area == null ? null : area.width & ~1;
    final height = area == null ? null : area.height & ~1;
    if (system == HostSystem.windows) {
      return [
        '-thread_queue_size',
        '64',
        '-f',
        'gdigrab',
        '-framerate',
        '$framesPerSecond',
        '-draw_mouse',
        '0',
        if (area != null) ...[
          '-offset_x',
          '${area.x}',
          '-offset_y',
          '${area.y}',
          '-video_size',
          '${width}x$height',
        ],
        '-i',
        'desktop',
      ];
    }
    final display = environment['DISPLAY'] ?? ':0';
    return [
      '-thread_queue_size',
      '64',
      '-f',
      'x11grab',
      '-framerate',
      '$framesPerSecond',
      '-draw_mouse',
      '0',
      if (area != null) ...['-video_size', '${width}x$height'],
      '-i',
      area == null ? display : '$display+${area.x},${area.y}',
    ];
  }

  /// The size [area] fits in within [maxWidth] by [maxHeight], keeping its shape, never larger
  /// than it is, in even numbers.
  static (int, int) fit(ScreenArea? area, int maxWidth, int maxHeight) {
    if (area == null) return (maxWidth & ~1, maxHeight & ~1);
    var scale = maxWidth / area.width;
    if (maxHeight / area.height < scale) scale = maxHeight / area.height;
    if (scale > 1) scale = 1;
    final width = ((area.width * scale).round() & ~1).clamp(2, 1 << 14);
    final height = ((area.height * scale).round() & ~1).clamp(2, 1 << 14);
    return (width, height);
  }
}
