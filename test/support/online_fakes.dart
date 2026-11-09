import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/online/online_bridge_server.dart';
import 'package:anyps5_desktop/core/online/online_peer.dart';
import 'package:anyps5_desktop/core/online/online_peer_mesh.dart';
import 'package:anyps5_desktop/core/online/online_wire.dart';
import 'package:anyps5_desktop/core/together/account.dart';

/// The engine's side of the bridge, as libSceNetCtl speaks it, for driving the launcher's side.
class FakeEngine {
  FakeEngine._(this._socket, this._inbox);

  final Socket _socket;
  final WireInbox _inbox;
  WireAccount? account;
  bool launcherProven = false;
  Uint8List? refusal;
  int _nextCall = 1;

  /// Connects and runs the handshake; with [expectRefusal] a refused engine is returned too
  /// (its [refusal] set), else null.
  static Future<FakeEngine?> connect(
    int port,
    List<int> secret, {
    int protocolVersion = OnlineWire.protocolVersion,
    String build = 'engine-test',
    bool expectRefusal = false,
  }) async {
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
    final engine = FakeEngine._(socket, WireInbox(socket));
    final nonce = OnlineWire.randomBytes(16);
    engine.write(
      OnlineWire.frame(
        WireKind.hello,
        WireHello(protocolVersion: protocolVersion, nonce: nonce, build: build, pid: 1).payload,
      ),
    );
    final welcome = await engine.readFrame();
    if (welcome == null) return null;
    if (welcome.header.kind == WireKind.refuse.value) {
      engine.refusal = welcome.payload;
      return expectRefusal ? engine : null;
    }
    if (welcome.header.kind != WireKind.welcome.value) return null;
    final reader = WireReader(welcome.payload)..u16();
    final launcherNonce = reader.raw(16);
    final proof = reader.raw(32);
    engine.launcherProven = OnlineWire.sameProof(proof, OnlineWire.proof(secret, Side.launcher, nonce, launcherNonce));
    engine.write(OnlineWire.frame(WireKind.proof, OnlineWire.proof(secret, Side.engine, nonce, launcherNonce)));
    final next = await engine.readFrame();
    if (next == null) return null;
    if (next.header.kind == WireKind.refuse.value) {
      engine.refusal = next.payload;
      return expectRefusal ? engine : null;
    }
    if (next.header.kind != WireKind.account.value) return null;
    engine.account = WireAccount.parse(next.payload);
    return engine;
  }

  /// From the environment a game is started with.
  static Future<FakeEngine?> fromEnvironment(Map<String, String> environment, {String build = 'engine-test'}) {
    final port = int.parse(environment['ANYPS5_ONLINE']!.split(':').last);
    return connect(port, OnlineWire.fromHex(environment['ANYPS5_ONLINE_SECRET']!)!, build: build);
  }

  int? get refusalReason => refusal == null ? null : WireReader(refusal!).u16();

  void write(List<int> data) => _socket.add(data);

  Future<WireFrame?> readFrame({Duration timeout = const Duration(seconds: 5)}) => _inbox.next(timeout: timeout);

  /// The next frame of [kind], taking account changes on the way.
  Future<WireFrame?> next(WireKind kind, {Duration timeout = const Duration(seconds: 5)}) async {
    while (true) {
      final frame = await readFrame(timeout: timeout);
      if (frame == null) return null;
      if (frame.header.kind == WireKind.account.value) account = WireAccount.parse(frame.payload);
      if (frame.header.kind == kind.value) return frame;
    }
  }

  Future<WireWebReply?> web(WireWebRequest request) async {
    final call = _nextCall++;
    write(OnlineWire.frame(WireKind.webRequest, request.payload, call: call));
    while (true) {
      final frame = await next(WireKind.webRequest);
      if (frame == null) return null;
      if (frame.header.call == call && frame.header.isReply) return WireWebReply.parse(frame.payload);
    }
  }

  void send(WireDatagram datagram) => write(OnlineWire.frame(WireKind.datagram, datagram.payload));

  void sendStream(WireStream frame) => write(frame.frame);

  /// The next stream frame, skipping datagrams and taking account changes on the way.
  Future<WireStream?> nextStream({Duration timeout = const Duration(seconds: 5)}) async {
    while (true) {
      final frame = await readFrame(timeout: timeout);
      if (frame == null) return null;
      if (frame.header.kind == WireKind.account.value) account = WireAccount.parse(frame.payload);
      final kind = WireKind.of(frame.header.kind);
      if (kind != null && kind.isStream) return WireStream.parse(kind, frame.payload);
    }
  }

  Future<WireDatagram?> nextDatagram({Duration timeout = const Duration(seconds: 5)}) async {
    final frame = await next(WireKind.datagram, timeout: timeout);
    return frame == null ? null : WireDatagram.parse(frame.payload);
  }

