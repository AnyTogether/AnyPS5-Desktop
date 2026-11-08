import 'dart:io';

import 'package:anyps5_desktop/core/desktop/launcher_window.dart';
import 'package:anyps5_desktop/core/gamepad/guide_switch.dart';
import 'package:anyps5_desktop/core/gamepad/pad_navigation.dart';
import 'package:anyps5_desktop/core/gamepad/shortcuts.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/remote/remote_protocol.dart';
import 'package:anyps5_desktop/core/installer.dart';
import 'package:anyps5_desktop/core/replay_buffer.dart';
import 'package:anyps5_desktop/core/screenshots.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/components.dart';
import 'package:anyps5_desktop/ui/home.dart' show PhoneIndicator;
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:anyps5_desktop/ui/theme.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart'
    show Center, Directionality, IgnorePointer, Offset, Stack, TextDirection, ValueKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../core/replay_buffer_test.dart' show FakeProcess;
import '../support/ui_support.dart';
import 'desktop_features_test.dart' show FakeDesktop, FakePads;

/// The window's full screen as asked.
class FakeWindow implements LauncherWindow {
  final List<bool> asked = [];
  int minimized = 0;
  int closed = 0;
  bool works = true;
  String? marker;
  void Function(bool fullscreen)? system;

  @override
  Future<bool> setFullscreen(bool on) async {
    asked.add(on);
    return works;
  }

  @override
  Future<bool> close() async {
    closed++;
    return true;
  }

  @override
  Future<bool> removeAfterClose(String path) async {
    marker = path;
    return true;
  }

  @override
  void listen({required void Function(bool fullscreen) fullscreenChanged}) => system = fullscreenChanged;

  @override
  Future<bool> minimize() async {
    minimized++;
    return true;
  }

  int restored = 0;

  @override
  Future<bool> restore() async {
    restored++;
    return true;
  }
}

