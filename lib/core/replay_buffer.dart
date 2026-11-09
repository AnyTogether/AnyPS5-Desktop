import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'capture/game_sound.dart';
import 'capture/video_encoders.dart';
import 'capture/wayland_capture.dart';
import 'host.dart';

/// Starts a program and gives its process; Process.start by default.
typedef ProcessStarter = Future<Process> Function(String executable, List<String> arguments);

/// Runs a program to its end; Process.run by default.
typedef ProcessRunner = Future<ProcessResult> Function(String executable, List<String> arguments);

/// The last minutes of play, kept by ffmpeg in a temporary folder only while a game runs: the
/// screen is recorded into short MPEG-TS segments that wrap around, so the folder never holds
/// more than [seconds] and a segment or two. Nothing is kept unless Share asks: [save] joins the
/// newest segments into one MP4 (no re-encoding) beside the game's screenshots.
///
/// The screen comes from gdigrab on Windows, x11grab on X11 and the desktop's portal under
/// Wayland ([wayland], the game's window once the user shares it), 720p at 30 frames a second. The
/// graphics card's encoder does the work when one works here ([encoder], chosen as for Remote
/// Play); x264's ultrafast preset otherwise, about one CPU core while a game plays, which is why
/// it is off until the user turns it on. The game's sound ([sound]) comes in on ffmpeg's
/// standard input and goes in the clip as AAC.
class ReplayBuffer {
  ReplayBuffer({
    required this.ffmpeg,
    required this.folder,
    required this.seconds,
    required this.system,
    this.environment = const {},
    this.encoder,
    this.sound,
    this.wayland,
    ProcessStarter? start,
    ProcessRunner? run,
  }) : _start = start ?? ((executable, arguments) => Process.start(executable, arguments)),
       _run = run ?? ((executable, arguments) => Process.run(executable, arguments));

  /// The lengths offered in Settings › Captures, in seconds.
  static const lengths = [30, 60, 180, 300];
  static const defaultLength = 60;

  /// Each segment's length: the most a clip runs past what was asked.
  static const segmentSeconds = 5;
  static const height = 720;
  static const framesPerSecond = 30;

  final String ffmpeg;
  final String folder;
  final int seconds;
  final HostSystem system;
  final Map<String, String> environment;

  /// The encoder that works here; null for x264 as before encoders were tried.
  final VideoEncoder? encoder;

  /// The game's sound, recorded with the picture; null for picture alone.
  final GameSound? sound;

  /// Under Wayland, where the picture comes from; null on X11 and Windows.
  final WaylandCapture? wayland;
  final ProcessStarter _start;
  final ProcessRunner _run;

  Process? _process;
  WaylandFeed? _feed;
  bool _stopping = false;

  /// Counts stops: a stop during the desktop's dialog ends that start.
  int _stops = 0;
  Timer? _soundTick;

  /// The bit rate of the picture for the encoders that take one (x264 keeps its quality level).
  static const bitRate = 4000000;

  bool get running => _process != null;

  /// The segments kept: enough for [seconds], the one being written and one spare.
  int get wrap => (seconds / segmentSeconds).ceil() + 2;

  /// Whether the screen can be recorded without the portal (Wayland is [WaylandCapture]'s).
  static bool supported(HostSystem system, Map<String, String> environment) {
    if (system == HostSystem.windows) return true;
    final session = (environment['XDG_SESSION_TYPE'] ?? '').toLowerCase();
    if (session == 'wayland') return false;
    return (environment['DISPLAY'] ?? '').isNotEmpty;
  }

  /// ffmpeg beside the launcher, else on the PATH; null when there is none.
  static String? locate({
    required HostSystem system,
    required Map<String, String> environment,
    String? launcherFolder,
    bool Function(String path)? exists,
  }) {
    final name = system == HostSystem.windows ? 'ffmpeg.exe' : 'ffmpeg';
    final found = exists ?? (path) => File(path).existsSync();
    final folders = [
      ?launcherFolder,
      ...(environment['PATH'] ?? environment['Path'] ?? '').split(system == HostSystem.windows ? ';' : ':'),
    ];
    for (final folder in folders) {
      if (folder.trim().isEmpty) continue;
      final path = system == HostSystem.windows ? p.windows.join(folder, name) : p.posix.join(folder, name);
      if (found(path)) return path;
    }
    return null;
  }

  /// ffmpeg's arguments for the recording.
  List<String> get captureArguments => [
    '-hide_banner',
    '-loglevel',
    'error',
    '-nostdin',
    ...?encoder?.deviceArguments,
    if (_feed case final feed?)
      ...feed.input
    else if (system == HostSystem.windows) ...[
      '-f',
      'gdigrab',
      '-framerate',
      '$framesPerSecond',
      '-draw_mouse',
      '0',
      '-i',
      'desktop',
    ] else ...[
      '-f',
      'x11grab',
      '-framerate',
      '$framesPerSecond',
      '-draw_mouse',
      '0',
      '-i',
      environment['DISPLAY'] ?? ':0',
    ],
    if (sound != null) ...[
      '-thread_queue_size',
      '1024',
      '-f',
      's16le',
      '-ar',
      '48000',
      '-ac',
      '2',
      '-i',
      'pipe:0',
      '-map',
      '0:v',
      '-map',
      '1:a',
    ],
    if (encoder == null || encoder == VideoEncoder.x264) ...[
      '-vf',
      'scale=-2:$height',
      '-c:v',
      'libx264',
      '-preset',
      'ultrafast',
      '-tune',
      'zerolatency',
      '-crf',
      '28',
      '-pix_fmt',
      'yuv420p',
    ] else ...[
      '-vf',
      'scale=-2:$height,${encoder!.filterTail}',
      ...encoder!.arguments(use: EncodeUse.replay, bitRate: bitRate, keyEvery: framesPerSecond * segmentSeconds),
    ],
    if (sound != null) ...['-af', 'aresample=async=1', '-c:a', 'aac', '-b:a', '128000'],
    // A key frame at every segment's start, so each one can be joined on its own.
    '-force_key_frames',
    'expr:gte(t,n_forced*$segmentSeconds)',
    '-f',
    'segment',
    '-segment_time',
    '$segmentSeconds',
    '-segment_wrap',
    '$wrap',
    '-segment_format',
    'mpegts',
    '-reset_timestamps',
    '1',
    p.join(folder, 'segment%03d.ts'),
  ];

