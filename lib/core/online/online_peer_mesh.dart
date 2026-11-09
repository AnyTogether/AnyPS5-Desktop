import 'dart:async';
import 'dart:typed_data';

import 'online_identity.dart';
import 'online_peer.dart';
import 'online_wire.dart';

/// One peer connection with its game channel, as the mesh needs it; flutter_webrtc makes real
/// ones (lib/ui/online_webrtc.dart), tests make fakes. Descriptions and candidates are JSON as a
/// browser's toJSON() gives them.
abstract class GameLink {
  Future<Map<String, dynamic>> createOffer();
  Future<Map<String, dynamic>> createAnswer();
  Future<void> setLocal(Map<String, dynamic> description);
  Future<void> setRemote(Map<String, dynamic> description);
  Future<void> addCandidate(Map<String, dynamic> candidate);

  /// The offerer opens the channels (`game`: unordered, no resends; `stream`: reliable and
  /// ordered) before its offer; the answerer gets them from the other side.
  Future<void> openChannel();

  /// Sends one message on the game channel; false while it is not open.
  bool send(Uint8List data);

  /// Sends one message on the stream channel; false while it is not open.
  bool sendStream(Uint8List data);

  /// Whether the stream channel is open.
  bool get streamOpen;

  set onStreamMessage(void Function(Uint8List data) handler);

  set onCandidate(void Function(Map<String, dynamic> candidate) handler);
  set onMessage(void Function(Uint8List data) handler);

  /// The connection's state as the W3C names it: new, connecting, connected, disconnected, failed,
  /// closed.
  set onState(void Function(String state) handler);

  /// The connection's statistics as W3C reports (their `type` and values as text). Empty, or
  /// throwing, when the platform gives none: the launcher then says only what it knows.
  Future<List<GameLinkStat>> stats();

  Future<void> close();
}

/// One entry of a connection's statistics.
class GameLinkStat {
  const GameLinkStat(this.id, this.type, this.values);

  final String id;
  final String type;
  final Map<String, String> values;
}

/// How another player is reached: straight (host or STUN candidates), through a TURN relay, up
/// without the statistics saying how ([connected]), still coming up, or not at all.
enum PeerRoute { connecting, connected, direct, relay, failed }

/// A route and, once there is one, the round trip in milliseconds.
class PeerPath {
  const PeerPath(this.route, [this.rttMs]);

  final PeerRoute route;
  final int? rttMs;

  /// The route a statistics report shows: the transport's selected candidate pair (or the
  /// nominated pair that succeeded), relayed when either end is a relay candidate. Without those
  /// entries, as with empty statistics, it stays [PeerRoute.connected]: nothing is guessed.
  static PeerPath of(List<GameLinkStat> stats) {
    final byId = {for (final entry in stats) entry.id: entry};
    final selectedId = stats.where((entry) => entry.type == 'transport').firstOrNull?.values['selectedCandidatePairId'];
    final pair =
        (selectedId == null ? null : byId[selectedId]) ??
        stats
            .where(
              (entry) =>
                  entry.type == 'candidate-pair' &&
                  entry.values['state'] == 'succeeded' &&
                  const {'1', 'true', 'YES'}.contains(entry.values['nominated']),
            )
            .firstOrNull;
    if (pair == null) return const PeerPath(PeerRoute.connected);
    final ends = [pair.values['localCandidateId'], pair.values['remoteCandidateId']];
    final types = [for (final id in ends) byId[id]?.values['candidateType']];
    final rtt = double.tryParse(pair.values['currentRoundTripTime'] ?? '');
    final millis = rtt == null ? null : (rtt * 1000).round();
    if (types.contains('relay')) return PeerPath(PeerRoute.relay, millis);
    if (types.contains(null)) return const PeerPath(PeerRoute.connected);
    return PeerPath(PeerRoute.direct, millis);
  }
}

/// Makes peer connections with the session's STUN and TURN servers.
abstract class GameLinks {
  Future<GameLink> link(List<Map<String, dynamic>> iceServers);
}

enum PeerState { connecting, connected, failed, closed }

class _Peer {
  _Peer(this.userId, this.address, this.device, {required this.offerer, required this.link});

