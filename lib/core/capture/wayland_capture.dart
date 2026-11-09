import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../desktop/desktop.dart' show ScreenArea;
import '../host.dart';
import '../replay_buffer.dart' show ProcessRunner, ProcessStarter;
import 'video_encoders.dart' show ScreenGrab;

/// Why the game's window cannot be recorded under Wayland, each with its text in the language
/// files. Missing ffmpeg and encoders have their own texts, as on X11.
enum WaylandProblem {
  /// No xdg-desktop-portal answers on the session bus.
  noPortal('waylandNoPortal'),

  /// The portal this desktop has offers whole screens only.
  noWindowShare('waylandNoWindowShare'),

  /// No PipeWire to carry the picture.
  noPipeWire('waylandNoPipeWire'),

  /// gst-launch-1.0 or its PipeWire plugin is not installed.
  noGstreamer('waylandNoGstreamer'),

  /// The user closed the desktop's dialog without sharing a window.
  declined('waylandDeclined'),

  /// The portal or GStreamer failed along the way.
  failed('waylandFailed');

  const WaylandProblem(this.textKey);

  final String textKey;
}

/// What the desktop's ScreenCast portal offers.
class PortalInfo {
  const PortalInfo({required this.version, required this.sharesWindows});

  final int version;
  final bool sharesWindows;
}

/// A window the user shared: the PipeWire node that carries it.
class PortalGrant {
  const PortalGrant({required this.node, this.width, this.height, this.restoreToken});

  final int node;
  final int? width;
  final int? height;

  /// Asks for the same window next time without the dialog, where the desktop can.
  final String? restoreToken;

  ScreenArea? get area {
    final w = width;
    final h = height;
    return w == null || h == null || w <= 0 || h <= 0 ? null : ScreenArea(0, 0, w, h);
  }
}

/// org.freedesktop.portal.ScreenCast, behind an interface so tests need no desktop.
abstract interface class ScreenCastPortal {
  /// What it offers; null when no portal answers.
  Future<PortalInfo?> probe();

  /// Asks the desktop for one window, showing its dialog unless [restoreToken] brings the choice
  /// back. Null when the user declined. The sharing lasts until [close].
  Future<PortalGrant?> shareWindow({String? restoreToken});

  /// Ends the sharing, and a dialog still open.
  Future<void> close();
}

/// The picture of one recording: GStreamer writing raw frames into a named pipe that ffmpeg
/// reads. A pipe rather than the program's pipes because ffmpeg's standard input already takes
/// the game's sound, and so that 100 MB a second never pass through the launcher.
class WaylandFeed {
  WaylandFeed._(this._process, this._folder, this.pipe, this.width, this.height, this.framesPerSecond) {
    ended = _process.exitCode.then((_) {});
  }

  final Process _process;
  final Directory _folder;
  final String pipe;
  final int width;
  final int height;
  final int framesPerSecond;

  /// Completes when GStreamer stops: ffmpeg would otherwise wait on the pipe for ever.
  late final Future<void> ended;
  bool _closed = false;

  /// ffmpeg's arguments for this input.
  List<String> get input => [
    '-thread_queue_size',
    '64',
    '-f',
    'rawvideo',
    '-pixel_format',
    'bgr0',
    '-video_size',
    '${width}x$height',
    '-framerate',
    '$framesPerSecond',
    '-i',
    pipe,
  ];

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _process.kill();
    try {
      await _process.exitCode.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      _process.kill(ProcessSignal.sigkill);
    }
    try {
      if (_folder.existsSync()) _folder.deleteSync(recursive: true);
    } on FileSystemException {
      // The system's cleanup takes it.
    }
  }
}

/// Recording under Wayland, where no program may read another's window without the user's say.
/// The desktop's portal asks which window to share and hands a PipeWire node; GStreamer's
/// pipewiresrc turns that into raw frames for ffmpeg, whose released versions have no PipeWire
/// input. One sharing serves everything recording the game and ends with it.
///
/// GStreamer connects to the user's PipeWire by node number, not through the portal's file
/// descriptor: a Dart program cannot hand a descriptor to a child. That needs the launcher to be
/// outside a sandbox, as its AppImage, .deb and .tar.gz are.
class WaylandCapture {
  WaylandCapture({
    required this.portal,
    required this.environment,
    this.readToken,
    this.saveToken,
    this.beforeAsking,
    this.log,
    ProcessRunner? run,
    ProcessStarter? start,
    bool Function(String path)? exists,
    Directory Function()? newFolder,
  }) : _run = run ?? ((executable, arguments) => Process.run(executable, arguments)),
       _start = start ?? ((executable, arguments) => Process.start(executable, arguments)),
       _exists = exists ?? ((path) => FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound),
       _newFolder = newFolder ?? (() => Directory.systemTemp.createTempSync('anyps5-wayland-'));

  final ScreenCastPortal portal;
  final Map<String, String> environment;

  /// Where the restore token lives between runs.
  final String? Function()? readToken;
  final void Function(String token)? saveToken;

  /// Waits for the game's window: the dialog lists open windows, and a restore needs it there.
  final Future<void> Function()? beforeAsking;
  final void Function(String line)? log;
  final ProcessRunner _run;
  final ProcessStarter _start;
  final bool Function(String path) _exists;
  final Directory Function() _newFolder;

  /// The elements GStreamer needs: pipewiresrc comes in its own package on most systems.
  static const elements = ['pipewiresrc', 'videoconvert', 'videoscale', 'videorate'];

  /// Whether this desktop is recorded through the portal: exactly the sessions x11grab never
  /// served, so X11 goes on as it was.
  static bool applies(HostSystem system, Map<String, String> environment) =>
      system == HostSystem.linux && (environment['XDG_SESSION_TYPE'] ?? '').toLowerCase() == 'wayland';

