import 'dart:io';

import 'package:anyps5_desktop/core/together/e2ee_client.dart';
import 'package:anyps5_desktop/core/together/messages.dart';
import 'package:anyps5_desktop/core/together/people.dart' show Person;
import 'package:anyps5_desktop/ui/app_model.dart' hide Command, GameState;
import 'package:anyps5_desktop/ui/messages_view.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:anyps5_desktop/ui/together_model.dart';
import 'package:anyps5_desktop/ui/voice_note_player.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_together.dart';
import '../support/ui_support.dart';
import 'together_interface_test.dart' show signedInPreview;

/// A voice note player that plays nothing: what it was asked to open, pause and stop.
class FakeVoicePlayback implements VoicePlayback {
  final opened = <String>[];
  int toggles = 0;
  int stops = 0;
  final _state = ValueNotifier(const VoiceTrack());

  @override
  ValueListenable<VoiceTrack> get state => _state;

  set now(VoiceTrack track) => _state.value = track;

  @override
  Future<void> open(String source) async {
    opened.add(source);
    _state.value = const VoiceTrack(playing: true, duration: Duration(seconds: 8));
  }

  @override
  Future<void> playOrPause() async {
    toggles++;
    _state.value = _state.value.copyWith(playing: !_state.value.playing);
  }

  @override
  Future<void> stop() async => stops++;

  @override
  Future<void> dispose() async {}
}

