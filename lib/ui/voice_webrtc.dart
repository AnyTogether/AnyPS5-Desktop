import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../core/together/voice_mesh.dart';

/// Voice with flutter_webrtc on Windows and Linux: the microphone with WebRTC's echo
/// cancellation, gain and (unless turned off) noise suppression, the others on the default
/// output, and one RTCPeerConnection per member.
class WebRtcVoice implements VoiceEngine {
  MediaStream? _stream;
  final List<_Link> _links = [];
  bool _talking = true;

  static Future<MediaStream> _microphone(bool noiseSuppression) => navigator.mediaDevices.getUserMedia({
    'audio': voiceAudioConstraints(noiseSuppression: noiseSuppression),
    'video': false,
  });

  /// The connections made, for deafening: the others' sound is turned off on each.
  final List<RTCPeerConnection> _connections = [];
  bool _hearing = true;

  @override
  Future<void> start({bool noiseSuppression = true}) async {
    try {
      _stream = await _microphone(noiseSuppression);
    } on Object {
      throw const VoiceDenied();
    }
    if (_stream!.getAudioTracks().isEmpty) {
      await stop();
      throw const VoiceDenied();
    }
  }

  @override
  Future<VoiceLink> link(List<Map<String, dynamic>> iceServers) async {
    final pc = await createPeerConnection({'iceServers': iceServers, 'sdpSemantics': 'unified-plan'});
    _connections.add(pc);
    // A voice that comes while deafened stays unheard.
    pc.onTrack = (event) {
      if (event.track.kind == 'audio') event.track.enabled = _hearing;
    };
    final stream = _stream;
    if (stream != null) {
      for (final track in stream.getAudioTracks()) {
        await pc.addTrack(track, stream);
      }
    }
    final link = _Link(pc, _links.remove);
    _links.add(link);
    return link;
  }

  @override
  void setTalking(bool on) {
    _talking = on;
    for (final track in _stream?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      track.enabled = on;
    }
  }

  /// A remote audio track turned off is not played (WebRTC sets its output to nothing).
  @override
  void setHearing(bool on) {
    _hearing = on;
    _connections.removeWhere((pc) => pc.connectionState == RTCPeerConnectionState.RTCPeerConnectionStateClosed);
    for (final pc in _connections) {
      unawaited(
        pc
            .getReceivers()
            .then((receivers) {
              for (final receiver in receivers) {
                final track = receiver.track;
                if (track != null && track.kind == 'audio') track.enabled = on;
              }
            })
            .catchError((Object _) {}),
      );
    }
  }

  /// The audio processing is the source's, set when the microphone opens: a new microphone
  /// stream with the other setting, its track put on every sender in place of the old one.
  @override
  Future<void> setNoiseSuppression(bool on) async {
    final old = _stream;
    if (old == null) return;
    final fresh = await _microphone(on);
    final tracks = fresh.getAudioTracks();
    if (tracks.isEmpty) {
      await fresh.dispose();
      return;
    }
    final track = tracks.first..enabled = _talking;
    for (final link in _links) {
      for (final sender in await link.pc.getSenders()) {
        if (sender.track?.kind == 'audio') await sender.replaceTrack(track);
      }
    }
    _stream = fresh;
    for (final previous in old.getTracks()) {
      await previous.stop();
    }
    await old.dispose();
  }

  @override
  Future<void> stop() async {
    _connections.clear();
    final stream = _stream;
    _stream = null;
    _links.clear();
    if (stream != null) {
      for (final track in stream.getTracks()) {
        await track.stop();
      }
      await stream.dispose();
    }
  }
}

class _Link implements VoiceLink {
  _Link(this.pc, this._closed) {
    pc.onConnectionState = (_) => _onState?.call();
  }

  final RTCPeerConnection pc;

  /// Tells the engine this connection is gone, so a new microphone track skips it.
  final bool Function(_Link) _closed;
  void Function()? _onState;

  /// Kept here, not read from the plugin, which hears of changes a moment late.
  String _signaling = 'stable';
  bool _hasRemote = false;

  @override
  set onCandidate(void Function(Map<String, dynamic>) handler) => pc.onIceCandidate = (candidate) {
    if (candidate.candidate != null) handler(Map<String, dynamic>.from(candidate.toMap() as Map));
  };

  @override
  set onState(void Function() handler) => _onState = handler;

  @override
  String get signalingState => _signaling;

  @override
  bool get hasRemote => _hasRemote;

  @override
  String get connectionState => switch (pc.connectionState) {
    RTCPeerConnectionState.RTCPeerConnectionStateConnecting => 'connecting',
    RTCPeerConnectionState.RTCPeerConnectionStateConnected => 'connected',
    RTCPeerConnectionState.RTCPeerConnectionStateDisconnected => 'disconnected',
    RTCPeerConnectionState.RTCPeerConnectionStateFailed => 'failed',
    RTCPeerConnectionState.RTCPeerConnectionStateClosed => 'closed',
    _ => 'new',
  };

  @override
  Future<Map<String, dynamic>> createOffer({bool restart = false}) async {
    if (restart) await pc.restartIce();
    final offer = await pc.createOffer({'offerToReceiveAudio': true, 'offerToReceiveVideo': false});
    return {'type': offer.type, 'sdp': offer.sdp};
  }

  @override
  Future<Map<String, dynamic>> createAnswer() async {
    final answer = await pc.createAnswer();
    return {'type': answer.type, 'sdp': answer.sdp};
  }

  @override
  Future<void> setLocal(Map<String, dynamic> description) async {
    final type = description['type'] as String?;
    await pc.setLocalDescription(RTCSessionDescription(description['sdp'] as String?, type));
    _signaling = type == 'offer' ? 'have-local-offer' : 'stable';
  }

  @override
  Future<void> setRemote(Map<String, dynamic> description) async {
    final type = description['type'] as String?;
    await pc.setRemoteDescription(RTCSessionDescription(description['sdp'] as String?, type));
    _hasRemote = true;
    _signaling = type == 'offer' ? 'have-remote-offer' : 'stable';
  }

  @override
  Future<void> addCandidate(Map<String, dynamic> candidate) => pc.addCandidate(
    RTCIceCandidate(
      candidate['candidate'] as String?,
      candidate['sdpMid'] as String?,
      (candidate['sdpMLineIndex'] as num?)?.toInt(),
    ),
  );

  @override
  Future<({double incoming, double outgoing})> levels() async {
    double incoming = 0;
    double outgoing = 0;
    for (final report in await pc.getStats()) {
      final values = report.values;
      final level = (values['audioLevel'] as num?)?.toDouble();
      if (level == null) continue;
      final kind = values['kind'] ?? values['mediaType'];
      if (report.type == 'inbound-rtp' && kind == 'audio') {
        incoming = level;
      } else if (report.type == 'media-source' && kind == 'audio') {
        outgoing = level;
      } else if (report.type == 'track') {
        // Older stats: one per track, the remote one marked as such.
        if (values['remoteSource'] == true) {
          incoming = level;
        } else {
          outgoing = level;
        }
      }
    }
    return (incoming: incoming, outgoing: outgoing);
  }

  @override
  Future<void> close() async {
    _onState = null;
    _closed(this);
    await pc.close();
  }
}