  Future<WirePushEvent?> nextPushEvent() async {
    final frame = await next(WireKind.pushEvent);
    return frame == null ? null : WirePushEvent.parse(frame.payload);
  }

  Future<WireAccount?> nextAccount() async {
    final frame = await next(WireKind.account);
    return frame == null ? null : account;
  }

  /// Reads until the account has [address] (it may have come already).
  Future<bool> addressSoon(int address) async {
    while (account?.address != address) {
      if (await nextAccount() == null) return false;
    }
    return true;
  }

  void observe(String line) => write(OnlineWire.frame(WireKind.observation, (WireWriter()..str(line)).data));

  Future<void> close() async {
    await _inbox.cancel();
    _socket.destroy();
  }
}

/// AnyTogether as the online pieces ask it: friends, game sessions and member publishing, with
/// every call written down.
class FakeOnlineTogether {
  FakeOnlineTogether({List<(String, String, String)> friends = const [], this.session, this.answer}) {
    setFriends(friends);
  }

  List<Map<String, dynamic>> friends = [];
  Map<String, dynamic>? session;

  /// What every call answers instead, when set (game sessions for the router's tests).
  Map<String, dynamic>? answer;
  TogetherProblem? failure;
  final calls = <(String, String, Map<String, dynamic>?)>[];

  void setFriends(List<(String, String, String)> list) => friends = [
    for (final (id, handle, state) in list)
      {
        'userId': id,
        'handle': handle,
        'displayName': handle,
        'avatar': null,
        'presence': {'state': state, 'titleId': null, 'since': null},
      },
  ];

  Future<Map<String, dynamic>> call(String method, String path, [Map<String, dynamic>? body]) async {
    calls.add((method, path, body == null ? null : jsonDecode(jsonEncode(body)) as Map<String, dynamic>));
    final failure = this.failure;
    if (failure != null) throw failure;
    final answer = this.answer;
    if (answer != null) return answer;
    if (path == 'me/friends') return {'friends': friends};
    final session = this.session;
    if (path.startsWith('game-sessions/') && session != null) return session;
    throw const TogetherProblem(404, 'not_found', 'Not found');
  }

  static Map<String, dynamic> sessionJson({
    required String id,
    required List<String> players,
    Map<String, String> devices = const {},
    String titleId = 'PPSA00000',
  }) => {
    'id': id,
    'titleId': titleId,
    'gameVersion': '01.000',
    'engineBuild': 'engine-test',
    'capacity': 4,
    'joinable': true,
    'host': {'userId': players.first, 'handle': players.first, 'displayName': players.first, 'avatar': null},
    'players': [
      for (final player in players) {'userId': player, 'handle': player, 'displayName': player, 'avatar': null},
    ],
    'members': [
      for (final player in players)
        {
          'userId': player,
          'device': devices[player],
          'properties': {},
          'joinedAt': '2026-10-25T10:00:00Z',
          'updatedAt': null,
        },
    ],
    'properties': {},
    'createdAt': '2026-10-25T10:00:00Z',
    'endedAt': null,
  };
}

/// Waits until [condition] holds (polling), false after [timeout].
Future<bool> eventually(bool Function() condition, {Duration timeout = const Duration(seconds: 5)}) async {
  final end = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(end)) return false;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return true;
}

/// Peer connections in one process: two links that set each other's descriptions connect, and
/// a message sent on one arrives on the other a moment later. Candidates are made up and checked
/// for arriving at the right link.
class FakeGameNetwork {
  /// What every link's statistics answer; null throws, as a platform without statistics may.
  List<GameLinkStat>? stats = const [];

  final _links = <String, FakeGameLink>{};
  int _next = 0;

  /// What the links were made with (the ICE servers each time).
  final made = <List<Map<String, dynamic>>>[];

  /// Messages dropped on the way (as an unreliable channel may), per sender; tests set it.
  bool Function(Uint8List data)? lose;

  GameLinks get links => _FakeLinks(this);

  List<FakeGameLink> get all => _links.values.toList();

  FakeGameLink _make(List<Map<String, dynamic>> servers) {
    made.add(servers);
    final link = FakeGameLink._(this, 'link-${_next++}');
    _links[link.id] = link;
    return link;
  }
}

class _FakeLinks implements GameLinks {
  _FakeLinks(this.network);
  final FakeGameNetwork network;

  @override
  Future<GameLink> link(List<Map<String, dynamic>> iceServers) async => network._make(iceServers);
}

class FakeGameLink implements GameLink {
  FakeGameLink._(this.network, this.id);

  final FakeGameNetwork network;
  final String id;
  String? _remote;
  bool _local = false;
  bool _channel = false;
  bool _wantsChannel = false;
  bool closed = false;
  String state = 'new';
  final candidatesIn = <Map<String, dynamic>>[];
  void Function(Map<String, dynamic>)? _onCandidate;
  void Function(Uint8List)? _onMessage;
  void Function(Uint8List)? _onStreamMessage;
  void Function(String)? _onState;

