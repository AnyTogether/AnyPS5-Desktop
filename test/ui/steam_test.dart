import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/installer.dart';
import 'package:anyps5_desktop/core/steam/steam_install.dart';
import 'package:anyps5_desktop/core/steam/steam_launch.dart';
import 'package:anyps5_desktop/core/steam/steam_shortcuts.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/launcher.dart';
import 'package:anyps5_desktop/ui/crash_model.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/ui_support.dart';

/// Settings › Steam over a made-up Steam folder: adding AnyPS5 (and its games), Steam open,
/// started from Steam, removing; and a game's shortcut starting the game.
void main() {
  late Fixture fixture;
  late AppModel model;
  late Directory proc;
  late String steamRoot;
  final quits = <int>[];
  const program = '/home/deck/Applications/AnyPS5-Desktop-x86_64.AppImage';

  void process(int pid, String name) => File(p.join(proc.path, '$pid', 'comm'))
    ..createSync(recursive: true)
    ..writeAsStringSync('$name\n');

  setUp(() {
    quits.clear();
    fixture = makeFixture(quit: quits.add);
    model = fixture.model;
    final home = p.join(fixture.temp.path, 'steamhome');
    steamRoot = p.join(home, '.local', 'share', 'Steam');
    Directory(p.join(steamRoot, 'userdata', '52079950', 'config')).createSync(recursive: true);
    proc = Directory(p.join(fixture.temp.path, 'proc'))..createSync();
    model.steam
      ..find = (() => SteamLocator.find(system: HostSystem.linux, environment: {'HOME': home}))
      ..control = ((install) => SteamControl(
        install,
        system: HostSystem.linux,
        procRoot: proc.path,
        start: (executable, arguments) async {
          // Steam quits when asked.
          for (final entry in proc.listSync()) {
            entry.deleteSync(recursive: true);
          }
        },
      ))
      ..program = (() => program)
      ..homeFolder = (() => Directory(home).resolveSymbolicLinksSync())
      ..launcherArt = (() async => {
        for (final kind in SteamArt.values) kind: Uint8List.fromList([1, kind.index]),
      })
      ..gameArt = ((game) async => {
        for (final kind in SteamArt.values) kind: Uint8List.fromList([2, kind.index]),
      });
  });

  tearDown(() {
    T.language = Language.english;
    model.dispose();
    fixture.dispose();
  });

  Future<void> until(bool Function() condition) async {
    for (var tries = 0; tries < 500 && !condition(); tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(condition(), isTrue);
  }

  PanelCategory steamCategory() => model.panelCategories().firstWhere((category) => category.id == 'steam');
  List<String> rowIds() => steamCategory().rows.map((row) => row.id).toList();
  PanelRow row(String id) => steamCategory().rows.firstWhere((row) => row.id == id);

  Future<void> openSteam() async {
    model.open(Layer.settings);
    model.panelCategory = model.panelCategories().indexWhere((category) => category.id == 'steam');
    rowIds();
    await until(() => !rowIds().contains('steamLooking'));
  }

  void choose(String id) => model.activateRow(rowIds().indexOf(id));

  SteamShortcuts shortcuts() =>
      SteamShortcuts(SteamInstall(Directory(steamRoot).resolveSymbolicLinksSync()), const SteamUser(id: '52079950'));

  testWidgets('golden: Settings › Steam with AnyPS5 added', (tester) async {
    await tester.runAsync(() async {
      model.steam.chooseAccount(0);
      await model.steam.scan();
      await model.steam.add();
    });
    // The "Added to Steam" toast runs on a real 4 s timer (it was made inside runAsync), so whether
    // it is still up when the golden is taken depends on the machine's speed. The golden is the page.
    model.toast = null;
    model.open(Layer.settings);
    model.selectCategory(model.panelCategories().indexWhere((category) => category.id == 'steam'));
    await pumpLauncher(tester, model);
    expect(find.text('Update in Steam'), findsOneWidget);
    expect(find.text('Remove from Steam'), findsOneWidget);
    await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/settings_steam.png'));
  });

  test('without Steam the category says so', () async {
    model.steam.find = () async => const [];
    await openSteam();
    expect(rowIds(), ['steamMissing', 'reset-steam']);
    expect(row('steamMissing').title, 'Not found on this PC');
  });

  test('Add to Steam writes AnyPS5 with its pictures; Update and Remove follow', () async {
    await openSteam();
    expect(rowIds(), [
      'steamWhere',
      'steamAccount',
      'steamInSteam',
      'steamGames',
      'steamFullscreen',
      'steamAdd',
      'reset-steam',
    ]);
    expect((row('steamInSteam').kind as InfoRow).text, 'Not added yet');
    choose('steamAdd');
    await until(() => model.steam.inSteam == 1);
    final ours = shortcuts().ours();
    expect(ours.single.string('AppName'), 'AnyPS5');
    expect(ours.single.string('LaunchOptions'), '--steam --fullscreen');
    expect(ours.single.string('Exe'), '"$program"');
    final appId = ShortcutsFile.appIdOf(ours.single);
    for (final kind in SteamArt.values) {
      expect(File(shortcuts().artPath(appId, kind)).readAsBytesSync(), [1, kind.index]);
    }
    expect(model.toast, 'Added to Steam: AnyPS5. Open Steam to find it in the AnyPS5 collection.');
    expect(rowIds(), containsAllInOrder(['steamAdd', 'steamRemove']));
    expect(row('steamAdd').title, 'Update in Steam');
    choose('steamRemove');
    await until(() => model.steam.inSteam == 0);
    expect(shortcuts().ours(), isEmpty);
    expect(File(shortcuts().artPath(appId, SteamArt.hero)).existsSync(), isFalse);
    expect(model.toast, 'AnyPS5 is no longer in Steam');
  });

  test('games on: every unlocked game gets its own shortcut starting it with --play', () async {
    await openSteam();
    choose('steamGames');
    expect(model.preferences.steamGames, isTrue);
    choose('steamFullscreen');
    expect(model.preferences.steamFullscreen, isFalse);
    choose('steamAdd');
    await until(() => model.steam.inSteam == 2);
    final ours = shortcuts().ours();
    // Orbit Runner is the fixture's only unlocked game.
    expect(ours.map((entry) => entry.string('AppName')), ['AnyPS5', 'Orbit Runner']);
    expect(ours.last.string('LaunchOptions'), '--steam --play PPSA01001');
    expect((row('steamInSteam').kind as InfoRow).text, 'AnyPS5 and 1 games');
    expect(model.toast, contains('AnyPS5 and 1 games'));
    // Games off again: their entry goes at the next update.
    choose('steamGames');
    choose('steamAdd');
    await until(() => model.steam.inSteam == 1);
  });

  test('with Steam open it offers to close it, then adds and offers to open it again', () async {
    process(900, 'steam');
    await openSteam();
    choose('steamAdd');
    await until(() => model.steam.waiting != null);
    expect(rowIds(), containsAllInOrder(['steamRunning', 'steamClose', 'steamCancel']));
    expect(row('steamClose').title, 'Close Steam and add');
    expect(shortcuts().ours(), isEmpty, reason: 'nothing is written while Steam runs');
    choose('steamCancel');
    expect(model.steam.waiting, isNull);
    choose('steamAdd');
    await until(() => model.steam.waiting != null);
    choose('steamClose');
    await until(() => model.steam.inSteam == 1);
    expect(proc.listSync(), isEmpty);
    expect(rowIds(), contains('steamOpen'));
    choose('steamOpen');
    expect(fixture.opened.last, Uri.parse('steam://open/games'));
    expect(rowIds(), isNot(contains('steamOpen')));
  });

  test('started from Steam it never closes Steam (that would close the launcher)', () async {
    model.steamLaunch = SteamLaunch.detect(const ['--steam'], const {'SteamGameId': '1'});
    process(900, 'steam');
    await openSteam();
    choose('steamAdd');
    await until(() => model.toast != null);
    expect(model.toast, contains('started from Steam'));
    expect(model.steam.waiting, isNull);
    expect(shortcuts().ours(), isEmpty);
  });

  test('several accounts: the one signed in last first, the choice kept', () async {
    Directory(p.join(steamRoot, 'userdata', '22202', 'config')).createSync(recursive: true);
    File(p.join(steamRoot, 'config', 'loginusers.vdf'))
      ..createSync(recursive: true)
      ..writeAsStringSync('''
"users"
{
	"76561198012345678" { "PersonaName" "Siler" "MostRecent" "1" }
	"76561197960287930" { "PersonaName" "Gabe" "MostRecent" "0" }
}''');
    await openSteam();
    final choice = row('steamAccount').kind as ChoiceRow;
    expect(choice.options, ['Siler', 'Gabe']);
    expect(choice.selected, 0);
    choice.set(1);
    expect(model.preferences.steamUser, endsWith('|22202'));
    expect((row('steamAccount').kind as ChoiceRow).selected, 1);
  });

  test('Turkish', () async {
    T.language = Language.byCode('tr');
    await openSteam();
    expect(row('steamAdd').title, "Steam'e ekle");
    expect(row('steamGames').title, 'Oyunlarımı da ekle');
  });

  group('a game\'s shortcut', () {
    Game orbit() => model.games.firstWhere((game) => game.titleId == 'PPSA01001');

    test('the arguments', () {
      final options = LaunchOptions.parse(['--steam', '--fullscreen', '--play', 'PPSA01001']);
      expect(options.steam, isTrue);
      expect(options.fullscreen, isTrue);
      expect(options.play, 'PPSA01001');
      expect(LaunchOptions.parse(['--play']).play, isNull);
      expect(LaunchOptions.parse(['--play', '--steam']).play, isNull);
    });

    test('a game not there or still locked is said, nothing starts', () async {
      await model.playAtLaunch('PPSA09999', quitAfter: true);
      expect(model.toast, 'Steam asked for PPSA09999, which is not in your games folder');
      await model.playAtLaunch('ppsa02002', quitAfter: true);
      expect(model.toast, 'Neon Alley is not unlocked yet: unlock it, then start it from Steam again');
      expect(model.selectedGame!.titleId, 'PPSA02002');
      expect(model.running, isNull);
      expect(quits, isEmpty);
    });

    test('an unlocked one starts, and the launcher goes when it ends well', () async {
      final installed = Installer.installedFolder(orbit(), model.root!);
      File(p.join(installed, 'app.elf')).writeAsStringSync('#!/bin/sh\nexit 0\n');
      Process.runSync('chmod', ['755', p.join(installed, 'app.elf')]);
      await model.playAtLaunch('PPSA01001', quitAfter: true);
      expect(quits, [0]);
    }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);

    test('a crash keeps the launcher open on its report', () async {
      final installed = Installer.installedFolder(orbit(), model.root!);
      File(p.join(installed, 'app.elf')).writeAsStringSync('#!/bin/sh\nexit 3\n');
      Process.runSync('chmod', ['755', p.join(installed, 'app.elf')]);
      await model.playAtLaunch('PPSA01001', quitAfter: true);
      expect(quits, isEmpty);
      expect(model.overlay, Layer.crashReport);
    }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);
  });
}
