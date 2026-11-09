import 'dart:async';

import 'account.dart';
import 'media.dart';
import 'notifier.dart';
import 'people.dart';
import 'play_together.dart';
import 'socket.dart';

/// At most eight in a party on a server without a media server: its voice is a mesh, each member
/// talking to every other. A server with one says its own size ([Party.max]).
const maxPartySize = 8;

/// A party's join code: eight characters people can read out, and the website's page for it. A
/// code never lets anyone in: it asks the leader, whose yes is an invite.
class JoinCode {
  const JoinCode({required this.code, required this.url, this.expiresAt});

  /// The code, or null when the server sent none.
  static JoinCode? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final code = json['code'];
    if (code is! String || code.isEmpty) return null;
    final url = json['url'] is String ? Uri.tryParse(json['url'] as String) : null;
    return JoinCode(
      code: code,
      url: url ?? Uri.parse('https://anytogether.net/join/$code'),
      expiresAt: json['expiresAt'] is String ? DateTime.tryParse(json['expiresAt'] as String) : null,
    );
  }

  /// No 0 or O, no 1 or I.
  static const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  static const length = 8;

  final String code;
  final Uri url;
  final DateTime? expiresAt;

  /// XXXX-XXXX, for reading out.
  String get shown => show(code);

  static String show(String code) => code.length == length ? '${code.substring(0, 4)}-${code.substring(4)}' : code;

  /// A code as typed or pasted (any case, with dashes or spaces, or its link); null when it
  /// cannot be one.
  static String? clean(String text) {
    var raw = text.trim();
    final link = RegExp(r'/join/([^/?#]+)/?(?:[?#].*)?$').firstMatch(raw);
    if (link != null) raw = link.group(1)!;
    final code = raw.toUpperCase().replaceAll(RegExp(r'[\s-]'), '');
    if (code.length != length || !code.split('').every(alphabet.contains)) return null;
    return code;
  }
}

/// The game a join code's party plays, by its names in each language.
class JoinGame {
  const JoinGame({required this.titleId, this.title, this.names = const {}});

  final String titleId;
  final String? title;
  final Map<String, String> names;

  /// Its name in [language] (en, tr), else its title, else the title ID.
  String name(String language) => names[language] ?? title ?? titleId;
}

/// What a join code opens, as anyone holding it sees it: whose party (or share play), its game,
/// how full, and where the reader stands (none, member, requested, invited).
class JoinPreview {
  const JoinPreview({
    required this.code,
    required this.kind,
    required this.id,
    this.host,
    this.game,
    this.size = 0,
    this.max = 0,
    this.state = 'none',
  });

  factory JoinPreview.fromJson(Map<String, dynamic> json) {
    final host = json['host'];
    final game = json['game'];
    return JoinPreview(
      code: json['code'] as String? ?? '',
      kind: json['kind'] as String? ?? 'party',
      id: json['id'] as String? ?? '',
      host: host is Map<String, dynamic>
          ? Person(
              id: host['userId'] as String? ?? '',
              handle: host['handle'] as String? ?? '',
              displayName: host['displayName'] as String? ?? '',
              avatar: host['avatar'] as String?,
            )
          : null,
      game: game is Map<String, dynamic> && game['titleId'] is String
          ? JoinGame(
              titleId: game['titleId'] as String,
              title: game['title'] as String?,
              names: {
                for (final entry in (game['names'] as Map<String, dynamic>? ?? const {}).entries)
                  if (entry.value is String) entry.key: entry.value as String,
              },
            )
          : null,
      size: (json['size'] as num?)?.toInt() ?? 0,
      max: (json['max'] as num?)?.toInt() ?? 0,
      state: json['state'] as String? ?? 'none',
    );
  }

  final String code;
  final String kind;
  final String id;
  final Person? host;
  final JoinGame? game;
  final int size;
  final int max;
  final String state;

  bool get party => kind == 'party';

  /// Nobody else fits.
  bool get full => max > 0 && size >= max;

  JoinPreview withState(String state) =>
      JoinPreview(code: code, kind: kind, id: id, host: host, game: game, size: size, max: max, state: state);
}

/// The party someone is in: who leads it, who is in it and who is invited, whether friends may
/// walk in, its join code, Discord link and the people asking to join, and its voice call while
/// one runs.
class Party {
  const Party({
    required this.id,
    required this.leaderId,
    required this.open,
    required this.members,
    required this.invited,
    required this.callId,
    required this.inCall,
    this.muted = const {},
    this.deafened = const {},
    this.callMedia = MediaRoute.mesh,
    this.max = maxPartySize,
    this.joinCode,
    this.discord,
    this.requests = const [],
    this.together,
    this.listing,
    this.conversationId,
  });

