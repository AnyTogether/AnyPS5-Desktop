import 'account.dart';
import 'people.dart';
import 'profiles.dart';

/// Finding people to play with beyond friends, as the macOS launcher's TogetherDiscover: the
/// looking-for-group board ("Find players"), parties their leaders list in public, suggestions,
/// players of a game and a game's hub. Who sees whom follows blocks and each person's privacy on
/// the server.

/// What a post is for: co-op over share play, an online game, a party to talk in, trophy help.
enum LfgPurpose {
  coop,
  online,
  party,
  trophies;

  static LfgPurpose named(Object? name) => values.where((purpose) => purpose.name == name).firstOrNull ?? coop;

  /// Co-op goes over share play, where a viewer can hold pad 2, 3 or 4; everyone else ends up in
  /// the poster's party of eight.
  int get maxSlots => this == coop ? 3 : 7;
}

/// Where an accepted player was invited: the poster's party or the share play they host.
class LfgInvite {
  const LfgInvite({required this.kind, required this.id});

  static LfgInvite? fromJson(Object? json) {
    if (json is! Map || json['id'] is! String) return null;
    return LfgInvite(kind: json['kind'] as String? ?? 'party', id: json['id'] as String);
  }

  final String kind;
  final String id;

  bool get isSharePlay => kind == 'share_play';
}

/// Someone's "I'm in" on the user's own post.
class LfgRequest {
  const LfgRequest({required this.user, required this.status, this.invite});

  static LfgRequest? fromJson(Object? json) {
    if (json is! Map<String, dynamic> || json['user'] is! Map<String, dynamic>) return null;
    return LfgRequest(
      user: Person.fromJson(json['user'] as Map<String, dynamic>),
      status: json['status'] as String? ?? 'pending',
      invite: LfgInvite.fromJson(json['invite']),
    );
  }

  final Person user;

  /// "pending", "accepted" or "declined".
  final String status;
  final LfgInvite? invite;

  bool get pending => status == 'pending';
}

/// Where the user stands with someone else's post.
enum LfgStanding { canAsk, waiting, accepted, declined, closed, own }

/// A post on the board.
class LfgPost {
  const LfgPost({
    required this.id,
    required this.author,
    required this.titleId,
    this.names = const {},
    required this.purpose,
    this.startsAt,
    this.languages = const [],
    required this.slots,
    this.filled = 0,
    this.note,
    required this.expiresAt,
    this.status = 'open',
    this.mine = false,
    this.myStatus,
    this.myInvite,
    this.requests,
  });

