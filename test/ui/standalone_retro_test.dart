import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/retro_folder_tile.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter/widgets.dart' show ValueKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_process.dart';
import '../support/ui_support.dart';

void _writePs3Title(String folder) {
  const key = 'TITLE_ID\x00';
  const value = 'BLUS01234\x00';
  const keyStart = 36;
  const valueStart = keyStart + key.length;
  final bytes = ByteData(valueStart + value.length)
    ..setUint32(0, 0x00505346)
    ..setUint32(8, keyStart, Endian.little)
    ..setUint32(12, valueStart, Endian.little)
    ..setUint32(16, 1, Endian.little)
    ..setUint16(22, 0x0204, Endian.little)
    ..setUint32(24, value.length, Endian.little);
  final data = bytes.buffer.asUint8List();
  data.setRange(keyStart, valueStart, key.codeUnits);
  data.setRange(valueStart, data.length, value.codeUnits);
  File(p.join(folder, 'PS3_GAME', 'PARAM.SFO')).writeAsBytesSync(data);
}

void main() {
  for (final (platform, relativeDisc) in [
    (RetroPlatform.ps1, 'Game disc.cue'),
    (RetroPlatform.ps2, 'Game disc.iso'),
    (RetroPlatform.ps3, 'PS3_DISC.SFB'),
  ]) {
    test('${platform.name} picks a local executable and launches the selected disc', () async {
      String? picked;
      final fixture = makeFixture(
        withToolkit: false,
        pickFile: (_, extensions) async {
          expect(extensions, isEmpty);
          return picked;
        },
      );
      final model = fixture.model;
      addTearDown(() {
        model.dispose();
        fixture.dispose();
      });
      final folder = Directory(p.join(model.root!, 'Retro Game'))..createSync();
      final disc = File(p.join(folder.path, relativeDisc))..createSync();
      var boot = disc;
      if (platform == RetroPlatform.ps3) {
        boot = File(p.join(folder.path, 'PS3_GAME', 'USRDIR', 'EBOOT.BIN'))..createSync(recursive: true);
        _writePs3Title(folder.path);
      } else {
        File(p.join(folder.path, 'retro.json')).writeAsStringSync(
          jsonEncode({'platform': platform.name, 'titleId': 'TEST12345', 'name': 'Retro game', 'disc': relativeDisc}),
        );
      }
      model.rescan();
      final game = model.games.singleWhere((game) => game.retro != null);
      expect(model.records, isNot(contains(game.id)));

      await model.chooseStandaloneEmulator(platform);
      expect(model.preferences.retroEmulators, isEmpty);
      picked = (File(p.join(fixture.temp.path, 'Local emulator.AppImage'))..createSync()).path;
      await model.chooseStandaloneEmulator(platform);
      expect(model.preferences.retroEmulators[platform.name], picked);

      final process = FakeGameProcess();
      addTearDown(process.quit);
      final run = runningFor(process);
      var launches = 0;
      model.startRetroGame = ({required installed, required program, required arguments, required logFile}) async {
        launches++;
        expect(program, picked);
        expect(installed, fixture.temp.path);
        expect(arguments, [
          if (platform == RetroPlatform.ps3) '--no-gui' else ...['-nogui', '--'],
          boot.path,
        ]);
        return run;
      };

      final play = model.play(game);
      await pumpEventQueue();
      expect(model.running, (game, run));
      expect(model.preferences.lastPlayed[game.id], isNotNull);
      expect(launches, 1);
      process.quit();
      await play;
      expect(model.running, isNull);

      boot.deleteSync();
      await model.play(game);
      expect(launches, 1);
    });
  }

  test('a failed native file picker leaves emulator preferences alone', () async {
    final fixture = makeFixture(pickFile: (_, _) async => throw PlatformException(code: 'picker-unavailable'));
    final model = fixture.model;
    addTearDown(() {
      model.dispose();
      fixture.dispose();
    });
    await model.chooseStandaloneEmulator(RetroPlatform.ps2);
    expect(model.preferences.retroEmulators, isEmpty);
    expect(model.toast, 'Could not open the emulator file picker');
  });

  testWidgets('a console folder groups games only when its emulator is configured', (tester) async {
    final fixture = makeFixture(system: HostSystem.windows);
    final model = fixture.model;
    addTearDown(() {
      model.dispose();
      fixture.dispose();
    });
    for (final name in ['Game A', 'Game B']) {
      final folder = Directory(p.join(model.root!, name))..createSync();
      File(p.join(folder.path, 'disc.iso')).createSync();
      File(p.join(folder.path, 'retro.json')).writeAsStringSync(
        jsonEncode({
          'platform': 'ps2',
          'titleId': name.replaceAll(' ', '').toUpperCase(),
          'name': name,
          'disc': 'disc.iso',
        }),
      );
    }
    model.rescan();
    model.setShowRetroFolders(true);
    expect(model.homeTiles.map((tile) => tile.folder), everyElement(isNull));

    final program = File(p.join(fixture.temp.path, 'pcsx2.exe'))..createSync();
    model.preferences.retroEmulators['ps2'] = program.path;
    expect(model.homeTiles.last.folder, RetroPlatform.ps2);
    model.selectHomeTile(model.homeTiles.length - 1);
    expect(model.homePreviewGame, isNull);
    expect(model.homeFolderTiles, hasLength(2));
    await pumpLauncher(tester, model);
    expect(find.byType(RetroFolderTile), findsOneWidget);
    expect(find.byKey(const ValueKey('retro-folder-games')), findsOneWidget);
    expect(find.text('Game A'), findsNothing, reason: 'the folder preview shows tiles without the first game title');
    model.handle(Command.options);
    expect(model.overlay, isNull);
    model.handle(Command.down);
    expect(model.homePreviewGame?.name, 'Game A');
    model.handle(Command.right);
    expect(model.homePreviewGame?.name, 'Game B');
    model.handle(Command.up);
    expect(model.selectedHomeFolder, RetroPlatform.ps2);
    await tester.pump(const Duration(seconds: 4)); // Finish the discovery toast timer.
  });
}