  final String userId;
  final int address;
  final String device;
  final bool offerer;
  final GameLink link;

  /// Candidates wait until the other side's description is set.
  final queued = <Map<String, dynamic>>[];
  bool haveRemote = false;
  bool closed = false;
  PeerState state = PeerState.connecting;

  /// The offer or answer this side sent, the offer the other side sent (for an answerer), and
  /// this side's candidates so far: what is sent again when a signal crossed another.
  Map<String, dynamic>? local;
  String? remoteOffer;
  String? remoteAnswer;
  final sentCandidates = <Map<String, dynamic>>[];
}

/// Game packets between the players of an AnyTogether game session over WebRTC data channels: one
/// peer connection to each other player, the offers, answers and ICE candidates carried as
/// `game_session.signal` through the realtime gateway, STUN and TURN from the session's ICE
/// servers (`GET /game-sessions/:id/ice-servers`). The player with the smaller user ID offers, so
/// two launchers never offer at once; a player who comes in later asks the others for an offer
/// ("renegotiate"), in case theirs went out before it was listening. The Mac launcher's
/// OnlinePeerMesh, the same messages, so a Mac and a PC play together.
///
/// One unordered channel without resends (`game`) carries datagrams: a 9-byte header (source port,
/// source virtual port, destination port, destination virtual port, kind; little-endian) and the
/// game's bytes. The sender's virtual address is not in the packet: it is the address of whoever
/// the connection is with, so nobody can speak for another player. A datagram to a broadcast or
/// multicast address goes to every other player; one bigger than UDP allows is dropped and
/// counted. A second, reliable and ordered channel (`stream`) carries the game's streams as
/// `OnlineStreamRelay` messages.
class OnlinePeerMesh implements OnlinePeerTransport {
  /// [iceServers] replaces asking AnyTogether for them (tests pass [] for host candidates only).
  OnlinePeerMesh({required this.context, required this.links, List<Map<String, dynamic>>? iceServers})
    : _fixedIceServers = iceServers;

  static const label = 'game';
  static const streamLabel = 'stream';
  static const headerSize = 9;

  final OnlinePeerContext context;
  final GameLinks links;
  final List<Map<String, dynamic>>? _fixedIceServers;

  OnlinePeerSession? _session;
  final _peers = <String, _Peer>{};
  final _byAddress = <int, _Peer>{};
  ({String session, List<Map<String, dynamic>> servers})? _iceServers;
  bool _stopped = false;
  Future<void> _queue = Future.value();

  /// Candidates that came before the offer they belong to (the signals of one connection may
  /// overtake each other), by user and device; handed to the connection the offer makes.
  final _early = <String, List<Map<String, dynamic>>>{};

  int _sent = 0;
  int _received = 0;
  int _dropped = 0;
  int _tooLarge = 0;

  /// Each player's connection, by user ID.
  Map<String, PeerState> get states => {for (final entry in _peers.entries) entry.key: entry.value.state};

  /// How each other player is reached now, by user ID.
  Future<Map<String, PeerPath>> paths() async {
    final peers = _peers.entries.toList();
    final paths = await Future.wait([for (final entry in peers) _path(entry.value)]);
    return {for (var index = 0; index < peers.length; index++) peers[index].key: paths[index]};
  }

  Future<PeerPath> _path(_Peer peer) async {
    return switch (peer.state) {
      PeerState.failed || PeerState.closed => const PeerPath(PeerRoute.failed),
      PeerState.connecting => const PeerPath(PeerRoute.connecting),
      PeerState.connected => await () async {
        try {
          return PeerPath.of(await peer.link.stats());
        } on Object {
          return const PeerPath(PeerRoute.connected);
        }
      }(),
    };
  }

  /// Datagrams sent, received and dropped (no open channel to their player, or too large) so far.
  /// A broadcast counts once for each player it goes to.
  ({int sent, int received, int dropped}) get traffic => (sent: _sent, received: _received, dropped: _dropped);

  /// Datagrams dropped because they were larger than a UDP datagram can be.
  int get droppedTooLarge => _tooLarge;

