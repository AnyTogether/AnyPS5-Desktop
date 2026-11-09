import 'dart:async';

import 'account.dart';
import 'levels.dart';
import 'notifier.dart';
import 'people.dart';
import 'profiles.dart';
import 'socket.dart';

/// AnyTogether's social side beyond friends and messages, as the macOS launcher has it: the
/// activity feed with its four reactions, the leaderboards, and the notification center with
/// its unread count. The gateway's `feed.item`, `notification` and `notification.read` events
/// keep what was read up to date.

/// The four reactions an activity item can get, one per person.
enum Reaction {
  fire('🔥'),
  clap('👏'),
  wow('😮'),
  heart('❤️');

  const Reaction(this.emoji);

  /// The mark the launcher draws it as, the server's own.
  final String emoji;

  static Reaction? named(Object? name) => values.where((reaction) => reaction.name == name).firstOrNull;
}

/// An item's reactions: how many of each, and the user's own.
class Reactions {
  const Reactions({this.counts = const {}, this.mine});

  factory Reactions.fromJson(Object? json) {
    if (json is! Map) return const Reactions();
    final counts = <Reaction, int>{};
    final raw = json['counts'];
    if (raw is Map) {
      for (final entry in raw.entries) {
        final reaction = Reaction.named(entry.key);
        final count = entry.value;
        if (reaction != null && count is num && count > 0) counts[reaction] = count.toInt();
      }
    }
    return Reactions(counts: counts, mine: Reaction.named(json['mine']));
  }

  final Map<Reaction, int> counts;
  final Reaction? mine;

  int get total => counts.values.fold(0, (sum, count) => sum + count);

  int count(Reaction reaction) => counts[reaction] ?? 0;

  /// As they will be once [reaction] is chosen: the same one again takes it back, another one
  /// takes the old one's place.
  Reactions choosing(Reaction reaction) {
    final next = {...counts};
    final old = mine;
    if (old != null) next[old] = (next[old] ?? 1) - 1;
    final chosen = old == reaction ? null : reaction;
    if (chosen != null) next[chosen] = (next[chosen] ?? 0) + 1;
    next.removeWhere((_, count) => count <= 0);
    return Reactions(counts: next, mine: chosen);
  }

  @override
  bool operator ==(Object other) =>
      other is Reactions &&
      other.mine == mine &&
      other.counts.length == counts.length &&
      counts.entries.every((entry) => other.counts[entry.key] == entry.value);

  @override
  int get hashCode =>
      Object.hash(mine, Object.hashAllUnordered(counts.entries.map((e) => Object.hash(e.key, e.value))));
}

/// A game as the social lists name it.
class SocialGame {
  const SocialGame({required this.titleId, this.names = const {}, this.iconUrl});

  static SocialGame? fromJson(Object? json) {
    if (json is! Map || json['titleId'] is! String) return null;
    return SocialGame(
      titleId: json['titleId'] as String,
      names: namesOf(json['names']),
      iconUrl: json['iconUrl'] as String?,
    );
  }

  final String titleId;
  final Map<String, String> names;
  final String? iconUrl;

  String name(String language) => pickName(names, language) ?? titleId;
}

/// A trophy an activity item is about.
class ActivityTrophy {
  const ActivityTrophy({
    required this.trophyId,
    required this.grade,
    this.hidden = false,
    this.names,
    this.rarity,
    this.rarityLabel,
  });

  factory ActivityTrophy.fromJson(Map<String, dynamic> json) {
    final texts = json['texts'];
    return ActivityTrophy(
      trophyId: (json['trophyId'] as num? ?? 0).toInt(),
      grade: json['grade'] as String? ?? 'bronze',
      hidden: json['hidden'] == true,
      names: texts is Map
          ? {
              for (final entry in texts.entries)
                if (entry.value is Map && (entry.value as Map)['name'] is String)
                  entry.key as String: (entry.value as Map)['name'] as String,
            }
          : null,
      rarity: (json['rarity'] as num?)?.toDouble(),
      rarityLabel: json['rarityLabel'] as String?,
    );
  }

  final int trophyId;
  final String grade;
  final bool hidden;

  /// Names by language; null for a hidden trophy this user has not earned.
  final Map<String, String>? names;
  final double? rarity;
  final String? rarityLabel;