  @override
  Future<List<GameLinkStat>> stats() async {
    final answer = network.stats;
    if (answer == null) throw StateError('no statistics');
    return answer;
  }

  /// Messages sent on the stream channel (reliable: never lost).
  int streamMessages = 0;

  FakeGameLink? get partner => _remote == null ? null : network._links[_remote];

  @override
  Future<Map<String, dynamic>> createOffer() async => {
    'type': 'offer',
    'sdp': 'fake $id${_wantsChannel ? ' channel' : ''}',
  };

  @override
  Future<Map<String, dynamic>> createAnswer() async => {'type': 'answer', 'sdp': 'fake $id'};

  @override
  Future<void> setLocal(Map<String, dynamic> description) async {
    _local = true;
    scheduleMicrotask(() => _onCandidate?.call({'candidate': 'candidate:$id', 'sdpMid': '0', 'sdpMLineIndex': 0}));
    _maybeConnect();
  }

  @override
  Future<void> setRemote(Map<String, dynamic> description) async {
    final sdp = description['sdp'] as String;
    _remote = sdp.split(' ')[1];
    if (sdp.endsWith(' channel')) _wantsChannel = true;
    _maybeConnect();
  }

  @override
  Future<void> addCandidate(Map<String, dynamic> candidate) async {
    if (_remote == null) throw StateError('a candidate before the description');
    candidatesIn.add(candidate);
  }

  @override
  Future<void> openChannel() async => _wantsChannel = true;

  void _maybeConnect() {
    final other = partner;
    if (!_local || other == null || !other._local || other._remote != id || closed || other.closed) return;
    Timer(const Duration(milliseconds: 5), () {
      for (final link in [this, other]) {
        if (link.closed) continue;
        link.state = 'connected';
        link._onState?.call('connected');
        if (_wantsChannel || other._wantsChannel) link._channel = true;
      }
    });
  }

  @override
  bool send(Uint8List data) {
    final other = partner;
    if (!_channel || closed || other == null || other.closed) return false;
    if (network.lose?.call(data) ?? false) return true;
    final copy = Uint8List.fromList(data);
    Timer.run(() {
      if (!other.closed) other._onMessage?.call(copy);
    });
    return true;
  }

  @override
  bool get streamOpen => _channel && !closed;

  @override
  bool sendStream(Uint8List data) {
    final other = partner;
    if (!_channel || closed || other == null || other.closed) return false;
    streamMessages++;
    final copy = Uint8List.fromList(data);
    Timer.run(() {
      if (!other.closed) other._onStreamMessage?.call(copy);
    });
    return true;
  }

  @override
  set onStreamMessage(void Function(Uint8List data) handler) => _onStreamMessage = handler;

  @override
  set onCandidate(void Function(Map<String, dynamic> candidate) handler) => _onCandidate = handler;

  @override
  set onMessage(void Function(Uint8List data) handler) => _onMessage = handler;

  @override
  set onState(void Function(String state) handler) => _onState = handler;

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    _channel = false;
    state = 'closed';
    final other = partner;
    if (other != null && !other.closed && other._remote == id) {
      other._channel = false;
      other.state = 'disconnected';
      other._onState?.call('disconnected');
    }
  }
}

/// AnyTogether for one game session: every player sees the same session with everyone's device;
/// the gateway hands each signal to the launcher it is for, as `game_session.signal`.
class OneSession {
  final id = '0190a0b1-0000-7000-8000-0000000000aa';
  final players = <(String, String)>[];
  final _receivers = <String, void Function(OnlinePeerSignal signal, String sessionId)>{};
  final signals = <String>[];

  void add(String userId, String device) => players.add((userId, device));

  void attach(String userId, void Function(OnlinePeerSignal signal, String sessionId) receive) =>
      _receivers[userId] = receive;

  Map<String, dynamic> get json => FakeOnlineTogether.sessionJson(
    id: id,
    players: [for (final (user, _) in players) user],
    devices: {for (final (user, device) in players) user: device},
  );

  Future<Map<String, dynamic>> call(String method, String path, [Map<String, dynamic>? body]) async {
    if (path.endsWith('/ice-servers')) {
      return {
        'iceServers': [
          {
            'urls': ['turn:relay.example:3478'],
            'username': 'u',
            'credential': 'c',
          },
        ],
        'expiresAt': null,
      };
    }
    return json;
  }

  /// The gateway, for signals from [from] on [fromDevice].
  OnlineSignal relay(String from, String fromDevice) => (to, device, session, kind, data) {
    signals.add('$from>$to $kind');
    if (!players.any((player) => player.$1 == to && player.$2 == device)) return;
    final receive = _receivers[to];
    // The gateway sends JSON: what arrives is decoded again.
    final decoded = jsonDecode(jsonEncode(data));
    Timer.run(
      () => receive?.call(OnlinePeerSignal(from: from, device: fromDevice, kind: kind, data: decoded), session),
    );
  };
}
