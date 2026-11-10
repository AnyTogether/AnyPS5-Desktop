import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/desktop/desktop.dart';
import 'package:anyps5_desktop/core/gamepad/feel.dart';
import 'package:anyps5_desktop/core/gamepad/guide_switch.dart';
import 'package:anyps5_desktop/core/gamepad/pad_navigation.dart';
import 'package:anyps5_desktop/core/installer.dart';
import 'package:anyps5_desktop/core/screenshots.dart';
import 'package:anyps5_desktop/core/toolkit_download.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_github.dart';
import '../support/signing.dart';
import '../support/trophy_fixture.dart';
import '../support/ui_support.dart';

/// What the launcher asked of the desktop.
class FakeDesktop implements DesktopWindows {
  final List<String> calls = [];
  final List<RgbaImage> cards = [];
  bool cardsWork = true;

  /// What each notice card was drawn with, and whether this desktop can draw one.
  final List<(String, String?)> noticeCards = [];
  bool canShow = true;

  /// Each desktop notice's title and text.
  final List<(String, String)> notified = [];

  @override
  bool get canShowCard => canShow;

  @override
  Future<bool> showBadge(RgbaImage? badge, {int? pid}) async {
    calls.add(badge == null ? 'badge-off' : 'badge');
    return true;
  }

  /// How the badge stays out of the picture here: none, unless a test says.
  BadgeReach reach = BadgeReach.none;

  @override
  BadgeReach get badgeReach => reach;

  @override
  Future<bool> raiseLauncher() async {
    calls.add('raise');
    return true;
  }

  @override
  Future<bool> focusGame(int pid) async {
    calls.add('focus');
    return true;
  }

  /// Whether the launcher's window is the one in front, as the desktop sees it (null: it cannot
  /// tell).
  bool? focused;

  @override
  bool? launcherFocused() => focused;

  @override
  Future<bool> applyDisplay(int pid, {required bool fullscreen, required int windowSize}) async {
    calls.add('display ${fullscreen ? 'fullscreen' : '$windowSize%'}');
    return true;
  }

  @override
  Future<bool> pressKey(int pid, String key, {Duration hold = const Duration(milliseconds: 100)}) async {
    calls.add('key $key');
    return true;
  }

  @override
  Future<RgbaImage?> captureGame(int pid) async {
    calls.add('capture');
    return RgbaImage(2, 1, Uint8List.fromList([10, 20, 30, 255, 40, 50, 60, 255]));
  }

  @override
  double cardScale(int? pid) => 1;

  @override
  Future<bool> showCard(RgbaImage card, {int? pid}) async {
    calls.add('card');
    cards.add(card);
    return cardsWork;
  }

  @override
  Future<bool> notify(String title, String body, {String? icon}) async {
    calls.add('notify $body');
    notified.add((title, body));
    return true;
  }

  @override
  void dispose() {}
}

class FakePads implements PadSource, PadRumble {
  void Function(PadEvent)? send;

  /// What the launcher set the motors to: "pad strong weak ms".
  final List<String> rumbles = [];

  @override
  PadRumble? get motors => this;
  @override
  bool canRumble(String pad) => true;
  @override
  void rumble(String pad, double strong, double weak, Duration length) =>
      rumbles.add('$pad $strong $weak ${length.inMilliseconds}');

  @override
  void start(void Function(PadEvent event) onEvent) => send = onEvent;
  @override
  void stop() => send = null;
  @override
  String get description => 'fake';

  void press(PadButton button) {
    send!(PadButtonEvent('pad', button, down: true));
    send!(PadButtonEvent('pad', button, down: false));
  }

  void hold(PadButton button) => send!(PadButtonEvent('pad', button, down: true));
  void release(PadButton button) => send!(PadButtonEvent('pad', button, down: false));
}