  /// One negotiation step at a time, in the order the signals came.
  Future<void> _serial(Future<void> Function() step) {
    final next = _queue.then((_) => _stopped ? null : step());
    _queue = next.catchError((Object _) {});
    return _queue;
  }

  @override
  void update(OnlinePeerSession? next) {
    if (_stopped) return;
    final previous = _session;
    _session = next;
    final gone = <_Peer>[];
    if (next == null || next.id != previous?.id) {
      gone.addAll(_peers.values);
      _peers.clear();
      _byAddress.clear();
      _early.clear();
    }
    final wanted = <(String, int, String)>[];
    final askOffer = <(String, String)>[];
    if (next != null) {
      for (final entry in _peers.entries.toList()) {
        final peer = entry.value;
        final device = next.devices[entry.key];
        // Gone from the session, or their launcher started again.
        if (next.addresses[entry.key] != peer.address || (device != null && device != peer.device)) {
          gone.add(peer);
          _peers.remove(entry.key);
          if (identical(_byAddress[peer.address], peer)) _byAddress.remove(peer.address);
        }
      }
      for (final entry in next.addresses.entries) {
        final userId = entry.key;
        if (userId == next.me || _peers.containsKey(userId)) continue;
        final device = next.devices[userId];
        if (device == null) continue;
        if (OnlineIdentity.before(next.me, userId)) {
          wanted.add((userId, entry.value, device));
        } else if (previous?.devices[userId] != device || previous?.id != next.id) {
          askOffer.add((userId, device));
        }
      }
    }
    // Leaving the session (or for another) says goodbye to everyone in it; a player who left or
    // whose launcher started again needs none.
    final leaving = previous != null && (next == null || next.id != previous.id);
    for (final peer in gone) {
      _close(peer, sayBye: leaving, sessionId: previous?.id);
    }
    if (next == null) return;
    for (final (userId, device) in askOffer) {
      context.signal(userId, device, next.id, 'renegotiate', null);
    }
    for (final (userId, address, device) in wanted) {
      unawaited(_serial(() => _offer(userId, address, device, next.id)));
    }
  }

  @override
  bool send(WireDatagram datagram) {
    if (datagram.data.length > OnlineWire.maxGameDatagram) {
      _tooLarge++;
      _dropped++;
      return false;
    }
    final targets = OnlineWire.isGroup(datagram.peer) ? _byAddress.values.toList() : [?_byAddress[datagram.peer]];
    if (targets.isEmpty) {
      _dropped++;
      return false;
    }
    final packet = Uint8List(headerSize + datagram.data.length);
    final view = ByteData.sublistView(packet)
      ..setUint16(0, datagram.localPort, Endian.little)
      ..setUint16(2, datagram.localVport, Endian.little)
      ..setUint16(4, datagram.peerPort, Endian.little)
      ..setUint16(6, datagram.peerVport, Endian.little)
      ..setUint8(8, datagram.kind.value);
    assert(view.lengthInBytes == packet.length);
    packet.setRange(headerSize, packet.length, datagram.data);
    var sent = 0;
    for (final peer in targets) {
      if (!peer.closed && peer.link.send(packet)) {
        sent++;
      } else {
        _dropped++;
      }
    }
    _sent += sent;
    return sent > 0;
  }

  @override
  bool sendStream(int peer, Uint8List message) {
    final target = _byAddress[peer];
    return target != null && !target.closed && target.link.sendStream(message);
  }

  /// Whether the reliable channel to the player at a virtual address is open.
  bool canStream(int peer) {
    final target = _byAddress[peer];
    return target != null && !target.closed && target.link.streamOpen;
  }

  @override
  void receive(OnlinePeerSignal signal) {
    final session = _session;
    if (_stopped || session == null || signal.from == session.me) return;
    final address = session.addresses[signal.from];
    if (address == null) return;
    unawaited(_serial(() => _signal(signal, session, address)));
  }

