import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'child_processes.dart';

/// A video played over and over as the launcher's background (the macOS launcher's LoopingVideo,
/// AVPlayerLooper there). Flutter has no video player on Windows and Linux, so ffmpeg (the one
/// the replay buffer uses: beside the launcher or on the PATH) decodes it at the video's own pace,
/// without sound, scaled and cropped to [width] by [height] to fill the screen, and sends the
/// frames as raw RGBA. A background behind darkened panels does not need more than 960 by 540:
/// the theme's own animation is drawn at half the window's size too.
class LoopingVideo {
  LoopingVideo({
    required this.ffmpeg,
    required this.file,
    this.width = 960,
    this.height = 540,
    this.framesPerSecond = 30,
    Future<Process> Function(String executable, List<String> arguments)? start,
  }) : _start = start ?? ((executable, arguments) => ChildProcesses.start(executable, arguments));

  final String ffmpeg;
  final String file;
  final int width;
  final int height;
  final int framesPerSecond;
  final Future<Process> Function(String executable, List<String> arguments) _start;

  Process? _process;
  StreamSubscription<List<int>>? _output;

  /// The bytes of one frame.
  int get frameBytes => width * height * 4;

  /// ffmpeg's arguments: the file looped for ever, read at its own speed, no sound or subtitles,
  /// filling [width] by [height] (cropped, as a background is), [framesPerSecond] frames a second.
  List<String> get arguments => [
    '-hide_banner',
    '-loglevel',
    'error',
    '-nostdin',
    '-stream_loop',
    '-1',
    '-re',
    '-i',
    file,
    '-an',
    '-sn',
    '-vf',
    'scale=$width:$height:force_original_aspect_ratio=increase,crop=$width:$height,fps=$framesPerSecond',
    '-pix_fmt',
    'rgba',
    '-f',
    'rawvideo',
    'pipe:1',
  ];

  bool get running => _process != null;

  /// Starts decoding; each whole frame goes to [onFrame]. False when ffmpeg could not start.
  Future<bool> start(void Function(Uint8List frame) onFrame) async {
    if (_process != null) return true;
    final Process process;
    try {
      process = await _start(ffmpeg, arguments);
    } on Object {
      return false;
    }
    _process = process;
    final frames = FrameChunker(frameBytes);
    _output = process.stdout.listen((chunk) {
      for (final frame in frames.add(chunk)) {
        onFrame(frame);
      }
    });
    // Its complaints are not read, but must be drained, or a full pipe stops it.
    unawaited(process.stderr.drain<void>().catchError((Object _) {}));
    unawaited(
      process.exitCode.then((_) {
        if (identical(_process, process)) _process = null;
      }),
    );
    return true;
  }

  /// Stops decoding (paused, another file, the launcher behind a game).
  Future<void> stop() async {
    final process = _process;
    _process = null;
    await _output?.cancel();
    _output = null;
    process?.kill();
  }
}

/// Cuts ffmpeg's output, which comes in pieces of any size, into whole frames of [frameBytes].
class FrameChunker {
  FrameChunker(this.frameBytes) : _frame = Uint8List(frameBytes);

  final int frameBytes;
  Uint8List _frame;
  int _filled = 0;

  /// The frames [chunk] completes, in order.
  List<Uint8List> add(List<int> chunk) {
    final done = <Uint8List>[];
    var offset = 0;
    while (offset < chunk.length) {
      final take = (frameBytes - _filled).clamp(0, chunk.length - offset);
      _frame.setRange(_filled, _filled + take, chunk, offset);
      _filled += take;
      offset += take;
      if (_filled == frameBytes) {
        done.add(_frame);
        _frame = Uint8List(frameBytes);
        _filled = 0;
      }
    }
    return done;
  }
}