  String? name(String language) => names == null ? null : pickName(names!, language);
}

enum ActivityKind { trophy, platinum, firstPlay, longSession, friendship, milestone, levelUp, other }

/// One item of the activity feed: trophies earned in a game, a platinum, a first play, a long
/// session, a new friend, a milestone or a new trophy level.
class Activity {
  const Activity({
    required this.id,
    required this.kind,
    required this.createdAt,
    required this.actor,
    this.game,
    this.highlight,
    this.trophies = const [],
    this.trophyCount,
    this.seconds,
    this.friend,
    this.milestoneKind,
    this.milestoneValue,
    this.level,
    this.reactions = const Reactions(),
  });

  static Activity? fromJson(Object? json) {
    if (json is! Map<String, dynamic> || json['id'] is! String || json['actor'] is! Map<String, dynamic>) return null;
    final milestone = json['milestone'];
    return Activity(
      id: json['id'] as String,
      kind: switch (json['kind']) {
        'trophy' => ActivityKind.trophy,
        'platinum' => ActivityKind.platinum,
        'first_play' => ActivityKind.firstPlay,
        'long_session' => ActivityKind.longSession,
        'friendship' => ActivityKind.friendship,
        'milestone' => ActivityKind.milestone,
        'level_up' => ActivityKind.levelUp,
        _ => ActivityKind.other,
      },
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
      actor: Person.fromJson(json['actor'] as Map<String, dynamic>),
      game: SocialGame.fromJson(json['game']),
      highlight: json['highlight'] as String?,
      trophies: [
        for (final trophy in json['trophies'] as List<dynamic>? ?? const [])
          if (trophy is Map<String, dynamic>) ActivityTrophy.fromJson(trophy),
      ],
      trophyCount: (json['trophyCount'] as num?)?.toInt(),
      seconds: (json['seconds'] as num?)?.toInt(),
      friend: json['friend'] is Map<String, dynamic> ? Person.fromJson(json['friend'] as Map<String, dynamic>) : null,
      milestoneKind: milestone is Map ? milestone['kind'] as String? : null,
      milestoneValue: milestone is Map ? (milestone['value'] as num?)?.toInt() : null,
      level: LevelBadge.fromJson(json['level']),
      reactions: Reactions.fromJson(json['reactions']),
    );
  }

  final String id;
  final ActivityKind kind;
  final DateTime createdAt;
  final Person actor;
  final SocialGame? game;

  /// "platinum", "rare" (a trophy held by at most 20 % of players) or null.
  final String? highlight;

  /// The best first, at most five.
  final List<ActivityTrophy> trophies;
  final int? trophyCount;
  final int? seconds;
  final Person? friend;

  /// "trophies", "platinums", "games" or "hours", and the round number reached.
  final String? milestoneKind;
  final int? milestoneValue;
  final LevelBadge? level;
  final Reactions reactions;

  Activity withReactions(Reactions next) => Activity(
    id: id,
    kind: kind,
    createdAt: createdAt,
    actor: actor,
    game: game,
    highlight: highlight,
    trophies: trophies,
    trophyCount: trophyCount,
    seconds: seconds,
    friend: friend,
    milestoneKind: milestoneKind,
    milestoneValue: milestoneValue,
    level: level,
    reactions: next,
  );
}

/// The feed as the launcher holds it: newest first (IDs are time-ordered UUIDv7s), one item per
/// ID, and where the next, older page starts.
class FeedList {
  List<Activity> items = const [];
  String? next;
  bool loaded = false;

  /// The first page, in place of whatever was read before.
  void load(List<Activity> page, String? next) {
    items = const [];
    loaded = true;
    this.next = next;
    page.forEach(upsert);
  }

  /// An older page, after what is there.
  void loadOlder(List<Activity> page, String? next) {
    this.next = next;
    page.forEach(upsert);
  }

  /// A new or changed item: it replaces the one with its ID, or goes in at its place.
  void upsert(Activity item) {
    final list = [...items];
    final at = list.indexWhere((known) => known.id == item.id);
    if (at >= 0) {
      list[at] = item;
    } else {
      final place = list.indexWhere((known) => known.id.compareTo(item.id) < 0);
      list.insert(place < 0 ? list.length : place, item);
    }
    items = list;
  }

