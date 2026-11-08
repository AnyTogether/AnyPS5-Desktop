import 'package:anyps5_desktop/core/themes/theme_design.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/launcher.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:anyps5_desktop/ui/theme_studio_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/ui_support.dart';

/// The Theme studio over the live home screen, and the Themes panel, as goldens.
void main() {
  late Fixture fixture;

  tearDown(() {
    T.language = Language.english;
    fixture.dispose();
  });

  final shell = find.byType(LauncherShell);

  /// A theme of the Studio's knobs: violet with a warm highlight and a coral accent.
  void studio(AppModel model) {
    model.openStudio();
    model.editTheme(
      (design) => const ThemeKnobs(
        hue: 265,
        highlight: 45,
        depth: 5,
        accentHue: 15,
      ).applyTo(design).copyWith(name: 'Night Drive', style: 1),
    );
    model.panelRow = 3;
  }

  testWidgets('the Theme studio over the home screen it changes', (tester) async {
    fixture = makeFixture();
    final model = fixture.model;
    studio(model);
    await pumpLauncher(tester, model);
    await expectLater(shell, matchesGoldenFile('goldens/theme_studio.png'));
  });

  testWidgets('the Theme studio in Turkish, in a smaller window', (tester) async {
    fixture = makeFixture(language: Language.byCode('tr'));
    final model = fixture.model;
    studio(model);
    await pumpLauncher(tester, model, size: const Size(1280, 720));
    await expectLater(shell, matchesGoldenFile('goldens/theme_studio_tr.png'));
  });

  testWidgets('the Themes panel: the built-in looks, a custom theme in use, the Studio', (tester) async {
    fixture = makeFixture();
    final model = fixture.model;
    studio(model);
    model.open(Layer.themes);
    model.panelRow = 5;
    await pumpLauncher(tester, model);
    await expectLater(shell, matchesGoldenFile('goldens/themes.png'));
  });

  testWidgets('the Themes in Turkish, in a smaller window: a pane beside the home screen, Cosmic readable', (
    tester,
  ) async {
    fixture = makeFixture(language: Language.byCode('tr'));
    final model = fixture.model;
    model.open(Layer.themes);
    await pumpLauncher(tester, model, size: const Size(1280, 720));
    expect(model.panelCategories().single.rows[model.panelRow].id, 'builtin-cosmic');
    await expectLater(shell, matchesGoldenFile('goldens/themes_tr.png'));
  });

  testWidgets('the Themes pane keeps its width in a wide window, the home screen in view beside it', (tester) async {
    fixture = makeFixture();
    final model = fixture.model;
    model.open(Layer.themes);
    await pumpLauncher(tester, model, size: const Size(2560, 1440));
    final pane = tester.getRect(find.byKey(const ValueKey('themes-pane')));
    expect(find.byType(ThemesView), findsOneWidget);
    expect(pane.width, lessThan(2560 / 2), reason: 'not the whole window');
    expect(pane.right, greaterThan(2560 - 120), reason: 'on the right, as the Studio');
    // A click on the home screen beside it goes back to Settings › Appearance.
    await tester.tapAt(const Offset(200, 720));
    await tester.pump();
    expect(model.overlay, Layer.settings);
  });

  testWidgets('a row taking the focus turns its words dark with its light fill, not before it', (tester) async {
    fixture = makeFixture();
    final model = fixture.model;
    model.open(Layer.themes);
    await pumpLauncher(tester, model);
    double lightness(String id, String title) => tester
        .widget<Text>(find.descendant(of: find.byKey(ValueKey('row-$id')), matching: find.text(title)))
        .style!
        .color!
        .computeLuminance();
    expect(lightness('builtin-cosmic', 'Cosmic'), lessThan(0.2), reason: 'focused: dark words on the white fill');
    model.handle(Command.down);
    await tester.pump();
    // The fill has not come yet (it fades in, and stands still while the launcher rests behind
    // another window): the words stay light on the dark row.
    expect(lightness('builtin-aurora', 'Aurora'), greaterThan(0.8));
    await tester.pump(const Duration(milliseconds: 400));
    expect(lightness('builtin-aurora', 'Aurora'), lessThan(0.2));
    expect(lightness('builtin-cosmic', 'Cosmic'), greaterThan(0.8));
  });
}
