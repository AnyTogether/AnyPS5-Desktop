import 'dart:convert';
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:io' as io show pid;

import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import 'launcher_health_native.dart';
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
    this.thread,
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
    thread: switch (json['thread']) {
      final List<dynamic> lines => [for (final line in lines) '$line'],
      _ => null,
    },
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

  /// What the watchdog saw of the interface's thread a few seconds into the stall: whether it was
  /// busy on the CPU or waiting, then where ([ThreadSampler]).
  final List<String>? thread;

  /// A run that ended without closing (a crash, or a stall it never came out of): the system may
  /// have a report of how it ended.
  bool get endedUnclosed => kind == LauncherProblemKind.crash || !recovered;

  LauncherProblem copyWith({
    String? error,
    int? pid,
    DateTime? started,
    Duration? stalledFor,
    bool? recovered,
    List<String>? thread,
  }) => LauncherProblem(
    kind: kind,
    at: at,
    version: version,
    platform: platform,
    stalledFor: stalledFor ?? this.stalledFor,
    recovered: recovered ?? this.recovered,
    whileClosing: whileClosing,
    error: error ?? this.error,
    lines: lines,
    pid: pid ?? this.pid,
    started: started ?? this.started,
    thread: thread ?? this.thread,
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
    'thread': ?thread,
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
  LauncherShutdown({
    required this.health,
    required this.closeWindow,
    required this.exit,
    this.beforeClose,
    this.fallbackAfter = defaultFallbackAfter,
    this.unansweredAfter = defaultUnansweredAfter,
  });

  final LauncherHealth health;

  /// Asks the window to close; whether it was asked.
  final Future<bool> Function() closeWindow;
  final void Function(int code) exit;

  /// Before the marker is written: the watchdog stops writing it.
  final void Function()? beforeClose;

  /// A close that has not ended the process this long after the exit request was answered (the
  /// game asked to close and given its time, the child programs ended: [childrenEnded]) is not
  /// coming: exit().
  static const defaultFallbackAfter = Duration(seconds: 5);

  /// A close the launcher never answered (the exit request does not come, or hangs before the
  /// game's time even starts): exit() after this long. Longer than what the request itself waits
  /// for (the emulator hosts, the game's grace, the replay buffer) and [fallbackAfter].
  static const defaultUnansweredAfter = Duration(seconds: 20);

  /// See [defaultFallbackAfter].
  final Duration fallbackAfter;

  /// See [defaultUnansweredAfter].
  final Duration unansweredAfter;

  bool _quitting = false;
  bool _closeAsked = false;
  bool _childrenEnded = false;
  int _code = 0;
  Timer? _fallback;

  /// The exit request was answered: the game had its time to save and the child programs are
  /// ended. Only now does a Quit's five seconds start (a game that takes longer than that to
  /// save is not cut off); the title bar's close has no timer at all.
  void childrenEnded() {
    _childrenEnded = true;
    if (_closeAsked) _arm(fallbackAfter);
  }

  void _arm(Duration after) {
    _fallback?.cancel();
    _fallback = Timer(after, () {
      health.closed();
      exit(_code);
    });
  }

  Future<void> quit(int code) async {
    if (_quitting) return;
    _quitting = true;
    beforeClose?.call();
    health.closing();
    if (await closeWindow()) {
      _code = code;
      _closeAsked = true;
      _arm(_childrenEnded ? fallbackAfter : unansweredAfter);
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

  /// How long the interface has not answered (null before its first ping).
  Duration? quietFor(DateTime now) => _ping == null ? null : now.difference(_ping!);

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

/// What each of the interface's pings carries to the watchdog, as on the Mac: the last seconds
/// whenever a line was added since the ping before (a line a second), and the first uncaught
/// error once it is caught. A stall's report then ends at most a second before the stall began:
/// sent every fourth second, its last seconds could stop up to four seconds short of it.
class PingFeed {
  int _sentLines = -1;
  String? _sentError;

  /// What the next ping carries: [lines] when [added] (the lines added so far) changed, [error]
  /// when it is new; null for what the watchdog has already.
  ({List<String>? lines, String? error}) next({required int added, required List<String> lines, String? error}) {
    final freshLines = added != _sentLines;
    _sentLines = added;
    final freshError = error != null && error != _sentError;
    if (freshError) _sentError = error;
    return (lines: freshLines ? List.of(lines) : null, error: freshError ? error : null);
  }
}

/// [LauncherHealth]'s watchdog in an isolate of its own, which keeps running while the
/// interface's isolate is stuck: it writes the stall to problem.json as soon as it is long, with
/// what it saw of the interface's thread then ([ThreadSampler]), its length again every [every]
/// while it lasts and once more when it ends, and the run's marker every few seconds with what
/// [ping] told it. While the interface answers it reads nothing of that thread: a second without
/// an answer (a fifth of the limit), it notes the thread's CPU time once, to tell a busy thread
/// from a waiting one.
class StallWatch {
  StallWatch._(this._port);

  final SendPort _port;

  /// How often a stall's length is written again while it lasts.
  static const every = Duration(seconds: 5);

  /// Started from the interface's isolate: the thread it runs on is the one sampled ([threadId]
  /// for another one).
  static Future<StallWatch> start(
    LauncherHealth health, {
    required DateTime started,
    int? threadId,
    Duration limit = LauncherHealth.stall,
    Duration every = every,
  }) async {
    final ready = ReceivePort();
    await Isolate.spawn(_run, [
      ready.sendPort,
      health.folder,
      health.pid,
      health.version,
      health.platform,
      started.toUtc().toIso8601String(),
      threadId ?? ThreadSampler.currentId(),
      limit.inMilliseconds,
      every.inMilliseconds,
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
    final threadId = arguments[6] as int?;
    final limit = Duration(milliseconds: arguments[7]! as int);
    final every = Duration(milliseconds: arguments[8]! as int);
    final health = LauncherHealth(folder, version: version, platform: platform, pid: pid);
    final detector = StallDetector(limit: limit);
    final sampler = threadId == null ? null : ThreadSampler(threadId);
    var lines = const <String>[];
    String? error;
    var ticks = 0;
    final port = ReceivePort();
    reply.send(port.sendPort);

    // The stall being reported (or the last one), as problem.json has it.
    LauncherProblem? stall;
    DateTime? lastWrite;
    // The interface thread's CPU time a second into a silence, and when it was read.
    ({DateTime at, int cpuMs})? quiet;
    void write(LauncherProblem problem) {
      stall = problem;
      LauncherHealth._write(health.problemFile, problem.toJson());
    }

    var closing = false;
    port.listen((message) {
      if (message == 'closing') closing = true;
      final now = DateTime.now();
      if (message is List && message.length == 2) {
        if (message[0] case final List<Object?> told) lines = [for (final line in told) '$line'];
        if (message[1] case final String told) error = told;
      }
      quiet = null;
      final since = detector.stalledSince;
      final ended = detector.ping(now);
      if (ended != null && since != null) {
        final base =
            stall ??
            LauncherProblem(
              kind: LauncherProblemKind.hang,
              at: since,
              version: version,
              platform: platform,
              lines: lines,
            );
        write(base.copyWith(stalledFor: ended, recovered: true, error: error));
      }
    });
    Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (closing) return;
      final now = DateTime.now();
      if (quiet == null &&
          detector.stalledSince == null &&
          sampler != null &&
          (detector.quietFor(now) ?? Duration.zero) >= limit ~/ 5) {
        if (sampler.cpuMs() case final cpu?) quiet = (at: now, cpuMs: cpu);
      }
      if (detector.tick(now)) {
        final since = detector.stalledSince!;
        final length = now.difference(since);
        write(
          LauncherProblem(
            kind: LauncherProblemKind.hang,
            at: since,
            version: version,
            platform: platform,
            stalledFor: length,
            error: error,
            lines: lines,
          ),
        );
        // Written first: reading the thread can take up to a second.
        if (sampler != null) {
          final cpu = sampler.cpuMs();
          final window = quiet;
          final headline = ThreadSampler.headline(
            sampledMs: length.inMilliseconds,
            cpuMs: cpu == null || window == null ? null : cpu - window.cpuMs,
            windowMs: cpu == null || window == null ? null : now.difference(window.at).inMilliseconds,
          );
          write(stall!.copyWith(thread: [headline, ...sampler.where()]));
        }
        lastWrite = now;
      } else if (detector.stalledSince case final since?
          when stall != null && !stall!.recovered && lastWrite != null && now.difference(lastWrite!) >= every) {
        // Still stuck: how long so far, for a run that never comes out of it.
        write(stall!.copyWith(stalledFor: now.difference(since)));
        lastWrite = now;
      }
      // The marker every five seconds: what a crash report says the launcher was doing.
      if (++ticks % 10 == 0) {
        LauncherHealth._write(health._marker, {...health._markerJson(DateTime.parse(started), now, lines, error)});
      }
    });
  }
}

/// What the stall watchdog sees of the interface's thread a few seconds into a freeze, from its
/// own isolate: the CPU time the thread used and where it is, in the same lines as the Mac
/// launcher's ThreadSampler. Windows (x64): its stack, read by native/health/anyps5_health.c,
/// which holds the thread only while it copies its registers and the top of its stack. Linux: what
/// /proc tells of it (its state, its system call and where in the kernel it waits) and the return
/// addresses found on its stack, read through /proc/self/mem: nothing holds the thread.
class ThreadSampler {
  ThreadSampler(this.id);

  /// The thread: the kernel's thread id (Linux), the Win32 one (Windows).
  final int id;

  /// The frames a sample keeps: the innermost ones tell where it is stuck.
  static const frameLimit = 24;

  static const stackHeading = 'Stack:';
  static const stackUnread = 'Stack: could not be read.';

  /// The calling thread's id, or null when the native library is missing.
  static int? currentId() {
    try {
      final id = healthThreadId();
      return id > 0 ? id : null;
    } on Object {
      return null;
    }
  }

  /// The sample's first line: how far into the freeze it was taken and whether the thread was
  /// busy on the CPU or waiting in the [windowMs] before (from about a second into the freeze).
  static String headline({required int sampledMs, int? cpuMs, int? windowMs}) {
    final at = 'Sampled ${sampledMs ~/ 1000} s into the freeze';
    if (cpuMs == null || windowMs == null || windowMs <= 0) return '$at.';
    final used = cpuMs < 0 ? 0 : cpuMs;
    final doing = used * 2 >= windowMs ? 'busy on the CPU' : 'waiting, not on the CPU';
    // Tenths of a second rounded half up, as on the Mac: the same words for the same times.
    final tenths = (windowMs + 50) ~/ 100;
    return '$at: $doing ($used ms of CPU time in the ${tenths ~/ 10}.${tenths % 10} s before).';
  }

  /// The CPU time the thread has used, user and system, in ms.
  int? cpuMs() {
    if (Platform.isLinux) return _linuxStat()?.cpuMs;
    if (!Platform.isWindows) return null;
    try {
      final ms = healthCpuMs(id);
      return ms >= 0 ? ms : null;
    } on Object {
      return null;
    }
  }

  /// Where the thread is, the lines after the headline.
  List<String> where() {
    try {
      if (Platform.isWindows) return _windowsStack();
      if (Platform.isLinux) return _linux();
    } on Object {
      return const [stackUnread];
    }
    return const ['Stack: not read on this system.'];
  }

  List<String> _windowsStack() {
    const size = 8192;
    final out = calloc<Uint8>(size).cast<Utf8>();
    try {
      final count = healthStack(id, out, size, 1000);
      final text = out.toDartString();
      if (count < 0) return ['Stack: could not be read ($text).'];
      return [stackHeading, ...const LineSplitter().convert(text).take(frameLimit)];
    } finally {
      calloc.free(out);
    }
  }

  String get _task => '/proc/self/task/$id';

  ({String state, int cpuMs})? _linuxStat() {
    try {
      final stat = File('$_task/stat').readAsStringSync();
      // After "pid (name) ": the state (field 3), then utime and stime (fields 14 and 15), in
      // clock ticks of 1/100 s.
      final fields = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
      return (state: fields[0], cpuMs: (int.parse(fields[11]) + int.parse(fields[12])) * 10);
    } on Object {
      return null;
    }
  }

  static const _states = {
    'R': 'running',
    'S': 'sleeping',
    'D': 'in uninterruptible sleep (disk or driver)',
    'T': 'stopped',
    't': 'stopped by a debugger',
    'Z': 'ended',
  };

  List<String> _linux() {
    String read(String name) {
      try {
        return File('$_task/$name').readAsStringSync().trim();
      } on Object {
        return '';
      }
    }

    // "running", "-1 sp pc" outside a system call, or "nr arg1 … arg6 sp pc" inside one.
    final syscall = read('syscall').split(' ');
    final wchan = read('wchan');
    final state = _linuxStat()?.state;
    final parts = [
      if (state != null) '${_states[state] ?? 'state'} ($state)',
      if (syscall.length >= 3)
        switch (int.tryParse(syscall[0])) {
          -1 => 'not in a system call',
          final int number => 'in the system call ${_syscallName(number)}',
          null => null,
        },
      if (wchan.isNotEmpty && wchan != '0') 'waiting in $wchan',
    ].nonNulls;
    final lines = ['Kernel: ${parts.isEmpty ? 'nothing readable' : parts.join(', ')}.'];
    if (syscall.length < 3) {
      return [...lines, 'Stack: not read while the thread runs.'];
    }
    final sp = int.tryParse(syscall[syscall.length - 2]);
    final pc = int.tryParse(syscall[syscall.length - 1]);
    if (sp == null || pc == null) return [...lines, stackUnread];
    final maps = _maps();
    final frames = <String>[];
    void add(int address) {
      final line = _name(address, maps.code);
      if (line != null) frames.add('${frames.length}  $line');
    }

    add(pc);
    // The thread's stack from sp, to the end of its mapping or 32 KB.
    var stackEnd = sp;
    for (final region in maps.all) {
      if (sp >= region.start && sp < region.end) stackEnd = region.end;
    }
    final length = (stackEnd - sp).clamp(0, 32 * 1024);
    if (length > 0) {
      final memory = File('/proc/self/mem').openSync();
      try {
        memory.setPositionSync(sp);
        final bytes = memory.readSync(length);
        final words = ByteData.sublistView(bytes);
        int? last;
        for (var at = 0; at + 8 <= bytes.length && frames.length < frameLimit; at += 8) {
          final value = words.getUint64(at, Endian.little);
          if (value == last) continue;
          if (_name(value, maps.code) != null) {
            add(value);
            last = value;
          }
        }
      } finally {
        memory.closeSync();
      }
    }
    return [...lines, 'Stack (return addresses found on it; some may be left over from earlier calls):', ...frames];
  }

  /// The process's mappings, and those of them that are code from a file, sorted by address.
  static ({List<_Region> all, List<_Region> code}) _maps() {
    final all = <_Region>[];
    for (final line in File('/proc/self/maps').readAsLinesSync()) {
      // "start-end perms offset dev inode path"
      final fields = line.split(RegExp(r'\s+'));
      if (fields.length < 5) continue;
      final range = fields[0].split('-');
      final start = int.tryParse(range[0], radix: 16), end = int.tryParse(range.last, radix: 16);
      final offset = int.tryParse(fields[2], radix: 16);
      if (start == null || end == null || offset == null) continue;
      final path = fields.length >= 6 ? fields.sublist(5).join(' ') : '';
      all.add(_Region(start, end, offset, path, executable: fields[1].contains('x')));
    }
    all.sort((a, b) => a.start.compareTo(b.start));
    return (
      all: all,
      code: [
        for (final region in all)
          if (region.executable && region.path.startsWith('/')) region,
      ],
    );
  }

  /// "libc.so.6 +0x91234" (the offset in the file), or null for an address in no code.
  static String? _name(int address, List<_Region> code) {
    var low = 0, high = code.length - 1;
    while (low <= high) {
      final middle = (low + high) >> 1;
      final region = code[middle];
      if (address < region.start) {
        high = middle - 1;
      } else if (address >= region.end) {
        low = middle + 1;
      } else {
        return '${p.basename(region.path)} +0x${(address - region.start + region.offset).toRadixString(16)}';
      }
    }
    return null;
  }

  static String _syscallName(int number) =>
      (Abi.current() == Abi.linuxArm64 ? _arm64Calls : _x64Calls)[number] ?? 'number $number';

  static const _x64Calls = {
    0: 'read', 1: 'write', 3: 'close', 7: 'poll', 9: 'mmap', 11: 'munmap', 16: 'ioctl', 23: 'select', //
    24: 'sched_yield', 35: 'nanosleep', 42: 'connect', 43: 'accept', 44: 'sendto', 45: 'recvfrom', //
    46: 'sendmsg', 47: 'recvmsg', 61: 'wait4', 72: 'fcntl', 73: 'flock', 74: 'fsync', 75: 'fdatasync', //
    202: 'futex', 217: 'getdents64', 219: 'restart_syscall', 230: 'clock_nanosleep', 232: 'epoll_wait', //
    247: 'waitid', 257: 'openat', 262: 'newfstatat', 270: 'pselect6', 271: 'ppoll', 281: 'epoll_pwait', //
    288: 'accept4', 332: 'statx', 426: 'io_uring_enter', 441: 'epoll_pwait2', 449: 'futex_waitv',
  };

  static const _arm64Calls = {
    22: 'epoll_pwait', 25: 'fcntl', 29: 'ioctl', 32: 'flock', 56: 'openat', 57: 'close', 61: 'getdents64', //
    63: 'read', 64: 'write', 72: 'pselect6', 73: 'ppoll', 79: 'newfstatat', 82: 'fsync', 83: 'fdatasync', //
    95: 'waitid', 98: 'futex', 101: 'nanosleep', 115: 'clock_nanosleep', 124: 'sched_yield', //
    128: 'restart_syscall', 202: 'accept', 203: 'connect', 206: 'sendto', 207: 'recvfrom', 211: 'sendmsg', //
    212: 'recvmsg', 215: 'munmap', 222: 'mmap', 242: 'accept4', 260: 'wait4', 291: 'statx', //
    426: 'io_uring_enter', 441: 'epoll_pwait2', 449: 'futex_waitv',
  };
}

class _Region {
  const _Region(this.start, this.end, this.offset, this.path, {required this.executable});

  final int start;
  final int end;
  final int offset;
  final String path;
  final bool executable;
}
