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

    test('a window that never closes after Quit: exit after a few seconds, the marker gone first', () {
      fakeAsync((async) {
        final health = run(100)
          ..start()
          ..runnerRemovesMarker = true;
        final exits = <int>[];
        LauncherShutdown(health: health, closeWindow: () async => true, exit: exits.add).quit(0);
        async.elapse(const Duration(seconds: 4));
        expect(exits, isEmpty);
        async.elapse(LauncherShutdown.fallbackAfter);
        expect(exits, [0]);
        expect(File(p.join(folder, 'running-100.json')).existsSync(), isFalse);
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

  test('the watchdog\'s isolate writes a stall the interface never comes back from', () async {
    final health = run(100)..start();
    final watch = await StallWatch.start(health, started: DateTime.now());
    watch.ping(lines: ['frames 60 build 2.1/3.0/4.2 raster 3.0/4.1/6.0 | look cosmic layer home in front']);
    // The interface's isolate is stuck from here: no more pings.
    final problem = File(health.problemFile);
    for (var waited = 0; waited < 80 && !problem.existsSync(); waited++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final json = jsonDecode(problem.readAsStringSync()) as Map<String, dynamic>;
    final stall = LauncherProblem.fromJson(json);
    expect(stall.kind, LauncherProblemKind.hang);
    expect(stall.recovered, isFalse);
    expect(stall.lines.single, contains('layer home'));
    watch.ping();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final ended = LauncherProblem.fromJson(jsonDecode(problem.readAsStringSync()) as Map<String, dynamic>);
    expect(ended.recovered, isTrue);
    expect(ended.stalledFor!.inSeconds, greaterThanOrEqualTo(5));
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
}
