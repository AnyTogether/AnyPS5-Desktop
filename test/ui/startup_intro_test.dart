import 'package:anyps5_desktop/core/profiles/profiles.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/startup_intro.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:anyps5_desktop/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/ui_support.dart';

void main() {
  late Fixture fixture;

  // The intro is off everywhere else (previews and the other tests build the home screen
  // directly); both fields are static, so they go back after each test.
  setUp(() {
    StartupIntro.enabled = true;
    StartupIntro.played = false;
  });

  tearDown(() {
    StartupIntro.enabled = false;
    StartupIntro.played = false;
    Motion.reduced = false;
    T.language = Language.english;
    fixture.model.starting = null;
    fixture.dispose();
  });

  final curtain = find.byType(IntroCurtain);

  testWidgets('the curtain is there at the start, gone after the intro, and does not come back', (tester) async {
    fixture = makeFixture();
    final model = fixture.model;
    await pumpLauncher(tester, model);
    expect(curtain, findsOneWidget);
    expect(StartupIntro.played, isTrue);

    await tester.pump(StartupIntro.duration);
    await tester.pump();
    expect(curtain, findsNothing);

    model.open(Layer.settings);
    await settle(tester);
    model.closeOverlay();
    await settle(tester);
    expect(curtain, findsNothing);
  });

  testWidgets('a key finishes it at once', (tester) async {
    fixture = makeFixture();
    await pumpLauncher(tester, fixture.model);
    expect(curtain, findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(curtain, findsNothing);
  });

  testWidgets('it does not play with reduced motion', (tester) async {
    fixture = makeFixture();
    Motion.reduced = true;
    await pumpLauncher(tester, fixture.model);
    expect(curtain, findsNothing);
    expect(StartupIntro.played, isTrue);
  });

  testWidgets('it does not play when the system asks for no animations', (tester) async {
    fixture = makeFixture();
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(
      disableAnimations: true,
    );
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await pumpLauncher(tester, fixture.model);
    expect(curtain, findsNothing);
    expect(StartupIntro.played, isTrue);
  });

  testWidgets('it does not play with a game starting', (tester) async {
    fixture = makeFixture();
    final model = fixture.model;
    model.starting = model.games.first;
    await pumpLauncher(tester, model);
    expect(curtain, findsNothing);
    expect(StartupIntro.played, isTrue);
  });

  testWidgets('with the launch picker open it waits until the picker closes', (tester) async {
    fixture = makeFixture();
    final model = fixture.model;
    model.profiles.add(name: 'Mira', mode: ProfileMode.offline);
    model.openProfilePicker(atLaunch: true);
    await pumpLauncher(tester, model);
    expect(curtain, findsNothing);
    expect(StartupIntro.played, isFalse);

    model.closeOverlay();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(curtain, findsOneWidget);
    expect(StartupIntro.played, isTrue);

    await tester.pump(StartupIntro.duration);
    await tester.pump();
    expect(curtain, findsNothing);
  });
}
