import 'dart:convert';
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:io' as io show pid;

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import 'system_crash_report.dart';

/// What went wrong with the launcher itself (not a game) in an earlier run, offered as a report
/// at the next start.
enum LauncherProblemKind {
  /// The run ended without the launcher closing: a crash, or the user ending it from the task
  /// manager.
  crash,

  /// The interface did not answer for [LauncherProblem.stalledFor] (or until the run ended).
  hang,
}

class LauncherProblem {
  const LauncherProblem({
    required this.kind,
    required this.at,
    required this.version,
    required this.platform,
    this.stalledFor,
    this.recovered = false,
    this.whileClosing = false,
    this.error,
    this.lines = const [],
    this.pid,
    this.started,
  });

  factory LauncherProblem.fromJson(Map<String, dynamic> json) => LauncherProblem(
    kind: LauncherProblemKind.values.asNameMap()[json['kind']] ?? LauncherProblemKind.crash,
    at: DateTime.tryParse(json['at'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
    version: json['version'] as String? ?? '?',
    platform: json['platform'] as String? ?? '?',
    stalledFor: switch (json['stalledMs']) {
      final num ms => Duration(milliseconds: ms.toInt()),
      _ => null,
    },
    recovered: json['recovered'] == true,
    whileClosing: json['whileClosing'] == true,
    error: json['error'] as String?,
    lines: [for (final line in json['lines'] as List<dynamic>? ?? const []) '$line'],
    pid: switch (json['pid']) {
      final num pid => pid.toInt(),
      _ => null,
    },
    started: DateTime.tryParse(json['started'] as String? ?? ''),
  );

  final LauncherProblemKind kind;

  /// When it happened: the stall's start, or the last moment the run was seen alive.
  final DateTime at;
  final String version;

  /// "Windows" or "Linux".
  final String platform;
  final Duration? stalledFor;

  /// The stall ended by itself (the launcher went on).
  final bool recovered;

  /// The crash came after the launcher began to close (Quit, the window's close): shutting
  /// down failed.
  final bool whileClosing;

  /// The first error the run's Dart code did not catch, with its stack.
  final String? error;

  /// What the launcher was doing in its last seconds: a line a second of the frames it drew
  /// and what was on screen (FrameLog's lines).
  final List<String> lines;

  /// The process of the run that ended, and when it started: what the system's report of it is
  /// found by.
  final int? pid;
  final DateTime? started;

  /// A run that ended without closing (a crash, or a stall it never came out of): the system may
  /// have a report of how it ended.
  bool get endedUnclosed => kind == LauncherProblemKind.crash || !recovered;

  LauncherProblem copyWith({String? error, int? pid, DateTime? started}) => LauncherProblem(
    kind: kind,
    at: at,
    version: version,
    platform: platform,
    stalledFor: stalledFor,
    recovered: recovered,
    whileClosing: whileClosing,
    error: error ?? this.error,
    lines: lines,
    pid: pid ?? this.pid,
    started: started ?? this.started,
  );

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'at': at.toUtc().toIso8601String(),
    'version': version,
    'platform': platform,
    if (stalledFor != null) 'stalledMs': stalledFor!.inMilliseconds,
    if (recovered) 'recovered': true,
    if (whileClosing) 'whileClosing': true,
    if (error != null) 'error': error,
    'lines': lines,
    'pid': ?pid,
    if (started != null) 'started': started!.toUtc().toIso8601String(),
  };
}

/// The launcher's own crashes and long stalls, kept so the next start can offer a report:
///
/// - `running-<pid>.json` while a run lasts: when it started and, every few seconds, what it was
///   doing. When the launcher begins to close (its window, Quit, an update) it says so, and the
///   runner takes it away once the window has closed and Flutter has shut down
///   ([runnerRemovesMarker]; without a runner, closing takes it away). One left by a process that
///   is gone is a run that crashed or was ended, or that crashed while closing.
/// - `problem.json`: a stall the watchdog saw (written from its own isolate, so even an interface
///   that never answers again leaves it), or a crash found at start.
///
/// Nothing leaves the computer: the report is a GitHub issue the user opens and sends.
class LauncherHealth {
  LauncherHealth(
    this.folder, {
    required this.version,
    required this.platform,
    int? pid,
    bool Function(int pid)? alive,
    Future<String> Function(DateTime started, int pid)? systemReport,
  }) : pid = pid ?? io.pid,
       _alive = alive ?? processAlive,
       _systemReport = systemReport ?? ((started, pid) => SystemCrashReport.find(since: started, pid: pid));

