import 'dart:async';

import 'package:anyps5_desktop/core/together/account.dart';
import 'package:anyps5_desktop/core/together/parties.dart';
import 'package:anyps5_desktop/core/together/socket.dart';
import 'package:anyps5_desktop/core/together/talk_key.dart';
import 'package:anyps5_desktop/core/together/token_store.dart';
import 'package:anyps5_desktop/core/together/voice.dart';
import 'package:anyps5_desktop/core/together/voice_mesh.dart';
import 'package:test/test.dart';

import '../support/fake_together.dart';
import '../support/fake_voice.dart' show FakeKeys;

Future<void> until(bool Function() condition) async {
  for (var tries = 0; tries < 300 && !condition(); tries++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue);
}

/// The mesh tests are the phone app's (mobile/test/voice_test.dart), on the same VoiceMesh.
const offerSdp =
    'v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=rtpmap:111 opus/48000/2\r\n'
    'a=fmtp:111 minptime=10;useinbandfec=0\r\n';

/// A peer connection that keeps what it was told and answers like a browser would.
class FakeLink implements VoiceLink {
  FakeLink(this.engine);

  final FakeEngine engine;
  final calls = <String>[];
  final candidates = <Map<String, dynamic>>[];
  Map<String, dynamic>? local;
  Map<String, dynamic>? remote;
  void Function(Map<String, dynamic>)? candidate;
  void Function()? state;
  double incoming = 0;
  double outgoing = 0;
  bool closed = false;

  @override
  String signalingState = 'stable';
  @override
  String connectionState = 'new';
  @override
  bool hasRemote = false;

  @override
  Future<Map<String, dynamic>> createOffer({bool restart = false}) async {
    calls.add(restart ? 'offer(restart)' : 'offer');
    return {'type': 'offer', 'sdp': offerSdp};
  }

  @override
  Future<Map<String, dynamic>> createAnswer() async {
    calls.add('answer');
    return {'type': 'answer', 'sdp': offerSdp};
  }

  @override
  Future<void> setLocal(Map<String, dynamic> description) async {
    local = description;
    calls.add('local ${description['type']}');
    signalingState = description['type'] == 'offer' ? 'have-local-offer' : 'stable';
  }

  @override
  Future<void> setRemote(Map<String, dynamic> description) async {
    remote = description;
    hasRemote = true;
    calls.add('remote ${description['type']}');
    signalingState = description['type'] == 'offer' ? 'have-remote-offer' : 'stable';
  }

  @override
  Future<void> addCandidate(Map<String, dynamic> candidate) async => candidates.add(candidate);

  @override
  Future<({double incoming, double outgoing})> levels() async => (incoming: incoming, outgoing: outgoing);

  @override
  set onCandidate(void Function(Map<String, dynamic>) handler) => candidate = handler;

  @override
  set onState(void Function() handler) => state = handler;

  @override
  Future<void> close() async => closed = true;
}

class FakeEngine implements VoiceEngine {
  FakeEngine({this.deny = false});

  final bool deny;
  final links = <FakeLink>[];
  List<Map<String, dynamic>>? ice;
  bool talking = true;
  bool started = false;
  bool stopped = false;
  final noise = <bool>[];

  @override
  Future<void> start({bool noiseSuppression = true}) async {
    if (deny) throw const VoiceDenied();
    started = true;
    noise.add(noiseSuppression);
  }

  @override
  Future<void> setNoiseSuppression(bool on) async => noise.add(on);

  @override
  Future<VoiceLink> link(List<Map<String, dynamic>> iceServers) async {
    ice = iceServers;
    final link = FakeLink(this);
    links.add(link);
    return link;
  }

  @override
  void setTalking(bool on) => talking = on;

  bool hearing = true;

  @override
  void setHearing(bool on) => hearing = on;

  @override
  Future<void> stop() async => stopped = true;
}