  void setReactions(String id, Reactions reactions) {
    final at = items.indexWhere((item) => item.id == id);
    if (at < 0) return;
    items = [...items]..[at] = items[at].withReactions(reactions);
  }

  void clear() {
    items = const [];
    next = null;
    loaded = false;
  }
}

/// Who a leaderboard ranks: the user and their friends, or everyone whose trophies (and, for a
/// game, library) are public.
enum BoardScope { friends, global }

/// What a game's leaderboard ranks by.
enum GameBoard { points, time, completion }

class BoardEntry {
  const BoardEntry({required this.rank, required this.user, required this.value, this.level});

  static BoardEntry? fromJson(Object? json) {
    if (json is! Map<String, dynamic> || json['user'] is! Map<String, dynamic>) return null;
    return BoardEntry(
      rank: (json['rank'] as num? ?? 0).toInt(),
      user: Person.fromJson(json['user'] as Map<String, dynamic>),
      value: (json['value'] as num? ?? 0).toInt(),
      level: LevelBadge.fromJson(json['level']),
    );
  }

  final int rank;
  final Person user;

  /// Points, seconds played, or completion percent.
  final int value;
  final LevelBadge? level;
}

/// What a board shows, line by line.
sealed class BoardLine {
  const BoardLine();
}

class BoardPerson extends BoardLine {
  const BoardPerson(this.entry, {required this.me});
  final BoardEntry entry;
  final bool me;
}

/// Places left out between the top and the people around the user.
class BoardGap extends BoardLine {
  const BoardGap();
}

/// The user, not on the board: where they would be.
class BoardUnlisted extends BoardLine {
  const BoardUnlisted({this.rank, required this.value});
  final int? rank;
  final int value;
}

/// A leaderboard as AnyTogether answers it: the top, the user's place, and the people around them.
class Leaderboard {
  const Leaderboard({
    required this.board,
    required this.scope,
    this.game,
    this.entries = const [],
    this.myRank,
    this.myValue = 0,
    this.listed = true,
    this.around = const [],
    this.total = 0,
  });

  factory Leaderboard.fromJson(Map<String, dynamic> json) {
    final me = json['me'];
    List<BoardEntry> entries(Object? list) => [
      for (final item in list as List<dynamic>? ?? const []) ?BoardEntry.fromJson(item),
    ];
    return Leaderboard(
      board: json['board'] as String? ?? 'points',
      scope: json['scope'] == 'global' ? BoardScope.global : BoardScope.friends,
      game: SocialGame.fromJson(json['game']),
      entries: entries(json['entries']),
      myRank: me is Map ? (me['rank'] as num?)?.toInt() : null,
      myValue: me is Map ? (me['value'] as num? ?? 0).toInt() : 0,
      listed: me is Map ? me['listed'] != false : true,
      around: entries(json['around']),
      total: (json['total'] as num? ?? 0).toInt(),
    );
  }

  /// "points", "time" or "completion".
  final String board;
  final BoardScope scope;
  final SocialGame? game;
  final List<BoardEntry> entries;

  /// The user's rank (null with nothing to rank) and value; not [listed] when the board leaves
  /// them out (private, or nothing yet), the rank then saying where they would be.
  final int? myRank;
  final int myValue;
  final bool listed;
  final List<BoardEntry> around;
  final int total;

  /// The top; then, when the user is further down, a gap and the people around them; or a line
  /// for the user when they are not on the board.
  List<BoardLine> lines(String me) {
    final lines = <BoardLine>[for (final entry in entries) BoardPerson(entry, me: entry.user.id == me)];
    final shown = {for (final entry in entries) entry.user.id};
    final rest = around.where((entry) => !shown.contains(entry.user.id)).toList();
    if (rest.isNotEmpty) {
      if (entries.isNotEmpty && rest.first.rank > entries.last.rank + 1) lines.add(const BoardGap());
      lines.addAll([for (final entry in rest) BoardPerson(entry, me: entry.user.id == me)]);
    }
    if (!listed) lines.add(BoardUnlisted(rank: myRank, value: myValue));
    return lines;
  }
}

