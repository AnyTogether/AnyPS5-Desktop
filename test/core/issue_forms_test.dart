import 'dart:io';

import 'package:anyps5_desktop/core/crash_report.dart';
import 'package:anyps5_desktop/core/game_settings.dart';
import 'package:anyps5_desktop/core/launcher_health.dart';
import 'package:test/test.dart';

/// The issue forms in .github/ISSUE_TEMPLATE and the links the launcher fills them with: every
/// field it fills is one of the form's, and the box the user writes in is never one of them (a
/// field filled from the link is put back by GitHub over what was typed in it).
void main() {
  /// The form's fields by id: their type and whether they are rendered as code.
  Map<String, ({String type, bool render, bool required})> fields(String template) {
    final lines = File('.github/ISSUE_TEMPLATE/$template').readAsLinesSync();
    final found = <String, ({String type, bool render, bool required})>{};
    String? type;
    String? id;
    var render = false;
    var required = false;
    void close() {
      if (type != null && id != null) found[id] = (type: type, render: render, required: required);
    }

    for (final line in lines) {
      final item = RegExp(r'^  - type: (\w+)').firstMatch(line);
      if (item != null) {
        close();
        type = item[1];
        id = null;
        render = false;
        required = false;
        continue;
      }
      id = RegExp(r'^    id: (\w+)').firstMatch(line)?[1] ?? id;
      if (RegExp(r'^      render: ').hasMatch(line)) render = true;
      if (RegExp(r'^      required: true').hasMatch(line)) required = true;
    }
    close();
    return found;
  }

  Set<String> filled(IssueDraft draft) => {...draft.url.queryParameters.keys}..removeAll(['template', 'title']);

  final report = SessionReport(
    gameName: 'Orbit Runner',
    titleId: 'PPSA01001',
    gameVersion: '01.000.002',
    settings: const GameSettings(),
    system: const SystemInfo(os: 'Windows 11 Home 25H2 (Build 26200.6899)'),
    launcherVersion: '0.1.14',
    platform: 'Windows',
    session: '--- 2026-10-30T01:20:00.000 PPSA01001-app\n--- exit 1',
    privacy: const ReportPrivacy(home: r'C:\Users\ada', names: ['ada']),
    exitCode: 1,
  );

  final problem = LauncherProblem(
    kind: LauncherProblemKind.hang,
    at: DateTime.utc(2026, 10, 30, 1, 21, 26),
    version: '0.1.14',
    platform: 'Windows',
    stalledFor: const Duration(seconds: 15),
    recovered: true,
    lines: ['2026-10-30T04:21:00.203748 frames 0 build - raster - | look aurora layer home in front'],
  );

  for (final (template, draft) in [
    ('crash.yml', IssueDraft.launcher(report)),
    (
      'launcher_crash.yml',
      IssueDraft.launcherProblem(
        problem,
        system: const SystemInfo(os: 'Windows 11 Home 25H2 (Build 26200.6899)'),
        privacy: const ReportPrivacy(home: r'C:\Users\ada', names: ['ada']),
      ),
    ),
  ]) {
    test('$template: the launcher fills only its own fields, and leaves What You Were Doing to the user', () {
      final form = fields(template);
      expect(filled(draft).difference(form.keys.toSet()), isEmpty, reason: 'every filled field is on the form');
      final doing = form['doing'];
      expect(doing, isNotNull, reason: 'a box of the user\'s own');
      expect(doing!.type, 'textarea');
      expect(doing.render, isFalse, reason: 'a code block is no place to write in');
      expect(doing.required, isTrue);
      expect(filled(draft), isNot(contains('doing')));
      for (final id in filled(draft)) {
        expect(
          form[id]!.required && form[id]!.type == 'textarea' && !form[id]!.render,
          isFalse,
          reason: '$id is filled by the launcher: no box the form asks the user to write in',
        );
      }
    });
  }

  test('the launcher\'s own problem: what it noticed, without a line for the user to finish', () {
    final draft = IssueDraft.launcherProblem(
      problem,
      system: const SystemInfo(os: 'Windows 11 Home 25H2 (Build 26200.6899)'),
      privacy: const ReportPrivacy(home: r'C:\Users\ada', names: ['ada']),
    );
    expect(
      draft.url.queryParameters['what'],
      'The interface did not answer for 15 s from 2026-10-30 01:21:26 UTC, then recovered by itself.',
    );
    expect(draft.url.queryParameters['system'], 'Windows 11 Home 25H2 (Build 26200.6899)');
    expect(draft.linesLeftOut, 0);
  });

  test('a link too long for GitHub leaves the oldest lines out and says the whole report is on the clipboard', () {
    final long = LauncherProblem(
      kind: LauncherProblemKind.crash,
      at: DateTime.utc(2026, 10, 30, 1, 21),
      version: '0.1.14',
      platform: 'Windows',
      lines: [for (var second = 0; second < 30; second++) 'line $second ${'x' * 280}'],
    );
    final draft = IssueDraft.launcherProblem(
      long,
      system: const SystemInfo(os: 'Windows 11 Home 25H2 (Build 26200.6899)'),
      privacy: const ReportPrivacy(home: r'C:\Users\ada', names: ['ada']),
    );
    expect(draft.url.toString().length, lessThanOrEqualTo(IssueDraft.maximumLength));
    expect(draft.linesLeftOut, greaterThan(0));
    final log = draft.url.queryParameters['log']!;
    expect(log, contains('line 29 '));
    expect(log, isNot(contains('line 0 ')));
    expect(log, contains('${draft.linesLeftOut} older lines left out'));
    expect(log, contains('clipboard'));
    final whole = IssueDraft.launcherProblemText(
      long,
      system: const SystemInfo(os: 'Windows 11 Home 25H2 (Build 26200.6899)'),
      privacy: const ReportPrivacy(home: r'C:\Users\ada', names: ['ada']),
    );
    expect(whole, contains('line 0 '));
    expect(whole, contains('line 29 '));
  });

  test('a crash while closing is said as one', () {
    final draft = IssueDraft.launcherProblem(
      LauncherProblem(
        kind: LauncherProblemKind.crash,
        at: DateTime.utc(2026, 10, 30, 1, 5),
        version: '0.1.14',
        platform: 'Windows',
        whileClosing: true,
      ),
      system: const SystemInfo(os: 'Windows 11 Home 25H2 (Build 26200.6899)'),
      privacy: const ReportPrivacy(home: r'C:\Users\ada', names: ['ada']),
    );
    expect(draft.title, 'Launcher crash while closing');
    expect(draft.url.queryParameters['what'], contains('crashed while closing'));
    expect(draft.url.queryParameters['what'], contains('2026-10-30 01:05:00 UTC'));
  });
}
