import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/components.dart';
import 'package:anyps5_desktop/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_process.dart';
import '../support/ui_support.dart';

/// The focus ring's glint and halo loop: only the focused home tile runs it, and only while
/// nothing else needs the computer. A loop that never ends keeps a frame scheduled, so that is
/// what is looked at here.
void main() {
  late Fixture fixture;
  late AppModel model;

  setUp(() {
    fixture = makeFixture();
    model = fixture.model;
    FocusRing.enabled = true;
  });

  tearDown(() {
    FocusRing.enabled = false;
    Motion.reduced = false;
    fixture.dispose();
  });

  Game orbit() => model.games.firstWhere((game) => game.titleId == 'PPSA01001');

  /// A few frames, as the launcher's own animations (a layer fading in) finish; a ring that
  /// loops still has a frame scheduled after them.
  Future<void> frames(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> home(WidgetTester tester) async {
    model.select(model.games.indexOf(orbit()));
    await pumpLauncher(tester, model);
    await frames(tester);
  }

  testWidgets('with the switch off (as in every other test) the ring stands still', (tester) async {
    FocusRing.enabled = false;
    await home(tester);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('a focused home tile keeps a frame scheduled', (tester) async {
    await home(tester);
    expect(tester.binding.hasScheduledFrame, isTrue);
  });

  testWidgets('it stops with reduced motion, and starts again when that is off', (tester) async {
    await home(tester);
    expect(tester.binding.hasScheduledFrame, isTrue);
    model.preferences.reducedMotion = true;
    Motion.reduced = true;
    model.refresh();
    await frames(tester);
    expect(tester.binding.hasScheduledFrame, isFalse, reason: 'already moving, then reduced motion turned on');
    model.preferences.reducedMotion = false;
    Motion.reduced = false;
    model.refresh();
    await frames(tester);
    expect(tester.binding.hasScheduledFrame, isTrue);
  });

  testWidgets('it stops with the system asking for less animation', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await home(tester);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('it stops with a layer open', (tester) async {
    await home(tester);
    expect(tester.binding.hasScheduledFrame, isTrue);
    model.open(Layer.library);
    await frames(tester);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('it stops while a game runs', (tester) async {
    await home(tester);
    expect(tester.binding.hasScheduledFrame, isTrue);
    model.running = (orbit(), runningFor(FakeGameProcess()));
    model.refresh();
    await frames(tester);
    expect(tester.binding.hasScheduledFrame, isFalse);
    model.running = null;
  });

  testWidgets('it stops while a game starts', (tester) async {
    await home(tester);
    expect(tester.binding.hasScheduledFrame, isTrue);
    model.starting = orbit();
    model.refresh();
    await frames(tester);
    // The starting card has an animation of its own, so a frame stays scheduled; the ring is
    // already still when turning every ring off changes nothing.
    final withSwitch = tester.binding.transientCallbackCount;
    FocusRing.enabled = false;
    model.refresh();
    await frames(tester);
    expect(tester.binding.transientCallbackCount, withSwitch);
    model.starting = null;
  });

  testWidgets('a focused settings tab never schedules one', (tester) async {
    model.open(Layer.settings);
    await pumpLauncher(tester, model);
    await frames(tester);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
}
