import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'account.dart';
import 'e2ee.dart';
import 'e2ee_client.dart';
import 'notifier.dart';
import 'people.dart';
import 'socket.dart';

/// A UUIDv7: the time first, then randomness; the id a message is sent with, so a message sent
/// twice is kept once.
String uuidv7([Random? random]) {
  final source = random ?? Random.secure();
  final bytes = List<int>.generate(16, (_) => source.nextInt(256));
  final ms = DateTime.now().millisecondsSinceEpoch;
  for (var i = 0; i < 6; i++) {
    bytes[i] = (ms >> (8 * (5 - i))) & 0xff;
  }
  bytes[6] = 0x70 | (bytes[6] & 0x0f);
  bytes[8] = 0x80 | (bytes[8] & 0x3f);
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// The reactions a message can get, one of each per person, in the API's order.
const messageReactions = ['like', 'love', 'laugh', 'wow', 'sad', 'fire', 'gg'];

/// How the clients draw them.
const reactionGlyphs = {'like': '👍', 'love': '❤️', 'laugh': '😂', 'wow': '😮', 'sad': '😢', 'fire': '🔥', 'gg': 'GG'};

/// One reaction on a message: how many added it, and who.
class ReactionCount {
  const ReactionCount({required this.name, required this.count, required this.userIds});

  static ReactionCount? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final name = json['reaction'];
    if (name is! String || !messageReactions.contains(name)) return null;
    final userIds = [
      for (final id in (json['userIds'] as List<dynamic>? ?? const []))
        if (id is String) id,
    ];
    return ReactionCount(name: name, count: (json['count'] as num? ?? userIds.length).toInt(), userIds: userIds);
  }

  /// A list as the API sends it; the ones this launcher does not know left out.
  static List<ReactionCount> list(Object? json) => [
    if (json is List<dynamic>)
      for (final item in json) ?ReactionCount.fromJson(item),
  ];

  final String name;
  final int count;
  final List<String> userIds;
}

/// How far another member has got: read (null unless both share read receipts) and delivered
/// (in a direct conversation only).
class Receipt {
  const Receipt({required this.userId, required this.readSeq, required this.deliveredSeq});

  factory Receipt.fromJson(Map<String, dynamic> json) => Receipt(
    userId: json['userId'] as String? ?? '',
    readSeq: (json['readSeq'] as num?)?.toInt(),
    deliveredSeq: (json['deliveredSeq'] as num?)?.toInt(),
  );

  final String userId;
  final int? readSeq;
  final int? deliveredSeq;
}

enum ReceiptKind { sent, delivered, read, seen }

/// Where a message of mine has got: sent, delivered or read in a direct conversation; seen by
/// [count] in a group, [everyone] once all have.
class MessageReceipt {
  const MessageReceipt(this.kind, {this.count = 0, this.everyone = false});

  final ReceiptKind kind;
  final int count;
  final bool everyone;
}

/// Where an end-to-end encrypted message is on this device: still being opened, [opened] (its
/// text and attachment are the payload's), sent before this device was added ([beforeDevice]),
/// or not to be read ([undecryptable]: anything moved, changed or signed by someone else).
enum SealState { opening, opened, beforeDevice, undecryptable }

/// A message's media as the server lists it: a signed link to the file (and a clip's poster);
/// sealed media serves the ciphertext. [gone] when it was removed or is blocked.
class MediaLink {
  const MediaLink({
    required this.id,
    required this.kind,
    this.url,
    this.poster,
    this.sealed = false,
    this.gone = false,
    this.width,
    this.height,
    this.durationMs,
  });

  static MediaLink? fromJson(Object? json) {
    if (json is! Map<String, dynamic> || json['id'] is! String) return null;
    return MediaLink(
      id: json['id'] as String,
      kind: json['kind'] as String? ?? 'image',
      url: json['url'] as String?,
      poster: json['poster'] as String?,
      sealed: json['sealed'] == true,
      gone: json['removed'] == true || json['blocked'] == true,
      width: (json['width'] as num?)?.toInt(),
      height: (json['height'] as num?)?.toInt(),
      durationMs: (json['durationMs'] as num?)?.toInt(),
    );
  }

  /// Its picture's shape, kept between a tall 1:2 and a wide 2.4:1; 16:9 when the server did not say.
  double get aspect {
    final w = width, h = height;
    if (w == null || h == null || w <= 0 || h <= 0) return 16 / 9;
    return (w / h).clamp(0.5, 2.4);
  }

  final String id;
  final String kind;
  final String? url;
  final String? poster;
  final bool sealed;
  final bool gone;
  final int? width;
  final int? height;

  /// A clip's or voice note's length, when the server says.
  final int? durationMs;
}

