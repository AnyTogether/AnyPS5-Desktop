import 'dart:async';
import 'dart:math';

import 'account.dart';
import 'messages.dart';
import 'notifier.dart';
import 'parties.dart';
import 'people.dart';
import 'socket.dart';

/// Why a message is reported, as the server knows the reasons; the ones a chat message can
/// have.
const messageReportReasons = ['spam', 'harassment', 'hate', 'sexual', 'other'];

/// The party's text chat, beside its voice: everyone in the party reads and writes it while they
/// are in it, and someone who joins reads what was said so far. Text only, with replies,
/// reactions, edits, unsending, typing and reports, as the messages have them.
///
/// It is an ordinary group conversation that follows the party (the party view's
/// `conversationId`), so the messages' routes and events work for it; it stays out of the
/// conversation list and its unread count ([Messages.elsewhere]).
class PartyChat with Notifier {
  PartyChat({required this.account, required this.socket, required this.parties, this.messages}) {
    _events = socket.events.listen(_event);
    parties.addListener(_partyChanged);
    _partyChanged();
  }

  /// How many messages a page holds: the newest ones first, older ones on the way up.
  static const pageSize = 40;

  final TogetherAccount account;
  final TogetherSocket socket;
  final Parties parties;

  /// The inbox, told which conversation is kept here.
  final Messages? messages;
  late final StreamSubscription<TogetherEvent> _events;

  /// Whether the party screen shows the chat now: what comes in is read at once.
  bool Function() shown = () => false;

  /// A message did not get there: why (a blocked link, too many, no connection).
  void Function(Object error)? onSendFailed;

  /// The chat's conversation; null without a party, and from an older server.
  String? id;

  /// Its messages, oldest first; whether older ones are left; the first page on its way, or in.
  List<ChatMessage> thread = const [];
  bool more = false;
  bool loading = false;
  bool loaded = false;
  bool _older = false;

  /// Read up to here, on the server too.
  int readSeq = 0;

  /// Others' messages that came while the chat was not on screen.
  int unread = 0;

  /// Everyone seen in this party while the launcher runs, by id: a message from someone who left
  /// still says who wrote it.
  final Map<String, Person> _seen = {};
  String? _partyId;

  final Map<String, DateTime> _typing = {};
  Timer? _typingExpiry;
  DateTime _toldTyping = DateTime.fromMillisecondsSinceEpoch(0);

  String? get _me => account.user?.id;

  /// Someone who wrote in the chat: a member, or someone seen in the party earlier; null for
  /// someone this launcher never saw in it (a former member).
  Person? author(String? userId) {
    if (userId == null) return null;
    return parties.party?.members.where((person) => person.id == userId).firstOrNull ?? _seen[userId];
  }

  void _partyChanged() {
    final party = parties.party;
    if (party == null) {
      _partyId = null;
      _seen.clear();
    } else {
      if (party.id != _partyId) {
        _partyId = party.id;
        _seen.clear();
      }
      for (final member in party.members) {
        _seen[member.id] = member;
      }
    }
    final chat = party?.conversationId;
    if (chat == id) return;
    if (id != null) messages?.elsewhere.remove(id);
    id = chat;
    thread = const [];
    more = false;
    loading = false;
    loaded = false;
    readSeq = 0;
    unread = 0;
    _typing.clear();
    if (chat != null) {
      messages?.elsewhere.add(chat);
      if (shown()) unawaited(show().catchError((Object _) {}));
    }
    notifyListeners();
  }

  /// The party screen opened: the newest messages the first time, and read up to the newest.
  Future<void> show() async {
    final chat = id;
    if (chat == null) return;
    if (unread > 0) {
      unread = 0;
      notifyListeners();
    }
    if (!loaded && !loading) {
      loading = true;
      notifyListeners();
      try {
        final page = await account.call('GET', 'conversations/$chat/messages?limit=$pageSize');
        if (id != chat) return;
        thread = _merge(_page(page), thread);
        more = page['more'] == true;
        loaded = true;
      } on TogetherProblem catch (problem) {
        // Out of the party already (left, kicked): nothing to read.
        if (problem.status != 404) rethrow;
      } finally {
        if (id == chat) {
          loading = false;
          notifyListeners();
        }
      }
    }
    await _readAll();
  }

  /// Older messages above the ones shown.
  Future<void> older() async {
    final chat = id;
    final first = thread.where((m) => m.seq > 0).firstOrNull;
    if (chat == null || !more || first == null || _older) return;
    _older = true;
    final Map<String, dynamic> page;
    try {
      page = await account.call('GET', 'conversations/$chat/messages?limit=$pageSize&before=${first.seq}');
    } finally {
      _older = false;
    }
    if (id != chat) return;
    thread = _merge(_page(page), thread);
    more = page['more'] == true;
    notifyListeners();
  }

