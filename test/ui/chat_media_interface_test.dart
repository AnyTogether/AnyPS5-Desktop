import 'package:anyps5_desktop/core/libmpv.dart';
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

/// The typing line, dragging files over a chat, and voice notes in their bubbles, as on the Mac.
void main() {
  late Fixture fixture;
  late AppModel model;

  Future<void> until(bool Function() condition) async {
    for (var tries = 0; tries < 300 && !condition(); tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(condition(), isTrue);
  }

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

    test('Linux without libmpv: a voice note goes to the system, and the first says how to install it', () async {
      fixture = makeFixture(voicePlayback: () => throw const LibmpvMissing(['sudo apt install libmpv2']));
      model = fixture.model;
      openThread([voice(1, 'v1'), voice(2, 'v2')]);
      model.together.viewChatMedia(voice(1, 'v1').media!);
      await until(() => fixture.opened.length == 1);
      expect(fixture.opened.single.toString(), 'https://cdn.test/v1.ogg');
      expect(model.toast, 'Install libmpv to play voice notes in the launcher: sudo apt install libmpv2');
      model.toast = null;
      model.together.viewChatMedia(voice(2, 'v2').media!);
      await until(() => fixture.opened.length == 2);
      expect(model.toast, isNull, reason: 'said once');
    });

    test('Linux without libmpv on a distribution it does not know: the plain sentence', () async {
      fixture = makeFixture(voicePlayback: () => throw const LibmpvMissing(SystemLibmpv.all));
      model = fixture.model;
      openThread([voice(1, 'v1')]);
      model.together.viewChatMedia(voice(1, 'v1').media!);
      await until(() => fixture.opened.length == 1);
      expect(model.toast, 'Install libmpv to play voice notes in the launcher.');
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
