import 'dart:typed_data';

import 'package:anyps5_desktop/core/together/discover.dart' show PublicJoin;
import 'package:anyps5_desktop/core/together/media.dart';
import 'package:anyps5_desktop/core/together/people.dart';
import 'package:anyps5_desktop/core/together/share_audio.dart';
import 'package:anyps5_desktop/core/together/share_host.dart';
import 'package:anyps5_desktop/core/together/share_play.dart';
import 'package:test/test.dart';

class FakeBridges implements SharePadBridges {
  final free = <int>[3, 2];
  final sent = <(int, Uint8List)>[];
  final released = <int>[];
  @override
  int? reservePadBridge() => free.isEmpty ? null : free.removeAt(0);
  @override
  void releasePadBridge(int bridge) => released.add(bridge);
  @override
  void sendPad(Uint8List data, int bridge) => sent.add((bridge, data));
}

class FakeLink implements ShareLink {
  final offers = <bool>[];
  final remotes = <Map<String, dynamic>>[];
  final candidates = <Map<String, dynamic>>[];
  final padsOut = <Uint8List>[];
  final encodings = <int>[];
  String signaling = 'stable';
  bool remote = false;
  bool closed = false;
  Map<String, dynamic>? local;
  void Function(Uint8List)? pad;

  @override
  Future<Map<String, dynamic>> createOffer({bool restart = false}) async {
    offers.add(restart);
    return {'type': 'offer', 'sdp': 'offer-${offers.length}'};
  }

  @override
  Future<void> setLocal(Map<String, dynamic> description) async {
    local = description;
    signaling = 'have-local-offer';
  }

  @override
  Future<void> setRemote(Map<String, dynamic> description) async {
    remotes.add(description);
    remote = true;
    signaling = 'stable';
  }

  @override
  Future<void> addCandidate(Map<String, dynamic> candidate) async => candidates.add(candidate);
  @override
  String get signalingState => signaling;
  @override
  String get connectionState => closed ? 'closed' : state;
  String state = 'connecting';
  @override
  bool get hasRemote => remote;
  @override
  Map<String, dynamic>? get localDescription => local;
  @override
  set onCandidate(void Function(Map<String, dynamic>) handler) {}
  @override
  set onState(void Function() handler) {}
  @override
  set onPad(void Function(Uint8List) handler) => pad = handler;
  @override
  void sendPad(Uint8List packet) => padsOut.add(packet);
  @override
  Future<void> setEncoding({required int maxBitrate, required int maxFramerate, required double scaleDown}) async =>
      encodings.add(maxBitrate);
  @override
  Future<void> close() async => closed = true;

  void Function(String)? hello;
  final soundOut = <Uint8List>[];
  int soundTracks = 0;
  bool canAddSound = true;
  ShareLinkStats? measured;
  @override
  set onHello(void Function(String) handler) => hello = handler;
  @override
  Future<bool> addSound() async {
    if (canAddSound) soundTracks++;
    return canAddSound;
  }

  @override
  bool sendSound(Uint8List packet, {int most = 65536}) {
    soundOut.add(packet);
    return true;
  }

  @override
  Future<ShareLinkStats?> stats() async => measured;
}

class FakeEngine implements ShareEngine {
  final links = <FakeLink>[];
  bool stopped = false;
  bool sound = true;
  @override
  bool get hasSound => sound;
  @override
  Future<bool> start({required String windowTitle}) async => true;
  @override
  Future<ShareLink> link(List<Map<String, dynamic>> iceServers) async {
    final link = FakeLink();
    links.add(link);
    return link;
  }

  /// The media server publisher handed out, once asked for.
  FakePublisher? publisher;
  bool publisherFails = false;

  @override
  SfuPublisher? mediaServer(void Function() changed) => publisher = FakePublisher(changed, fails: publisherFails);

  @override
  Future<void> stop() async => stopped = true;
}

class FakePublisher implements SfuPublisher {
  FakePublisher(this.changed, {this.fails = false});
  final void Function() changed;
  final bool fails;
  SfuAccess? access;
  bool closed = false;