  static LfgPost? fromJson(Object? json) {
    if (json is! Map<String, dynamic> || json['id'] is! String || json['author'] is! Map<String, dynamic>) return null;
    final game = json['game'];
    final my = json['myRequest'];
    final requests = json['requests'];
    return LfgPost(
      id: json['id'] as String,
      author: Person.fromJson(json['author'] as Map<String, dynamic>),
      titleId: json['titleId'] as String? ?? '',
      names: game is Map ? namesOf(game['names']) : const {},
      purpose: LfgPurpose.named(json['purpose']),
      startsAt: DateTime.tryParse(json['startsAt'] as String? ?? ''),
      languages: [for (final code in json['languages'] as List<dynamic>? ?? const []) '$code'],
      slots: (json['slots'] as num? ?? 1).toInt(),
      filled: (json['filled'] as num? ?? 0).toInt(),
      note: json['note'] as String?,
      expiresAt: DateTime.tryParse(json['expiresAt'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
      status: json['status'] as String? ?? 'open',
      mine: json['mine'] == true,
      myStatus: my is Map ? my['status'] as String? : null,
      myInvite: my is Map ? LfgInvite.fromJson(my['invite']) : null,
      requests: requests is List ? [for (final request in requests) ?LfgRequest.fromJson(request)] : null,
    );
  }

  final String id;
  final Person author;
  final String titleId;
  final Map<String, String> names;
  final LfgPurpose purpose;

  /// Null: now.
  final DateTime? startsAt;
  final List<String> languages;
  final int slots;
  final int filled;
  final String? note;
  final DateTime expiresAt;

  /// "open", "full", "closed", "expired" or "removed".
  final String status;
  final bool mine;

  /// The user's own "I'm in" on it: its status and, once let in, where they were invited.
  final String? myStatus;
  final LfgInvite? myInvite;

  /// Only on the user's own posts: who wants in.
  final List<LfgRequest>? requests;

  String name(String language) => pickName(names, language) ?? titleId;

  bool isOpen([DateTime? now]) => status == 'open' && expiresAt.isAfter(now ?? DateTime.now()) && filled < slots;

  LfgStanding standing([DateTime? now]) {
    if (mine) return LfgStanding.own;
    return switch (myStatus) {
      'pending' => isOpen(now) ? LfgStanding.waiting : LfgStanding.closed,
      'accepted' => LfgStanding.accepted,
      'declined' => LfgStanding.declined,
      _ => isOpen(now) ? LfgStanding.canAsk : LfgStanding.closed,
    };
  }

  /// Minutes until it starts; 0 for now (a start a little in the past is now).
  int startsIn([DateTime? now]) {
    final start = startsAt;
    if (start == null) return 0;
    final minutes = (start.difference(now ?? DateTime.now()).inSeconds / 60).round();
    return minutes <= 1 ? 0 : minutes;
  }

  /// People still waiting for the poster's answer.
  List<LfgRequest> get pending => [
    for (final request in requests ?? const <LfgRequest>[])
      if (request.pending) request,
  ];
}

/// The board's filters: one game or all, what for, a language, and only what starts soon.
class LfgFilter {
  const LfgFilter({this.titleId, this.purpose, this.language, this.now = false});

  final String? titleId;
  final LfgPurpose? purpose;
  final String? language;
  final bool now;

  LfgFilter copyWith({
    String? Function()? titleId,
    LfgPurpose? Function()? purpose,
    String? Function()? language,
    bool? now,
  }) => LfgFilter(
    titleId: titleId == null ? this.titleId : titleId(),
    purpose: purpose == null ? this.purpose : purpose(),
    language: language == null ? this.language : language(),
    now: now ?? this.now,
  );

  /// The query string for GET /lfg; [before] is the last post of the page before.
  String query({String? before, int? limit}) {
    final items = [
      if (titleId != null) 'titleId=$titleId',
      if (purpose != null) 'purpose=${purpose!.name}',
      if (language != null) 'language=$language',
      if (now) 'now=1',
      if (before != null) 'before=${Uri.encodeQueryComponent(before)}',
      if (limit != null) 'limit=$limit',
    ];
    return items.isEmpty ? '' : '?${items.join('&')}';
  }

  @override
  bool operator ==(Object other) =>
      other is LfgFilter &&
      other.titleId == titleId &&
      other.purpose == purpose &&
      other.language == language &&
      other.now == now;

  @override
  int get hashCode => Object.hash(titleId, purpose, language, now);
}

/// A post being written in "Find players for" a game.
class LfgDraft {
  LfgDraft({
    required this.titleId,
    this.purpose = LfgPurpose.coop,
    this.slots = 1,
    required this.languages,
    this.note = '',
    this.startsIn = 0,
    this.hours = 3,
  });

  static const maxNote = 140;
  static const maxLanguages = 3;
  static const maxHours = 24;

  /// When it may start: now, or in so many minutes.
  static const startChoices = [0, 15, 30, 60, 120];

  final String titleId;
  LfgPurpose purpose;
  int slots;
  List<String> languages;
  String note;

  /// Minutes from now until it starts; 0 for now.
  int startsIn;

  /// Hours after the start until the post goes.
  int hours;

  /// Changes what it is for, keeping the slots within what the new purpose allows.
  void setPurpose(LfgPurpose next) {
    purpose = next;
    slots = slots.clamp(1, next.maxSlots);
  }

  /// Hours the post may stay after its start: until 24 hours from now.
  int get maxStay => (maxHours - (startsIn / 60).ceil()).clamp(1, maxHours);

  /// Starts at another time, the stay shortened to fit.
  void setStart(int minutes) {
    startsIn = minutes;
    hours = hours.clamp(1, maxStay);
  }

  /// What POST /lfg takes.
  Map<String, dynamic> body([DateTime? now]) {
    final at = (now ?? DateTime.now()).toUtc();
    final start = at.add(Duration(minutes: startsIn < 0 ? 0 : startsIn));
    final latest = at.add(const Duration(hours: maxHours));
    final stay = start.add(Duration(hours: hours.clamp(1, maxHours)));
    final expires = stay.isAfter(latest) ? latest : stay;
    final text = note.trim();
    return {
      'titleId': titleId,
      'purpose': purpose.name,
      'slots': slots.clamp(1, purpose.maxSlots),
      'languages': languages.take(maxLanguages).toList(),
      'expiresAt': expires.toIso8601String(),
      if (startsIn > 0) 'startsAt': start.toIso8601String(),
      if (text.isNotEmpty) 'note': text.length > maxNote ? text.substring(0, maxNote) : text,
    };
  }
}

/// A game with open posts, for the board's game filter.
class LfgGame {
  const LfgGame({required this.titleId, required this.posts, this.names = const {}});

  static LfgGame? fromJson(Object? json) {
    if (json is! Map || json['titleId'] is! String) return null;
    return LfgGame(
      titleId: json['titleId'] as String,
      posts: (json['posts'] as num? ?? 0).toInt(),
      names: namesOf(json['names']),
    );
  }

  final String titleId;
  final int posts;
  final Map<String, String> names;

  String name(String language) => pickName(names, language) ?? titleId;
}

/// How strangers get into a public party: they ask, or walk in.
enum PublicJoin { request, open }

/// A party in the public list.
class PublicParty {
  const PublicParty({
    required this.id,
    this.host,
    this.titleId,
    this.names = const {},
    this.language,
    this.join = PublicJoin.request,
    this.size = 1,
    this.max = 8,
    this.requested = false,
  });

  static PublicParty? fromJson(Object? json) {
    if (json is! Map<String, dynamic> || json['id'] is! String) return null;
    final game = json['game'];
    return PublicParty(
      id: json['id'] as String,
      host: json['host'] is Map<String, dynamic> ? Person.fromJson(json['host'] as Map<String, dynamic>) : null,
      titleId: json['titleId'] as String?,
      names: game is Map ? namesOf(game['names']) : const {},
      language: json['language'] as String?,
      join: json['join'] == 'open' ? PublicJoin.open : PublicJoin.request,
      size: (json['size'] as num? ?? 1).toInt(),
      max: (json['max'] as num? ?? 8).toInt(),
      requested: json['requested'] == true,
    );
  }

  final String id;
  final Person? host;
  final String? titleId;
  final Map<String, String> names;
  final String? language;
  final PublicJoin join;
  final int size;
  final int max;

  /// The user asked to join and waits.
  final bool requested;

  bool get full => size >= max;
}

/// "Show me in discovery": what the user chose, or following the library's privacy.
class Discovery {
  const Discovery({required this.discoverable, this.chosen, this.languages = const []});

  factory Discovery.fromJson(Map<String, dynamic> json) => Discovery(
    discoverable: json['discoverable'] == true,
    chosen: json['chosen'] as bool?,
    languages: [for (final code in json['languages'] as List<dynamic>? ?? const []) '$code'],
  );

  static const maxLanguages = 5;

  /// Whether the user shows in discovery now.
  final bool discoverable;

  /// What they chose; null while it follows the library.
  final bool? chosen;
  final List<String> languages;

  /// The languages with [language] turned on or off; null when it would go past five.
  List<String>? toggling(String language) {
    if (languages.contains(language)) {
      return [
        for (final code in languages)
          if (code != language) code,
      ];
    }
    return languages.length >= maxLanguages ? null : [...languages, language];
  }
}

/// Someone found in discovery: their card, where the user stands with them, and why.
class DiscoveredPerson {
  const DiscoveredPerson({
    required this.user,
    this.friendship = 'none',
    this.state,
    this.lastPlayedAt,
    this.reasons = const [],
  });

  static DiscoveredPerson? fromJson(Object? json) {
    if (json is! Map<String, dynamic> || json['user'] is! Map<String, dynamic>) return null;
    final presence = json['presence'];
    return DiscoveredPerson(
      user: Person.fromJson(json['user'] as Map<String, dynamic>),
      friendship: json['friendship'] as String? ?? 'none',
      state: presence is Map ? presence['state'] as String? : null,
      lastPlayedAt: DateTime.tryParse(json['lastPlayedAt'] as String? ?? ''),
      reasons: [
        for (final reason in json['reasons'] as List<dynamic>? ?? const [])
          if (reason is Map) DiscoverReason.fromJson(reason),
      ],
    );
  }

  final Person user;

  /// "none", "friends", "pending_out" or "pending_in".
  final String friendship;

  /// "in_game", "online", "away", "offline" or null when not shown.
  final String? state;
  final DateTime? lastPlayedAt;
  final List<DiscoverReason> reasons;

  /// A friend request can go to them.
  bool get canAsk => friendship == 'none';
}

/// Why someone is suggested: a game both play, friends in common, a shared language.
class DiscoverReason {
  const DiscoverReason({required this.kind, this.titleId, this.names = const {}, this.count, this.language});

  factory DiscoverReason.fromJson(Map<dynamic, dynamic> json) => DiscoverReason(
    kind: json['kind'] as String? ?? '',
    titleId: json['titleId'] as String?,
    names: namesOf(json['names']),
    count: (json['count'] as num?)?.toInt(),
    language: json['language'] as String?,
  );

  /// "game", "friends", "language", or one this launcher does not know.
  final String kind;
  final String? titleId;
  final Map<String, String> names;
  final int? count;
  final String? language;
}

/// Someone playing a game now, in its hub.
class HubPlayer {
  const HubPlayer({required this.user, this.since});

  final Person user;
  final DateTime? since;
}

/// One game's hub: who plays it now, open posts, public parties, its players.
class GameHub {
  const GameHub({
    required this.titleId,
    this.names = const {},
    this.players = 0,
    this.playingTotal = 0,
    this.playing = const [],
    this.lfg = const [],
    this.parties = const [],
    this.recentPlayers = const [],
  });

  factory GameHub.fromJson(Map<String, dynamic> json) {
    final game = json['game'];
    final playing = json['playing'];
    return GameHub(
      titleId: game is Map ? game['titleId'] as String? ?? '' : '',
      names: game is Map ? namesOf(game['names']) : const {},
      players: (json['players'] as num? ?? 0).toInt(),
      playingTotal: playing is Map ? (playing['total'] as num? ?? 0).toInt() : 0,
      playing: [
        if (playing is Map)
          for (final player in playing['people'] as List<dynamic>? ?? const [])
            if (player is Map && player['user'] is Map<String, dynamic>)
              HubPlayer(
                user: Person.fromJson(player['user'] as Map<String, dynamic>),
                since: DateTime.tryParse(player['since'] as String? ?? ''),
              ),
      ],
      lfg: [for (final post in json['lfg'] as List<dynamic>? ?? const []) ?LfgPost.fromJson(post)],
      parties: [for (final party in json['parties'] as List<dynamic>? ?? const []) ?PublicParty.fromJson(party)],
      recentPlayers: [
        for (final person in json['recentPlayers'] as List<dynamic>? ?? const []) ?DiscoveredPerson.fromJson(person),
      ],
    );
  }

  final String titleId;
  final Map<String, String> names;

  /// Accounts with the game in their library.
  final int players;
  final int playingTotal;
  final List<HubPlayer> playing;
  final List<LfgPost> lfg;
  final List<PublicParty> parties;
  final List<DiscoveredPerson> recentPlayers;

  GameHub withPost(LfgPost post) => GameHub(
    titleId: titleId,
    names: names,
    players: players,
    playingTotal: playingTotal,
    playing: playing,
    lfg: [for (final known in lfg) known.id == post.id ? post : known],
    parties: parties,
    recentPlayers: recentPlayers,
  );
}

/// The public topics a gateway socket listens to: the board and the public lists, all of them or
/// one game's. They only say "something changed"; the list is read again.
abstract final class DiscoverTopics {
  static const max = 8;
  static final _valid = RegExp(r'^(lfg|discover)(:[A-Z]{4}[0-9]{5})?$');

  /// Valid topics, each once, at most eight.
  static List<String> clean(Iterable<String> topics) => topics.where(_valid.hasMatch).toSet().take(max).toList();

  /// What a screen listens to: the board (all or one game's) and the public lists.
  static List<String> of(String? titleId) =>
      clean(titleId == null ? const ['lfg', 'discover'] : ['lfg:$titleId', 'discover:$titleId']);
}

/// Languages offered for posts, listings and discovery: ISO 639-1 codes, each named in itself.
abstract final class DiscoverLanguages {
  static const common = ['en', 'tr', 'de', 'fr', 'es', 'pt', 'it', 'ru', 'pl', 'nl', 'ar', 'ja', 'ko', 'zh'];

  static const _names = {
    'en': 'English',
    'tr': 'Türkçe',
    'de': 'Deutsch',
    'fr': 'Français',
    'es': 'Español',
    'pt': 'Português',
    'it': 'Italiano',
    'ru': 'Русский',
    'pl': 'Polski',
    'nl': 'Nederlands',
    'ar': 'العربية',
    'ja': '日本語',
    'ko': '한국어',
    'zh': '中文',
  };

  /// A code's name, as the language calls itself ("Türkçe", "Deutsch"); the code when unknown.
  static String name(String code) => _names[code] ?? code;
}

/// The discovery calls.
class Discover {
  const Discover(this.account);

  final TogetherAccount account;

  /// How many are online now, a number only (stats/online): accounts that are invisible or show
  /// their presence to nobody are not in it. Null when the server has no count.
  Future<int?> online() async {
    final read = await account.call('GET', 'stats/online');
    return switch (read['online']) {
      final int count when count >= 0 => count,
      _ => null,
    };
  }

  // The board.

  Future<(List<LfgPost>, bool)> board(LfgFilter filter, {String? before}) async {
    final page = await account.call('GET', 'lfg${filter.query(before: before)}');
    return (_posts(page['posts']), page['more'] == true);
  }

  /// Games with open posts, the busiest first.
  Future<List<LfgGame>> games() async {
    final list = await account.call('GET', 'lfg/games');
    return [for (final game in list['games'] as List<dynamic>? ?? const []) ?LfgGame.fromJson(game)];
  }

  /// The user's posts of the last two days with who asked, and the posts they said "I'm in" to.
  Future<(List<LfgPost>, List<LfgPost>)> mine() async {
    final mine = await account.call('GET', 'me/lfg');
    return (_posts(mine['posts']), _posts(mine['asked']));
  }

  Future<LfgPost?> post(LfgDraft draft, [DateTime? now]) async =>
      LfgPost.fromJson(await account.call('POST', 'lfg', draft.body(now)));

  Future<LfgPost?> read(String id) async => LfgPost.fromJson(await account.call('GET', 'lfg/$id'));

  /// The poster takes it off the board.
  Future<void> close(String id) => account.call('DELETE', 'lfg/$id');

  /// "I'm in".
  Future<LfgPost?> join(String id) async => LfgPost.fromJson(await account.call('POST', 'lfg/$id/requests', {}));

  Future<void> takeBack(String id) => account.call('DELETE', 'lfg/$id/requests/me');

  /// The poster's answer; yes invites the player to their party (or share play) on the server.
  Future<LfgPost?> answer(String postId, String userId, {required bool accept}) async =>
      LfgPost.fromJson(await account.call('POST', 'lfg/$postId/requests/$userId/${accept ? 'accept' : 'decline'}', {}));

  // Public parties.

  Future<List<PublicParty>> parties({String? titleId, String? language}) async {
    final query = [if (titleId != null) 'titleId=$titleId', if (language != null) 'language=$language'];
    final list = await account.call('GET', 'parties/public${query.isEmpty ? '' : '?${query.join('&')}'}');
    return [for (final party in list['parties'] as List<dynamic>? ?? const []) ?PublicParty.fromJson(party)];
  }

  /// Asks to join a public party; the leader's yes is an invite.
  Future<void> askToJoin(String partyId) => account.call('POST', 'parties/$partyId/requests', {});

  Future<void> cancelAsk(String partyId) => account.call('DELETE', 'parties/$partyId/requests/me');

  /// Lists the party in public, or takes it off the list (null); the leader only.
  Future<void> listParty(String partyId, {PublicJoin? join, String? titleId, String? language}) =>
      account.call('PATCH', 'parties/$partyId', {
        'public': join == null ? null : {'join': join.name, 'titleId': titleId, 'language': language},
      });

  // Discovery.

  Future<Discovery> discovery() async => Discovery.fromJson(await account.call('GET', 'me/discovery'));

  /// "Show me in discovery" (null: follow the library) and the languages played in.
  Future<Discovery> setDiscovery({bool? Function()? discoverable, List<String>? languages}) async => Discovery.fromJson(
    await account.call('PATCH', 'me/discovery', {
      if (discoverable != null) 'discoverable': discoverable(),
      if (languages != null) 'languages': languages.take(Discovery.maxLanguages).toList(),
    }),
  );

  Future<List<DiscoveredPerson>> suggestions() async {
    final list = await account.call('GET', 'discover/suggestions');
    return [for (final person in list['suggestions'] as List<dynamic>? ?? const []) ?DiscoveredPerson.fromJson(person)];
  }

  Future<GameHub> hub(String titleId) async => GameHub.fromJson(await account.call('GET', 'games/$titleId/hub'));

  static List<LfgPost> _posts(Object? list) => [
    for (final post in list as List<dynamic>? ?? const []) ?LfgPost.fromJson(post),
  ];
}