/// One message in a conversation; a deleted (unsent or removed) one keeps its place with no text
/// and no reactions. [pending] while it is on its way, [failed] when it did not get there.
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.conversationId,
    required this.seq,
    required this.authorId,
    required this.text,
    required this.createdAt,
    this.edited = false,
    this.deleted = false,
    this.pending = false,
    this.failed = false,
    this.replyTo,
    this.editCount = 0,
    this.reactions = const [],
    this.kind = 'text',
    this.caption,
    this.sealed,
    this.seal,
    this.attachment,
    this.media,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final deleted = json['deletedAt'] != null;
    final edited = json['editedAt'] != null;
    final sealed = deleted ? null : SealedMessage.fromJson(json['sealed']);
    final attachments = json['attachments'];
    final media = attachments is List<dynamic> && attachments.isNotEmpty ? MediaLink.fromJson(attachments.first) : null;
    if (sealed != null) {
      // Its text is the stand-in for older clients: nothing shows until it is opened here.
      return ChatMessage(
        id: json['id'] as String,
        conversationId: json['conversationId'] as String,
        seq: (json['seq'] as num).toInt(),
        authorId: json['authorId'] as String?,
        text: null,
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
        edited: edited,
        replyTo: (json['replyTo'] as num?)?.toInt(),
        editCount: (json['editCount'] as num?)?.toInt() ?? (edited ? 1 : 0),
        reactions: ReactionCount.list(json['reactions']),
        kind: 'text',
        sealed: sealed,
        seal: SealState.opening,
        media: media,
      );
    }
    return ChatMessage(
      id: json['id'] as String,
      conversationId: json['conversationId'] as String,
      seq: (json['seq'] as num).toInt(),
      authorId: json['authorId'] as String?,
      text: deleted ? null : json['text'] as String?,
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
      edited: edited,
      deleted: deleted,
      replyTo: (json['replyTo'] as num?)?.toInt(),
      // An older server leaves the count out: an edited one was edited once at least.
      editCount: (json['editCount'] as num?)?.toInt() ?? (edited ? 1 : 0),
      reactions: deleted ? const [] : ReactionCount.list(json['reactions']),
      kind: json['kind'] as String? ?? 'text',
      caption: json['caption'] as String?,
      media: media,
    );
  }

  final String id;
  final String conversationId;

  /// Its place in the conversation; 0 until the server gave it one.
  final int seq;
  final String? authorId;
  final String? text;
  final DateTime createdAt;
  final bool edited;
  final bool deleted;
  final bool pending;
  final bool failed;

  /// The seq of the message it answers, in the same conversation.
  final int? replyTo;

  /// How many times it was edited (20 at most).
  final int editCount;
  final List<ReactionCount> reactions;

  /// text, or a piece of media whose [text] is a stand-in and [caption] the caption alone.
  final String kind;
  final String? caption;

  /// End-to-end encrypted: the sealed form as the server keeps it, and where opening it got.
  final SealedMessage? sealed;
  final SealState? seal;

  /// An opened sealed message's attachment: how to open its file.
  final SealedAttachment? attachment;

  /// The media the server lists for it.
  final MediaLink? media;

  bool get encrypted => sealed != null;

  /// What it says when it was opened: its words and attachment from the payload.
  ChatMessage opened(E2eePayload payload) => _with(
    seal: SealState.opened,
    text: payload.text,
    kind: payload.attachment?.kind ?? 'text',
    caption: payload.attachment == null ? null : payload.text,
    attachment: payload.attachment,
  );

  /// It could not be opened here, and why.
  ChatMessage unopened(SealState why) => _with(seal: why);

  ChatMessage _with({
    required SealState seal,
    String? text,
    String kind = 'text',
    String? caption,
    SealedAttachment? attachment,
  }) => ChatMessage(
    id: id,
    conversationId: conversationId,
    seq: seq,
    authorId: authorId,
    text: text,
    createdAt: createdAt,
    edited: edited,
    deleted: deleted,
    pending: pending,
    failed: failed,
    replyTo: replyTo,
    editCount: editCount,
    reactions: reactions,
    kind: kind,
    caption: caption,
    sealed: sealed,
    seal: seal,
    attachment: attachment,
    media: media,
  );

  /// Whether [userId] added the reaction [name].
  bool reacted(String name, String? userId) =>
      reactions.any((reaction) => reaction.name == name && reaction.userIds.contains(userId));

  /// What can be edited and quoted: the text, or a piece of media's caption (null without one,
  /// never the server's "[photo]" stand-in).
  String? get words => kind == 'text' ? text : caption;

  ChatMessage copyWith({
    String? text,
    int? replyTo,
    List<ReactionCount>? reactions,
    bool? pending,
    bool? failed,
    int? seq,
  }) => ChatMessage(
    id: id,
    conversationId: conversationId,
    seq: seq ?? this.seq,
    authorId: authorId,
    text: text ?? this.text,
    createdAt: createdAt,
    edited: edited,
    deleted: deleted,
    pending: pending ?? this.pending,
    failed: failed ?? this.failed,
    replyTo: replyTo ?? this.replyTo,
    editCount: editCount,
    reactions: reactions ?? this.reactions,
    kind: kind,
    caption: caption,
    sealed: sealed,
    seal: seal,
    attachment: attachment,
    media: media,
  );

  /// Unsent: its place stays, nothing else.
  ChatMessage removed() => ChatMessage(
    id: id,
    conversationId: conversationId,
    seq: seq,
    authorId: authorId,
    text: null,
    createdAt: createdAt,
    edited: edited,
    deleted: true,
    replyTo: replyTo,
    editCount: editCount,
    kind: kind,
  );
}

/// A direct conversation with a friend or a group.
class Conversation {
  const Conversation({
    required this.id,
    required this.group,
    required this.title,
    required this.members,
    required this.lastSeq,
    required this.readSeq,
    required this.lastMessage,
    required this.updatedAt,
    this._unread,
    this.pinned = false,
    this.muted = false,
    this.receipts,
    this.encrypted = false,
    this.partyId,
  });