  /// Starts recording; false when ffmpeg could not be started.
  Future<bool> start() async {
    if (_process != null) return true;
    try {
      _clear();
      Directory(folder).createSync(recursive: true);
      if (wayland case final capture?) {
        final stops = _stops;
        final feed = await capture.openFeed(maxWidth: 1 << 14, maxHeight: height, framesPerSecond: framesPerSecond);
        if (stops != _stops) {
          await feed?.close();
          return false;
        }
        if (feed == null) return false;
        _feed = feed;
      }
      final process = await _start(ffmpeg, captureArguments);
      _process = process;
      _stopping = false;
      final picture = _feed;
      // GStreamer gone: ffmpeg would wait on the pipe for ever.
      if (picture != null) {
        unawaited(
          picture.ended.then((_) {
            if (_process == process) process.kill();
          }),
        );
      }
      // Its output is drained so it never blocks on a full pipe.
      process.stdout.listen((_) {}, onError: (_) {});
      process.stderr.listen((_) {}, onError: (_) {});
      final heard = sound;
      if (heard != null) {
        // The sound made steady on ffmpeg's input, so it keeps pace with the picture.
        final steady = SteadyPcm((samples) {
          try {
            process.stdin.add(samples);
          } on Object {
            // ffmpeg is ending.
          }
        });
        unawaited(process.stdin.done.catchError((_) {}));
        await heard.start(steady.add);
        _soundTick = Timer.periodic(const Duration(milliseconds: 20), (_) => steady.tick());
      }
      unawaited(
        process.exitCode.then((_) {
          if (_process == process) _process = null;
          unawaited(picture?.close());
          if (_feed == picture) _feed = null;
        }),
      );
      return true;
    } on Object {
      _process = null;
      await _feed?.close();
      _feed = null;
      return false;
    }
  }

  /// The segments to join for the last [seconds], oldest first: the newest ones by time
  /// written, the one being written included (an MPEG-TS cut short still plays).
  List<String> segments() {
    final found = <(File, DateTime)>[];
    try {
      for (final entity in Directory(folder).listSync()) {
        if (entity is! File || !p.basename(entity.path).startsWith('segment') || !entity.path.endsWith('.ts')) continue;
        final stat = entity.statSync();
        if (stat.size == 0) continue;
        found.add((entity, stat.modified));
      }
    } on FileSystemException {
      return const [];
    }
    found.sort((a, b) {
      final byTime = a.$2.compareTo(b.$2);
      return byTime != 0 ? byTime : a.$1.path.compareTo(b.$1.path);
    });
    final wanted = (seconds / segmentSeconds).ceil() + 1;
    final kept = found.length > wanted ? found.sublist(found.length - wanted) : found;
    return [for (final (file, _) in kept) file.path];
  }

  /// Joins the last [seconds] into [destination] (an .mp4), with a picture of its last moment
  /// beside it ([thumbnailOf]) for the gallery; the clip's path, or null when there was nothing
  /// recorded yet or ffmpeg failed.
  Future<String?> save(String destination) async {
    final parts = segments();
    if (parts.isEmpty) return null;
    try {
      Directory(p.dirname(destination)).createSync(recursive: true);
      final list = File(p.join(folder, 'join.txt'));
      list.writeAsStringSync(
        [for (final part in parts) "file '${part.replaceAll("'", r"'\''")}'"].join('\n'),
        encoding: utf8,
      );
      final joined = await _run(ffmpeg, [
        '-hide_banner',
        '-loglevel',
        'error',
        '-y',
        '-f',
        'concat',
        '-safe',
        '0',
        '-i',
        list.path,
        '-c',
        'copy',
        '-movflags',
        '+faststart',
        destination,
      ]);
      if (joined.exitCode != 0 || !File(destination).existsSync()) return null;
      // The picture is a help for the gallery, never a reason to fail.
      try {
        await _run(ffmpeg, [
          '-hide_banner',
          '-loglevel',
          'error',
          '-y',
          '-sseof',
          '-1',
          '-i',
          destination,
          '-frames:v',
          '1',
          '-q:v',
          '4',
          thumbnailOf(destination),
        ]);
      } on Object {
        // No picture: the gallery draws the clip without one.
      }
      return destination;
    } on Object {
      return null;
    }
  }

  /// The picture of a clip's last moment, beside it.
  static String thumbnailOf(String clip) => '${p.withoutExtension(clip)}.thumb.jpg';

  /// Stops recording (ffmpeg is asked to finish, then ended) and deletes the segments.
  Future<void> stop() async {
    _stops++;
    _soundTick?.cancel();
    _soundTick = null;
    await sound?.stop();
    final process = _process;
    _process = null;
    if (process != null && !_stopping) {
      _stopping = true;
      process.kill();
      try {
        await process.exitCode.timeout(const Duration(seconds: 3));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
      }
    }
    await _feed?.close();
    _feed = null;
    _clear();
  }

  void _clear() {
    try {
      final directory = Directory(folder);
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    } on FileSystemException {
      // A segment still open on Windows: the next start or the system's cleanup takes it.
    }
  }
}
