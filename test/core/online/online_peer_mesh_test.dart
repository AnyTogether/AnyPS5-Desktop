import 'dart:convert';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/online/online_identity.dart';
import 'package:anyps5_desktop/core/online/online_peer.dart';
import 'package:anyps5_desktop/core/online/online_peer_mesh.dart';
import 'package:anyps5_desktop/core/online/online_play.dart';
import 'package:anyps5_desktop/core/online/online_web_router.dart';
import 'package:anyps5_desktop/core/online/online_wire.dart';
import 'package:anyps5_desktop/core/together/account.dart';
import 'package:test/test.dart';

import '../../support/online_fakes.dart';

const alice = '0190a0b1-0000-7000-8000-00000000000a';
const bob = '0190a0b1-0000-7000-8000-00000000000b';
const carol = '0190a0b1-0000-7000-8000-00000000000c';
const game = OnlineGame(titleId: 'PPSA00000', gameVersion: '01.000', engineBuild: 'mesh-test');

/// Two or three launchers in one process, each with its bridge, a game (the fake engine) and the
/// mesh over in-process peer connections; one AnyTogether session and its gateway between them.
class Players {
  Players(List<String> users) {
    for (final (index, user) in users.indexed) {
      together.add(user, 'dev-$index');
    }
  }

  final together = OneSession();
  final network = FakeGameNetwork();
  final plays = <String, OnlinePlay>{};
  final meshes = <String, OnlinePeerMesh>{};
  final engines = <String, FakeEngine>{};

  Future<void> start(String user, {List<Map<String, dynamic>>? iceServers}) async {
    final device = together.players.firstWhere((player) => player.$1 == user).$2;
    final play = OnlinePlay(
      call: together.call,
      user: TogetherUser(id: user, handle: user.substring(user.length - 1), displayName: user),
      game: game,
      signal: together.relay(user, device),
      transport: (context) =>
          meshes[user] = OnlinePeerMesh(context: context, links: network.links, iceServers: iceServers),
    );
    together.attach(user, play.receive);
    plays[user] = play;
    engines[user] = (await FakeEngine.fromEnvironment(await play.start()))!;
  }

  Future<void> stop() async {
    for (final engine in engines.values) {
      await engine.close();
    }
    for (final play in plays.values) {
      await play.stop();
    }
  }
}

WireDatagram datagram(int peer, String text, {int port = 3658, int vport = 1, DatagramKind kind = DatagramKind.p2p}) =>
    WireDatagram(
      peer: peer,
      peerPort: port,
      peerVport: vport,
      localPort: port,
      localVport: 2,
      kind: kind,
      data: utf8.encode(text),
    );