  factory Conversation.fromJson(Map<String, dynamic> json) {
    final receipts = json['receipts'];
    return Conversation(
      id: json['id'] as String,
      group: json['kind'] == 'group',
      title: json['title'] as String?,
      members: [
        for (final member in (json['members'] as List<dynamic>? ?? const []))
          Person.fromJson(member as Map<String, dynamic>),
      ],
      lastSeq: (json['lastSeq'] as num? ?? 0).toInt(),
      readSeq: (json['readSeq'] as num? ?? 0).toInt(),
      lastMessage: json['lastMessage'] is Map<String, dynamic>
          ? ChatMessage.fromJson(json['lastMessage'] as Map<String, dynamic>)
          : null,
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ?? DateTime.now(),
      unread: (json['unread'] as num?)?.toInt(),
      pinned: json['pinned'] == true,
      muted: json['muted'] == true,
      receipts: receipts is List<dynamic>
          ? [
              for (final receipt in receipts)
                if (receipt is Map<String, dynamic>) Receipt.fromJson(receipt),
            ]
          : null,
      encrypted: json['encrypted'] == true,
      partyId: json['partyId'] as String?,
    );
  }

  final String id;
  final bool group;
  final String? title;
  final List<Person> members;
  final int lastSeq;
  final int readSeq;
  final ChatMessage? lastMessage;
  final DateTime updatedAt;
  final int? _unread;

  /// Pinned to the top of the list; its notifications muted.
  final bool pinned;
  final bool muted;

  /// The other members' read and delivered marks; null from an older server.
  final List<Receipt>? receipts;

  /// A direct conversation with an end-to-end encrypted message in it: no plain text from then on.
  final bool encrypted;

  /// The party whose chat this is (it sits beside the party, never in the list); null for any
  /// other conversation, and from an older server.
  final String? partyId;

  /// The others' messages after the read mark that are still there, as the server counts them;
  /// an older server's from the marks.
  int get unread => _unread ?? max(0, lastSeq - readSeq);

  /// Everyone in it but [me].
  List<Person> others(String? me) => members.where((person) => person.id != me).toList();

  /// Its title, or the people in it.
  String name(String? me) =>
      title ?? (others(me).isEmpty ? '…' : others(me).map((person) => person.displayName).join(', '));

  Person? author(String? id) => members.where((person) => person.id == id).firstOrNull;

  Conversation copyWith({
    int? lastSeq,
    int? readSeq,
    ChatMessage? lastMessage,
    DateTime? updatedAt,
    int? unread,
    List<Receipt>? receipts,
  }) => Conversation(
    id: id,
    group: group,
    title: title,
    members: members,
    lastSeq: lastSeq ?? this.lastSeq,
    readSeq: readSeq ?? this.readSeq,
    lastMessage: lastMessage ?? this.lastMessage,
    updatedAt: updatedAt ?? this.updatedAt,
    unread: unread ?? _unread,
    pinned: pinned,
    muted: muted,
    receipts: receipts ?? this.receipts,
    encrypted: encrypted || (lastMessage?.encrypted ?? false),
    partyId: partyId,
  );

  /// The other person of a direct conversation.
  String? partner(String? me) => group ? null : others(me).firstOrNull?.id;
}

/// Messages: the conversations (pinned first, then the newest) with what is unread, the one open
/// with its thread, sending (kept once however often it is sent), replies, edits, unsending,
/// reactions, read and delivered marks, pins and mutes, and everything live.
class Messages with Notifier {
  Messages({required this.account, required this.socket, this.e2ee}) {
    _events = socket.events.listen(_event);
    e2ee?.addListener(notifyListeners);
  }

  /// How long the author may edit a message, how many times, and how many conversations can be
  /// pinned: the server's limits.
  static const editWindow = Duration(minutes: 15);
  static const maxEdits = 20;
  static const maxPinned = 5;

  final TogetherAccount account;
  final TogetherSocket socket;

  /// End-to-end encryption of direct conversations; null leaves every message plain.
  final EndToEnd? e2ee;
  late final StreamSubscription<TogetherEvent> _events;

  /// Events that wait for a sealed message before them to be opened, so they keep their order.
  Future<void> _queue = Future.value();
  int _queued = 0;

  /// How often a sealed message is sealed again when the server says the devices changed.
  static const sealTries = 3;

  List<Conversation> conversations = const [];

  /// Conversations kept somewhere else: a party's chat, beside the party. They are not in the
  /// list or its unread count, bring no notice, and are never a reason to read the list again.
  final Set<String> elsewhere = {};

  /// Conversations a message came in for that the list still did not have once it was read
  /// again for it (a party's or a community's chat): the list is not read again for them.
  final Set<String> _unlisted = {};

  /// A message did not get there: why (a blocked link, no connection).
  void Function(Object error)? onSendFailed;

  /// Who is typing where, until when: the gateway's typing events, shown for a few seconds.
  final Map<String, Map<String, DateTime>> _typing = {};
  Timer? _typingExpiry;
  DateTime _toldTyping = DateTime.fromMillisecondsSinceEpoch(0);
  static const typingShown = Duration(seconds: 5);

  /// Messages not read yet, over every conversation.
  int unread = 0;
  bool loaded = false;

  /// The conversation shown, its messages oldest first, and whether older ones are left.
  String? openId;
  List<ChatMessage> thread = const [];
  bool more = false;
  bool loadingThread = false;
  bool _older = false;

  String? get _me => account.user?.id;

  Conversation? byId(String? id) => conversations.where((c) => c.id == id).firstOrNull;

  Conversation? get open => byId(openId);