  final String folder;
  final String version;
  final String platform;
  final int pid;
  final bool Function(int pid) _alive;

  /// What the system kept of how the run `pid` ended, or a line saying it kept nothing
  /// (SystemCrashReport.find).
  final Future<String> Function(DateTime started, int pid) _systemReport;

  /// A stall this long is a problem worth a report.
  static const stall = Duration(seconds: 5);

  /// The lines of recent activity a marker and a report keep.
  static const keptLines = 30;

  String get _marker => p.join(folder, 'running-$pid.json');

  /// This run's marker, for the runner to take away after a clean close.
  String get markerPath => _marker;

  /// The runner takes the marker away once the window has closed and Flutter has shut down
  /// (it said so through LauncherWindow.removeAfterClose).
  bool runnerRemovesMarker = false;
  String get problemFile => p.join(folder, 'problem.json');

  /// Starts this run's marker and returns what an earlier run left to report, if anything: the
  /// stall the watchdog wrote, else a crash read from the marker of a run whose process is gone.
  LauncherProblem? start({DateTime? now}) {
    final started = now ?? DateTime.now();
    LauncherProblem? found;
    try {
      Directory(folder).createSync(recursive: true);
      final saved = File(problemFile);
      if (saved.existsSync()) found = _read(saved);
      for (final entity in Directory(folder).listSync()) {
        final name = p.basename(entity.path);
        final match = RegExp(r'^running-(\d+)\.json$').firstMatch(name);
        if (entity is! File || match == null) continue;
        final other = int.parse(match[1]!);
        if (other == pid || _alive(other)) continue;
        final marker = _readJson(entity);
        entity.deleteSync();
        final markerStarted = DateTime.tryParse(marker?['started'] as String? ?? '');
        // A stall the watchdog wrote is the same run, told better; one it never came out of keeps
        // the process, for the system's report of how it ended.
        if (found case final stall?
            when stall.pid == null &&
                stall.endedUnclosed &&
                markerStarted != null &&
                !stall.at.isBefore(markerStarted)) {
          found = stall.copyWith(pid: other, started: markerStarted);
          _write(problemFile, found.toJson());
        }
        if (found != null || marker == null) continue;
        final closing = marker['closing'] as String?;
        found = LauncherProblem(
          kind: LauncherProblemKind.crash,
          at: DateTime.tryParse(closing ?? marker['alive'] as String? ?? marker['started'] as String? ?? '') ?? started,
          whileClosing: closing != null,
          version: marker['version'] as String? ?? version,
          platform: marker['platform'] as String? ?? platform,
          error: marker['error'] as String?,
          lines: [for (final line in marker['lines'] as List<dynamic>? ?? const []) '$line'],
          pid: other,
          started: markerStarted,
        );
        _write(problemFile, found.toJson());
      }
      _write(_marker, _markerJson(started, started, const [], null));
    } on FileSystemException {
      // Reports are a help, never a reason not to start.
    }
    return found;
  }

  /// Whether [problem] still waits for what the system kept of the run.
  static bool needsSystemReport(LauncherProblem problem) =>
      problem.endedUnclosed &&
      problem.pid != null &&
      problem.started != null &&
      !(problem.error ?? '').contains(SystemCrashReport.heading);

  /// [problem] with what the system kept of how the run ended (Windows Error Reporting's report,
  /// Linux's core dump), or a line saying it kept nothing, first in its error; read when the
  /// report is sent, a while after the crash, so a report written late is there too.
  Future<LauncherProblem> lookAgain(LauncherProblem problem) async {
    if (!needsSystemReport(problem)) return problem;
    final String report;
    try {
      report = await _systemReport(problem.started!, problem.pid!);
    } on Object {
      return problem;
    }
    return problem.copyWith(error: [report, ?problem.error].where((part) => part.isNotEmpty).join('\n\n'));
  }

