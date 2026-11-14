import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/launcher.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:anyps5_desktop/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/ui_support.dart';

/// The home tile row keeps the game before the selected one in view, partly past the window's
/// edge: a little dimmer, selectable with a click, with the game before that one gone. The
/// selected game's name carries its state as an icon only, with the words as a label and a hint.
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

  String idAt(int index) => model.games[model.homeTiles[index].gameIndex].id;

  Finder tile(int index) => find.byKey(ValueKey('tile-${idAt(index)}'));

  Finder label(int index) => find.byKey(ValueKey('label-${idAt(index)}'));

  double opacityOf(WidgetTester tester, int index) =>
      tester.widget<AnimatedOpacity>(find.descendant(of: tile(index), matching: find.byType(AnimatedOpacity)).first).opacity;

  Future<void> select(WidgetTester tester, int index) async {
    model.selectHomeTile(index);
    await settle(tester);
  }

  testWidgets('with the second game selected the first stays in view, a little dimmer', (tester) async {
    await pumpLauncher(tester, model);
    await select(tester, 1);
    expect(model.homeTileIndex(model.homeTiles), 1);
    expect(opacityOf(tester, 0), tilePeekOpacity);
    expect(opacityOf(tester, 1), 1);
    expect(tester.getTopLeft(tile(0)).dx, lessThan(0), reason: 'it starts past the window\'s edge');
    expect(tester.getTopRight(tile(0)).dx, greaterThan(0), reason: 'and a strip of it is in view');
  });

  testWidgets('with the first game selected nothing is before it', (tester) async {
    await pumpLauncher(tester, model);
    await select(tester, 0);
    expect(opacityOf(tester, 1), 1);
    expect(tester.getTopLeft(tile(0)).dx, greaterThan(0));
  });

  testWidgets('a tap on the previous tile selects that game', (tester) async {
    await pumpLauncher(tester, model);
    await select(tester, 1);
    await tester.tap(tile(0));
    await settle(tester);
    expect(model.homeTileIndex(model.homeTiles), 0);
    expect(model.selected, model.homeTiles[0].gameIndex);
    expect(opacityOf(tester, 1), 1, reason: 'the game after it is an ordinary tile again');
  });

  testWidgets('the game before the previous one is not drawn', (tester) async {
    await pumpLauncher(tester, model);
    await select(tester, 2);
    expect(opacityOf(tester, 1), tilePeekOpacity);
    expect(opacityOf(tester, 0), 0);
  });

  testWidgets('the name carries the state as an icon, with its words as a label and a hint; none for a plain lock', (
    tester,
  ) async {
    await pumpLauncher(tester, model);
    var withIcon = 0;
    var withoutIcon = 0;
    for (var index = 0; index < model.homeTiles.length; index++) {
      await select(tester, index);
      final game = model.games[model.homeTiles[index].gameIndex];
      final icons = find.descendant(of: label(index), matching: find.byType(Icon));
      // Only the name is written: the state's words are not drawn beside it.
      expect(find.descendant(of: label(index), matching: find.byType(Text)), findsOneWidget);
      if (model.stateOf(game) case Locked(waitingToPrepare: false)) {
        withoutIcon++;
        expect(icons, findsNothing, reason: '${game.titleId}: a plain locked game has its padlock on the tile');
        continue;
      }
      withIcon++;
      expect(icons, findsOneWidget, reason: game.titleId);
      final words = tester.widget<Icon>(icons).semanticLabel;
      expect(words, isNotEmpty, reason: '${game.titleId}: a screen reader reads the state');
      final hint = find.descendant(of: label(index), matching: find.byType(Tooltip));
      expect(tester.widget<Tooltip>(hint).message, words);
    }
    expect(withIcon, greaterThan(0));
    expect(withoutIcon, greaterThan(0));
  });

  testWidgets('the installed game says Ready in words for a screen reader', (tester) async {
    await pumpLauncher(tester, model);
    final index = model.homeTiles.indexWhere((tile) => model.games[tile.gameIndex].titleId == 'PPSA01001');
    await select(tester, index);
    final icon = tester.widget<Icon>(find.descendant(of: label(index), matching: find.byType(Icon)));
    expect(icon.semanticLabel, T.text('ready'));
  });

  group('golden', () {
    testWidgets('home, the second game selected: the first one peeks in from the edge', (tester) async {
      await pumpLauncher(tester, model);
      await select(tester, 1);
      await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/home_previous_tile.png'));
    });
  });
}