  Future<void> refresh() async {
    final list = await account.call('GET', 'me/conversations');
    final fetched = [
      for (final json in (list['conversations'] as List<dynamic>? ?? const []))
        if (Conversation.fromJson(json as Map<String, dynamic>) case final c
            when c.partyId == null && !elsewhere.contains(c.id))
          c,
    ];
    conversations = ordered(await _openLast(fetched));
    _unlisted.removeAll(conversations.map((c) => c.id));
    loaded = true;
    await _countUnread();
    final shown = open;
    if (shown != null && shown.unread > 0) await _read(shown);
  }

  Future<void> _countUnread() async {
    final count = await account.call('GET', 'me/conversations/unread');
    unread = (count['messages'] as num? ?? 0).toInt();
    notifyListeners();
  }

  /// Shows a conversation: its newest messages, and read up to them.
  Future<void> show(String id) async {
    openId = id;
    thread = const [];
    more = false;
    loadingThread = true;
    notifyListeners();
    try {
      final shown = byId(id);
      if (shown != null) unawaited(checkLock(shown).then((_) {}, onError: (Object _) {}));
      final page = await account.call('GET', 'conversations/$id/messages?limit=50');
      final opened = await openAll(_page(page));
      if (openId != id) return;
      thread = opened;
      more = page['more'] == true;
    } finally {
      if (openId == id) {
        loadingThread = false;
        notifyListeners();
      }
    }
    final conversation = byId(id);
    if (conversation != null) await _read(conversation);
  }

  /// Nothing shown any more: new messages count as unread again.
  void hide() {
    openId = null;
    thread = const [];
    more = false;
    notifyListeners();
  }

  /// The conversation with a friend, made the first time, and shown.
  Future<void> withFriend(String userId) async {
    final json = await account.call('POST', 'conversations', {
      'members': [userId],
    });
    final conversation = (await _openLast([Conversation.fromJson(json)])).single;
    if (byId(conversation.id) == null) {
      conversations = [conversation, ...conversations];
    }
    await show(conversation.id);
  }

  /// A group with friends (one or more), made and shown; without a name its members stand for it.
  Future<Conversation> startGroup(List<String> userIds, {String? title}) async {
    final name = title?.trim() ?? '';
    final json = await account.call('POST', 'conversations', {
      'members': userIds,
      'group': true,
      if (name.isNotEmpty) 'title': String.fromCharCodes(name.runes.take(80)),
    });
    final group = (await _openLast([Conversation.fromJson(json)])).single;
    if (byId(group.id) == null) conversations = [group, ...conversations];
    await show(group.id);
    return group;
  }

  /// Older messages above the ones shown.
  Future<void> older() async {
    final id = openId;
    if (id == null || !more || thread.isEmpty || _older) return;
    _older = true;
    final Map<String, dynamic> page;
    try {
      page = await account.call('GET', 'conversations/$id/messages?limit=50&before=${thread.first.seq}');
    } finally {
      _older = false;
    }
    final opened = await openAll(_page(page));
    if (openId != id) return;
    final known = thread.map((m) => m.id).toSet();
    thread = [...opened.where((m) => !known.contains(m.id)), ...thread];
    more = page['more'] == true;
    notifyListeners();
  }

