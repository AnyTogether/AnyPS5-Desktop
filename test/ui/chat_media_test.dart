import 'dart:io';

import 'package:anyps5_desktop/core/together/e2ee_client.dart';
import 'package:anyps5_desktop/core/together/messages.dart';
import 'package:anyps5_desktop/ui/app_model.dart' hide Command, GameState;
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:anyps5_desktop/ui/together_model.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_together.dart';
import '../support/ui_support.dart';

/// A picture file in a normal chat, chosen or dropped, as on the Mac. Against the fake server, so
/// no testWidgets in this file: its binding would answer every HTTP call with a 400.
void main() {
  late FakeTogether server;
  late Fixture fixture;
  late AppModel model;
  var ids = 0;

  Future<void> until(bool Function() condition) async {
    for (var tries = 0; tries < 300 && !condition(); tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(condition(), isTrue);
  }

  group('sending pictures', () {
    late List<String> picked;

    setUp(() async {
      server = await FakeTogether.start();
      server.friend('u-ana', 'ana', 'Ana', presence: {'state': 'online'});
      server.conversation('c-ana', [FakeTogether.card('u-ana', 'ana', 'Ana')], texts: [('u-ana', 'Hi!')]);
      server.handlers.add((call) {
        if (call.path == 'me/media?kind=image' && call.method == 'POST') {
          final id = 'media-${++ids}';
          server.mediaKinds[id] = 'image';
          return (
            201,
            {
              'media': {
                'id': id,
                'kind': 'image',
                'contentType': 'image/png',
                'size': 100,
                'width': 8,
                'height': 8,
                'url': '${server.base}/media/$id.png',
                'createdAt': '2026-11-07T10:00:00Z',
              },
            },
          );
        }
        return null;
      });
      picked = [];
      fixture = makeFixture(together: server.base, pickPictures: () async => picked);
      model = fixture.model;
      model.together.email = 'utku@example.com';
      await model.together.sendCode();
      model.together.code = '123456';
      await model.together.verify();
      await until(() => model.together.hub.messages.loaded);
    });

    tearDown(() async {
      model.dispose();
      await server.close();
      T.language = Language.english;
      fixture.dispose();
    });

    String pictureFile(String name) {
      final file = p.join(fixture.temp.path, name);
      File(file).writeAsBytesSync(png(16, 16, (x, y) => 0x3366FFFF));
      return file;
    }

    Conversation ana() => model.together.hub.messages.byId('c-ana')!;

    test("a conversation's options send picture files, drawn again, one after the other", () async {
      final together = model.together;
      await together.openMessages();
      together.openConversationMenu(ana());
      expect(together.messageMenuItems, ['photo', 'pin', 'mute']);
      expect(together.menuLabel('photo'), 'Send a photo');
      picked = [pictureFile('one.png'), pictureFile('two.jpg')];
      together.runMenuItem('photo');
      await until(() => server.callsTo('conversations/c-ana/messages', method: 'POST').length == 2);
      await until(() => model.toast == 'Sent to Ana');
      final uploads = server.calls.where((call) => call.path == 'me/media?kind=image').toList();
      expect(uploads, hasLength(2));
      expect(uploads.first.headers.contentType?.mimeType, 'image/png');
      final sent = server.callsTo('conversations/c-ana/messages', method: 'POST').first.body;
      expect(sent['attachments'], [
        {'mediaId': 'media-${ids - 1}'},
      ]);
      await until(() => together.hub.messages.thread.where((m) => m.kind == 'image').length == 2);
    });

    test('a conversation whose other side has no device takes none', () async {
      final together = model.together;
      await together.openMessages();
      together.e2ee.showLock(
        'c-ana',
        const ConversationLock(
          state: EncryptionState.noDevice,
          mine: UserDevices('u-me', [], []),
          theirs: UserDevices('u-ana', [], []),
        ),
      );
      together.openConversationMenu(ana());
      expect(together.messageMenuItems, isNot(contains('photo')));
    });

    test('dropped files: the pictures go, anything else is said no to', () async {
      final together = model.together;
      await together.openMessages();
      final notes = p.join(fixture.temp.path, 'notes.txt');
      File(notes).writeAsStringSync('hello');
      together.dropPictures([notes]);
      expect(model.toast, T.text('cloudBadMedia'));
      expect(server.callsTo('conversations/c-ana/messages', method: 'POST'), isEmpty);
      together.dropPictures([notes, pictureFile('shot.webp')]);
      await until(() => server.callsTo('conversations/c-ana/messages', method: 'POST').length == 1);
      await until(() => model.toast == 'Sent to Ana');
    });

    test('a file that is no picture says so', () async {
      final together = model.together;
      await together.openMessages();
      final bad = p.join(fixture.temp.path, 'broken.png');
      File(bad).writeAsBytesSync(Uint8List.fromList(List.filled(64, 7)));
      together.dropPictures([bad]);
      await until(() => model.toast == T.text('cloudBadMedia'));
      expect(server.calls.where((call) => call.path == 'me/media?kind=image'), isEmpty);
    });
  });
}