enum NoticeKind {
  friendRequest,
  friendAccepted,
  message,
  partyInvite,
  gameInvite,
  missedCall,
  lfgRequest,
  lfgAccepted,
  levelUp,
  challengeInvite,
  challengeStarted,
  challengeEnded,
  warning,
  other;

  static NoticeKind named(Object? name) => switch (name) {
    'friend_request' => friendRequest,
    'friend_accepted' => friendAccepted,
    'message' => message,
    'party_invite' => partyInvite,
    'game_invite' => gameInvite,
    'missed_call' => missedCall,
    'lfg_request' => lfgRequest,
    'lfg_accepted' => lfgAccepted,
    'level_up' => levelUp,
    'challenge_invite' => challengeInvite,
    'challenge_started' => challengeStarted,
    'challenge_ended' => challengeEnded,
    'warning' => warning,
    _ => other,
  };

  /// Whether a new one deserves a toast of its own: requests, invites and missed calls are
  /// announced by their own events already; challenges by nothing else.
  bool get toastsOnItsOwn =>
      this == message ||
      this == warning ||
      this == other ||
      this == challengeInvite ||
      this == challengeStarted ||
      this == challengeEnded;
}

/// A notification from AnyTogether: a friend request or answer, messages while no device was
/// connected, an invite, a missed call, a looking-for-group answer, a level or a moderator's
/// warning.
class Notice {
  const Notice({
    required this.id,
    required this.kind,
    required this.kindName,
    this.actor,
    this.subjectId,
    this.data = const {},
    this.read = false,
    required this.createdAt,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? createdAt;

  static Notice? fromJson(Object? json) {
    if (json is! Map<String, dynamic> || json['id'] is! String) return null;
    final created = DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
    final data = json['data'];
    return Notice(
      id: json['id'] as String,
      kind: NoticeKind.named(json['kind']),
      kindName: json['kind'] as String? ?? '',
      actor: json['actor'] is Map<String, dynamic> && (json['actor'] as Map)['userId'] is String
          ? Person.fromJson(json['actor'] as Map<String, dynamic>)
          : null,
      subjectId: json['subjectId'] is String ? json['subjectId'] as String : null,
      // Fields of a shape this launcher does not expect are left out, not a failure.
      data: data is Map<String, dynamic> ? data : const {},
      read: json['read'] == true,
      createdAt: created,
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? ''),
    );
  }

  final String id;
  final NoticeKind kind;

  /// The kind as the server named it (family_request and others this launcher shows as other).
  final String kindName;

  /// Who did it; null for a warning.
  final Person? actor;

  /// What it is about (a challenge's ID for the challenge kinds).
  final String? subjectId;

  /// What the kind carries: message {conversationId, title, group, count, text}, game_invite
  /// {sessionId, titleId}, warning {reason}, lfg_* {postId, titleId, gameNames, purpose,
  /// invite}, level_up {level, tier, frame}, challenge_* {challengeId, title, titleId, gameNames,
  /// metric, endsAt}, challenge_ended also {rank, value, entrants, winner}.
  final Map<String, dynamic> data;
  final bool read;
  final DateTime createdAt;
  final DateTime updatedAt;

  int? get count => (data['count'] as num?)?.toInt();
  String? get text => data['text'] is String ? data['text'] as String : null;
  String? get titleId => data['titleId'] is String ? data['titleId'] as String : null;
  LevelBadge? get level => LevelBadge.fromJson(data);

  Notice markedRead() => Notice(
    id: id,
    kind: kind,
    kindName: kindName,
    actor: actor,
    subjectId: subjectId,
    data: data,
    read: true,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );
}

/// The notification center as the launcher holds it: newest first, one per ID, and the badge.
class NoticeList {
  List<Notice> items = const [];
  int unread = 0;
  bool more = false;
  bool loaded = false;

  void load(List<Notice> page, {required int unread, required bool more}) {
    items = const [];
    loaded = true;
    loadOlder(page, unread: unread, more: more);
  }

  void loadOlder(List<Notice> page, {required int unread, required bool more}) {
    page.forEach(upsert);
    this.unread = unread;
    this.more = more;
  }

