import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:anyps5_desktop/core/launcher_health.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// What the stall watchdog reads of a stuck interface thread (native/health on Windows, /proc on
/// Linux). Run on the Linux and the Windows runners (.github/workflows/ci.yml).
void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('anyps5_sampler'));
  tearDown(() => temp.deleteSync(recursive: true));

  LauncherHealth run(int pid) => LauncherHealth(
    p.join(temp.path, 'Launcher'),
    version: '0.1.27',
    platform: 'Windows',
    pid: pid,
    alive: (_) => false,
  );

  /// A thread stuck the way a frozen interface is: an isolate asleep in dart:io's sleep, which
  /// holds its thread. Gives that thread's id.
  Future<int> stuckThread(Duration length) async {
    final told = ReceivePort();
    await Isolate.spawn((SendPort port) {
      port.send(ThreadSampler.currentId());
      sleep(length);
    }, told.sendPort);
    final id = await told.first as int?;
    expect(id, isNotNull, reason: 'the native library gives the thread\'s id');
    return id!;
  }

  void expectWhereItWaits(List<String> where) {
    final all = where.join('\n');
    if (Platform.isLinux) {
      expect(where.first, startsWith('Kernel: sleeping (S), in the system call '), reason: all);
      expect(where.first, contains('nanosleep'), reason: all);
      expect(where, contains(startsWith('Stack (return addresses found on it')), reason: all);
      expect(where, contains(matches(RegExp(r'^0  libc\.so[^ ]* \+0x[0-9a-f]+$'))), reason: 'the pc, in libc: $all');
    } else {
      expect(where.first, ThreadSampler.stackHeading, reason: all);
      expect(where[1], matches(RegExp(r'^0  ntdll\.dll \+0x[0-9a-f]+$')), reason: 'stuck in the kernel\'s wait: $all');
      expect(all.toLowerCase(), contains('kernelbase.dll'), reason: 'unwound to Sleep: $all');
      expect(where.length, lessThanOrEqualTo(ThreadSampler.frameLimit + 1));
    }
  }

  final sampled = Platform.isLinux || Platform.isWindows ? null : 'reads /proc (Linux) or the native stack (Windows)';

  test('the sampler reads where a stuck thread waits, and that it uses no CPU', () async {
    final sampler = ThreadSampler(await stuckThread(const Duration(seconds: 3)));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final before = sampler.cpuMs();
    expect(before, isNotNull);
    expectWhereItWaits(sampler.where());
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(sampler.cpuMs()! - before!, lessThan(100), reason: 'a sleeping thread uses no CPU');
  }, skip: sampled);

  test(
    'the watchdog samples the stuck thread and writes the stall\'s length while it lasts',
    () async {
      final health = run(100)..start();
      final thread = await stuckThread(const Duration(seconds: 6));
      final watch = await StallWatch.start(
        health,
        started: DateTime.now(),
        threadId: thread,
        limit: const Duration(seconds: 2),
        every: const Duration(milliseconds: 500),
      );
      watch.ping(lines: ['frames 60 | look cosmic layer home in front']);
      final problem = File(health.problemFile);
      Future<LauncherProblem?> written(bool Function(LauncherProblem) awaited) async {
        for (var waited = 0; waited < 100; waited++) {
          try {
            final found = LauncherProblem.fromJson(jsonDecode(problem.readAsStringSync()) as Map<String, dynamic>);
            if (awaited(found)) return found;
          } on Object {
            // Not there yet, or being written.
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        return null;
      }

      final stuck = await written((found) => found.thread != null);
      expect(stuck, isNotNull, reason: 'the stall was written with its sample');
      expect(stuck!.recovered, isFalse);
      final sample = stuck.thread!;
      expect(
        sample.first,
        startsWith('Sampled 2 s into the freeze: waiting, not on the CPU ('),
        reason: sample.join('\n'),
      );
      expectWhereItWaits(sample.sublist(1));
      final longer = await written(
        (found) => found.stalledFor! >= const Duration(milliseconds: 3000) && !found.recovered,
      );
      expect(longer, isNotNull, reason: 'its length so far, written again while it lasts');
      expect(longer!.thread, sample, reason: 'the sample stays');
      watch.ping();
      final ended = await written((found) => found.recovered);
      expect(ended, isNotNull);
      expect(ended!.thread, sample, reason: 'the sample stays when it recovers');
      expect(ended.stalledFor!, greaterThanOrEqualTo(const Duration(seconds: 3)));
      watch.closing();
    },
    timeout: const Timeout(Duration(seconds: 30)),
    skip: sampled,
  );
}
