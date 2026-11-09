import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// A request the fake AnyTogether got.
class FakeCall {
  FakeCall(this.method, this.path, this.body, this.headers, {this.bytes = const []});

  final String method;
  final String path;
  final Map<String, dynamic> body;
  final HttpHeaders headers;

  /// What came up when it was no JSON (a picture, a sealed file).
  final List<int> bytes;

  @override
  String toString() => '$method $path ${jsonEncode(body)}';
}

/// AnyTogether for the tests, on localhost: the API under /api/v1 as the launcher uses it, in
/// memory, and the realtime gateway on /rt. Everyone is a user named by a token; a test pushes
/// events to the sockets and looks at the calls and frames that came in.
class FakeTogether {
  FakeTogether._(this._server) {
    _server.listen(_serve);
  }

  static Future<FakeTogether> start() async => FakeTogether._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;

  Uri get base => Uri.parse('http://127.0.0.1:${_server.port}');

  final List<FakeCall> calls = [];

  /// The user signing in, and the code the mail would carry.
  Map<String, dynamic> me = {'id': 'u-me', 'handle': 'utku', 'displayName': 'Utku'};

  /// Whether it has idle and do not disturb (`status`); a server before them only knows
  /// appear offline and drops the field, as AnyTogether's checks do.
  bool presenceStatuses = false;
  String emailCode = '123456';

  /// How long an access token lives; a refresh gives a new one.
  int expiresIn = 900;
  int _tokens = 0;
  final Set<String> validAccess = {};
  final Set<String> validRefresh = {};

  /// Sign-ins waiting for an approval: device codes and hand-offs, by their secret.
  final Map<String, bool> _pending = {};
  final Map<String, String> _handoffSecrets = {};
  String? lastHandoff;
  String? lastDeviceCode;

  /// Answers for paths the tests choose: a status and a JSON body.
  final Map<String, (int, Object?)> answers = {};

  /// Files served as they are, by path (signed media links).
  final Map<String, List<int>> files = {};

  /// The kind of each media the launcher uploaded (POST /me/media), by its ID.
  final Map<String, String> mediaKinds = {};

  /// The gateway's sockets and the frames they sent.
  final List<WebSocket> sockets = [];
  final List<Map<String, dynamic>> frames = [];
  final _frameAdded = StreamController<Map<String, dynamic>>.broadcast();
  int heartbeatSeconds = 25;
  int _sessions = 0;

  /// People on the server by handle (their name cards), friends with their presence, and
  /// requests both ways.
  final Map<String, Map<String, dynamic>> people = {};
  final List<Map<String, dynamic>> friends = [];
  final List<Map<String, dynamic>> incoming = [];
  final List<Map<String, dynamic>> outgoing = [];

  /// A person card as the API sends it.
  static Map<String, dynamic> card(String id, String handle, String name) => {
    'userId': id,
    'handle': handle,
    'displayName': name,
    'avatar': null,
  };

  /// Someone the server knows, and so can be asked by handle.
  Map<String, dynamic> person(String id, String handle, String name) => people[handle] = card(id, handle, name);

  /// A friend with a presence (null is offline).
  void friend(String id, String handle, String name, {Map<String, dynamic>? presence}) {
    person(id, handle, name);
    friends.add({
      ...card(id, handle, name),
      'presence': presence ?? {'state': 'offline'},
    });
  }

  /// What the launcher's outbox sent: this computer, the games' names, the trophy sets, the
  /// sessions and the earned trophies (by "titleId/trophyId").
  final Map<String, Map<String, dynamic>> devices = {};
  final Map<String, Map<String, dynamic>> games = {};
  final Map<String, Map<String, dynamic>> trophySets = {};
  final Map<String, Map<String, dynamic>> playSessions = {};
  final Map<String, Map<String, dynamic>> earned = {};

  /// Conversations by id with their messages, the party the user is in and the invites, the
  /// party's call (who is in it, by user, with their device).
  final Map<String, Map<String, dynamic>> conversations = {};
  final Map<String, List<Map<String, dynamic>>> threads = {};

  /// Party chats by id: their messages are in [threads], but they are never listed or counted.
  final Map<String, Map<String, dynamic>> partyChats = {};

  /// The reports sent (POST /reports bodies).
  final List<Map<String, dynamic>> reports = [];
  Map<String, dynamic>? party;
  final List<Map<String, dynamic>> partyInvites = [];
  final Map<String, String> callPeers = {};

  /// The join codes the party gets, in turn, and what codes open (by code) for someone holding
  /// one.
  final List<String> nextCodes = ['K7QM3XPA', 'H8NZ4WRB', 'P2TV6YCD'];
  final Map<String, Map<String, dynamic>> joinPreviews = {};
  int _ids = 0;

  /// A conversation with [others] (cards), and its messages as [texts] by author id; each other
  /// member's receipt (read and delivered up to nothing yet; delivered only in a direct one).
  Map<String, dynamic> conversation(
    String id,
    List<Map<String, dynamic>> others, {
    List<(String, String)> texts = const [],
    int readSeq = 0,
    String updatedAt = '2026-10-24T20:00:00Z',
    bool pinned = false,
  }) {
    final members = [card(me['id'] as String, me['handle'] as String, me['displayName'] as String), ...others];
    final messages = threads[id] = [
      for (var index = 0; index < texts.length; index++) _message(id, index + 1, texts[index].$1, texts[index].$2),
    ];
    final direct = others.length == 1;
    return conversations[id] = {
      'id': id,
      'kind': direct ? 'direct' : 'group',
      'title': null,
      'members': members,
      'lastSeq': messages.length,
      'readSeq': readSeq,
      'lastMessage': messages.isEmpty ? null : messages.last,
      'updatedAt': updatedAt,
      'pinned': pinned,
      'muted': false,
      'receipts': [
        for (final other in others) {'userId': other['userId'], 'readSeq': 0, 'deliveredSeq': direct ? 0 : null},
      ],
    };
  }