  /// New, or one that gathered another message.
  void upsert(Notice notice) {
    final list = [...items];
    final at = list.indexWhere((known) => known.id == notice.id);
    if (at >= 0) {
      list[at] = notice;
    } else {
      final place = list.indexWhere((known) => known.id.compareTo(notice.id) < 0);
      list.insert(place < 0 ? list.length : place, notice);
    }
    items = list;
  }

  /// Read on some device: these, or all (null).
  void readOn(List<String>? ids, int unread) {
    items = [for (final item in items) ids == null || ids.contains(item.id) ? item.markedRead() : item];
    this.unread = unread;
  }

  /// Read here, before the server answers; the badge drops once.
  void markRead(String id) {
    final at = items.indexWhere((item) => item.id == id);
    if (at < 0 || items[at].read) return;
    items = [...items]..[at] = items[at].markedRead();
    unread = (unread - 1).clamp(0, 1 << 30);
  }

  void markAllRead() {
    items = [for (final item in items) item.markedRead()];
    unread = 0;
  }

  void clear() {
    items = const [];
    unread = 0;
    more = false;
    loaded = false;
  }
}

/// The feed, the boards and the notifications, read through the account, and what the gateway
/// says about them.
class Social with Notifier {
  Social({required this.account, required this.socket}) {
    _events = socket.events.listen(_event);
  }

  final TogetherAccount account;
  final TogetherSocket socket;
  late final StreamSubscription<TogetherEvent> _events;

  final FeedList feed = FeedList();
  final NoticeList notices = NoticeList();

  /// A notification came in that nothing else announces (a message while away, a warning).
  void Function(Notice notice)? onNotice;

  /// A notification of a family's (a parent answered or changed something).
  void Function(Notice notice)? onFamilyNotice;

  /// An activity item came or changed on the gateway, whether or not the feed was read: a
  /// profile showing it takes it.
  void Function(Activity item)? onActivity;

  /// Runs a new item's change of the feed with the focus held on the item it is on (the launcher
  /// sets it: a new item coming in above must not move what the keys are on).
  void Function(void Function() change)? holdFeedFocus;

  // The feed.

  /// Friends' activity, newest first; [before] an item's ID reads the page after it.
  Future<(List<Activity>, String?)> readFeed({String? before, int? limit}) async {
    final page = await account.call('GET', 'me/feed${_paging(before, limit)}');
    return (_activities(page['items']), page['next'] as String?);
  }

  /// One person's recent activity, as their privacy lets this user see it.
  Future<(List<Activity>, String?)> activityOf(String handle, {String? before, int? limit}) async {
    final page = await account.call('GET', 'users/${Uri.encodeComponent(handle)}/activity${_paging(before, limit)}');
    return (_activities(page['items']), page['next'] as String?);
  }

  Future<void> loadFeed() async {
    final (items, next) = await readFeed();
    feed.load(items, next);
    notifyListeners();
  }

  bool _readingOlder = false;

  /// The next, older page; nothing while one is on its way or at the end.
  Future<void> loadOlderFeed() async {
    final before = feed.next;
    if (before == null || _readingOlder) return;
    _readingOlder = true;
    try {
      final (items, next) = await readFeed(before: before);
      feed.loadOlder(items, next);
      notifyListeners();
    } finally {
      _readingOlder = false;
    }
  }

  /// Reacts to an item (the same reaction again takes it back): shown at once, then as the
  /// server says; a failure puts the old ones back and is thrown.
  Future<void> react(String id, Reaction reaction) async {
    final item = feed.items.where((known) => known.id == id).firstOrNull;
    if (item == null) return;
    final before = item.reactions;
    final chosen = before.choosing(reaction);
    feed.setReactions(id, chosen);
    notifyListeners();
    try {
      final path = 'activities/${Uri.encodeComponent(id)}/reaction';
      final mine = chosen.mine;
      final now = mine == null
          ? await account.call('DELETE', path)
          : await account.call('PUT', path, {'reaction': mine.name});
      feed.setReactions(id, Reactions.fromJson(now));
    } on Object {
      feed.setReactions(id, before);
      rethrow;
    } finally {
      notifyListeners();
    }
  }

  // The boards.

