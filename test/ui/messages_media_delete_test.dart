import 'dart:typed_data';

import 'package:anyps5_desktop/core/together/e2ee_client.dart';
import 'package:anyps5_desktop/core/together/messages.dart';
import 'package:anyps5_desktop/core/together/people.dart';
import 'package:anyps5_desktop/ui/app_model.dart' hide Command, GameState;
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:anyps5_desktop/ui/together_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/ui_support.dart';
import 'together_interface_test.dart' show signedInPreview;

/// A tester's report (2026-11-07): a photo sent from the website showed there but not in the
/// launcher, and he found no way to delete a message. A photo sent as it is shows as a picture
/// with its caption (never the server's "[photo]" stand-in), and the user's own message has
/// Delete for everyone, asked first.
/// A 1×1 transparent PNG.
const onePixelPng = [
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52, //
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4, //
  0x89,
  0x00,
  0x00,
  0x00,
  0x0B,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0x60,
  0x00,
  0x02,
  0x00, //
  0x00,
  0x05,
  0x00,
  0x01,
  0x7A,
  0x5E,
  0xAB,
  0x3F,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44, //
  0xAE, 0x42, 0x60, 0x82,
];

void main() {
  late Fixture fixture;
  late AppModel model;

  const ana = Person(id: 'u-ana', handle: 'ana', displayName: 'Ana');
  const me = Person(id: 'u-me', handle: 'utku', displayName: 'Utku Halis');

  /// A photo as GET /conversations/:id/messages lists one the website sent as it is.
  Map<String, dynamic> webPhoto(int seq, {String? caption}) => {
    'id': 'm$seq',
    'conversationId': 'c-ana',
    'seq': seq,
    'authorId': 'u-ana',
    'kind': 'image',
    'text': caption ?? '[photo]',
    'caption': caption,
    'attachments': [
      {
        'id': 'media-$seq',
        'kind': 'image',
        'contentType': 'image/webp',
        'size': 182000,
        'width': 1200,
        'height': 800,
        'durationMs': null,
        'url': 'http://127.0.0.1:9/api/v1/files/media/media-$seq/file?e=1&s=x',
        'thumb': 'http://127.0.0.1:9/api/v1/files/media/media-$seq/thumb?e=1&s=x',
        'poster': null,
        'createdAt': '2026-11-07T14:00:00.000Z',
      },
    ],
    'replyTo': null,
    'editedAt': null,
    'editCount': 0,
    'reactions': <Object>[],
    'deletedAt': null,
    'createdAt': '2026-11-07T14:0$seq:00.000Z',
  };

  void conversationWithAna(List<ChatMessage> thread) {
    signedInPreview(model);
    model.together.hub.messages
      ..conversations = [
        Conversation(
          id: 'c-ana',
          group: false,
          title: null,
          members: const [me, ana],
          lastSeq: thread.length,
          readSeq: thread.length,
          lastMessage: thread.last,
          updatedAt: DateTime.utc(2026, 11, 7),
        ),
      ]
      ..loaded = true
      ..openId = 'c-ana'
      ..thread = thread;
    model.together.e2ee.showLock(
      'c-ana',
      const ConversationLock(
        state: EncryptionState.off,
        mine: UserDevices('u-me', [], []),
        theirs: UserDevices('u-ana', [], []),
      ),
    );
    model.open(Layer.messages);
    model.together
      ..messagesInThread = true
      ..messageFocus = thread.length - 1;
  }

  var made = false;
  tearDown(() {
    T.language = Language.english;
    if (made) fixture.dispose();
    made = false;
  });

  test('a photo sent as it is reads as its caption, or as Photo, never as "[photo]"', () {
    final bare = ChatMessage.fromJson(webPhoto(1));
    final captioned = ChatMessage.fromJson(webPhoto(2, caption: 'Look at this'));
    expect(bare.media!.url, contains('media-1/file'));
    expect(bare.media!.aspect, 1.5);
    expect(TogetherMessages.shownText(bare), '');
    expect(TogetherMessages.shownText(captioned), 'Look at this');
    expect(bare.words, isNull);
    expect(captioned.words, 'Look at this');
    expect(TogetherMessages.previewText(bare), 'Photo');
    expect(TogetherMessages.previewText(captioned), 'Look at this');
  });

  testWidgets('a photo from the website shows as a picture in its own shape, with its caption', (tester) async {
    fixture = makeFixture();
    made = true;
    model = fixture.model;
    conversationWithAna([
      ChatMessage.fromJson(webPhoto(1)),
      ChatMessage.fromJson(webPhoto(2, caption: 'Look at this')),
    ]);
    // The pictures as if downloaded already: nothing goes to the network here.
    for (final seq in [1, 2]) {
      model.together.captures.pictures['http://127.0.0.1:9/api/v1/files/media/media-$seq/file'] = Future.value(
        Uint8List.fromList(onePixelPng),
      );
    }
    await pumpLauncher(tester, model);
    expect(find.text('[photo]'), findsNothing);
    expect(find.text('Look at this'), findsWidgets);
    expect(find.byWidgetPredicate((widget) => widget is AspectRatio && widget.aspectRatio == 1.5), findsNWidgets(2));
  });

  testWidgets('the user\'s own message: Delete for everyone, asked first, in Turkish too', (tester) async {
    fixture = makeFixture(language: Language.byCode('tr'));
    made = true;
    model = fixture.model;
    final mine = ChatMessage(
      id: 'm1',
      conversationId: 'c-ana',
      seq: 1,
      authorId: 'u-me',
      text: 'Yanlış kişiye gitti',
      createdAt: DateTime.utc(2026, 11, 7, 14),
    );
    conversationWithAna([mine]);
    await pumpLauncher(tester, model);
    model.together.openMessageMenu(mine);
    await tester.pumpAndSettle();
    expect(model.together.messageMenuItems, contains('unsend'));
    expect(find.text('Herkesten sil'), findsOneWidget);
    model.together.runMenuItem('unsend');
    await tester.pumpAndSettle();
    expect(model.together.messageMenuItems, ['unsend-confirm', 'cancel']);
    expect(find.text('Bu mesaj herkesten silinsin mi? Geri getirilemez.'), findsOneWidget);
  });
}