  /// When the messages were sent: the minute is their place, so a test can make one fresh.
  String Function(int seq) messageTime = (seq) => '2026-10-24T20:${seq.toString().padLeft(2, '0')}:00Z';

  Map<String, dynamic> _message(String conversation, int seq, String author, String text, {String? id, int? replyTo}) =>
      {
        'id': id ?? 'm-$conversation-$seq',
        'conversationId': conversation,
        'seq': seq,
        'authorId': author,
        'kind': 'text',
        'text': text,
        'caption': null,
        'replyTo': replyTo,
        'editedAt': null,
        'editCount': 0,
        'reactions': <Map<String, dynamic>>[],
        'deletedAt': null,
        'createdAt': messageTime(seq),
      };

  /// The others' messages after the user's read mark that are still there, as the server counts.
  int unreadIn(Map<String, dynamic> conversation) => [
    for (final message in threads[conversation['id']] ?? const <Map<String, dynamic>>[])
      if (message['authorId'] != me['id'] &&
          message['deletedAt'] == null &&
          (message['seq'] as int) > (conversation['readSeq'] as int))
        message,
  ].length;

  /// The reactions a message has now, in the API's order, from who reacted with what.
  final Map<String, Map<String, Set<String>>> _reacted = {};
  static const reactionOrder = ['like', 'love', 'laugh', 'wow', 'sad', 'fire', 'gg'];

  List<Map<String, dynamic>> _reactions(String messageId) => [
    for (final name in reactionOrder)
      if (_reacted[messageId]?[name] case final Set<String> who when who.isNotEmpty)
        {'reaction': name, 'count': who.length, 'userIds': who.toList()},
  ];

  /// A message from someone else, as the gateway brings it.
  void receive(String conversation, String author, String text) {
    final thread = threads[conversation]!;
    final message = _message(conversation, thread.length + 1, author, text);
    thread.add(message);
    final view = (conversations[conversation] ?? partyChats[conversation])!;
    view['lastSeq'] = thread.length;
    view['lastMessage'] = message;
    push('message.created', message);
  }

  /// The party the user is in gets its chat [id], with [texts] (author id, text) said so far.
  Map<String, dynamic> partyChat(String id, {List<(String, String)> texts = const []}) {
    final messages = threads[id] = [
      for (var index = 0; index < texts.length; index++) _message(id, index + 1, texts[index].$1, texts[index].$2),
    ];
    party!['conversationId'] = id;
    return partyChats[id] = {
      'id': id,
      'kind': 'group',
      'title': null,
      'members': party!['members'],
      'lastSeq': messages.length,
      'readSeq': 0,
      'lastMessage': messages.isEmpty ? null : messages.last,
      'updatedAt': '2026-10-24T20:00:00Z',
      'pinned': false,
      'muted': true,
      'partyId': party!['id'],
    };
  }

  Map<String, dynamic> _party(List<Map<String, dynamic>> members, {String? leader}) => party = {
    'id': 'party-${++_ids}',
    'leaderId': leader ?? me['id'],
    'privacy': 'invite',
    'members': members,
    'invited': <Map<String, dynamic>>[],
    'call': null,
    'joinCode': null,
    'discord': null,
    'requests': <Map<String, dynamic>>[],
  };

  /// The user is in a party with [others].
  Map<String, dynamic> inParty(List<Map<String, dynamic>> others, {String? leader}) => _party([
    card(me['id'] as String, me['handle'] as String, me['displayName'] as String),
    ...others,
  ], leader: leader);

  /// Profiles by handle, with their library and trophies; a handle in [privateParts] keeps
  /// those parts (profile, library, trophies) from the user.
  final Map<String, Map<String, dynamic>> profiles = {};
  final Map<String, List<Map<String, dynamic>>> libraries = {};
  final Map<String, List<Map<String, dynamic>>> trophyLists = {};
  final Map<String, Set<String>> privateParts = {};

  /// Showcases by handle, the compared games by handle and one game compared by
  /// "handle/titleId"; `showcase` and `compare` in [privateParts] keep them from the user.
  final Map<String, Map<String, dynamic>> showcases = {};

  /// Recent activity by handle (`users/:handle/activity`); none answers 404, as an older server.
  final Map<String, List<Map<String, dynamic>>> activities = {};
  final Map<String, List<Map<String, dynamic>>> compareLists = {};
  final Map<String, Map<String, dynamic>> compareViews = {};

  /// The Theme Hub's published themes (cards as GET /themes sends them): a profile may wear one.
  final List<Map<String, dynamic>> hubThemes = [];

  /// PATCH /me/look with a theme: only a published one; putting it on clears the cover and
  /// accent unless they come too. The user's own profile answers with it after.
  (int, Object?) _look(Map<String, dynamic> body) {
    if (body.containsKey('theme')) {
      final id = body['theme'];
      if (id == null) {
        me['theme'] = null;
      } else {
        final theme = hubThemes.where((theme) => theme['id'] == id).firstOrNull;
        if (theme == null) return problem(400, 'bad_request', 'theme: no such theme in the Theme Hub');
        me['theme'] = {
          for (final key in const ['id', 'name', 'colors', 'preview', 'thumb', 'maker']) key: theme[key],
        };
        me['cover'] = null;
        me['accent'] = null;
      }
    }
    if (body.containsKey('accent')) me['accent'] = body['accent'];
    final own = profiles[me['handle']];
    if (own != null) {
      for (final key in const ['cover', 'accent', 'theme']) {
        own[key] = me[key];
      }
    }
    return (200, {'cover': me['cover'], 'accent': me['accent'], 'theme': me['theme']});
  }