  Future<void> _signal(OnlinePeerSignal signal, OnlinePeerSession session, int address) async {
    if (_session?.id != session.id) return;
    final peer = _peers[signal.from];
    final data = signal.data is Map ? Map<String, dynamic>.from(signal.data as Map) : const <String, dynamic>{};
    switch (signal.kind) {
      case 'offer':
        final sdp = data['sdp'];
        if (sdp is! String) return;
        await _answer(signal.from, address, signal.device, sdp, session);
      case 'answer':
        final sdp = data['sdp'];
        if (sdp is! String || peer == null || !peer.offerer) return;
        if (peer.haveRemote) {
          // The same answer again (sent again after a crossed request) changes nothing. Another
          // one means the other side started its connection over (the Mac launcher does when an
          // offer comes twice): so does this side, with a new offer it will answer once.
          if (sdp == peer.remoteAnswer) return;
          _forget(peer);
          _close(peer, sayBye: false);
          await _offer(peer.userId, peer.address, peer.device, session.id);
          return;
        }
        try {
          peer.remoteAnswer = sdp;
          await peer.link.setRemote({'type': 'answer', 'sdp': sdp});
          await _flush(peer);
        } on Object {
          peer.state = PeerState.failed;
        }
      case 'candidate':
        if (data['candidate'] is! String) return;
        if (peer == null || peer.device != signal.device) {
          final early = _early.putIfAbsent('${signal.from} ${signal.device}', () => []);
          if (early.length < 64) early.add(data);
          return;
        }
        if (!peer.haveRemote) {
          peer.queued.add(data);
        } else {
          await peer.link.addCandidate(data).catchError((Object _) {});
        }
      case 'bye':
        _early.remove('${signal.from} ${signal.device}');
        if (peer == null) return;
        _forget(peer);
        _close(peer, sayBye: false);
      case 'renegotiate':
        // They are listening now: whoever offers offers again. An offer still unanswered is sent
        // again as it was, with its candidates, rather than started over: the request may have
        // crossed it, and a second connection would take candidates meant for the first.
        if (!OnlineIdentity.before(session.me, signal.from)) return;
        final local = peer?.local;
        if (peer != null && peer.device == signal.device && !peer.haveRemote && local != null) {
          _send(peer, 'offer', local);
          for (final candidate in peer.sentCandidates) {
            _send(peer, 'candidate', candidate);
          }
          return;
        }
        if (peer != null) {
          _forget(peer);
          _close(peer, sayBye: false);
        }
        await _offer(signal.from, address, signal.device, session.id);
    }
  }

  @override
  void stop() {
    if (_stopped) return;
    _stopped = true;
    final sessionId = _session?.id;
    for (final peer in _peers.values.toList()) {
      _close(peer, sayBye: true, sessionId: sessionId);
    }
    _peers.clear();
    _byAddress.clear();
    _early.clear();
  }

  // Negotiation.

  Future<List<Map<String, dynamic>>> _servers(String sessionId) async {
    final fixed = _fixedIceServers;
    if (fixed != null) return fixed;
    final kept = _iceServers;
    if (kept != null && kept.session == sessionId) return kept.servers;
    var servers = <Map<String, dynamic>>[];
    try {
      final json = await context.call('GET', 'game-sessions/$sessionId/ice-servers');
      servers = [
        for (final server in json['iceServers'] as List<dynamic>? ?? const [])
          if (server is Map) Map<String, dynamic>.from(server),
      ];
    } on Object {
      // Host candidates only, then.
    }
    _iceServers = (session: sessionId, servers: servers);
    return servers;
  }

  Future<_Peer?> _make(
    String userId,
    int address,
    String device, {
    required bool offerer,
    required String sessionId,
  }) async {
    final servers = await _servers(sessionId);
    final GameLink link;
    try {
      link = await links.link(servers);
    } on Object {
      return null;
    }
    final peer = _Peer(userId, address, device, offerer: offerer, link: link);
    link
      ..onCandidate = (candidate) {
        if (peer.closed) return;
        if (peer.sentCandidates.length < 64) peer.sentCandidates.add(candidate);
        _send(peer, 'candidate', candidate);
      }
      ..onState = (state) {
        if (peer.closed) return;
        switch (state) {
          case 'connected':
            peer.state = PeerState.connected;
          case 'failed':
            peer.state = PeerState.failed;
          case 'closed':
            peer.state = PeerState.closed;
        }
        if ((state == 'failed' || state == 'closed') && identical(_byAddress[peer.address], peer)) {
          context.peerGone?.call(peer.address);
        }
      }
      ..onMessage = ((data) => _deliver(data, peer))
      ..onStreamMessage = (data) {
        if (peer.closed || !identical(_byAddress[peer.address], peer)) return;
        context.deliverStream?.call(peer.address, data);
      };
    return peer;
  }

