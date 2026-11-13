import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/crash_report.dart';
import 'package:anyps5_desktop/core/custom_options.dart';
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

/// A game's own options typed as text, as on the Mac: Custom relinker options (checked word by
/// word, passed after the launcher's own on the next rebuild) and Launch options (variables under
/// the launcher's, arguments for the game).
void main() {
  List<String> words(String text) {
    final split = splitOptionWords(text);
    expect(split.ok, isTrue, reason: '$text: ${split.problem}');
    return split.words;
  }

  OptionProblem? relinkerProblem(String text) => checkRelinkerOptions(text).problem;

  group('splitting', () {
    test('spaces, tabs and line breaks separate words, as many as there are', () {
      expect(words(''), isEmpty);
      expect(words('  \t\n\r '), isEmpty);
      expect(words('a b\tc\nd\r\ne'), ['a', 'b', 'c', 'd', 'e']);
      expect(words('  --lazy-binding   --registry  '), ['--lazy-binding', '--registry']);
    });

    test('single quotes keep everything as it is, up to the next one', () {
      expect(words(r"'a b' 'c\d' '\'"), ['a b', r'c\d', r'\']);
      expect(words("'say \"hi\"'"), ['say "hi"']);
    });

    test('double quotes take \\" and \\\\, and keep any other backslash', () {
      expect(words(r'"a b"'), ['a b']);
      expect(words(r'"a\"b"'), ['a"b']);
      expect(words(r'"a\\b"'), [r'a\b']);
      expect(words(r'"a\nb"'), [r'a\nb']);
      expect(words('"it\'s"'), ["it's"]);
    });

    test('outside quotes a backslash makes the next character plain; one at the end stays', () {
      expect(words(r'a\ b'), ['a b']);
      expect(words(r'\"x\"'), ['"x"']);
      expect(words(r'\\'), [r'\']);
      expect(words(r'end\'), [r'end\']);
    });

    test('a quoted part joins the word it touches; empty quotes alone are an empty word', () {
      expect(words('--a="b c"'), ['--a=b c']);
      expect(words("x'y'\"z\"w"), ['xyzw']);
      expect(words("'' \"\""), ['', '']);
      expect(words('a "" b'), ['a', '', 'b']);
    });

    test('a quote left open is the problem, wherever it is', () {
      for (final text in ["'a", '"a', 'a "b c', r'"a\"', "ok 'b"]) {
        expect(splitOptionWords(text).problem, const OptionProblem(OptionProblemKind.openQuote), reason: text);
      }
    });

    test('letters outside the basic plane pass through whole', () {
      expect(words(r'NAME=🎮 \🎮'), ['NAME=🎮', '🎮']);
    });
  });

  group('the relinker check', () {
    test('the options a player may add are passed, word by word', () {
      for (final option in RelinkerOptions.plain) {
        expect(checkRelinkerOptions(option).words, [option]);
      }
      expect(checkRelinkerOptions('--frame-red-zone --exclude-sce-module libSceNpToolkit.sprx unused-filter=2').words, [
        '--frame-red-zone',
        '--exclude-sce-module',
        'libSceNpToolkit.sprx',
        'unused-filter=2',
      ]);
      expect(checkRelinkerOptions('--windows-fixed-base "0x 1000"').words, ['--windows-fixed-base', '0x 1000']);
      expect(checkRelinkerOptions('   ').words, isEmpty);
    });

    test('the launcher keeps the system, the target and the paths', () {
      for (final option in RelinkerOptions.launcherOwned) {
        expect(relinkerProblem('--lazy-binding $option'), OptionProblem(OptionProblemKind.launcherOption, option));
      }
      expect(RelinkerOptions.launcherOwned, hasLength(11));
    });

    test('options that give no game, or a broken one, are refused', () {
      for (final option in RelinkerOptions.breaking) {
        expect(relinkerProblem(option), OptionProblem(OptionProblemKind.breaksGame, option));
      }
      expect(RelinkerOptions.breaking, hasLength(7));
    });

    test('--trace-imports has its own switch', () {
      expect(relinkerProblem('--trace-imports'), const OptionProblem(OptionProblemKind.hasSwitch, '--trace-imports'));
    });

    test('an option that takes a value needs one, not missing, empty or another option', () {
      for (final option in RelinkerOptions.withValue) {
        expect(relinkerProblem(option), OptionProblem(OptionProblemKind.needsValue, option));
        expect(relinkerProblem('$option ""'), OptionProblem(OptionProblemKind.needsValue, option));
        expect(relinkerProblem('$option --lazy-binding'), OptionProblem(OptionProblemKind.needsValue, option));
        expect(checkRelinkerOptions('$option value').ok, isTrue);
      }
      // The value is taken as it is, even one with a single dash.
      expect(checkRelinkerOptions('--exclude-sce-module -x').words, ['--exclude-sce-module', '-x']);
    });

    test('an option the relinker does not have is unknown', () {
      expect(relinkerProblem('--fast'), const OptionProblem(OptionProblemKind.unknown, '--fast'));
      expect(relinkerProblem('--lazy-binding=1'), const OptionProblem(OptionProblemKind.unknown, '--lazy-binding=1'));
    });

    test('unused-filter takes 0, 1 or 2; anything else under that name is unknown', () {
      for (final level in ['0', '1', '2']) {
        expect(checkRelinkerOptions('unused-filter=$level').ok, isTrue);
      }
      for (final word in ['unused-filter=3', 'unused-filter', 'unused-filter=', 'unused-filters=1']) {
        expect(relinkerProblem(word), OptionProblem(OptionProblemKind.unknown, word), reason: word);
      }
    });

    test('anything that is not an option is positional: files, --, -x, an empty word', () {
      for (final word in ['eboot.bin', '--', '-x', 'out/app.elf']) {
        expect(relinkerProblem('--registry $word'), OptionProblem(OptionProblemKind.positional, word), reason: word);
      }
      final empty = relinkerProblem('""')!;
      expect(empty, const OptionProblem(OptionProblemKind.positional));
      expect(empty.shown, '""');
    });

    test('the first problem from the left is the one said', () {
      expect(relinkerProblem('--fast --windows'), const OptionProblem(OptionProblemKind.unknown, '--fast'));
      expect(relinkerProblem('--windows --fast'), const OptionProblem(OptionProblemKind.launcherOption, '--windows'));
      expect(relinkerProblem("--fast 'open"), const OptionProblem(OptionProblemKind.openQuote));
    });
  });

  group('launch options', () {
    GameLaunchOptions parse(String text) {
      final (options, problem) = GameLaunchOptions.parse(text);
      expect(problem, isNull);
      return options!;
    }

    test('leading NAME=value words are variables, the rest arguments, in order', () {
      final options = parse('APS5_REPORT=0 EMPTY= _X1="a b" --aps5-report=off LATER=1 "two words"');
      expect(options.environment, {'APS5_REPORT': '0', 'EMPTY': '', '_X1': 'a b'});
      expect(options.environment.keys, ['APS5_REPORT', 'EMPTY', '_X1']);
      expect(options.arguments, ['--aps5-report=off', 'LATER=1', 'two words']);
      expect(options.text, 'APS5_REPORT=0 EMPTY= _X1="a b" --aps5-report=off LATER=1 "two words"');
    });

    test('the value is everything after the first =; a name is letters, digits and _', () {
      expect(parse('A=b=c').environment, {'A': 'b=c'});
      expect(parse('1A=b').arguments, ['1A=b']);
      expect(parse('A-B=c').arguments, ['A-B=c']);
      expect(parse('=x').arguments, ['=x']);
      expect(parse('"QUOTED=yes"').environment, {'QUOTED': 'yes'}, reason: 'after the quotes are taken off');
    });

    test('only a quote left open stops them', () {
      expect(GameLaunchOptions.parse('A=1 "b').$2, const OptionProblem(OptionProblemKind.openQuote));
      expect(parse('--windows eboot.bin').arguments, ['--windows', 'eboot.bin']);
    });

    test("the launcher's values win, and the names it kept are said, sorted", () {
      final options = parse('ZED=mine ANYPS5_LANGUAGE=99 MINE=1 APS5_REPORT=0');
      final (environment, overridden) = options.over({'ANYPS5_LANGUAGE': '1', 'ZED': 'launcher', 'OTHER': 'x'});
      expect(environment, {'ZED': 'launcher', 'ANYPS5_LANGUAGE': '1', 'MINE': '1', 'APS5_REPORT': '0', 'OTHER': 'x'});
      expect(overridden, ['ANYPS5_LANGUAGE', 'ZED']);
      expect(options.notes(overridden), [
        '[anyps5-launcher] launch options: ZED=mine ANYPS5_LANGUAGE=99 MINE=1 APS5_REPORT=0',
        "[anyps5-launcher] launch options: the launcher's own value is used for ANYPS5_LANGUAGE, ZED",
      ]);
      expect(options.notes(const []), [
        '[anyps5-launcher] launch options: ZED=mine ANYPS5_LANGUAGE=99 MINE=1 APS5_REPORT=0',
      ]);
    });
  });

  group('settings', () {
    test('both are saved as typed and read back; none leaves no key', () {
      const settings = GameSettings(
        customRelinkerOptions: '--exclude-sce-module "lib a.sprx"',
        launchOptions: 'APS5_REPORT=0 --aps5-report=off',
      );
      final json = jsonDecode(jsonEncode(settings.toJson())) as Map<String, dynamic>;
      expect(json['customRelinkerOptions'], '--exclude-sce-module "lib a.sprx"');
      expect(json['launchOptions'], 'APS5_REPORT=0 --aps5-report=off');
      final back = GameSettings.fromJson(json);
      expect(back, settings);
      expect(back.customRelinkerWords, ['--exclude-sce-module', 'lib a.sprx']);
      expect(back.launch!.environment, {'APS5_REPORT': '0'});
      expect(back.launch!.arguments, ['--aps5-report=off']);
      final none = const GameSettings().toJson();
      expect(none.containsKey('customRelinkerOptions'), isFalse);
      expect(none.containsKey('launchOptions'), isFalse);
      expect(const GameSettings().customRelinkerWords, isEmpty);
      expect(const GameSettings().launch, isNull);
    });

    test('a value of the wrong type, only spaces, or one that fails its check reads as none', () {
      GameSettings read(Object? relinker, Object? launch) =>
          GameSettings.fromJson({'customRelinkerOptions': relinker, 'launchOptions': launch});
      for (final (relinker, launch) in [
        (42, true),
        (['--lazy-binding'], ['A=1']),
        ('   ', '\n'),
        ('--windows', 'A="open'),
        ('eboot.bin', "'"),
        ('--trace-imports', '"'),
      ]) {
        final settings = read(relinker, launch);
        expect(settings.customRelinkerOptions, isNull, reason: '$relinker');
        expect(settings.launchOptions, isNull, reason: '$launch');
      }
    });

    test('words that fail the check never reach a rebuild, whatever built the settings', () {
      expect(const GameSettings(customRelinkerOptions: '--rpath /tmp').customRelinkerWords, isEmpty);
      expect(const GameSettings(launchOptions: 'A="open').launch, isNull);
    });
  });

  group('a rebuild', () {
    late Directory temp;
    late String root;
    late String toolkitFolder;

    setUp(() {
      temp = temporaryFolder('custom-options');
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

    Future<(String, List<String>)> unlock(Game game, List<String> custom, {List<RelinkerFlag> flags = const []}) async {
      final lines = <String>[];
      final installed = await Installer(
        game: game,
        toolkit: Toolkit(toolkitFolder),
        root: root,
        relinkerFlags: flags,
        customRelinkerOptions: custom,
        onLog: lines.add,
      ).run();
      return (installed, lines);
    }

    test("passes them after the launcher's options and before the two paths, and records them", () async {
      final game = makeGame();
      const custom = ['--frame-red-zone', '--exclude-sce-module', 'lib a.sprx'];
      final (installed, _) = await unlock(game, custom, flags: const [RelinkerFlag.traceImports]);
      final arguments = fakeRelinkerArguments(toolkitFolder).skip(1).toList(); // After the working directory.
      expect(arguments.first, '--trace-imports');
      final moduleDir = arguments.lastIndexOf('--module-dir');
      expect(moduleDir, greaterThan(0));
      expect(arguments.sublist(moduleDir + 2, arguments.length - 2), custom);
      expect(arguments[arguments.length - 2], 'eboot.bin');
      expect(arguments.last, endsWith(HostSystem.linux.executableName));
      final record = Installer.record(installed, system: HostSystem.linux)!;
      expect(record.customRelinkerOptions, custom);
      expect(record.relinkerFlags, ['--trace-imports']);
      final file = jsonDecode(File(p.join(installed, Installer.recordName)).readAsStringSync()) as Map<String, dynamic>;
      expect(file['customRelinkerOptions'], custom);
    });

    test('a record without them has no key, and reads as none', () async {
      final game = makeGame();
      final (installed, _) = await unlock(game, const []);
      final file = jsonDecode(File(p.join(installed, Installer.recordName)).readAsStringSync()) as Map<String, dynamic>;
      expect(file.containsKey('customRelinkerOptions'), isFalse);
      expect(Installer.record(installed, system: HostSystem.linux)!.customRelinkerOptions, isEmpty);
    });

    test('are part of the key: a change relinks, the same words reuse the kept output', () async {
      final game = makeGame();
      final kit = Toolkit(toolkitFolder);
      final found = Installer.modulesOf(game, kit.system);
      final none = Installer.relinkKey(game, kit, found, null);
      expect(
        Installer.relinkKey(game, kit, found, null, custom: const []),
        none,
        reason: 'no words, the key as it was',
      );
      final spaced = Installer.relinkKey(game, kit, found, null, custom: const ['--registry', 'a b']);
      expect(spaced, isNot(none));
      expect(Installer.relinkKey(game, kit, found, null, custom: const ['--registry', 'a', 'b']), isNot(spaced));

      await unlock(game, const []);
      await unlock(game, const ['--lazy-binding']);
      expect(fakeRelinkerRuns(toolkitFolder), hasLength(2));
      expect(fakeRelinkerRuns(toolkitFolder).last, contains('--lazy-binding'));
      await unlock(game, const ['--lazy-binding']);
      expect(fakeRelinkerRuns(toolkitFolder), hasLength(Installer.keepsOutput(root) ? 2 : 3));
    });

    test('a relinker that stops with them runs again without them, flags too, and says so', () async {
      makeFakeToolkit(toolkitFolder, traceImports: true, refuseOption: '--lazy-binding');
      final game = makeGame();
      final (installed, log) = await unlock(game, const ['--lazy-binding'], flags: const [RelinkerFlag.traceImports]);
      final runs = fakeRelinkerRuns(toolkitFolder);
      expect(runs.map((run) => run.contains('--lazy-binding')), [true, false]);
      expect(runs.last, isNot(contains('--trace-imports')));
      expect(File(p.join(installed, HostSystem.linux.executableName)).existsSync(), isTrue);
      final record = Installer.record(installed, system: HostSystem.linux)!;
      expect(record.customRelinkerOptions, isEmpty, reason: 'what it was really made with');
      expect(record.relinkerFlags, isEmpty);
      final said = log.singleWhere((line) => line.contains('the game is rebuilt without it'));
      expect(said, startsWith('PPSA01234: the relinker stopped with --trace-imports --lazy-binding ('));
      expect(said, endsWith('); the game is rebuilt without it'));
    });

    test('custom words alone are retried without them too', () async {
      makeFakeToolkit(toolkitFolder, refuseOption: '--registry');
      final game = makeGame();
      final (installed, log) = await unlock(game, const ['--registry']);
      expect(fakeRelinkerRuns(toolkitFolder).map((run) => run.contains('--registry')), [true, false]);
      expect(Installer.record(installed, system: HostSystem.linux)!.customRelinkerOptions, isEmpty);
      expect(log, contains(startsWith('PPSA01234: the relinker stopped with --registry (')));
    });
  });

  group('the report', () {
    test('the settings line and the session report say what is saved and what the game was built with', () {
      const settings = GameSettings(customRelinkerOptions: '--lazy-binding', launchOptions: 'APS5_REPORT=0');
      expect(const GameSettings().reportSummary, isNot(contains('Custom relinker options')));
      expect(const GameSettings().reportSummary, isNot(contains('Launch options')));
      expect(settings.reportSummary, contains('Custom relinker options --lazy-binding'));
      expect(settings.reportSummary, contains('Launch options APS5_REPORT=0'));
      SessionReport report(List<String> custom) => SessionReport(
        gameName: 'Orbit',
        titleId: 'PPSA01001',
        gameVersion: '1.0',
        settings: const GameSettings(),
        system: const SystemInfo(os: 'Linux'),
        launcherVersion: '0.1',
        platform: 'Linux',
        session: '',
        privacy: const ReportPrivacy(home: '/nowhere'),
        relinkerFlags: const ['--trace-imports'],
        customRelinkerOptions: custom,
      );
      expect(report(const []).text(), isNot(contains('Custom relinker options the game was unlocked with')));
      final text = report(const ['--exclude-sce-module', 'libA.sprx']).text();
      expect(text, contains('Custom relinker options the game was unlocked with: --exclude-sce-module libA.sprx'));
      expect(
        text.indexOf('Custom relinker options the game was unlocked with'),
        greaterThan(text.indexOf('Relinker flags the game was unlocked with')),
      );
    });
  });
}
