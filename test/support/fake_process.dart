import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/game_process.dart';
import 'package:anyps5_desktop/core/host.dart';

/// A game's process that runs until a test ends it: it records the signals it gets, and ends on
/// the first one unless told to hold on ([ignoresTerm], a game that does not close when asked).
class FakeGameProcess implements Process {
  FakeGameProcess({this.pid = 4242, this.ignoresTerm = false});

  @override
  final int pid;

  /// SIGTERM (close as the window would) is ignored; only SIGKILL ends it.
  final bool ignoresTerm;

  final signals = <ProcessSignal>[];
  final _exit = Completer<int>();

  bool get ended => _exit.isCompleted;

  /// The game ends on its own (the player quit it in game).
  void quit([int code = 0]) {
    if (!_exit.isCompleted) _exit.complete(code);
  }

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    signals.add(signal);
    if (signal == ProcessSignal.sigkill || !ignoresTerm) quit(-signal.signalNumber);
    return true;
  }

  @override
  Future<int> get exitCode => _exit.future;

  @override
  Stream<List<int>> get stdout => const Stream.empty();

  @override
  Stream<List<int>> get stderr => const Stream.empty();

  @override
  IOSink get stdin => IOSink(StreamController<List<int>>().sink, encoding: utf8);
}

/// Starts [process] (a new one each start by default) instead of the installed game, and keeps
/// what it was asked to start.
class FakeGameStarts {
  FakeGameStarts([FakeGameProcess Function()? make]) : make = make ?? FakeGameProcess.new;

  final FakeGameProcess Function() make;
  final started = <String>[];
  final processes = <FakeGameProcess>[];

  /// What each start was given: its environment, its arguments and its log notes.
  final environments = <Map<String, String>>[];
  final arguments = <List<String>>[];
  final notes = <List<String>>[];

  FakeGameProcess get last => processes.last;

  Future<RunningGame> call({
    required String installed,
    required Map<String, String> environment,
    List<String> arguments = const [],
    required String logFile,
    HostSystem? system,
    bool traced = false,
    List<String> notes = const [],
  }) async {
    started.add(installed);
    environments.add(environment);
    this.arguments.add(arguments);
    this.notes.add(notes);
    final process = make();
    processes.add(process);
    return RunningGame(process, process.exitCode, DateTime(2026, 10, 30, 20));
  }
}

/// A [RunningGame] of [process], as the launcher keeps one it started.
RunningGame runningFor(FakeGameProcess process) => RunningGame(process, process.exitCode, DateTime(2026, 10, 30, 20));