  /// The launcher begins to close as it should. With the runner taking the marker away after a
  /// clean close, the marker says when closing began (written and flushed now, before anything
  /// in shutting down can fail); without one, the marker goes now.
  void closing({DateTime? now}) {
    if (!runnerRemovesMarker) return closed();
    final marker =
        _readJson(File(_marker)) ?? _markerJson(now ?? DateTime.now(), now ?? DateTime.now(), const [], null);
    _write(_marker, {...marker, 'closing': (now ?? DateTime.now()).toUtc().toIso8601String()});
  }

  /// The launcher has closed (or is about to exit() at once): no crash to find next time.
  void closed() {
    try {
      File(_marker).deleteSync();
    } on FileSystemException {
      // Already gone.
    }
  }

  /// The report was sent or put aside.
  void forget() {
    try {
      File(problemFile).deleteSync();
    } on FileSystemException {
      // Already gone.
    }
  }

  Map<String, dynamic> _markerJson(DateTime started, DateTime alive, List<String> lines, String? error) => {
    'pid': pid,
    'started': started.toUtc().toIso8601String(),
    'alive': alive.toUtc().toIso8601String(),
    'version': version,
    'platform': platform,
    'error': ?error,
    'lines': lines,
  };

  static LauncherProblem? _read(File file) {
    final json = _readJson(file);
    return json == null ? null : LauncherProblem.fromJson(json);
  }

  static Map<String, dynamic>? _readJson(File file) {
    try {
      final json = jsonDecode(file.readAsStringSync());
      return json is Map<String, dynamic> ? json : null;
    } on Object {
      return null;
    }
  }

  static void _write(String path, Map<String, dynamic> json) {
    try {
      File(path).writeAsStringSync(jsonEncode(json), flush: true);
    } on FileSystemException {
      // Kept nowhere this time.
    }
  }

  /// Whether a process with [pid] runs: /proc on Linux, OpenProcess and its exit code on Windows.
  static bool processAlive(int pid) {
    if (pid <= 0) return false;
    if (Platform.isLinux) return Directory('/proc/$pid').existsSync();
    if (!Platform.isWindows) return false;
    try {
      final kernel = DynamicLibrary.open('kernel32.dll');
      final open = kernel.lookupFunction<IntPtr Function(Uint32, Int32, Uint32), int Function(int, int, int)>(
        'OpenProcess',
      );
      // PROCESS_QUERY_LIMITED_INFORMATION
      final handle = open(0x1000, 0, pid);
      if (handle == 0) return false;
      try {
        final exitCode = kernel
            .lookupFunction<Int32 Function(IntPtr, Pointer<Uint32>), int Function(int, Pointer<Uint32>)>(
              'GetExitCodeProcess',
            );
        final code = calloc<Uint32>();
        try {
          // STILL_ACTIVE
          return exitCode(handle, code) != 0 && code.value == 259;
        } finally {
          calloc.free(code);
        }
      } finally {
        kernel.lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle')(handle);
      }
    } on Object {
      return false;
    }
  }
}

/// Quitting the launcher (its Quit, the window buttons' close, an update's installer, a Steam
/// game ending): the marker says closing, then the window closes as its title bar's close does
/// and the runner ends the process once Flutter has shut down. exit() straight from Dart, with
/// the engine still drawing, crashed on Windows (the full-screen close), and took the marker
/// away before it did. With no window to close, exit() as before.
class LauncherShutdown {
  LauncherShutdown({required this.health, required this.closeWindow, required this.exit, this.beforeClose});

  final LauncherHealth health;

  /// Asks the window to close; whether it was asked.
  final Future<bool> Function() closeWindow;
  final void Function(int code) exit;

  /// Before the marker is written: the watchdog stops writing it.
  final void Function()? beforeClose;

  /// A close that has not ended the process by then is not coming: exit().
  static const fallbackAfter = Duration(seconds: 5);

  bool _quitting = false;

