import 'dart:io';
import 'dart:ui' show instantiateImageCodec;

import 'package:anyps5_desktop/core/gamepad/pad_navigation.dart';
import 'package:anyps5_desktop/core/installer.dart';
import 'package:anyps5_desktop/core/profiles/profile_saves.dart';
import 'package:anyps5_desktop/core/profiles/profiles.dart';
import 'package:anyps5_desktop/core/together/token_store.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/launcher.dart';
import 'package:anyps5_desktop/ui/profiles_view.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:anyps5_desktop/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_together.dart';
import '../support/ui_support.dart';

/// Profiles in the launcher: the first start's mode, the migration of a launcher set up before,
/// "Who's playing?", switching (never over a game), each profile's settings, saves and session,
/// and the friends-only names.
void main() {
  late Fixture fixture;
  final shell = find.byType(LauncherShell);

  // The widget binding answers every HTTP request with 400; these talk to a local fake server.
  setUp(() => HttpOverrides.global = null);

  tearDown(() {
    T.language = Language.english;
    Motion.reduced = false;
    fixture.dispose();
  });

  Future<void> until(bool Function() condition) async {
    for (var tries = 0; tries < 300 && !condition(); tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(condition(), isTrue);
  }

  SavedSession session(String id, String handle, String name) => SavedSession(
    accessToken: 'access-$id',
    accessExpiry: DateTime.now().add(const Duration(minutes: 10)),
    refreshToken: 'refresh-$id',
    user: TogetherUser(id: id, handle: handle, displayName: name),
  );

  group('migration', () {
    test('a launcher set up before profiles is its first profile: no welcome, no picker', () {
      fixture = makeFixture();
      final model = fixture.model;
      expect(model.profiles.book.profiles, hasLength(1));
      expect(model.profiles.book.profiles.single.id, LauncherProfile.legacyId);
      expect(model.profiles.launchScreen, const LaunchScreen.home(LauncherProfile.legacyId));
      model.startProfiles();
      expect(model.overlay, isNull);
    });

    test('a signed-in launcher keeps its session in the first profile, online', () async {
      final server = await FakeTogether.start();
      addTearDown(server.close);
      fixture = makeFixture(
        together: server.base,
        togetherStore: MemoryTokenStore(session('u-me', 'utku', 'Utku Halis')),
      );
      final model = fixture.model;
      await model.together.start();
      final profile = model.profiles.book.profiles.single;
      expect(profile.mode, ProfileMode.online);
      expect(profile.account?.handle, 'utku');
      expect(model.together.signedIn, isTrue);
      model.dispose();
    });
  });

  group('the first start', () {
    test('offline: the last step makes the profile and goes home', () {
      fixture = makeFixture(onboarded: false);
      final model = fixture.model;
      expect(model.profiles.book.profiles, isEmpty);
      model.onboardingStep = 4;
      model.profileFlow.modeChoice = 0;
      model.handle(Command.select);
      expect(model.preferences.onboarded, isTrue);
      expect(model.profiles.book.profiles.single.mode, ProfileMode.offline);
      expect(model.profiles.book.profiles.single.name, 'Utku');
    });

    test('online: the sign-in comes up, and signing in makes the profile and goes home', () async {
      final server = await FakeTogether.start();
      addTearDown(server.close);
      fixture = makeFixture(onboarded: false, together: server.base);
      final model = fixture.model;
      model.onboardingStep = 4;
      model.handle(Command.right);
      model.handle(Command.select);
      await until(() => model.overlay == Layer.signIn);
      expect(model.panelCategories().single.rows.map((row) => row.id), containsAll(['together-email', 'together-web']));
      model.together.email = 'utku@example.com';
      await model.together.sendCode();
      model.together.code = '123456';
      await model.together.verify();
      await until(() => model.preferences.onboarded);
      final profile = model.profiles.book.profiles.single;
      expect(profile.mode, ProfileMode.online);
      expect(profile.account?.handle, 'utku');
      expect(model.overlay, isNull);
      model.dispose();
    });

    test('back on the sign-in goes back to the cards, nothing made', () async {
      fixture = makeFixture(onboarded: false);
      final model = fixture.model;
      model.onboardingStep = 4;
      model.profileFlow.modeChoice = 1;
      model.handle(Command.select);
      await until(() => model.overlay == Layer.signIn);
      model.handle(Command.back);
      await until(() => model.overlay == null);
      expect(model.profiles.book.profiles, isEmpty);
      expect(model.preferences.onboarded, isFalse);
    });
  });

  group('switching', () {
    test(
      'Options/Start on Home opens the menu with Switch profile and online or offline; Triangle stays the game\'s',
      () {
        fixture = makeFixture();
        final model = fixture.model;
        model.padCommand(PadCommand.options);
        expect(model.overlay, Layer.gameSettings);
        model.closeOverlay();
        model.padCommand(PadCommand.menu);
        expect(model.overlay, Layer.profileMenu);
        expect(model.panelCategories().single.rows.map((row) => row.id), [
          'menu-game',
          'menu-switch',
          'menu-mode',
          'menu-profiles',
        ]);
      },
    );

    test('Switch profile in the PS menu opens the picker; not while a game starts', () async {
      fixture = makeFixture();
      final model = fixture.model;
      model.profiles.add(name: 'Selin', mode: ProfileMode.offline);
      model.homeHeld();
      final row = model.panelCategories().single.rows.firstWhere((row) => row.id == 'switchProfile');
      (row.kind as ActionRow).run();
      expect(model.overlay, Layer.profilePicker);
      model.closeOverlay();
      model.starting = model.games.first;
      model.homeHeld();
      ((model.panelCategories().single.rows.firstWhere((row) => row.id == 'switchProfile')).kind as ActionRow).run();
      expect(model.overlay, isNot(Layer.profilePicker));
      expect(model.toast, 'Close ${model.games.first.name} first');
      final selin = model.profiles.book.profiles.last.id;
      await model.switchProfile(selin);
      expect(model.currentProfile?.name, 'Utku', reason: 'never over a game');
    });

    test('each profile has its own settings, and comes back with them', () async {
      fixture = makeFixture();
      final model = fixture.model;
      model.preferences
        ..theme = 2
        ..sounds = false;
      final selin = model.profiles.add(name: 'Selin', mode: ProfileMode.offline);
      await model.switchProfile(selin.id);
      expect(model.currentProfile?.name, 'Selin');
      expect(model.preferences.theme, 0, reason: 'a new profile starts from the defaults');
      expect(model.preferences.sounds, isTrue);
      expect(model.preferences.profileName, 'Selin');
      expect(model.preferences.gamesFolders, isNotEmpty, reason: "the computer's settings stay");
      model.preferences.theme = 1;
      await model.switchProfile(LauncherProfile.legacyId);
      expect(model.preferences.theme, 2);
      expect(model.preferences.sounds, isFalse);
      await model.switchProfile(selin.id);
      expect(model.preferences.theme, 1);
    });

    test("each profile's saves and trophies are its own", () async {
      fixture = makeFixture();
      final model = fixture.model;
      final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
      final installed = Installer.installedFolder(orbit, model.root!);
      expect(model.trophies[orbit.id]?.unlockedCount, 2);
      final selin = model.profiles.add(name: 'Selin', mode: ProfileMode.offline);
      await model.switchProfile(selin.id);
      expect(Directory(p.join(installed, '_trophy')).existsSync(), isFalse);
      expect(model.trophies[orbit.id]?.unlockedCount ?? 0, 0, reason: "Selin has none of Utku's trophies");
      expect(ProfileSaves.owner(installed, legacyOwner: LauncherProfile.legacyId), selin.id);
      await model.switchProfile(LauncherProfile.legacyId);
      expect(model.trophies[orbit.id]?.unlockedCount, 2);
    });

    test('a new online profile signs in with its own session; the first one keeps its own', () async {
      final server = await FakeTogether.start();
      addTearDown(server.close);
      final first = MemoryTokenStore(session('u-me', 'utku', 'Utku'));
      final others = <String, MemoryTokenStore>{};
      fixture = makeFixture(
        together: server.base,
        togetherStore: first,
        togetherStoreFor: (id) => others[id] ??= MemoryTokenStore(),
      );
      final model = fixture.model;
      await model.together.start();
      expect(model.together.user?.handle, 'utku');
      model.openAddProfile();
      model.profileFlow.modeChoice = 1;
      model.handle(Command.select);
      await until(() => model.overlay == Layer.signIn);
      expect(model.together.signedIn, isFalse, reason: 'the new profile starts signed out');
      server.me = {'id': 'u-selin', 'handle': 'selin', 'displayName': 'Selin'};
      model.together.email = 'selin@example.com';
      await model.together.sendCode();
      model.together.code = '123456';
      await model.together.verify();
      await until(() => model.overlay == null);
      expect(model.currentProfile?.name, 'Selin');
      expect(model.together.user?.handle, 'selin');
      expect(first.session?.user.handle, 'utku', reason: "signing Selin in did not touch Utku's session");
      expect(others.values.single.session?.user.handle, 'selin');
      await model.switchProfile(LauncherProfile.legacyId);
      await until(() => model.together.user?.handle == 'utku');
      expect(others.values.single.session?.user.handle, 'selin', reason: 'switching signs nobody out');
      model.dispose();
    });

    test('going offline keeps the session; going online brings it back', () async {
      final server = await FakeTogether.start();
      addTearDown(server.close);
      final store = MemoryTokenStore(session('u-me', 'utku', 'Utku'));
      fixture = makeFixture(together: server.base, togetherStore: store);
      final model = fixture.model;
      await model.together.start();
      await model.toggleProfileMode();
      expect(model.together.signedIn, isFalse);
      expect(model.currentProfile?.mode, ProfileMode.offline);
      expect(store.session, isNotNull, reason: 'offline is not a sign-out');
      model.open(Layer.settings);
      model.panelCategory = model.panelCategories().indexWhere((category) => category.id == 'together');
      expect(model.panelCategories()[model.panelCategory].rows.map((row) => row.id), [
        'together-offline',
        'together-go-online',
      ]);
      await model.toggleProfileMode();
      await until(() => model.together.signedIn);
      expect(model.currentProfile?.mode, ProfileMode.online);
      model.dispose();
    });

    test('deleting asks first, backs the saves up and keeps the others', () async {
      fixture = makeFixture();
      final model = fixture.model;
      final selin = model.profiles.add(name: 'Selin', mode: ProfileMode.offline);
      await model.switchProfile(selin.id);
      await model.switchProfile(LauncherProfile.legacyId);
      model.open(Layer.settings);
      model.panelCategory = model.panelCategories().indexWhere((category) => category.id == 'profiles');
      List<PanelRow> rows() => model.panelCategories()[model.panelCategory].rows;
      (rows().firstWhere((row) => row.id == 'profile-delete-${selin.id}').kind as ActionRow).run();
      expect(rows().map((row) => row.id), contains('profile-delete-${selin.id}-cancel'));
      (rows().firstWhere((row) => row.id == 'profile-delete-${selin.id}-yes').kind as ActionRow).run();
      await until(() => model.profiles.book.profiles.length == 1);
      expect(model.toast, 'Selin was deleted');
    });
  });

  group('friends-only names', () {
    test('a friend shows with their private name and the handle beside', () async {
      final server = await FakeTogether.start();
      addTearDown(server.close);
      server.friend('f1', 'mira', 'NightOwl', presence: {'state': 'online'});
      server.friends.last['privateName'] = 'Mira Kaya';
      server.friend('f2', 'sol', 'Sol');
      fixture = makeFixture(together: server.base);
      final model = fixture.model;
      await model.together.start();
      await model.together.account.startEmail('utku@example.com');
      await model.together.account.verifyEmail(server.emailCode);
      await model.together.hub.friends.refresh();
      final rows = model.together.friendRows();
      final mira = rows.firstWhere((row) => row.id == 'friend-f1');
      expect(mira.title, 'Mira Kaya');
      expect(mira.detail, startsWith('@mira · NightOwl'));
      expect(rows.firstWhere((row) => row.id == 'friend-f2').title, 'Sol');
      model.dispose();
    });
  });

  group('the name, the colour and the picture', () {
    test("a profile left without a name is the language's player, numbered when taken", () {
      fixture = makeFixture(onboarded: false, language: Language.byCode('tr'));
      final model = fixture.model;
      model.preferences.profileName = '';
      model.onboardingStep = 4;
      model.profileFlow.modeChoice = 0;
      model.handle(Command.select);
      expect(model.profiles.book.profiles.single.name, 'Oyuncu');
      expect(model.preferences.profileName, 'Oyuncu');
      model.openAddProfile();
      model.profileFlow.name = '   ';
      model.confirmModeChoice();
      expect(model.profiles.book.profiles.map((profile) => profile.name), ['Oyuncu', 'Oyuncu 2']);
      // Emptied in Settings › Profiles: the next free one, never English.
      model.renameCurrentProfile('');
      expect(model.currentProfile!.name, 'Oyuncu 2');
    });

    testWidgets("the colour chosen shows at once on Home's picture", (tester) async {
      fixture = makeFixture();
      final model = fixture.model;
      await pumpLauncher(tester, model);
      Color shown() {
        final tile = find.descendant(
          of: find.byKey(const ValueKey('home-avatar')),
          matching: find.byType(AnimatedContainer),
        );
        final decoration = tester.widget<AnimatedContainer>(tile.first).decoration! as BoxDecoration;
        return (decoration.gradient! as LinearGradient).colors.first;
      }

      expect(shown(), LauncherProfiles.palette[0]);
      model.openProfileSettings();
      final rows = model.panelCategories()[model.panelCategory].rows;
      final colour = rows.firstWhere((row) => row.id == 'profile-color').kind as ChoiceRow;
      colour.set(3);
      await settle(tester);
      expect(shown(), LauncherProfiles.palette[3]);
    });

    testWidgets('a picture is chosen with the file dialog, cut to a square in the crop, shown and removed', (
      tester,
    ) async {
      String? picked;
      fixture = makeFixture(pickImage: () async => picked);
      final model = fixture.model;
      // 600×300: red at the sides, blue in the middle square.
      picked = p.join(fixture.temp.path, 'me.png');
      File(picked).writeAsBytesSync(png(600, 300, (x, y) => x < 150 || x >= 450 ? 0xFF0000FF : 0x0000FFFF));
      model.openProfileSettings();
      List<String> ids() => model.panelCategories()[model.panelCategory].rows.map((row) => row.id).toList();
      expect(ids(), contains('profile-picture'));
      expect(ids(), isNot(contains('profile-picture-remove')));
      await tester.runAsync(model.chooseProfilePicture);
      // The crop first, as on the Mac: saved as it opens, the middle square.
      expect(model.overlay, Layer.cropPicture);
      expect(model.pictureCrop?.rect, const Rect.fromLTWH(150, 0, 300, 300));
      await tester.runAsync(model.saveCrop);
      expect(model.overlay, Layer.settings);
      expect(model.pictureCrop, isNull);
      final kept = model.profiles.pictureOf(model.currentProfile);
      expect(kept, isNotNull, reason: model.toast);
      expect(p.isWithin(p.join(model.paths.config, 'Profiles'), kept!), isTrue);
      final image = await tester.runAsync(() async {
        final codec = await instantiateImageCodec(File(kept).readAsBytesSync());
        return (await codec.getNextFrame()).image;
      });
      expect([image!.width, image.height], [256, 256]);
      final pixels = (await tester.runAsync(() => image.toByteData()))!;
      int at(int x, int y) => pixels.getUint32((y * 256 + x) * 4);
      expect(at(2, 2), 0x0000FFFF, reason: 'the sides are cut off');
      expect(at(253, 128), 0x0000FFFF);
      // The row for a controller, and the picture on Home and in Settings.
      expect(ids(), containsAll(['profile-picture', 'profile-picture-remove']));
      expect(model.panelCategories()[model.panelCategory].rows.first.person?.picture, kept);
      model.closeOverlay();
      await pumpLauncher(tester, model);
      expect(tester.widget<ProfileTile>(find.byKey(const ValueKey('home-avatar'))).picture, kept);
      expect(
        find.descendant(of: find.byKey(const ValueKey('home-avatar')), matching: find.byType(Image)),
        findsOneWidget,
      );
      model.removeProfilePicture();
      expect(model.profiles.pictureOf(model.currentProfile), isNull);
      expect(File(kept).existsSync(), isFalse);
      model.openProfileSettings();
      expect(ids(), isNot(contains('profile-picture-remove')));
      // The toast's timer runs out.
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('the crop zooms with the arrows and keeps the square dragged to; Back keeps nothing', (tester) async {
      String? picked;
      fixture = makeFixture(pickImage: () async => picked);
      final model = fixture.model;
      // 600×300: red on the left quarter, blue elsewhere.
      picked = p.join(fixture.temp.path, 'me.png');
      File(picked).writeAsBytesSync(png(600, 300, (x, y) => x < 150 ? 0xFF0000FF : 0x0000FFFF));
      model.openProfileSettings();
      final category = model.panelCategory;
      model.panelRow = model.panelCategories()[category].rows.indexWhere((row) => row.id == 'profile-picture');
      final row = model.panelRow;

      // Back: nothing kept, and Settings where they were.
      await tester.runAsync(model.chooseProfilePicture);
      model.handle(Command.back);
      expect(model.overlay, Layer.settings);
      expect((model.panelCategory, model.panelRow), (category, row));
      expect(model.profiles.pictureOf(model.currentProfile), isNull);

      await tester.runAsync(model.chooseProfilePicture);
      final crop = model.pictureCrop!;
      for (var press = 0; press < 4; press++) {
        model.handle(Command.right);
      }
      expect(crop.zoom, 2);
      // No further than 4, no less than 1.
      for (var press = 0; press < 20; press++) {
        model.handle(Command.right);
      }
      expect(crop.zoom, 4);
      for (var press = 0; press < 20; press++) {
        model.handle(Command.left);
      }
      expect(crop.zoom, 1);
      for (var press = 0; press < 4; press++) {
        model.handle(Command.right);
      }
      // The picture dragged right: the square goes to its left edge, onto the red.
      crop.drag(const Offset(1000, 0));
      expect(crop.rect, const Rect.fromLTWH(0, 75, 150, 150));
      await pumpLauncher(tester, model);
      expect(find.text('Crop your picture'), findsOneWidget);
      model.handle(Command.select);
      await tester.runAsync(() async {
        for (var tries = 0; tries < 100 && model.pictureCrop != null; tries++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      final kept = model.profiles.pictureOf(model.currentProfile)!;
      final image = await tester.runAsync(() async {
        final codec = await instantiateImageCodec(File(kept).readAsBytesSync());
        return (await codec.getNextFrame()).image;
      });
      expect([image!.width, image.height], [150, 150], reason: 'never larger than the square was');
      final pixels = (await tester.runAsync(() => image.toByteData()))!;
      expect(pixels.getUint32((75 * 150 + 75) * 4), 0xFF0000FF);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('a picture under 32 pixels is too small for the crop', (tester) async {
      fixture = makeFixture(pickImage: () async => p.join(fixture.temp.path, 'tiny.png'));
      final model = fixture.model;
      File(p.join(fixture.temp.path, 'tiny.png')).writeAsBytesSync(png(20, 40, (x, y) => 0x00FF00FF));
      await tester.runAsync(model.chooseProfilePicture);
      expect(model.overlay, isNot(Layer.cropPicture));
      expect(model.toast, 'The picture is too small: at least 32 pixels');
    });

    // A plain test: real sockets to the fake server (testWidgets answers every HTTP request itself).
    test('signed in: the picture goes up as the AnyTogether one, and the account\'s comes down', () async {
      final server = await FakeTogether.start();
      // The kept session is one the server knows, so nothing signs it out.
      server.validAccess.add('access-u-me');
      server.validRefresh.add('refresh-u-me');
      final store = MemoryTokenStore(session('u-me', 'utku', 'Utku'));
      fixture = makeFixture(together: server.base, togetherStore: store);
      final model = fixture.model;
      await model.together.start();
      await until(() => model.together.signedIn);
      List<String> ids() => model.panelCategories()[model.panelCategory].rows.map((row) => row.id).toList();
      model.openProfileSettings();
      expect(ids(), isNot(contains('profile-picture-upload')), reason: 'no picture yet');
      expect(ids(), isNot(contains('profile-picture-from-together')), reason: 'the account has none yet');

      // The account's picture, here: a square the server made.
      server.files['/avatars/u-me.png'] = png(64, 64, (x, y) => 0xFF8800FF);
      model.together.account.updateUser(
        TogetherUser(id: 'u-me', handle: 'utku', displayName: 'Utku', avatar: '${server.base}/avatars/u-me.png'),
      );
      expect(ids(), containsAllInOrder(['profile-picture', 'profile-picture-from-together']));
      await model.useTogetherPicture();
      expect(model.toast, 'Profile picture set');
      expect(model.profiles.pictureOf(model.currentProfile), isNotNull);

      // This one, up as the account's.
      server.answers['PUT me/avatar'] = (200, {'avatar': '${server.base}/avatars/u-me-2.jpg'});
      expect(ids(), containsAllInOrder(['profile-picture', 'profile-picture-upload', 'profile-picture-from-together']));
      await model.uploadProfilePicture();
      final upload = server.calls.lastWhere((call) => call.path == 'me/avatar');
      expect(upload.method, 'PUT');
      expect(upload.headers.contentType?.mimeType, 'image/png');
      expect(upload.bytes.take(4), [0x89, 0x50, 0x4E, 0x47]);
      expect(model.toast, 'Your AnyTogether picture is updated');
      expect(model.together.user?.avatar, '${server.base}/avatars/u-me-2.jpg');

      // Refused: said so.
      server.answers['PUT me/avatar'] = FakeTogether.problem(413, 'payload_too_large', 'The file is too big');
      await model.uploadProfilePicture();
      // The launcher's words for the code, not the server's English.
      expect(model.toast, 'The picture could not be uploaded: That\'s too large.');
      // A picture that does not come: said so.
      model.together.account.updateUser(
        TogetherUser(id: 'u-me', handle: 'utku', displayName: 'Utku', avatar: '${server.base}/avatars/gone.png'),
      );
      await model.useTogetherPicture();
      expect(model.toast, 'Your AnyTogether picture could not be downloaded');
      model.dispose();
      await server.close();
    });

    testWidgets('a file that is not a picture changes nothing', (tester) async {
      fixture = makeFixture(pickImage: () async => p.join(fixture.temp.path, 'notes.png'));
      final model = fixture.model;
      File(p.join(fixture.temp.path, 'notes.png')).writeAsStringSync('not a picture');
      await tester.runAsync(model.chooseProfilePicture);
      expect(model.profiles.pictureOf(model.currentProfile), isNull);
      expect(model.toast, T.text('profilePictureFailed'));
    });
  });

  group('for a screen reader', () {
    testWidgets('the picker, Add profile and the home menu are named', (tester) async {
      final semantics = tester.ensureSemantics();
      fixture = makeFixture();
      final model = fixture.model;
      model.profiles.add(name: 'Mira', mode: ProfileMode.offline);
      model.openProfilePicker(atLaunch: true);
      await pumpLauncher(tester, model);
      expect(find.bySemanticsLabel('Mira'), findsOneWidget);
      expect(find.bySemanticsLabel(T.text('profileAdd')), findsOneWidget);

      model.openAddProfile();
      await tester.pumpAndSettle();
      expect(
        find.bySemanticsLabel('${T.text('profileOfflineTitle')}. ${T.text('profileOfflineLead')}'),
        findsOneWidget,
      );

      model.closeOverlay();
      model.open(Layer.homeMenu);
      await tester.pumpAndSettle();
      final rows = model.panelCategories().single.rows;
      expect(find.bySemanticsLabel(rows.first.title), findsOneWidget);
      semantics.dispose();
    });
  });

  group('golden', () {
    testWidgets("who's playing", (tester) async {
      fixture = makeFixture();
      final model = fixture.model;
      model.profiles
        ..add(
          name: 'Mira',
          mode: ProfileMode.online,
          account: const ProfileAccount(userId: 'u7', handle: 'mira.k'),
        )
        ..add(name: 'Deniz', mode: ProfileMode.offline);
      model.openProfilePicker(atLaunch: true);
      model.handle(Command.right);
      await pumpLauncher(tester, model);
      await expectLater(shell, matchesGoldenFile('goldens/profiles_picker.png'));
    });

    testWidgets('Quit AnyPS5?: a small yes or no, the answers side by side, in Turkish', (tester) async {
      fixture = makeFixture(language: Language.byCode('tr'));
      final model = fixture.model;
      model.open(Layer.confirmQuit);
      model.handle(Command.right);
      await pumpLauncher(tester, model);
      await expectLater(shell, matchesGoldenFile('goldens/quit_confirm_tr.png'));
    });

    testWidgets("who's playing: a linked profile wears AnyTogether's mark, a local one says Local", (tester) async {
      fixture = makeFixture();
      final model = fixture.model;
      model.profiles
        ..add(
          name: 'Mira',
          mode: ProfileMode.online,
          account: const ProfileAccount(userId: 'u7', handle: 'mira.k'),
        )
        ..add(name: 'Deniz', mode: ProfileMode.offline);
      model.openProfilePicker(atLaunch: true);
      await pumpLauncher(tester, model);
      expect(find.byType(LinkedProfileTile), findsNWidgets(3));
      expect(find.byKey(const ValueKey('together-badge')), findsOneWidget, reason: 'only Mira is linked');
      expect(find.text('@mira.k'), findsOneWidget);
      expect(find.text(T.text('profileOfflineTag')), findsNWidgets(2), reason: 'the first profile and Deniz are local');
    });

    testWidgets('the first start: offline or online, in Turkish', (tester) async {
      fixture = makeFixture(onboarded: false, language: Language.byCode('tr'));
      final model = fixture.model;
      model.onboardingStep = 4;
      model.profileFlow.modeChoice = 1;
      await pumpLauncher(tester, model);
      await expectLater(shell, matchesGoldenFile('goldens/profiles_welcome_tr.png'));
    });

    testWidgets('the Options menu', (tester) async {
      fixture = makeFixture();
      final model = fixture.model;
      model.profiles.add(name: 'Selin', mode: ProfileMode.offline);
      model.padCommand(PadCommand.menu);
      model.handle(Command.down);
      await pumpLauncher(tester, model);
      await expectLater(shell, matchesGoldenFile('goldens/profiles_menu.png'));
    });

    testWidgets('Settings › Profiles', (tester) async {
      fixture = makeFixture();
      final model = fixture.model;
      model.profiles.add(
        name: 'Selin',
        mode: ProfileMode.online,
        account: const ProfileAccount(userId: 'u2', handle: 'selin'),
      );
      model.openProfileSettings();
      await pumpLauncher(tester, model);
      await expectLater(shell, matchesGoldenFile('goldens/profiles_settings.png'));
    });

    testWidgets('the crop, zoomed in and moved, in Turkish', (tester) async {
      String? picked;
      fixture = makeFixture(language: Language.byCode('tr'), pickImage: () async => picked);
      final model = fixture.model;
      // Rings of colour, so where the square is shows.
      picked = p.join(fixture.temp.path, 'me.png');
      File(picked).writeAsBytesSync(
        png(480, 320, (x, y) {
          final ring = ((x - 240) * (x - 240) + (y - 160) * (y - 160)) ~/ 1600 % 3;
          return const [0xE8505BFF, 0xF9D56EFF, 0x14B1ABFF][ring];
        }),
      );
      model.openProfileSettings();
      await tester.runAsync(model.chooseProfilePicture);
      model.pictureCrop!
        ..zoomTo(1.5)
        ..drag(const Offset(40, -20));
      await pumpLauncher(tester, model);
      expect(find.text('Fotoğrafını kırp'), findsOneWidget);
      await expectLater(shell, matchesGoldenFile('goldens/profile_picture_crop_tr.png'));
    });

    testWidgets('Add profile', (tester) async {
      fixture = makeFixture();
      final model = fixture.model;
      model.openAddProfile();
      await pumpLauncher(tester, model);
      await expectLater(shell, matchesGoldenFile('goldens/profiles_add.png'));
    });
  });
}
