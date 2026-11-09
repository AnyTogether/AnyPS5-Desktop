import 'package:anyps5_desktop/core/together/account.dart';
import 'package:anyps5_desktop/core/together/messages.dart';
import 'package:anyps5_desktop/core/together/parties.dart';
import 'package:anyps5_desktop/core/together/party_chat.dart';
import 'package:anyps5_desktop/core/together/socket.dart';
import 'package:anyps5_desktop/core/together/token_store.dart';
import 'package:test/test.dart';

import '../support/fake_together.dart';

/// The party's chat against the pretend AnyTogether: the party view names it, its history comes
/// in pages, everything a thread does works in it, and it stays out of the inbox.
void main() {
  late FakeTogether server;
  late TogetherAccount account;
  late TogetherSocket socket;
  late Messages messages;
  late Parties parties;
  late PartyChat chat;
  var shown = false;

  Future<void> until(bool Function() condition) async {
    for (var tries = 0; tries < 300 && !condition(); tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(condition(), isTrue);
  }

  final ana = FakeTogether.card('u-ana', 'ana', 'Ana');
  final cem = FakeTogether.card('u-cem', 'cem', 'Cem');

  setUp(() async {
    shown = false;
    server = await FakeTogether.start();
    server.friend('u-ana', 'ana', 'Ana');
    server.conversation('c-ana', [ana], texts: [('u-ana', 'Hi!')]);
    server.inParty([ana, cem]);
    server.partyChat(
      'chat-1',
      texts: [for (var seq = 1; seq <= 45; seq++) (seq.isEven ? 'u-ana' : 'u-cem', 'Line $seq')],
    );
    account = TogetherAccount(base: server.base, store: MemoryTokenStore(), clientName: 'launcher-linux/0.1.0 (Linux)');
    await account.startEmail('utku@example.com');
    await account.verifyEmail('123456');
    socket = TogetherSocket(
      account: account,
      retryBase: const Duration(milliseconds: 10),
      retryMost: const Duration(milliseconds: 40),
    );
    messages = Messages(account: account, socket: socket);
    parties = Parties(account: account, socket: socket);
    chat = PartyChat(account: account, socket: socket, parties: parties, messages: messages)..shown = () => shown;
    socket.start();
    await until(() => parties.loaded && messages.loaded);
  });

  tearDown(() async {
    chat.dispose();
    parties.dispose();
    messages.dispose();
    socket.dispose();
    account.close();
    await server.close();
  });

  test('the party view names its chat; an older server and someone outside get none', () {
    expect(parties.party!.conversationId, 'chat-1');
    expect(chat.id, 'chat-1');
    final older = Party.fromJson({'id': 'p-1', 'leaderId': 'u-me', 'members': <Object>[]});
    expect(older.conversationId, isNull);
    expect(Party.fromJson({'id': 'p-1', 'conversationId': ''}).conversationId, isNull);
    // A member joining keeps it.
    expect(older.copyWith(open: true).conversationId, isNull);
    expect(parties.party!.copyWith(open: true).conversationId, 'chat-1');
    expect(
      Conversation.fromJson({'id': 'chat-1', 'kind': 'group', 'partyId': 'p-1', 'members': <Object>[]}).partyId,
      'p-1',
    );
  });

  test('shown: the newest forty, older ones on the way up, and read up to the newest', () async {
    expect(chat.loaded, isFalse, reason: 'nothing is read before the party screen opens');
    shown = true;
    await chat.show();
    expect(server.callsTo('conversations/chat-1/messages?limit=40'), hasLength(1));
    expect(chat.thread.map((m) => m.seq).first, 6);
    expect(chat.thread.length, 40);
    expect(chat.more, isTrue);
    expect(server.callsTo('conversations/chat-1/read').single.body, {'upToSeq': 45});
    await chat.older();
    expect(server.callsTo('conversations/chat-1/messages?limit=40&before=6'), hasLength(1));
    expect(chat.thread.first.seq, 1);
    expect(chat.more, isFalse);
    // Opening it again reads nothing new.
    await chat.show();
    expect(server.callsTo('conversations/chat-1/read'), hasLength(1));
  });

  test('send, reply, edit, unsend, react and report, as a thread does', () async {
    shown = true;
    await chat.show();
    await chat.send('  Ready?  ');
    final sent = server.callsTo('conversations/chat-1/messages', method: 'POST').single.body;
    expect(sent['text'], 'Ready?');
    expect(sent['clientId'], chat.thread.last.id);
    expect(chat.thread.last.seq, 46);
    expect(chat.thread.last.pending, isFalse);

    await chat.send('Yes', replyTo: 45);
    expect(server.callsTo('conversations/chat-1/messages', method: 'POST').last.body['replyTo'], 45);

    await chat.edit(chat.thread.last, 'Yes!');
    expect(server.callsTo('conversations/chat-1/messages/47', method: 'PATCH').single.body, {'text': 'Yes!'});
    expect(chat.thread.last.text, 'Yes!');
    expect(chat.thread.last.edited, isTrue);

    await chat.unsend(chat.thread.last);
    expect(server.callsTo('conversations/chat-1/messages/47', method: 'DELETE'), hasLength(1));
    expect(chat.thread.last.deleted, isTrue);

    final anas = chat.inThread(44)!;
    await chat.react(anas, 'gg');
    expect(server.callsTo('conversations/chat-1/messages/44/reactions/gg', method: 'PUT'), hasLength(1));
    expect(chat.inThread(44)!.reacted('gg', 'u-me'), isTrue);
    await chat.react(chat.inThread(44)!, 'gg');
    expect(server.callsTo('conversations/chat-1/messages/44/reactions/gg', method: 'DELETE'), hasLength(1));
    expect(chat.inThread(44)!.reactions, isEmpty);

    await chat.report(anas, 'harassment');
    expect(server.reports.single, {'targetKind': 'message', 'targetId': anas.id, 'reason': 'harassment'});
  });

  test('a message that does not get there fails, says why, and goes again with the same id', () async {
    shown = true;
    await chat.show();
    Object? why;
    chat.onSendFailed = (error) => why = error;
    server.answers['POST conversations/chat-1/messages'] = FakeTogether.problem(429, 'rate_limited');
    await chat.send('Too fast');
    expect((why as TogetherProblem?)?.status, 429);
    expect(chat.thread.last.failed, isTrue);
    server.answers.remove('POST conversations/chat-1/messages');
    final first = chat.thread.last.id;
    await chat.retry(chat.thread.last);
    expect(server.callsTo('conversations/chat-1/messages', method: 'POST').last.body['clientId'], first);
    expect(chat.thread.last.failed, isFalse);
    expect(chat.thread.last.seq, 46);
  });

  test('live: messages, edits, removals, reactions and typing; read at once while shown', () async {
    shown = true;
    await chat.show();
    server.push('typing', {'conversationId': 'chat-1', 'userId': 'u-ana'});
    await until(() => chat.typingNow.isNotEmpty);
    expect(chat.typingNow, ['u-ana']);
    server.receive('chat-1', 'u-ana', 'GG');
    await until(() => chat.thread.last.text == 'GG');
    expect(chat.typingNow, isEmpty, reason: 'a message ends its author\'s typing');
    await until(() => server.callsTo('conversations/chat-1/read').length == 2);
    expect(server.callsTo('conversations/chat-1/read').last.body, {'upToSeq': 46});

    // Not shown: it comes in, unread.
    shown = false;
    server.receive('chat-1', 'u-cem', 'Again?');
    await until(() => chat.thread.last.text == 'Again?');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(server.callsTo('conversations/chat-1/read'), hasLength(2));

    server.push('message.updated', {...server.threads['chat-1']!.last, 'text': 'Again!', 'editedAt': 'now'});
    await until(() => chat.thread.last.text == 'Again!');
    server.push('message.reactions', {
      'conversationId': 'chat-1',
      'seq': 47,
      'reactions': [
        {
          'reaction': 'fire',
          'count': 1,
          'userIds': ['u-ana'],
        },
      ],
    });
    await until(() => chat.thread.last.reactions.isNotEmpty);
    server.push('message.deleted', {...server.threads['chat-1']!.last, 'deletedAt': 'now'});
    await until(() => chat.thread.last.deleted);
    expect(chat.thread.last.reactions, isEmpty);

    // Typing goes out for the chat, at most every two seconds.
    chat.typing();
    chat.typing();
    final frame = await server.nextFrame('typing');
    expect(frame['conversation'], 'chat-1');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(server.frames.where((f) => f['op'] == 'typing'), isEmpty);
  });

  test('after a reconnect, what came meanwhile', () async {
    shown = true;
    await chat.show();
    await server.dropSockets();
    server.threads['chat-1']!.add({...server.threads['chat-1']!.last, 'id': 'm-46', 'seq': 46, 'text': 'While away'});
    await until(() => server.callsTo('conversations/chat-1/messages?limit=40&after=45').isNotEmpty);
    await until(() => chat.thread.last.text == 'While away');
  });

  test('a reconnect reads every page that came while away, up to ten, as on the Mac', () async {
    shown = true;
    await chat.show();
    await server.dropSockets();
    final last = server.threads['chat-1']!.last;
    server.threads['chat-1']!.addAll([
      for (var seq = 46; seq <= 130; seq++) {...last, 'id': 'm-$seq', 'seq': seq, 'text': 'Line $seq'},
    ]);
    await until(() => chat.thread.last.text == 'Line 130');
    expect(server.callsTo('conversations/chat-1/messages?limit=40&after=45'), hasLength(1));
    expect(server.callsTo('conversations/chat-1/messages?limit=40&after=85'), hasLength(1));
    expect(server.callsTo('conversations/chat-1/messages?limit=40&after=125'), hasLength(1));
  });

  test('others\' messages count as unread unless the chat is shown, and unsending takes one back', () async {
    expect(chat.unread, 0);
    server.receive('chat-1', 'u-ana', 'One');
    server.receive('chat-1', 'u-cem', 'Two');
    await until(() => chat.unread == 2);
    expect(chat.loaded, isFalse, reason: 'counted before the history was ever read');
    await chat.show();
    expect(chat.unread, 0, reason: 'shown: read');
    shown = true;
    server.receive('chat-1', 'u-ana', 'Seen');
    await until(() => chat.thread.last.text == 'Seen');
    expect(chat.unread, 0);
    shown = false;
    server.receive('chat-1', 'u-ana', 'Gone soon');
    await until(() => chat.unread == 1);
    server.push('message.deleted', {
      ...server.threads['chat-1']!.last,
      'deletedAt': DateTime.now().toUtc().toIso8601String(),
    });
    await until(() => chat.unread == 0);
  });

  test('stays out of the inbox: no unread, no list read again, whatever comes', () async {
    expect(messages.elsewhere, {'chat-1'});
    final lists = server.callsTo('me/conversations').length;
    final counts = server.callsTo('me/conversations/unread').length;
    for (var i = 0; i < 3; i++) {
      server.receive('chat-1', 'u-ana', 'Party $i');
    }
    server.push('conversation.read', {'conversationId': 'chat-1', 'userId': 'u-me', 'upToSeq': 48, 'unread': 0});
    // Something for the inbox after it, to know the events went by.
    server.receive('c-ana', 'u-ana', 'Inbox');
    await until(() => messages.unread == 2);
    expect(messages.byId('chat-1'), isNull);
    expect(server.callsTo('me/conversations'), hasLength(lists));
    expect(server.callsTo('me/conversations/unread'), hasLength(counts));
  });

  test('a conversation the list does not have is read for once, not for every message', () async {
    server.threads['c-community'] = [];
    final lists = server.callsTo('me/conversations').length;
    server.push('message.created', {
      'id': 'm-x1',
      'conversationId': 'c-community',
      'seq': 1,
      'authorId': 'u-ana',
      'text': 'Hello all',
      'createdAt': '2026-10-24T20:00:00Z',
    });
    await until(() => server.callsTo('me/conversations').length == lists + 1);
    for (var seq = 2; seq <= 4; seq++) {
      server.push('message.created', {
        'id': 'm-x$seq',
        'conversationId': 'c-community',
        'seq': seq,
        'authorId': 'u-ana',
        'text': 'Again',
        'createdAt': '2026-10-24T20:00:00Z',
      });
    }
    server.receive('c-ana', 'u-ana', 'Inbox');
    await until(() => messages.byId('c-ana')!.lastMessage?.text == 'Inbox');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(server.callsTo('me/conversations'), hasLength(lists + 1));

    // A new direct conversation still comes into the list with its first message.
    server.conversation('c-bora', [FakeTogether.card('u-bora', 'bora', 'Bora')], texts: [('u-bora', 'Hey')]);
    server.push('message.created', server.threads['c-bora']!.single);
    await until(() => messages.byId('c-bora') != null);
  });

  test('who wrote: a member, someone seen in the party before, or nobody known', () async {
    expect(chat.author('u-cem')?.displayName, 'Cem');
    server.push('party.member_left', {'partyId': parties.party!.id, 'userId': 'u-cem'});
    await until(() => !parties.party!.has('u-cem'));
    expect(chat.author('u-cem')?.displayName, 'Cem', reason: 'seen in this party earlier');
    expect(chat.author('u-dan'), isNull);
  });

  test('leaving the party ends the chat; a new party brings its own', () async {
    shown = true;
    await chat.show();
    expect(chat.thread, isNotEmpty);
    await parties.leave();
    expect(chat.id, isNull);
    expect(chat.thread, isEmpty);
    expect(messages.elsewhere, isEmpty);
    server.inParty([ana]);
    server.partyChat('chat-2', texts: [('u-ana', 'New one')]);
    server.push('party.updated', server.party);
    await until(() => chat.id == 'chat-2');
    // Shown: its history comes at once.
    await until(() => chat.thread.length == 1);
    expect(chat.author('u-cem'), isNull, reason: 'Cem was in the other party');
    expect(messages.elsewhere, {'chat-2'});
  });

  test('kicked meanwhile: the history answers 404 and the chat stays empty', () async {
    server.answers['GET conversations/chat-1/messages?limit=40'] = FakeTogether.problem(404, 'not_found');
    shown = true;
    await chat.show();
    expect(chat.thread, isEmpty);
    expect(chat.loading, isFalse);
  });

  test('the reasons a message can be reported are the server\'s', () {
    expect(messageReportReasons, ['spam', 'harassment', 'hate', 'sexual', 'other']);
  });
}