  /// Overall trophy points.
  Future<Leaderboard> pointsBoard(BoardScope scope, {int? limit}) async => Leaderboard.fromJson(
    await account.call('GET', 'leaderboards/points?scope=${scope.name}${limit == null ? '' : '&limit=$limit'}'),
  );

  /// One game's board; a game no one has played on AnyTogether answers 404.
  Future<Leaderboard> gameBoard(String titleId, GameBoard by, BoardScope scope, {int? limit}) async =>
      Leaderboard.fromJson(
        await account.call(
          'GET',
          'games/${Uri.encodeComponent(titleId)}/leaderboard?by=${by.name}&scope=${scope.name}'
              '${limit == null ? '' : '&limit=$limit'}',
        ),
      );

  // The notifications.

  Future<void> loadNotices() async {
    final page = await account.call('GET', 'me/notifications');
    notices.load(_notices(page['notifications']), unread: _unread(page), more: page['more'] == true);
    notifyListeners();
  }

  Future<void> loadOlderNotices() async {
    final before = notices.items.lastOrNull?.id;
    if (before == null || !notices.more) return;
    final page = await account.call('GET', 'me/notifications${_paging(before, null)}');
    notices.loadOlder(_notices(page['notifications']), unread: _unread(page), more: page['more'] == true);
    notifyListeners();
  }

  /// The badge alone, read before the list.
  Future<void> loadUnread() async {
    final heard = _noticeEvents;
    final unread = _unread(await account.call('GET', 'me/notifications/unread'));
    // A notification event that came meanwhile has the newer count.
    if (heard != _noticeEvents) return;
    notices.unread = unread;
    notifyListeners();
  }

  /// The gateway's notification events so far, so a count read before one is not kept after it.
  int _noticeEvents = 0;

  /// Read here at once, then on the server, whose count follows.
  Future<void> readNotice(String id) async {
    notices.markRead(id);
    notifyListeners();
    notices.unread = _unread(await account.call('POST', 'me/notifications/${Uri.encodeComponent(id)}/read'));
    notifyListeners();
  }

  Future<void> readAllNotices() async {
    notices.markAllRead();
    notifyListeners();
    notices.unread = _unread(await account.call('POST', 'me/notifications/read-all'));
    notifyListeners();
  }

  /// Signed out: nothing kept.
  void clear() {
    feed.clear();
    notices.clear();
    notifyListeners();
  }

  void _event(TogetherEvent event) {
    final data = event.json;
    switch (event.type) {
      case 'live.ready':
        // Back online: the badge may have changed meanwhile.
        unawaited(loadUnread().catchError((Object _) {}));
      case 'feed.item':
        final item = Activity.fromJson(data);
        if (item != null) onActivity?.call(item);
        if (item == null || !feed.loaded) return;
        final hold = holdFeedFocus;
        if (hold != null) {
          hold(() => feed.upsert(item));
        } else {
          feed.upsert(item);
        }
        notifyListeners();
      case 'notification':
        final notice = Notice.fromJson(data['notification']);
        if (notice == null) return;
        _noticeEvents++;
        notices
          ..upsert(notice)
          ..unread = _unread(data);
        notifyListeners();
        if (notice.kindName.startsWith('family_')) onFamilyNotice?.call(notice);
        if (!notice.read && notice.kind.toastsOnItsOwn && !notice.kindName.startsWith('family_')) {
          onNotice?.call(notice);
        }
      case 'notification.read':
        _noticeEvents++;
        final ids = data['ids'];
        notices.readOn(ids is List ? [for (final id in ids) '$id'] : null, _unread(data));
        notifyListeners();
    }
  }

  static int _unread(Map<String, dynamic> json) => (json['unread'] as num? ?? 0).toInt();

  static List<Activity> _activities(Object? list) => [
    for (final item in list as List<dynamic>? ?? const []) ?Activity.fromJson(item),
  ];

  static List<Notice> _notices(Object? list) => [
    for (final item in list as List<dynamic>? ?? const []) ?Notice.fromJson(item),
  ];

  static String _paging(String? before, int? limit) {
    final query = [if (before != null) 'before=${Uri.encodeQueryComponent(before)}', if (limit != null) 'limit=$limit'];
    return query.isEmpty ? '' : '?${query.join('&')}';
  }

  void dispose() => unawaited(_events.cancel());
}