void main() {
  tearDown(() {
    T.language = Language.english;
    Motion.reduced = false;
  });

  Future<void> until(bool Function() condition, {int tries = 500}) async {
    for (var index = 0; index < tries && !condition(); index++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(condition(), isTrue);
  }

  group('full screen', () {
    test('full screen at the first launch; the choice is kept after', () async {
      final window = FakeWindow();
      final fixture = makeFixture(window: window);
      final model = fixture.model;
      addTearDown(fixture.dispose);
      expect(model.preferences.launcherFullscreen, isNull);
      await model.applyLauncherWindow();
      expect(window.asked, [true]);
      await model.toggleFullscreen();
      expect(window.asked, [true, false]);
      expect(model.preferences.launcherFullscreen, isFalse);
      expect(Preferences.fromJson(model.preferences.toJson()).launcherFullscreen, isFalse);
      await model.applyLauncherWindow();
      expect(window.asked.last, isFalse, reason: 'the next start keeps the window');
    });

    test(
      'the system made it full screen or a window (Maximize, Win+Up): the launcher and its setting follow',
      () async {
        final window = FakeWindow();
        final fixture = makeFixture(window: window);
        final model = fixture.model;
        addTearDown(fixture.dispose);
        await model.setLauncherFullscreen(false);
        expect(model.windowFullscreen, isFalse);
        expect(window.system, isNotNull, reason: 'the model listens to the window');
        window.system!(true);
        expect(model.windowFullscreen, isTrue, reason: 'the window buttons wait at the top edge');
        expect(model.launcherFullscreen, isTrue, reason: 'Settings › Full screen reads on');
        expect(Preferences.fromJson(model.preferences.toJson()).launcherFullscreen, isTrue, reason: 'and stays so');
        expect(window.asked, [false], reason: 'nothing asked back of the window: it is full screen already');
        model.open(Layer.settings);
        final row = model.panelCategories().first.rows.firstWhere((row) => row.id == 'fullscreen');
        expect((row.kind as ToggleRow).value, isTrue);
        window.system!(false);
        expect(model.windowFullscreen, isFalse);
        expect(model.launcherFullscreen, isFalse);
      },
    );

    test('full screen the window could not make: the setting stays as the window is', () async {
      final window = FakeWindow();
      final fixture = makeFixture(window: window);
      final model = fixture.model;
      addTearDown(fixture.dispose);
      await model.setLauncherFullscreen(false);
      window.works = false;
      await model.setLauncherFullscreen(true);
      expect(model.windowFullscreen, isFalse);
      expect(model.launcherFullscreen, isFalse, reason: 'Settings must not say full screen over a window');
    });

    testWidgets('F11 switches it; Settings › Appearance has it', (tester) async {
      final window = FakeWindow();
      final fixture = makeFixture(window: window);
      addTearDown(fixture.dispose);
      final model = fixture.model;
      await pumpLauncher(tester, model);
      await press(tester, LogicalKeyboardKey.f11);
      expect(window.asked, [false], reason: 'full screen by default: F11 goes back to a window');
      model.open(Layer.settings);
      final appearance = model.panelCategories().first.rows.map((row) => row.id);
      expect(appearance, contains('fullscreen'));
      await settle(tester);
      expect(find.text('Full screen'), findsWidgets);
    });
  });

  group('window buttons', () {
    late FakeWindow window;
    late List<int> quits;
    late AppModel model;
    late TestGesture mouse;

    Finder buttons() => find.byKey(const ValueKey('window-buttons'));
    Finder button(String id) => find.byKey(ValueKey('window-$id'));
    bool shown(WidgetTester tester) => !tester.widget<IgnorePointer>(buttons()).ignoring;

    Future<void> start(WidgetTester tester) async {
      window = FakeWindow();
      quits = [];
      final fixture = makeFixture(window: window, quit: quits.add);
      addTearDown(fixture.dispose);
      model = fixture.model;
      await model.applyLauncherWindow();
      await pumpLauncher(tester, model);
      mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(800, 450));
      addTearDown(mouse.removePointer);
    }

    Future<void> moveTo(WidgetTester tester, Offset to) async {
      await mouse.moveTo(to);
      await settle(tester);
    }

    Future<void> click(WidgetTester tester, String id) async {
      await moveTo(tester, tester.getCenter(button(id)));
      await mouse.down(tester.getCenter(button(id)));
      await mouse.up();
      await settle(tester);
    }

    testWidgets('full screen, the pointer at the top edge brings them down; they go up when it leaves', (tester) async {
      await start(tester);
      expect(model.windowFullscreen, isTrue);
      expect(shown(tester), isFalse);
      await moveTo(tester, const Offset(1200, 1));
      expect(shown(tester), isTrue);
      await moveTo(tester, tester.getCenter(button('minimize')));
      expect(find.text('Minimize'), findsOneWidget, reason: 'the button under the pointer says what it does');
      await click(tester, 'minimize');
      expect(window.minimized, 1);
      await moveTo(tester, const Offset(800, 450));
      expect(shown(tester), isFalse, reason: 'a moment after the pointer leaves');
      await tester.tapAt(const Offset(1200, 2));
      await settle(tester);
      expect(window.minimized, 1, reason: 'hidden, they take no clicks');
    });

    testWidgets('Leave full screen makes a window with the system\'s title bar, and they are gone; Quit quits', (
      tester,
    ) async {
      await start(tester);
      await moveTo(tester, const Offset(1200, 1));
      await click(tester, 'windowed');
      expect(window.asked.last, isFalse);
      expect(model.windowFullscreen, isFalse);
      expect(buttons(), findsNothing, reason: 'a window has the system\'s own buttons');
      await model.setLauncherFullscreen(true);
      await settle(tester);
      await moveTo(tester, const Offset(800, 450));
      await moveTo(tester, const Offset(1200, 1));
      await click(tester, 'quit');
      expect(quits, [0]);
    });

    testWidgets('Settings › Appearance turns them off; on by default', (tester) async {
      await start(tester);
      expect(model.preferences.windowButtons, isTrue);
      model.open(Layer.settings);
      final row = model.panelCategories().first.rows.firstWhere((row) => row.id == 'windowButtons');
      (row.kind as ToggleRow).set(false);
      expect(Preferences.fromJson(model.preferences.toJson()).windowButtons, isFalse);
      model.closeOverlay();
      await settle(tester);
      expect(buttons(), findsNothing);
      await moveTo(tester, const Offset(1200, 1));
      expect(buttons(), findsNothing);
    });
  });

  group('settings with a controller', () {
    late Fixture fixture;
    late AppModel model;
    late FakePads pads;

    setUp(() {
      pads = FakePads();
      fixture = makeFixture(pads: () => pads);
      model = fixture.model..startPads();
      model.open(Layer.settings);
    });
    tearDown(() {
      model.dispose();
      fixture.dispose();
    });

    test('← goes to the sections, ↑ ↓ change the section there, → goes back into its rows', () {
      expect(model.panelSections, isFalse);
      pads.press(PadButton.dpadLeft);
      expect(model.panelSections, isTrue);
      pads.press(PadButton.dpadDown);
      expect(model.panelCategory, 1);
      pads.press(PadButton.dpadDown);
      expect(model.panelCategory, 2);
      pads.press(PadButton.dpadUp);
      expect(model.panelCategory, 1);
      pads.press(PadButton.dpadRight);
      expect(model.panelSections, isFalse);
      pads.press(PadButton.dpadDown);
      expect(model.panelRow, greaterThan(0), reason: 'in the rows ↓ moves between rows');
      expect(model.panelCategory, 1);
    });

    test('the left stick does the same as the D-pad', () {
      pads.send!(const PadAxisEvent('pad', PadAxis.leftX, -0.9));
      pads.send!(const PadAxisEvent('pad', PadAxis.leftX, 0));
      expect(model.panelSections, isTrue);
      pads.send!(const PadAxisEvent('pad', PadAxis.leftY, 0.9));
      pads.send!(const PadAxisEvent('pad', PadAxis.leftY, 0));
      expect(model.panelCategory, 1);
    });

    test('L1 and R1 still change the section from anywhere; Circle on the sections closes', () {
      pads.press(PadButton.r1);
      expect(model.panelCategory, 1);
      pads.press(PadButton.dpadLeft);
      pads.press(PadButton.l1);
      expect(model.panelCategory, 0);
      pads.press(PadButton.east);
      expect(model.overlay, isNull);
    });

    test('a value row does not change when highlighted or on ← →; ✕ edits it, ✕ or ○ leaves', () {
      final theme = model.preferences.theme;
      expect(model.panelCategories().first.rows[model.panelRow].id, 'theme');
      pads.press(PadButton.dpadRight);
      expect(model.preferences.theme, theme, reason: '→ on the row changes nothing');
      expect(model.editingValue, isNull);
      pads.press(PadButton.south);
      expect(model.editingValue, 'theme');
      pads.press(PadButton.dpadRight);
      expect(model.preferences.theme, theme + 1);
      pads.press(PadButton.dpadLeft);
      expect(model.preferences.theme, theme);
      expect(model.panelSections, isFalse, reason: 'in edit mode ← is the value, not the sections');
      pads.press(PadButton.dpadRight);
      pads.press(PadButton.east);
      expect(model.editingValue, isNull);
      expect(model.overlay, Layer.settings, reason: 'Circle leaves edit mode, not the settings');
      expect(model.preferences.theme, theme + 1, reason: 'the value stays');
      pads.press(PadButton.dpadRight);
      expect(model.preferences.theme, theme + 1);
      pads.press(PadButton.south);
      pads.press(PadButton.south);
      expect(model.editingValue, isNull, reason: 'Cross leaves it too');
    });

    test('↓ in edit mode leaves it and moves on; a toggle still flips with ✕', () {
      pads.press(PadButton.south);
      expect(model.editingValue, 'theme');
      pads.press(PadButton.dpadDown);
      expect(model.editingValue, isNull);
      expect(model.panelRow, 1);
      final rows = model.panelCategories().first.rows;
      final toggle = rows.indexWhere((row) => row.kind is ToggleRow);
      while (model.panelRow < toggle) {
        pads.press(PadButton.dpadDown);
      }
      final before = (rows[toggle].kind as ToggleRow).value;
      pads.press(PadButton.south);
      expect((model.panelCategories().first.rows[toggle].kind as ToggleRow).value, !before);
    });

    test('the keyboard keeps its ways: → changes the value at once, ← on an action row changes the section', () {
      final theme = model.preferences.theme;
      model.usedKeyboard();
      model.command(Command.right);
      expect(model.preferences.theme, theme + 1);
      expect(model.editingValue, isNull);
      expect(model.panelSections, isFalse);
    });

    test('game settings: the window mode only changes in edit mode', () {
      model.closeOverlay();
      model.open(Layer.gameSettings);
      final game = model.selectedGame!;
      expect(model.panelCategories().first.rows.first.id, 'display');
      pads.press(PadButton.dpadRight);
      pads.press(PadButton.dpadLeft);
      expect(model.currentSettings(game).fullscreen, isFalse);
      expect(model.currentSettings(game).ownFullscreen, isNull);
      pads.press(PadButton.south);
      pads.press(PadButton.dpadRight);
      expect(model.currentSettings(game).ownFullscreen, isFalse, reason: 'Default, then Window');
      pads.press(PadButton.dpadRight);
      expect(model.currentSettings(game).fullscreen, isTrue);
    });
  });

  group('input-aware hints', () {
    testWidgets('a controller hides the keys, the keys hide the controller\'s glyphs, live', (tester) async {
      final pads = FakePads();
      final fixture = makeFixture(pads: () => pads);
      addTearDown(fixture.dispose);
      final model = fixture.model..startPads();
      addTearDown(model.dispose);
      await pumpLauncher(tester, model);
      expect(model.inputMode, InputMode.keyboardMouse);
      expect(find.text('Enter'), findsOneWidget);
      expect(find.text('Q'), findsOneWidget);
      expect(find.byType(PadGlyphIcon), findsNothing, reason: 'no pad glyphs while the keys are in use');
      pads.press(PadButton.dpadDown);
      await settle(tester);
      expect(model.inputMode, InputMode.pad);
      expect(find.text('Enter'), findsNothing);
      expect(find.text('Q'), findsNothing);
      expect(find.text('L1'), findsOneWidget);
      expect(find.byType(PadGlyphIcon), findsWidgets);
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(model.inputMode, InputMode.keyboardMouse);
      expect(find.text('Enter'), findsOneWidget);
    });

    testWidgets('with a controller the ‹ › arrows show only in edit mode; Back shows ○, not Esc', (tester) async {
      final pads = FakePads();
      final fixture = makeFixture(pads: () => pads);
      addTearDown(fixture.dispose);
      final model = fixture.model..startPads();
      addTearDown(model.dispose);
      model.open(Layer.settings);
      await pumpLauncher(tester, model);
      expect(find.byKey(const ValueKey('theme-next')), findsOneWidget);
      expect(find.text('Esc'), findsWidgets);
      pads.press(PadButton.dpadDown);
      pads.press(PadButton.dpadUp);
      await settle(tester);
      expect(find.byKey(const ValueKey('theme-next')), findsNothing);
      expect(find.text('Esc'), findsNothing);
      pads.press(PadButton.south);
      await settle(tester);
      expect(find.byKey(const ValueKey('theme-next')), findsOneWidget, reason: 'edit mode shows them');
    });
  });

  group('PS', () {
    late Fixture fixture;
    late AppModel model;
    late FakePads pads;
    late FakeDesktop desktop;
    late List<int> quits;

    setUp(() {
      pads = FakePads();
      desktop = FakeDesktop();
      quits = [];
      fixture = makeFixture(pads: () => pads, desktop: desktop, quit: quits.add);
      model = fixture.model..startPads();
    });
    tearDown(() {
      model.dispose();
      fixture.dispose();
    });

    Future<({Future<void> done})> startOrbit() async {
      final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
      final installed = Installer.installedFolder(orbit, model.root!);
      File(p.join(installed, 'app.elf')).writeAsStringSync('#!/bin/sh\nsleep 5\n');
      if (!Platform.isWindows) Process.runSync('chmod', ['755', p.join(installed, 'app.elf')]);
      model.select(model.games.indexOf(orbit));
      final playing = model.play(orbit);
      await until(() => model.running != null);
      desktop.calls.clear();
      return (done: playing);
    }

    Future<void> holdGuide() async {
      pads.hold(PadButton.guide);
      await Future<void>.delayed(ShortcutTiming.hold + const Duration(milliseconds: 50));
      pads.release(PadButton.guide);
    }

    test('held in the launcher: the home menu, Switch profile, Quit AnyPS5', () async {
      desktop.focused = true;
      await holdGuide();
      expect(model.overlay, Layer.homeMenu);
      final rows = model.panelCategories().single.rows;
      expect(rows.map((row) => row.id), ['switchProfile', 'quit']);
      expect(rows.first.focusable, isTrue, reason: 'Switch profile opens "Who\'s playing?"');
      pads.press(PadButton.south);
      expect(model.overlay, Layer.profilePicker);
      pads.press(PadButton.east);
      await holdGuide();
      pads.press(PadButton.dpadDown);
      pads.press(PadButton.south);
      expect(quits, [0]);
    });

    test('a short press in the launcher does not open the home menu', () async {
      desktop.focused = true;
      model.open(Layer.settings);
      pads.press(PadButton.guide);
      expect(model.overlay, isNull, reason: 'PS closes the layer, as before');
    });

    test('in a game: the game\'s Options pressed, then the launcher with the quick menu', () async {
      final playing = (await startOrbit()).done;
      desktop.focused = false;
      pads.press(PadButton.guide);
      await until(() => desktop.calls.contains('raise'));
      expect(desktop.calls, ['key Escape', 'raise'], reason: 'Options is Escape by default, pressed first');
      expect(model.overlay, Layer.quickMenu);
      expect(model.panelCategories().single.rows.map((row) => row.id), ['resume', 'gameSettings', 'closeGame']);
      desktop.focused = true;
      pads.press(PadButton.south);
      expect(model.overlay, isNull);
      await until(() => desktop.calls.contains('focus'));
      expect(model.running, isNotNull, reason: 'Resume keeps the game');
      model.stopGame();
      await playing;
    }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);

    test('Pause game when opening the menu off: no key; Circle resumes; Close game closes', () async {
      model.preferences.pauseOnMenu = false;
      final playing = (await startOrbit()).done;
      desktop.focused = false;
      pads.press(PadButton.guide);
      await until(() => model.overlay == Layer.quickMenu);
      expect(desktop.calls, ['raise']);
      desktop.focused = true;
      pads.press(PadButton.east);
      expect(model.overlay, isNull);
      desktop.focused = false;
      await Future<void>.delayed(GuideSwitch.defaultDebounce);
      pads.press(PadButton.guide);
      await until(() => model.overlay == Layer.quickMenu);
      desktop.focused = true;
      pads.press(PadButton.dpadDown);
      pads.press(PadButton.dpadDown);
      pads.press(PadButton.south);
      expect(model.overlay, Layer.closeGame, reason: 'Close game asks first');
      pads.press(PadButton.south);
      await playing;
      expect(model.running, isNull);
      expect(model.overlay, isNull);
    }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);

    test('an engine that takes presses: Options held on player 1 through the bridge, no key typed', () async {
      await model.startPhoneServer();
      final game = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      final got = <Uint8List>[];
      game.listen((event) {
        if (event == RawSocketEvent.read) got.add(game.receive()!.data);
      });
      game.send(
        RemotePacket.hello(player: 1, takesPresses: true),
        InternetAddress.loopbackIPv4,
        model.remote!.bridgePorts.first,
      );
      await until(() => model.remote!.gameTakesPresses);
      final playing = (await startOrbit()).done;
      // A running game says hello every second.
      game.send(
        RemotePacket.hello(player: 1, takesPresses: true),
        InternetAddress.loopbackIPv4,
        model.remote!.bridgePorts.first,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      desktop.focused = false;
      pads.press(PadButton.guide);
      await until(() => desktop.calls.contains('raise'));
      expect(desktop.calls, ['raise'], reason: 'no key into the window');
      expect(got.where((data) => data.length == RemotePacket.pressSize), hasLength(3));
      expect(model.quickMenuPaused, isTrue);
      game.close();
      model.stopGame();
      await playing;
      await model.stopPhoneServer();
    }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);

    test('a remapped Options key is the one pressed', () async {
      final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
      model.saveSettings(
        orbit,
        model
            .currentSettings(orbit)
            .copyWith(
              controls: {
                'Options': ['KEY:P'],
              },
            ),
      );
      final playing = (await startOrbit()).done;
      desktop.focused = false;
      pads.press(PadButton.guide);
      await until(() => desktop.calls.contains('raise'));
      expect(desktop.calls.first, 'key P');
      model.stopGame();
      await playing;
    }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);

    test('held in a game: Close game? straight away; Cancel goes back to the game', () async {
      final playing = (await startOrbit()).done;
      desktop.focused = false;
      await holdGuide();
      expect(model.overlay, Layer.closeGame);
      expect(desktop.calls, ['raise'], reason: 'no pause key for the question');
      desktop.focused = true;
      expect(model.panelCategories().single.rows.map((row) => row.id), ['confirmClose', 'cancel']);
      pads.press(PadButton.dpadDown);
      pads.press(PadButton.south);
      expect(model.overlay, isNull);
      await until(() => desktop.calls.contains('focus'));
      desktop.focused = false;
      await holdGuide();
      expect(model.overlay, Layer.closeGame);
      desktop.focused = true;
      pads.press(PadButton.south);
      await playing;
      expect(model.running, isNull);
    }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);
  });

  group('Hide the launcher while a game runs', () {
    late Fixture fixture;
    late AppModel model;
    late FakePads pads;
    late FakeDesktop desktop;
    late FakeWindow window;

    setUp(() {
      pads = FakePads();
      desktop = FakeDesktop();
      window = FakeWindow();
      fixture = makeFixture(pads: () => pads, desktop: desktop, window: window);
      model = fixture.model..startPads();
    });
    tearDown(() {
      model.dispose();
      fixture.dispose();
    });

    Future<({Future<void> done})> startOrbit() async {
      final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
      final installed = Installer.installedFolder(orbit, model.root!);
      File(p.join(installed, 'app.elf')).writeAsStringSync('#!/bin/sh\nsleep 5\n');
      if (!Platform.isWindows) Process.runSync('chmod', ['755', p.join(installed, 'app.elf')]);
      model.select(model.games.indexOf(orbit));
      final playing = model.play(orbit);
      await until(() => model.running != null);
      return (done: playing);
    }

    test('off by default: the window stays', () async {
      expect(model.preferences.hideWhilePlaying, isFalse);
      final playing = (await startOrbit()).done;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(window.minimized, 0);
      model.stopGame();
      await playing;
      expect(window.restored, 0);
    }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);

    test('on: minimized once the game starts, back from PS, aside again on Resume, back when it closes', () async {
      model.open(Layer.settings);
      final row = model
          .panelCategories()
          .firstWhere((category) => category.id == 'general')
          .rows
          .firstWhere((row) => row.id == 'hide');
      (row.kind as ToggleRow).set(true);
      model.closeOverlay();
      expect(Preferences.fromJson(model.preferences.toJson()).hideWhilePlaying, isTrue, reason: 'kept');
      final playing = (await startOrbit()).done;
      await until(() => window.minimized == 1);
      expect(model.hiddenForGame, isTrue);
      desktop.focused = false;
      model.preferences.pauseOnMenu = false;
      pads.press(PadButton.guide);
      await until(() => model.overlay == Layer.quickMenu && desktop.calls.contains('raise'));
      expect(window.restored, 1, reason: 'the quick menu brings the window back first');
      desktop.focused = true;
      pads.press(PadButton.south);
      await until(() => window.minimized == 2);
      model.stopGame();
      await playing;
      expect(window.restored, 2, reason: 'back when the game closes');
      expect(model.hiddenForGame, isFalse);
    }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);
  });

  group('Share and the replay buffer', () {
    late Fixture fixture;
    late AppModel model;
    late FakePads pads;
    late FakeDesktop desktop;
    late List<String> saved;

    setUp(() {
      pads = FakePads();
      desktop = FakeDesktop();
      saved = [];
      fixture = makeFixture(
        pads: () => pads,
        desktop: desktop,
        replay: (seconds) => ReplayBuffer(
          ffmpeg: 'ffmpeg',
          folder: p.join(Directory.systemTemp.path, 'anyps5-replay-test-${DateTime.now().microsecondsSinceEpoch}'),
          seconds: seconds,
          system: HostSystem.linux,
          start: (_, _) async => FakeProcess(),
          run: (_, arguments) async {
            if (arguments.contains('concat')) saved.add(arguments.last);
            File(arguments.last)
              ..parent.createSync(recursive: true)
              ..writeAsStringSync('mp4');
            return ProcessResult(1, 0, '', '');
          },
        ),
      );
      model = fixture.model..startPads();
    });
    tearDown(() {
      model.dispose();
      fixture.dispose();
    });

    Future<({Future<void> done})> startOrbit() async {
      final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
      final installed = Installer.installedFolder(orbit, model.root!);
      File(p.join(installed, 'app.elf')).writeAsStringSync('#!/bin/sh\nsleep 5\n');
      if (!Platform.isWindows) Process.runSync('chmod', ['755', p.join(installed, 'app.elf')]);
      model.select(model.games.indexOf(orbit));
      final playing = model.play(orbit);
      await until(() => model.running != null);
      desktop.calls.clear();
      return (done: playing);
    }

    test('off by default; with it off Share takes a screenshot into the game\'s gallery', () async {
      expect(model.preferences.replayBuffer, isFalse);
      final playing = (await startOrbit()).done;
      desktop.focused = false;
      pads.press(PadButton.misc);
      await until(() => desktop.calls.contains('capture'));
      final game = model.running!.$1;
      await until(() => model.screenshotsOf(game).any((shot) => !shot.contains('trophy')));
      expect(model.replayRecording, isFalse);
      model.stopGame();
      await playing;
    }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);

    test('on: Share saves the last minute as a clip in the gallery, held a screenshot', () async {
      model.preferences.replayBuffer = true;
      final playing = (await startOrbit()).done;
      await until(() => model.replayRecording);
      final game = model.running!.$1;
      // A segment recorded, as ffmpeg would.
      final folder = Directory.systemTemp.listSync().whereType<Directory>().firstWhere(
        (directory) => p.basename(directory.path).startsWith('anyps5-replay-test-'),
      );
      File(p.join(folder.path, 'segment000.ts')).writeAsStringSync('ts');
      desktop.focused = false;
      pads.press(PadButton.misc);
      await until(() => saved.isNotEmpty);
      expect(p.basename(saved.single), matches(RegExp(r'^PPSA01001-clip-\d{8}-\d{6}\.mp4$')));
      expect(p.dirname(saved.single), Screenshots.folderFor(model.paths.pictures, game));
      expect(model.screenshotsOf(game).where(Screenshots.isClip), hasLength(1));
      pads.hold(PadButton.misc);
      await Future<void>.delayed(ShortcutTiming.hold + const Duration(milliseconds: 50));
      pads.release(PadButton.misc);
      await until(() => desktop.calls.contains('capture'));
      model.stopGame();
      await playing;
      await until(() => !model.replayRecording);
    }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);

    test('the setting shows the cost and its lengths; kept', () {
      model.open(Layer.settings);
      final captures = model.panelCategories().firstWhere((category) => category.id == 'captures');
      expect(captures.rows.first.detail, contains('CPU'));
      expect(captures.rows.map((row) => row.id), isNot(contains('replayLength')));
      model.preferences.replayBuffer = true;
      final lengths = model.panelCategories().firstWhere((category) => category.id == 'captures').rows[1];
      expect((lengths.kind as ChoiceRow).options, ['30 s', '1 min', '3 min', '5 min']);
      final json = Preferences.fromJson(model.preferences.toJson());
      expect(json.replayBuffer, isTrue);
      expect(json.replaySeconds, 60);
    });

    testWidgets('a clip shows in the gallery and opens in the launcher\'s viewer, not the system player', (
      tester,
    ) async {
      final game = model.selectedGame!;
      final clip = Screenshots.clipPath(model.paths.pictures, game, DateTime(2026, 10, 26, 12));
      File(clip)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('mp4');
      model.open(Layer.gallery);
      expect(model.galleryShots, contains(clip));
      model.galleryIndex = model.galleryShots.indexOf(clip);
      final opened = fixture.opened.length;
      model.handle(Command.select);
      expect(model.galleryViewing, isTrue);
      expect(fixture.opened, hasLength(opened));
      // No player in this launcher: the viewer shows the clip's picture.
      await pumpLauncher(tester, model);
      expect(find.byKey(const ValueKey('clip-badge')), findsWidgets);
    });
  });

  group('shortcuts', () {
    late Fixture fixture;
    late AppModel model;
    late FakePads pads;
    late FakeWindow window;

    setUp(() {
      pads = FakePads();
      window = FakeWindow();
      fixture = makeFixture(pads: () => pads, window: window);
      model = fixture.model..startPads();
      model.open(Layer.settings);
      model.selectCategory(model.panelCategories().indexWhere((category) => category.id == 'shortcuts'));
    });
    tearDown(() {
      model.dispose();
      fixture.dispose();
    });

    int rowOf(LauncherAction action) =>
        model.panelCategories()[model.panelCategory].rows.indexWhere((row) => row.id == 'shortcut-${action.name}');

    testWidgets('a key: chosen, pressed, kept, and run in the launcher', (tester) async {
      await pumpLauncher(tester, model);
      model.activateRow(rowOf(LauncherAction.toggleFullscreen));
      expect(model.shortcutCapture, LauncherAction.toggleFullscreen);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(tester);
      expect(model.shortcutCapture, isNull);
      expect(
        model.preferences.shortcuts[LauncherAction.toggleFullscreen].key,
        KeyCombo(LogicalKeyboardKey.keyF.keyId, control: true),
      );
      expect(find.text('Ctrl+F'), findsOneWidget);
      await press(tester, LogicalKeyboardKey.f11);
      expect(window.asked, isEmpty, reason: 'F11 is free now');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(tester);
      expect(window.asked, [false]);
    });

    testWidgets('a key another action has, or one AnyPS5 moves with, is refused and said', (tester) async {
      await pumpLauncher(tester, model);
      model.activateRow(rowOf(LauncherAction.screenshot));
      await press(tester, LogicalKeyboardKey.f11);
      expect(model.preferences.shortcuts[LauncherAction.screenshot].key, isNull);
      expect(model.toast, 'Already used by Full screen');
      model.activateRow(rowOf(LauncherAction.screenshot));
      await press(tester, LogicalKeyboardKey.enter);
      expect(model.toast, contains('AnyPS5 moves with'));
      model.activateRow(rowOf(LauncherAction.screenshot));
      await press(tester, LogicalKeyboardKey.escape);
      expect(model.shortcutCapture, isNull, reason: 'Esc cancels');
      expect(model.overlay, Layer.settings, reason: 'and does not close the settings');
      model.activateRow(rowOf(LauncherAction.nextSection));
      await press(tester, LogicalKeyboardKey.backspace);
      expect(model.shortcutCapture, isNull);
      expect(model.preferences.shortcuts[LauncherAction.nextSection].key, isNull, reason: 'Backspace clears the key');
      expect(model.preferences.shortcuts[LauncherAction.nextSection].pad, PadChord.of(PadButton.r1));
      await tester.pump(const Duration(seconds: 5));
    });

    test('buttons together: a chord, held a long press; Circle alone cancels; it acts at once', () async {
      model.panelRow = rowOf(LauncherAction.quickMenu);
      pads.press(PadButton.south);
      expect(model.shortcutCapture, LauncherAction.quickMenu);
      pads.release(PadButton.south);
      pads.hold(PadButton.select);
      pads.hold(PadButton.start);
      pads.release(PadButton.start);
      pads.release(PadButton.select);
      expect(model.preferences.shortcuts[LauncherAction.quickMenu].pad, PadChord({PadButton.select, PadButton.start}));
      expect(model.overlay, Layer.settings, reason: 'Options in the chord did not also act');

      model.panelRow = rowOf(LauncherAction.screenshot);
      pads.press(PadButton.south);
      pads.press(PadButton.east);
      expect(model.shortcutCapture, isNull);
      expect(model.preferences.shortcuts[LauncherAction.screenshot].pad, PadChord.of(PadButton.misc, hold: true));

      pads.press(PadButton.south);
      pads.hold(PadButton.r3);
      await Future<void>.delayed(ShortcutTiming.hold + const Duration(milliseconds: 50));
      pads.release(PadButton.r3);
      expect(model.preferences.shortcuts[LauncherAction.screenshot].pad, PadChord.of(PadButton.r3, hold: true));
      expect(model.panelCategories()[model.panelCategory].rows[model.panelRow].kind, isA<ShortcutRow>());

      // Triangle alone while waiting clears the controller's binding; the key stays.
      model.panelRow = rowOf(LauncherAction.previousSection);
      pads.press(PadButton.south);
      pads.press(PadButton.north);
      expect(model.shortcutCapture, isNull);
      expect(model.preferences.shortcuts[LauncherAction.previousSection].pad, isNull);
      expect(model.preferences.shortcuts[LauncherAction.previousSection].key, const KeyCombo(KeyIds.q));
    });

    test('a chord another action has is refused; Triangle clears the binding of the input in use', () {
      model.panelRow = rowOf(LauncherAction.quickMenu);
      pads.press(PadButton.south);
      pads.press(PadButton.misc);
      expect(model.preferences.shortcuts[LauncherAction.quickMenu].pad, isNull);
      expect(model.toast, 'Already used by Save clip');
      model.panelRow = rowOf(LauncherAction.nextSection);
      pads.press(PadButton.north);
      expect(
        model.preferences.shortcuts[LauncherAction.nextSection].pad,
        isNull,
        reason: 'the pad was in use: R1 goes',
      );
      expect(model.preferences.shortcuts[LauncherAction.nextSection].key, const KeyCombo(KeyIds.e), reason: 'E stays');
      expect(model.overlay, Layer.settings);
    });

    test('reset to defaults; the game\'s own buttons are linked', () {
      model.preferences.shortcuts = ShortcutMap().withBinding(LauncherAction.home, const ShortcutBinding());
      final rows = model.panelCategories()[model.panelCategory].rows;
      expect(rows.map((row) => row.id), containsAll(['gameControls', 'shortcutsReset']));
      model.activateRow(rows.indexWhere((row) => row.id == 'shortcutsReset'));
      expect(model.preferences.shortcuts.isDefault, isTrue);
      model.activateRow(rows.indexWhere((row) => row.id == 'gameControls'));
      expect(model.overlay, Layer.controls);
    });

    test('a remapped section shortcut moves the settings and the home screen', () {
      model.preferences.shortcuts = model.preferences.shortcuts.withBinding(
        LauncherAction.nextSection,
        ShortcutBinding(pad: PadChord.of(PadButton.r2)),
      );
      model.savePreferences();
      final category = model.panelCategory;
      pads.press(PadButton.r1);
      expect(model.panelCategory, category, reason: 'R1 is nothing now');
      pads.press(PadButton.r2);
      expect(model.panelCategory, category + 1);
    });

    test('kept in the preferences', () {
      model.preferences.shortcuts = model.preferences.shortcuts.withBinding(
        LauncherAction.quickMenu,
        ShortcutBinding(pad: PadChord({PadButton.l3, PadButton.r3})),
      );
      final back = Preferences.fromJson(model.preferences.toJson());
      expect(back.shortcuts[LauncherAction.quickMenu].pad, PadChord({PadButton.l3, PadButton.r3}));
    });
  });

  test('every new text is in both languages', () {
    final keys = [
      'quickResume',
      'quickCloseGame',
      'closeGameTitle',
      'switchProfile',
      'quitLauncher',
      'launcherFullscreen',
      'pauseOnMenu',
      'replayBuffer',
      'shortcuts',
      'shortcutHeld',
      'captures',
    ];
    for (final language in T.languages) {
      T.language = language;
      for (final key in keys) {
        expect(T.text(key), isNot(key), reason: '$key in ${language.code}');
      }
    }
    T.language = Language.byCode('tr');
    expect(T.text('quickResume'), 'Devam et');
    expect(AppModel.padLabel(PadChord.of(PadButton.misc, hold: true)), 'Share (basılı)');
  });

  testWidgets('the phone pill\'s latency keeps one width from 1 ms to 999 ms', (tester) async {
    await tester.runAsync(loadFonts);
    final widths = <double>[];
    for (final ms in [3.0, 23.0, 230.0, 999.0, 4000.0]) {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(child: PhoneIndicator.latency(ms, 1, false)),
        ),
      );
      widths.add(tester.getSize(find.byType(Stack).first).width);
    }
    expect(widths.toSet(), hasLength(1), reason: '$widths');
    expect(find.text('999 ms'), findsWidgets, reason: 'more than 999 shows as 999');
  });
}