void main() {
  tearDown(() => T.language = Language.english);

  Future<void> until(bool Function() condition, {int tries = 500}) async {
    for (var index = 0; index < tries && !condition(); index++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(condition(), isTrue);
  }

  group('controller', () {
    late Fixture fixture;
    late AppModel model;
    late FakePads pads;
    late FakeDesktop desktop;

    setUp(() {
      pads = FakePads();
      desktop = FakeDesktop();
      fixture = makeFixture(pads: () => pads, desktop: desktop);
      model = fixture.model..startPads();
    });

    tearDown(() {
      model.dispose();
      fixture.dispose();
    });

    test('the pad moves through the launcher as the keys do', () {
      final first = model.selected;
      pads.press(PadButton.r1);
      expect(model.selected, first + 1);
      pads.press(PadButton.l1);
      expect(model.selected, first);
      pads.press(PadButton.north);
      expect(model.overlay, Layer.gameSettings, reason: 'Triangle opens the options');
      pads.press(PadButton.dpadDown);
      expect(model.panelRow, 1);
      pads.press(PadButton.east);
      expect(model.overlay, isNull, reason: 'Circle goes back');
    });

    test('L1 and R1 move between the settings\' categories', () {
      model.open(Layer.settings);
      pads.press(PadButton.r1);
      expect(model.panelCategory, 1);
    });

    test('behind another window only PS counts, and it brings the launcher in front', () {
      model.setActive(false);
      final selected = model.selected;
      pads.press(PadButton.r1);
      pads.press(PadButton.south);
      expect(model.selected, selected);
      expect(desktop.calls, isEmpty);
      pads.press(PadButton.guide);
      expect(desktop.calls, ['raise']);
    });

    test('a game in front keeps the pad out of the launcher, even while Flutter says it has the focus', () {
      // What happened on Windows: the launcher still thought it was in front behind the game,
      // and Cross in the game pressed what the launcher had focused.
      expect(model.active, isTrue);
      desktop.focused = false;
      final selected = model.selected;
      pads.press(PadButton.r1);
      pads.press(PadButton.dpadRight);
      pads.press(PadButton.south);
      pads.press(PadButton.north);
      expect(model.selected, selected);
      expect(model.overlay, isNull);
      expect(model.focus, HomeFocus.tiles);
      expect(desktop.calls, isEmpty);
      pads.press(PadButton.guide);
      expect(desktop.calls, ['raise'], reason: 'PS still brings the launcher in front');
    });

    test('back in front, what was held in the game waits to be let go', () {
      desktop.focused = false;
      pads.hold(PadButton.north);
      pads.hold(PadButton.dpadDown);
      desktop.focused = true;
      pads.release(PadButton.north);
      pads.release(PadButton.dpadDown);
      expect(model.overlay, isNull, reason: 'Triangle went down in the game: letting go of it opens nothing');
      expect(model.focus, HomeFocus.tiles);
      pads.press(PadButton.north);
      expect(model.overlay, Layer.gameSettings, reason: 'a new press counts');
    });

    test('the PS press that brought the launcher in front does not act in it again', () {
      model.open(Layer.settings);
      desktop.focused = false;
      pads.press(PadButton.guide);
      expect(desktop.calls, ['raise'], reason: 'PS acts when it is let go');
      // Held from behind as the launcher came in front (Alt+Tab): letting go of it there does nothing.
      pads.hold(PadButton.guide);
      desktop.focused = true;
      pads.release(PadButton.guide);
      expect(model.overlay, Layer.settings, reason: 'PS in front closes a layer; letting go of it does not');
      expect(desktop.calls, ['raise']);
    });

    test('a desktop that cannot tell leaves it to Flutter\'s focus', () {
      desktop.focused = null;
      final selected = model.selected;
      pads.press(PadButton.r1);
      expect(model.selected, selected + 1);
      model.setActive(false);
      pads.press(PadButton.r1);
      expect(model.selected, selected + 1);
    });

    test('while a game runs, PS goes from the game to the launcher and back', () async {
      final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
      final installed = Installer.installedFolder(orbit, model.root!);
      File(p.join(installed, 'app.elf')).writeAsStringSync('#!/bin/sh\nsleep 2\n');
      if (!Platform.isWindows) Process.runSync('chmod', ['755', p.join(installed, 'app.elf')]);
      model.select(model.games.indexOf(orbit));
      final playing = model.play(orbit);
      await until(() => model.running != null);
      model.setActive(false);
      pads.press(PadButton.guide);
      await until(() => desktop.calls.contains('raise'));
      model.setActive(true);
      await Future<void>.delayed(GuideSwitch.defaultDebounce);
      pads.press(PadButton.guide);
      expect(desktop.calls.where((call) => call == 'raise' || call == 'focus'), ['raise', 'focus']);
      expect(desktop.calls.first, 'display 75%', reason: 'upstream\'s engine: the launcher sizes the window');
      model.stopGame();
      await playing;
    }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);

    Future<({Future<void> done})> startOrbit({String script = 'sleep 2'}) async {
      final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
      final installed = Installer.installedFolder(orbit, model.root!);
      File(p.join(installed, 'app.elf')).writeAsStringSync('#!/bin/sh\n$script\n');
      if (!Platform.isWindows) Process.runSync('chmod', ['755', p.join(installed, 'app.elf')]);
      model.select(model.games.indexOf(orbit));
      final playing = model.play(orbit);
      await until(() => model.running != null);
      return (done: playing);
    }

    test('PS toggles game and launcher: one press is one switch, also read twice', () async {
      final playing = await startOrbit();
      desktop.calls.clear();
      // The game's pause key before the quick menu is not what this is about.
      model.preferences.pauseOnMenu = false;
      desktop.focused = false;
      pads.press(PadButton.guide);
      await until(() => desktop.calls.isNotEmpty);
      expect(desktop.calls, ['raise']);
      desktop.focused = true;
      pads.press(PadButton.guide);
      expect(desktop.calls, ['raise'], reason: 'the same press seen twice (or a bounce) does not switch back');
      await Future<void>.delayed(GuideSwitch.defaultDebounce);
      pads.press(PadButton.guide);
      expect(desktop.calls, ['raise', 'focus'], reason: 'the next press takes the game back in front');
      desktop.focused = false;
      await Future<void>.delayed(GuideSwitch.defaultDebounce);
      pads.press(PadButton.guide);
      await until(() => desktop.calls.length == 3);
      expect(desktop.calls, ['raise', 'focus', 'raise']);
      model.stopGame();
      await playing.done;
    }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);

    test('PS goes back to the game even while Flutter has not yet said the launcher has the focus', () async {
      final playing = await startOrbit();
      desktop.calls.clear();
      // Just raised: Windows has the launcher in front, Flutter's focus report has not arrived.
      model.setActive(false);
      desktop.focused = true;
      pads.press(PadButton.guide);
      expect(desktop.calls, ['focus']);
      model.stopGame();
      await playing.done;
    }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);

    test('the game is started reading the controllers only while its window is in front', () async {
      final seen = p.join(fixture.temp.path, 'sdl-hint.txt');
      final playing = await startOrbit(script: 'echo "\$SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS" > "$seen"; sleep 1');
      await until(() => File(seen).existsSync() && File(seen).readAsStringSync().trim().isNotEmpty);
      expect(File(seen).readAsStringSync().trim(), '0');
      model.stopGame();
      await playing.done;
    }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);

    test('on Windows too, the game process gets the variable that keeps its pad to its own window', () async {
      // A copy of cmd.exe stands in for the game: it reads what to do from its input.
      final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
      final installed = Installer.installedFolder(orbit, model.root!);
      final cmd = File(p.join(Platform.environment['SystemRoot'] ?? r'C:\Windows', 'System32', 'cmd.exe'));
      for (final name in ['app.exe', 'app.elf']) {
        cmd.copySync(p.join(installed, name));
      }
      final seen = p.join(fixture.temp.path, 'sdl-hint.txt');
      model.select(model.games.indexOf(orbit));
      final playing = model.play(orbit);
      await until(() => model.running != null);
      model.running!.$2.process.stdin.writeln('(echo %SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS%)> "$seen" & exit');
      await playing;
      expect(File(seen).readAsStringSync().trim(), '0');
    }, skip: Platform.isWindows ? false : 'Windows only (the other systems run the shell script one)');

    test('behind a game the launcher rests, and wakes when it is in front again', () async {
      final playing = await startOrbit();
      expect(model.resting, isFalse);
      desktop.focused = false;
      model.checkFront();
      expect(model.resting, isTrue, reason: 'Flutter still says in front; the desktop knows better');
      desktop.focused = true;
      model.checkFront();
      expect(model.resting, isFalse);
      model.stopGame();
      await playing.done;
    }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);
  });

  group('controller feel', () {
    late Fixture fixture;
    late AppModel model;
    late FakePads pads;
    late FakeDesktop desktop;

    setUp(() {
      pads = FakePads();
      desktop = FakeDesktop();
      fixture = makeFixture(pads: () => pads, desktop: desktop);
      model = fixture.model..startPads();
    });

    tearDown(() {
      model.dispose();
      fixture.dispose();
    });

    Future<List<String>> felt() async {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      final seen = [...pads.rumbles];
      pads.rumbles.clear();
      return seen;
    }

    test('select and back pulse in the pad that pressed them, then the motors stop', () async {
      pads.press(PadButton.north);
      expect(model.overlay, Layer.gameSettings);
      expect(await felt(), ['pad 0.0 0.42 18', 'pad 0.0 0.0 0'], reason: 'opening the options is a select');
      pads.press(PadButton.east);
      expect(await felt(), ['pad 0.0 0.3 14', 'pad 0.0 0.0 0']);
    });

    test('the end of the row bumps once, barely', () async {
      model.select(0);
      pads.press(PadButton.dpadLeft);
      expect(model.selected, 0);
      expect(await felt(), ['pad 0.0 0.2 12', 'pad 0.0 0.0 0']);
      pads.press(PadButton.dpadRight);
      expect(model.selected, 1);
      expect(await felt(), isEmpty, reason: 'moving the focus has no pulse');
    });

    test('nothing while the keyboard is in use, a game is in front or the setting is off', () async {
      model.usedKeyboard();
      model.command(Command.options);
      expect(await felt(), isEmpty, reason: 'the controller on the desk stays still');
      model.command(Command.back);
      pads.press(PadButton.north);
      await felt();
      model.setActive(false);
      model.vibrate(HapticCue.trophy);
      expect(await felt(), isEmpty, reason: 'the game owns the pad');
      model.setActive(true);
      model.preferences.controllerVibration = false;
      model.haptics.enabled = false;
      pads.press(PadButton.east);
      expect(await felt(), isEmpty);
    });

    test('no pulse with a game in front, even while Flutter says the launcher has the focus', () async {
      pads.press(PadButton.north);
      pads.press(PadButton.east);
      await felt();
      desktop.focused = false;
      model.vibrate(HapticCue.trophy);
      model.vibrate(HapticCue.ring);
      pads.press(PadButton.south);
      pads.press(PadButton.dpadLeft);
      expect(await felt(), isEmpty, reason: 'the game owns the pad');
      desktop.focused = true;
      pads.press(PadButton.north);
      expect(await felt(), isNotEmpty, reason: 'back in front, the pad pulses again');
    });

    test('Controller Vibration is a Behaviour setting, on by default, kept', () {
      expect(model.preferences.controllerVibration, isTrue);
      model.open(Layer.settings);
      final behaviour = model.panelCategories().firstWhere((category) => category.id == 'general');
      expect(behaviour.rows.map((row) => row.id), contains('vibration'));
      final json = model.preferences.toJson();
      expect(json['controllerVibration'], isTrue);
      expect(Preferences.fromJson({...json, 'controllerVibration': false}).controllerVibration, isFalse);
      expect(Preferences.fromJson({}).controllerVibration, isTrue);
    });
  });

  group('trophies while playing', () {
    late Fixture fixture;
    late AppModel model;
    late FakeDesktop desktop;

    setUp(() {
      desktop = FakeDesktop();
      fixture = makeFixture(
        desktop: desktop,
        renderTrophyCard: (trophy, scale) async => RgbaImage(1, 1, Uint8List.fromList([1, 2, 3, 4])),
        renderNoticeCard: (title, detail, symbol, scale) async {
          desktop.noticeCards.add((title, detail));
          return RgbaImage(1, 1, Uint8List.fromList([1, 2, 3, 4]));
        },
      );
      model = fixture.model;
    });

    tearDown(() {
      model.dispose();
      fixture.dispose();
    });

    test('a trophy earned in the game: a picture of the game first, then the card over it', () async {
      final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
      final installed = Installer.installedFolder(orbit, model.root!);
      File(p.join(installed, 'app.elf')).writeAsStringSync('#!/bin/sh\nsleep 6\n');
      if (!Platform.isWindows) Process.runSync('chmod', ['755', p.join(installed, 'app.elf')]);
      final playing = model.play(orbit);
      await until(() => model.running != null);
      writeTrophies(orbit.folder, installed: installed, earned: [1, 2, 3]);
      await until(() => desktop.calls.contains('card'), tries: 400);
      expect(desktop.calls.where((call) => call == 'capture' || call == 'card'), ['capture', 'card']);
      final shots = Screenshots.list(model.paths.pictures, orbit);
      expect(shots, hasLength(1));
      expect(p.basename(shots.single), startsWith('PPSA01001-trophy0_3-'));
      expect(File(shots.single).readAsBytesSync().sublist(1, 4), 'PNG'.codeUnits);
      expect(model.trophyShots['0/3'], shots.single);
      model.stopGame();
      await playing;
    }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);

    test('a game playing: the main button brings it to the front', () async {
      final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
      final installed = Installer.installedFolder(orbit, model.root!);
      File(p.join(installed, 'app.elf')).writeAsStringSync('#!/bin/sh\nsleep 6\n');
      if (!Platform.isWindows) Process.runSync('chmod', ['755', p.join(installed, 'app.elf')]);
      final playing = model.play(orbit);
      await until(() => model.running != null);
      desktop.calls.clear();
      model.primaryAction(orbit);
      await until(() => desktop.calls.contains('focus'));
      expect(model.stopping, isFalse);
      model.stopGame();
      await playing;
    }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);

    test('a notice while the game is in front is a card, and a notification where no card can be drawn', () async {
      final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
      final installed = Installer.installedFolder(orbit, model.root!);
      File(p.join(installed, 'app.elf')).writeAsStringSync('#!/bin/sh\nsleep 6\n');
      if (!Platform.isWindows) Process.runSync('chmod', ['755', p.join(installed, 'app.elf')]);
      final playing = model.play(orbit);
      await until(() => model.running != null);
      List<String> notices() => desktop.calls.where((call) => call == 'card' || call.startsWith('notify')).toList();
      desktop.focused = false;
      desktop.calls.clear();
      await model.noticeOverGame('Ana sent an invite', detail: 'Friends');
      expect(desktop.noticeCards.single, ('Ana sent an invite', 'Friends'));
      expect(notices(), ['card'], reason: 'the card, and no desktop notice as well');
      // No window can go over the game here (Wayland): the desktop notice says it.
      desktop.canShow = false;
      desktop.calls.clear();
      await model.noticeOverGame('Ana sent an invite', detail: 'Friends');
      expect(notices(), ['notify Friends']);
      // A card that could not be shown after all falls back too.
      desktop
        ..canShow = true
        ..cardsWork = false;
      desktop.calls.clear();
      await model.noticeOverGame('Ana sent an invite');
      expect(notices(), ['card', 'notify AnyPS5']);
      // The launcher in front: its toast is enough.
      desktop.focused = true;
      desktop.calls.clear();
      await model.noticeOverGame('Ana sent an invite');
      expect(notices(), isEmpty);
      model.stopGame();
      await playing;
    }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);

    test('with no game playing, no card: a notification over whatever is in front', () async {
      desktop.focused = false;
      await model.noticeOverGame('Ana sent an invite', detail: 'Friends');
      expect(desktop.noticeCards, isEmpty);
      expect(desktop.calls.last, 'notify Friends');
    });

    test('where no card can be shown, a notification says it', () async {
      desktop.cardsWork = false;
      final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
      final trophy = model.trophies[orbit.id]!.trophies.first;
      await model.celebrate(orbit, trophy, 1);
      expect(desktop.calls.last, 'notify ${trophy.name}');
    });
  });

  group('AnyPS5-ARM engine', () {
    final key = TestReleaseKey('release');
    late FakeGitHub upstream;
    late FakeGitHub arm;
    late Fixture fixture;
    late AppModel model;

    setUp(() async {
      upstream = await FakeGitHub.start();
      arm = await FakeGitHub.start(repository: ArmToolkitPackage.repository);
      fixture = makeFixture(engine: upstream.api, armEngine: arm.api, armKeys: [key.key]);
      model = fixture.model;
    });

    tearDown(() async {
      model.dispose();
      await upstream.close();
      await arm.close();
      fixture.dispose();
    });

    PanelRow row(String id) => model
        .panelCategories()
        .expand((category) => category.rows)
        .firstWhere((row) => row.id == id, orElse: () => throw StateError('no row $id'));

    test(
      'chosen in Settings, downloaded from AnyPS5-ARM\'s releases, in use; the game\'s window settings are its own',
      () async {
        arm.releases.add(signed(armRelease('v0.2.17-arm', '26d785b'), [key]));
        final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
        model.select(model.games.indexOf(orbit));
        model.open(Layer.gameSettings);
        expect(row('display').detail, T.text('displayUpstream'), reason: 'upstream\'s engine is in use');
        model.closeOverlay();

        model.open(Layer.settings);
        model.panelCategory = model.panelCategories().indexWhere((category) => category.id == 'engine');
        final source = row('engineSource').kind as ChoiceRow;
        expect(source.selected, 0);
        source.set(1);
        expect(model.preferences.engineSource, 'arm');
        await until(() => model.engine.armChecked);
        expect(model.engine.armPackage?.commit, '26d785b');
        (row('engineDownload').kind as ActionRow).run();
        await until(() => model.engine.downloading == null && model.toolkitVersion == 'arm-26d785b');
        expect(model.engine.readsDisplaySettings, isTrue);
        expect(row('engineCurrent').kind, isA<InfoRow>().having((info) => info.text, 'text', 'AnyPS5-ARM 26d785b'));

        model.open(Layer.gameSettings);
        expect(row('display').detail, T.text('displayBorderless'), reason: 'the ARM engine opens it borderless');
        model.closeOverlay();

        // Back to upstream: the settings offer it again, the ARM engine stays downloaded.
        model.open(Layer.settings);
        model.panelCategory = model.panelCategories().indexWhere((category) => category.id == 'engine');
        (row('engineSource').kind as ChoiceRow).set(0);
        expect(model.preferences.engineSource, 'upstream');
        expect(model.engine.downloaded.map((kit) => p.basename(kit.root)), contains('arm-26d785b'));
      },
    );

    test('no engine for this system yet: the settings say so', () async {
      arm.releases.add(signed(armRelease('v0.2.17-arm', '26d785b', linux: false), [key]));
      model.engine.chooseSource(true);
      await until(() => model.engine.armChecked);
      model.open(Layer.settings);
      model.panelCategory = model.panelCategories().indexWhere((category) => category.id == 'engine');
      expect(row('engineCheck').detail, T.text('engineArmNone'));
    });
  });
}