  /// PUT /me/showcase: up to six pins, trophies and games together, from the user's own
  /// trophies and library; the showcase as the user sees it back.
  (int, Object?) _saveShowcase(Map<String, dynamic> body) {
    final trophies = [for (final pin in body['trophies'] as List<dynamic>? ?? const []) pin as Map<String, dynamic>];
    final games = [for (final id in body['games'] as List<dynamic>? ?? const []) id as String];
    if (trophies.length + games.length > 6) {
      return problem(400, 'bad_request', 'showcase: up to six pins, trophies and games together');
    }
    final handle = me['handle'] as String;
    // The user's earned trophies: the recent ones and any pinned before.
    final earned = [
      ...?trophyLists[handle],
      for (final trophy in showcases[handle]?['trophies'] as List<dynamic>? ?? const []) trophy as Map<String, dynamic>,
    ];
    final library = libraries[handle] ?? const [];
    return (
      200,
      showcases[handle] = {
        'trophies': [
          for (final pin in trophies)
            ...earned
                .where((trophy) => trophy['titleId'] == pin['titleId'] && trophy['trophyId'] == pin['trophyId'])
                .take(1),
        ],
        'games': [for (final id in games) ...library.where((game) => game['titleId'] == id)],
      },
    );
  }

  /// Game sessions by id, and the invites to the user.
  final Map<String, Map<String, dynamic>> gameSessions = {};
  final List<Map<String, dynamic>> gameInvites = [];

  /// A game session [host] runs; a `lan` one (Play Together) shows in the party the user is in.
  Map<String, dynamic> hostSession(
    String id,
    Map<String, dynamic> host, {
    String titleId = 'PPSA01001',
    String gameVersion = '01.000.000',
    String engineBuild = 'toolkit-1',
    String kind = 'online',
  }) => gameSessions[id] = _together({
    'id': id,
    'kind': kind,
    'partyId': kind == 'lan' ? (party?['id']) : null,
    'versionRule': 'exact',
    'host': host,
    'titleId': titleId,
    'gameVersion': gameVersion,
    'engineBuild': engineBuild,
    'capacity': 4,
    'joinable': true,
    'players': [host],
    'members': [
      {
        'userId': host['userId'],
        'device': 'device-host',
        'properties': {'address': 'relay:1'},
        'joinedAt': '2026-10-24T20:00:00Z',
        'updatedAt': null,
      },
    ],
    'properties': {'mode': 'coop'},
  });

  /// A Play Together session shows in the party's view as the server keeps it.
  Map<String, dynamic> _together(Map<String, dynamic> session) {
    if (session['kind'] == 'lan' && party != null) {
      party!['together'] = {
        'sessionId': session['id'],
        'hostId': (session['host'] as Map)['userId'],
        'titleId': session['titleId'],
        'gameVersion': session['gameVersion'],
        'engineBuild': session['engineBuild'],
        'versionRule': session['versionRule'] ?? 'exact',
        'players': [for (final player in session['players'] as List<dynamic>) (player as Map)['userId']],
        'capacity': session['capacity'],
        'startedAt': '2026-10-26T00:00:00Z',
      };
    }
    return session;
  }

  /// Handlers a test adds for its own paths: return null to fall through.
  final List<FutureOr<(int, Object?)?> Function(FakeCall call)> handlers = [];

  Future<void> close() async {
    // A socket that closes removes itself from the list, so walk a copy.
    for (final socket in [...sockets]) {
      await socket.close();
    }
    await _frameAdded.close();
    await _server.close(force: true);
  }

  /// Approves the device code shown on the website, or a hand-off the phone was asked about.
  void approveDevice() => _pending[lastDeviceCode!] = true;

  void approveHandoff([String? id]) {
    final secret = _handoffSecrets[id ?? lastHandoff];
    if (secret != null) _pending[secret] = true;
  }

  /// Calls to [path] (and [method]).
  List<FakeCall> callsTo(String path, {String? method}) =>
      calls.where((call) => call.path == path && (method == null || call.method == method)).toList();

  /// An event to every connected socket.
  void push(String type, Object? data, {String? id}) {
    final frame = jsonEncode({
      'op': 'event',
      'id': id ?? 'e-${DateTime.now().microsecondsSinceEpoch}',
      'type': type,
      'data': data,
    });
    for (final socket in sockets) {
      socket.add(frame);
    }
  }

  /// The next frame a socket sends with this op (and passing [test]).
  Future<Map<String, dynamic>> nextFrame(String op, {bool Function(Map<String, dynamic>)? test}) {
    for (final frame in frames) {
      if (frame['op'] == op && (test == null || test(frame))) {
        frames.remove(frame);
        return Future.value(frame);
      }
    }
    return _frameAdded.stream
        .firstWhere((frame) => frame['op'] == op && (test == null || test(frame)))
        .then((frame) {
          frames.remove(frame);
          return frame;
        })
        .timeout(const Duration(seconds: 5));
  }

  /// Closes every socket with [code] (4001 refused token, 4003 signed out elsewhere).
  Future<void> dropSockets([int code = 1001]) async {
    for (final socket in List.of(sockets)) {
      await socket.close(code);
    }
    sockets.clear();
  }

  Map<String, dynamic> _tokensFor() {
    _tokens++;
    final access = 'access-$_tokens';
    final refresh = 'refresh-$_tokens';
    validAccess.add(access);
    validRefresh.add(refresh);
    return {'accessToken': access, 'expiresIn': expiresIn, 'refreshToken': refresh, 'user': me};
  }