  /// Sends a text to the open conversation, an answer to the message at [replyTo] when given;
  /// it shows at once and settles when the server has it.
  Future<void> send(String text, {int? replyTo}) async {
    final id = openId;
    final trimmed = text.trim();
    if (id == null || trimmed.isEmpty) return;
    final message = ChatMessage(
      id: uuidv7(),
      conversationId: id,
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

  Future<void> _deliver(ChatMessage message, {SealedAttachment? attachment}) async {
    try {
      final json = await _post(message, attachment: attachment);
      _arrived(await _openOne(ChatMessage.fromJson(json)));
    } on Object catch (error) {
      onSendFailed?.call(error);
      _replace(message.copyWith(seq: 0, pending: false, failed: true));
    }
  }

  /// A message out: sealed in an end-to-end encrypted direct conversation (again, with the
  /// devices fetched again, when the server says they changed), plain otherwise. Plain text
  /// never goes to a conversation this device saw encrypted: E2eeUnavailable instead.
  Future<Map<String, dynamic>> _post(ChatMessage message, {SealedAttachment? attachment}) async {
    final path = 'conversations/${message.conversationId}/messages';
    final conversation = byId(message.conversationId);
    var lock = conversation == null ? null : await checkLock(conversation);
    for (var attempt = 0; ; attempt++) {
      try {
        switch (lock?.state) {
          case EncryptionState.on:
            final sealed = await e2ee!.sealFor(
              conversationId: message.conversationId,
              messageId: message.id,
              other: conversation!.partner(_me)!,
              payload: E2eePayload(text: message.text, attachment: attachment),
            );
            return await account.call('POST', path, {
              'clientId': message.id,
              'sealed': sealed.sealed.toJson(),
              'replyTo': ?message.replyTo,
              if (attachment != null)
                'attachments': [
                  {'mediaId': attachment.mediaId},
                ],
            });
          case EncryptionState.noDevice:
            throw const E2eeUnavailable();
          case EncryptionState.off || null:
            if (attachment != null) throw const E2eeUnavailable();
            return await account.call('POST', path, {
              'clientId': message.id,
              'text': message.text,
              'replyTo': ?message.replyTo,
            });
        }
      } on TogetherProblem catch (problem) {
        final again = problem.code == 'e2ee_devices' || problem.code == 'e2ee_required';
        if (!again || conversation == null || e2ee == null || attempt + 1 >= sealTries) rethrow;
        if (problem.code == 'e2ee_required') e2ee!.markEncrypted(conversation.id);
        lock = await checkLock(conversation, fresh: true);
      }
    }
  }

  /// A direct conversation's lock, worked out again ([fresh]: with the devices fetched again);
  /// null for a group or on a server without encryption.
  Future<ConversationLock?> checkLock(Conversation conversation, {bool fresh = false}) async {
    final other = conversation.partner(_me);
    final e2ee = this.e2ee;
    if (e2ee == null || other == null) return null;
    return e2ee.check(conversationId: conversation.id, other: other, encrypted: conversation.encrypted, fresh: fresh);
  }

  /// The lock of [conversationId] as last worked out.
  ConversationLock? lockOf(String? conversationId) => e2ee?.lockOf(conversationId);

  /// A screenshot or clip from the gallery into [conversationId] (open or not), as the Mac's Send
  /// to a chat: sealed where the conversation is end-to-end encrypted ([sealed] uploads it so),
  /// else the [plain] upload's media attached. Throws what refused it.
  Future<void> sendMedia(
    String conversationId, {
    required String kind,
    required Future<String> Function() plain,
    required Future<SealedAttachment> Function() sealed,
  }) async {
    final conversation = byId(conversationId);
    final message = ChatMessage(
      id: uuidv7(),
      conversationId: conversationId,
      seq: 0,
      authorId: _me,
      text: null,
      createdAt: DateTime.now(),
      pending: true,
      kind: kind,
    );
    if (openId == conversationId) {
      thread = [...thread, message];
      notifyListeners();
    }
    try {
      final lock = conversation == null ? null : await checkLock(conversation);
      final Map<String, dynamic> json;
      switch (lock?.state) {
        case EncryptionState.on:
          json = await _post(message, attachment: await sealed());
        case EncryptionState.noDevice:
          throw const E2eeUnavailable();
        case EncryptionState.off || null:
          final mediaId = await plain();
          json = await account.call('POST', 'conversations/$conversationId/messages', {
            'clientId': message.id,
            'attachments': [
              {'mediaId': mediaId},
            ],
          });
      }
      _arrived(await _openOne(ChatMessage.fromJson(json)));
    } on Object {
      // Not kept as failed: sending it again is sharing it again from the gallery.
      if (thread.any((m) => m.id == message.id)) {
        thread = [
          for (final m in thread)
            if (m.id != message.id) m,
        ];
        notifyListeners();
      }
      rethrow;
    }
  }

  /// A sealed attachment's file (or its poster), downloaded and opened in memory.
  Future<Uint8List> attachmentBytes(ChatMessage message, {bool poster = false}) async {
    final attachment = message.attachment;
    final media = message.media;
    final link = poster ? media?.poster : media?.url;
    if (attachment == null || media == null || link == null || e2ee == null) throw const E2eeError('bad_message');
    return e2ee!.download(link, attachment, poster: poster);
  }

  /// Reports someone's message for [reason]; a sealed one sends its content key, so the
  /// moderators can read it (and only it).
  Future<void> report(ChatMessage message, String reason) async {
    final sealed = message.sealed;
    final key = sealed == null ? null : e2ee?.contentKeyOf(message.id, sealed);
    if (sealed != null && key == null) throw const E2eeError('bad_message');
    await account.call('POST', 'reports', {
      'targetKind': 'message',
      'targetId': message.id,
      'reason': reason,
      if (key != null) 'contentKey': toBase64(key),
    });
  }

  /// Opens the sealed messages among [messages] on this device; the plain ones stay as they are.
  Future<List<ChatMessage>> openAll(List<ChatMessage> messages) async => [
    for (final message in messages) await _openOne(message),
  ];

  Future<ChatMessage> _openOne(ChatMessage message) async {
    final sealed = message.sealed;
    final e2ee = this.e2ee;
    if (sealed == null) return message;
    final author = message.authorId;
    if (e2ee == null || author == null) return message.unopened(SealState.undecryptable);
    try {
      final opened = await e2ee.openMessage(
        sealed: sealed,
        conversationId: message.conversationId,
        messageId: message.id,
        authorId: author,
      );
      // The payload's media must be the one the server lists for the message.
      final attachment = opened.payload.attachment;
      if (attachment != null && message.media?.id != attachment.mediaId) {
        return message.unopened(SealState.undecryptable);
      }
      return message.opened(opened.payload);
    } on E2eeError catch (error) {
      return message.unopened(error.code == 'no_key' ? SealState.beforeDevice : SealState.undecryptable);
    } on Object {
      // No devices (offline): not read here now.
      return message.unopened(SealState.undecryptable);
    }
  }

  /// The list's last messages opened for their previews.
  Future<List<Conversation>> _openLast(List<Conversation> list) async {
    final e2ee = this.e2ee;
    if (e2ee == null || !list.any((c) => c.lastMessage?.encrypted ?? false)) return list;
    try {
      await e2ee.fetch({
        for (final c in list)
          if (c.lastMessage case final ChatMessage last when last.encrypted && last.authorId != null) last.authorId!,
      });
    } on Object {
      // Each one says it could not be opened.
    }
    return [
      for (final c in list)
        if (c.lastMessage case final ChatMessage last when last.encrypted)
          c.copyWith(lastMessage: await _openOne(last))
        else
          c,
    ];
  }

  /// A message of mine with new words; thrown when the server says no (403 after the edit
  /// window, 409 edit_limit after the last edit).
  Future<void> edit(ChatMessage message, String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || message.seq <= 0) return;
    final path = 'conversations/${message.conversationId}/messages/${message.seq}';
    if (!message.encrypted) {
      _changed(ChatMessage.fromJson(await account.call('PATCH', path, {'text': trimmed})));
      return;
    }
    // A sealed one: a new seal of the same message, its attachment kept.
    final conversation = byId(message.conversationId);
    final other = conversation?.partner(_me);
    if (conversation == null || other == null || e2ee == null) throw const E2eeUnavailable();
    var fresh = false;
    for (var attempt = 0; ; attempt++) {
      final lock = await checkLock(conversation, fresh: fresh);
      if (lock?.state != EncryptionState.on) throw const E2eeUnavailable();
      final sealed = await e2ee!.sealFor(
        conversationId: message.conversationId,
        messageId: message.id,
        other: other,
        payload: E2eePayload(text: trimmed, attachment: message.attachment),
      );
      try {
        final json = await account.call('PATCH', path, {'sealed': sealed.sealed.toJson()});
        _changed(await _openOne(ChatMessage.fromJson(json)));
        return;
      } on TogetherProblem catch (problem) {
        if (problem.code != 'e2ee_devices' || attempt + 1 >= sealTries) rethrow;
        fresh = true;
      }
    }
  }

  /// A message of mine unsent for everyone: its place stays.
  Future<void> unsend(ChatMessage message) async {
    if (message.seq <= 0) return;
    await account.call('DELETE', 'conversations/${message.conversationId}/messages/${message.seq}');
    _changed(message.removed());
  }

  /// Adds the reaction [name] to a message, or takes it back when this user had added it.
  Future<void> react(ChatMessage message, String name) async {
    if (message.seq <= 0 || message.deleted || !messageReactions.contains(name)) return;
    final json = await account.call(
      message.reacted(name, _me) ? 'DELETE' : 'PUT',
      'conversations/${message.conversationId}/messages/${message.seq}/reactions/$name',
    );
    _reactions(message.conversationId, message.seq, ReactionCount.list(json['reactions']));
  }

  void _reactions(String conversationId, int seq, List<ReactionCount> reactions) {
    ChatMessage update(ChatMessage message) =>
        message.conversationId == conversationId && message.seq == seq && !message.deleted
        ? message.copyWith(reactions: reactions)
        : message;
    if (conversationId == openId) thread = [for (final message in thread) update(message)];
    conversations = [
      for (final c in conversations)
        if (c.lastMessage case final ChatMessage last when c.id == conversationId && last.seq == seq)
          c.copyWith(lastMessage: update(last))
        else
          c,
    ];
    notifyListeners();
  }

  /// Pinned to the top of the list or not; thrown with code `full` when five are pinned.
  Future<void> setPinned(Conversation conversation, bool pinned) async {
    final json = await account.call('PUT', 'conversations/${conversation.id}/pin', {'pinned': pinned});
    _settled(conversation, json);
  }

  /// Its notifications muted or not.
  Future<void> setMuted(Conversation conversation, bool muted) async {
    final json = await account.call('PUT', 'conversations/${conversation.id}/mute', {'muted': muted});
    _settled(conversation, json);
  }

  void _settled(Conversation before, Map<String, dynamic> json) {
    final after = json['id'] == before.id ? Conversation.fromJson(json) : before;
    conversations = ordered([
      for (final c in conversations)
        if (c.id == before.id) after else c,
    ]);
    notifyListeners();
  }

  void _replace(ChatMessage message) {
    thread = [
      for (final m in thread)
        if (m.id == message.id) message else m,
    ];
    notifyListeners();
  }

  /// A message the server has (sent here, or live from the gateway): into the thread when it is
  /// open, and to the top of the list.
  void _arrived(ChatMessage message) {
    final mine = message.authorId == _me;
    if (message.conversationId == openId) {
      final at = thread.indexWhere((m) => m.id == message.id);
      if (at >= 0) {
        thread = [...thread]..[at] = message;
      } else {
        thread = [...thread, message]..sort(_order);
      }
    }
    final conversation = byId(message.conversationId);
    if (conversation == null) {
      // A conversation new to the list is read with it, once: one the list does not have even
      // then is left alone, however many messages come for it.
      final id = message.conversationId;
      if (!_unlisted.contains(id)) {
        _unlisted.add(id);
        unawaited(
          refresh().then((_) {
            if (byId(id) != null) _unlisted.remove(id);
          }, onError: (Object _) => _unlisted.remove(id)),
        );
      }
      notifyListeners();
      return;
    }
    if (message.seq <= conversation.readSeq && !mine) {
      notifyListeners();
      return;
    }
    // Mine is read already; one in the open conversation is read just after.
    final newer = message.seq > conversation.lastSeq;
    final next = conversation.copyWith(
      lastSeq: max(conversation.lastSeq, message.seq),
      readSeq: mine ? max(conversation.readSeq, message.seq) : null,
      lastMessage: message.seq >= conversation.lastSeq ? message : null,
      updatedAt: message.createdAt,
      unread: mine ? 0 : conversation.unread + (newer ? 1 : 0),
    );
    if (!mine && newer) unread++;
    // Sending reads the conversation up to it (on the server too).
    if (mine) unread = max(0, unread - conversation.unread);
    // To the top of its part of the list: the pinned ones stay first.
    conversations = ordered([next, ...conversations.where((c) => c.id != message.conversationId)], byTime: false);
    notifyListeners();
    if (message.conversationId == openId && !mine) {
      unawaited(_read(next).catchError((Object _) {}));
    }
  }

  /// An edit or a deletion: changed where it shows, nothing moves.
  void _changed(ChatMessage message) {
    if (message.conversationId == openId) _replace(message);
    conversations = [
      for (final c in conversations)
        if (c.lastMessage?.id == message.id) c.copyWith(lastMessage: message) else c,
    ];
    notifyListeners();
  }

  /// Someone else's message removed before it was read: one fewer unread, and the count again.
  void _removed(ChatMessage message) {
    final conversation = byId(message.conversationId);
    final known = message.conversationId == openId
        ? thread.where((m) => m.id == message.id).firstOrNull
        : conversation?.lastMessage?.id == message.id
        ? conversation?.lastMessage
        : null;
    final wasThere = known == null || !known.deleted;
    _changed(message);
    if (conversation == null || message.authorId == _me || message.seq <= conversation.readSeq || !wasThere) return;
    conversations = [
      for (final c in conversations)
        if (c.id == conversation.id) c.copyWith(unread: max(0, c.unread - 1)) else c,
    ];
    notifyListeners();
    unawaited(_countUnread().catchError((Object _) {}));
  }

  /// Another member's read or delivered mark: their receipt goes up, never down. Read is
  /// delivered too.
  void _mark(String conversationId, String userId, int upTo, {required bool read}) {
    conversations = [
      for (final c in conversations)
        if (c.id == conversationId && c.receipts != null)
          c.copyWith(
            receipts: [
              for (final r in c.receipts!)
                if (r.userId == userId)
                  Receipt(
                    userId: r.userId,
                    readSeq: read ? max(r.readSeq ?? 0, upTo) : r.readSeq,
                    deliveredSeq: r.deliveredSeq == null ? null : max(r.deliveredSeq!, upTo),
                  )
                else
                  r,
            ],
          )
        else
          c,
    ];
    notifyListeners();
  }

  /// A direct message from someone else reached this device while its conversation is not open:
  /// the sender sees it delivered. (Opening it reads it, which says so by itself.)
  void _delivered(ChatMessage message) {
    final conversation = byId(message.conversationId);
    if (conversation == null || conversation.group || message.authorId == _me) return;
    if (message.conversationId == openId || message.seq <= 0) return;
    unawaited(
      account
          .call('POST', 'conversations/${message.conversationId}/delivered', {'upToSeq': message.seq})
          .then((_) {}, onError: (Object _) {}),
    );
  }

  /// Where a message of mine has got, for the line under it; null for someone else's, a removed
  /// one, one on its way, or a server without receipts.
  static MessageReceipt? receiptOf(Conversation conversation, ChatMessage message, String? me) {
    final receipts = conversation.receipts;
    if (message.authorId != me || message.deleted || message.seq <= 0 || receipts == null) return null;
    if (conversation.group) {
      final count = receipts.where((r) => (r.readSeq ?? 0) >= message.seq).length;
      if (count == 0) return const MessageReceipt(ReceiptKind.sent);
      return MessageReceipt(ReceiptKind.seen, count: count, everyone: count == receipts.length);
    }
    final other = receipts.firstOrNull;
    if (other == null) return null;
    if ((other.readSeq ?? 0) >= message.seq) return const MessageReceipt(ReceiptKind.read);
    if ((other.deliveredSeq ?? 0) >= message.seq) return const MessageReceipt(ReceiptKind.delivered);
    return const MessageReceipt(ReceiptKind.sent);
  }

  /// One's own text (or caption), within the edit window and under the edit limit.
  static bool canEdit(ChatMessage message, String? me, DateTime now) {
    if (message.authorId != me || message.deleted || message.seq <= 0) return false;
    if (message.editCount >= maxEdits) return false;
    if (now.difference(message.createdAt) >= editWindow) return false;
    return message.kind == 'text' || message.caption != null;
  }

  /// Pinned ones first, then (with [byTime]) the newest; otherwise as they were.
  static List<Conversation> ordered(List<Conversation> list, {bool byTime = true}) {
    final indexed = [for (var i = 0; i < list.length; i++) (i, list[i])];
    indexed.sort((a, b) {
      if (a.$2.pinned != b.$2.pinned) return a.$2.pinned ? -1 : 1;
      if (byTime) {
        final time = b.$2.updatedAt.compareTo(a.$2.updatedAt);
        if (time != 0) return time;
      }
      return a.$1.compareTo(b.$1);
    });
    return [for (final (_, conversation) in indexed) conversation];
  }

  /// The message at [seq] in the open thread, if it is loaded.
  ChatMessage? inThread(int? seq) => seq == null ? null : thread.where((m) => m.seq == seq).firstOrNull;

  /// Read up to the newest message, here and on the server.
  Future<void> _read(Conversation conversation) async {
    final before = byId(conversation.id) ?? conversation;
    final upTo = before.lastSeq;
    if (before.readSeq >= upTo) return;
    unread = max(0, unread - before.unread);
    conversations = [
      for (final c in conversations)
        if (c.id == before.id) c.copyWith(readSeq: upTo, unread: 0) else c,
    ];
    notifyListeners();
    await account.call('POST', 'conversations/${before.id}/read', {'upToSeq': upTo});
  }

  /// The people typing in [conversationId] now (by user id), not counting this user.
  List<String> typingIn(String? conversationId) {
    final now = DateTime.now();
    final typing = _typing[conversationId] ?? const {};
    return [
      for (final entry in typing.entries)
        if (entry.value.isAfter(now) && entry.key != _me) entry.key,
    ];
  }

  /// Tells the others in the open conversation this user is typing, at most every 2 s.
  void typing() {
    final id = openId;
    if (id == null) return;
    final now = DateTime.now();
    if (now.difference(_toldTyping) < const Duration(seconds: 2)) return;
    _toldTyping = now;
    socket.send({'op': 'typing', 'conversation': id});
  }

  void _someoneTyping(String conversationId, String userId) {
    (_typing[conversationId] ??= {})[userId] = DateTime.now().add(typingShown);
    _typingExpiry?.cancel();
    _typingExpiry = Timer(typingShown + const Duration(milliseconds: 50), () {
      final now = DateTime.now();
      for (final people in _typing.values) {
        people.removeWhere((_, until) => !until.isAfter(now));
      }
      _typing.removeWhere((_, people) => people.isEmpty);
      notifyListeners();
    });
    notifyListeners();
  }

  void clear() {
    _typing.clear();
    _unlisted.clear();
    conversations = const [];
    unread = 0;
    loaded = false;
    openId = null;
    thread = const [];
    more = false;
    notifyListeners();
  }

  /// A gateway event: handled at once, unless it carries a sealed message (opened first) or a
  /// sealed one is still being opened before it, so they keep their order.
  void _event(TogetherEvent event) {
    final sealed = event.type.startsWith('message.') && event.json['sealed'] != null && e2ee != null;
    if (_queued == 0 && !sealed) return _handle(event, null);
    _queued++;
    _queue = _queue
        .then((_) async {
          final opened = sealed ? await _openOne(ChatMessage.fromJson(event.json)) : null;
          _handle(event, opened);
        })
        .catchError((Object _) {})
        .whenComplete(() => _queued--);
  }

  void _handle(TogetherEvent event, ChatMessage? opened) {
    final data = event.json;
    // A party's chat keeps its own messages (party_chat.dart).
    if (elsewhere.contains(data['conversationId'])) return;
    switch (event.type) {
      case 'live.ready':
        unawaited(refresh().then((_) => _catchUp()).catchError((Object _) {}));
        final shown = open;
        if (shown != null) unawaited(checkLock(shown, fresh: true).then((_) {}, onError: (Object _) {}));
      case 'e2ee.devices':
        // Someone's devices changed: the list again, and the open conversation's lock with it
        // (a notice when they are this conversation's people).
        final user = data['userId'];
        if (user is String && e2ee != null) {
          unawaited(
            e2ee!
                .devicesChanged(user)
                .then((_) async {
                  final shown = open;
                  if (shown != null && (user == _me || shown.partner(_me) == user)) await checkLock(shown);
                })
                .catchError((Object _) {}),
          );
        }
      case 'message.created':
        final message = opened ?? ChatMessage.fromJson(data);
        // A message ends its author's typing.
        _typing[message.conversationId]?.remove(message.authorId);
        _delivered(message);
        _arrived(message);
      case 'typing':
        final conversation = data['conversationId'];
        final user = data['userId'];
        if (conversation is String && user is String && user != _me) _someoneTyping(conversation, user);
      case 'message.updated':
        _changed(opened ?? ChatMessage.fromJson(data));
      case 'message.deleted':
        _removed(opened ?? ChatMessage.fromJson(data));
      case 'message.reactions':
        final id = data['conversationId'];
        final seq = data['seq'];
        if (id is String && seq is num) _reactions(id, seq.toInt(), ReactionCount.list(data['reactions']));
      case 'conversation.read' when data['userId'] == _me:
        // Read on another device: the server says what is left unread there.
        final id = data['conversationId'];
        final upTo = (data['upToSeq'] as num? ?? 0).toInt();
        final left = (data['unread'] as num?)?.toInt();
        conversations = [
          for (final c in conversations)
            if (c.id == id)
              c.copyWith(readSeq: max(c.readSeq, upTo), unread: left ?? max(0, c.lastSeq - max(c.readSeq, upTo)))
            else
              c,
        ];
        notifyListeners();
        unawaited(_countUnread().catchError((Object _) {}));
      case 'conversation.read' || 'conversation.delivered':
        // Another member's mark: their receipt.
        final id = data['conversationId'];
        final user = data['userId'];
        final upTo = data['upToSeq'];
        if (id is String && user is String && upTo is num) {
          _mark(id, user, upTo.toInt(), read: event.type == 'conversation.read');
        }
      case 'messages.settings':
        // Read receipts turned on or off on another device: what the others' receipts show
        // changes with it.
        unawaited(refresh().catchError((Object _) {}));
      case 'conversation.updated':
        if (data['removed'] == true && data['conversationId'] == openId) {
          hide();
        }
        unawaited(refresh().catchError((Object _) {}));
    }
  }

  /// After a reconnect, the open thread gets what came while the socket was away.
  Future<void> _catchUp() async {
    final id = openId;
    final last = thread.where((m) => m.seq > 0).lastOrNull;
    if (id == null || last == null) return;
    final page = await account.call('GET', 'conversations/$id/messages?limit=100&after=${last.seq}');
    (await openAll(_page(page))).forEach(_arrived);
  }

  static List<ChatMessage> _page(Map<String, dynamic> page) => [
    for (final json in (page['messages'] as List<dynamic>? ?? const []))
      ChatMessage.fromJson(json as Map<String, dynamic>),
  ];

  /// By place in the conversation; the ones still on their way last.
  static int _order(ChatMessage a, ChatMessage b) {
    if (a.seq == 0 || b.seq == 0) return a.seq == 0 ? (b.seq == 0 ? 0 : 1) : -1;
    return a.seq.compareTo(b.seq);
  }

  void dispose() {
    e2ee?.removeListener(notifyListeners);
    _typingExpiry?.cancel();
    unawaited(_events.cancel());
  }
}
