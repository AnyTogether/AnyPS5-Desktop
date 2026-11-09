import 'package:anyps5_desktop/core/together/talk_key.dart';
import 'package:anyps5_desktop/core/together/voice_mesh.dart';

/// A microphone and peer connections for the tests: offers and answers with an Opus line, what
/// was set, and levels a test chooses.
class FakeVoiceEngine implements VoiceEngine {
  FakeVoiceEngine({this.deny = false});

  final bool deny;
  bool started = false;
  bool stopped = false;
  final List<bool> talking = [];
  final List<FakeLink> links = [];
  List<Map<String, dynamic>>? iceServers;

  /// The noise suppression the microphone opened with, then each change in the call.
  final List<bool> noiseSuppression = [];

  @override
  Future<void> start({bool noiseSuppression = true}) async {
    if (deny) throw const VoiceDenied();
    started = true;
    this.noiseSuppression.add(noiseSuppression);
  }

  @override
  Future<void> setNoiseSuppression(bool on) async => noiseSuppression.add(on);

  @override
  Future<VoiceLink> link(List<Map<String, dynamic>> iceServers) async {
    this.iceServers = iceServers;
    final link = FakeLink();
    links.add(link);
    return link;
  }

  @override
  void setTalking(bool on) => talking.add(on);

  /// What deafening and undeafening set, in turn.
  final List<bool> hearing = [];

  @override
  void setHearing(bool on) => hearing.add(on);

  @override
  Future<void> stop() async => stopped = true;
}

class FakeLink implements VoiceLink {
  static const sdp = 'v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=rtpmap:111 opus/48000/2\r\n';

  @override
  String signalingState = 'stable';
  @override
  String connectionState = 'new';
  @override
  bool hasRemote = false;
  Map<String, dynamic>? local;
  Map<String, dynamic>? remote;
  final List<Map<String, dynamic>> candidates = [];
  double incoming = 0;
  double outgoing = 0;
  bool closed = false;
  void Function()? stateChanged;

  @override
  Future<Map<String, dynamic>> createOffer({bool restart = false}) async => {'type': 'offer', 'sdp': sdp};

  @override
  Future<Map<String, dynamic>> createAnswer() async => {'type': 'answer', 'sdp': sdp};

  @override
  Future<void> setLocal(Map<String, dynamic> description) async {
    local = description;
    signalingState = description['type'] == 'offer' ? 'have-local-offer' : 'stable';
  }

  @override
  Future<void> setRemote(Map<String, dynamic> description) async {
    remote = description;
    hasRemote = true;
    signalingState = description['type'] == 'offer' ? 'have-remote-offer' : 'stable';
  }

  @override
  Future<void> addCandidate(Map<String, dynamic> candidate) async => candidates.add(candidate);

  @override
  Future<({double incoming, double outgoing})> levels() async => (incoming: incoming, outgoing: outgoing);

  @override
  set onCandidate(void Function(Map<String, dynamic> candidate) handler) {}

  @override
  set onState(void Function() handler) => stateChanged = handler;

  @override
  Future<void> close() async => closed = true;
}

/// Keys a test holds down.
class FakeKeys extends KeyStateReader {
  final Set<int> down = {};

  @override
  bool isDown(int usage) => down.contains(usage);
}