  Future<void> _serve(HttpRequest request) async {
    if (request.uri.path == '/rt' && WebSocketTransformer.isUpgradeRequest(request)) {
      final socket = await WebSocketTransformer.upgrade(request);
      _socket(socket);
      return;
    }
    final bytes = await request.fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));
    final file = files[request.uri.path];
    if (file != null && request.method == 'GET') {
      request.response.headers.contentType = ContentType.binary;
      request.response.add(file);
      await request.response.close();
      return;
    }
    // A picture going up is no JSON: its size stands for it.
    final isJson = request.headers.contentType == null || request.headers.contentType?.mimeType == 'application/json';
    final text = isJson ? utf8.decode(bytes) : '';
    final body = !isJson
        ? <String, dynamic>{'bytes': bytes.length}
        : text.isEmpty
        ? <String, dynamic>{}
        : (jsonDecode(text) as Map<String, dynamic>? ?? {});
    final prefix = '/api/v1/';
    final path = request.uri.path.startsWith(prefix)
        ? request.uri.path.substring(prefix.length) + (request.uri.hasQuery ? '?${request.uri.query}' : '')
        : request.uri.path;
    final call = FakeCall(request.method, path, body, request.headers, bytes: isJson ? const [] : bytes);
    calls.add(call);
    final (status, json) = await _route(call, request.headers.value(HttpHeaders.authorizationHeader));
    request.response.statusCode = status;
    if (json != null) {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(json));
    }
    await request.response.close();
  }

  static (int, Object?) problem(int status, String code, [String title = '']) =>
      (status, {'type': 'about:blank', 'status': status, 'code': code, 'title': title.isEmpty ? code : title});

  Future<(int, Object?)> _route(FakeCall call, String? authorization) async {
    final answer = answers['${call.method} ${call.path}'] ?? answers[call.path];
    if (answer != null) return answer;
    switch ((call.method, call.path)) {
      case ('POST', 'auth/email/start'):
        return (202, null);
      case ('POST', 'auth/email/verify'):
        return call.body['code'] == emailCode ? (200, _tokensFor()) : problem(400, 'code_invalid');
      case ('POST', 'auth/device'):
        lastDeviceCode = 'device-code-${_tokens}0000000000000000000000';
        _pending[lastDeviceCode!] = false;
        return (
          201,
          {
            'deviceCode': lastDeviceCode,
            'userCode': 'ABCD-EFGH',
            'verificationUri': '$base/link',
            'expiresIn': 600,
            'interval': 5,
          },
        );
      case ('POST', 'auth/handoff/start'):
        lastHandoff = 'handoff-${_handoffSecrets.length + 1}';
        final secret = 'secret-${_handoffSecrets.length + 1}';
        _handoffSecrets[lastHandoff!] = secret;
        _pending[secret] = false;
        return (201, {'handoffId': lastHandoff, 'secret': secret});
      case ('POST', 'auth/token'):
        switch (call.body['grantType']) {
          case 'refresh_token':
            final refresh = call.body['refreshToken'] as String?;
            if (!validRefresh.remove(refresh)) return problem(400, 'invalid_grant');
            return (200, _tokensFor());
          case 'device_code' || 'handoff':
            final secret = (call.body['deviceCode'] ?? call.body['secret']) as String?;
            final approved = _pending[secret];
            if (approved == null) return problem(400, 'expired_token');
            if (!approved) return problem(400, 'authorization_pending');
            _pending.remove(secret);
            return (200, _tokensFor());
        }
        return problem(400, 'bad_request');
    }
    for (final handler in handlers) {
      final handled = await handler(call);
      if (handled != null) return handled;
    }
    // Everything else needs a valid access token.
    final token = authorization?.replaceFirst('Bearer ', '');
    if (token == null || !validAccess.contains(token)) return problem(401, 'unauthorized');
    final handoffApprove = RegExp(r'^auth/handoff/([^/]+)/approve$').firstMatch(call.path);
    if (call.method == 'POST' && handoffApprove != null) {
      final secret = _handoffSecrets[handoffApprove.group(1)];
      if (secret == null) return problem(404, 'not_found');
      _pending[secret] = true;
      return (204, null);
    }
    switch ((call.method, call.path)) {
      case ('POST', 'auth/logout'):
        validAccess.remove(token);
        return (204, null);
      case ('GET', 'me'):
        return (
          200,
          {
            'account': {'id': me['id']},
            'profile': me,
          },
        );
      case ('PATCH', 'me/look'):
        return _look(call.body);
      // Your profile and who sees what, as AnyTogether's profile routes answer them.
      case ('PATCH', 'me/profile'):
        for (final key in const ['displayName', 'bio', 'country', 'privateName']) {
          if (call.body.containsKey(key)) me[key] = call.body[key];
        }
        return (200, me);
      case ('PATCH', 'me/handle'):
        final handle = call.body['handle'] as String? ?? '';
        if (!RegExp(r'^[a-z0-9_.]{3,20}$').hasMatch(handle)) return problem(400, 'bad_request');
        if (people.containsKey(handle)) return problem(409, 'handle_taken');
        if (me['handleChangeAt'] case final String at) {
          return (
            429,
            {'type': 'about:blank', 'status': 429, 'code': 'handle_cooldown', 'title': 'Not yet', 'handleChangeAt': at},
          );
        }
        me['handle'] = handle;
        me['handleChangeAt'] = DateTime.now().toUtc().add(const Duration(days: 30)).toIso8601String();
        return (200, me);
      case ('PATCH', 'me/privacy'):
        final privacy = me['privacy'] = {...?(me['privacy'] as Map<String, dynamic>?), ...call.body};
        return (200, privacy);
      case ('PUT', 'me/showcase'):
        return _saveShowcase(call.body);
      case ('GET', 'themes?sort=popular&limit=24'):
        return (200, {'themes': hubThemes, 'next': null});
      case ('PATCH', 'me/presence'):
        if (call.body['status'] case final String status when presenceStatuses) {
          if (!const ['online', 'idle', 'dnd', 'invisible'].contains(status)) return problem(400, 'bad_request');
          me['status'] = status;
          me['appearOffline'] = status == 'invisible';
          return (200, {'appearOffline': me['appearOffline'], 'status': status});
        }
        if (call.body['appearOffline'] is! bool) return problem(400, 'bad_request');
        me['appearOffline'] = call.body['appearOffline'];
        return (200, {'appearOffline': me['appearOffline']});
      case ('GET', 'me/friends'):
        return (200, {'friends': friends});
      case ('GET', 'me/friends/requests'):
        return (200, {'incoming': incoming, 'outgoing': outgoing});
      case ('POST', 'me/friends/requests'):
        final someone = people[call.body['handle']];
        if (someone == null) return problem(404, 'not_found', 'No such user');
        if (incoming.any((person) => person['userId'] == someone['userId'])) {
          incoming.removeWhere((person) => person['userId'] == someone['userId']);
          friends.add({
            ...someone,
            'presence': {'state': 'online'},
          });
          return (200, {'state': 'accepted'});
        }
        outgoing.add(someone);
        return (201, {'state': 'pending'});
    }
    switch ((call.method, call.path)) {
      case ('POST', 'me/devices'):
        devices[call.body['id'] as String] = call.body;
        return (201, call.body);
      case ('POST', 'me/sessions'):
        final items = call.body['sessions'] as List<dynamic>;
        return (
          200,
          {
            'results': [
              for (var index = 0; index < items.length; index++)
                () {
                  final item = items[index] as Map<String, dynamic>;
                  if (!devices.containsKey(item['deviceId'])) {
                    return {'index': index, 'status': 'rejected', 'code': 'unknown_device'};
                  }
                  final duplicate = playSessions.containsKey(item['id']);
                  playSessions[item['id'] as String] = item;
                  return {'index': index, 'status': duplicate ? 'duplicate' : 'stored'};
                }(),
            ],
          },
        );
      case ('POST', 'me/trophies'):
        final items = call.body['trophies'] as List<dynamic>;
        return (
          200,
          {
            'results': [
              for (var index = 0; index < items.length; index++)
                () {
                  final item = items[index] as Map<String, dynamic>;
                  if (!trophySets.containsKey('${item['titleId']}/${item['setHash']}')) {
                    return {'index': index, 'status': 'rejected', 'code': 'unknown_trophy'};
                  }
                  final key = '${item['titleId']}/${item['trophyId']}';
                  final duplicate = earned.containsKey(key);
                  earned[key] = item;
                  return {'index': index, 'status': duplicate ? 'duplicate' : 'stored'};
                }(),
            ],
          },
        );
    }
    switch ((call.method, call.path)) {
      case ('GET', 'me/conversations'):
        final list = [
          for (final conversation in conversations.values) {...conversation, 'unread': unreadIn(conversation)},
        ]..sort((a, b) => (b['pinned'] == true ? 1 : 0) - (a['pinned'] == true ? 1 : 0));
        return (200, {'conversations': list});
      case ('GET', 'me/conversations/unread'):
        var unread = 0;
        var having = 0;
        for (final conversation in conversations.values) {
          final count = unreadIn(conversation);
          unread += count;
          if (count > 0) having++;
        }
        return (200, {'conversations': having, 'messages': unread});
      case ('PATCH', 'me/read-receipts'):
        if (call.body['readReceipts'] is! bool) return problem(400, 'bad_request');
        me['readReceipts'] = call.body['readReceipts'];
        return (200, {'readReceipts': me['readReceipts']});
      case ('PATCH', 'me/public-profile'):
        if (call.body['publicProfile'] is! bool) return problem(400, 'bad_request');
        me['publicProfile'] = call.body['publicProfile'];
        return (200, {'publicProfile': me['publicProfile']});
      case ('POST', 'conversations') when call.body['group'] == true:
        // A group: always a new one, with its name when it has one.
        final members = [
          for (final id in call.body['members'] as List<dynamic>)
            people.values.firstWhere((person) => person['userId'] == id),
        ];
        final group = conversation('c-${++_ids}', members);
        group['kind'] = 'group';
        group['title'] = call.body['title'];
        return (201, group);
      case ('POST', 'conversations'):
        final other = (call.body['members'] as List<dynamic>).single as String;
        final existing = conversations.values.where(
          (conversation) =>
              conversation['kind'] == 'direct' &&
              (conversation['members'] as List<dynamic>).any((member) => (member as Map)['userId'] == other),
        );
        if (existing.isNotEmpty) return (200, existing.first);
        final person = people.values.firstWhere((person) => person['userId'] == other);
        return (201, conversation('c-${++_ids}', [person]));
      case ('GET', 'me/party'):
        return (200, {'party': party, 'invites': partyInvites});
      case ('POST', 'parties'):
        final created = inParty(const []);
        created['privacy'] = call.body['privacy'] ?? 'invite';
        return (201, created);
      case ('POST', 'calls'):
        final current = party;
        if (current == null || current['id'] != call.body['partyId']) return problem(404, 'not_found');
        final id = (current['call'] as Map<String, dynamic>?)?['id'] as String? ?? 'call-${++_ids}';
        current['call'] = {
          'id': id,
          'in': [...callPeers.keys, me['id']],
          'muted': <String>[],
        };
        return (
          201,
          {
            'call': {
              'id': id,
              'kind': 'party',
              'partyId': current['id'],
              'in': [
                for (final peer in callPeers.entries) {'userId': peer.key, 'device': peer.value, 'muted': false},
              ],
            },
            'iceServers': [
              {
                'urls': ['stun:stun.example.org:3478'],
              },
            ],
            'expiresAt': DateTime.now().add(const Duration(hours: 12)).toUtc().toIso8601String(),
          },
        );
      case ('GET', 'ice-servers'):
        return (200, {'iceServers': <Object>[], 'expiresAt': null});
    }
    final compare = RegExp(r'^users/([^/?]+)/trophies/compare(?:\?titleId=([A-Z0-9]+))?$').firstMatch(call.path);
    if (call.method == 'GET' && compare != null) {
      final handle = Uri.decodeComponent(compare.group(1)!);
      if (privateParts[handle]?.contains('compare') == true) {
        return (
          403,
          {
            'type': 'about:blank',
            'status': 403,
            'code': 'forbidden',
            'title': 'Trophies are private',
            'details': {'section': 'trophies'},
          },
        );
      }
      final titleId = compare.group(2);
      if (titleId == null) return (200, {'games': compareLists[handle] ?? const []});
      final view = compareViews['$handle/$titleId'];
      return view == null ? problem(404, 'not_found', 'No such game') : (200, view);
    }
    final activity = RegExp(r'^users/([^/?]+)/activity(\?.*)?$').firstMatch(call.path);
    if (call.method == 'GET' && activity != null) {
      final handle = Uri.decodeComponent(activity.group(1)!);
      final items = activities[handle];
      return items == null ? problem(404, 'not_found') : (200, {'items': items, 'next': null});
    }
    final user = RegExp(r'^users/([^/?]+)(/library|/trophies|/showcase)?$').firstMatch(call.path);
    if (call.method == 'GET' && user != null) {
      final handle = Uri.decodeComponent(user.group(1)!);
      final part = user.group(2)?.substring(1) ?? 'profile';
      if (privateParts[handle]?.contains(part) == true) return problem(403, 'private', 'Private');
      if (part == 'showcase') {
        final showcase = showcases[handle];
        return showcase == null ? problem(404, 'not_found') : (200, showcase);
      }
      final profile = profiles[handle];
      if (profile == null) return problem(404, 'not_found');
      return switch (part) {
        'library' => (200, {'games': libraries[handle] ?? const []}),
        'trophies' => (200, {'trophies': trophyLists[handle] ?? const []}),
        _ => (200, profile),
      };
    }
    final me_ = card(me['id'] as String, me['handle'] as String, me['displayName'] as String);
    switch ((call.method, call.path)) {
      case ('GET', 'me/game-session'):
        final mine = gameSessions.values
            .where(
              (session) => (session['players'] as List<dynamic>).any((player) => (player as Map)['userId'] == me['id']),
            )
            .firstOrNull;
        return (200, {'session': mine, 'invites': gameInvites});
      case ('POST', 'game-sessions'):
        final id = 'gs-${++_ids}';
        if (call.body['kind'] == 'lan' && party?['together'] != null) {
          return (409, {'status': 409, 'code': 'conflict', 'title': 'Your party is already playing together'});
        }
        return (
          201,
          gameSessions[id] = _together({
            'kind': 'online',
            'versionRule': 'exact',
            ...call.body,
            if (call.body['kind'] == 'lan') 'partyId': party?['id'],
            'id': id,
            'host': me_,
            'players': [me_],
            'members': [
              {
                'userId': me['id'],
                'device': null,
                'properties': <String, Object>{},
                'joinedAt': '2026-10-24T20:00:00Z',
                'updatedAt': null,
              },
            ],
            'properties': <String, Object>{},
          }),
        );
    }
    final gameSession = RegExp(r'^game-sessions/([^/?]+)(/[a-z]+)?(\?.*)?$').firstMatch(call.path);
    if (gameSession != null) {
      final id = gameSession.group(1)!;
      final session = gameSessions[id];
      if (session == null) return problem(404, 'not_found');
      switch ((call.method, gameSession.group(2))) {
        case ('GET', null):
          return (200, session);
        case ('PATCH', null):
          session.addAll(call.body);
          return (200, session);
        case ('DELETE', null):
          gameSessions.remove(id);
          if ((party?['together'] as Map?)?['sessionId'] == id) party!['together'] = null;
          return (204, null);
        case ('POST', '/join'):
          // Try anyway passes the game version, never the engine build.
          if (call.body['gameVersion'] != session['gameVersion'] && call.body['overrideVersion'] != true) {
            return (
              409,
              {
                'status': 409,
                'code': 'version_mismatch',
                'title': 'Not the same version',
                'reason': 'game_version',
                'expected': session['gameVersion'],
                'actual': call.body['gameVersion'],
                'update': 'you',
                'overridable': true,
              },
            );
          }
          if (call.body['engineBuild'] != session['engineBuild']) {
            return (
              409,
              {
                'status': 409,
                'code': 'version_mismatch',
                'title': 'Not the same engine',
                'reason': 'engine',
                'expected': session['engineBuild'],
                'actual': call.body['engineBuild'],
                'update': 'host',
                'overridable': false,
              },
            );
          }
          final players = session['players'] as List<dynamic>;
          if (players.length >= (session['capacity'] as int)) return problem(409, 'full', 'Full');
          players.add(me_);
          gameInvites.removeWhere((invite) => invite['sessionId'] == id);
          _together(session);
          return (200, session);
        case ('POST', '/leave'):
          (session['players'] as List<dynamic>).removeWhere((player) => (player as Map)['userId'] == me['id']);
          _together(session);
          return (204, null);
        case ('POST', '/code'):
          return (201, {'code': 'K7QM3XPA', 'url': '$base/join/K7QM3XPA', 'expiresAt': '2026-10-27T00:00:00Z'});
        case ('POST', '/invites' || '/decline'):
          gameInvites.removeWhere((invite) => invite['sessionId'] == id);
          return (204, null);
      }
    }
    final thread = RegExp(r'^conversations/([^/]+)/messages(\?.*)?$').firstMatch(call.path);
    if (thread != null) {
      final id = thread.group(1)!;
      final messages = threads[id];
      if (messages == null) return problem(404, 'not_found');
      if (call.method == 'GET') {
        // The newest [limit] before `before`, or the oldest after `after`; oldest first.
        final query = Uri.splitQueryString(thread.group(2)?.substring(1) ?? '');
        final limit = int.tryParse(query['limit'] ?? '') ?? 50;
        final before = int.tryParse(query['before'] ?? '');
        final after = int.tryParse(query['after'] ?? '');
        final matching = [
          for (final message in messages)
            if ((before == null || (message['seq'] as int) < before) &&
                (after == null || (message['seq'] as int) > after))
              message,
        ];
        final page = after != null
            ? matching.take(limit).toList()
            : matching.skip(max(0, matching.length - limit)).toList();
        return (200, {'messages': page, 'more': matching.length > page.length});
      }
      // A party's chat takes text only.
      if (partyChats.containsKey(id) && (call.body['attachments'] as List<dynamic>? ?? const []).isNotEmpty) {
        return problem(400, 'bad_request', "A party's chat takes text only");
      }
      final attachments = call.body['attachments'] as List<dynamic>? ?? const [];
      final text = call.body['text'] as String? ?? '';
      if (text.contains('blocked.example')) return problem(400, 'link_blocked', 'That link is blocked');
      final message = _message(
        id,
        messages.length + 1,
        me['id'] as String,
        text,
        id: call.body['clientId'] as String?,
        replyTo: call.body['replyTo'] as int?,
      );
      // A photo or clip sent as it is: the media the launcher uploaded, behind a link.
      if (attachments.isNotEmpty && call.body['text'] == null) {
        final media = (attachments.first as Map<String, dynamic>)['mediaId'] as String;
        message
          ..['text'] = null
          ..['kind'] = mediaKinds[media] ?? 'image'
          ..['attachments'] = [
            {'id': media, 'kind': mediaKinds[media] ?? 'image', 'url': '$base/media/$media.png', 'poster': null},
          ];
      }
      messages.add(message);
      (conversations[id] ?? partyChats[id])!
        ..['lastSeq'] = messages.length
        ..['readSeq'] = messages.length
        ..['lastMessage'] = message;
      return (201, message);
    }
    final one = RegExp(r'^conversations/([^/]+)/messages/(\d+)(/reactions/([a-z]+))?$').firstMatch(call.path);
    if (one != null) {
      final id = one.group(1)!;
      final seq = int.parse(one.group(2)!);
      final message = threads[id]?.where((m) => m['seq'] == seq).firstOrNull;
      if (message == null) return problem(404, 'not_found');
      final reaction = one.group(4);
      if (reaction != null) {
        if (!reactionOrder.contains(reaction)) return problem(400, 'bad_request');
        final who = (_reacted[message['id'] as String] ??= {})[reaction] ??= {};
        if (call.method == 'PUT') who.add(me['id'] as String);
        if (call.method == 'DELETE') who.remove(me['id']);
        message['reactions'] = _reactions(message['id'] as String);
        return (200, {'conversationId': id, 'seq': seq, 'reactions': message['reactions']});
      }
      if (message['authorId'] != me['id']) return problem(403, 'forbidden');
      if (call.method == 'PATCH') {
        if ((message['editCount'] as int) >= 20) return problem(409, 'edit_limit');
        message
          ..['text'] = call.body['text']
          ..['editedAt'] = '2026-10-24T21:00:00Z'
          ..['editCount'] = (message['editCount'] as int) + 1;
        return (200, message);
      }
      if (call.method == 'DELETE') {
        message
          ..['text'] = null
          ..['deletedAt'] = '2026-10-24T21:00:00Z'
          ..['reactions'] = <Map<String, dynamic>>[];
        return (204, null);
      }
    }
    final mark = RegExp(r'^conversations/([^/]+)/(delivered|pin|mute)$').firstMatch(call.path);
    if (mark != null) {
      final conversation = conversations[mark.group(1)];
      if (conversation == null) return problem(404, 'not_found');
      switch ((call.method, mark.group(2))) {
        case ('POST', 'delivered'):
          return (204, null);
        case ('PUT', 'pin'):
          final pinned = conversations.values.where((c) => c['pinned'] == true && c != conversation).length;
          if (call.body['pinned'] == true && pinned >= 5) return problem(409, 'full');
          conversation['pinned'] = call.body['pinned'];
          return (200, {...conversation, 'unread': unreadIn(conversation)});
        case ('PUT', 'mute'):
          conversation['muted'] = call.body['muted'];
          return (200, {...conversation, 'unread': unreadIn(conversation)});
      }
    }
    final read = RegExp(r'^conversations/([^/]+)/read$').firstMatch(call.path);
    if (call.method == 'POST' && read != null) {
      (conversations[read.group(1)] ?? partyChats[read.group(1)])?['readSeq'] = call.body['upToSeq'];
      return (204, null);
    }
    if (call.method == 'POST' && call.path == 'reports') {
      reports.add(call.body);
      return (201, {'id': 'report-${reports.length}'});
    }
    final partyCall = RegExp(r'^parties/([^/]+)(/[a-z]+)?$').firstMatch(call.path);
    if (partyCall != null) {
      final id = partyCall.group(1)!;
      switch ((call.method, partyCall.group(2))) {
        case ('POST', '/invites'):
          final invited = party!['invited'] as List<Map<String, dynamic>>;
          for (final userId in call.body['userIds'] as List<dynamic>) {
            invited.add(people.values.firstWhere((person) => person['userId'] == userId));
          }
          return (200, party);
        case ('POST', '/join'):
          final invite = partyInvites.where((invite) => invite['partyId'] == id).firstOrNull;
          if (invite == null) return problem(404, 'not_found');
          if (invite['full'] == true) return problem(409, 'full', 'The party is full');
          partyInvites.remove(invite);
          final from = invite['from'] as Map<String, dynamic>;
          final joined = inParty([from], leader: from['userId'] as String);
          joined['id'] = id;
          return (200, joined);
        case ('POST', '/decline'):
          partyInvites.removeWhere((invite) => invite['partyId'] == id);
          return (204, null);
        case ('POST', '/leave'):
          party = null;
          return (204, null);
        case ('POST', '/leader'):
          party!['leaderId'] = call.body['userId'];
          return (200, party);
        case ('POST', '/kick'):
          (party!['members'] as List<Map<String, dynamic>>).removeWhere(
            (member) => member['userId'] == call.body['userId'],
          );
          return (204, null);
        case ('PATCH', null):
          if (call.body.containsKey('privacy')) party!['privacy'] = call.body['privacy'];
          // Listed in public (Find Players) or taken off the list.
          if (call.body.containsKey('public')) party!['public'] = call.body['public'];
          if (call.body.containsKey('discord')) {
            final link = call.body['discord'] as String?;
            if (link != null && !RegExp(r'^https://(discord\.gg|(www\.)?discord\.com)/').hasMatch(link)) {
              return problem(400, 'bad_request', 'Invalid body');
            }
            party!['discord'] = link;
          }
          return (200, party);
        case ('POST', '/code'):
          final code = nextCodes.removeAt(0);
          final joinCode = party!['joinCode'] = {
            'code': code,
            'url': 'https://anytogether.net/join/$code',
            'expiresAt': '2026-10-26T20:00:00Z',
          };
          return (201, joinCode);
        case ('DELETE', '/code'):
          if (party?['joinCode'] == null) return problem(404, 'not_found');
          party!['joinCode'] = null;
          return (204, null);
      }
    }
    final request = RegExp(r'^parties/([^/]+)/requests/([^/]+)/(accept|decline)$').firstMatch(call.path);
    if (call.method == 'POST' && request != null) {
      final requests = party?['requests'] as List<dynamic>? ?? [];
      requests.removeWhere((person) => (person as Map)['userId'] == request.group(2));
      return (204, null);
    }
    final joinCode = RegExp(r'^join/([A-Z0-9]+)$').firstMatch(call.path);
    if (joinCode != null) {
      final preview = joinPreviews[joinCode.group(1)];
      if (preview == null) return problem(404, 'not_found');
      if (call.method == 'GET') return (200, preview);
      if (preview['state'] == 'member') return problem(409, 'conflict', 'Already a member');
      final again = preview['state'] == 'requested' || preview['state'] == 'invited';
      if (!again) preview['state'] = 'requested';
      return (again ? 200 : 201, {'kind': preview['kind'], 'id': preview['id'], 'state': preview['state']});
    }
    final callAction = RegExp(r'^calls/([^/]+)/(leave|mute)$').firstMatch(call.path);
    if (call.method == 'POST' && callAction != null) return (204, null);
    final teach = RegExp(r'^games/([A-Z]{4}[0-9]{5})$').firstMatch(call.path);
    if (call.method == 'PUT' && teach != null) {
      games[teach.group(1)!] = call.body;
      return (200, {'titleId': teach.group(1)});
    }
    final set = RegExp(r'^trophy-sets/([A-Z]{4}[0-9]{5})/([A-Za-z0-9._-]+)$').firstMatch(call.path);
    if (call.method == 'PUT' && set != null) {
      trophySets['${set.group(1)}/${set.group(2)}'] = call.body;
      return (200, {'stored': true});
    }
    final reply = RegExp(r'^me/friends/requests/([^/]+)/(accept|decline)$').firstMatch(call.path);
    if (call.method == 'POST' && reply != null) {
      final asking = incoming.where((person) => person['userId'] == reply.group(1)).firstOrNull;
      if (asking == null) return problem(404, 'not_found');
      incoming.remove(asking);
      if (reply.group(2) == 'accept') {
        friends.add({
          ...asking,
          'presence': {'state': 'online'},
        });
      }
      return (204, null);
    }
    final unfriend = RegExp(r'^me/friends/([^/]+)$').firstMatch(call.path);
    if (call.method == 'DELETE' && unfriend != null) {
      friends.removeWhere((friend) => friend['userId'] == unfriend.group(1));
      // A request sent and not answered yet is taken back the same way.
      outgoing.removeWhere((person) => person['userId'] == unfriend.group(1));
      return (204, null);
    }
    return problem(404, 'not_found', 'No route for ${call.method} ${call.path}');
  }

  void _socket(WebSocket socket) {
    sockets.add(socket);
    socket.listen((data) {
      if (data is! String) return;
      final frame = jsonDecode(data) as Map<String, dynamic>;
      if (_frameAdded.isClosed) return;
      if (frame['op'] == 'hello') {
        if (!validAccess.contains(frame['token'])) {
          socket.close(4001);
          return;
        }
        _sessions++;
        socket.add(jsonEncode({'op': 'ready', 'session': 'session-$_sessions', 'heartbeat': heartbeatSeconds}));
      }
      frames.add(frame);
      // A socket still talking while the server shuts down at the end of a test.
      if (!_frameAdded.isClosed) _frameAdded.add(frame);
    }, onDone: () => sockets.remove(socket));
  }
}