  factory Party.fromJson(Map<String, dynamic> json) {
    final call = json['call'];
    return Party(
      id: json['id'] as String,
      leaderId: json['leaderId'] as String? ?? '',
      open: json['privacy'] == 'friends',
      members: [
        for (final member in (json['members'] as List<dynamic>? ?? const []))
          Person.fromJson(member as Map<String, dynamic>),
      ],
      invited: [
        for (final person in (json['invited'] as List<dynamic>? ?? const []))
          Person.fromJson(person as Map<String, dynamic>),
      ],
      callId: call is Map<String, dynamic> ? call['id'] as String? : null,
      inCall: call is Map<String, dynamic> ? _ids(call['in']) : const {},
      muted: call is Map<String, dynamic> ? _ids(call['muted']) : const {},
      deafened: call is Map<String, dynamic> ? _ids(call['deafened']) : const {},
      callMedia: call is Map<String, dynamic> ? MediaRoute.parse(call['media']) : MediaRoute.mesh,
      max: switch (json['max']) {
        final num max when max >= 1 => max.toInt(),
        _ => maxPartySize,
      },
      joinCode: JoinCode.fromJson(json['joinCode']),
      discord: json['discord'] is String && (json['discord'] as String).isNotEmpty ? json['discord'] as String : null,
      requests: [
        for (final person in (json['requests'] as List<dynamic>? ?? const []))
          if (person is Map<String, dynamic>) Person.fromJson(person),
      ],
      together: PartyTogether.fromJson(json['together']),
      listing: PartyListing.fromJson(json['public']),
      conversationId: json['conversationId'] is String && (json['conversationId'] as String).isNotEmpty
          ? json['conversationId'] as String
          : null,
    );
  }

  final String id;
  final String leaderId;
  final bool open;
  final List<Person> members;
  final List<Person> invited;

  /// The party's voice call, who is talking in it and who of them muted themselves.
  final String? callId;
  final Set<String> inCall;
  final Set<String> muted;

  /// Who in the call hears no one (and so is muted too).
  final Set<String> deafened;

  /// The call on the mesh, or through the media server (a call with more voices than the mesh
  /// holds, on a server with one).
  final MediaRoute callMedia;

  /// How many the party may hold on this server: eight, or more with a media server.
  final int max;

  /// The leader's code for people who are not friends to ask to join with; null when none works.
  final JoinCode? joinCode;

  /// The party's Discord server or channel link, for everyone in it.
  final String? discord;

  /// People asking to join (from the code, or the public list), for the leader to answer.
  final List<Person> requests;

  /// The party's Play Together game while one runs (older servers never say).
  final PartyTogether? together;

  /// How the party is listed in public (Find Players); null while it is not.
  final PartyListing? listing;

  /// The party's text chat, beside its voice: an ordinary group conversation that follows the
  /// party. Only its members get it; an older server sends none.
  final String? conversationId;

  /// User ids as a list of strings, or of peers with a userId.
  static Set<String> _ids(Object? list) => {
    for (final item in (list as List<dynamic>? ?? const []))
      if (item is String) item else if (item is Map && item['userId'] is String) item['userId'] as String,
  };

  bool get full => members.length >= max;

  bool leads(String userId) => leaderId == userId;

  bool has(String userId) => members.any((person) => person.id == userId);

  Party copyWith({
    String? leaderId,
    bool? open,
    List<Person>? members,
    List<Person>? invited,
    String? Function()? callId,
    Set<String>? inCall,
    Set<String>? muted,
    Set<String>? deafened,
    MediaRoute? callMedia,
    JoinCode? Function()? joinCode,
    String? Function()? discord,
    List<Person>? requests,
  }) => Party(
    id: id,
    leaderId: leaderId ?? this.leaderId,
    open: open ?? this.open,
    members: members ?? this.members,
    invited: invited ?? this.invited,
    callId: callId == null ? this.callId : callId(),
    inCall: inCall ?? this.inCall,
    muted: muted ?? this.muted,
    deafened: deafened ?? this.deafened,
    callMedia: callMedia ?? this.callMedia,
    max: max,
    joinCode: joinCode == null ? this.joinCode : joinCode(),
    discord: discord == null ? this.discord : discord(),
    requests: requests ?? this.requests,
    together: together,
    listing: listing,
    conversationId: conversationId,
  );
}

/// How a party is listed in public: who may get in (they ask, or walk in), and the game and
/// language it is about.
class PartyListing {
  const PartyListing({required this.open, this.titleId, this.language});

  static PartyListing? fromJson(Object? json) {
    if (json is! Map) return null;
    return PartyListing(
      open: json['join'] == 'open',
      titleId: json['titleId'] as String?,
      language: json['language'] as String?,
    );
  }

  /// Anyone may walk in; else they ask.
  final bool open;
  final String? titleId;
  final String? language;
}

/// An invite to someone's party.
class PartyInvite {
  const PartyInvite({required this.partyId, required this.from, this.size});