void main() {
  test('two launchers carry game packets over the data channels, broadcasts included', () async {
    final players = Players([alice, bob]);
    addTearDown(players.stop);
    await players.start(alice);
    await players.start(bob);
    final addresses = OnlineIdentity.addresses([alice, bob]);
    final (a, b) = (addresses[alice]!, addresses[bob]!);

    // Bob's launcher follows the session first; Alice's (who offers, her ID being smaller) later.
    await players.plays[bob]!.follow(players.together.id);
    await players.plays[alice]!.follow(players.together.id);
    final aliceEngine = players.engines[alice]!, bobEngine = players.engines[bob]!;
    expect(
      await aliceEngine.addressSoon(a) && await bobEngine.addressSoon(b),
      isTrue,
      reason: 'each game learns its address',
    );
    final aliceMesh = players.meshes[alice]!, bobMesh = players.meshes[bob]!;
    expect(
      await eventually(
        () => aliceMesh.states[bob] == PeerState.connected && bobMesh.states[alice] == PeerState.connected,
      ),
      isTrue,
      reason: '${players.together.signals}',
    );
    expect(players.together.signals, contains('$alice>$bob offer'), reason: 'the smaller user ID offers');
    expect(players.together.signals, isNot(contains('$bob>$alice offer')));
    expect(players.together.signals, contains('$bob>$alice renegotiate'), reason: 'the later one asks for an offer');
    expect(players.network.made.first.single['urls'], ['turn:relay.example:3478'], reason: 'TURN from AnyTogether');
    expect(players.network.made, hasLength(2), reason: 'one connection, even when the request for an offer crossed it');
    for (final link in players.network.all.where((link) => link.state == 'connected')) {
      expect(link.candidatesIn, isNotEmpty, reason: 'candidates that came before the description were kept for it');
    }

    final ping = datagram(b, 'ping');
    expect(await eventually(() => aliceMesh.send(ping)), isTrue);
    expect(
      await bobEngine.nextDatagram(),
      WireDatagram(
        peer: a,
        peerPort: 3658,
        peerVport: 2,
        localPort: 3658,
        localVport: 1,
        kind: DatagramKind.p2p,
        data: utf8.encode('ping'),
      ),
      reason: 'the packet reaches the other game from the sender\'s virtual address and ports',
    );
    bobEngine.send(
      WireDatagram(
        peer: a,
        peerPort: 3658,
        peerVport: 2,
        localPort: 3658,
        localVport: 1,
        kind: DatagramKind.p2p,
        data: utf8.encode('pong'),
      ),
    );
    final atAlice = (await aliceEngine.nextDatagram())!;
    expect(utf8.decode(atAlice.data), 'pong');
    expect(atAlice.peer, b);

    for (var index = 0; index < 200; index++) {
      aliceEngine.send(
        WireDatagram(
          peer: b,
          peerPort: 9000,
          peerVport: 0,
          localPort: 9001,
          localVport: 0,
          kind: DatagramKind.udp,
          data: Uint8List(1200)..fillRange(0, 1200, index),
        ),
      );
    }
    var received = 0;
    while (received < 200) {
      final next = await bobEngine.nextDatagram();
      if (next == null) break;
      expect(next.data, hasLength(1200));
      expect(next.kind, DatagramKind.udp);
      received++;
    }
    expect(received, 200, reason: 'a burst of game-sized packets crosses');

    final stranger = datagram(OnlineWire.virtualNetwork | 0x1234, 'x', kind: DatagramKind.udp);
    expect(aliceMesh.send(stranger), isFalse, reason: 'a packet for someone outside the session goes nowhere');

    // A game's broadcast (LAN-style discovery) reaches every other player, from the sender.
    for (final group in [0xFFFFFFFF, OnlineWire.virtualBroadcast, 0xE00000FB]) {
      aliceEngine.send(
        WireDatagram(
          peer: group,
          peerPort: 3659,
          peerVport: 0,
          localPort: 3660,
          localVport: 0,
          kind: DatagramKind.udp,
          data: utf8.encode('who is there'),
        ),
      );
      expect(
        await bobEngine.nextDatagram(),
        WireDatagram(
          peer: a,
          peerPort: 3660,
          peerVport: 0,
          localPort: 3659,
          localVport: 0,
          kind: DatagramKind.udp,
          data: utf8.encode('who is there'),
        ),
        reason: 'a datagram to ${group.toRadixString(16)} arrives from the sender\'s virtual address',
      );
    }

    // The largest UDP datagram crosses; a bigger one is dropped and counted, never fatal.
    aliceEngine.send(
      WireDatagram(
        peer: b,
        peerPort: 9000,
        peerVport: 0,
        localPort: 9001,
        localVport: 0,
        kind: DatagramKind.udp,
        data: Uint8List(OnlineWire.maxGameDatagram),
      ),
    );
    expect((await bobEngine.nextDatagram())!.data, hasLength(OnlineWire.maxGameDatagram));
    final tooBig = WireDatagram(
      peer: b,
      peerPort: 9000,
      peerVport: 0,
      localPort: 9001,
      localVport: 0,
      kind: DatagramKind.udp,
      data: Uint8List(OnlineWire.maxGameDatagram + 1),
    );
    expect(aliceMesh.send(tooBig), isFalse);
    expect(aliceMesh.droppedTooLarge, 1);
    final traffic = aliceMesh.traffic;
    expect(traffic.sent, greaterThanOrEqualTo(205));
    expect(traffic.dropped, 2, reason: 'the stranger\'s packet and the big one');
    expect(bobMesh.traffic.received, greaterThanOrEqualTo(205));

    // Bob leaves: Alice's connection to him closes and the game's packets to him are dropped.
    await players.plays[bob]!.follow(null);
    expect(
      await eventually(() => aliceMesh.states[bob] == null || aliceMesh.states[bob] == PeerState.closed),
      isTrue,
      reason: 'a goodbye closes the other side: ${players.together.signals}',
    );
    expect(players.together.signals, contains('$bob>$alice bye'));
    expect(aliceMesh.send(ping), isFalse);
  });

  test('a broadcast goes to each of the other players; a newcomer is offered to again', () async {
    final players = Players([alice, bob, carol]);
    addTearDown(players.stop);
    for (final user in [alice, bob, carol]) {
      await players.start(user, iceServers: const []);
    }
    final addresses = OnlineIdentity.addresses([alice, bob, carol]);
    for (final user in [carol, bob, alice]) {
      await players.plays[user]!.follow(players.together.id);
    }
    final meshes = players.meshes;
    expect(
      await eventually(
        () =>
            meshes[alice]!.states.values.where((state) => state == PeerState.connected).length == 2 &&
            meshes[bob]!.states[carol] == PeerState.connected,
      ),
      isTrue,
      reason: '${players.together.signals}',
    );
    expect(players.network.made.first, isEmpty, reason: 'fixed ICE servers replace asking AnyTogether');

    final shout = WireDatagram(
      peer: 0xFFFFFFFF,
      peerPort: 3659,
      peerVport: 0,
      localPort: 3660,
      localVport: 0,
      kind: DatagramKind.udp,
      data: utf8.encode('hi'),
    );
    expect(await eventually(() => meshes[bob]!.send(shout)), isTrue);
    for (final user in [alice, carol]) {
      final heard = (await players.engines[user]!.nextDatagram())!;
      expect(heard.peer, addresses[bob], reason: '$user hears bob\'s broadcast from bob');
    }
    expect(meshes[bob]!.traffic.sent, 2, reason: 'a broadcast counts once for each player it goes to');

    // Carol's launcher starts again (a new device): the others connect to the new one.
    final oldLinks = players.network.made.length;
    players.together.players[2] = (carol, 'dev-2b');
    await players.plays[carol]!.stop();
    await players.engines[carol]!.close();
    await players.start(carol, iceServers: const []);
    await players.plays[carol]!.follow(players.together.id);
    await players.plays[alice]!.refresh();
    await players.plays[bob]!.refresh();
    expect(
      await eventually(
        () => meshes[carol]!.states.length == 2 && meshes[carol]!.states.values.every((s) => s == PeerState.connected),
      ),
      isTrue,
      reason: '${players.together.signals}',
    );
    expect(players.network.made.length, greaterThan(oldLinks));
    final hello = WireDatagram(
      peer: addresses[alice]!,
      peerPort: 1,
      peerVport: 0,
      localPort: 2,
      localVport: 0,
      kind: DatagramKind.udp,
      data: [5],
    );
    expect(await eventually(() => meshes[carol]!.send(hello)), isTrue);
    expect((await players.engines[alice]!.nextDatagram())?.peer, addresses[carol]);
  });

  test('signals from outside the session, from oneself or out of order are harmless', () async {
    final sent = <String>[];
    final delivered = <WireDatagram>[];
    final network = FakeGameNetwork();
    final mesh = OnlinePeerMesh(
      context: OnlinePeerContext(
        deliver: delivered.add,
        call: FakeOnlineTogether().call,
        signal: (to, device, session, kind, data) => sent.add('$to $kind'),
      ),
      links: network.links,
      iceServers: const [],
    );
    addTearDown(mesh.stop);
    final addresses = OnlineIdentity.addresses([alice, bob]);
    mesh.receive(const OnlinePeerSignal(from: bob, device: 'dev-b', kind: 'offer', data: {'sdp': 'x'}));
    expect(network.made, isEmpty, reason: 'no session, nothing');
    mesh.update(
      OnlinePeerSession(id: 's', me: bob, addresses: addresses, devices: const {alice: 'dev-a', bob: 'dev-b'}),
    );
    expect(sent, ['$alice renegotiate'], reason: 'the larger ID asks the smaller for an offer');
    mesh.receive(const OnlinePeerSignal(from: 'stranger', device: 'x', kind: 'offer', data: {'sdp': 'fake link-9'}));
    mesh.receive(const OnlinePeerSignal(from: bob, device: 'dev-b', kind: 'offer', data: {'sdp': 'fake link-9'}));
    mesh.receive(const OnlinePeerSignal(from: alice, device: 'dev-a', kind: 'answer', data: {'sdp': 'x'}));
    mesh.receive(const OnlinePeerSignal(from: alice, device: 'dev-a', kind: 'candidate', data: {'candidate': 'c'}));
    mesh.receive(const OnlinePeerSignal(from: alice, device: 'dev-a', kind: 'renegotiate'));
    mesh.receive(const OnlinePeerSignal(from: alice, device: 'dev-a', kind: 'bye'));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(
      network.made,
      isEmpty,
      reason: 'only an offer from a player makes a connection, and the larger ID never offers',
    );
    expect(mesh.states, isEmpty);
    mesh.stop();
    mesh.update(
      OnlinePeerSession(id: 's', me: alice, addresses: addresses, devices: const {alice: 'dev-a', bob: 'dev-b'}),
    );
    expect(sent, hasLength(1), reason: 'a stopped mesh does nothing');
  });

  test('an answerer that starts over on a repeated offer (as the Mac launcher does) is met with a new offer', () async {
    final sent = <(String, Object?)>[];
    final network = FakeGameNetwork();
    final mesh = OnlinePeerMesh(
      context: OnlinePeerContext(
        deliver: (_) {},
        call: FakeOnlineTogether().call,
        signal: (to, device, session, kind, data) => sent.add((kind, data)),
      ),
      links: network.links,
      iceServers: const [],
    );
    addTearDown(mesh.stop);
    final addresses = OnlineIdentity.addresses([alice, bob]);
    mesh.update(
      OnlinePeerSession(id: 's', me: alice, addresses: addresses, devices: const {alice: 'dev-a', bob: 'dev-b'}),
    );
    Future<Map<String, dynamic>> offer(int count) async {
      expect(await eventually(() => sent.where((signal) => signal.$1 == 'offer').length == count), isTrue);
      return sent.lastWhere((signal) => signal.$1 == 'offer').$2! as Map<String, dynamic>;
    }

    // Bob's side, by hand: a new connection for every offer, as the Mac's answerer makes.
    Future<String> answer(Map<String, dynamic> offer) async {
      final link = await network.links.link(const []);
      await link.setRemote(offer);
      final made = await link.createAnswer();
      await link.setLocal(made);
      return made['sdp'] as String;
    }

    void signal(String kind, Object? data) =>
        mesh.receive(OnlinePeerSignal(from: bob, device: 'dev-b', kind: kind, data: data));

    final first = await offer(1);
    final firstAnswer = await answer(first);
    signal('answer', {'type': 'answer', 'sdp': firstAnswer});
    expect(await eventually(() => mesh.states[bob] == PeerState.connected), isTrue);
    signal('answer', {'type': 'answer', 'sdp': firstAnswer});
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(sent.where((signal) => signal.$1 == 'offer'), hasLength(1), reason: 'the same answer again changes nothing');

    // The offer came twice to bob (a crossed request), and bob started over with a new answer.
    signal('answer', {'type': 'answer', 'sdp': await answer(first)});
    final second = await offer(2);
    expect(second['sdp'], isNot(first['sdp']), reason: 'a new connection, with its own offer');
    signal('answer', {'type': 'answer', 'sdp': await answer(second)});
    expect(await eventually(() => mesh.states[bob] == PeerState.connected), isTrue);
    expect(
      sent.where((signal) => signal.$1 == 'offer'),
      hasLength(2),
      reason: 'it settles: one new offer, answered once',
    );
  });

  test('two launchers carry a game stream over the reliable channel', () async {
    final players = Players([alice, bob]);
    addTearDown(players.stop);
    await players.start(alice);
    await players.start(bob);
    final addresses = OnlineIdentity.addresses([alice, bob]);
    final (a, b) = (addresses[alice]!, addresses[bob]!);
    await players.plays[bob]!.follow(players.together.id);
    await players.plays[alice]!.follow(players.together.id);
    final aliceEngine = players.engines[alice]!, bobEngine = players.engines[bob]!;
    expect(await aliceEngine.addressSoon(a) && await bobEngine.addressSoon(b), isTrue);
    final aliceMesh = players.meshes[alice]!, bobMesh = players.meshes[bob]!;
    expect(
      await eventually(() => aliceMesh.canStream(b) && bobMesh.canStream(a)),
      isTrue,
      reason: '${players.together.signals}',
    );
    // Some game datagrams are lost on the way; stream messages never are.
    players.network.lose = (data) => true;

    aliceEngine.sendStream(
      WireStream.open(stream: 1, peer: b, peerPort: 3659, peerVport: 1, localPort: 3660, localVport: 5),
    );
    final opened = (await bobEngine.nextStream())!;
    expect(opened.kind, WireKind.streamOpen);
    final id = opened.stream;
    expect(id & OnlineWire.launcherStream, isNot(0));
    expect(
      [opened.peer, opened.peerPort, opened.peerVport, opened.localPort, opened.localVport],
      [a, 3660, 5, 3659, 1],
    );
    bobEngine.sendStream(WireStream.accept(id));
    expect(await aliceEngine.nextStream(), WireStream.accept(1));

    final big = Uint8List.fromList(List.generate(60000, (index) => (index * 13) & 0xFF));
    aliceEngine.sendStream(WireStream.data(1, big));
    final received = <int>[];
    while (received.length < big.length) {
      final frame = await bobEngine.nextStream();
      if (frame == null || frame.kind != WireKind.streamData) break;
      received.addAll(frame.data);
    }
    expect(received, big, reason: 'the bytes arrive whole and in order');
    bobEngine.sendStream(WireStream.data(id, utf8.encode('pong')));
    expect(await aliceEngine.nextStream(), WireStream.data(1, utf8.encode('pong')));
    aliceEngine.sendStream(WireStream.close(1, StreamCloseReason.closed));
    expect(await bobEngine.nextStream(), WireStream.close(id, StreamCloseReason.closed));
    bobEngine.sendStream(WireStream.data(id, utf8.encode('late')));
    expect(
      await aliceEngine.nextStream(),
      WireStream.data(1, utf8.encode('late')),
      reason: 'a half close carries back',
    );
    bobEngine.sendStream(WireStream.close(id, StreamCloseReason.closed));
    expect(await aliceEngine.nextStream(), WireStream.close(1, StreamCloseReason.closed));
    expect(players.plays[alice]!.streams.count + players.plays[bob]!.streams.count, 0);

    aliceEngine.sendStream(
      WireStream.open(stream: 2, peer: b, peerPort: 3659, peerVport: 1, localPort: 0, localVport: 0),
    );
    final second = (await bobEngine.nextStream())!.stream;
    bobEngine.sendStream(WireStream.accept(second));
    expect(await aliceEngine.nextStream(), WireStream.accept(2));
    await players.plays[bob]!.follow(null);
    expect(
      await aliceEngine.nextStream(),
      WireStream.close(2, StreamCloseReason.reset),
      reason: 'a player who leaves breaks the streams with them',
    );
  });

  group('how a player is reached', () {
    GameLinkStat stat(String id, String type, Map<String, String> values) => GameLinkStat(id, type, values);
    final local = stat('l', 'local-candidate', const {'candidateType': 'host'});
    final remote = stat('r', 'remote-candidate', const {'candidateType': 'srflx'});
    final relayed = stat('r', 'remote-candidate', const {'candidateType': 'relay'});

    test('direct from the selected pair, with the round trip', () {
      final pair = stat('p', 'candidate-pair', const {
        'localCandidateId': 'l',
        'remoteCandidateId': 'r',
        'currentRoundTripTime': '0.023',
      });
      final path = PeerPath.of([
        stat('t', 'transport', const {'selectedCandidatePairId': 'p'}),
        pair,
        local,
        remote,
      ]);
      expect(path.route, PeerRoute.direct);
      expect(path.rttMs, 23);
    });

    test('relayed when either end is a relay candidate', () {
      final path = PeerPath.of([
        stat('p', 'candidate-pair', const {
          'state': 'succeeded',
          'nominated': 'true',
          'localCandidateId': 'l',
          'remoteCandidateId': 'r',
        }),
        local,
        relayed,
      ]);
      expect(path.route, PeerRoute.relay);
      expect(path.rttMs, isNull);
    });

    test('no route is guessed from statistics that do not say', () {
      expect(PeerPath.of(const []).route, PeerRoute.connected);
      final noCandidates = PeerPath.of([
        stat('t', 'transport', const {'selectedCandidatePairId': 'p'}),
        stat('p', 'candidate-pair', const {'localCandidateId': 'l', 'remoteCandidateId': 'r'}),
      ]);
      expect(noCandidates.route, PeerRoute.connected);
    });

    test('a mesh gives each player\'s path; statistics that fail are only "connected"', () async {
      final players = Players([alice, bob]);
      addTearDown(players.stop);
      await players.start(alice);
      await players.start(bob);
      await players.plays[bob]!.follow(players.together.id);
      await players.plays[alice]!.follow(players.together.id);
      final mesh = players.meshes[alice]!;
      expect(await eventually(() => mesh.states[bob] == PeerState.connected), isTrue);
      players.network.stats = [
        stat('t', 'transport', const {'selectedCandidatePairId': 'p'}),
        stat('p', 'candidate-pair', const {
          'localCandidateId': 'l',
          'remoteCandidateId': 'r',
          'currentRoundTripTime': '0.08',
        }),
        local,
        relayed,
      ];
      var links = await mesh.paths();
      expect(links[bob]!.route, PeerRoute.relay);
      expect(links[bob]!.rttMs, 80);
      players.network.stats = null;
      links = await mesh.paths();
      expect(links[bob]!.route, PeerRoute.connected);
      expect(links[bob]!.rttMs, isNull);
    });
  });
}