void main() {
  test('Opus is tuned for voice, the way the website does it', () {
    final tuned = tuneOpus(offerSdp);
    expect(tuned, contains('a=fmtp:111 minptime=10;useinbandfec=1;usedtx=1;stereo=0;maxaveragebitrate=32000'));
    final bare = tuneOpus('m=audio 9 UDP/TLS/RTP/SAVPF 109\r\na=rtpmap:109 opus/48000/2\r\n');
    expect(
      bare,
      contains('a=rtpmap:109 opus/48000/2\r\na=fmtp:109 useinbandfec=1;usedtx=1;stereo=0;maxaveragebitrate=32000'),
    );
    expect(tuneOpus('m=video 9'), 'm=video 9');
  });

  group('the mesh', () {
    late FakeEngine engine;
    late List<(String, String, String, Object?)> sent;
    late VoiceMesh mesh;

    VoiceMesh make(String me) => VoiceMesh(
      me: me,
      engine: engine,
      iceServers: const [
        {
          'urls': ['stun:stun.example.org'],
        },
      ],
      signal: (to, device, kind, data) {
        sent.add((to, device, kind, data));
        return true;
      },
      onChange: () {},
    );

    setUp(() {
      engine = FakeEngine();
      sent = [];
      mesh = make('m');
    });

    test('the newcomer offers, and takes the answer', () async {
      await mesh.connectTo('z', 'dz');
      final (to, device, kind, data) = sent.single;
      expect((to, device, kind), ('z', 'dz', 'offer'));
      expect((data! as Map)['sdp'], contains('usedtx=1'));
      expect(engine.ice!.single['urls'], ['stun:stun.example.org']);
      // A candidate before the answer waits for it.
      await mesh.onSignal('z', 'dz', 'candidate', {'candidate': 'c1'});
      expect(engine.links.single.candidates, isEmpty);
      await mesh.onSignal('z', 'dz', 'answer', {'type': 'answer', 'sdp': offerSdp});
      expect(engine.links.single.calls, ['offer', 'local offer', 'remote answer']);
      expect(engine.links.single.candidates.single['candidate'], 'c1');
      engine.links.single.candidate!({'candidate': 'mine'});
      expect(sent.last.$3, 'candidate');
    });

    test('an offer is answered, and a signal from another device is not taken', () async {
      await mesh.onSignal('a', 'da', 'offer', {'type': 'offer', 'sdp': offerSdp});
      expect(sent.single.$3, 'answer');
      expect((sent.single.$4! as Map)['sdp'], contains('stereo=0'));
      await mesh.onSignal('a', 'other', 'candidate', {'candidate': 'x'});
      expect(engine.links.single.candidates, isEmpty);
      await mesh.onSignal('a', 'da', 'candidate', {'candidate': 'y'});
      expect(engine.links.single.candidates.single['candidate'], 'y');
    });

    test('two offers at once: the polite side gives way, the other ignores', () async {
      // 'm' is larger than 'a': polite.
      await mesh.connectTo('a', 'da');
      await mesh.onSignal('a', 'da', 'offer', {'type': 'offer', 'sdp': offerSdp});
      expect(engine.links.single.calls, [
        'offer',
        'local offer',
        'local rollback',
        'remote offer',
        'answer',
        'local answer',
      ]);
      // 'm' is smaller than 'z': impolite, keeps its own offer.
      await mesh.connectTo('z', 'dz');
      await mesh.onSignal('z', 'dz', 'offer', {'type': 'offer', 'sdp': offerSdp});
      expect(engine.links.last.calls, ['offer', 'local offer']);
    });

    test('a failed path is restarted by the impolite side', () async {
      await mesh.connectTo('z', 'dz');
      await mesh.onSignal('z', 'dz', 'answer', {'type': 'answer', 'sdp': offerSdp});
      final link = engine.links.single
        ..connectionState = 'failed'
        ..state!();
      await until(() => link.calls.contains('offer(restart)'));
      expect(sent.last.$3, 'offer');
    });

    test('speaking rings come from the levels, and muting stops mine', () async {
      await mesh.connectTo('z', 'dz');
      engine.links.single
        ..incoming = 0.2
        ..outgoing = 0.3;
      await mesh.measure();
      expect(mesh.peers.single.speaking, isTrue);
      expect(mesh.speaking, isTrue);
      mesh.talking = false;
      expect(engine.talking, isFalse);
      await mesh.measure();
      expect(mesh.speaking, isFalse);
    });

    test('leaving says bye to everyone and lets go of the microphone', () async {
      await mesh.connectTo('z', 'dz');
      await mesh.onSignal('a', 'da', 'offer', {'type': 'offer', 'sdp': offerSdp});
      sent.clear();
      await mesh.close();
      expect(sent.map((s) => (s.$1, s.$3)).toSet(), {('z', 'bye'), ('a', 'bye')});
      expect(engine.links.every((link) => link.closed), isTrue);
      expect(engine.stopped, isTrue);
    });
  });

  group('voice in the party', () {
    late FakeTogether server;
    late TogetherAccount account;
    late TogetherSocket socket;
    late Parties parties;
    late FakeEngine engine;
    late Voice voice;

    setUp(() async {
      server = await FakeTogether.start();
      final ana = server.person('u-ana', 'ana', 'Ana');
      server.inParty([ana]);
      server.callPeers['u-ana'] = 'device-ana';
      account = TogetherAccount(base: server.base, store: MemoryTokenStore(), clientName: 'launcher-linux/0.1.0');
      await account.startEmail('utku@example.com');
      await account.verifyEmail('123456');
      socket = TogetherSocket(account: account);
      parties = Parties(account: account, socket: socket);
      engine = FakeEngine();
      voice = Voice(
        account: account,
        socket: socket,
        parties: parties,
        engine: () => engine,
        measureEvery: const Duration(milliseconds: 20),
      );
      socket.start();
      await until(() => parties.party != null && socket.status == SocketStatus.ready);
    });

    tearDown(() async {
      voice.dispose();
      parties.dispose();
      socket.dispose();
      account.close();
      await server.close();
    });

    test('joining calls everyone already in, through the gateway, with the relays from the call', () async {
      await voice.join();
      expect(voice.active, isTrue);
      expect(server.callsTo('calls').single.body, {'partyId': parties.party!.id});
      final offer = await server.nextFrame('signal');
      expect(engine.ice!.single['urls'], ['stun:stun.example.org:3478']);
      expect(offer['to'], 'u-ana');
      expect(offer['device'], 'device-ana');
      expect(offer['kind'], 'offer');
      expect(offer['call'], voice.callId);
      expect((offer['data'] as Map)['sdp'], contains('usedtx=1'));

      server.push('signal', {
        'call': voice.callId,
        'from': 'u-ana',
        'device': 'device-ana',
        'kind': 'answer',
        'data': {'type': 'answer', 'sdp': offerSdp},
      });
      await until(() => engine.links.single.remote != null);

      server.push('call.ended', {'callId': voice.callId, 'partyId': parties.party!.id, 'reason': 'ended'});
      await until(() => !voice.active);
      expect(engine.links.single.closed, isTrue);
      expect(engine.stopped, isTrue);
    });

    test('deafened: nobody is heard, the microphone is off, the others are told; undeafened it is as before', () async {
      await voice.join();
      final mute = 'calls/${voice.callId}/mute';
      voice.setDeafened(true);
      expect(voice.deafened, isTrue);
      expect(voice.muted, isTrue);
      expect(engine.hearing, isFalse);
      expect(engine.talking, isFalse);
      await until(() => server.callsTo(mute).isNotEmpty);
      expect(server.callsTo(mute).last.body, {'muted': true, 'deafened': true});
      voice.setDeafened(false);
      expect(engine.hearing, isTrue);
      expect(voice.muted, isFalse, reason: 'the microphone was on before');
      expect(engine.talking, isTrue);
      await until(() => server.callsTo(mute).length == 2);
      expect(server.callsTo(mute).last.body, {'muted': false, 'deafened': false});

      // Muted first: undeafening keeps it muted; turning the microphone on undeafens.
      voice.setMuted(true);
      voice.setDeafened(true);
      voice.setDeafened(false);
      expect(voice.muted, isTrue);
      voice.setDeafened(true);
      voice.setMuted(false);
      expect(voice.deafened, isFalse);
      expect(engine.hearing, isTrue);
      expect(engine.talking, isTrue);

      // Out of the call: hearing comes back.
      voice.setDeafened(true);
      await voice.leave();
      expect(voice.deafened, isFalse);
      expect(voice.muted, isFalse);
    });

    test('the microphone off tells the others; push-to-talk sends only while the key is held', () async {
      await voice.join();
      expect(voice.sending, isTrue);
      voice.setMuted(true);
      expect(engine.talking, isFalse);
      await until(() => server.callsTo('calls/${voice.callId}/mute').isNotEmpty);
      expect(server.callsTo('calls/${voice.callId}/mute').single.body, {'muted': true, 'deafened': false});
      // Toggle mode: a press of the talk key turns it back on.
      voice.talkKey(true);
      voice.talkKey(false);
      expect(voice.muted, isFalse);
      expect(engine.talking, isTrue);

      voice.setPushToTalk(true);
      expect(engine.talking, isFalse);
      final keys = FakeKeys();
      final watch = TalkKeyWatch(reader: keys, onChange: voice.talkKey, every: const Duration(milliseconds: 5))
        ..start();
      keys.down.add(TalkKeys.standard);
      await until(() => engine.talking);
      expect(voice.sending, isTrue);
      keys.down.clear();
      await until(() => !engine.talking);
      watch.stop();
      expect(server.callsTo('calls/${voice.callId}/mute'), hasLength(2), reason: 'holds do not mute on the server');
    });

    test('joined on the phone: quiet here, still in the party, no goodbye and no leaving', () async {
      String? told;
      voice.onMoved = (client) => told = client;
      await voice.join();
      final id = voice.callId!;
      await server.nextFrame('signal');
      server.push('call.moved', {
        'callId': id,
        'partyId': parties.party!.id,
        'userId': 'u-me',
        'device': 'phone-session',
        'client': 'phone',
      });
      await until(() => !voice.active);
      expect(told, 'phone');
      expect(voice.movedTo, 'phone');
      expect(engine.stopped, isTrue);
      expect(engine.links.single.closed, isTrue);
      // The phone talks to everyone now: no bye from here, and the server is not told to leave.
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(server.frames.where((f) => f['op'] == 'signal' && f['kind'] == 'bye'), isEmpty);
      expect(server.callsTo('calls/$id/leave'), isEmpty);
      expect(parties.party, isNotNull);
      // Joining here again takes it back.
      await voice.join();
      expect(voice.active, isTrue);
      expect(voice.movedTo, isNull);
    });

    test('noise suppression opens the microphone as set and changes the call without reconnecting', () async {
      voice.noiseSuppression = false;
      await voice.join();
      expect(engine.noise, [false]);
      await server.nextFrame('signal');
      final callsBefore = server.callsTo('calls').length;
      await voice.setNoiseSuppression(true);
      expect(voice.noiseSuppression, isTrue);
      expect(engine.noise, [false, true]);
      // The same connection, no new offer, no new call.
      expect(engine.links, hasLength(1));
      expect(engine.links.single.closed, isFalse);
      expect(engine.links.single.calls.where((call) => call.startsWith('offer')), hasLength(1));
      expect(server.callsTo('calls'), hasLength(callsBefore));
      // The same value again changes nothing.
      await voice.setNoiseSuppression(true);
      expect(engine.noise, [false, true]);
      await voice.leave();
      // Out of voice it is only kept for the next call.
      await voice.setNoiseSuppression(false);
      expect(engine.noise, [false, true]);
    });

    test('the microphone keeps echo cancellation and gain whichever way noise suppression is', () {
      expect(voiceAudioConstraints(noiseSuppression: true), {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
      });
      expect(voiceAudioConstraints(noiseSuppression: false)['noiseSuppression'], isFalse);
      expect(voiceAudioConstraints(noiseSuppression: false)['echoCancellation'], isTrue);
    });

    test('call.updated marks who muted themselves in the party', () async {
      await voice.join();
      server.push('call.updated', {
        'callId': voice.callId,
        'partyId': parties.party!.id,
        'userId': 'u-ana',
        'muted': true,
      });
      await until(() => parties.party!.muted.contains('u-ana'));
      server.push('call.updated', {
        'callId': voice.callId,
        'partyId': parties.party!.id,
        'userId': 'u-ana',
        'muted': false,
      });
      await until(() => !parties.party!.muted.contains('u-ana'));
    });

    test('leaving tells the server; no microphone, no voice', () async {
      await voice.join();
      final id = voice.callId;
      await voice.leave();
      expect(server.callsTo('calls/$id/leave'), hasLength(1));
      engine = FakeEngine(deny: true);
      await voice.join();
      expect(voice.active, isFalse);
      expect(voice.problem, VoiceProblem.microphone);
    });
  });

  test('talk keys: letters, digits, F keys and modifiers, as Windows and X11 name them', () {
    expect(TalkKeys.virtualKey(TalkKeys.standard), 0x56); // V
    expect(TalkKeys.keysym(TalkKeys.standard), 0x76); // v
    expect(TalkKeys.virtualKey(0x3A), 0x70); // F1
    expect(TalkKeys.keysym(0x45), 0xFFC9); // F12
    expect(TalkKeys.virtualKey(0x1E), 0x31); // 1
    expect(TalkKeys.keysym(0xE6), 0xFFEA); // Right Alt
    expect(TalkKeys.supported(0x4F), isFalse, reason: 'arrows move the launcher');
  });
}
