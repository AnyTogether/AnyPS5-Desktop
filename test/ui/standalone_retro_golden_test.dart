import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/launcher.dart';
import 'package:anyps5_desktop/ui/retro_folder_tile.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/ui_support.dart';

/// The emulator games as they look: the switch that turns them on, Settings › Emulators, a game
/// whose emulator is not picked yet, and a console's folder on the home screen.
void main() {
  late Fixture fixture;
  final shell = find.byType(LauncherShell);

  tearDown(() {
    T.language = Language.english;
    fixture.dispose();
  });

  AppModel withDiscs() {
    fixture = makeFixture();
    final model = fixture.model;
    for (final (folder, titleId, name) in [
      ('chrome', 'SLUS20001', 'Chrome Circuit'),
      ('harbor', 'SLUS20002', 'Harbor Lights'),
    ]) {
      final game = Directory(p.join(model.root!, folder))..createSync();
      File(p.join(game.path, 'disc.iso')).createSync();
      File(p.join(game.path, 'retro.json')).writeAsStringSync(
        jsonEncode({'platform': 'ps2', 'titleId': titleId, 'name': name, 'disc': 'disc.iso'}),
      );
    }
    model.setRetroLibrary(true);
    return model;
  }

  testWidgets('settings searched for the switch, off as it starts', (tester) async {
    fixture = makeFixture();
    final model = fixture.model..open(Layer.settings);
    model.setSettingsQuery('emulator');
    await pumpLauncher(tester, model);
    expect(find.text('Emulator games'), findsOneWidget);
    await expectLater(shell, matchesGoldenFile('goldens/settings_emulator_games_en.png'));
  });

  testWidgets('settings: Emulators, shown once Emulator games is on', (tester) async {
    final model = withDiscs()..open(Layer.settings);
    model.selectCategory(model.panelCategories().indexWhere((category) => category.id == 'emulators'));
    await pumpLauncher(tester, model);
    expect(find.text('PCSX2'), findsOneWidget);
    expect(find.text('Show as folders'), findsOneWidget);
    await expectLater(shell, matchesGoldenFile('goldens/settings_emulators_en.png'));
  });

  testWidgets('home: a PS2 game whose emulator is not picked yet', (tester) async {
    final model = withDiscs();
    model.select(model.games.indexWhere((game) => game.name == 'Chrome Circuit'));
    await pumpLauncher(tester, model);
    expect(find.text('Emulator required'), findsWidgets);
    expect(find.text('Choose emulator'), findsOneWidget);
    await expectLater(shell, matchesGoldenFile('goldens/home_emulator_required_en.png'));
  });

  testWidgets('home: the PS2 folder selected, its games under it', (tester) async {
    final model = withDiscs();
    model.preferences.retroEmulators['ps2'] = (File(p.join(fixture.temp.path, 'pcsx2'))..createSync()).path;
    model.setShowRetroFolders(true);
    model.selectHomeTile(model.homeTiles.indexWhere((tile) => tile.folder == RetroPlatform.ps2));
    await pumpLauncher(tester, model);
    expect(find.byType(RetroFolderTile), findsOneWidget);
    expect(find.text('PS2 games'), findsOneWidget);
    await expectLater(shell, matchesGoldenFile('goldens/home_retro_folder_en.png'));
  });
}
