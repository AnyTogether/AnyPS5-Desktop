import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The programs the launcher started and that end with it: the game, ffmpeg (the replay buffer,
/// Remote Play, a broadcast), the relinker, the engine's build and the like.
///
/// A process started with dart:io does not end with its parent on Windows, and on Linux its own
/// children do not either. Left alone, they outlive the launcher (an AnyPS5 process with no window
/// in Task Manager, an ffmpeg still recording). Each is started through [start] instead, and
/// [killAll] ends what is left when the launcher closes.
///
/// A process started in [ProcessStartMode.detached] (the update's installer, Steam) is not made
/// here: it is meant to outlive the launcher.
abstract final class ChildProcesses {
  static final Map<int, Process> _live = {};

  /// How many of the processes started here are running.
  static int get count => _live.length;

  /// [Process.start], with the process remembered until it ends. A program that must finish what
  /// it does even when the launcher closes (Install now of Git, moving a game to the Trash) is
  /// started with [endsWithLauncher] false: it is not remembered, and [killAll] leaves it.
  static Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    bool endsWithLauncher = true,
  }) async {
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: includeParentEnvironment,
      runInShell: runInShell,
    );
    if (endsWithLauncher) {
      final pid = process.pid;
      _live[pid] = process;
      unawaited(process.exitCode.then((_) => _live.remove(pid), onError: (Object _) => _live.remove(pid)));
    }
    return process;
  }

  /// Ends every process started here that is still running, and the programs they started in
  /// turn. Synchronous: nobody can wait for it while the launcher is closing.
  ///
  /// Windows: `taskkill /T /F` takes each process with its tree. POSIX: the whole tree is walked
  /// (a `pkill -P` on the direct children is not enough: the compilers under `cmake --build` are
  /// two levels down, below ninja), everything is asked to end with SIGTERM, and what is still
  /// there after a short pause is killed.
  static void killAll() {
    final processes = _live.values.toList();
    _live.clear();
    if (processes.isEmpty) return;
    try {
      if (Platform.isWindows) {
        Process.runSync('taskkill', ['/T', '/F', for (final process in processes) ...['/PID', '${process.pid}']]);
      } else {
        _endTrees(processes);
      }
    } on Object {
      // The kill of each process below still ends it.
    }
    for (final process in processes) {
      try {
        process.kill(ProcessSignal.sigkill);
      } on Object {
        // Gone already.
      }
    }
  }

  /// POSIX: SIGTERM to [roots] and all their descendants, then SIGKILL to the descendants still
  /// there after a short pause (the roots get theirs from [killAll]).
  static void _endTrees(List<Process> roots) {
    final seen = <int>{for (final process in roots) process.pid};
    final descendants = <int>[];
    void walk(int pid) {
      final result = Process.runSync('pgrep', ['-P', '$pid']);
      for (final line in const LineSplitter().convert('${result.stdout}')) {
        final child = int.tryParse(line.trim());
        if (child != null && seen.add(child)) {
          descendants.add(child);
          walk(child);
        }
      }
    }

    for (final process in roots) {
      walk(process.pid);
    }
    Process.runSync('kill', [
      '-TERM',
      for (final process in roots) '${process.pid}',
      ...descendants.map((pid) => '$pid'),
    ]);
    if (descendants.isEmpty) return;
    // A moment to end by themselves, then the ones that did not.
    sleep(const Duration(milliseconds: 300));
    Process.runSync('kill', ['-KILL', ...descendants.map((pid) => '$pid')]);
  }
}