/// A picture file in a normal chat (chosen or dropped), the typing line and voice notes, as on
/// the Mac.
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

  group('the thread', () {
    const ana = Person(id: 'u-ana', handle: 'ana', displayName: 'Ana');
    const bora = Person(id: 'u-bora', handle: 'bora', displayName: 'Bora');
    const me = Person(id: 'u-me', handle: 'utku', displayName: 'Utku Halis');

    ChatMessage voice(int seq, String mediaId) => ChatMessage(
      id: 'm$seq',
      conversationId: 'c-group',
      seq: seq,
      authorId: 'u-ana',
      text: null,
      createdAt: DateTime.utc(2026, 11, 6, 20, seq),
      kind: 'voice',
      media: MediaLink(id: mediaId, kind: 'voice', url: 'https://cdn.test/$mediaId.ogg', durationMs: 7000),
    );

    void openThread(List<ChatMessage> thread) {
      signedInPreview(model);
      model.together.hub.messages
        ..conversations = [
          Conversation(
            id: 'c-group',
            group: true,
            title: 'Night crew',
            members: const [me, ana, bora],
            lastSeq: thread.length,
            readSeq: thread.length,
            lastMessage: thread.isEmpty ? null : thread.last,
            updatedAt: DateTime.utc(2026, 11, 6),
          ),
        ]
        ..loaded = true
        ..openId = 'c-group'
        ..thread = thread;
      model.open(Layer.messages);
    }

    tearDown(() {
      T.language = Language.english;
      fixture.dispose();
    });

    testWidgets('the typing line names everyone', (tester) async {
      fixture = makeFixture();
      model = fixture.model;
      openThread([]);
      final conversation = model.together.hub.messages.byId('c-group')!;
      expect(model.together.typingText(conversation, const []), isNull);
      expect(model.together.typingText(conversation, const ['u-ana']), 'Ana is typing…');
      expect(model.together.typingText(conversation, const ['u-ana', 'u-bora']), 'Ana, Bora are typing…');
    });

    testWidgets('files dragged over the conversation: the frame says so, letting go sends them', (tester) async {
      fixture = makeFixture();
      model = fixture.model;
      openThread([voice(1, 'v1')]);
      await pumpLauncher(tester, model);
      final target = tester.widget<DropTarget>(find.byType(DropTarget));
      expect(target.enable, isTrue);
      target.onDragEntered!(DropEventDetails(localPosition: Offset.zero, globalPosition: Offset.zero));
      await tester.pump();
      expect(find.text('Send a photo'), findsOneWidget);
      target.onDragExited!(DropEventDetails(localPosition: Offset.zero, globalPosition: Offset.zero));
      await tester.pump();
      expect(find.text('Send a photo'), findsNothing);
    });

    testWidgets('a voice note plays in its bubble, one at a time, and leaving stops it', (tester) async {
      final players = <FakeVoicePlayback>[];
      fixture = makeFixture(voicePlayback: () => FakeVoicePlayback()..let(players.add));
      model = fixture.model;
      openThread([voice(1, 'v1'), voice(2, 'v2')]);
      await pumpLauncher(tester, model);
      expect(find.text('0:07'), findsNWidgets(2));

      // The older note, at the top of the thread; the newest is first in the list.
      await tester.tap(find.text('0:07').last);
      await tester.pump();
      await tester.pump();
      expect(players.single.opened, ['https://cdn.test/v1.ogg']);
      expect(model.together.voiceNotes.state.value.id, 'v1');
      expect(model.together.voiceNotes.state.value.playing, isTrue);

      // Halfway through: the bars and the clock show it.
      players.single.now = const VoiceTrack(
        playing: true,
        position: Duration(seconds: 4),
        duration: Duration(seconds: 8),
      );
      await tester.pump();
      expect(model.together.voiceNotes.state.value.progress, closeTo(0.5, 0.01));
      expect(find.text('0:04'), findsOneWidget);

      // A second press pauses it.
      await tester.tap(find.text('0:04'));
      await tester.pump();
      expect(players.single.toggles, 1);
      expect(model.together.voiceNotes.state.value.playing, isFalse);

      // The other note takes over.
      await tester.tap(find.text('0:07').first);
      await tester.pump();
      await tester.pump();
      expect(players.single.opened, ['https://cdn.test/v1.ogg', 'https://cdn.test/v2.ogg']);
      expect(model.together.voiceNotes.state.value.id, 'v2');

      // Its end: back at the start, and a press plays it from the start.
      players.single.now = const VoiceTrack(duration: Duration(seconds: 8), ended: true);
      await tester.pump();
      expect(model.together.voiceNotes.state.value.playing, isFalse);
      expect(model.together.voiceNotes.state.value.progress, 0);
      await tester.tap(find.text('0:07').first);
      await tester.pump();
      await tester.pump();
      expect(players.single.opened, hasLength(3));

      // The conversation left: it stops.
      model.closeOverlay();
      await tester.pumpAndSettle();
      expect(find.byType(MessagesView), findsNothing);
      expect(players.single.stops, greaterThan(0));
      expect(model.together.voiceNotes.state.value.id, isNull);
    });

    test('the message menu plays a sealed voice note; a player that cannot open it hands it to the system', () async {
      final player = FakeVoicePlayback();
      fixture = makeFixture(voicePlayback: () => player);
      model = fixture.model;
      final note = voice(1, 'v1');
      openThread([note]);
      final together = model.together;
      together.openMessageMenu(note);
      expect(together.messageMenuItems, contains('open'));
      together.runMenuItem('open');
      await until(() => player.opened.length == 1);
      expect(fixture.opened, isEmpty);

      player.now = const VoiceTrack(failed: true);
      await until(() => fixture.opened.length == 1);
      expect(fixture.opened.single.toString(), 'https://cdn.test/v1.ogg');
      expect(together.voiceNotes.state.value.id, isNull);
    });

    test('without the launcher\'s player a voice note goes to the system', () async {
      fixture = makeFixture();
      model = fixture.model;
      openThread([voice(1, 'v1')]);
      model.together.viewChatMedia(voice(1, 'v1').media!);
      await until(() => fixture.opened.length == 1);
      expect(fixture.opened.single.toString(), 'https://cdn.test/v1.ogg');
    });
  });
}

extension<T> on T {
  T let(void Function(T) use) {
    use(this);
    return this;
  }
}
