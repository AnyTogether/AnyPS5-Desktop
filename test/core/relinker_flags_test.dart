import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/crash_report.dart';
import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/game_settings.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/installer.dart';
import 'package:anyps5_desktop/core/relinker_flags.dart';
import 'package:anyps5_desktop/core/toolkit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_toolkit.dart';
import '../support/fixtures.dart';
import '../support/self_builder.dart';

/// The relinker options a player can choose for a game: which ones ever reach the relinker, that
/// a rebuild picks a change up past the kept output, and that a saved option never costs the game
/// its unlock on an engine that lacks it or a relinker that refuses it.
void main() {
  late Directory temp;
  late String root;
  late String toolkitFolder;

  setUp(() {
    temp = temporaryFolder('relinker-flags');
    root = p.join(temp.path, 'Games');
    toolkitFolder = makeFakeToolkit(p.join(temp.path, 'toolkit'), traceImports: true);
  });
  tearDown(() => temp.deleteSync(recursive: true));

  Game makeGame() {
    final folder = makeDump(root, 'Astro', titleId: 'PPSA01234', names: {'en-US': 'Astro Bot'}, eboot: const [0]);
    File(p.join(folder, 'eboot.bin')).writeAsBytesSync(typicalSelf());
    Directory(p.join(folder, 'sce_module')).createSync();
    File(p.join(folder, 'sce_module', 'libgame.sprx')).writeAsBytesSync(typicalSelf(seed: 2));
    return GameLibrary.inspect(folder)!;
  }

  Future<(String, List<String>)> unlock(Game game, List<RelinkerFlag> flags, {String? kit}) async {
    final lines = <String>[];
    final installed = await Installer(
      game: game,
      toolkit: Toolkit(kit ?? toolkitFolder),
      root: root,
      relinkerFlags: flags,
      onLog: lines.add,
    ).run();
    return (installed, lines);
  }

  group('the choice', () {
    test('only options the launcher knows are chosen, whatever a settings file says', () {
      const file = GameSettings(relinkerFlags: ['--windows', '--trace-imports', '--rpath', '/tmp/evil']);
      expect(file.chosenRelinkerFlags, [RelinkerFlag.traceImports]);
      final off = file.withRelinkerFlag(RelinkerFlag.traceImports, false);
      expect(off.relinkerFlags, isNull, reason: 'nothing chosen leaves nothing behind');
      expect(off.withRelinkerFlag(RelinkerFlag.traceImports, true).relinkerFlags, ['--trace-imports']);
    });

    test('is saved in the settings file; a file without it, or with something odd there, has none', () {
      const settings = GameSettings(relinkerFlags: ['--trace-imports']);
      expect(GameSettings.fromJson(jsonDecode(jsonEncode(settings.toJson())) as Map<String, dynamic>).relinkerFlags, [
        '--trace-imports',
      ]);
      expect(GameSettings.fromJson(const {}).relinkerFlags, isNull);
      expect(GameSettings.fromJson(const {'relinkerFlags': '--windows'}).chosenRelinkerFlags, isEmpty);
    });
  });

  group('which engines have it', () {
    test('its relinker has to know it and its libc.prx has to export what it needs', () {
      expect(Toolkit(toolkitFolder).supports(RelinkerFlag.traceImports), isTrue);
      final without = makeFakeToolkit(p.join(temp.path, 'without'));
      expect(Toolkit(without).supports(RelinkerFlag.traceImports), isFalse);
      final relinkerOnly = makeFakeToolkit(p.join(temp.path, 'relinker-only'), traceImports: true);
      File(p.join(relinkerOnly, 'libs', 'libc.prx')).writeAsStringSync('an old libc');
      expect(Toolkit(relinkerOnly).supports(RelinkerFlag.traceImports), isFalse, reason: 'the game would not load');
      final libcOnly = makeFakeToolkit(p.join(temp.path, 'libc-only'));
      File(p.join(libcOnly, 'libs', 'libc.prx')).writeAsStringSync('exports TraceImport_nid_no_patch');
      expect(Toolkit(libcOnly).supports(RelinkerFlag.traceImports), isFalse);
    });

    test('a match across two reads of a large file is found', () {
      final folder = makeFakeToolkit(p.join(temp.path, 'large'), traceImports: true);
      final relinker = File(p.join(folder, 'relinker'));
      final padding = '#'.padRight((1 << 20) - 8, '#');
      relinker.writeAsStringSync('$padding--trace-imports\n');
      expect(Toolkit(folder).supports(RelinkerFlag.traceImports), isTrue);
    });
  });

  group('a rebuild', () {
    test('passes the option to the relinker and records it, past the kept output when it changes', () async {
      final game = makeGame();
      var (installed, _) = await unlock(game, const []);
      expect(fakeRelinkerRuns(toolkitFolder).single, isNot(contains('--trace-imports')));
      expect(Installer.record(installed, system: HostSystem.linux)!.relinkerFlags, isEmpty);

      (installed, _) = await unlock(game, const [RelinkerFlag.traceImports]);
      expect(fakeRelinkerRuns(toolkitFolder), hasLength(2), reason: 'the kept output is not reused for another option');
      expect(fakeRelinkerRuns(toolkitFolder).last, startsWith('--trace-imports'));
      expect(Installer.record(installed, system: HostSystem.linux)!.relinkerFlags, ['--trace-imports']);

      (installed, _) = await unlock(game, const [RelinkerFlag.traceImports]);
      expect(
        fakeRelinkerRuns(toolkitFolder),
        hasLength(Installer.keepsOutput(root) ? 2 : 3),
        reason: 'the same option reuses it',
      );
      expect(Installer.record(installed, system: HostSystem.linux)!.relinkerFlags, ['--trace-imports']);
      expect(
        Installer.plan(game, root, toolkit: Toolkit(toolkitFolder)).space!.keptRelink,
        isNull,
        reason: 'kept for the option',
      );
    });

    test('keeps the key as it was when no option is chosen', () {
      final game = makeGame();
      final kit = Toolkit(toolkitFolder);
      final found = Installer.modulesOf(game, kit.system);
      final none = Installer.relinkKey(game, kit, found, null);
      expect(none.split('\n')[2], 'system linux ');
      expect(Installer.relinkKey(game, kit, found, null, flags: const [RelinkerFlag.traceImports]), isNot(none));
    });

    test('on an engine that lacks it: left out, said in the log, the game unlocked', () async {
      final without = makeFakeToolkit(p.join(temp.path, 'without'));
      final game = makeGame();
      final (installed, log) = await unlock(game, const [RelinkerFlag.traceImports], kit: without);
      expect(fakeRelinkerRuns(without).single, isNot(contains('--trace-imports')));
      expect(File(p.join(installed, 'app.elf')).existsSync(), isTrue);
      expect(Installer.record(installed, system: HostSystem.linux)!.relinkerFlags, isEmpty);
      expect(log, contains('PPSA01234: this engine does not support --trace-imports, the game is rebuilt without it'));
    });

    test('a relinker that refuses it runs again without it; the game is unlocked and says so', () async {
      makeFakeToolkit(toolkitFolder, traceImports: true, refuseTrace: true);
      final game = makeGame();
      final (installed, log) = await unlock(game, const [RelinkerFlag.traceImports]);
      expect(fakeRelinkerRuns(toolkitFolder).map((run) => run.contains('--trace-imports')), [true, false]);
      expect(File(p.join(installed, 'app.elf')).existsSync(), isTrue);
      expect(
        Installer.record(installed, system: HostSystem.linux)!.relinkerFlags,
        isEmpty,
        reason: 'what it was really made with',
      );
      expect(log.where((line) => line.contains('the game is rebuilt without it')), hasLength(1));
      // Filed under what it was made with: reused with no option, tried again with it.
      await unlock(game, const []);
      expect(fakeRelinkerRuns(toolkitFolder), hasLength(Installer.keepsOutput(root) ? 2 : 3));
    });

    test('a module the relinker cannot convert keeps the option, as a run without it would', () async {
      makeFakeToolkit(toolkitFolder, traceImports: true, failOn: 'sce_module/libgame.sprx');
      final game = makeGame();
      final (installed, _) = await unlock(game, const [RelinkerFlag.traceImports]);
      expect(fakeRelinkerRuns(toolkitFolder), everyElement(contains('--trace-imports')));
      expect(Installer.record(installed, system: HostSystem.linux)!.relinkerFlags, ['--trace-imports']);
    });

    test('a failure with the option and without it ends with the real failure', () async {
      makeFakeToolkit(toolkitFolder, traceImports: true, failOn: 'eboot.bin');
      final game = makeGame();
      await expectLater(unlock(game, const [RelinkerFlag.traceImports]), throwsA(isA<ToolFailed>()));
      expect(fakeRelinkerRuns(toolkitFolder).map((run) => run.contains('--trace-imports')), [true, false]);
    });
  });

  group('the report', () {
    test('lists what the game was built with and what is saved for the next rebuild', () {
      const settings = GameSettings(relinkerFlags: ['--trace-imports']);
      expect(const GameSettings().reportSummary, isNot(contains('Relinker flags')));
      expect(settings.reportSummary, contains('Relinker flags --trace-imports'));
      SessionReport report(List<String> flags) => SessionReport(
        gameName: 'Orbit',
        titleId: 'PPSA01001',
        gameVersion: '1.0',
        settings: const GameSettings(),
        system: const SystemInfo(os: 'Linux'),
        launcherVersion: '0.1',
        platform: 'Linux',
        session: '',
        privacy: const ReportPrivacy(home: '/nowhere'),
        relinkerFlags: flags,
      );
      expect(report(const []).text(), isNot(contains('Relinker flags the game was unlocked with')));
      expect(
        report(const ['--trace-imports']).text(),
        contains('Relinker flags the game was unlocked with: --trace-imports'),
      );
    });
  });
}