  Future<void> _offer(String userId, int address, String device, String sessionId) async {
    if (_session?.id != sessionId || _peers.containsKey(userId)) return;
    final peer = await _make(userId, address, device, offerer: true, sessionId: sessionId);
    if (peer == null) return;
    if (_stopped || _session?.id != sessionId || _peers.containsKey(userId)) {
      peer.closed = true;
      await peer.link.close();
      return;
    }
    _peers[userId] = peer;
    _byAddress[address] = peer;
    try {
      await peer.link.openChannel();
      final offer = await peer.link.createOffer();
      await peer.link.setLocal(offer);
      peer.local = {'type': 'offer', 'sdp': offer['sdp']};
      _send(peer, 'offer', peer.local);
    } on Object {
      peer.state = PeerState.failed;
    }
  }

  Future<void> _answer(String userId, int address, String device, String sdp, OnlinePeerSession session) async {
    // The same offer again (sent again after a crossed request): the same answer again.
    final current = _peers[userId];
    final answered = current?.local;
    if (current != null && current.device == device && current.remoteOffer == sdp && answered != null) {
      _send(current, 'answer', answered);
      return;
    }
    final peer = await _make(userId, address, device, offerer: false, sessionId: session.id);
    if (peer == null) return;
    if (_stopped || _session?.id != session.id) {
      peer.closed = true;
      await peer.link.close();
      return;
    }
    final old = _peers[userId];
    _peers[userId] = peer;
    _byAddress[address] = peer;
    if (old != null) _close(old, sayBye: false);
    peer
      ..queued.addAll(_early.remove('$userId $device') ?? const [])
      ..remoteOffer = sdp;
    try {
      await peer.link.setRemote({'type': 'offer', 'sdp': sdp});
      await _flush(peer);
      final answer = await peer.link.createAnswer();
      await peer.link.setLocal(answer);
      peer.local = {'type': 'answer', 'sdp': answer['sdp']};
      _send(peer, 'answer', peer.local);
    } on Object {
      peer.state = PeerState.failed;
    }
  }

  Future<void> _flush(_Peer peer) async {
    peer.haveRemote = true;
    final queued = [...peer.queued];
    peer.queued.clear();
    for (final candidate in queued) {
      await peer.link.addCandidate(candidate).catchError((Object _) {});
    }
  }

  void _send(_Peer peer, String kind, Object? data) {
    final sessionId = _session?.id;
    if (sessionId == null) return;
    context.signal(peer.userId, peer.device, sessionId, kind, data);
  }

  void _deliver(Uint8List data, _Peer peer) {
    if (data.length < headerSize || peer.closed || !identical(_byAddress[peer.address], peer)) return;
    final view = ByteData.sublistView(data);
    final kind = DatagramKind.of(view.getUint8(8));
    if (kind == null) return;
    _received++;
    context.deliver(
      WireDatagram(
        peer: peer.address,
        peerPort: view.getUint16(0, Endian.little),
        peerVport: view.getUint16(2, Endian.little),
        localPort: view.getUint16(4, Endian.little),
        localVport: view.getUint16(6, Endian.little),
        kind: kind,
        data: Uint8List.sublistView(data, headerSize),
      ),
    );
  }

  void _forget(_Peer peer) {
    if (identical(_peers[peer.userId], peer)) _peers.remove(peer.userId);
    if (identical(_byAddress[peer.address], peer)) _byAddress.remove(peer.address);
  }

  void _close(_Peer peer, {required bool sayBye, String? sessionId}) {
    if (peer.closed) return;
    final session = sessionId ?? _session?.id;
    if (sayBye && session != null) context.signal(peer.userId, peer.device, session, 'bye', null);
    peer
      ..closed = true
      ..state = PeerState.closed;
    unawaited(peer.link.close().catchError((Object _) {}));
    // The game's streams with this player end with the connection.
    context.peerGone?.call(peer.address);
  }
}
