import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/managed_retro.dart';
import 'package:anyps5_desktop/core/retro_settings.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/home.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/ui_support.dart';

Directory _installFixtureCore(AppModel model, RetroPlatform platform) {
  final header = ByteData(96)
    ..setUint16(0, 0x5a4d, Endian.little)
    ..setUint32(60, 64, Endian.little)
    ..setUint32(64, 0x4550, Endian.little)
    ..setUint16(68, 0x8664, Endian.little)
    ..setUint16(86, 0x2000, Endian.little);
  final emulator = Directory(p.join(p.dirname(model.paths.toolkits), 'Emulators'))..createSync(recursive: true);
  File(p.join(emulator.path, ManagedRetro.libraryName(platform))).writeAsBytesSync(header.buffer.asUint8List());
  return emulator;
}

void main() {
  test('Windows onboarding can reach Home with no library or PS5 toolkit', () {
    final fixture = makeFixture(onboarded: false, withToolkit: false, system: HostSystem.windows);
    final model = fixture.model;
    addTearDown(() {
      model.dispose();
      fixture.dispose();
    });
    model.preferences.gamesFolders = [];
    model.onboardingStep = 2;
    model.handle(Command.right);
    model.handle(Command.select);
    expect(model.onboardingStep, 3);
    model.onboardingBack();
    expect(model.onboardingStep, 2);
    model.handle(Command.select);
    model.onboardingChoice = 2;
    model.handle(Command.select);
    expect(model.onboardingStep, 4);
    model.handle(Command.select);
    expect(model.preferences.onboarded, isTrue);
    expect(model.preferences.gamesFolders, isEmpty);
    expect(model.toolkit, isNull);
    expect(model.overlay, isNull);
    model.openSettingsCategory('emulators');
    expect(model.spot?.category, 'emulators');
  }, skip: Abi.current() != Abi.windowsX64);

  test('managed setup can finish with an empty or previously added games folder', () async {
    late Fixture fixture;
    String? selectedBios;
    final picks = <String>[];
    fixture = makeFixture(
      system: HostSystem.windows,
      pickFile: (title, _) async {
        picks.add(title);
        return selectedBios;
      },
      pickFolder: (title) async {
        picks.add(title);
        return fixture.temp.path;
      },
    );
    final model = fixture.model;
    addTearDown(() {
      model.dispose();
      fixture.dispose();
    });
    model.preferences.gamesFolders = [];
    final emulator = Directory(p.join(p.dirname(model.paths.toolkits), 'Emulators'));
    List<PanelRow> rows() => model.retroSettings.categories(RetroPlatform.ps1).first.rows;
    expect(rows().first.title, 'Install SwanStation (DuckStation-based)');
    expect(rows().any((row) => row.title == 'Finish setup'), isFalse);
    expect(rows().any((row) => row.id.endsWith('-games-folder')), isFalse);
    expect(emulator.existsSync(), isFalse);

    _installFixtureCore(model, RetroPlatform.ps1);
    expect(rows().map((row) => row.title), ['SwanStation (DuckStation-based)', 'BIOS selection']);
    await model.setupManagedRetro(RetroPlatform.ps1);
    expect(picks, ['Select your PS1 BIOS']);
    expect(rows().any((row) => row.id.endsWith('-games-folder')), isFalse);

    final bios = File(p.join(fixture.temp.path, 'ps1.bin'));
    final image = Uint8List(512 * 1024)..[0] = 1;
    await bios.writeAsBytes(image);
    selectedBios = bios.path;
    await model.setupManagedRetro(RetroPlatform.ps1);
    expect(model.managedRetroStatus(RetroPlatform.ps1).systemReady, isTrue);
    expect(model.preferences.gamesFolders, isEmpty);
    expect(rows().map((row) => row.title), [
      'SwanStation (DuckStation-based)',
      'BIOS selection',
      'PS1 games library folder',
      'Finish setup',
    ]);
    expect(rows()[1].detail, bios.path);
    final finish = rows().last;
    expect(finish.pinToBottom, isTrue);
    (rows()[2].kind as ActionRow).run();
    await Future<void>.delayed(Duration.zero);
    expect(picks.last, 'Choose your PS1 games folder');
    expect(model.preferences.gamesFolders, [fixture.temp.path]);
    await model.addGamesFolder(console: RetroPlatform.ps1);
    expect(model.preferences.gamesFolders, [fixture.temp.path]);
    expect(model.games.where((game) => game.retro?.platform == RetroPlatform.ps1), isEmpty);
    expect(rows()[2].detail, fixture.temp.path);
    expect(rows()[2].previewGames, isEmpty);
    final reloaded = Preferences.fromJson(model.preferences.toJson());
    expect(reloaded.retroSetupFolders['ps1'], fixture.temp.path);
    expect(reloaded.retroBiosSources['ps1'], bios.path);
    model.openSettingsCategory('emulators');
    model.panelCommand(Command.select);
    model.panelCommand(Command.select);
    expect(model.panelCategories().single.rows.any((row) => row.id == finish.id), isTrue);
    (finish.kind as ActionRow).run();
    expect(model.overlay, isNull);
    final game = Directory(p.join(fixture.temp.path, 'Example PS1 Game'))..createSync();
    File(p.join(game.path, 'disc.cue')).createSync();
    File(p.join(game.path, 'retro.json')).writeAsStringSync(
      jsonEncode({'platform': 'ps1', 'name': 'Example PS1 Game', 'titleId': 'SCUS99999', 'disc': 'disc.cue'}),
    );
    model.rescan();
    expect(rows()[2].previewGames.map((game) => game.name), ['Example PS1 Game']);
  }, skip: Abi.current() != Abi.windowsX64);

  testWidgets('PS2 Setup renders paths, covers, and the bottom action in order', (tester) async {
    final fixture = makeFixture(system: HostSystem.windows);
    final model = fixture.model;
    addTearDown(() {
      model.dispose();
      fixture.dispose();
    });
    final emulator = _installFixtureCore(model, RetroPlatform.ps2);
    final bios = File(p.join(emulator.path, 'system', 'pcsx2', 'bios', 'anyps5-imported.bin'));
    bios.parent.createSync(recursive: true);
    bios.writeAsBytesSync(Uint8List(4 * 1024 * 1024));
    final root = Directory(p.join(fixture.temp.path, 'PS2'))..createSync();
    final game = Directory(p.join(root.path, 'Example PS2 Game'))..createSync();
    File(p.join(game.path, 'disc.iso')).createSync();
    File(p.join(game.path, 'retro.json')).writeAsStringSync(
      jsonEncode({'platform': 'ps2', 'name': 'Example PS2 Game', 'titleId': 'SLUS99999', 'disc': 'disc.iso'}),
    );
    model.preferences.gamesFolders = [root.path];
    model.rescan();
    model.openSettingsCategory('emulators');
    model.panelRow = 1;
    model.panelCommand(Command.select);
    model.panelCommand(Command.select);
    await pumpLauncher(tester, model);
    final cover = find.byWidgetPredicate((widget) => widget is GameTile && widget.game.name == 'Example PS2 Game').last;
    final finish = find.text('Finish setup');
    expect(
      tester.getTopLeft(find.text('LRPS2 (PCSX2-based)')).dy,
      lessThan(tester.getTopLeft(find.text(bios.path)).dy),
    );
    expect(tester.getTopLeft(find.text(bios.path)).dy, lessThan(tester.getTopLeft(find.text(root.path)).dy));
    expect(tester.getTopLeft(find.text(root.path)).dy, lessThan(tester.getTopLeft(cover).dy));
    expect(tester.getTopLeft(finish).dy - tester.getBottomLeft(cover).dy, greaterThan(60));
  }, skip: Abi.current() != Abi.windowsX64);

  test('launcher settings contain one emulator section and Back restores the console row', () {
    final fixture = makeFixture(system: HostSystem.windows);
    final model = fixture.model;
    addTearDown(() {
      model.dispose();
      fixture.dispose();
    });

    model.open(Layer.settings);
    final settings = model.panelCategories();
    expect(settings.first.id, 'appearance');
    expect(settings.where((category) => category.id.startsWith('retro-')), isEmpty);
    final emulators = settings.singleWhere((category) => category.id == 'emulators');
    expect(emulators.rows.where((row) => row.id != 'emulators-show-folders').map((row) => row.title), [
      'PS1',
      'PS2',
      'PS3',
    ]);
    final folders = emulators.rows.singleWhere((row) => row.id == 'emulators-show-folders');
    expect(folders.title, 'Show as folders');
    expect((folders.kind as ToggleRow).value, isFalse);
    expect((folders.kind as ToggleRow).checkbox, isTrue);
    model.openSettingsCategory('emulators');
    model.panelRow = 2;
    model.panelCommand(Command.select);
    expect(model.panelCategories().single.title, contains('PS3'));
    expect(model.panelCategories().single.rows.map((row) => row.title), contains('Setup'));
    model.panelCommand(Command.back);
    expect(model.overlay, Layer.settings);
    expect(model.spot?.category, 'emulators');
    expect(model.spot?.row, emulators.rows[2].id);
  });

  test('a custom emulator setting remains reachable through Advanced and Settings search', () {
    final fixture = makeFixture(system: HostSystem.windows);
    final model = fixture.model;
    addTearDown(() {
      model.dispose();
      fixture.dispose();
    });
    final program = File(p.join(fixture.temp.path, 'emulator.exe'))..createSync();
    model.preferences.retroEmulators['ps2'] = program.path;
    final config = RetroSettings.configFile(program.path, RetroPlatform.ps2);
    config.parent.createSync(recursive: true);
    config.writeAsStringSync('[CustomSection]\nPrivateTuningKey = true\n');

    model.open(Layer.settings);
    model.setSettingsQuery('ps2 privatetuningkey');
    final match = model.panelCategories().single.rows.single;
    expect(match.title, 'PrivateTuningKey');
    expect(match.detail, contains('PS2 › Advanced › CustomSection'));
    (match.kind as ActionRow).run();
    expect(model.panelCategories().single.rows.single.kind, isA<ToggleRow>());
    expect(model.spot?.row, match.id);
    model.panelCommand(Command.back);
    expect(model.panelCategories().single.title, 'PS2 › Advanced');
    expect(model.spot?.row, 'retro-ps2-CustomSection');
    model.panelCommand(Command.back);
    expect(model.panelCategories().single.title, 'PS2');
    expect(model.spot?.row, 'emulator-group-advanced');
    model.panelCommand(Command.back);
    expect(model.spot?.row, 'emulators-ps2');
  });

  for (final platform in RetroPlatform.ps1AndPs2) {
    testWidgets('${platform.name} configures a fresh emulator and exposes its settings inside the app', (tester) async {
      late String selected;
      final fixture = makeFixture(pickFile: (_, _) async => selected);
      final model = fixture.model;
      addTearDown(() {
        model.dispose();
        fixture.dispose();
      });
      final program = File(p.join(fixture.temp.path, platform.name, 'emulator.exe'));
      program.parent.createSync();
      program.createSync();
      selected = program.path;
      final row = model.retroSettings.categories(platform).first.rows.first;
      (row.kind as ActionRow).run();
      final config = RetroSettings.configFile(program.path, platform);
      await tester.runAsync(() async {
        for (var i = 0; i < 100 && model.preferences.retroEmulators[platform.name] == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      expect(model.preferences.retroEmulators[platform.name], program.path);
      expect(File(p.join(program.parent.path, 'portable.txt')).existsSync(), isTrue);
      expect(RetroSettings.read(config).options.length, greaterThan(300));

      final categories = model.retroSettings.categories(platform);
      final add = categories.first.rows.firstWhere((row) => row.id.endsWith('-add')).kind as TextRow;
      add.set('EmuCore/CPU/Recompiler/TestSetting=true');
      add.submit!();
      expect(
        RetroSettings.read(config).options.any(
          (entry) => entry.section == 'EmuCore/CPU/Recompiler' && entry.key == 'TestSetting' && entry.value == 'true',
        ),
        isTrue,
      );
      if (platform == RetroPlatform.ps2) {
        final graphics = model.retroSettings
            .categories(platform)
            .singleWhere((panel) => panel.id == 'retro-ps2-graphics');
        final resolution = graphics.rows.singleWhere((row) => row.title == 'Internal Resolution').kind as ChoiceRow;
        resolution.set(resolution.options.indexOf('3× (~1080p)'));
        expect(RetroSettings.read(config).options.singleWhere((entry) => entry.key == 'upscale_multiplier').value, '3');
      }

      final oldText = config.readAsStringSync();
      (model.retroSettings.categories(platform).first.rows.first.kind as ActionRow).run();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      expect(config.readAsStringSync(), oldText);

      final folder = Directory(p.join(model.root!, 'Retro'))..createSync();
      File(p.join(folder.path, 'disc.${platform == RetroPlatform.ps1 ? 'cue' : 'iso'}')).createSync();
      File(p.join(folder.path, 'retro.json')).writeAsStringSync(
        jsonEncode({
          'platform': platform.name,
          'name': 'Test game',
          'titleId': 'TEST12345',
          'disc': 'disc.${platform == RetroPlatform.ps1 ? 'cue' : 'iso'}',
        }),
      );
      model.rescan();
      model.starting = model.games.singleWhere((game) => game.retro != null);
      final locked = model.retroSettings.categories(platform);
      expect(locked.map((category) => category.id), ['retro-${platform.name}', 'retro-${platform.name}-graphics']);
      expect(locked.first.rows.first.kind, isA<InfoRow>());
      expect(locked.first.rows.any((row) => row.id.endsWith('-bios')), isFalse);
      await tester.pump(const Duration(seconds: 5));
    });
  }
}
