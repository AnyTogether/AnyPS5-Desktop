import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/together/cloud_saves.dart';
import 'package:anyps5_desktop/core/together/messages.dart';
import 'package:anyps5_desktop/core/together/people.dart';
import 'package:anyps5_desktop/core/together/posts.dart';
import 'package:anyps5_desktop/ui/app_model.dart' hide Command, GameState;
import 'package:anyps5_desktop/ui/launcher.dart';
import 'package:anyps5_desktop/core/together/cloud_saves.dart' show StorageInfo;
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:anyps5_desktop/ui/together_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/ui_support.dart';
import 'together_interface_test.dart' show signedInPreview;

/// Captures' screens: the feed, a post's comments, the Share menu over the gallery and the post
/// being written.
void main() {
  late Fixture fixture;
  late AppModel model;

  tearDown(() {
    T.language = Language.english;
    fixture.dispose();
  });

  /// A screenshot with sky, sun and ground, so a picture reads as one.
  Uint8List scene(int width, int height) => png(width, height, (x, y) {
    final dx = x - width * 0.7;
    final dy = y - height * 0.35;
    if (dx * dx + dy * dy < (height * 0.12) * (height * 0.12)) return 0xFFD36EFF;
    if (y > height * 0.68) return 0x1E3A2FFF;
    return y < height * 0.34 ? 0x3B4E9AFF : 0x7A5C9EFF;
  });

  Post post(
    String id,
    Person author, {
    required String caption,
    int likes = 0,
    bool liked = false,
    int comments = 0,
    bool mine = false,
  }) => Post(
    id: id,
    author: author,
    caption: caption,
    game: const PostGame(titleId: 'PPSA02002', names: {'en': 'Neon Alley'}),
    media: [MediaItem(id: 'm-$id', kind: 'image', url: 'https://together.test/media/$id.png')],
    likes: likes,
    liked: liked,
    comments: comments,
    mine: mine,
    createdAt: DateTime.now().subtract(const Duration(hours: 3)),
  );

  void feed(AppModel model) {
    final pictures = model.together.captures.pictures;
    for (final id in ['p2', 'p1']) {
      pictures['https://together.test/media/$id.png'] = Future.value(scene(640, 360));
    }
    model.together.captures.feed.load([
      post(
        'p2',
        const Person(id: 'u-ana', handle: 'ana', displayName: 'Ana'),
        caption: 'Finally beat the night race',
        likes: 4,
        liked: true,
        comments: 2,
      ),
      post(
        'p1',
        const Person(id: 'u-me', handle: 'utku', displayName: 'Utku Halis'),
        caption: 'Photo mode is too good',
        mine: true,
      ),
    ], null);
  }

  testWidgets('golden: Captures, a liked post with Comments focused', (tester) async {
    fixture = makeFixture();
    model = fixture.model;
    signedInPreview(model);
    feed(model);
    model.open(Layer.captures);
    model.together.captures
      ..index = 0
      ..action = 1;
    await pumpLauncher(tester, model);
    await settle(tester);
    expect(find.text('Captures'), findsWidgets);
    expect(find.text('Liked · 4'), findsOneWidget);
    await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/captures_feed_en.png'));
  });

  testWidgets('a server that keeps no files says so on Captures', (tester) async {
    fixture = makeFixture();
    model = fixture.model;
    signedInPreview(model);
    model.saveSync.info = StorageInfo.disabled;
    model.together.captures.failed = true;
    model.open(Layer.captures);
    await pumpLauncher(tester, model);
    expect(find.text(T.text('capturesRefusedStorage')), findsOneWidget);
    expect(find.text(T.text('capturesFailed')), findsNothing);
  });

  testWidgets('golden: a post\'s comments with a reply, in Turkish', (tester) async {
    fixture = makeFixture(language: Language.byCode('tr'));
    model = fixture.model;
    signedInPreview(model);
    feed(model);
    model.open(Layer.captures);
    const cem = Person(id: 'u-cem', handle: 'cem', displayName: 'Cem Yılmaz');
    final at = DateTime.now().subtract(const Duration(minutes: 40));
    final thread = CommentThread('p2')
      ..load([
        PostComment(
          id: 'c1',
          postId: 'p2',
          author: cem,
          text: 'O son viraj!',
          createdAt: at,
          replies: [
            PostComment(
              id: 'c2',
              postId: 'p2',
              author: const Person(id: 'u-ana', handle: 'ana', displayName: 'Ana'),
              text: 'Üç denemede geldi',
              replyTo: 'c1',
              createdAt: at,
            ),
          ],
        ),
      ], null);
    model.together.captures
      ..thread = thread
      ..line = 1
      ..composer = 0;
    await pumpLauncher(tester, model);
    await settle(tester);
    expect(find.text('Yorumlar'), findsWidgets);
    await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/captures_comments_tr.png'));
  });

  testWidgets('golden: the Share menu over the gallery, then the post being written', (tester) async {
    fixture = makeFixture();
    model = fixture.model;
    signedInPreview(model);
    model.saveSync.info = const StorageInfo(enabled: true);
    model.together.hub.messages
      ..conversations = [
        Conversation(
          id: 'c-ana',
          group: false,
          title: null,
          members: const [
            Person(id: 'u-me', handle: 'utku', displayName: 'Utku Halis'),
            Person(id: 'u-ana', handle: 'ana', displayName: 'Ana'),
          ],
          lastSeq: 1,
          readSeq: 1,
          lastMessage: null,
          updatedAt: DateTime.utc(2026, 11, 6),
        ),
      ]
      ..loaded = true;
    final shot = p.join(fixture.temp.path, 'shot.png');
    File(shot).writeAsBytesSync(scene(1280, 720));
    model.selected = model.games.indexWhere((game) => game.titleId == 'PPSA01001');
    model.open(Layer.gallery);
    model.galleryShots = [shot];
    model.galleryIndex = 0;
    model.together.openShareMenu();
    model.together.captures.shareIndex = 1;
    await pumpLauncher(tester, model);
    await settle(tester);
    expect(find.text('Send to Ana'), findsOneWidget);
    await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/captures_share_en.png'));

    model.together.captures.shareIndex = 0;
    await model.together.share(const PostShare());
    model.together.captures.draft!
      ..caption = 'Photo mode is too good'
      ..visibility = PostVisibility.public;
    model.together.captures.draftRow = DraftRow.post;
    model.refresh();
    await pumpLauncher(tester, model);
    await settle(tester);
    expect(find.text('Share to AnyTogether'), findsWidgets);
    await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/captures_post_en.png'));
  });
}
