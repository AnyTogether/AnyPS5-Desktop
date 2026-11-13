import 'dart:io';

import 'package:anyps5_desktop/core/crash_report.dart';
import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/gamepad/pad_navigation.dart';
import 'package:anyps5_desktop/core/game_settings.dart';
import 'package:anyps5_desktop/core/installer.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/crash_model.dart';
import 'package:anyps5_desktop/ui/launcher.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_toolkit.dart';
import '../support/ui_support.dart';

const crashScript = '''
echo '[agc] Selected GPU name=Test GPU 9000 vendor=0x1 device=0x2 subgroup=32'
echo "FATAL: unhandled exception 0xc0000005 on thread 1 'GameMain'" >&2
echo '  rip app.exe+0x10006' >&2
exit 3''';

void main() {
  late Fixture fixture;
  late AppModel model;
  late List<String> suggested;
  String? saveTo;

  setUp(() {
    suggested = [];
    saveTo = null;
    fixture = makeFixture(
      saveFile: (name) async {
        suggested.add(name);
        return saveTo;
      },
    );
    model = fixture.model;
  });

  tearDown(() {
    T.language = Language.english;
    model.dispose();
    fixture.dispose();
  });

  Game orbit() => model.games.firstWhere((game) => game.titleId == 'PPSA01001');

  void gameScript(String body) {
    final installed = Installer.installedFolder(orbit(), model.root!);
    File(p.join(installed, 'app.elf')).writeAsStringSync('#!/bin/sh\n$body\n');
    Process.runSync('chmod', ['755', p.join(installed, 'app.elf')]);
  }

  String log() => File(model.paths.logFile('PPSA01001')).readAsStringSync();

  Future<void> until(bool Function() condition) async {
    for (var tries = 0; tries < 500 && !condition(); tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(condition(), isTrue);
  }

  List<String> rowIds() => model.panelCategories().single.rows.map((row) => row.id).toList();

  void choose(String id) => model.activateRow(rowIds().indexOf(id));

  group('after a crash', () {
    test('the crash report opens on why the game stopped', () async {
      model.select(model.games.indexOf(orbit()));
      gameScript(crashScript);
      await model.play(orbit());
      expect(model.overlay, Layer.crashReport);
      await model.crash.pending;
      final current = model.crash.current!;
      expect(current.afterCrash, isTrue);
      expect(current.report!.reason, 'The game crashed: access violation (0xC0000005)');
      expect(current.report!.exitCode, 3);
      expect(current.report!.systemInfo.gpu, 'Test GPU 9000');
      expect(current.tail.last, '--- exit 3');
      expect(rowIds(), ['save', 'copy', 'issue', 'log', 'playTraced', 'close']);
      expect(model.crash.reasonText(current), 'The game crashed (access violation (0xC0000005)).');
    }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);

    test('with online play on, the report carries the end of the game\'s online log', () async {
      model.preferences.onlinePlay = true;
      gameScript('echo \'{"v":1,"fn":"sceNpGetState","ret":0}\' >> "\$ANYPS5_ONLINE_LOG"\n$crashScript');
      await model.play(orbit());
      await model.crash.pending;
      final report = model.crash.current!.report!;
      expect(report.onlineLines, ['{"v":1,"fn":"sceNpGetState","ret":0}']);
      expect(report.text(), contains('Online play, the end of the game\'s online log (1 line):'));
      expect(model.together.online.running, isNull, reason: 'the bridge closed with the game');
    }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);

    test('Save crash_log.txt writes the report and the whole start where the user picks', () async {
      gameScript(crashScript);
      await model.play(orbit());
      await model.crash.pending;
      saveTo = p.join(fixture.temp.path, 'picked', 'crash_log.txt');
      Directory(p.dirname(saveTo!)).createSync();
      choose('save');
      await model.crash.pending;
      expect(suggested, ['crash_log.txt']);
      final text = File(saveTo!).readAsStringSync();
      expect(text, startsWith('AnyPS5 crash report, '));
      expect(text, contains('Game: Orbit Runner (PPSA01001)'));
      expect(text, contains('The log of this start'));
      expect(text, contains('  rip app.exe+0x10006'));
      expect(model.toast, 'Report saved: crash_log.txt');
    }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);

    test('a cancelled save writes nothing', () async {
      gameScript(crashScript);
      await model.play(orbit());
      await model.crash.pending;
      choose('save');
      await model.crash.pending;
      expect(suggested, hasLength(1));
      expect(model.toast, isNot(startsWith('Report saved')));
    }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);

    test('Copy puts the report with the end of the log on the clipboard', () async {
      gameScript(crashScript);
      await model.play(orbit());
      await model.crash.pending;
      choose('copy');
      expect(fixture.copied.single, contains('What happened: The game crashed: access violation (0xC0000005)'));
      expect(fixture.copied.single, contains('--- exit 3'));
      expect(model.toast, 'Report copied');
    }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);

    test('Open an issue shows what is shared, then opens the engine\'s pre-filled form', () async {
      gameScript(crashScript);
      await model.play(orbit());
      await model.crash.pending;
      choose('issue');
      expect(model.crash.current!.sharing, isTrue);
      expect(rowIds(), ['github', 'launcher', 'save', 'back']);
      expect(model.crash.current!.engineIssue!.preview, contains('Crash: Orbit Runner (PPSA01001)'));
      model.handle(Command.select);
      final engine = fixture.opened.last;
      expect(engine.path, '/boykopovar/AnyPS5/issues/new');
      expect(engine.queryParameters['template'], 'bug_report.yml');
      expect(engine.toString().length, lessThanOrEqualTo(IssueDraft.maximumLength));
      expect(model.toast, 'Issue page opened: attach crash_log.txt there');
      model
        ..handle(Command.down)
        ..handle(Command.select);
      expect(fixture.opened.last.path, '/AnyTogether/AnyPS5-Desktop/issues/new');
      // Back steps out of the shared text onto Open an issue; Back again closes.
      model.handle(Command.back);
      expect(model.crash.current!.sharing, isFalse);
      expect(rowIds()[model.panelRow], 'issue');
      model.handle(Command.back);
      expect(model.overlay, isNull);
    }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);

    test('moves with the keys and the pad like the other panels', () async {
      gameScript(crashScript);
      await model.play(orbit());
      await model.crash.pending;
      expect(model.panelRow, 0);
      model
        ..handle(Command.down)
        ..handle(Command.down);
      expect(rowIds()[model.panelRow], 'issue');
      model.padCommand(PadCommand.select);
      expect(model.crash.current!.sharing, isTrue);
      model.padCommand(PadCommand.back);
      expect(model.crash.current!.sharing, isFalse);
      model.padCommand(PadCommand.options);
      expect(model.overlay, isNull);
    }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);

    group('a dump without PlayGo chunk files', () {
      // Upstream's words when a title asks for a chunk ID and the dump has no playgo-chunk.dat and
      // no playgo-scenario.json (SILENT HILL: The Short Message on v0.1.4); the rule is the
      // message, not the title.
      const playGoCrash = '''
if [ "\$APS5_PLAYGO_UNLISTED_CHUNKS" = installed ]; then echo 'chunks counted as installed'; exit 0; fi
echo "terminate called after throwing an instance of 'std::runtime_error'" >&2
echo '  what():  scePlayGo: sce_sys/playgo-chunk.dat and sce_sys/playgo-scenario.json are missing, so chunk ID 1 cannot be checked; set APS5_PLAYGO_UNLISTED_CHUNKS=installed or =absent to answer for this dump' >&2
exit 3''';

      test('the engine\'s message is read whatever the title, the scenario one too', () {
        expect(
          SessionReport.playGoChunksUnknownIn(
            'what():  scePlayGo: sce_sys/playgo-chunk.dat and sce_sys/playgo-scenario.json are missing, so chunk ID 1 '
            'cannot be checked; set APS5_PLAYGO_UNLISTED_CHUNKS=installed or =absent to answer for this dump',
          ),
          isTrue,
        );
        expect(
          SessionReport.playGoChunksUnknownIn(
            'scePlayGo: sce_sys/playgo-chunk.dat is missing and sce_sys/playgo-scenario.json lists no chunks, so '
            'chunk ID 1200 outside the listed ids 0 to 999 cannot be checked; set APS5_PLAYGO_UNLISTED_CHUNKS=installed',
          ),
          isTrue,
        );
        expect(SessionReport.playGoChunksUnknownIn('scePlayGo: sce_sys/playgo-chunk.dat could not be read'), isFalse);
        expect(SessionReport.playGoChunksUnknownIn('FATAL: unhandled exception 0xc0000005'), isFalse);
      });

      test('the report offers AnyPS5-ARM\'s engine and a start with the chunks counted as installed', () async {
        gameScript(playGoCrash);
        await model.play(orbit());
        await model.crash.pending;
        expect(model.crash.current!.report!.playGoChunksUnknown, isTrue);
        expect(rowIds(), ['playGoArm', 'playGoInstalled', 'save', 'copy', 'issue', 'log', 'playTraced', 'close']);
        // Back from the shared text still lands on Open an issue.
        choose('issue');
        model.handle(Command.back);
        expect(rowIds()[model.panelRow], 'issue');
      }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);

      test('Play again with missing chunks counted as installed: that start only', () async {
        gameScript(playGoCrash);
        await model.play(orbit());
        await model.crash.pending;
        choose('playGoInstalled');
        expect(model.overlay, isNull);
        await until(
          () => model.running == null && model.starting == null && log().contains('chunks counted as installed'),
        );
        expect(log(), contains('[anyps5-launcher] this start only: APS5_PLAYGO_UNLISTED_CHUNKS=installed'));
        expect(model.overlay, isNull, reason: 'it ended well: no report');
        // The next start is as before.
        await model.play(orbit());
        await model.crash.pending;
        expect(model.overlay, Layer.crashReport);
        expect(model.crash.current!.report!.playGoChunksUnknown, isTrue);
      }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);

      test('Switch to the AnyPS5-ARM engine and play again: used, then the game unlocked with it', () async {
        makeFakeToolkit(p.join(model.engine.store.root, 'arm-5ca076a87'), version: 'arm-5ca076a87');
        model.engine.refresh();
        gameScript(playGoCrash);
        await model.play(orbit());
        await model.crash.pending;
        choose('playGoArm');
        await until(() => model.records[orbit().id]?.toolkit == 'arm-5ca076a87');
        expect(model.preferences.engineSource, 'arm');
        expect(model.toolkitVersion, 'arm-5ca076a87');
      }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);

      test('a game made with AnyPS5-ARM\'s engine is offered only the start with the chunks installed', () async {
        gameScript(playGoCrash);
        final installed = Installer.installedFolder(orbit(), model.root!);
        final record = File(p.join(installed, Installer.recordName));
        record.writeAsStringSync(
          record.readAsStringSync().replaceFirst(RegExp(r'"toolkit":"[^"]*"'), '"toolkit":"arm-5ca076a87"'),
        );
        model.rescan();
        expect(model.records[orbit().id]?.toolkit, 'arm-5ca076a87');
        // The copy as it is: this is about the engine it was made with, not about rebuilding it.
        await model.play(orbit(), asItIs: true);
        await model.crash.pending;
        expect(rowIds(), isNot(contains('playGoArm')));
        expect(rowIds().first, 'playGoInstalled');
      }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);
    });

    test('with another panel open, a toast says it instead', () async {
      gameScript('sleep 1\nexit 3');
      final playing = model.play(orbit());
      await until(() => model.running != null);
      model.open(Layer.settings);
      await playing;
      expect(model.overlay, Layer.settings);
      expect(model.toast, 'Orbit Runner: The game exited with status 3.');
    }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);
  });

  group('no report is offered', () {
    test('when the user closed the game', () async {
      gameScript('sleep 5');
      final playing = model.play(orbit());
      await until(() => model.running != null);
      model.stopGame();
      await playing;
      expect(model.overlay, isNull);
      expect(model.crash.lastSessions['PPSA01001']!.stoppedByUser, isTrue);
    }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);

    test('when the game closed normally', () async {
      gameScript('exit 0');
      await model.play(orbit());
      expect(model.overlay, isNull);
      expect(model.crash.lastSessions['PPSA01001']!.exitCode, 0);
    }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);
  });

  group('in the game\'s options', () {
    PanelRow row(String id) {
      model.select(model.games.indexOf(orbit()));
      model.open(Layer.gameSettings);
      return model.panelCategories().single.rows.firstWhere((row) => row.id == id);
    }

    test('the last session\'s report opens for the last start', () async {
      gameScript('echo hello\nexit 0');
      await model.play(orbit());
      expect(row('report').title, 'Last session\'s report');
      choose('report');
      expect(model.overlay, Layer.crashReport);
      await model.crash.pending;
      expect(model.crash.current!.afterCrash, isFalse);
      expect(model.crash.reasonText(model.crash.current!), 'No error found: the game closed normally.');
      expect(model.crash.current!.tail, contains('hello'));
    }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);

    test('Detailed Logging starts every start with the engine\'s trace switches', () async {
      expect((row('trace').kind as ToggleRow).value, isFalse);
      choose('trace');
      expect(model.currentSettings(orbit()).trace, isTrue);
      gameScript('env | grep ^APS5_ | sort');
      await model.play(orbit());
      expect(log(), contains('APS5_LOG_SYNC=1'));
      expect(log(), contains('APS5_TRACE_EXIT=1'));
      expect(RegExp(r'^--- \S+ \S+ trace$', multiLine: true).hasMatch(log()), isTrue);
    }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);

    test('Play with detailed logging traces one start, the setting left as it is', () async {
      gameScript('env | grep ^APS5_LOG_SYNC');
      row('playTraced');
      choose('playTraced');
      expect(model.overlay, isNull);
      await until(() => File(model.paths.logFile('PPSA01001')).existsSync() && log().contains('--- exit'));
      await until(() => model.running == null);
      expect(log(), contains('APS5_LOG_SYNC=1'));
      expect(model.currentSettings(orbit()).trace, isNull);
      expect(model.crash.lastSessions['PPSA01001']!.traced, isTrue);
    }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);
  });

  test('--trace on the launcher\'s command line traces every start of this run', () async {
    model.crash.traceAll = true;
    gameScript('env | grep ^APS5_LOG_SYNC');
    await model.play(orbit());
    expect(log(), contains('APS5_LOG_SYNC=1'));
    expect(model.currentSettings(orbit()).trace, isNull);
  }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);

  test('the launcher reads --trace from its arguments', () {
    expect(LaunchOptions.parse(['--trace']).trace, isTrue);
    expect(LaunchOptions.parse(const []).trace, isFalse);
  });

  group('looks', () {
    SessionReport sample({required GameSettings settings}) => SessionReport(
      gameName: 'Orbit Runner',
      titleId: 'PPSA01001',
      gameVersion: '01.000.002',
      settings: settings,
      system: const SystemInfo(
        os: 'Ubuntu 24.04.1 LTS, kernel 6.8.0-45-generic',
        cpu: 'AMD Ryzen 7 5800X',
        memoryGB: 32,
      ),
      launcherVersion: '0.1.4',
      platform: 'Linux',
      session: [
        '--- 2026-10-24T21:30:00.000 PPSA01001-app',
        '[agc] Selected GPU name=AMD Radeon RX 7800 XT (RADV NAVI32) vendor=0x1002 device=0x747e subgroup=64',
        '[kernel] loaded 14 modules',
        '[savedata] mount savedata0',
        '[agc] pipeline cache: 412 entries',
        '[libc] abort() called from 0x00000000004a1c2f',
        '--- exit -6',
      ].join('\n'),
      privacy: const ReportPrivacy(home: ''),
      created: DateTime(2026, 10, 24, 21, 31),
      exitCode: -6,
      unlockedWith: 'upstream-v0.1.3',
      engineNow: 'upstream-v0.1.3',
      started: DateTime(2026, 10, 24, 21, 30),
      ended: DateTime(2026, 10, 24, 21, 34, 12),
    );

    testWidgets('the crash report', (tester) async {
      model.select(model.games.indexOf(orbit()));
      model.crash.show(orbit(), sample(settings: const GameSettings()), afterCrash: true);
      await pumpLauncher(tester, model);
      await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/crash_report.png'));
    });

    testWidgets('what is shared, in Turkish', (tester) async {
      T.language = Language.byCode('tr');
      model.select(model.games.indexOf(orbit()));
      model.crash.show(orbit(), sample(settings: const GameSettings(trace: true)), afterCrash: true, sharing: true);
      await pumpLauncher(tester, model);
      expect(find.text('Paylaşılacaklar'), findsOneWidget);
      expect(find.text('GitHub\'da aç'), findsOneWidget);
      await press(tester, LogicalKeyboardKey.escape);
      expect(model.crash.current!.sharing, isFalse);
      expect(find.text('crash_log.txt olarak kaydet'), findsOneWidget);
    });
  });
}
