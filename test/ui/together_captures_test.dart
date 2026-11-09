import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/capture/clip_tools.dart';
import 'package:anyps5_desktop/core/together/cloud_saves.dart';
import 'package:anyps5_desktop/core/together/posts.dart';
import 'package:anyps5_desktop/core/together/profiles.dart';
import 'package:anyps5_desktop/ui/app_model.dart' hide Command, GameState;
import 'package:anyps5_desktop/ui/app_model.dart' as launcher show Command;
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:anyps5_desktop/ui/together_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_together.dart';
import '../support/ui_support.dart';

/// A clip's length and still, chosen by the test; making one smaller is never asked here.
class _Clips implements ClipTools {
  _Clips(this.ms);

  final int? ms;

  @override
  Future<int?> durationMs(String path) async => ms;

  @override
  Future<Uint8List?> poster(String path) async => Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]);

  @override
  Future<String> shrink(String path, {required int maxBytes, required int durationMs, required String folder}) =>
      throw UnimplementedError();
}

/// Captures and the gallery's Share menu, as on the Mac: a screenshot or clip to a chat, to the
/// AnyTogether gallery or as a post; the Captures feed with likes, comments and Delete.
void main() {
  late FakeTogether server;
  late Fixture fixture;
  late AppModel model;
  late List<Map<String, dynamic>> posts;
  late List<String> gallery;
  late Map<String, List<Map<String, dynamic>>> comments;
  var ids = 0;

  Future<void> until(bool Function() condition) async {
    for (var tries = 0; tries < 300 && !condition(); tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(condition(), isTrue);
  }

  Map<String, dynamic> media(String id, String kind) => {
    'id': id,
    'kind': kind,
    'contentType': kind == 'clip' ? 'video/mp4' : 'image/png',
    'size': 1000,
    'width': 1280,
    'height': 720,
    'durationMs': kind == 'clip' ? 30000 : null,
    'url': '${server.base}/media/$id.png',
    'thumb': null,
    'poster': null,
    'createdAt': '2026-11-07T10:00:00Z',
  };

  Map<String, dynamic> post(
    String id,
    Map<String, dynamic> author, {
    bool mine = false,
    int likes = 0,
    int count = 0,
  }) => {
    'id': id,
    'author': author,
    'caption': 'Look at this',
    'game': {
      'titleId': 'PPSA02002',
      'names': {'en': 'Neon Alley'},
      'iconUrl': null,
    },
    'visibility': 'friends',
    'commentsOff': false,
    'media': [media('m-$id', 'image')],
    'likes': likes,
    'liked': false,
    'comments': count,
    'mine': mine,
    'source': 'launcher',
    'createdAt': '2026-11-07T09:00:00Z',
    'editedAt': null,
  };

  setUp(() async {
    server = await FakeTogether.start();
    ids = 0;
    posts = [];
    gallery = [];
    comments = {};
    server.friend('u-ana', 'ana', 'Ana', presence: {'state': 'online'});
    server.conversation('c-ana', [FakeTogether.card('u-ana', 'ana', 'Ana')], texts: [('u-ana', 'Hi!')]);
    final me = FakeTogether.card('u-me', 'utku', 'Utku');
    final ana = FakeTogether.card('u-ana', 'ana', 'Ana');
    server.handlers.add((call) {
      final path = call.path;
      final like = RegExp(r'^posts/([^/]+)/like$').firstMatch(path);
      final thread = RegExp(r'^posts/([^/]+)/comments(?:/([^/?]+))?(?:\?.*)?$').firstMatch(path);
      final onePost = RegExp(r'^posts/([^/]+)$').firstMatch(path);
      if (path.startsWith('me/media?kind=') && call.method == 'POST') {
        final kind = path.split('=').last;
        final id = 'media-${++ids}';
        server.mediaKinds[id] = kind;
        return (201, {'media': media(id, kind)});
      }
      if (path.startsWith('me/media/') && path.endsWith('/poster')) {
        return (200, {'media': media(path.split('/')[2], 'clip')..['poster'] = '${server.base}/p.jpg'});
      }
      if (path == 'me/gallery' && call.method == 'GET') {
        return (
          200,
          {
            'items': [for (final id in gallery) media(id, 'image')],
          },
        );
      }
      if (path == 'me/gallery' && call.method == 'PUT') {
        gallery = [...(call.body['items'] as List<dynamic>).cast<String>()];
        return (
          200,
          {
            'items': [for (final id in gallery) media(id, 'image')],
          },
        );
      }
      if (path == 'posts' && call.method == 'POST') {
        final made = post('p-${++ids}', me, mine: true)
          ..['caption'] = call.body['caption']
          ..['visibility'] = call.body['visibility'];
        posts.insert(0, made);
        return (201, made);
      }
      if (path == 'me/captures') return (200, {'items': posts, 'next': null});
      if (like != null) {
        final liked = posts.firstWhere((item) => item['id'] == like.group(1));
        final on = call.method == 'PUT';
        if (on != liked['liked']) liked['likes'] = (liked['likes'] as int) + (on ? 1 : -1);
        liked['liked'] = on;
        return (200, {'likes': liked['likes'], 'liked': on});
      }
      if (thread != null) {
        final postId = thread.group(1)!;
        final list = comments.putIfAbsent(postId, () => []);
        if (call.method == 'GET') return (200, {'items': list, 'next': null});
        if (call.method == 'DELETE') {
          list.removeWhere((comment) => comment['id'] == thread.group(2));
          return (204, null);
        }
        final made = {
          'id': 'c-${++ids}',
          'postId': postId,
          'author': me,
          'text': call.body['text'],
          'replyTo': call.body['replyTo'],
          'createdAt': '2026-11-07T10:00:00Z',
          'canDelete': true,
          'replies': <Object>[],
        };
        if (call.body['replyTo'] == null) list.insert(0, made);
        return (201, made);
      }
      if (onePost != null && call.method == 'DELETE') {
        posts.removeWhere((item) => item['id'] == onePost.group(1));
        return (204, null);
      }
      return null;
    });
    posts.addAll([post('p-ana', ana, likes: 2), post('p-mine', me, mine: true)]);
    fixture = makeFixture(together: server.base);
    model = fixture.model;
    model.together.email = 'utku@example.com';
    await model.together.sendCode();
    model.together.code = '123456';
    await model.together.verify();
    await until(() => model.together.hub.friends.loaded && model.together.hub.messages.loaded);
  });

  tearDown(() async {
    model.dispose();
    await server.close();
    T.language = Language.english;
    fixture.dispose();
  });

  /// The gallery open on one screenshot (or clip) of Orbit Runner.
  String openGallery({String name = 'shot.png'}) {
    final shot = p.join(fixture.temp.path, name);
    File(shot).writeAsBytesSync(name.endsWith('.mp4') ? List.filled(64, 1) : png(64, 36, (x, y) => 0x3366FFFF));
    model.selected = model.games.indexWhere((game) => game.titleId == 'PPSA01001');
    model.open(Layer.gallery);
    model.galleryShots = [shot];
    model.galleryIndex = 0;
    return shot;
  }

  test("someone's gallery: shown, private or failed, as the owner's setting and the server say", () async {
    final files = model.together.mediaFiles;
    server.answers['GET users/ana/gallery'] = (
      200,
      {
        'items': [media('m1', 'image')],
      },
    );
    final shown = await files.gallery('ana');
    expect(shown, isA<SectionShown<List<MediaItem>>>());
    expect(shown.value!.single.id, 'm1');

    server.answers['GET users/ana/gallery'] = FakeTogether.problem(403, 'forbidden');
    expect(await files.gallery('ana'), isA<SectionPrivate<List<MediaItem>>>());

    server.answers['GET users/ana/gallery'] = FakeTogether.problem(500, 'internal');
    expect(await files.gallery('ana'), isA<SectionFailed<List<MediaItem>>>());
  });

  test('without a server that keeps files, △ in the gallery shows the file in its folder', () {
    final shot = openGallery();
    model.handle(launcher.Command.options);
    expect(model.together.captures.sharing, isFalse);
    expect(fixture.folders, [p.dirname(shot)]);
  });

  test('Share: to a chat it goes as a photo, to my gallery it is pinned, and a full gallery says so', () async {
    final together = model.together;
    model.saveSync.info = const StorageInfo(enabled: true, galleryMax: 1);
    openGallery();
    model.handle(launcher.Command.options);
    expect(together.captures.sharing, isTrue);
    expect(together.shareTargets.map((target) => target.runtimeType), [
      PostShare,
      ChatShare,
      GalleryShare,
      FolderShare,
    ]);

    // Down to Ana's conversation.
    model.handle(launcher.Command.down);
    model.handle(launcher.Command.select);
    await until(() => model.toast == 'Sent to Ana');
    final upload = server.calls.firstWhere((call) => call.path == 'me/media?kind=image');
    expect(upload.headers.contentType?.mimeType, 'image/png');
    final sent = server.callsTo('conversations/c-ana/messages', method: 'POST').single.body;
    expect(sent['attachments'], [
      {'mediaId': 'media-1'},
    ]);
    expect(sent.containsKey('text'), isFalse);
    expect(together.captures.sharing, isFalse);
    // The list shows it as a photo.
    final last = together.hub.messages.byId('c-ana')!.lastMessage!;
    expect(last.media?.id, 'media-1');
    expect(TogetherMessages.previewText(last), 'Photo');

    // My gallery: pinned at its end.
    model.handle(launcher.Command.options);
    model.handle(launcher.Command.down);
    model.handle(launcher.Command.down);
    model.handle(launcher.Command.select);
    await until(() => model.toast == 'Added to your gallery');
    expect(server.callsTo('me/gallery', method: 'PUT').single.body, {
      'items': ['media-2'],
    });
    // Full now: nothing goes up.
    final uploads = server.calls.where((call) => call.path.startsWith('me/media')).length;
    await together.shareShotToGallery(together.app.galleryShots.single);
    expect(model.toast, 'Your gallery is full (1): unpin something first');
    expect(server.calls.where((call) => call.path.startsWith('me/media')).length, uploads);
  });

  test('a post from the gallery: a caption, Public, Post; it tops Captures', () async {
    final together = model.together;
    model.saveSync.info = const StorageInfo(enabled: true);
    openGallery();
    model.handle(launcher.Command.options);
    model.handle(launcher.Command.select);
    final draft = together.captures.draft!;
    expect(draft.titleId, 'PPSA01001');
    expect(together.captures.draftRow, DraftRow.caption);
    model.handle(launcher.Command.select);
    expect(model.editingRow, TogetherCaptures.captionRow);
    (together.captionField.kind as TextRow).set('First boss down');
    model.stopEditing();
    model.handle(launcher.Command.down);
    model.handle(launcher.Command.right);
    expect(draft.visibility, PostVisibility.public);
    model.handle(launcher.Command.down);
    model.handle(launcher.Command.select);
    await until(() => model.toast == 'Posted to Captures');
    expect(server.callsTo('posts', method: 'POST').single.body, {
      'media': ['media-1'],
      'visibility': 'public',
      'source': 'launcher',
      'caption': 'First boss down',
      'titleId': 'PPSA01001',
    });
    expect(together.captures.draft, isNull);

    together.openCaptures();
    await until(() => together.captures.feed.loaded);
    expect(together.captures.feed.items.where((post) => post.caption == 'First boss down'), hasLength(1));
    expect(model.overlay, Layer.captures);
  });

  test('a server that keeps no files: Captures says so, not that it failed to read', () async {
    final together = model.together;
    server.answers['me/captures'] = FakeTogether.problem(503, 'storage_disabled');
    together.openCaptures();
    await until(() => together.captures.failed);
    expect(model.saveSync.info?.enabled, isFalse);
  });

  test('a clip longer than a post takes is said before anything goes up', () async {
    final together = model.together;
    model.saveSync.info = const StorageInfo(enabled: true);
    together.clipToolsOverride = _Clips(90000);
    openGallery(name: 'clip.mp4');
    model.handle(launcher.Command.options);
    model.handle(launcher.Command.select);
    await until(() => together.captures.clipCheck != null);
    expect(together.captures.clipCheck, isA<ClipTooLong>());
    expect(together.canPostDraft, isFalse);
    await together.postCapture();
    expect(model.toast, 'This clip is 1:30 long');
    expect(server.calls.where((call) => call.path.startsWith('me/media')), isEmpty);

    // One that fits goes up with its poster.
    together.clipToolsOverride = _Clips(20000);
    await together.checkClip(together.captures.draftFile!);
    expect(together.captures.clipCheck, isA<ClipFits>());
    await together.postCapture();
    await until(() => model.toast == 'Posted to Captures');
    expect(server.calls.where((call) => call.path == 'me/media?kind=clip'), hasLength(1));
    expect(
      server.calls.where((call) => call.path.endsWith('/poster')).single.headers.contentType?.mimeType,
      'image/jpeg',
    );
  });

  test('Captures: a like at once, a comment and a reply, a delete pressed twice', () async {
    final together = model.together;
    model.open(Layer.friends);
    final row = model.panelCategories().single.rows.firstWhere((row) => row.id == 'friends-captures');
    expect(row.title, 'Captures');
    (row.kind as ActionRow).run();
    await until(() => together.captures.feed.loaded);
    expect(together.captures.feed.items.map((post) => post.id), ['p-mine', 'p-ana']);

    // Ana's: liked at once, then what the server says.
    model.handle(launcher.Command.down);
    model.handle(launcher.Command.select);
    expect(together.captures.feed.items[1].liked, isTrue);
    expect(together.captures.feed.items[1].likes, 3);
    await until(() => server.callsTo('posts/p-ana/like', method: 'PUT').isNotEmpty);

    // Comments: GG from the quick comments, then a reply to it.
    model.handle(launcher.Command.right);
    model.handle(launcher.Command.select);
    await until(() => together.captures.thread?.loaded ?? false);
    for (var press = 0; press < 5; press++) {
      model.handle(launcher.Command.left);
    }
    model.handle(launcher.Command.select);
    await until(() => model.toast == 'Comment sent');
    expect(server.callsTo('posts/p-ana/comments', method: 'POST').single.body, {'text': 'GG'});
    expect(together.captures.feed.items[1].comments, 1);
    model.handle(launcher.Command.down);
    model.handle(launcher.Command.select);
    expect(together.captures.replyTo?.text, 'GG');
    expect(model.editingRow, TogetherCaptures.commentRow);
    final field = together.commentField.kind as TextRow;
    field.set('Thanks!');
    field.submit!();
    await until(() => server.callsTo('posts/p-ana/comments', method: 'POST').length == 2);
    expect(server.callsTo('posts/p-ana/comments', method: 'POST').last.body['replyTo'], startsWith('c-'));
    await until(() => together.captures.thread!.lines.length == 2);
    expect(together.captures.thread!.lines.last.isReply, isTrue);
    model.handle(launcher.Command.back);
    expect(together.captures.thread, isNull);

    // My own: Delete is asked twice.
    model.handle(launcher.Command.up);
    for (var press = 0; press < 3; press++) {
      model.handle(launcher.Command.right);
    }
    expect(together.captureActions(together.focusedCapture!).last, CaptureAction.delete);
    model.handle(launcher.Command.select);
    expect(together.captures.armedPost, 'p-mine');
    expect(server.callsTo('posts/p-mine', method: 'DELETE'), isEmpty);
    model.handle(launcher.Command.select);
    await until(() => model.toast == 'Post deleted');
    expect(together.captures.feed.items.map((post) => post.id), ['p-ana']);

    // A friend's new post comes in on the socket.
    server.push('post.new', post('p-new', FakeTogether.card('u-ana', 'ana', 'Ana')));
    await until(() => together.captures.feed.items.length == 2);
    server.push('post.counts', {'postId': 'p-new', 'likes': 5, 'comments': 1});
    await until(() => together.captures.feed.items.first.likes == 5);
    model.handle(launcher.Command.back);
    expect(model.overlay, Layer.friends);
  });
}
