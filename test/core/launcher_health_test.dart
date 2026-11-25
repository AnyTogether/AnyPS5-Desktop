import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/crash_report.dart';
import 'package:anyps5_desktop/core/launcher_health.dart';
import 'package:fake_async/fake_async.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The launcher's own crashes and stalls: found at the next start, told in a GitHub issue the user
/// opens, nothing of theirs in it.
void main() {
  late Directory temp;
  late String folder;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('anyps5_health');
    folder = p.join(temp.path, 'Launcher');
  });
  tearDown(() => temp.deleteSync(recursive: true));

  LauncherHealth run(int pid, {Set<int> alive = const {}}) =>
      LauncherHealth(folder, version: '0.1.12', platform: 'Windows', pid: pid, alive: alive.contains);

  test('a run that closed as it should leaves nothing to report', () {
    final first = run(100);
    expect(first.start(), isNull);
    first.closed();
    expect(run(200).start(), isNull);
  });

  test('a run whose process is gone without closing was a crash; one still running is not', () {
    final first = run(100);
    first.start(now: DateTime.utc(2026, 10, 28, 20));
    // Another launcher running beside this one is no crash.
    expect(run(200, alive: {100}).start(now: DateTime.utc(2026, 10, 28, 20)), isNull);
    final problem = run(300).start();
    expect(problem?.kind, LauncherProblemKind.crash);
    expect(problem?.version, '0.1.12');
    expect(problem?.at, DateTime.utc(2026, 10, 28, 20));
    final fourth = run(400);
    expect(fourth.start()?.kind, LauncherProblemKind.crash, reason: 'kept until sent or put aside');
    fourth
      ..forget()
      ..closed();
    expect(run(500).start(), isNull);
  });

  group('what the system kept of how the run ended', () {
    test(
      'a crash keeps its process and start; sending looks for the system\'s report once, first in the error',
      () async {
        final first = run(100)..start(now: DateTime.utc(2026, 11, 9, 4));
        expect(first.pid, 100);
        final problem = run(200).start()!;
        expect(problem.pid, 100);
        expect(problem.started, DateTime.utc(2026, 11, 9, 4));
        expect(LauncherProblem.fromJson(problem.toJson()).pid, 100, reason: 'kept in problem.json');
        expect(LauncherHealth.needsSystemReport(problem), isTrue);
        final asked = <String>[];
        final health = LauncherHealth(
          folder,
          version: '0.1.12',
          platform: 'Windows',
          pid: 300,
          alive: (_) => false,
          systemReport: (started, pid) async {
            asked.add('$pid ${started.toIso8601String()}');
            return 'System crash report (Windows Error Reporting):\n  Exception Code: c0000005';
          },
        );
        final told = await health.lookAgain(problem.copyWith(error: 'Bad state: No element'));
        expect(asked, ['100 2026-11-09T04:00:00.000Z']);
        expect(
          told.error,
          'System crash report (Windows Error Reporting):\n  Exception Code: c0000005\n\nBad state: No element',
        );
        expect(await health.lookAgain(told), same(told), reason: 'looked for once');
        expect(asked, hasLength(1));
        final recovered = LauncherProblem(
          kind: LauncherProblemKind.hang,
          at: DateTime.utc(2026, 11, 9, 4),
          version: '0.1.12',
          platform: 'Windows',
          stalledFor: const Duration(seconds: 6),
          recovered: true,
          pid: 100,
          started: DateTime.utc(2026, 11, 9, 4),
        );
        expect(await health.lookAgain(recovered), same(recovered), reason: 'a stall it came out of ended no run');
      },
    );

    test('a stall the run never came out of keeps its process too', () {
      run(100).start(now: DateTime.utc(2026, 11, 9, 4));
      File(p.join(folder, 'problem.json')).writeAsStringSync(
        jsonEncode(
          LauncherProblem(
            kind: LauncherProblemKind.hang,
            at: DateTime.utc(2026, 11, 9, 4, 10),
            version: '0.1.12',
            platform: 'Windows',
            stalledFor: const Duration(seconds: 8),
          ).toJson(),
        ),
      );
      final problem = run(200).start()!;
      expect(problem.kind, LauncherProblemKind.hang);
      expect(problem.pid, 100);
      expect(LauncherHealth.needsSystemReport(problem), isTrue);
    });
  });

  group('closing', () {
    test('with the runner taking the marker away after a clean close: the marker says closing until then', () {
      final first = run(100)..start(now: DateTime.utc(2026, 10, 30, 1));
      first
        ..runnerRemovesMarker = true
        ..closing(now: DateTime.utc(2026, 10, 30, 1, 5));
      final marker = File(p.join(folder, 'running-100.json'));
      expect(marker.existsSync(), isTrue, reason: 'still there: a crash while shutting down must leave it');
      expect((jsonDecode(marker.readAsStringSync()) as Map)['closing'], '2026-10-30T01:05:00.000Z');
      // The runner closed the window, Flutter shut down, and it took the marker away.
      marker.deleteSync();
      expect(run(200).start(), isNull, reason: 'a clean quit is no crash');
    });

    test('a crash while closing (the marker left) is reported as one, said apart', () {
      final first = run(100)..start(now: DateTime.utc(2026, 10, 30, 1));
      first
        ..runnerRemovesMarker = true
        ..closing(now: DateTime.utc(2026, 10, 30, 1, 5));
      final problem = run(200).start();
      expect(problem?.kind, LauncherProblemKind.crash);
      expect(problem?.whileClosing, isTrue);
      expect(problem?.at, DateTime.utc(2026, 10, 30, 1, 5), reason: 'when it began to close');
      expect(LauncherProblem.fromJson(problem!.toJson()).whileClosing, isTrue);
    });

    test('without a runner to take it away, closing takes the marker away itself', () {
      run(100)
        ..start()
        ..closing();
      expect(File(p.join(folder, 'running-100.json')).existsSync(), isFalse);
      expect(run(200).start(), isNull);
    });

    test('Quit: the marker is written before the window is asked to close; without a window, exit', () async {
      final health = run(100)
        ..start()
        ..runnerRemovesMarker = true;
      final marker = File(p.join(folder, 'running-100.json'));
      final said = <String>[];
      var closingAtClose = false;
      final shutdown = LauncherShutdown(
        health: health,
        beforeClose: () => said.add('watch'),
        closeWindow: () async {
          closingAtClose = (jsonDecode(marker.readAsStringSync()) as Map).containsKey('closing');
          said.add('close');
          return true;
        },
        exit: (code) => said.add('exit $code'),
      );
      await shutdown.quit(0);
      expect(said, ['watch', 'close'], reason: 'the window closes as its title bar\'s close does: no exit()');
      expect(closingAtClose, isTrue, reason: 'flushed before anything that can fail');
      expect(marker.existsSync(), isTrue, reason: 'the runner takes it away once shut down');

      final other = run(300)..start();
      final exits = <int>[];
      await LauncherShutdown(health: other, closeWindow: () async => false, exit: exits.add).quit(0);
      expect(exits, [0], reason: 'no window to close: exit, as before');
      expect(File(p.join(folder, 'running-300.json')).existsSync(), isFalse);
    });

    test('a window that never closes after Quit: exit after a while, the marker gone first', () {
      fakeAsync((async) {
        final health = run(100)
          ..start()
          ..runnerRemovesMarker = true;
        final exits = <int>[];
        LauncherShutdown(health: health, closeWindow: () async => true, exit: exits.add).quit(0);
        async.elapse(LauncherShutdown.defaultUnansweredAfter - const Duration(seconds: 1));
        expect(exits, isEmpty);
        async.elapse(const Duration(seconds: 1));
        expect(exits, [0]);
        expect(File(p.join(folder, 'running-100.json')).existsSync(), isFalse);
      });
    });

    test('Quit: the five seconds start once the exit request is answered, not at the close', () {
      fakeAsync((async) {
        final health = run(100)
          ..start()
          ..runnerRemovesMarker = true;
        final exits = <int>[];
        final shutdown = LauncherShutdown(health: health, closeWindow: () async => true, exit: exits.add)..quit(0);
        async.elapse(const Duration(seconds: 12));
        expect(exits, isEmpty, reason: 'a game saving for 12 seconds is not cut off');
        shutdown.childrenEnded();
        async.elapse(LauncherShutdown.defaultFallbackAfter - const Duration(seconds: 1));
        expect(exits, isEmpty);
        async.elapse(const Duration(seconds: 1));
        expect(exits, [0], reason: 'a close that hangs after the game ended is still ended');
      });
    });

    test('the title bar\'s close has no timer', () {
      fakeAsync((async) {
        final exits = <int>[];
        LauncherShutdown(health: run(100)..start(), closeWindow: () async => true, exit: exits.add).childrenEnded();
        async.elapse(const Duration(minutes: 1));
        expect(exits, isEmpty);
      });
    });

    test('Quit twice closes once', () async {
      final health = run(100)..start();
      var closes = 0;
      final shutdown = LauncherShutdown(
        health: health,
        closeWindow: () async {
          closes++;
          return true;
        },
        exit: (_) {},
      );
      await Future.wait([shutdown.quit(0), shutdown.quit(0)]);
      expect(closes, 1);
    });
  });

  test('the watchdog sees a stall only past five seconds, and none while the computer slept', () {
    final detector = StallDetector();
    final start = DateTime(2026, 10, 28, 20);
    DateTime at(int ms) => start.add(Duration(milliseconds: ms));
    detector.ping(at(0));
    for (var ms = 500; ms < 5000; ms += 500) {
      expect(detector.tick(at(ms)), isFalse);
    }
    expect(detector.tick(at(5000)), isTrue, reason: 'five seconds without an answer');
    expect(detector.tick(at(5500)), isFalse, reason: 'told once');
    expect(detector.ping(at(12000)), const Duration(seconds: 12));
    expect(detector.ping(at(12250)), isNull);

    // Asleep: the watchdog's own ticks stopped as long as the pings did.
    detector.tick(at(12500));
    expect(detector.tick(at(60000)), isFalse);
    expect(detector.tick(at(60500)), isFalse);
  });

  test('each ping carries the last seconds once a line was added since the one before, the error once', () {
    final feed = PingFeed();
    final lines = ['12:00:00 frames 31 | look aurora layer home in front'];
    var ping = feed.next(added: 1, lines: lines);
    expect(ping.lines, lines, reason: 'the first ping has them');
    expect(ping.error, isNull);
    ping = feed.next(added: 1, lines: lines);
    expect(ping.lines, isNull, reason: 'no new line: nothing to send again');
    lines.add('12:00:01 frames 31 | look aurora layer home starting PPSA99313 in front');
    ping = feed.next(added: 2, lines: lines, error: 'Bad state: No element');
    expect(ping.lines!.last, contains('starting PPSA99313'), reason: 'the newest second, not four seconds late');
    expect(ping.error, 'Bad state: No element');
    lines.add('changed after');
    expect(ping.lines, hasLength(2), reason: 'a copy, not the list the interface goes on changing');
    ping = feed.next(added: 2, lines: lines, error: 'Bad state: No element');
    expect(ping.error, isNull, reason: 'the watchdog keeps it');
    // Past the 30 kept lines the list keeps its length: the count still tells a new line came.
    expect(feed.next(added: 3, lines: lines).lines, isNotNull);
  });

  test('the watchdog\'s isolate writes a stall the interface never comes back from', () async {
    final health = run(100)..start();
    final watch = await StallWatch.start(health, started: DateTime.now());
    watch.ping(lines: ['frames 60 build 2.1/3.0/4.2 raster 3.0/4.1/6.0 | look cosmic layer home in front']);
    // The interface's isolate is stuck from here: no more pings.
    final problem = File(health.problemFile);
    // The watchdog writes from its own isolate, on its own time, and a write truncates the file
    // before it fills it: wait for a whole report that says what is awaited, not a fixed time.
    Future<LauncherProblem?> written(bool Function(LauncherProblem) awaited) async {
      for (var waited = 0; waited < 80; waited++) {
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

    final stall = await written((_) => true);
    expect(stall, isNotNull, reason: 'the stall was written');
    expect(stall!.kind, LauncherProblemKind.hang);
    expect(stall.recovered, isFalse);
    expect(stall.lines.single, contains('layer home'));
    watch.ping();
    final ended = await written((found) => found.recovered);
    expect(ended, isNotNull, reason: 'the stall that ended was written');
    expect(ended!.stalledFor!.inSeconds, greaterThanOrEqualTo(5));
    watch.closing();
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('the issue: version, system, error and last seconds, without the home folder or the user', () {
    final problem = LauncherProblem(
      kind: LauncherProblemKind.hang,
      at: DateTime.utc(2026, 10, 28, 20, 5, 1),
      version: '0.1.12',
      platform: 'Windows',
      stalledFor: const Duration(seconds: 9),
      recovered: true,
      error:
          'FileSystemException: Cannot open file, path = \'C:\\Users\\ada\\AppData\\Roaming\\AnyPS5\\x.json\'\n'
          '#0 _File.open (dart:io/file_impl.dart:381)',
      lines: [for (var second = 0; second < 30; second++) 'frames $second | look cosmic layer settings in front'],
    );
    final draft = IssueDraft.launcherProblem(
      problem,
      system: const SystemInfo(os: 'Windows 11 Pro 10.0 (Build 22631)', cpu: 'AMD Ryzen 7 5800X', memoryGB: 32),
      privacy: const ReportPrivacy(home: r'C:\Users\ada', names: ['ada', 'ADA-PC']),
    );
    expect(draft.repository, 'AnyTogether/AnyPS5-Desktop');
    expect(draft.url.queryParameters['template'], 'launcher_crash.yml');
    expect(draft.title, 'Launcher stopped responding (9s)');
    final text = draft.preview;
    expect(text, contains('Launcher 0.1.12 (Windows)'));
    expect(text, contains('AMD Ryzen 7 5800X'));
    expect(text, contains('did not answer for 9 s'));
    expect(text, contains('_File.open'));
    expect(text, contains('frames 29 | look cosmic layer settings'));
    expect(text.toLowerCase(), isNot(contains('ada')), reason: 'the user and the computer are taken out');
    expect(text, isNot(contains(r'C:\Users')), reason: 'the home folder too');
    expect(draft.url.toString().length, lessThanOrEqualTo(IssueDraft.maximumLength));
  });

  test('a stall\'s report says how long it lasted, whether it recovered and what the interface thread did', () {
    final thread = [
      ThreadSampler.headline(sampledMs: 5100, cpuMs: 12, windowMs: 4000),
      ThreadSampler.stackHeading,
      '0  ntdll.dll +0x9d1b4',
      r'1  anyps5_desktop.exe +0x1234 C:\Users\ada\x',
    ];
    final never = LauncherProblem(
      kind: LauncherProblemKind.hang,
      at: DateTime.utc(2026, 11, 21, 23, 9, 12),
      version: '0.1.27',
      platform: 'Windows',
      stalledFor: const Duration(milliseconds: 20300),
      thread: thread,
    );
    expect(LauncherProblem.fromJson(jsonDecode(jsonEncode(never.toJson())) as Map<String, dynamic>).thread, thread);
    const system = SystemInfo(os: 'Windows 10 Pro 22H2 (Build 19045.6456)');
    const privacy = ReportPrivacy(home: r'C:\Users\ada', names: ['ada']);
    final draft = IssueDraft.launcherProblem(never, system: system, privacy: privacy);
    expect(draft.title, 'Launcher stopped responding (20s+, never recovered)');
    expect(
      draft.url.queryParameters['what'],
      'The interface stopped answering at 2026-11-21 23:09:12 UTC and had not recovered 20 s later, when the watchdog '
      'last looked before the launcher was closed.',
    );
    final sample = draft.url.queryParameters['thread']!;
    expect(
      sample,
      startsWith(
        'Sampled 5 s into the freeze: waiting, not on the CPU (12 ms of CPU time in the 4.0 s before).\nStack:\n'
        '0  ntdll.dll +0x9d1b4',
      ),
    );
    expect(sample.toLowerCase(), isNot(contains('ada')), reason: 'cleaned like every field');
    expect(draft.fields.map((field) => field.label).elementAt(3), 'Interface thread while stuck');
    final whole = IssueDraft.launcherProblemText(never, system: system, privacy: privacy);
    expect(whole, contains('Interface thread while stuck:\nSampled 5 s into the freeze'));
    // A stall from before the watchdog sampled, and a crash, which has no freeze to sample.
    final old = IssueDraft.launcherProblem(
      LauncherProblem(
        kind: LauncherProblemKind.hang,
        at: DateTime.utc(2026, 11, 19, 19, 7, 2),
        version: '0.1.27',
        platform: 'Windows',
        stalledFor: const Duration(seconds: 19),
        recovered: true,
      ),
      system: system,
      privacy: privacy,
    );
    expect(old.title, 'Launcher stopped responding (19s)');
    expect(old.url.queryParameters['what'], endsWith('then recovered by itself.'));
    expect(old.url.queryParameters['thread'], 'Not sampled.');
    final crash = IssueDraft.launcherProblem(
      LauncherProblem(kind: LauncherProblemKind.crash, at: DateTime.utc(2026), version: '0.1.27', platform: 'Windows'),
      system: system,
      privacy: privacy,
    );
    expect(crash.url.queryParameters.containsKey('thread'), isFalse);
  });

  test('the headline tells a busy thread from a waiting one', () {
    expect(
      ThreadSampler.headline(sampledMs: 5400, cpuMs: 3950, windowMs: 4000),
      'Sampled 5 s into the freeze: busy on the CPU (3950 ms of CPU time in the 4.0 s before).',
    );
    expect(
      ThreadSampler.headline(sampledMs: 5000, cpuMs: 12, windowMs: 4250),
      'Sampled 5 s into the freeze: waiting, not on the CPU (12 ms of CPU time in the 4.2 s before).',
    );
    expect(ThreadSampler.headline(sampledMs: 5000), 'Sampled 5 s into the freeze.');
  });
}
