import 'dart:async';
import 'dart:io';
import 'package:anyps5_desktop/core/child_processes.dart';
import 'package:test/test.dart';

/// A program that runs for a minute unless it is ended.
(String, List<String>) get _longRunning => Platform.isWindows ? ('ping', ['-n', '60', '127.0.0.1']) : ('sleep', ['60']);

Future<Process> _start({bool endsWithLauncher = true}) {
  final (executable, arguments) = _longRunning;
  return ChildProcesses.start(executable, arguments, endsWithLauncher: endsWithLauncher);
}

Future<void> _until(bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException('it did not come true');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  // Whatever a test left running.
  tearDown(ChildProcesses.killAll);

  test('a process started is remembered, and forgotten when it ends', () async {
    final process = await _start();
    expect(ChildProcesses.count, 1);
    process.kill();
    await process.exitCode;
    await Future<void>.delayed(Duration.zero);
    expect(ChildProcesses.count, 0);
  });

  test('killAll ends every process and forgets them', () async {
    final first = await _start();
    final second = await _start();
    expect(ChildProcesses.count, 2);
    ChildProcesses.killAll();
    expect(ChildProcesses.count, 0);
    await first.exitCode.timeout(const Duration(seconds: 10));
    await second.exitCode.timeout(const Duration(seconds: 10));
  });

  test('killAll with nothing running does nothing', () {
    expect(ChildProcesses.count, 0);
    expect(ChildProcesses.killAll, returnsNormally);
    expect(ChildProcesses.count, 0);
  });

  test('a program that is to finish what it does is not remembered, and killAll leaves it', () async {
    final process = await _start(endsWithLauncher: false);
    expect(ChildProcesses.count, 0);
    var ended = false;
    unawaited(process.exitCode.then((_) => ended = true));
    ChildProcesses.killAll();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(ended, isFalse);
    process.kill();
    await process.exitCode.timeout(const Duration(seconds: 10));
  });

  test(
    'on Linux the programs a process started end too, however far down',
    () async {
      await ChildProcesses.start('sh', ['-c', 'sh -c "sleep 61 & sleep 62 & wait" & wait']);
      bool running() => Process.runSync('pgrep', ['-f', 'sleep 6[12]']).stdout.toString().trim().isNotEmpty;
      await _until(running);
      ChildProcesses.killAll();
      await _until(() => !running());
    },
    skip: Platform.isWindows ? 'Windows ends the tree with taskkill /T' : null,
  );
}
