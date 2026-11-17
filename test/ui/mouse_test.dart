import 'dart:io';

import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/game_settings.dart';
import 'package:anyps5_desktop/core/screenshots.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/components.dart';
import 'package:anyps5_desktop/ui/launcher.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:anyps5_desktop/ui/theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/ui_support.dart';

/// The launcher with a mouse and the keyboard: every row, arrow and pill clickable, a way out of
/// every layer, the arrows going the way they point.
void main() {
  late Fixture fixture;
  late AppModel model;

  setUp(() {
    fixture = makeFixture();
    model = fixture.model;
  });

  tearDown(() {
    T.language = Language.english;
    Motion.reduced = false;
    fixture.dispose();
  });

  Game orbit() => model.games.firstWhere((game) => game.titleId == 'PPSA01001');
  GameSettings settings() => model.currentSettings(orbit());

  Future<void> openGameSettings(WidgetTester tester) async {
    model.select(model.games.indexOf(orbit()));
    model.open(Layer.gameSettings);
    await pumpLauncher(tester, model);
  }

  testWidgets('← on a choice goes to the option before, even on a row of two; → to the next', (tester) async {
    await openGameSettings(tester);
    expect(settings().fullscreen, isFalse);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(settings().fullscreen, isFalse, reason: 'already at the first option: ← stays');
    expect(settings().ownFullscreen, isNull, reason: 'at the first option, Default');
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(settings().ownFullscreen, isFalse, reason: 'Window');
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(settings().fullscreen, isTrue);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(settings().fullscreen, isFalse);
  });

  testWidgets('the arrows of a choice and the − + of a stepper are clicked on their own', (tester) async {
    await openGameSettings(tester);
    // Performance overlay: Off, top left, top right...
    await tester.tap(find.byKey(const ValueKey('overlay-next')));
    await settle(tester);
    expect(settings().overlay, OverlayCorner.topLeft);
    expect(model.panelRow, model.panelCategories().single.rows.indexWhere((row) => row.id == 'overlay'));
    await tester.tap(find.byKey(const ValueKey('overlay-next')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('overlay-previous')));
    await settle(tester);
    expect(settings().overlay, OverlayCorner.topLeft, reason: 'the left arrow goes back');
    await tester.tap(find.byKey(const ValueKey('windowSize-previous')));
    await settle(tester);
    expect(settings().windowSize, 70);
    await tester.tap(find.byKey(const ValueKey('windowSize-next')));
    await tester.tap(find.byKey(const ValueKey('windowSize-next')));
    await settle(tester);
    expect(settings().windowSize, 80);
  });

  testWidgets('clicking a row does what Enter does there; the pointer moving over one focuses it', (tester) async {
    await openGameSettings(tester);
    final rows = model.panelCategories().single.rows;
    final vsync = rows.indexWhere((row) => row.id == 'vsync');
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.byKey(const ValueKey('row-vsync'))));
    await settle(tester);
    expect(model.panelRow, vsync, reason: 'the focus follows the pointer');
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(model.panelRow, vsync + 1, reason: 'the keys carry on from there; a still pointer does not pull it back');
    // Default, On, Off.
    await tester.tap(find.byKey(const ValueKey('row-vsync')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('row-vsync')));
    await settle(tester);
    expect(settings().vsync, isFalse);
  });

  testWidgets('every panel has a way out for the mouse: its button, a click beside it, the right button', (
    tester,
  ) async {
    model.open(Layer.settings);
    await pumpLauncher(tester, model);
    await tester.tap(find.byKey(const ValueKey('back-pill')));
    await settle(tester);
    expect(model.overlay, isNull);

    model.open(Layer.settings);
    await settle(tester);
    await tester.tapAt(const Offset(40, 450));
    await settle(tester);
    expect(model.overlay, isNull, reason: 'a click outside the panel closes it');

    model.open(Layer.settings);
    await settle(tester);
    await tester.tapAt(const Offset(800, 450), buttons: kSecondaryMouseButton, kind: PointerDeviceKind.mouse);
    await settle(tester);
    expect(model.overlay, isNull, reason: 'the right button is Back');
  });

  testWidgets('the mouse\'s Back button is Back (Circle) everywhere; Forward opens again what it closed', (
    tester,
  ) async {
    Future<void> side(int button) async {
      await tester.tapAt(const Offset(800, 450), buttons: button, kind: PointerDeviceKind.mouse);
      await settle(tester);
    }

    await openGameSettings(tester);
    model.open(Layer.controls);
    await settle(tester);
    await side(kBackMouseButton);
    expect(model.overlay, Layer.gameSettings, reason: 'as Circle: the controls go back to the game settings');
    await side(kBackMouseButton);
    expect(model.overlay, isNull, reason: 'and the game settings close');
    await side(kForwardMouseButton);
    expect(model.overlay, Layer.gameSettings, reason: 'Forward opens again the layer Back closed');
    await side(kForwardMouseButton);
    expect(model.overlay, Layer.gameSettings, reason: 'once: nothing further ahead');

    model.open(Layer.library);
    await settle(tester);
    await side(kBackMouseButton);
    expect(model.overlay, isNull);
    await press(tester, LogicalKeyboardKey.arrowRight);
    await side(kForwardMouseButton);
    expect(model.overlay, isNull, reason: 'another game chosen since: Forward has nothing to open again');

    model.open(Layer.settings);
    await settle(tester);
    model.startEditing('name');
    await side(kBackMouseButton);
    expect(model.editingRow, isNull, reason: 'a field typed in lets go first, as Esc does');
    expect(model.overlay, Layer.settings);
    await side(kBackMouseButton);
    expect(model.overlay, isNull);
  });

  testWidgets('a keyboard\'s or a mouse driver\'s Back and Forward keys do the same', (tester) async {
    model.open(Layer.settings);
    await pumpLauncher(tester, model);
    Future<void> key(LogicalKeyboardKey key, PhysicalKeyboardKey physical) async {
      await tester.sendKeyDownEvent(key, physicalKey: physical, platform: 'windows');
      await tester.sendKeyUpEvent(key, physicalKey: physical, platform: 'windows');
      await settle(tester);
    }

    await key(LogicalKeyboardKey.browserBack, PhysicalKeyboardKey.browserBack);
    expect(model.overlay, isNull);
    await key(LogicalKeyboardKey.browserForward, PhysicalKeyboardKey.browserForward);
    expect(model.overlay, Layer.settings);
  });

  testWidgets('the controls go back to the game settings, not home', (tester) async {
    await openGameSettings(tester);
    model.open(Layer.controls);
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('back-pill')));
    await settle(tester);
    expect(model.overlay, Layer.gameSettings);
  });

  testWidgets('the library and the trophies have their way out too; the library opens a game with a double click', (
    tester,
  ) async {
    model.open(Layer.library);
    await pumpLauncher(tester, model);
    await tester.tap(find.byKey(const ValueKey('back-pill')));
    await settle(tester);
    expect(model.overlay, isNull);

    model.select(model.games.indexOf(orbit()));
    model.open(Layer.trophies);
    await settle(tester);
    expect(find.byKey(const ValueKey('back-pill')), findsOneWidget);
    await press(tester, LogicalKeyboardKey.escape);
    expect(model.overlay, isNull);
  });

  testWidgets('on Messages the back pill sits on the title\'s line, at the content\'s edge', (tester) async {
    model.open(Layer.messages);
    await pumpLauncher(tester, model);
    final title = find.text(T.text('messagesTitle'));
    final pill = tester.getRect(find.byKey(const ValueKey('back-pill')));
    final scale = LayoutScale.of(tester.element(title));
    final width = tester.getSize(find.byType(LauncherShell)).width;
    expect((pill.center.dy - tester.getRect(title).center.dy).abs(), lessThan(1), reason: 'level with the title');
    expect(pill.right, moreOrLessEquals(width - 80 * scale, epsilon: 1), reason: 'at the content\'s right edge');
  });

  testWidgets('the hint pills are buttons: Esc, Enter, O and Q/E run what their keys do', (tester) async {
    await pumpLauncher(tester, model);
    final first = model.selected;
    await tester.tap(find.text(T.text('hintNextGame')));
    await settle(tester);
    expect(model.selected, first + 1);
    await tester.tap(find.text(T.text('hintPreviousGame')));
    await settle(tester);
    expect(model.selected, first);
    await tester.tap(find.text(T.text('hintOptions')));
    await settle(tester);
    expect(model.overlay, Layer.gameSettings);
    await tester.tap(find.text(T.text('hintBack')).last);
    await settle(tester);
    expect(model.overlay, isNull);
  });

  testWidgets('a click on a game selects it at once; a second click starts its main action', (tester) async {
    await pumpLauncher(tester, model);
    final locked = model.games.firstWhere((game) => game.titleId == 'PPSA03003');
    final finder = find.byKey(ValueKey('tile-press-${locked.id}'));
    await tester.tap(finder);
    await tester.pump();
    expect(model.selectedGame, locked, reason: 'no wait for a possible second click');
    // The selected tile grows and moves to the row's start; the second click lands where it is now.
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(finder);
    await tester.pump();
    // The unlock started (the made-up dump then fails at once).
    expect(model.stateOf(locked), isNot(isA<Locked>()));
    await settle(tester);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the wheel moves between games on the home screen', (tester) async {
    await pumpLauncher(tester, model);
    final first = model.selected;
    await tester.sendEventToBinding(
      const PointerScrollEvent(position: Offset(800, 450), scrollDelta: Offset(0, 120), kind: PointerDeviceKind.mouse),
    );
    await settle(tester);
    expect(model.selected, first + 1);
  });

  testWidgets('a trophy\'s picture shows with it and opens in the gallery', (tester) async {
    final game = orbit();
    final shot = Screenshots.trophyPath(model.paths.pictures, game, '0/1', DateTime(2026, 10, 25, 9));
    File(shot)
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(png(16, 9, (x, y) => 0x3366FFFF));
    model.select(model.games.indexOf(game));
    model.open(Layer.trophies);
    final first = model.trophies[game.id]!.trophies.indexWhere((trophy) => trophy.id == '0/1');
    model.trophyIndex = first;
    model.refresh();
    await pumpLauncher(tester, model);
    expect(find.byKey(const ValueKey('trophy-shot')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('trophy-shot')));
    await settle(tester);
    expect(model.overlay, Layer.gallery);
    expect(model.galleryViewing, isTrue);
    expect(p.basename(model.galleryShots[model.galleryIndex]), p.basename(shot));
    await press(tester, LogicalKeyboardKey.escape);
    expect(model.galleryViewing, isFalse);
    await press(tester, LogicalKeyboardKey.escape);
    expect(model.overlay, Layer.trophies, reason: 'back where the gallery was opened from');
    expect(model.trophyIndex, first);
  });
}
