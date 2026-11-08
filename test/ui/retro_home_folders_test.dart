import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/gamepad/pad_navigation.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/managed_retro.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/background.dart';
import 'package:anyps5_desktop/ui/retro_folder_tile.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart' show Icons;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/ui_support.dart';

Game _game(String name, {RetroPlatform? platform, String? background}) => Game(
  folder: name,
  titleId: name,
  name: name,
  names: const {},
  defaultLanguage: 'en',
  version: '',
  background: background,
  executable: platform == null ? ExecutableKind.elf : ExecutableKind.disc,
  retro: platform == null ? null : (platform: platform, path: name),
);

void _installFixtureCore(AppModel model, RetroPlatform platform) {
  final image = ByteData(96)
    ..setUint16(0, 0x5a4d, Endian.little)
    ..setUint32(0x3c, 64, Endian.little)
    ..setUint32(64, 0x4550, Endian.little)
    ..setUint16(68, 0x8664, Endian.little)
    ..setUint16(86, 0x2000, Endian.little);
  final path = p.join(p.dirname(model.paths.toolkits), 'Emulators', ManagedRetro.libraryName(platform));
  final file = File(path);
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(image.buffer.asUint8List());
}

void main() {
  final supportsManagedCores = Abi.current() == Abi.windowsX64;
  test('console folders preserve the real library, show both rows and move focus with Down and Up', () {
    final fixture = makeFixture(system: HostSystem.windows);
    final model = fixture.model;
    addTearDown(() {
      model.dispose();
      fixture.dispose();
    });

    final ps5 = _game('PS5');
    final ps1a = _game('First PS1', platform: RetroPlatform.ps1);
    final ps2 = _game('PS2', platform: RetroPlatform.ps2);
    final ps1b = _game('Second PS1', platform: RetroPlatform.ps1);
    final anotherPs5 = _game('Another PS5');
    model.games = [ps5, ps2, ps1a, ps1b, anotherPs5];
    model.select(0);

    expect(model.homeTiles, hasLength(5));
    model.setShowRetroFolders(true);
    expect(model.homeTiles.map((tile) => tile.folder), everyElement(isNull));
    expect(model.homeTiles, hasLength(5));

    _installFixtureCore(model, RetroPlatform.ps1);
    _installFixtureCore(model, RetroPlatform.ps2);
    expect(model.homeTiles.map((tile) => tile.folder), [null, null, RetroPlatform.ps1, RetroPlatform.ps2]);
    expect(model.selectedGame, same(ps5));

    model.handle(Command.right);
    expect(model.selectedGame, same(anotherPs5));
    model.handle(Command.right);
    expect(model.selectedHomeFolder, RetroPlatform.ps1);
    expect(model.homeFolderTiles.map((tile) => model.games[tile.gameIndex]), [ps1a, ps1b]);
    model.padCommand(PadCommand.menu);
    expect(model.overlay, isNull);
    expect(model.activeHomeRetroFolder, RetroPlatform.ps1);
    model.handle(Command.up);
    model.handle(Command.down);
    expect(model.activeHomeRetroFolder, RetroPlatform.ps1);
    expect(model.homeTiles.map((tile) => tile.folder), [null, null, RetroPlatform.ps1, RetroPlatform.ps2]);
    model.handle(Command.right);
    expect(model.selectedGame, same(ps1b));
    model.handle(Command.up);
    expect(model.activeHomeRetroFolder, isNull);
    expect(model.selectedHomeFolder, RetroPlatform.ps1);
    expect(model.selectedGame, same(ps1b));
    expect(model.games, [ps5, ps2, ps1a, ps1b, anotherPs5]);

    model.handle(Command.left);
    expect(model.selectedGame, same(anotherPs5));
    expect(model.selectedHomeFolder, isNull);
    expect(Preferences.fromJson(model.preferences.toJson()).showRetroFolders, isTrue);
    model.setShowRetroFolders(false);
    expect(model.homeTiles, hasLength(5));
  }, skip: !supportsManagedCores);

  testWidgets('folder selection uses the theme and its game row shows the game wallpaper', (tester) async {
    final fixture = makeFixture(system: HostSystem.windows);
    final model = fixture.model;
    addTearDown(() {
      model.dispose();
      fixture.dispose();
    });
    final gameWallpaper = File('${fixture.temp.path}/game.png')..writeAsBytesSync(backgroundArt(0x335577));
    model.games = [
      _game('PS1 Game', platform: RetroPlatform.ps1, background: gameWallpaper.path),
      _game('PS2 Game', platform: RetroPlatform.ps2),
      _game('PS3 Game', platform: RetroPlatform.ps3),
    ];
    model.select(0);
    for (final platform in RetroPlatform.values) {
      _installFixtureCore(model, platform);
    }
    model.setShowRetroFolders(true);
    model.preferences.gameArtwork = true;
    await pumpLauncher(tester, model);
    final artwork = find.byType(GameArtwork);
    expect(artwork, findsNothing);
    expect(artwork, findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await settle(tester);
    expect(tester.widget<GameArtwork>(artwork).path, gameWallpaper.path);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await settle(tester);
    expect(artwork, findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await settle(tester);
    expect(artwork, findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await settle(tester);
    expect(artwork, findsNothing);
  }, skip: !supportsManagedCores);

  testWidgets('hover reveals games below the folder and Down and Up keep both rows visible', (tester) async {
    final fixture = makeFixture(system: HostSystem.windows);
    final model = fixture.model;
    addTearDown(() {
      model.dispose();
      fixture.dispose();
    });

    model.games = [
      model.games.first,
      _game('First PS3', platform: RetroPlatform.ps3),
      _game('Second PS3', platform: RetroPlatform.ps3),
    ];
    model.select(0);
    _installFixtureCore(model, RetroPlatform.ps3);
    model.setShowRetroFolders(true);
    await pumpLauncher(tester, model);
    expect(find.byType(RetroFolderTile), findsOneWidget);
    expect(find.byKey(const ValueKey('tile-press-First PS3')), findsNothing);
    final folder = find.byKey(const ValueKey('tile-press-folder-ps3'));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(1, 1));
    await mouse.moveTo(tester.getCenter(folder));
    await tester.pump();
    expect(model.selectedHomeFolder, RetroPlatform.ps3);
    await settle(tester);
    final child = find.byKey(const ValueKey('tile-press-First PS3'));
    expect(child, findsOneWidget);
    expect(find.byType(RetroFolderTile), findsOneWidget);
    expect(tester.getTopLeft(child).dy - tester.getBottomLeft(folder).dy, greaterThanOrEqualTo(24));
    expect(tester.getSize(child).width, greaterThanOrEqualTo(112));
    expect(find.text('First PS3'), findsNothing);
    expect(find.byIcon(Icons.folder_rounded), findsNothing);
    expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsOneWidget);
    expect(model.activeHomeRetroFolder, isNull);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await mouse.removePointer();
    await settle(tester);
    expect(model.activeHomeRetroFolder, RetroPlatform.ps3);
    expect(find.text('First PS3'), findsWidgets);
    expect(tester.getSize(child).width, greaterThanOrEqualTo(148));
    expect(find.byType(RetroFolderTile), findsOneWidget);
    expect(find.byKey(const ValueKey('tile-press-Second PS3')), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await settle(tester);
    expect(model.selectedHomeFolder, RetroPlatform.ps3);
    expect(model.activeHomeRetroFolder, isNull);
    expect(child, findsOneWidget);

    await tester.tap(child);
    await settle(tester);
    expect(model.activeHomeRetroFolder, RetroPlatform.ps3);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(model.overlay, isNull);
    expect(model.selectedHomeFolder, RetroPlatform.ps3);
  }, skip: !supportsManagedCores);
}