  factory PartyInvite.fromJson(Map<String, dynamic> json) => PartyInvite(
    partyId: json['partyId'] as String,
    from: json['from'] is Map<String, dynamic> ? Person.fromJson(json['from'] as Map<String, dynamic>) : null,
    size: (json['size'] as num?)?.toInt(),
  );

  final String partyId;
  final Person? from;
  final int? size;
}

/// Parties: starting one, inviting friends, joining (by invite, or a friend's open
/// party), leaving; the party as everyone in it sees it, live.
class Parties with Notifier {
  Parties({required this.account, required this.socket}) {
    _events = socket.events.listen(_event);
  }

  final TogetherAccount account;
  final TogetherSocket socket;
  late final StreamSubscription<TogetherEvent> _events;

  Party? party;
  List<PartyInvite> invites = const [];
  bool loaded = false;

  /// Set when the leader took this launcher out of the party, until the next party.
  bool kicked = false;

  /// How each asker of the party's requests asked, by user id: "code" or "list" (from the
  /// party.request event; the party itself does not say).
  final Map<String, String> requestVia = {};

  /// Someone asks to join the party this launcher leads; the asker's request was answered.
  void Function(Person person, String via)? onRequest;
  void Function(bool accepted)? onRequestAnswered;

  /// The lead of the party came to this account (handed over, or the leader left).
  void Function()? onBecameLeader;

  String? get _me => account.user?.id;

  Future<void> refresh() async {
    final json = await account.call('GET', 'me/party');
    party = json['party'] is Map<String, dynamic> ? Party.fromJson(json['party'] as Map<String, dynamic>) : null;
    invites = [
      for (final invite in (json['invites'] as List<dynamic>? ?? const []))
        PartyInvite.fromJson(invite as Map<String, dynamic>),
    ];
    loaded = true;
    notifyListeners();
  }

  /// A new party with only this account in it; whoever is in another leaves it first.
  Future<void> create({bool open = false}) async {
    _keep(await account.call('POST', 'parties', {'privacy': open ? 'friends' : 'invite'}));
  }

  Future<void> invite(List<String> userIds) async {
    final current = party;
    if (current == null || userIds.isEmpty) return;
    _keep(await account.call('POST', 'parties/${current.id}/invites', {'userIds': userIds}));
  }

  Future<void> join(String partyId) async {
    _keep(await account.call('POST', 'parties/$partyId/join'));
    invites = invites.where((invite) => invite.partyId != partyId).toList();
    notifyListeners();
  }

  Future<void> decline(String partyId) async {
    invites = invites.where((invite) => invite.partyId != partyId).toList();
    notifyListeners();
    await account.call('POST', 'parties/$partyId/decline');
  }

  Future<void> leave() async {
    final current = party;
    if (current == null) return;
    party = null;
    notifyListeners();
    await account.call('POST', 'parties/${current.id}/leave');
  }

  /// Leader only: whether the leader's friends may join without an invite.
  Future<void> setOpen(bool open) async {
    final current = party;
    if (current == null) return;
    _keep(await account.call('PATCH', 'parties/${current.id}', {'privacy': open ? 'friends' : 'invite'}));
  }

  /// Leader only: someone out of the party.
  Future<void> kick(String userId) async {
    final current = party;
    if (current == null) return;
    await account.call('POST', 'parties/${current.id}/kick', {'userId': userId});
  }

  /// Leader only: someone else in the party leads it from now on (the website's Make leader).
  Future<void> makeLeader(String userId) async {
    final current = party;
    if (current == null) return;
    _keep(await account.call('POST', 'parties/${current.id}/leader', {'userId': userId}));
  }

  /// Leader only: a new join code, replacing the one before.
  Future<void> newCode() async {
    final current = party;
    if (current == null) return;
    final code = JoinCode.fromJson(await account.call('POST', 'parties/${current.id}/code', {}));
    if (party?.id != current.id) return;
    party = party!.copyWith(joinCode: () => code);
    notifyListeners();
  }

  /// Leader only: the join code stops working.
  Future<void> stopCode() async {
    final current = party;
    if (current == null) return;
    party = current.copyWith(joinCode: () => null);
    notifyListeners();
    try {
      await account.call('DELETE', 'parties/${current.id}/code');
    } on TogetherProblem catch (problem) {
      // No code worked anyway.
      if (problem.status != 404) rethrow;
    }
  }

  /// Leader only: someone asking to join is let in (an invite they answer) or turned down.
  Future<void> answerRequest(String userId, {required bool accept}) async {
    final current = party;
    if (current == null) return;
    party = current.copyWith(requests: current.requests.where((person) => person.id != userId).toList());
    requestVia.remove(userId);
    notifyListeners();
    await account.call('POST', 'parties/${current.id}/requests/$userId/${accept ? 'accept' : 'decline'}');
  }

