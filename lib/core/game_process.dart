import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'game_log.dart';
import 'host.dart';

/// A game the launcher started, with its output going to its log file.
class RunningGame {
  /// [exitCode] completes once the game ended and its output is in its log (a stand-in process
  /// in tests).
  RunningGame(this.process, this.exitCode, this.started);

  final Process process;

  /// Completes with the game's exit code once it ended and its log is written.
  final Future<int> exitCode;
  final DateTime started;

  int get pid => process.pid;

  /// Asks the game to end (SIGTERM on Linux, TerminateProcess on Windows).
  bool stop() => process.kill();

  /// Asks the game to close as closing its window would, so it can save first: SIGTERM on
  /// Linux, taskkill without /F on Windows (which sends its windows WM_CLOSE).
  Future<void> close() async {
    if (!Platform.isWindows) {
      process.kill(ProcessSignal.sigterm);
      return;
    }
    try {
      await Process.run('taskkill', ['/PID', '$pid', '/T']);
    } on ProcessException {
      // The kill after the grace period still ends it.
    }
  }

  /// Ends the game at once (SIGKILL, TerminateProcess).
  bool kill() => process.kill(ProcessSignal.sigkill);
}

/// Starts installed games.
abstract final class GameProcess {
  /// Starts the installed game in [installed] with its folder as the working directory (AnyPS5
  /// maps /app0 under it) and [environment] on top of the launcher's; its output is appended to
  /// [logFile]: set aside first when it grew past [GameLog.rollLimit], started again past
  /// [logCap] while the game runs. [traced] marks the start line of a start with detailed
  /// logging.
  static Future<RunningGame> start({
    required String installed,
    required Map<String, String> environment,
    required String logFile,
    HostSystem? system,
    String? program,
    List<String> arguments = const [],
    DateTime Function()? clock,
    bool traced = false,
    int logCap = GameLog.cap,
    List<String> notes = const [],
  }) async {
    final host = system ?? HostSystem.current;
    final executable = program ?? p.join(installed, host.executableName);
    if (!File(executable).existsSync()) {
      throw ProcessException(executable, arguments, 'the game is not installed', 2);
    }
    Directory(p.dirname(logFile)).createSync(recursive: true);
    GameLog.rollForStart(logFile);
    final log = CappedLog(logFile, cap: logCap);
    final started = (clock ?? DateTime.now)();
    log.writeln(GameLog.startLine(started, p.basename(installed), traced: traced));
    // The launcher's own lines for this start (the controllers connected), after its start line.
    for (final note in notes) {
      log.writeln(note);
    }
    final Process process;
    try {
      process = await Process.start(executable, arguments, workingDirectory: installed, environment: environment);
    } on Object {
      log.close();
      rethrow;
    }
    final done = Completer<int>();
    final out = process.stdout.listen(log.add).asFuture<void>();
    final err = process.stderr.listen(log.add).asFuture<void>();
    unawaited(() async {
      final code = await process.exitCode;
      await Future.wait([out, err])
          .timeout(const Duration(seconds: 5), onTimeout: () => const [])
          .catchError((_) => <void>[]);
      log
        ..writeln('--- exit $code')
        ..close();
      done.complete(code);
    }());
    return RunningGame(process, done.future, started);
  }
}
