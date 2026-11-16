import 'package:anyps5_desktop/core/launcher_health.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:anyps5_desktop/ui/theme.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_process.dart';
import '../support/ui_support.dart';

/// The launcher's own crash or long stall, offered at the next start: Send Report opens the
/// pre-filled GitHub issue in one step, nothing is sent without it.
void main() {
  tearDown(() {
    T.language = Language.english;
    Motion.reduced = false;
  });

  LauncherProblem crash() => LauncherProblem(
    kind: LauncherProblemKind.crash,
    at: DateTime.utc(2026, 10, 28, 20, 5),
    version: '0.1.12',
    platform: 'Linux',
    error: 'Bad state: No element\n#0 HomeView.build (file:///home/ada/AnyPS5/lib/ui/home.dart:120)',
    lines: ['2026-10-28T20:04:59 frames 58 build 3.1/4.0/9.2 raster 2.0/2.9/4.4 | look cosmic layer home in front'],
  );

  testWidgets('after a crash the next start offers Send Report, which opens the issue at once', (tester) async {
    final fixture = makeFixture();
    addTearDown(fixture.dispose);
    final model = fixture.model;
    var done = 0;
    model
      ..launcherProblem = crash()
      ..onLauncherProblemDone = () => done++;
    model.offerLauncherReport();
    await pumpLauncher(tester, model);
    expect(model.overlay, Layer.launcherReport);
    expect(find.text('AnyPS5 closed unexpectedly'), findsOneWidget);
    expect(model.panelCategories().single.rows.map((row) => row.id), ['sendReport', 'notNow']);
    expect(fixture.opened, isEmpty, reason: 'nothing leaves before the user asks');

    await press(tester, LogicalKeyboardKey.enter);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    expect(model.overlay, isNull);
    expect(done, 1, reason: 'not offered again');
    final issue = fixture.opened.single;
    expect(issue.host, 'github.com');
    expect(issue.path, '/AnyTogether/AnyPS5-Desktop/issues/new');
    expect(issue.queryParameters['template'], 'launcher_crash.yml');
    expect(issue.queryParameters['versions'], 'Launcher 0.1.12 (Linux)');
    expect(issue.queryParameters['error'], contains('HomeView.build'));
    expect(issue.queryParameters['error'], isNot(contains('ada')), reason: 'the user\'s folder is taken out');
    expect(issue.queryParameters['log'], contains('layer home'));
    model.offerLauncherReport();
    expect(model.overlay, isNull);
  });

  testWidgets('a stall says how long; Not Now puts it aside; nothing is offered over a screen the user opened', (
    tester,
  ) async {
    final fixture = makeFixture();
    addTearDown(fixture.dispose);
    final model = fixture.model;
    var done = 0;
    model
      ..launcherProblem = LauncherProblem(
        kind: LauncherProblemKind.hang,
        at: DateTime.utc(2026, 10, 28, 20),
        version: '0.1.12',
        platform: 'Windows',
        stalledFor: const Duration(seconds: 12),
        recovered: true,
      )
      ..onLauncherProblemDone = () => done++;
    model.open(Layer.settings);
    await pumpLauncher(tester, model);
    expect(model.overlay, Layer.settings, reason: 'not over what the user opened');
    await press(tester, LogicalKeyboardKey.escape);
    expect(model.overlay, Layer.launcherReport, reason: 'once the home screen is free');
    expect(find.text('AnyPS5 froze for 12 seconds'), findsOneWidget);
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.enter);
    expect(model.overlay, isNull);
    expect(done, 1);
    expect(fixture.opened, isEmpty);
  });

  testWidgets('a report too long for the link: the whole of it goes to the clipboard, and the launcher says so', (
    tester,
  ) async {
    final fixture = makeFixture();
    addTearDown(fixture.dispose);
    final model = fixture.model;
    model.launcherProblem = LauncherProblem(
      kind: LauncherProblemKind.crash,
      at: DateTime.utc(2026, 10, 30, 1, 21),
      version: '0.1.14',
      platform: 'Windows',
      lines: [for (var second = 0; second < 30; second++) 'line $second ${'x' * 280}'],
    );
    model.offerLauncherReport();
    await pumpLauncher(tester, model);
    await press(tester, LogicalKeyboardKey.enter);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    expect(fixture.opened.single.queryParameters['log'], contains('older lines left out'));
    expect(fixture.copied.single, contains('line 0 '), reason: 'every line, the oldest too');
    expect(find.textContaining('the whole of it is on the clipboard'), findsOneWidget);
    // The toast's own time.
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the line a second says which game is starting or playing, for a stall\'s last seconds', (tester) async {
    final fixture = makeFixture();
    addTearDown(fixture.dispose);
    final model = fixture.model;
    final game = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
    // The frames line of the last second (window and media lines come between them too).
    String lastSecond() => model.recentLines.lastWhere((line) => line.contains(' frames '));
    await pumpLauncher(tester, model);
    final added = model.recentLinesAdded;
    model.starting = game;
    await tester.pump(const Duration(seconds: 1));
    expect(model.recentLinesAdded, greaterThan(added), reason: 'a line each second');
    expect(lastSecond(), contains(' starting PPSA01001 '));
    model
      ..starting = null
      ..running = (game, runningFor(FakeGameProcess()));
    await tester.pump(const Duration(seconds: 1));
    expect(lastSecond(), contains(' playing PPSA01001 '));
    expect(lastSecond(), isNot(contains('starting')));
    model.running = null;
    await tester.pump(const Duration(seconds: 1));
    expect(lastSecond(), isNot(contains('PPSA01001')), reason: 'back on the home screen');
  });
}
