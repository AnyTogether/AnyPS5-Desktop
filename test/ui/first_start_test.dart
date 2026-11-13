import 'dart:io';

import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/background.dart';
import 'package:anyps5_desktop/ui/launcher.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:anyps5_desktop/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/ui_support.dart';

/// The first start as it comes up, before any key: every language and every theme is on the
/// screen, the arrows move through them, the choice is the one kept. And typing: the sign-in's
/// email after a click and after the keys, Add Profile's name, and Settings' sections following
/// the selection down a window too small for all of them.
void main() {
  late Fixture fixture;
  final shell = find.byType(LauncherShell);

  // The widget binding answers every HTTP request with 400; the sign-in asks nobody here.
  setUp(() => HttpOverrides.global = null);

  tearDown(() {
    T.language = Language.english;
    fixture.dispose();
  });

  /// Whether [finder]'s one widget is whole inside [within]'s.
  bool inside(WidgetTester tester, Finder finder, Finder within) {
    final box = tester.getRect(finder);
    final room = tester.getRect(within);
    return box.left >= room.left - 0.5 &&
        box.right <= room.right + 0.5 &&
        box.top >= room.top - 0.5 &&
        box.bottom <= room.bottom + 0.5;
  }

  for (final code in ['en', 'tr']) {
    testWidgets('the language step shows every language at once, before any key ($code)', (tester) async {
      fixture = makeFixture(onboarded: false, withToolkit: false, language: Language.byCode(code));
      final model = fixture.model;
      await pumpLauncher(tester, model);
      expect(model.onboardingStep, 0);
      expect(T.languages.length, greaterThan(20));
      for (final language in T.languages) {
        final name = find.text(language.displayName);
        expect(name, findsOneWidget, reason: '${language.code} has no card');
        expect(inside(tester, name, shell), isTrue, reason: '${language.code} is off the screen');
      }
      expect(model.onboardingChoice, T.languages.indexOf(T.language), reason: 'the language it starts in is chosen');
      await expectLater(shell, matchesGoldenFile('goldens/first_start_language_$code.png'));
    });

    testWidgets('the theme step shows every theme at once, before any key ($code)', (tester) async {
      fixture = makeFixture(onboarded: false, withToolkit: false, language: Language.byCode(code));
      final model = fixture.model;
      model.onboardingStep = 1;
      await pumpLauncher(tester, model);
      for (final style in LookStyle.values) {
        final title = find.text(style.title);
        expect(title, findsOneWidget, reason: '${style.name} has no card');
        expect(inside(tester, title, shell), isTrue);
      }
      // A picture for every theme (the window's own background is the large one behind them).
      final cards = [
        for (final element in find.byType(ThemeBackground).evaluate())
          if ((element.renderObject! as RenderBox).size.width < 600) (element.renderObject! as RenderBox).size,
      ];
      expect(cards, hasLength(LookStyle.values.length));
      for (final size in cards) {
        expect(size.width, greaterThan(200), reason: 'a theme card with no size');
        expect(size.height, greaterThan(100));
      }
      await expectLater(shell, matchesGoldenFile('goldens/first_start_theme_$code.png'));
    });
  }

  testWidgets('the arrows move through the languages and the themes, and the choice is kept', (tester) async {
    fixture = makeFixture(onboarded: false, withToolkit: false);
    final model = fixture.model;
    await pumpLauncher(tester, model);
    model.onboardingChoice = 0;
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(model.onboardingChoice, 1);
    expect(T.language.code, T.languages[1].code, reason: 'the step is drawn in the language the selection is on');
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(model.onboardingChoice, 1 + AppModel.languageColumns);
    await press(tester, LogicalKeyboardKey.arrowUp);
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(model.onboardingChoice, 1, reason: 'no row above the first');
    final turkish = T.languages.indexWhere((language) => language.code == 'tr');
    // A click on a card chooses it and goes on.
    await tester.tap(find.text(T.languages[turkish].displayName));
    await settle(tester);
    expect(T.language.code, 'tr');
    expect(model.onboardingStep, 1);
    expect(find.text(T.text('chooseTheme')), findsOneWidget);
    expect(model.onboardingChoice, model.preferences.theme);
    await press(tester, LogicalKeyboardKey.arrowRight);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(model.preferences.theme, 2, reason: 'the theme under the selection is shown at once');
    await press(tester, LogicalKeyboardKey.enter);
    expect(model.onboardingStep, 2);
    expect(model.preferences.theme, 2);
  });

  group('typing', () {
    /// The first start's last step with the sign-in over it.
    Future<AppModel> signingIn(WidgetTester tester) async {
      fixture = makeFixture(onboarded: false);
      final model = fixture.model;
      model.onboardingStep = 4;
      model.profileFlow.modeChoice = 1;
      await tester.runAsync(() async {
        model.handle(Command.select);
        for (var tries = 0; tries < 200 && model.overlay != Layer.signIn; tries++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      expect(model.overlay, Layer.signIn);
      await pumpLauncher(tester, model);
      return model;
    }

    List<PanelRow> rows(AppModel model) => model.panelCategories()[model.panelCategory].rows;
    // The sign-in has one field at this step: the email.
    final field = find.byType(TextField);

    testWidgets('first start, the sign-in: the keys reach the email row, Enter types in it', (tester) async {
      final model = await signingIn(tester);
      for (var moves = 0; moves < 10 && rows(model)[model.panelRow].id != 'together-email'; moves++) {
        await press(tester, LogicalKeyboardKey.arrowDown);
      }
      expect(rows(model)[model.panelRow].id, 'together-email');
      await press(tester, LogicalKeyboardKey.enter);
      expect(model.editingRow, 'together-email');
      expect(tester.widget<TextField>(field).focusNode?.hasFocus, isTrue, reason: 'the cursor is in the field');
      await tester.enterText(field, 'robin@example.com');
      await settle(tester);
      expect(model.together.email, 'robin@example.com');
      // The keys are the field's while it is typed in: space, Backspace and O do nothing else.
      await press(tester, LogicalKeyboardKey.space);
      await press(tester, LogicalKeyboardKey.backspace);
      await press(tester, LogicalKeyboardKey.keyO);
      expect(model.overlay, Layer.signIn);
      expect(model.editingRow, 'together-email');
      await press(tester, LogicalKeyboardKey.escape);
      expect(model.editingRow, isNull, reason: 'Esc gives the keys back');
      expect(model.overlay, Layer.signIn, reason: 'and does not leave the sign-in');
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(rows(model)[model.panelRow].id, isNot('together-email'), reason: 'the arrows move again');
    });

    testWidgets('first start, the sign-in: a click on the email field or on its row types in it', (tester) async {
      final model = await signingIn(tester);
      await tester.tap(field);
      await settle(tester);
      expect(model.editingRow, 'together-email', reason: 'a click on the field');
      expect(tester.widget<TextField>(field).focusNode?.hasFocus, isTrue);
      await tester.enterText(field, 'a@example.com');
      await settle(tester);
      expect(model.together.email, 'a@example.com');
      // Any model change while typing leaves the cursor where it is.
      model.refresh();
      await settle(tester);
      expect(tester.widget<TextField>(field).focusNode?.hasFocus, isTrue, reason: 'the launcher took the focus back');
      await press(tester, LogicalKeyboardKey.escape);
      expect(model.editingRow, isNull);
      // On the row's left end, away from the field.
      await tester.tapAt(
        tester.getRect(find.byKey(const ValueKey('row-together-email'))).centerLeft + const Offset(40, 0),
      );
      await settle(tester);
      expect(model.editingRow, 'together-email', reason: 'a click on the row');
      expect(tester.widget<TextField>(field).focusNode?.hasFocus, isTrue);
    });

    testWidgets('Add Profile: up goes to the name, the keys type, Enter gives them back to the cards', (tester) async {
      fixture = makeFixture();
      final model = fixture.model;
      model.openAddProfile();
      await pumpLauncher(tester, model);
      final name = find.byKey(const ValueKey('profile-add-name'));
      expect(tester.widget<TextField>(name).focusNode?.hasFocus, isFalse);
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(model.editingRow, ProfileFlow.nameRow);
      expect(
        tester.widget<TextField>(name).focusNode?.hasFocus,
        isTrue,
        reason: 'up from the cards puts the cursor in the name',
      );
      await tester.enterText(name, 'Deniz');
      await settle(tester);
      expect(model.profileFlow.name, 'Deniz');
      // While the name is typed its keys are not the launcher's: space is not Select, Backspace
      // is not Back, O is not Options, Q and E are not shortcuts.
      for (final key in [
        LogicalKeyboardKey.space,
        LogicalKeyboardKey.backspace,
        LogicalKeyboardKey.keyO,
        LogicalKeyboardKey.keyQ,
        LogicalKeyboardKey.keyE,
        LogicalKeyboardKey.arrowRight,
      ]) {
        await press(tester, key);
        expect(model.overlay, Layer.addProfile, reason: '${key.keyLabel} left Add Profile');
        expect(model.profileFlow.modeChoice, 0, reason: '${key.keyLabel} moved the cards');
        expect(model.profiles.book.profiles.where((profile) => profile.name == 'Deniz'), isEmpty);
      }
      model.refresh();
      await settle(tester);
      expect(tester.widget<TextField>(name).focusNode?.hasFocus, isTrue, reason: 'the launcher took the focus back');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
      expect(model.editingRow, isNull, reason: 'Enter gives the keys back');
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(model.profileFlow.modeChoice, 1, reason: 'the arrows pick a card again');
    });

    testWidgets('Add Profile: a click on the name types in it, Esc gives the keys back', (tester) async {
      fixture = makeFixture();
      final model = fixture.model;
      model.openAddProfile();
      await pumpLauncher(tester, model);
      final name = find.byKey(const ValueKey('profile-add-name'));
      await tester.tap(name);
      await settle(tester);
      expect(model.editingRow, ProfileFlow.nameRow);
      await press(tester, LogicalKeyboardKey.space);
      expect(model.overlay, Layer.addProfile, reason: 'space is the name\'s, not Select');
      await press(tester, LogicalKeyboardKey.escape);
      expect(model.editingRow, isNull);
      expect(model.overlay, Layer.addProfile, reason: 'the first Esc only leaves the field');
      expect(tester.widget<TextField>(name).focusNode?.hasFocus, isFalse);
    });
  });

  testWidgets('Settings\' sections follow the selection down and up a small window', (tester) async {
    fixture = makeFixture();
    final model = fixture.model;
    model.open(Layer.settings);
    await pumpLauncher(tester, model, size: const Size(1100, 700));
    final sections = model.panelCategories();
    expect(sections.length, greaterThan(12));
    Finder tab(int index) => find.byKey(ValueKey('section-${sections[index].id}'));
    final list = find.ancestor(of: tab(0), matching: find.byType(SingleChildScrollView)).first;
    expect(
      tester.getRect(tab(sections.length - 1)).bottom,
      greaterThan(tester.getRect(list).bottom),
      reason: 'the sections have to be taller than the window for this test',
    );
    for (var index = 1; index < sections.length; index++) {
      // As E (and R1) does.
      model.moveCategory(1);
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 400));
      expect(model.panelCategory, index);
      expect(
        inside(tester, tab(index), list),
        isTrue,
        reason: 'going down, ${sections[index].id} is not whole on the screen',
      );
    }
    for (var index = sections.length - 2; index >= 0; index--) {
      model.moveCategory(-1);
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        inside(tester, tab(index), list),
        isTrue,
        reason: 'going up, ${sections[index].id} is not whole on the screen',
      );
    }
  });
}