  Future<void> quit(int code) async {
    if (_quitting) return;
    _quitting = true;
    beforeClose?.call();
    health.closing();
    if (await closeWindow()) {
      Timer(fallbackAfter, () {
        health.closed();
        exit(code);
      });
      return;
    }
    health.closed();
    exit(code);
  }
}

/// The watchdog's reckoning, apart from its isolate (tests drive it with made-up times): the
/// interface pings it a few times a second; no ping for [LauncherHealth.stall] is a stall. When the
/// watchdog's own ticks stop too, the computer slept: that gap is no stall.
class StallDetector {
  StallDetector({this.limit = LauncherHealth.stall, this.asleep = const Duration(seconds: 3)});

  final Duration limit;

  /// A gap between the watchdog's own ticks this long means the whole process was stopped.
  final Duration asleep;

  DateTime? _ping;
  DateTime? _tick;

  /// When the stall being reported began; null while the interface answers.
  DateTime? stalledSince;

  /// The interface answered: the stall that ended, when one was reported.
  Duration? ping(DateTime now) {
    final since = stalledSince;
    _ping = now;
    stalledSince = null;
    return since == null ? null : now.difference(since);
  }

  /// The watchdog's own tick: true when a stall has just become long enough to report.
  bool tick(DateTime now) {
    final last = _tick;
    _tick = now;
    if (last != null && now.difference(last) >= asleep) {
      _ping = now;
      return false;
    }
    final ping = _ping;
    if (ping == null || stalledSince != null || now.difference(ping) < limit) return false;
    stalledSince = ping;
    return true;
  }
}

/// [LauncherHealth]'s watchdog in an isolate of its own, which keeps running while the
/// interface's isolate is stuck: it writes the stall to problem.json as soon as it is long, again
/// with its length when it ends, and the run's marker every few seconds with what [ping] told it.
class StallWatch {
  StallWatch._(this._port);

  final SendPort _port;

  static Future<StallWatch> start(LauncherHealth health, {required DateTime started}) async {
    final ready = ReceivePort();
    await Isolate.spawn(_run, [
      ready.sendPort,
      health.folder,
      health.pid,
      health.version,
      health.platform,
      started.toUtc().toIso8601String(),
    ], debugName: 'stall watch');
    return StallWatch._(await ready.first as SendPort);
  }

  /// The interface is alive; [lines] (its last seconds) and [error] (its first uncaught error)
  /// go into the marker when given.
  void ping({List<String>? lines, String? error}) => _port.send([lines, error]);

  /// The launcher is closing: the watchdog writes nothing more (no marker after it was taken away).
  void closing() => _port.send('closing');

  static void _run(List<Object?> arguments) {
    final reply = arguments[0]! as SendPort;
    final folder = arguments[1]! as String;
    final pid = arguments[2]! as int;
    final version = arguments[3]! as String;
    final platform = arguments[4]! as String;
    final started = arguments[5]! as String;
    final health = LauncherHealth(folder, version: version, platform: platform, pid: pid);
    final detector = StallDetector();
    var lines = const <String>[];
    String? error;
    var ticks = 0;
    final port = ReceivePort();
    reply.send(port.sendPort);

    void stall(Duration length, {required bool recovered, required DateTime since}) => LauncherHealth._write(
      health.problemFile,
      LauncherProblem(
        kind: LauncherProblemKind.hang,
        at: since,
        version: version,
        platform: platform,
        stalledFor: length,
        recovered: recovered,
        error: error,
        lines: lines,
      ).toJson(),
    );

    var closing = false;
    port.listen((message) {
      if (message == 'closing') closing = true;
      final now = DateTime.now();
      if (message is List && message.length == 2) {
        if (message[0] case final List<Object?> told) lines = [for (final line in told) '$line'];
        if (message[1] case final String told) error = told;
      }
      final since = detector.stalledSince;
      final ended = detector.ping(now);
      if (ended != null && since != null) stall(ended, recovered: true, since: since);
    });
    Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (closing) return;
      final now = DateTime.now();
      if (detector.tick(now)) {
        stall(now.difference(detector.stalledSince!), recovered: false, since: detector.stalledSince!);
      }
      // The marker every five seconds: what a crash report says the launcher was doing.
      if (++ticks % 10 == 0) {
        LauncherHealth._write(health._marker, {...health._markerJson(DateTime.parse(started), now, lines, error)});
      }
    });
  }
}
