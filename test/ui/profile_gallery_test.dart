import 'package:anyps5_desktop/core/together/compat.dart';
import 'package:anyps5_desktop/core/together/profiles.dart';
import 'package:anyps5_desktop/ui/app_model.dart' hide GameState;
import 'package:anyps5_desktop/ui/captures_view.dart' show CaptureViewer;
import 'package:anyps5_desktop/ui/launcher.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:anyps5_desktop/ui/together_model.dart';
import 'package:anyps5_desktop/core/together/posts.dart' show MediaItem;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_together.dart';
import '../support/ui_support.dart';
import 'together_levels_interface_test.dart' show library, mine, recent, signedIn;

/// A profile's pinned gallery and a game's community card on the home screen, as on the Mac.
void main() {
  late Fixture fixture;
  late AppModel model;

  tearDown(() {
    T.language = Language.english;
    fixture.dispose();
  });

  MediaItem media(String id, String kind) =>
      MediaItem(id: id, kind: kind, url: 'https://cdn.test/$id.png', width: 1280, height: 720);

  ProfilePage minePage() => ProfilePage(
    profile: TogetherProfile(
      userId: 'u-me',
      handle: 'utku',
      displayName: 'Utku Halis',
      bio: 'Night runs in Orbit Runner.',
      country: 'TR',
      friendship: 'me',
      trophyLevel: mine,
    ),
    library: SectionShown(library),
    trophies: SectionShown(recent),
    showcase: const SectionShown(Showcase(trophies: [], games: [])),
  );

  /// What a picture behind [media]'s link shows, without asking anyone.
  void keepPicture(MediaItem media, Color tint) {
    final bytes = png(320, 180, (x, y) => (tint.toARGB32() & 0xFFFFFF) << 8 | 0xFF);
    model.together.captures.pictures[media.still.split('?').first] = Future.value(bytes);
  }

  testWidgets('golden: the pinned gallery under the showcase', (tester) async {
    fixture = makeFixture();
    model = fixture.model;
    signedIn(model);
    final items = [media('m1', 'image'), media('m2', 'clip'), media('m3', 'image')];
    keepPicture(items[0], const Color(0xFFFF8A3D));
    keepPicture(items[1], const Color(0xFF3A6BFF));
    keepPicture(items[2], const Color(0xFF42D392));
    model.open(Layer.profile);
    model.together
      ..profile = minePage()
      ..profileGallery = SectionShown(items);
    await pumpLauncher(tester, model);
    expect(find.text(T.text('cloudProfileGallery')), findsOneWidget);
    await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/together_profile_gallery_en.png'));
  });

  testWidgets('a pinned photo opens over the whole screen and Back closes only that', (tester) async {
    fixture = makeFixture();
    model = fixture.model;
    signedIn(model);
    final photo = media('m1', 'image');
    keepPicture(photo, const Color(0xFFFF8A3D));
    model.open(Layer.profile);
    model.together
      ..profile = minePage()
      ..profileGallery = SectionShown([photo]);
    await pumpLauncher(tester, model);
    model.together.viewProfileMedia(photo);
    await tester.pump();
    expect(find.byType(CaptureViewer), findsOneWidget);
    model.handle(Command.back);
    await tester.pump();
    expect(find.byType(CaptureViewer), findsNothing);
    expect(model.overlay, Layer.profile);
  });

  test('the gallery comes from the server, private and failed included, and only where it keeps files', () async {
    final server = await FakeTogether.start();
    addTearDown(server.close);
    fixture = makeFixture(together: server.base);
    model = fixture.model;
    model.together.email = 'utku@example.com';
    await model.together.sendCode();
    model.together.code = '123456';
    await model.together.verify();
    final files = model.together.mediaFiles;

    server.answers['GET users/ana/gallery'] = (
      200,
      {
        'items': [
          {'id': 'm1', 'kind': 'image', 'url': 'https://cdn.test/m1.png'},
        ],
      },
    );
    final shown = await files.gallery('ana');
    expect(shown, isA<SectionShown<List<MediaItem>>>());
    expect(shown.value!.single.id, 'm1');

    server.answers['GET users/ana/gallery'] = (403, {'status': 403, 'code': 'forbidden', 'title': 'Private'});
    expect(await files.gallery('ana'), isA<SectionPrivate<List<MediaItem>>>());

    server.answers['GET users/ana/gallery'] = (500, {'status': 500, 'code': 'internal', 'title': 'Broken'});
    expect(await files.gallery('ana'), isA<SectionFailed<List<MediaItem>>>());
    model.dispose();
  });

  testWidgets('golden: the community card on the home screen once there is a verdict', (tester) async {
    fixture = makeFixture();
    model = fixture.model;
    signedIn(model);
    model.selected = model.games.indexWhere((game) => game.titleId == 'PPSA01001');
    final together = model.together;
    together.screens.compat['PPSA01001'] = const CompatSummary(statusName: 'playable', version: '0.1.17', reports: 7);
    together.screens.compatAsked['PPSA01001'] = DateTime.now();
    await pumpLauncher(tester, model);
    expect(find.text('Community'), findsOneWidget);
    expect(find.text('Playable'), findsOneWidget);
    expect(find.text('0.1.17'), findsOneWidget);
    await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/home_community_en.png'));
  });

  testWidgets('no community card until there is a verdict', (tester) async {
    fixture = makeFixture();
    model = fixture.model;
    signedIn(model);
    model.selected = model.games.indexWhere((game) => game.titleId == 'PPSA01001');
    model.together.screens.compatAsked['PPSA01001'] = DateTime.now();
    await pumpLauncher(tester, model);
    expect(find.text('Community'), findsNothing);
  });
}