  @override
  bool get connected => access != null && !closed;

  @override
  Future<void> start(SfuAccess access) async {
    if (fails) throw StateError('no media server');
    this.access = access;
    changed();
  }

  @override
  Future<void> close() async => closed = true;
}

Person person(String id) => Person(id: id, handle: id, displayName: id.toUpperCase());

ShareViewer viewer(String id, String device, {int? slot}) => ShareViewer(user: person(id), device: device, slot: slot);

SharePlay share(List<ShareViewer> viewers) =>
    SharePlay(id: 's1', hostDevice: 'host', titleId: 'PPSA01001', open: true, maxViewers: 4, viewers: viewers);

/// An 80-byte pad packet with a session, as a viewer's browser sends it.
Uint8List padPacket() {
  final packet = Uint8List(80);
  ByteData.sublistView(packet)
    ..setUint32(0, 0x49525041, Endian.little)
    ..setUint16(4, 1, Endian.little)
    ..setUint16(6, 80, Endian.little)
    ..setUint32(8, 5, Endian.little)
    ..setUint64(24, 99, Endian.little);
  packet[32] = 0xFF;
  return packet;
}

void main() {
  test('the server\'s share play reads as the Mac reads it', () {
    final start = SharePlayStart.fromJson({
      'sharePlay': {
        'id': 's1',
        'host': {'userId': 'h', 'handle': 'h', 'displayName': 'Host'},
        'hostDevice': 'dev',
        'titleId': 'PPSA01001',
        'title': 'Orbit',
        'open': true,
        'maxViewers': 3,
        'viewers': [
          {
            'user': {'userId': 'a', 'handle': 'a', 'displayName': 'A'},
            'device': 'd1',
            'slot': 2,
          },
        ],
      },
      'iceServers': [
        {
          'urls': ['stun:stun.example.org'],
        },
      ],
      'expiresAt': '2026-11-01T12:00:00Z',
    });
    expect(start.sharePlay.viewers.single.slot, 2);
    expect(start.sharePlay.maxViewers, 3);
    expect(start.iceServers, hasLength(1));
    expect(start.expiresAt, DateTime.utc(2026, 11, 1, 12));
    expect(ShareSignal.frame(to: 'a', device: 'd1', share: 's1', kind: 'offer', data: {'sdp': 'x'}), {
      'op': 'signal',
      'to': 'a',
      'device': 'd1',
      'share': 's1',
      'kind': 'offer',
      'data': {'sdp': 'x'},
    });
  });

  test('the roster calls newcomers, hangs up on leavers and on a device change', () {
    final plan = ShareRoster.plan([viewer('a', 'd1'), viewer('b', 'd2')], [viewer('a', 'd9'), viewer('c', 'd3')]);
    expect(plan.call.map((viewer) => viewer.user.id), ['a', 'c']);
    expect(plan.hangUp, ['a', 'b']);
    expect(ShareRoster.freePad([viewer('a', 'd', slot: 2), viewer('b', 'd', slot: 4)]), 3);
    expect(
      ShareRoster.freePad([
        for (final pad in [2, 3, 4]) viewer('$pad', 'd', slot: pad),
      ]),
      isNull,
    );
    expect(ShareRoster.encoding(3).maxFramerate, 30);
  });

  test('the answer gets WebRTC\'s bit rate hints on every H.264 format', () {
    const sdp = 'v=0\r\na=rtpmap:102 H264/90000\r\na=fmtp:102 profile-level-id=42e01f\r\na=rtpmap:104 H264/90000';
    final tuned = ShareRoster.tuneVideo(sdp, startKbps: 2500, maxKbps: 10000);
    expect(
      tuned,
      contains('a=fmtp:102 profile-level-id=42e01f;x-google-start-bitrate=2500;x-google-max-bitrate=10000'),
    );
    expect(tuned, contains('a=rtpmap:104 H264/90000\r\na=fmtp:104 x-google-start-bitrate=2500'));
  });

  test('only a viewer with a pad reaches the game, seated as their player, let go when it is taken back', () {
    final bridges = FakeBridges();
    final router = SharePadRouter(bridges);
    expect(router.receive(padPacket(), 'a'), isFalse);
    router.update({'a': 3});
    expect(router.receive(padPacket(), 'a'), isTrue);
    final (bridge, sent) = bridges.sent.single;
    expect(bridge, 3);
    expect(sent[13], 3, reason: 'the pad the host gave');
    expect(router.receive(padPacket(), 'b'), isFalse);
    // Assist: the packet says it helps player 1 instead of its pad.
    router.assist.add('a');
    expect(router.receive(padPacket(), 'a'), isTrue);
    expect(bridges.sent.last.$2[13], 1);
    router.assist.remove('a');
    expect(router.receive(Uint8List(80), 'a'), isFalse, reason: 'not a pad packet');
    router.update({});
    final letGo = bridges.sent.last.$2;
    expect(letGo[32], 0);
    expect(letGo.sublist(36, 40), [128, 128, 128, 128]);
    expect(ByteData.sublistView(letGo).getUint32(8, Endian.little), 6);
    expect(bridges.released, [3]);
  });

  test('the host is told who is listed, asking and holding a code, as the Mac reads it', () {
    final play = SharePlay.fromJson({
      'id': 's1',
      'hostDevice': 'dev',
      'titleId': 'PPSA01001',
      'open': true,
      'maxViewers': 10,
      'viewers': const <Object>[],
      'media': 'sfu',
      'public': {'join': 'open', 'language': 'tr', 'live': true},
      'requests': [
        {'userId': 'r', 'handle': 'r', 'displayName': 'R'},
      ],
      'joinCode': {'code': 'K7QM3XPA', 'url': 'https://anytogether.net/join/K7QM3XPA', 'expiresAt': '2026-11-08T12:00:00Z'},
    });
    expect(play.media, MediaRoute.sfu);
    expect(play.listing!.join, PublicJoin.open);
    expect(play.listing!.language, 'tr');
    expect(play.listing!.live, isTrue);
    expect(play.requests.single.id, 'r');
    expect(play.joinCode!.shown, 'K7QM-3XPA');
    expect(play.copyWith(joinCode: () => null).joinCode, isNull);
    expect(ShareListing(join: PublicJoin.request, live: true).live, isFalse, reason: 'only an open one is live');
    expect(ShareListing(join: PublicJoin.open, language: 'de', live: true).toJson(), {
      'join': 'open',
      'language': 'de',
      'live': true,
    });
    final plain = SharePlay.fromJson({'id': 's2', 'hostDevice': 'd', 'titleId': 't', 'open': false, 'maxViewers': 2, 'viewers': const <Object>[]});
    expect([plain.listing, plain.joinCode, plain.requests], [null, null, isEmpty]);
  });

  test('how many may watch: four on the mesh, the media server\'s limit with one', () {
    expect(ShareMedia.viewerChoices(null), (min: 1, max: 4));
    expect(ShareMedia.viewerChoices(const MediaLimits()), (min: 1, max: 4));
    const server = MediaLimits(sfu: true, maxShareViewers: 16);
    expect(ShareMedia.viewerChoices(server, watching: 6, current: 8), (min: 6, max: 16));
    expect(ShareMedia.viewerChoices(null, watching: 2, current: 7), (min: 2, max: 7), reason: 'never below its own limit');
    expect(ShareMedia.clampViewers(12, null), 4);
    expect(ShareMedia.clampViewers(12, server), 12);
    expect(ShareMedia.clampViewers(0, server), 1);
  });

  group('the host', () {
    late FakeEngine engine;
    late FakeBridges bridges;
    late List<(String, String, String, Object?)> signals;
    late ShareHostSession session;

    setUp(() {
      engine = FakeEngine();
      bridges = FakeBridges();
      signals = [];
      session = ShareHostSession(
        id: 's1',
        engine: engine,
        iceServers: const [],
        signal: (to, device, kind, data) => signals.add((to, device, kind, data)),
        router: SharePadRouter(bridges),
        changed: () {},
      );
    });

    test('offers each viewer, tunes their answer, queues early candidates', () async {
      await session.apply(share([viewer('a', 'd1')]));
      expect(signals.single.$3, 'offer');
      expect(signals.single.$2, 'd1');
      final link = engine.links.single;
      await session.receive(
        const ShareSignal(sharePlayId: 's1', from: 'a', device: 'd1', kind: 'candidate', data: {'candidate': 'c1'}),
      );
      expect(link.candidates, isEmpty);
      await session.receive(
        const ShareSignal(
          sharePlayId: 's1',
          from: 'a',
          device: 'd1',
          kind: 'answer',
          data: {'type': 'answer', 'sdp': 'a=rtpmap:96 H264/90000'},
        ),
      );
      expect(link.remotes.single['sdp'], contains('x-google-max-bitrate=10000'));
      expect(link.candidates, [
        {'candidate': 'c1'},
      ]);
      expect(link.encodings, isNotEmpty);
    });

    test('a viewer waiting for the offer gets it again; a broken one gets a new connection', () async {
      await session.apply(share([viewer('a', 'd1')]));
      await session.receive(const ShareSignal(sharePlayId: 's1', from: 'a', device: 'd1', kind: 'renegotiate'));
      expect(signals.map((signal) => signal.$3), ['offer', 'offer']);
      expect(engine.links, hasLength(1));
      engine.links.single.signaling = 'stable';
      await session.receive(const ShareSignal(sharePlayId: 's1', from: 'a', device: 'd1', kind: 'renegotiate'));
      expect(engine.links, hasLength(2));
      expect(engine.links.first.closed, isTrue);
    });

    test('a pad handed over reaches the game, its answers go back, leavers are hung up on', () async {
      await session.apply(share([viewer('a', 'd1', slot: 2)]));
      engine.links.single.pad!(padPacket());
      expect(bridges.sent.single.$1, 3);
      session.padOutput(3, Uint8List(32));
      expect(engine.links.single.padsOut, hasLength(1));
      await session.apply(share(const []));
      expect(engine.links.single.closed, isTrue);
      expect(bridges.released, [3]);
      await session.close();
      expect(engine.stopped, isTrue);
    });

    test('sound: PCM to everyone until a viewer\'s hello asks for Opus and their answer takes it', () async {
      await session.apply(share([viewer('a', 'd1'), viewer('b', 'd2')]));
      final a = engine.links[0];
      final b = engine.links[1];
      final packet = Uint8List(16 + 960);
      session.pushSound(packet);
      expect([a.soundOut.length, b.soundOut.length], [1, 1]);
      // Not a hello, and a hello for PCM only: nothing changes.
      a.hello!('hi');
      b.hello!(const ShareAudioHello([ShareAudioCodec.pcm]).text);
      await pumpEventQueue();
      expect([a.soundTracks, b.soundTracks], [0, 0]);
      a.hello!(const ShareAudioHello([ShareAudioCodec.opus, ShareAudioCodec.pcm]).text);
      await pumpEventQueue();
      expect(a.soundTracks, 1);
      expect(
        signals.where((signal) => signal.$1 == 'a' && signal.$3 == 'offer'),
        hasLength(2),
        reason: 'offered again',
      );
      a.hello!(const ShareAudioHello([ShareAudioCodec.opus]).text);
      await pumpEventQueue();
      expect(a.soundTracks, 1, reason: 'once');
      const answer =
          'v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\na=rtpmap:96 H264/90000\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=rtpmap:111 opus/48000/2\r\na=fmtp:111 minptime=10\r\na=recvonly';
      await session.receive(
        const ShareSignal(
          sharePlayId: 's1',
          from: 'a',
          device: 'd1',
          kind: 'answer',
          data: {'type': 'answer', 'sdp': answer},
        ),
      );
      final taken = a.remotes.single['sdp'] as String;
      expect(
        taken,
        contains('a=fmtp:111 minptime=10;stereo=1;sprop-stereo=1;maxaveragebitrate=128000;useinbandfec=1;usedtx=0'),
      );
      expect(taken, contains('a=ptime:10'));
      expect(session.sound, {'a': ShareAudioCodec.opus, 'b': ShareAudioCodec.pcm});
      session.pushSound(packet);
      expect([a.soundOut.length, b.soundOut.length], [1, 2], reason: 'no more PCM for the Opus viewer');
    });

    test('without an Opus track to give, a hello leaves the viewer on PCM', () async {
      engine.sound = false;
      await session.apply(share([viewer('a', 'd1')]));
      engine.links.single.hello!(const ShareAudioHello([ShareAudioCodec.opus, ShareAudioCodec.pcm]).text);
      await pumpEventQueue();
      expect(engine.links.single.soundTracks, 0);
      expect(signals.where((signal) => signal.$3 == 'offer'), hasLength(1));
    });

    test('each connected viewer\'s link is measured for the host\'s list', () async {
      await session.apply(share([viewer('a', 'd1')]));
      engine.links.single.measured = const ShareLinkStats(
        roundTripMs: 23,
        relayed: false,
        framesPerSecond: 60,
        frameHeight: 720,
      );
      await session.measure();
      expect(session.stats, isEmpty, reason: 'not connected yet');
      engine.links.single.state = 'connected';
      await session.measure();
      expect(session.stats['a']!.roundTripMs, 23);
    });

    test('through the media server only pad holders, and older apps that ask while there is room, get a link here', () async {
      SharePlay sfu(List<ShareViewer> viewers) => SharePlay(
        id: 's1',
        hostDevice: 'host',
        titleId: 'PPSA01001',
        open: true,
        maxViewers: 10,
        viewers: viewers,
        media: MediaRoute.sfu,
      );
      await session.apply(share([viewer('a', 'd1', slot: 2), viewer('b', 'd2')]));
      expect(engine.links, hasLength(2), reason: 'the mesh: everyone');
      final viewers = [viewer('a', 'd1', slot: 2), viewer('b', 'd2'), for (final id in ['c', 'd', 'e', 'f']) viewer(id, '$id-dev')];
      await session.apply(sfu(viewers));
      expect(engine.links[1].closed, isTrue, reason: 'b watches from the media server now');
      expect(session.links.keys, ['a']);
      // An older app asks for a link: served while the host has fewer than four.
      for (final id in ['c', 'd', 'e']) {
        await session.receive(ShareSignal(sharePlayId: 's1', from: id, device: '$id-dev', kind: 'renegotiate'));
      }
      expect(session.links.keys.toSet(), {'a', 'c', 'd', 'e'});
      await session.receive(const ShareSignal(sharePlayId: 's1', from: 'f', device: 'f-dev', kind: 'renegotiate'));
      expect(session.links.keys, isNot(contains('f')), reason: 'four links already');
      await session.receive(const ShareSignal(sharePlayId: 's1', from: 'z', device: 'z-dev', kind: 'renegotiate'));
      expect(session.links.keys, isNot(contains('z')), reason: 'not watching');
      // The next update keeps the ones who asked.
      await session.apply(sfu(viewers));
      expect(session.links.keys.toSet(), {'a', 'c', 'd', 'e'});
      expect(ShareMedia.meshViewers(sfu(viewers), {'c'}).map((viewer) => viewer.user.id), ['a', 'c']);
      expect(ShareMedia.meshViewers(share(viewers), const {}), hasLength(6));
    });

    test('signals of another share play are not taken', () async {
      await session.apply(share([viewer('a', 'd1')]));
      await session.receive(const ShareSignal(sharePlayId: 'other', from: 'a', device: 'd1', kind: 'bye'));
      expect(engine.links.single.closed, isFalse);
      await session.receive(const ShareSignal(sharePlayId: 's1', from: 'a', device: 'd1', kind: 'bye'));
      expect(engine.links.single.closed, isTrue);
    });
  });
}