  PortalGrant? _grant;
  Future<PortalGrant?>? _asking;
  bool _refused = false;
  int _game = 0;

  /// The reason the last attempt failed; null when it worked or none was made.
  WaylandProblem? problem;

  /// The size of the window shared, standing in for a position Wayland does not reveal.
  ScreenArea? get area => _grant == null ? null : (_grant!.area ?? const ScreenArea(0, 0, 1920, 1080));

  /// What is missing here, without asking the user anything; null when all is in place.
  Future<WaylandProblem?> check() async {
    final PortalInfo? info;
    try {
      info = await portal.probe();
    } on Object catch (error) {
      log?.call('wayland: portal probe failed: $error');
      return problem = WaylandProblem.noPortal;
    }
    if (info == null) return problem = WaylandProblem.noPortal;
    if (!info.sharesWindows) return problem = WaylandProblem.noWindowShare;
    final runtime = environment['XDG_RUNTIME_DIR'] ?? '';
    final elsewhere = (environment['PIPEWIRE_REMOTE'] ?? '').isNotEmpty;
    if (runtime.isNotEmpty && !elsewhere && !_exists(p.posix.join(runtime, 'pipewire-0'))) {
      return problem = WaylandProblem.noPipeWire;
    }
    for (final element in elements) {
      try {
        final found = await _run('gst-inspect-1.0', [element]);
        if (found.exitCode != 0) {
          log?.call('wayland: GStreamer has no $element');
          return problem = WaylandProblem.noGstreamer;
        }
      } on ProcessException {
        return problem = WaylandProblem.noGstreamer;
      }
    }
    return problem = null;
  }

  /// The window shared for this game, asking the desktop when none is yet. Asked once a game:
  /// three things record it, and a user who said no is not asked again until the next one.
  Future<PortalGrant?> share() async {
    if (_grant != null) return _grant;
    if (_refused) return null;
    return _asking ??= _ask().whenComplete(() => _asking = null);
  }

  Future<PortalGrant?> _ask() async {
    final game = _game;
    if (await check() != null) return null;
    await beforeAsking?.call();
    if (game != _game) return null;
    final token = readToken?.call() ?? '';
    final PortalGrant? grant;
    try {
      grant = await portal.shareWindow(restoreToken: token.isEmpty ? null : token);
    } on Object catch (error) {
      log?.call('wayland: the portal failed: $error');
      problem = WaylandProblem.failed;
      _refused = true;
      return null;
    }
    if (game != _game) {
      await portal.close();
      return null;
    }
    if (grant == null) {
      problem = WaylandProblem.declined;
      _refused = true;
      return null;
    }
    // A token works once: the new one replaces it, and none means the desktop keeps nothing.
    saveToken?.call(grant.restoreToken ?? '');
    return _grant = grant;
  }

  /// GStreamer's arguments for [node], frames of [width] by [height] into [pipe]. The queue drops
  /// frames rather than let a busy encoder fall behind; keepalive repeats the last frame, as
  /// compositors send none while a window does not change.
  static List<String> gstreamerArguments({
    required int node,
    required int width,
    required int height,
    required int framesPerSecond,
    required String pipe,
  }) => [
    '-q',
    'pipewiresrc',
    'path=$node',
    'do-timestamp=true',
    'keepalive-time=100',
    '!',
    'queue',
    'leaky=downstream',
    'max-size-buffers=2',
    'max-size-bytes=0',
    'max-size-time=0',
    '!',
    'videoconvert',
    '!',
    'videoscale',
    '!',
    'videorate',
    '!',
    'video/x-raw,format=BGRx,width=$width,height=$height,framerate=$framesPerSecond/1,pixel-aspect-ratio=1/1',
    '!',
    'filesink',
    'location=$pipe',
    'buffer-mode=unbuffered',
    'sync=false',
  ];

  /// Starts the picture for one recording, within [maxWidth] by [maxHeight] in the window's own
  /// shape; null with [problem] set when it cannot be had.
  Future<WaylandFeed?> openFeed({required int maxWidth, required int maxHeight, required int framesPerSecond}) async {
    final grant = await share();
    if (grant == null) return null;
    final (width, height) = ScreenGrab.fit(area, maxWidth, maxHeight);
    Directory? folder;
    try {
      folder = _newFolder();
      final pipe = p.posix.join(folder.path, 'picture');
      final made = await _run('mkfifo', [pipe]);
      if (made.exitCode != 0) throw ProcessException('mkfifo', [pipe], 'exit ${made.exitCode}', made.exitCode);
      final process = await _start(
        'gst-launch-1.0',
        gstreamerArguments(
          node: grant.node,
          width: width,
          height: height,
          framesPerSecond: framesPerSecond,
          pipe: pipe,
        ),
      );
      process.stdout.listen((_) {}, onError: (_) {});
      final errors = StringBuffer();
      process.stderr.listen((data) {
        if (errors.length < 2000) errors.write(String.fromCharCodes(data));
      }, onError: (_) {});
      final feed = WaylandFeed._(process, folder, pipe, width, height, framesPerSecond);
      unawaited(
        process.exitCode.then((code) {
          if (!feed._closed) log?.call('wayland: GStreamer ended ($code) ${errors.toString().trim()}');
        }),
      );
      return feed;
    } on Object catch (error) {
      log?.call('wayland: the picture did not start: $error');
      problem = WaylandProblem.failed;
      try {
        folder?.deleteSync(recursive: true);
      } on FileSystemException {
        // The system's cleanup takes it.
      }
      return null;
    }
  }

  /// The game ended: the sharing with it. The next game may ask again.
  Future<void> end() async {
    _game++;
    _grant = null;
    _refused = false;
    problem = null;
    await portal.close();
  }
}
