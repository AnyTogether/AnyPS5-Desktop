import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:anyps5_desktop/core/desktop/window_backdrop.dart';
import 'package:anyps5_desktop/core/together/profiles.dart';
import 'package:anyps5_desktop/core/trophies.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/background.dart';
import 'package:anyps5_desktop/ui/components.dart' show LayoutScale;
import 'package:anyps5_desktop/ui/glass.dart';
import 'package:anyps5_desktop/ui/home.dart';
import 'package:anyps5_desktop/ui/launcher.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:anyps5_desktop/ui/theme.dart';
import 'package:anyps5_desktop/ui/trophy_card.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fixtures.dart';
import '../support/ui_support.dart';
import 'together_interface_test.dart' show signedInPreview;

/// The Glass look: its place among the looks and in the preferences, the contrast its recipe
/// promises, and its screens.
void main() {
  tearDown(() {
    T.language = Language.english;
    Motion.reduced = false;
  });

  group('the look', () {
    test('Glass is the fourth look, kept as 3; anything unknown is Cosmic', () {
      expect(LookStyle.glass.index, 3);
      expect(LookStyle.values.take(3), [LookStyle.cosmic, LookStyle.aurora, LookStyle.sunset]);
      expect(LookStyle.fromIndex(3), LookStyle.glass);
      for (final unknown in [-1, 4, 99, null, '3', 2.5]) {
        expect(LookStyle.fromIndex(unknown), LookStyle.cosmic, reason: '$unknown');
      }
    });

    test('its colors, name and default accent match the Mac', () {
      expect(LookStyle.hex(LookStyle.glass.deep), '#04101C');
      expect(LookStyle.hex(LookStyle.glass.middle), '#1C4F73');
      expect(LookStyle.hex(LookStyle.glass.bright), '#CFEFFF');
      expect(LookStyle.glass.defaultAccent, Accent.ice);
      expect(LookStyle.hex(Accent.ice.color), '#8AD8FF');
      expect(Accent.ice.index, Accent.values.length - 1, reason: 'new accents go last');
      expect(LookStyle.glass.title, 'Glass');
      expect(Accent.ice.title, 'Ice');
      T.language = Language.byCode('tr');
      expect(LookStyle.glass.title, 'Cam');
      expect(Accent.ice.title, 'Buz');
    });

    test('saved as 3 and read back; garbage reads as Cosmic and keeps the other choices', () {
      final temp = temporaryFolder('glass-prefs');
      addTearDown(() => temp.deleteSync(recursive: true));
      final file = p.join(temp.path, 'preferences.json');
      final saved = Preferences()
        ..theme = LookStyle.glass.index
        ..reduceTransparency = true
        ..profileName = 'Utku';
      saved.save(file);
      expect((jsonDecode(File(file).readAsStringSync()) as Map)['theme'], 3);
      final read = Preferences.load(file);
      expect(read.theme, 3);
      expect(read.reduceTransparency, isTrue);

      for (final garbage in [99, -4, 'glass', 3.7, null, true]) {
        final json = {...saved.toJson(), 'theme': garbage};
        File(file).writeAsStringSync(jsonEncode(json));
        final back = Preferences.load(file);
        expect(back.theme, garbage == 3.7 ? 3 : LookStyle.cosmic.index, reason: '$garbage');
        expect(back.profileName, 'Utku', reason: 'the rest of the file still counts ($garbage)');
      }
    });

    test('the model wears Glass with the Ice accent, and a theme index it does not know as Cosmic', () {
      final fixture = makeFixture(theme: 3);
      addTearDown(fixture.dispose);
      final model = fixture.model;
      expect(model.look, LookStyle.glass);
      expect(model.builtInAccent, Accent.ice);
      model.preferences.theme = 42;
      expect(model.look, LookStyle.cosmic);
      expect(model.builtInAccent, Accent.blue);
    });

    test('choosing Glass in the settings resets the accent to Ice; Reduce transparency shows only there', () {
      final fixture = makeFixture();
      addTearDown(fixture.dispose);
      final model = fixture.model;
      model.preferences.accent = Accent.gold.name;
      model.open(Layer.settings);
      List<String> rows() => model.panelCategories().first.rows.map((row) => row.id).toList();
      expect(rows(), isNot(contains('transparency')));
      for (var step = 0; step < 3; step++) {
        model.handle(Command.right);
      }
      expect(model.preferences.theme, 3);
      expect(model.look, LookStyle.glass);
      expect(model.builtInAccent, Accent.ice);
      expect(rows(), containsAllInOrder(['theme', 'transparency', 'accent']));
      expect(model.solidGlass, isFalse);
      model.panelRow = rows().indexOf('transparency');
      model.handle(Command.select);
      expect(model.preferences.reduceTransparency, isTrue);
      expect(model.solidGlass, isTrue);
    });

    test('a GPU too slow for the blur turns Glass solid once, with a word; other looks are left alone', () {
      final fixture = makeFixture(theme: 3);
      addTearDown(fixture.dispose);
      final model = fixture.model;
      model.glassTooSlow();
      expect(model.glassFallback, isTrue);
      expect(model.solidGlass, isTrue);
      expect(model.toast, T.text('glassFallback'));
      final cosmic = makeFixture();
      addTearDown(cosmic.dispose);
      cosmic.model.glassTooSlow();
      expect(cosmic.model.glassFallback, isFalse);
    });

    test('a new install starts in Cosmic: Glass is picked, never the default', () {
      expect(LookStyle.fromIndex(Preferences().theme), LookStyle.cosmic);
      expect(LookStyle.fromIndex(Preferences.fromJson(const {}).theme), LookStyle.cosmic);
      final fresh = makeFixture(onboarded: false);
      addTearDown(fresh.dispose);
      expect(fresh.model.look, LookStyle.cosmic);
      expect(fresh.model.onboardingChoice, 0, reason: 'the first start offers the language first');
      fresh.model.onboardingConfirm();
      expect(fresh.model.onboardingChoice, LookStyle.cosmic.index, reason: 'the theme step starts on Cosmic');
    });

    test('a GPU found too slow for Glass is remembered: the next start is solid until Glass is picked again', () {
      final fixture = makeFixture(theme: 3);
      addTearDown(fixture.dispose);
      fixture.model.glassTooSlow();
      expect(fixture.model.preferences.glassTooSlow, isTrue);
      final kept = Preferences.fromJson(
        jsonDecode(jsonEncode(fixture.model.preferences.toJson())) as Map<String, dynamic>,
      );
      expect(kept.glassTooSlow, isTrue);
      expect(Preferences.fromJson(const {}).glassTooSlow, isFalse);
      expect(Preferences().toJson().containsKey('glassTooSlow'), isFalse, reason: 'only written once it happened');

      final next = makeFixture(theme: 3);
      addTearDown(next.dispose);
      final model = next.model;
      model.preferences.glassTooSlow = true;
      model.glassFallback = model.preferences.glassTooSlow;
      expect(model.solidGlass, isTrue);
      model.open(Layer.settings);
      final rows = model.panelCategories().first.rows;
      final theme = rows.firstWhere((row) => row.id == 'theme').kind as ChoiceRow;
      theme.set(LookStyle.glass.index);
      expect(model.preferences.glassTooSlow, isFalse, reason: 'picking Glass again gives it another try');
      expect(model.solidGlass, isFalse);
    });

    test('the raster watch trips only when most frames of two windows in a row are slow', () {
      var slow = 0;
      final watch = RasterWatch(onSlow: () => slow++, window: 10);
      const fast = Duration(milliseconds: 6);
      const late = Duration(milliseconds: 16);
      watch.add([for (var i = 0; i < 10; i++) i < 7 ? late : fast]);
      watch.add([for (var i = 0; i < 10; i++) i < 4 ? late : fast]);
      expect(slow, 0, reason: 'a window under the share starts over');
      watch.add(List.filled(10, late));
      expect(slow, 0, reason: 'one slow window is a stutter');
      watch.add(List.filled(10, late));
      expect(slow, 1);
      watch.add(List.filled(40, late));
      expect(slow, 1, reason: 'once');
      final again = RasterWatch(onSlow: () => slow++, window: 10)..add(List.filled(10, late));
      again
        ..reset()
        ..add(List.filled(10, late));
      expect(slow, 1, reason: 'a reset forgets the first window');
    });

    test('a run of frames that drag (under 25 a second) trips the watch at once', () {
      var slow = 0;
      final watch = RasterWatch(onSlow: () => slow++);
      const dragging = Duration(milliseconds: 70);
      watch.add([...List.filled(7, dragging), const Duration(milliseconds: 5), ...List.filled(7, dragging)]);
      expect(slow, 0, reason: 'one quick frame between breaks the run');
      watch.add([dragging]);
      expect(slow, 1, reason: 'eight in a row');
      expect(watch.tripped, isTrue);
    });
  });

  group('contrast (WCAG 2)', () {
    const white = Color(0xFFFFFFFF);
    const scrimNavy = GlassRecipe.layer;

    test('ink on the accents: dark on the light ones', () {
      for (final accent in Accent.values) {
        final light = Contrast.luminance(accent.color) > 0.4;
        expect(accent.ink, light ? Contrast.darkInk : Contrast.lightInk, reason: accent.name);
      }
      expect(Accent.ice.ink, Contrast.darkInk);
      expect(Contrast.ratio(Accent.ice.ink, Accent.ice.color), greaterThan(4.5));
      expect(Contrast.ratio(const Color(0xFF000000), white), closeTo(21, 0.01));
      expect(Contrast.ratio(white, white), 1);
    });

    test('white text on glass over the frosted picture\'s brightest pixel, under the lightest veil', () {
      // The brightest the picture can be (a white pixel: the ice tint keeps lightness), under the
      // thinnest part of the veil (the right edge, upper half), then the glass at its sheen.
      final thinnest = [
        for (var x = 0.0; x <= 1; x += 0.05)
          for (var y = 0.0; y <= 1; y += 0.05) GlassRecipe.veilAt(x, y),
      ].reduce(math.min);
      expect(thinnest, closeTo(GlassRecipe.veil, 1e-9));
      final backdrop = GlassRecipe.over(scrimNavy, thinnest, GlassRecipe.artworkCeiling);
      final surface = GlassRecipe.surfaceOver(backdrop);
      expect(Contrast.ratio(white, surface), greaterThanOrEqualTo(4.5));
    });

    test('the focused ice chip\'s ink, over the darkest and the brightest backdrops', () {
      for (final backdrop in [const Color(0xFF000000), white, LookStyle.glass.bright]) {
        final chip = GlassRecipe.over(white, GlassRecipe.chipTo, backdrop);
        expect(Contrast.ratio(GlassRecipe.ink, chip), greaterThanOrEqualTo(4.5), reason: '$backdrop');
      }
    });

    test('a full-screen layer over the brightest picture, then a panel on it', () {
      final layer = GlassRecipe.over(scrimNavy, GlassRecipe.layerOpacity, GlassRecipe.artworkCeiling);
      final panel = GlassRecipe.surfaceOver(layer);
      expect(Contrast.ratio(white, panel), greaterThanOrEqualTo(4.5));
      // The rows' detail text, at 72 % white.
      expect(Contrast.ratio(GlassRecipe.over(white, 0.72, panel), panel), greaterThanOrEqualTo(4.5));
    });

    testWidgets('white text on glass over the background shader\'s brightest pixel', (tester) async {
      await tester.runAsync(() async {
        await loadFonts();
        await ThemeBackground.preload();
      });
      tester.view.physicalSize = const Size(800, 450);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var brightest = const Color(0xFF000000);
      for (final time in [0.0, 120.0, 900.0, 2400.0]) {
        await tester.pumpWidget(
          RepaintBoundary(
            key: const ValueKey('background'),
            child: ThemeBackground(style: LookStyle.glass, time: time),
          ),
        );
        final pixels = await tester.runAsync(() async {
          final image = await captureImage(find.byKey(const ValueKey('background')).evaluate().single);
          final data = await image.toByteData();
          image.dispose();
          return data!;
        });
        for (var offset = 0; offset < pixels!.lengthInBytes; offset += 4) {
          final color = Color.fromARGB(
            255,
            pixels.getUint8(offset),
            pixels.getUint8(offset + 1),
            pixels.getUint8(offset + 2),
          );
          if (Contrast.luminance(color) > Contrast.luminance(brightest)) brightest = color;
        }
      }
      expect(Contrast.luminance(brightest), greaterThan(0.005), reason: 'the shader drew');
      final surface = GlassRecipe.surfaceOver(brightest);
      expect(Contrast.ratio(white, surface), greaterThanOrEqualTo(4.5), reason: 'brightest $brightest');
      expect(Contrast.ratio(GlassRecipe.over(white, 0.72, surface), surface), greaterThanOrEqualTo(4.5));
    });
  });

  group('golden', () {
    late Fixture fixture;

    tearDown(() => fixture.dispose());

    int indexOf(AppModel model, String titleId) => model.games.indexWhere((game) => game.titleId == titleId);

    /// Orbit Runner's key art: a bright sky, a sun and a planet, so the frosting shows.
    void keyArt(AppModel model) {
      final game = model.games[indexOf(model, 'PPSA01001')];
      File(p.join(game.folder, 'sce_sys', 'pic0.png')).writeAsBytesSync(
        png(320, 180, (x, y) {
          final t = y / 180;
          double disc(double cx, double cy, double r) =>
              math.max(0, 1 - math.sqrt(math.pow(x - cx, 2) + math.pow(y - cy, 2)) / r);
          final sun = disc(250, 50, 70);
          final planet = disc(110, 150, 90);
          int channel(double sky, double sunTint, double planetTint) =>
              (sky * (1 - t) + 40 * t + 255 * sun * sunTint + 200 * planet * planetTint).round().clamp(0, 255);
          return channel(255, 1, 0.9) << 24 | channel(150, 0.85, 0.3) << 16 | channel(70, 0.4, 0.8) << 8 | 0xFF;
        }),
      );
    }

    Future<void> shoot(WidgetTester tester, String name) =>
        expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/$name.png'));

    testWidgets('resting glass is drawn once and kept; a window being resized never keeps more than the cap', (
      tester,
    ) async {
      fixture = makeFixture(theme: 3);
      final model = fixture.model;
      await pumpLauncher(tester, model);
      final kept = iceCacheLength;
      expect(kept, greaterThan(0), reason: 'the cards, buttons and pills at rest are pictures now');
      model.refresh();
      await tester.pump();
      await tester.pump();
      expect(iceCacheLength, kept, reason: 'a frame with nothing new draws from what is kept');
      for (var width = 1000; width <= 1900; width += 30) {
        tester.view.physicalSize = Size(width.toDouble(), width * 9 / 16);
        await tester.pump();
      }
      expect(iceCacheBytes, lessThanOrEqualTo(48 << 20));
    });

    testWidgets('home, an installed game selected, its picture frosted', (tester) async {
      fixture = makeFixture(theme: 3);
      final model = fixture.model;
      keyArt(model);
      model.select(indexOf(model, 'PPSA01001'));
      await pumpLauncher(tester, model);
      await shoot(tester, 'glass_home');
      // The cards' labels (72 % white) keep AA contrast over the brightest picture where the
      // cards are: the veil there is the left-to-right one and the bottom one together.
      final cards = find.byType(InfoCard).evaluate().map((element) => tester.getRect(find.byWidget(element.widget)));
      final worst = Offset(
        cards.map((rect) => rect.right).reduce(math.max),
        cards.map((rect) => rect.top).reduce(math.min),
      );
      final veil = GlassRecipe.veilAt(worst.dx / 1600, worst.dy / 900);
      final surface = GlassRecipe.surfaceOver(GlassRecipe.over(GlassRecipe.layer, veil, GlassRecipe.artworkCeiling));
      const white = Color(0xFFFFFFFF);
      expect(Contrast.ratio(GlassRecipe.over(white, 0.72, surface), surface), greaterThanOrEqualTo(4.5));
      // The phone pill's words (90 % white) in the top bar, under the thinnest veil.
      final pill = GlassRecipe.surfaceOver(
        GlassRecipe.over(GlassRecipe.layer, GlassRecipe.veil, GlassRecipe.artworkCeiling),
      );
      expect(Contrast.ratio(GlassRecipe.over(white, 0.9, pill), pill), greaterThanOrEqualTo(4.5));
    });

    testWidgets('home, in Turkish, a locked game with the unlock button focused', (tester) async {
      fixture = makeFixture(theme: 3, language: Language.byCode('tr'));
      final model = fixture.model;
      model.select(indexOf(model, 'PPSA02002'));
      model.handle(Command.down);
      await pumpLauncher(tester, model);
      expect(find.text('Kilidi aç'), findsOneWidget);
      await shoot(tester, 'glass_home_tr');
    });

    testWidgets('home, the settings button focused, with Reduce transparency', (tester) async {
      fixture = makeFixture(theme: 3);
      final model = fixture.model;
      keyArt(model);
      model.preferences.reduceTransparency = true;
      model.select(indexOf(model, 'PPSA01001'));
      model.handle(Command.up);
      model.handle(Command.up);
      model.handle(Command.right);
      await pumpLauncher(tester, model);
      await shoot(tester, 'glass_home_solid');
    });

    testWidgets('library grid', (tester) async {
      fixture = makeFixture(theme: 3);
      final model = fixture.model;
      keyArt(model);
      model.open(Layer.library);
      model.handle(Command.right);
      await pumpLauncher(tester, model);
      await shoot(tester, 'glass_library');
    });

    testWidgets('game settings, in Turkish', (tester) async {
      fixture = makeFixture(theme: 3, language: Language.byCode('tr'));
      final model = fixture.model;
      keyArt(model);
      model.select(indexOf(model, 'PPSA01001'));
      model.open(Layer.gameSettings);
      model.handle(Command.down);
      await pumpLauncher(tester, model);
      await shoot(tester, 'glass_game_settings_tr');
    });

    testWidgets('settings, appearance', (tester) async {
      fixture = makeFixture(theme: 3);
      final model = fixture.model;
      model.open(Layer.settings);
      await pumpLauncher(tester, model);
      expect(find.text('Glass'), findsOneWidget);
      expect(find.text('Ice'), findsOneWidget);
      expect(find.text('Reduce transparency'), findsOneWidget);
      await shoot(tester, 'glass_settings');
    });

    testWidgets('settings, appearance, in Turkish', (tester) async {
      fixture = makeFixture(theme: 3, language: Language.byCode('tr'));
      final model = fixture.model;
      model.open(Layer.settings);
      model.handle(Command.down);
      await pumpLauncher(tester, model);
      expect(find.text('Cam'), findsOneWidget);
      expect(find.text('Şeffaflığı azalt'), findsOneWidget);
      await shoot(tester, 'glass_settings_tr');
    });

    testWidgets('settings: the focused section\'s glow has room on its left, as on its right', (tester) async {
      fixture = makeFixture(theme: 3);
      final model = fixture.model;
      model.open(Layer.settings);
      model.panelSections = true;
      await pumpLauncher(tester, model);
      final tab = find.byKey(ValueKey('section-${model.panelCategories()[model.panelCategory].id}'));
      final scroll = find.ancestor(of: tab, matching: find.byType(SingleChildScrollView)).first;
      final room = tester.getTopLeft(tab).dx - tester.getTopLeft(scroll).dx;
      expect(room, greaterThanOrEqualTo(14), reason: 'the scrolling box must not cut the glow on the left');
    });

    testWidgets('friends', (tester) async {
      fixture = makeFixture(theme: 3);
      final model = fixture.model;
      signedInPreview(model);
      model.open(Layer.friends);
      await pumpLauncher(tester, model);
      await shoot(tester, 'glass_friends');
    });

    testWidgets('a friend\'s profile, in Turkish', (tester) async {
      fixture = makeFixture(theme: 3, language: Language.byCode('tr'));
      final model = fixture.model;
      keyArt(model);
      signedInPreview(model);
      model.open(Layer.friends);
      model.open(Layer.profile);
      model.together
        ..profileReturn = (layer: Layer.friends, category: null, row: null)
        ..profileIndex = 2
        ..profile = ProfilePage(
          profile: const TogetherProfile(
            userId: 'u-bora',
            handle: 'bora',
            displayName: 'Bora',
            bio: 'Çoğunlukla ortak oyun geceleri.',
            country: 'TR',
            friendship: 'friends',
          ),
          library: SectionShown([
            PlayedGame(
              titleId: 'PPSA02002',
              names: const {'en': 'Neon Alley'},
              lastPlayedAt: DateTime(2026, 10, 24, 21),
              secondsPlayed: 3600 * 42,
              trophiesEarned: 18,
              trophiesTotal: 42,
              progress: 43,
              points: 690,
            ),
            PlayedGame(
              titleId: 'PPSA01001',
              names: const {'en': 'Orbit Runner'},
              lastPlayedAt: DateTime(2026, 10, 2),
              secondsPlayed: 3 * 3600,
              trophiesEarned: 5,
              trophiesTotal: 5,
              progress: 100,
              points: 435,
            ),
          ]),
          trophies: SectionShown([
            EarnedTrophy(
              titleId: 'PPSA01001',
              gameNames: const {'en': 'Orbit Runner'},
              trophyId: 0,
              grade: 'platinum',
              hidden: false,
              names: const {'en': 'Grand Tour'},
              earnedAt: DateTime(2026, 10, 2),
              rarity: 0.031,
              rarityLabel: 'ultra_rare',
            ),
          ]),
        );
      await pumpLauncher(tester, model);
      await shoot(tester, 'glass_profile_tr');
    });

    testWidgets('trophies', (tester) async {
      fixture = makeFixture(theme: 3);
      final model = fixture.model;
      keyArt(model);
      model.select(indexOf(model, 'PPSA01001'));
      model.open(Layer.trophies);
      model.handle(Command.down);
      await pumpLauncher(tester, model);
      await shoot(tester, 'glass_trophies');
    });

    testWidgets('a new game copied in: its toast', (tester) async {
      fixture = makeFixture(theme: 3);
      final model = fixture.model;
      keyArt(model);
      final orbit = model.games[indexOf(model, 'PPSA01001')];
      model.select(indexOf(model, 'PPSA01001'));
      model.show(T.format('newGame', [orbit.name]), icon: orbit.icon);
      await pumpLauncher(tester, model);
      await shoot(tester, 'glass_toast');
      await tester.pump(const Duration(seconds: 5));
    });

    for (final language in [Language.english, Language.byCode('tr')]) {
      testWidgets('the trophy card over a game, ${language.code}', (tester) async {
        fixture = makeFixture(theme: 3);
        T.language = language;
        final trophy = Trophy(
          serviceLabel: 0,
          number: 3,
          grade: TrophyGrade.gold,
          hidden: false,
          name: language == Language.byCode('tr') ? 'Kalenin Kalbine' : 'Into the Citadel',
          detail: language == Language.byCode('tr') ? 'Pharloom\'un kalbine ulaş' : 'Reach the heart of Pharloom',
          icon: iconArt(0xF2C14E, 0x5C3B0B, size: 64),
        );
        final card = await tester.runAsync(() async {
          await loadFonts();
          await ThemeBackground.preload();
          final rgba = await TrophyCard.render(trophy, glass: true);
          final completer = <ui.Image>[];
          ui.decodeImageFromPixels(rgba.pixels, rgba.width, rgba.height, ui.PixelFormat.rgba8888, completer.add);
          while (completer.isEmpty) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
          return completer.single;
        });
        tester.view.physicalSize = const Size(720, 240);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: RepaintBoundary(
              key: const ValueKey('card'),
              // A game behind it: the card is its own window, drawn over whatever runs.
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF3A5A40), Color(0xFF8D6E4A), Color(0xFF2B2D42)],
                  ),
                ),
                child: Center(child: RawImage(image: card)),
              ),
            ),
          ),
        );
        await expectLater(
          find.byKey(const ValueKey('card')),
          matchesGoldenFile('goldens/glass_trophy_card_${language.code}.png'),
        );
        card!.dispose();
      });
    }
  });

  group('the see-through window', () {
    const white = Color(0xFFFFFFFF);
    // Whatever is behind the window: a white page, a yellow, a cyan, a coral, a grey, black.
    const desktops = [
      Color(0xFFFFFFFF),
      Color(0xFFFFFF00),
      Color(0xFF00FFFF),
      Color(0xFFFF6650),
      Color(0xFF808080),
      Color(0xFF000000),
    ];

    test('the tint is light, the Mac\'s: the slider runs from a solid pane down to a breath of navy', () {
      expect(GlassWindow.tintAt(0), 1);
      expect(GlassWindow.tintAt(100), GlassWindow.minimumTint);
      expect(GlassWindow.tintAt(400), GlassWindow.minimumTint);
      expect(GlassWindow.tintAt(100, blurred: false), GlassWindow.sharpMinimumTint);
      expect(GlassWindow.tintAt(40), greaterThan(GlassWindow.tintAt(60)));
      expect(GlassWindow.defaultTransparency, 90);
      // By default most of the desktop's light comes through.
      expect(GlassWindow.tintAt(GlassWindow.defaultTransparency), lessThan(0.15));
    });

    test('text reads on its plates over any desktop at every slider step, with no help from the tint or the blur', () {
      expect(GlassWindow.plateFloor, 0.57, reason: 'the Mac\'s floor');
      expect(GlassWindow.plateOpacity, greaterThanOrEqualTo(GlassWindow.plateFloor));
      for (final blurred in [true, false]) {
        for (var percent = 0; percent <= 100; percent += 10) {
          final tint = GlassWindow.tintAt(percent, blurred: blurred);
          for (final desktop in desktops) {
            final behind = GlassRecipe.over(GlassRecipe.layer, tint, desktop);
            final what = '$percent % over $desktop, blurred $blurred';
            final plates = [
              // A soft plate behind bare text, at its least.
              GlassRecipe.over(GlassRecipe.layer, GlassWindow.plateFloor, behind),
              // A card, a button, a pill: glass raised to a plate.
              GlassRecipe.over(
                white,
                GlassRecipe.sheenFrom,
                GlassRecipe.over(GlassRecipe.base, GlassWindow.plateOpacity, behind),
              ),
            ];
            for (final plate in plates) {
              expect(Contrast.ratio(white, plate), greaterThanOrEqualTo(4.5), reason: what);
              expect(Contrast.ratio(GlassRecipe.over(white, 0.7, plate), plate), greaterThanOrEqualTo(3), reason: what);
            }
          }
        }
      }
    });

    testWidgets('on the see-through window bare text gets its plate and glass is raised to one; not elsewhere', (
      tester,
    ) async {
      Future<List<double>> plates(bool seeThrough) async {
        await tester.pumpWidget(
          LayoutScale(
            scale: 1,
            child: LookScope(
              glass: true,
              solid: false,
              seeThrough: seeThrough,
              child: const Directionality(
                textDirection: TextDirection.ltr,
                child: Legible(child: Text('Games')),
              ),
            ),
          ),
        );
        return [
          for (final paint in tester.widgetList<CustomPaint>(find.byType(CustomPaint)))
            if (paint.painter is PlatePainter) PlatePainter.fill.a,
        ];
      }

      expect(await plates(false), isEmpty);
      final core = await plates(true);
      expect(core, hasLength(1));
      // At its least, 0.94 of the fill reaches the text: still over the floor.
      expect(core.single * 0.94, greaterThanOrEqualTo(GlassWindow.plateFloor));
    });

    test('only Glass, where the system can, with transparency left, lets the desktop through', () {
      GlassWindow make({
        bool glass = true,
        bool solid = false,
        int? transparency,
        BackdropKind kind = BackdropKind.acrylic,
      }) => GlassWindow.make(glass: glass, solid: solid, transparency: transparency, kind: kind);
      expect(make().seeThrough, isTrue);
      expect(make().tint, GlassWindow.tintAt(90));
      expect(make().blurred, isTrue);
      expect(make(kind: BackdropKind.transparent).tint, GlassWindow.tintAt(90, blurred: false));
      expect(make(glass: false), GlassWindow.opaque);
      expect(make(solid: true), GlassWindow.opaque);
      expect(make(transparency: 0), GlassWindow.opaque);
      expect(make(kind: BackdropKind.none), GlassWindow.opaque);
    });

    test('Windows: Acrylic from 11 22H2, the accent policy\'s acrylic before, nothing before 10 1803', () {
      expect(windowsBackdropKind(26200), BackdropKind.acrylic);
      expect(windowsBackdropKind(22621), BackdropKind.acrylic);
      expect(windowsBackdropKind(22000), BackdropKind.accentAcrylic);
      expect(windowsBackdropKind(19045), BackdropKind.accentAcrylic);
      expect(windowsBackdropKind(17134), BackdropKind.accentAcrylic);
      expect(windowsBackdropKind(16299), BackdropKind.none);
      expect(windowsBackdropKind(26200, override: 'accent'), BackdropKind.accentAcrylic);
      expect(windowsBackdropKind(26200, override: 'off'), BackdropKind.none);
      expect(windowsBackdropKind(26200, override: 'kwin'), BackdropKind.acrylic);
      expect(windowsBackdropKind(26200, override: 'nonsense'), BackdropKind.acrylic);
    });

    test(
      'Linux: KWin\'s blur on X11 where it is offered, the bare desktop elsewhere, nothing without a compositor',
      () {
        BackdropKind kind({
          bool wayland = false,
          bool x11 = true,
          bool rgba = true,
          bool compositor = true,
          bool kwin = false,
          String? override,
        }) => linuxBackdropKind(
          wayland: wayland,
          x11: x11,
          rgbaVisual: rgba,
          compositor: compositor,
          kwinBlur: kwin,
          override: override,
        );
        expect(kind(kwin: true), BackdropKind.kwinBlur);
        expect(kind(), BackdropKind.transparent);
        expect(kind(compositor: false), BackdropKind.none);
        expect(kind(wayland: true, x11: false, compositor: false), BackdropKind.transparent);
        expect(kind(rgba: false, kwin: true), BackdropKind.none);
        expect(kind(x11: false), BackdropKind.none);
        expect(kind(kwin: true, override: 'transparent'), BackdropKind.transparent);
        expect(kind(kwin: true, override: 'none'), BackdropKind.none);
      },
    );

    test('the transparency and the picture behind are kept, garbage read as the default', () {
      final temp = temporaryFolder('glass-window');
      addTearDown(() => temp.deleteSync(recursive: true));
      final file = p.join(temp.path, 'preferences.json');
      final saved = Preferences()
        ..theme = 3
        ..glassTransparency = 40
        ..glassArtwork = true;
      File(file).writeAsStringSync(jsonEncode(saved.toJson()));
      final back = Preferences.fromJson(jsonDecode(File(file).readAsStringSync()) as Map<String, dynamic>);
      expect(back.glassTransparency, 40);
      expect(back.glassArtwork, isTrue);
      final garbage = Preferences.fromJson({'theme': 3, 'glassTransparency': 'lots', 'glassArtwork': 'yes'});
      expect(garbage.glassTransparency, isNull);
      expect(garbage.glassArtwork, isFalse);
      expect(Preferences.fromJson({'glassTransparency': 250}).glassTransparency, 100);
    });

    test('the window follows the look: see-through in Glass, opaque again for another look or Reduce transparency', () {
      final backdrop = _FakeBackdrop(BackdropKind.acrylic);
      final fixture = makeFixture(theme: 3, backdrop: backdrop);
      addTearDown(fixture.dispose);
      final model = fixture.model;
      expect(model.glassWindow.seeThrough, isTrue);
      model.applyBackdrop();
      model.applyBackdrop();
      expect(backdrop.calls, [true], reason: 'applied once, not again while nothing changed');
      model.preferences.reduceTransparency = true;
      model.applyBackdrop();
      expect(backdrop.calls, [true, false]);
      model.preferences.reduceTransparency = false;
      model.preferences.theme = 0;
      model.applyBackdrop();
      model.preferences.theme = 3;
      model.applyBackdrop();
      expect(backdrop.calls, [true, false, true]);
      // A GPU too slow for Glass: the window goes opaque with its surfaces.
      model.glassTooSlow();
      model.applyBackdrop();
      expect(backdrop.calls.last, isFalse);
    });

    test('the slider at 0 % is a solid pane: an opaque window and solid surfaces', () {
      final backdrop = _FakeBackdrop(BackdropKind.acrylic);
      final fixture = makeFixture(theme: 3, backdrop: backdrop);
      addTearDown(fixture.dispose);
      final model = fixture.model..preferences.glassTransparency = 0;
      expect(model.solidGlass, isTrue);
      expect(model.glassWindow.seeThrough, isFalse);
      // Where the window could never be see-through, 0 % changes nothing.
      final plain = makeFixture(theme: 3);
      addTearDown(plain.dispose);
      plain.model.preferences.glassTransparency = 0;
      expect(plain.model.solidGlass, isFalse);
    });

    test('before its window shows, the backdrop is tried again', () {
      fakeAsync((async) {
        final backdrop = _FakeBackdrop(BackdropKind.acrylic)..found = false;
        final fixture = makeFixture(theme: 3, backdrop: backdrop);
        fixture.model.applyBackdrop();
        expect(backdrop.calls, [true]);
        backdrop.found = true;
        async.elapse(const Duration(milliseconds: 300));
        expect(backdrop.calls, [true, true]);
        async.elapse(const Duration(seconds: 2));
        expect(backdrop.calls, [true, true]);
        fixture.dispose();
      });
    });

    test('the settings offer the transparency and the picture behind only where the window can be see-through', () {
      List<String> rows(AppModel model) => model.panelCategories().first.rows.map((row) => row.id).toList();
      final glass = makeFixture(theme: 3, backdrop: _FakeBackdrop(BackdropKind.kwinBlur));
      addTearDown(glass.dispose);
      glass.model.open(Layer.settings);
      expect(
        rows(glass.model),
        containsAllInOrder(['theme', 'transparency', 'glassTransparency', 'accent', 'glassArtwork']),
      );
      expect(rows(glass.model), isNot(contains('artwork')));
      final row = glass.model.panelCategories().first.rows.firstWhere((row) => row.id == 'glassTransparency');
      expect(row.detail, T.text('glassTransparencyDetail'));
      expect((row.kind as StepperRow).value, 90);
      (row.kind as StepperRow).set(30);
      expect(glass.model.preferences.glassTransparency, 30);
      expect(glass.model.glassWindow.tint, GlassWindow.tintAt(30));
      (row.kind as StepperRow).set(90);
      expect(glass.model.preferences.glassTransparency, isNull, reason: 'the default is kept as no choice');
      final sharp = makeFixture(theme: 3, backdrop: _FakeBackdrop(BackdropKind.transparent));
      addTearDown(sharp.dispose);
      sharp.model.open(Layer.settings);
      expect(
        sharp.model.panelCategories().first.rows.firstWhere((row) => row.id == 'glassTransparency').detail,
        T.text('glassTransparencySharp'),
      );
      final opaque = makeFixture(theme: 3);
      addTearDown(opaque.dispose);
      opaque.model.open(Layer.settings);
      expect(rows(opaque.model), isNot(contains('glassTransparency')));
      expect(rows(opaque.model), contains('artwork'));
      final cosmic = makeFixture(backdrop: _FakeBackdrop(BackdropKind.acrylic));
      addTearDown(cosmic.dispose);
      cosmic.model.open(Layer.settings);
      expect(rows(cosmic.model), isNot(contains('glassTransparency')));
    });

    group('screens over a mock desktop', () {
      late Fixture fixture;
      int indexOf(AppModel model, String titleId) => model.games.indexWhere((game) => game.titleId == titleId);
      tearDown(() => fixture.dispose());

      // A colourful wallpaper, blurred and dimmed as Acrylic roughly does: a mock, labelled so.
      final wallpaper = png(320, 180, (x, y) {
        double blob(double cx, double cy, double r) =>
            math.max(0, 1 - math.sqrt(math.pow(x - cx, 2) + math.pow(y - cy, 2)) / r);
        final pink = blob(60, 40, 120),
            blue = blob(260, 30, 130),
            green = blob(220, 170, 110),
            gold = blob(40, 170, 90);
        int channel(double base, List<double> parts) =>
            (base + parts.fold(0.0, (sum, part) => sum + part)).round().clamp(0, 255);
        return channel(40, [255 * pink, 40 * blue, 60 * green, 250 * gold]) << 24 |
            channel(30, [60 * pink, 140 * blue, 220 * green, 190 * gold]) << 16 |
            channel(80, [200 * pink, 255 * blue, 120 * green, 40 * gold]) << 8 |
            0xFF;
      });

      Widget desktop(Widget app) => Directionality(
        textDirection: TextDirection.ltr,
        child: RepaintBoundary(
          key: const ValueKey('desktop'),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ImageFiltered(
                imageFilter: ui.ImageFilter.blur(sigmaX: 40, sigmaY: 40, tileMode: TileMode.mirror),
                child: ColorFiltered(
                  colorFilter: const ColorFilter.matrix([
                    0.8, 0, 0, 0, 8, //
                    0, 0.8, 0, 0, 8, //
                    0, 0, 0.8, 0, 12, //
                    0, 0, 0, 1, 0,
                  ]),
                  child: Image.memory(wallpaper, fit: BoxFit.cover),
                ),
              ),
              app,
              const Positioned(
                left: 16,
                bottom: 14,
                child: ColoredBox(
                  color: Color(0xFFFFD60A),
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    child: Text(
                      'MOCK · desktop drawn by the test, blurred by Flutter, not the system\'s Acrylic',
                      style: TextStyle(color: Color(0xFF000000), fontSize: 13, fontFamily: AppText.family),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );

      Future<void> shoot(WidgetTester tester, String name) =>
          expectLater(find.byKey(const ValueKey('desktop')), matchesGoldenFile('goldens/$name.png'));

      testWidgets('home over the desktop, an installed game selected', (tester) async {
        fixture = makeFixture(theme: 3, backdrop: _FakeBackdrop(BackdropKind.acrylic));
        final model = fixture.model;
        model.select(indexOf(model, 'PPSA01001'));
        await pumpLauncher(tester, model, wrap: desktop);
        // No look background and no picture: the desktop is Glass's background.
        expect(find.byType(ThemeBackground), findsNothing);
        expect(find.byType(GameArtwork), findsNothing);
        await shoot(tester, 'glass_window_home');
      });

      testWidgets('the picture behind, laid over the desktop', (tester) async {
        fixture = makeFixture(theme: 3, backdrop: _FakeBackdrop(BackdropKind.acrylic));
        final model = fixture.model..preferences.glassArtwork = true;
        model.select(indexOf(model, 'PPSA01001'));
        await pumpLauncher(tester, model, wrap: desktop);
        expect(find.byType(GameArtwork), findsOneWidget);
        await shoot(tester, 'glass_window_artwork');
      });

      testWidgets('settings, appearance, the transparency focused', (tester) async {
        fixture = makeFixture(theme: 3, backdrop: _FakeBackdrop(BackdropKind.acrylic));
        final model = fixture.model;
        model.open(Layer.settings);
        model.panelRow = model.panelCategories().first.rows.indexWhere((row) => row.id == 'glassTransparency');
        await pumpLauncher(tester, model, wrap: desktop);
        expect(find.text('Glass transparency'), findsOneWidget);
        expect(find.text('Show game art behind'), findsOneWidget);
        await shoot(tester, 'glass_window_settings');
      });
    });
  });

  testWidgets('the onboarding offers Glass beside the other looks', (tester) async {
    final fixture = makeFixture(onboarded: false, withToolkit: false);
    addTearDown(fixture.dispose);
    final model = fixture.model;
    await pumpLauncher(tester, model);
    await press(tester, LogicalKeyboardKey.enter);
    for (var step = 0; step < 3; step++) {
      await press(tester, LogicalKeyboardKey.arrowRight);
    }
    expect(model.preferences.theme, 3);
    expect(model.look, LookStyle.glass);
    expect(find.text('Glass'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'four cards fit the row');
  });
}

/// A window backdrop that remembers what it was asked; [found] false acts as a window not shown
/// yet.
class _FakeBackdrop implements WindowBackdrop {
  _FakeBackdrop(this.kind);

  @override
  final BackdropKind kind;
  final List<bool> calls = [];
  bool found = true;

  @override
  bool apply({required bool seeThrough}) {
    calls.add(seeThrough);
    return found;
  }
}
