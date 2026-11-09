import 'package:anyps5_desktop/ui/app_model.dart' hide Command, GameState;
import 'package:anyps5_desktop/ui/app_model.dart' as launcher show Command;
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:anyps5_desktop/ui/together_model.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_together.dart';
import '../support/ui_support.dart';

/// The party screen's chat against the pretend AnyTogether: the keys go into it and out, a
/// message is sent, answered, reacted to, edited, unsent and reported, and none of it reaches
/// the inbox. (Rendered in together_interface_test.dart: a file with widget tests gets Flutter's
/// HTTP stand-in.)
void main() {
  late FakeTogether server;
  late Fixture fixture;
  late AppModel model;

  Future<void> until(bool Function() condition) async {
    for (var tries = 0; tries < 300 && !condition(); tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(condition(), isTrue);
  }

  final ana = FakeTogether.card('u-ana', 'ana', 'Ana');
  final cem = FakeTogether.card('u-cem', 'cem', 'Cem');

  Future<void> signIn({bool chat = true}) async {
    server = await FakeTogether.start();
    server
      ..friend('u-ana', 'ana', 'Ana', presence: {'state': 'online'})
      ..friend('u-cem', 'cem', 'Cem');
    // Sent just now, so the user's own can still be edited.
    server.messageTime = (seq) => DateTime.now().toUtc().subtract(Duration(seconds: 60 - seq)).toIso8601String();
    server.conversation('c-ana', [ana], texts: [('u-ana', 'Hi!')]);
    server.inParty([ana, cem]);
    if (chat) {
      server.partyChat('chat-1', texts: [('u-ana', 'Ready?'), ('u-dan', 'Bye all'), ('u-me', 'Almost')]);
    }
    fixture = makeFixture(together: server.base);
    model = fixture.model;
    model.together.email = 'utku@example.com';
    await model.together.sendCode();
    model.together.code = '123456';
    await model.together.verify();
    await until(() => model.together.hub.parties.loaded && model.together.hub.messages.loaded);
  }

  tearDown(() async {
    model.dispose();
    await server.close();
    T.language = Language.english;
    fixture.dispose();
  });

  TextRow field() => model.together.partyDraftField.kind as TextRow;

  test('the party screen: the chat comes in and is read; → goes into it, ← and Back out', () async {
    await signIn();
    final together = model.together;
    final chat = together.hub.partyChat;
    expect(together.partyChatShown, isTrue);
    expect(chat.loaded, isFalse);
    model.open(Layer.party);
    await until(() => chat.thread.length == 3);
    expect(server.callsTo('conversations/chat-1/messages?limit=40'), hasLength(1));
    await until(() => server.callsTo('conversations/chat-1/read').isNotEmpty);
    expect(server.callsTo('conversations/chat-1/read').single.body, {'upToSeq': 3});

    // Who wrote: a member, and someone this launcher never saw in the party.
    expect(together.partyAuthorName('u-ana'), 'Ana');
    expect(together.partyAuthorName('u-dan'), 'Former member');

    expect(model.panelCategories().single.rows[model.panelRow].id, 'voice-join');
    model.handle(launcher.Command.right);
    expect(together.partyChatKeys.focused, isTrue);
    model.handle(launcher.Command.up);
    expect(together.focusedPartyMessage!.text, 'Almost');
    model.handle(launcher.Command.up);
    expect(together.focusedPartyMessage!.text, 'Bye all');
    model.handle(launcher.Command.back);
    expect(together.focusedPartyMessage, isNull);
    // ← from the field goes onto the quick replies; Back leaves the chat, as ← does past the
    // first of them.
    model.handle(launcher.Command.left);
    expect(together.partyChatKeys.focused, isTrue);
    expect(together.partyChatKeys.place, TogetherMessages.composer - 1);
    model.handle(launcher.Command.back);
    expect(together.partyChatKeys.focused, isFalse);
    expect(model.overlay, Layer.party);

    // The pointer on a row takes the keys back to the rows; from a toggle → is still the toggle's.
    model.handle(launcher.Command.right);
    final privacy = model.panelCategories().single.rows.indexWhere((row) => row.id == 'party-privacy');
    model.hoverRow(privacy);
    expect(together.partyChatKeys.focused, isFalse);
    final open = server.party!['privacy'];
    model.handle(launcher.Command.right);
    expect(together.partyChatKeys.focused, isFalse);
    await until(() => server.party!['privacy'] != open);

    model.handle(launcher.Command.back);
    expect(model.overlay, isNull);
  });

  test('writing: typing is told, Enter sends; a reply quotes; a message that fails says why', () async {
    await signIn();
    final together = model.together;
    final chat = together.hub.partyChat;
    model.open(Layer.party);
    await until(() => chat.thread.length == 3);
    model.handle(launcher.Command.right);
    model.handle(launcher.Command.select);
    expect(model.editingRow, 'party-chat-draft');
    field().set('On my way');
    final typing = await server.nextFrame('typing');
    expect(typing['conversation'], 'chat-1');
    field().submit!();
    model.stopEditing();
    await until(() => server.threads['chat-1']!.length == 4);
    expect(server.threads['chat-1']!.last['text'], 'On my way');
    expect(together.partyChatKeys.draft, isEmpty);

    // Reply to Ana's.
    model.handle(launcher.Command.up);
    model.handle(launcher.Command.up);
    model.handle(launcher.Command.up);
    model.handle(launcher.Command.up);
    expect(together.focusedPartyMessage!.text, 'Ready?');
    model.handle(launcher.Command.select);
    expect(together.partyMenuItems, ['react', 'reply', 'report'], reason: "Ana's: no edit, no unsend");
    model.handle(launcher.Command.down);
    model.handle(launcher.Command.select);
    expect(together.partyChatKeys.replyingTo, 1);
    expect(model.editingRow, 'party-chat-draft');
    expect(together.partyComposerNote, ('Replying to Ana', 'Ready?'));
    field().set('Yes');
    field().submit!();
    model.stopEditing();
    await until(() => server.threads['chat-1']!.length == 5);
    expect(server.callsTo('conversations/chat-1/messages', method: 'POST').last.body['replyTo'], 1);
    await until(() => chat.thread.last.seq == 5);
    expect(together.partyQuoteOf(chat.thread.last), ('Ana', 'Ready?'));

    // Too many at once: said so, and the message waits to go again.
    server.answers['POST conversations/chat-1/messages'] = FakeTogether.problem(429, 'rate_limited');
    await together.sendPartyMessage('Again');
    expect(model.toast, T.text('togetherTooMany'));
    expect(chat.thread.last.failed, isTrue);
    server.answers.remove('POST conversations/chat-1/messages');
    model.handle(launcher.Command.select);
    await until(() => !chat.thread.last.failed && chat.thread.last.seq == 6);
  });

  test('a message: react, report with a reason; my own: edit, unsend after asking', () async {
    await signIn();
    final together = model.together;
    final chat = together.hub.partyChat;
    model.open(Layer.party);
    await until(() => chat.thread.length == 3);
    model.handle(launcher.Command.right);
    model.handle(launcher.Command.up);
    model.handle(launcher.Command.up);
    model.handle(launcher.Command.up);
    model.handle(launcher.Command.select);
    // 🔥: the sixth.
    for (var i = 0; i < 5; i++) {
      model.handle(launcher.Command.right);
    }
    model.handle(launcher.Command.select);
    await until(() => chat.thread.first.reactions.isNotEmpty);
    expect(server.callsTo('conversations/chat-1/messages/1/reactions/fire', method: 'PUT'), hasLength(1));

    // Report: the reasons, who reads it; the moderators get it.
    model.handle(launcher.Command.select);
    model.handle(launcher.Command.down);
    model.handle(launcher.Command.down);
    expect(together.partyMenuItems[2], 'report');
    model.handle(launcher.Command.select);
    expect(together.partyMenuItems, [
      'reason-spam',
      'reason-harassment',
      'reason-hate',
      'reason-sexual',
      'reason-other',
      'cancel',
    ]);
    expect(together.partyMenuHeading, (
      'Report this message',
      'A moderator reads it. Its author is not told who sent the report.',
    ));
    model.handle(launcher.Command.down);
    model.handle(launcher.Command.select);
    await until(() => server.reports.isNotEmpty);
    expect(server.reports.single, {'targetKind': 'message', 'targetId': 'm-chat-1-1', 'reason': 'harassment'});
    await until(() => model.toast == 'Thanks. A moderator will look at it.');
    expect(together.partyChatKeys.menu, isNull);

    // Mine: edit, then unsend after asking.
    model.handle(launcher.Command.down);
    model.handle(launcher.Command.down);
    expect(together.focusedPartyMessage!.text, 'Almost');
    model.handle(launcher.Command.select);
    expect(together.partyMenuItems, ['react', 'reply', 'edit', 'unsend']);
    model.handle(launcher.Command.down);
    model.handle(launcher.Command.down);
    model.handle(launcher.Command.select);
    expect(together.partyChatKeys.editing?.seq, 3);
    expect(together.partyChatKeys.draft, 'Almost');
    field().set('Almost there');
    field().submit!();
    model.stopEditing();
    await until(() => chat.thread.last.text == 'Almost there');
    expect(server.callsTo('conversations/chat-1/messages/3', method: 'PATCH').single.body, {'text': 'Almost there'});

    model.handle(launcher.Command.up);
    model.handle(launcher.Command.select);
    model.handle(launcher.Command.down);
    model.handle(launcher.Command.down);
    model.handle(launcher.Command.down);
    model.handle(launcher.Command.select);
    expect(together.partyMenuItems, ['unsend-confirm', 'cancel']);
    model.handle(launcher.Command.select);
    await until(() => chat.thread.last.deleted);
    expect(server.callsTo('conversations/chat-1/messages/3', method: 'DELETE'), hasLength(1));
  });

  test('the party chat never reaches the inbox: no word, no badge', () async {
    await signIn();
    final together = model.together;
    await until(() => together.unread == 1);
    server.receive('chat-1', 'u-ana', 'Party only');
    server.receive('c-ana', 'u-ana', 'For the inbox');
    await until(() => model.toast == 'Ana: For the inbox');
    expect(together.unread, 2);
    expect(together.hub.messages.byId('chat-1'), isNull);

    // While the party screen shows the chat, what comes is read at once.
    model.open(Layer.party);
    await until(() => together.hub.partyChat.loaded);
    server.receive('chat-1', 'u-cem', 'Seen');
    await until(() => server.callsTo('conversations/chat-1/read').length == 2);
    expect(server.callsTo('conversations/chat-1/read').last.body, {'upToSeq': 5});
  });

  test('quick replies: ← and → reach them, Enter sends one, ← past the first leaves, as on the Mac', () async {
    await signIn();
    final together = model.together;
    final chat = together.hub.partyChat;
    model.open(Layer.party);
    await until(() => chat.thread.length == 3);
    model.handle(launcher.Command.right);
    expect(together.partyChatKeys.place, TogetherMessages.composer, reason: 'the field first');
    for (var step = 0; step < TogetherMessages.composer - 1; step++) {
      model.handle(launcher.Command.left);
    }
    expect(together.partyChatKeys.place, 1, reason: 'on GG');
    model.handle(launcher.Command.select);
    await until(() => server.threads['chat-1']!.length == 4);
    expect(server.threads['chat-1']!.last['text'], 'GG');
    model.handle(launcher.Command.right);
    expect(together.partyChatKeys.place, 2);
    while (together.partyChatKeys.focused) {
      model.handle(launcher.Command.left);
    }
    expect(model.overlay, Layer.party);
  });

  test('others\' messages count for the Party tile until the party screen is shown', () async {
    await signIn();
    final together = model.together;
    expect(together.partyChatUnread, 0);
    server.receive('chat-1', 'u-ana', 'Over here');
    server.receive('chat-1', 'u-cem', 'Yes');
    await until(() => together.partyChatUnread == 2);
    model.open(Layer.party);
    expect(together.partyChatUnread, 0, reason: 'zero while the screen shows the chat');
    await until(() => together.hub.partyChat.thread.length == 5);
    model.closeOverlay();
    expect(together.partyChatUnread, 0, reason: 'read on opening');
    server.receive('chat-1', 'u-cem', 'Later');
    await until(() => together.partyChatUnread == 1);
  });

  test('an older server sends no chat: the party screen is as before', () async {
    await signIn(chat: false);
    final together = model.together;
    expect(together.partyChatShown, isFalse);
    model.open(Layer.party);
    final before = model.panelRow;
    model.handle(launcher.Command.right);
    expect(together.partyChatKeys.focused, isFalse);
    expect(model.panelRow, before);
    expect(server.calls.where((call) => call.path.startsWith('conversations/chat')), isEmpty);
  });
}