  /// Leader only: the party's Discord link, or none.
  Future<void> setDiscord(String? link) async {
    final current = party;
    if (current == null) return;
    _keep(await account.call('PATCH', 'parties/${current.id}', {'discord': link}));
  }

  /// What a join code opens.
  Future<JoinPreview> preview(String code) async => JoinPreview.fromJson(await account.call('GET', 'join/$code'));

  /// Asks to join with a code: "requested", or "invited" when an invite waits already (it is
  /// read again so it shows).
  Future<String> askToJoin(String code) async {
    final json = await account.call('POST', 'join/$code');
    final state = json['state'] as String? ?? 'requested';
    if (state == 'invited') await refresh();
    return state;
  }

  /// The party as the server has it now, and whether the lead just came to this account.
  void _partyUpdated(Party? before, Party updated) {
    final me = _me;
    final becameLeader = me != null && before != null && !before.leads(me) && updated.leads(me);
    party = updated;
    notifyListeners();
    if (becameLeader) onBecameLeader?.call();
  }

  void _keep(Map<String, dynamic> json) {
    party = Party.fromJson(json);
    kicked = false;
    notifyListeners();
  }

  void clear() {
    party = null;
    requestVia.clear();
    invites = const [];
    loaded = false;
    kicked = false;
    notifyListeners();
  }

  void _event(TogetherEvent event) {
    final data = event.json;
    final current = party;
    final ours = current != null && data['partyId'] == current.id;
    if (ours) {
      _ours(event.type, data, current);
      return;
    }
    switch (event.type) {
      case 'live.ready':
        unawaited(refresh().catchError((Object _) {}));
      case 'party.invite':
        final invite = PartyInvite.fromJson(data);
        invites = [...invites.where((known) => known.partyId != invite.partyId), invite];
        notifyListeners();
      case 'party.request_answered':
        onRequestAnswered?.call(data['answer'] == 'accepted');
      case 'party.updated':
        final updated = Party.fromJson(data);
        if (current?.id == updated.id || (current == null && updated.has(_me ?? ''))) {
          _partyUpdated(current, updated);
        }
    }
  }

  /// What happened in the party this launcher is in.
  void _ours(String type, Map<String, dynamic> data, Party current) {
    switch (type) {
      // A party view that names its party as partyId too.
      case 'party.updated' when data['id'] == current.id:
        _partyUpdated(current, Party.fromJson(data));
      case 'party.request':
        final from = data['from'];
        if (from is! Map<String, dynamic>) return;
        final person = Person.fromJson(from);
        final via = data['via'] as String? ?? 'list';
        requestVia[person.id] = via;
        party = current.copyWith(requests: [...current.requests.where((known) => known.id != person.id), person]);
        notifyListeners();
        onRequest?.call(person, via);
      case 'party.member_joined':
        final member = Person.fromJson(data['member'] as Map<String, dynamic>);
        if (current.has(member.id)) return;
        party = current.copyWith(
          members: [...current.members, member],
          invited: current.invited.where((p) => p.id != member.id).toList(),
        );
        notifyListeners();
      case 'party.member_left':
        final gone = data['userId'] as String?;
        if (gone == _me) {
          party = null;
          kicked = data['reason'] == 'kicked';
        } else {
          party = current.copyWith(
            leaderId: data['leaderId'] as String?,
            members: current.members.where((p) => p.id != gone).toList(),
            inCall: {...current.inCall}..remove(gone),
          );
        }
        notifyListeners();
      case 'party.ended':
        party = null;
        notifyListeners();
      case 'call.joined':
        party = current.copyWith(
          callId: () => data['callId'] as String?,
          inCall: {...current.inCall, data['userId'] as String},
        );
        notifyListeners();
      case 'call.left':
        party = current.copyWith(
          inCall: {...current.inCall}..remove(data['userId']),
          muted: {...current.muted}..remove(data['userId']),
          deafened: {...current.deafened}..remove(data['userId']),
        );
        notifyListeners();
      case 'call.updated':
        final user = data['userId'] as String?;
        if (user == null) return;
        party = current.copyWith(
          muted: data['muted'] == true ? {...current.muted, user} : ({...current.muted}..remove(user)),
          deafened: data['deafened'] == true ? {...current.deafened, user} : ({...current.deafened}..remove(user)),
        );
        notifyListeners();
      case 'call.media' when data['callId'] == current.callId:
        party = current.copyWith(callMedia: MediaRoute.parse(data['media']));
        notifyListeners();
      case 'call.ended':
        party = current.copyWith(
          callId: () => null,
          inCall: const {},
          muted: const {},
          deafened: const {},
          callMedia: MediaRoute.mesh,
        );
        notifyListeners();
    }
  }

  void dispose() => unawaited(_events.cancel());
}