  /// Sends a text, an answer to the message at [replyTo] when given; it shows at once and
  /// settles when the server has it.
  Future<void> send(String text, {int? replyTo}) async {
    final chat = id;
    final trimmed = text.trim();
    if (chat == null || trimmed.isEmpty) return;
    final message = ChatMessage(
      id: uuidv7(),
      conversationId: chat,
      seq: 0,
      authorId: _me,
      text: trimmed,
      createdAt: DateTime.now(),
      pending: true,
      replyTo: replyTo,
    );
    thread = [...thread, message];
    notifyListeners();
    await _deliver(message);
  }

  /// Sends again a message that did not get there, with the same id.
  Future<void> retry(ChatMessage message) async {
    _replace(message.copyWith(seq: 0, pending: true, failed: false));
    await _deliver(message);
  }

  Future<void> _deliver(ChatMessage message) async {
    try {
      final json = await account.call('POST', 'conversations/${message.conversationId}/messages', {
        'clientId': message.id,
        'text': message.text,
        'replyTo': ?message.replyTo,
      });
      _arrived(ChatMessage.fromJson(json));
    } on Object catch (error) {
      onSendFailed?.call(error);
      _replace(message.copyWith(seq: 0, pending: false, failed: true));
    }
  }

  /// A message of mine with new words; thrown when the server says no.
  Future<void> edit(ChatMessage message, String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || message.seq <= 0) return;
    final json = await account.call('PATCH', 'conversations/${message.conversationId}/messages/${message.seq}', {
      'text': trimmed,
    });
    _replace(ChatMessage.fromJson(json));
  }

  /// A message of mine unsent for everyone: its place stays.
  Future<void> unsend(ChatMessage message) async {
    if (message.seq <= 0) return;
    await account.call('DELETE', 'conversations/${message.conversationId}/messages/${message.seq}');
    _replace(message.removed());
  }

  /// Adds the reaction [name], or takes it back when this user had added it.
  Future<void> react(ChatMessage message, String name) async {
    if (message.seq <= 0 || message.deleted || !messageReactions.contains(name)) return;
    final json = await account.call(
      message.reacted(name, _me) ? 'DELETE' : 'PUT',
      'conversations/${message.conversationId}/messages/${message.seq}/reactions/$name',
    );
    _reactions(message.seq, ReactionCount.list(json['reactions']));
  }

  /// Someone else's message to the moderators, for [reason] (one of [messageReportReasons]).
  Future<void> report(ChatMessage message, String reason) async {
    await account.call('POST', 'reports', {'targetKind': 'message', 'targetId': message.id, 'reason': reason});
  }

  /// The message at [seq], if it is loaded.
  ChatMessage? inThread(int? seq) => seq == null ? null : thread.where((m) => m.seq == seq).firstOrNull;

  /// The people typing now (by user id), not counting this user.
  List<String> get typingNow {
    final now = DateTime.now();
    return [
      for (final entry in _typing.entries)
        if (entry.value.isAfter(now) && entry.key != _me) entry.key,
    ];
  }

  /// Tells the others this user is typing, at most every 2 s.
  void typing() {
    final chat = id;
    if (chat == null) return;
    final now = DateTime.now();
    if (now.difference(_toldTyping) < const Duration(seconds: 2)) return;
    _toldTyping = now;
    socket.send({'op': 'typing', 'conversation': chat});
  }

  void _someoneTyping(String userId) {
    _typing[userId] = DateTime.now().add(Messages.typingShown);
    _typingExpiry?.cancel();
    _typingExpiry = Timer(Messages.typingShown + const Duration(milliseconds: 50), () {
      final now = DateTime.now();
      _typing.removeWhere((_, until) => !until.isAfter(now));
      notifyListeners();
    });
    notifyListeners();
  }

  /// Read up to the newest message, here and on the server.
  Future<void> _readAll() async {
    final chat = id;
    final newest = thread.where((m) => m.seq > 0).lastOrNull?.seq ?? 0;
    if (chat == null || newest <= readSeq) return;
    readSeq = newest;
    await account.call('POST', 'conversations/$chat/read', {'upToSeq': newest});
  }

  void _replace(ChatMessage message) {
    thread = [
      for (final m in thread)
        if (m.id == message.id) message else m,
    ];
    notifyListeners();
  }

  void _reactions(int seq, List<ReactionCount> reactions) {
    thread = [
      for (final m in thread)
        if (m.seq == seq && !m.deleted) m.copyWith(reactions: reactions) else m,
    ];
    notifyListeners();
  }

  /// A message the server has (sent here, or live): into the thread, kept once.
  void _arrived(ChatMessage message) {
    if (message.conversationId != id) return;
    // Before the first page is asked for, the page brings it.
    if (!loaded && !loading) return;
    thread = _merge([message], thread);
    if (message.authorId == _me) readSeq = max(readSeq, message.seq);
    notifyListeners();
  }

  void _event(TogetherEvent event) {
    final data = event.json;
    if (event.type == 'live.ready') {
      unawaited(_catchUp().catchError((Object _) {}));
      return;
    }
    final chat = id;
    if (chat == null || data['conversationId'] != chat) return;
    switch (event.type) {
      case 'message.created':
        final message = ChatMessage.fromJson(data);
        // A message ends its author's typing.
        _typing.remove(message.authorId);
        final isNew = !thread.any((m) => m.id == message.id);
        _arrived(message);
        if (isNew) _count(message);
        if (message.authorId != _me && shown() && loaded) unawaited(_readAll().catchError((Object _) {}));
      case 'message.updated':
        final message = ChatMessage.fromJson(data);
        if (thread.any((m) => m.id == message.id)) _replace(message);
      case 'message.deleted':
        final message = ChatMessage.fromJson(data);
        final kept = thread.where((m) => m.id == message.id).firstOrNull;
        if (kept != null) _replace(message.removed());
        // Unsent before it was read.
        if ((kept == null ? !loaded : !kept.deleted) &&
            message.authorId != _me &&
            message.seq > readSeq &&
            unread > 0) {
          unread--;
          notifyListeners();
        }
      case 'message.reactions':
        final seq = data['seq'];
        if (seq is num) _reactions(seq.toInt(), ReactionCount.list(data['reactions']));
      case 'typing':
        final user = data['userId'];
        if (user is String && user != _me) _someoneTyping(user);
    }
  }

  /// Someone else's message that came while the chat was not on screen.
  void _count(ChatMessage message) {
    if (message.authorId == _me || message.deleted || shown() || message.seq <= readSeq) return;
    unread++;
    notifyListeners();
  }

  /// How many pages a reconnect reads at most, as on the Mac.
  static const catchUpPages = 10;

  /// After a reconnect, what came while the socket was away, a page at a time.
  Future<void> _catchUp() async {
    final chat = id;
    final last = thread.where((m) => m.seq > 0).lastOrNull;
    if (chat == null || !loaded) return;
    if (last == null) {
      loaded = false;
      if (shown()) await show();
      return;
    }
    var after = last.seq;
    for (var turn = 0; turn < catchUpPages; turn++) {
      final page = await account.call('GET', 'conversations/$chat/messages?limit=$pageSize&after=$after');
      if (id != chat) return;
      final fresh = _page(page);
      final known = {for (final message in thread) message.id};
      thread = _merge(fresh, thread);
      for (final message in fresh) {
        if (!known.contains(message.id)) _count(message);
      }
      notifyListeners();
      final newest = fresh.where((message) => message.seq > 0).lastOrNull?.seq;
      if (page['more'] != true || newest == null || newest <= after) break;
      after = newest;
    }
    if (shown()) await _readAll();
  }

  /// [incoming] over [known], kept once by id, by place; the ones still on their way last.
  static List<ChatMessage> _merge(List<ChatMessage> incoming, List<ChatMessage> known) {
    final byId = {for (final message in known) message.id: message};
    for (final message in incoming) {
      byId[message.id] = message;
    }
    return byId.values.toList()..sort(_order);
  }

  static List<ChatMessage> _page(Map<String, dynamic> page) => [
    for (final json in (page['messages'] as List<dynamic>? ?? const []))
      ChatMessage.fromJson(json as Map<String, dynamic>),
  ];

  static int _order(ChatMessage a, ChatMessage b) {
    if (a.seq == 0 || b.seq == 0) return a.seq == 0 ? (b.seq == 0 ? 0 : 1) : -1;
    return a.seq.compareTo(b.seq);
  }

  void clear() {
    if (id != null) messages?.elsewhere.remove(id);
    id = null;
    thread = const [];
    more = false;
    loading = false;
    loaded = false;
    readSeq = 0;
    unread = 0;
    _typing.clear();
    _seen.clear();
    _partyId = null;
    notifyListeners();
  }

  void dispose() {
    _typingExpiry?.cancel();
    parties.removeListener(_partyChanged);
    unawaited(_events.cancel());
  }
}
