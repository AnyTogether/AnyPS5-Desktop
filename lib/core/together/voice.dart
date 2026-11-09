import 'dart:async';

import 'account.dart';
import 'media.dart';
import 'notifier.dart';
import 'parties.dart';
import 'people.dart';
import 'socket.dart';
import 'voice_mesh.dart';

enum VoiceProblem { microphone, failed }

/// Voice in the party, the way the website does it: the call from /calls with its ICE servers
/// (renewed from /ice-servers before they run out), the offers and candidates through the
/// gateway, a mesh of peer connections. The microphone sends while it is on, or, with
/// push-to-talk, while the talk key is held; turning it off tells the others (call.updated).
/// A party call with more voices than the mesh holds goes through the server's media server
/// instead ("sfu", from the join answer, call.media or the party): the mesh closes and everyone
/// talks in one room there.
class Voice with Notifier {
  Voice({
    required this.account,
    required this.socket,
    required this.parties,
    required this.engine,
    this.sfuRoom,
    this.measureEvery = const Duration(milliseconds: 250),
  }) {
    _events = socket.events.listen(_event);
    parties.addListener(_partyChanged);
  }

  final TogetherAccount account;
  final TogetherSocket socket;
  final Parties parties;

  /// Makes the microphone and the connections (flutter_webrtc in the launcher, fakes in tests).
  final VoiceEngine Function() engine;

  /// Makes a media server room (LiveKit in the launcher); none, and a call on the media server
  /// cannot be joined.
  final SfuRoom Function()? sfuRoom;
  final Duration measureEvery;
  late final StreamSubscription<TogetherEvent> _events;

  VoiceMesh? _mesh;

  /// The media server room while the call goes through it.
  SfuRoom? _room;

  /// Between the mesh closing and the room taking over.
  bool _moving = false;
  Timer? _levels;
  Timer? _renew;
  String? callId;
  String? _partyId;
  bool joining = false;

  /// The microphone is off (the others see it muted).
  bool muted = false;

  /// Nobody in the call is heard and the microphone is off; undeafened, the microphone is as it
  /// was before. The others see it (call.updated).
  bool deafened = false;
  bool _mutedBefore = false;

  /// Push-to-talk: the microphone sends only while [held].
  bool pushToTalk = false;

  /// WebRTC's noise suppression on the microphone; changes the call in progress too.
  bool noiseSuppression = true;
  bool held = false;
  VoiceProblem? problem;

  /// The voice moved to another of the user's devices (the phone, while it is the controller):
  /// the client there ("phone", "web", a launcher). Joining here again takes it back.
  String? movedTo;

  /// Told when the voice moves away, with [movedTo].
  void Function(String client)? onMoved;

  /// The friend in a call with one friend (null in the party's voice), and whether it still
  /// rings on their side.
  Person? friend;
  bool waiting = false;

  /// Who else in the call muted or deafened themselves, as the join and call.updated say.
  Set<String> mutedOthers = {};
  Set<String> deafenedOthers = {};

  /// A call with a friend ended by the server: declined, given up or hung up on their side.
  void Function(Person friend, String? reason)? onCallEnded;

  /// The friend picked up.
  void Function(Person friend)? onAnswered;

  bool get active => _mesh != null || _room != null || _moving;

  /// The call goes through the media server.
  bool get viaServer => _room != null || _moving;

  bool get _wantsMic => !muted && (!pushToTalk || held);

  /// Whether the microphone goes to the others now.
  bool get sending => active && _wantsMic;

  /// This launcher's microphone is heard right now.
  bool get speaking {
    final room = _room;
    if (room != null) return sending && room.speaking.contains(account.user?.id);
    return sending && (_mesh?.speaking ?? false);
  }

  List<PeerVoice> get peers {
    final room = _room;
    if (room == null) return _mesh?.peers ?? const [];
    return [for (final userId in room.participants) PeerVoice(userId, 'connected', room.speaking.contains(userId))];
  }

  bool speakingOf(String userId) => peers.any((peer) => peer.userId == userId && peer.speaking);

  /// Joins the party's voice (starting it if no one talks yet).
  Future<void> join() async {
    final party = parties.party;
    if (party == null) return;
    try {
      await _start(() => account.call('POST', 'calls', {'partyId': party.id}), partyId: party.id);
    } on Object {
      // Said through [problem].
    }
  }

  /// Rings [person] (POST /calls with their user ID): the call is joined here already and waits
  /// for them to answer, as the Mac's Call. Throws what refused it ([problem] says the
  /// microphone).
  Future<void> callFriend(Person person) =>
      _start(() => account.call('POST', 'calls', {'userId': person.id}), friend: person, waiting: true);

  /// A ringing call answered on this device (refused with conflict, 409, when another of the
  /// user's devices answered first).
  Future<void> answer(String id, Person from) =>
      _start(() => account.call('POST', 'calls/$id/answer', {}), friend: from);

  /// A ringing call declined: it ends for the caller too.
  Future<void> decline(String id) => account.call('POST', 'calls/$id/decline', {});

  /// Into a call the server joined: the party's ([partyId]) or one with [friend]; the microphone
  /// first, then the media server's room or the mesh with everyone already in.
  Future<void> _start(
    Future<Map<String, dynamic>> Function() post, {
    String? partyId,
    Person? friend,
    bool waiting = false,
  }) async {
    final me = account.user?.id;
    if (me == null || joining || active) return;
    joining = true;
    problem = null;
    movedTo = null;
    notifyListeners();
    final engine = this.engine();
    try {
      await engine.start(noiseSuppression: noiseSuppression);
    } on Object {
      problem = VoiceProblem.microphone;
      joining = false;
      notifyListeners();
      throw const VoiceDenied();
    }
    try {
      final joined = await post();
      final call = joined['call'] as Map<String, dynamic>;
      final id = call['id'] as String;
      this.friend = friend;
      this.waiting = waiting;
      final members = [
        for (final peer in call['in'] as List<dynamic>? ?? const [])
          if (peer is Map && peer['userId'] is String) peer,
      ];
      mutedOthers = {
        for (final peer in members)
          if (peer['muted'] == true || peer['deafened'] == true) peer['userId'] as String,
      };
      deafenedOthers = {
        for (final peer in members)
          if (peer['deafened'] == true) peer['userId'] as String,
      };
      if (partyId != null && MediaRoute.parse(call['media']) == MediaRoute.sfu) {
        // The media server's SDK takes the microphone itself.
        await engine.stop();
        callId = id;
        _partyId = partyId;
        try {
          await _enterRoom(id, SfuAccess.fromJson(joined['sfu']));
        } on Object {
          await leave();
          rethrow;
        }
        if (muted || deafened) unawaited(_tellMuted());
        return;
      }
      final mesh = VoiceMesh(
        me: me,
        engine: engine,
        iceServers: _servers(joined['iceServers']),
        signal: (to, device, kind, data) =>
            socket.send({'op': 'signal', 'to': to, 'device': device, 'call': id, 'kind': kind, 'data': data}),
        onChange: notifyListeners,
      );
      _mesh = mesh;
      callId = id;
      _partyId = partyId;
      if (deafened) engine.setHearing(false);
      _apply();
      _levels = Timer.periodic(measureEvery, (_) => unawaited(mesh.measure()));
      _renewBefore(joined['expiresAt']);
      if (muted || deafened) unawaited(_tellMuted());
      // The newcomer calls everyone already in.
      for (final peer in (call['in'] as List<dynamic>? ?? const [])) {
        if (peer is! Map) continue;
        final userId = peer['userId'] as String;
        if (userId != me) unawaited(mesh.connectTo(userId, peer['device'] as String).catchError((Object _) {}));
      }
    } on Object {
      await engine.stop();
      if (callId == null) {
        this.friend = null;
        this.waiting = false;
      }
      problem = VoiceProblem.failed;
      rethrow;
    } finally {
      joining = false;
      notifyListeners();
    }
  }

  /// Joins the call's media server room ([given] while its token is fresh, else a fresh one)
  /// with the microphone published, muted or not.
  Future<void> _enterRoom(String id, SfuAccess? given) async {
    final make = sfuRoom;
    if (make == null) throw StateError('No media server client');
    final access = given != null && given.fresh() ? given : await MediaServerClient(account).call(id);
    final room = make();
    try {
      await room.connect(access);
      await room.publishMicrophone(enabled: _wantsMic);
    } on Object {
      await room.leave().catchError((Object _) {});
      rethrow;
    }
    if (callId != id) {
      await room.leave().catchError((Object _) {});
      return;
    }
    room.onChange = notifyListeners;
    _room = room;
    if (deafened) unawaited(room.setHearing(false).catchError((Object _) {}));
    notifyListeners();
  }

  /// The call moved to the media server: every mesh connection closes (and its signals go
  /// unanswered from now on), and the room takes over.
  Future<void> _moveToServer() async {
    final mesh = _mesh;
    final id = callId;
    if (mesh == null || id == null || _moving) return;
    _moving = true;
    _mesh = null;
    _levels?.cancel();
    _renew?.cancel();
    notifyListeners();
    await mesh.close().catchError((Object _) {});
    try {
      await _enterRoom(id, null);
    } on Object {
      problem = VoiceProblem.failed;
      _moving = false;
      await leave();
      return;
    }
    _moving = false;
    notifyListeners();
  }

  static List<Map<String, dynamic>> _servers(Object? list) => [
    for (final server in (list as List<dynamic>? ?? const [])) Map<String, dynamic>.from(server as Map),
  ];

  /// Out of the voice; the server is told unless it already knows (the party or call ended).
  Future<void> leave({bool tell = true}) async {
    final id = callId;
    await _stop();
    if (tell && id != null) {
      try {
        await account.call('POST', 'calls/$id/leave');
      } on Object {
        // The call ends for the others when this launcher stops answering.
      }
    }
  }

  /// Fresh relay credentials ten minutes before these run out (a call can outlast them).
  void _renewBefore(Object? expiresAt) {
    final expiry = DateTime.tryParse(expiresAt as String? ?? '');
    _renew?.cancel();
    if (expiry == null) return;
    final wait = expiry.difference(DateTime.now()) - const Duration(minutes: 10);
    _renew = Timer(wait.isNegative ? Duration.zero : wait, () async {
      try {
        final fresh = await account.call('GET', 'ice-servers');
        _mesh?.iceServers = _servers(fresh['iceServers']);
        if (_mesh != null) _renewBefore(fresh['expiresAt']);
      } on Object {
        // The ones held still work until they expire.
      }
    });
  }

  /// The microphone off or on; the others are told. On while deafened undeafens.
  void setMuted(bool on) {
    if (deafened) {
      // Off already; on hears everyone again.
      if (on) return;
      _hear(true);
    } else if (muted == on) {
      return;
    }
    muted = on;
    _apply();
    if (active) unawaited(_tellMuted());
  }

  /// Deafened: nobody is heard and the microphone is off; undeafened, the microphone is as it was
  /// before. The others are told.
  void setDeafened(bool on) {
    if (deafened == on) return;
    if (on) {
      _mutedBefore = muted;
      muted = true;
    } else {
      muted = _mutedBefore;
    }
    _hear(!on);
    _apply();
    if (active) unawaited(_tellMuted());
  }

  /// The others heard or not, on every connection and in the media server's room.
  void _hear(bool on) {
    deafened = !on;
    _mesh?.engine.setHearing(on);
    final room = _room;
    if (room != null) unawaited(room.setHearing(on).catchError((Object _) {}));
  }

  Future<void> _tellMuted() async {
    final id = callId;
    if (id == null) return;
    try {
      await account.call('POST', 'calls/$id/mute', {'muted': muted, 'deafened': deafened});
    } on Object {
      // Only the mute mark is lost; the microphone itself is off.
    }
  }

  /// Noise suppression on or off, in the call now too (nothing reconnects).
  Future<void> setNoiseSuppression(bool on) async {
    if (noiseSuppression == on) return;
    noiseSuppression = on;
    notifyListeners();
    try {
      await _mesh?.engine.setNoiseSuppression(on);
    } on Object {
      // The microphone keeps the processing it had; the next call takes the new one.
    }
  }

  void setPushToTalk(bool on) {
    pushToTalk = on;
    held = false;
    _apply();
  }

  /// The talk key: held to talk with push-to-talk, else a press turns the microphone on and off.
  void talkKey(bool pressed) {
    if (pushToTalk) {
      if (held == pressed) return;
      held = pressed;
      _apply();
    } else if (pressed) {
      setMuted(!muted);
    }
  }

  void _apply() {
    _mesh?.talking = sending;
    final room = _room;
    if (room != null) unawaited(room.setMicrophone(sending).catchError((Object _) {}));
    notifyListeners();
  }

  Future<void> _stop({bool sayBye = true}) async {
    final mesh = _mesh;
    final room = _room;
    _mesh = null;
    _room = null;
    room?.onChange = null;
    callId = null;
    _partyId = null;
    friend = null;
    waiting = false;
    mutedOthers = {};
    deafenedOthers = {};
    held = false;
    // Out of the call: hearing comes back, and the microphone is as it was before deafening.
    if (deafened) {
      deafened = false;
      muted = _mutedBefore;
    }
    _levels?.cancel();
    _renew?.cancel();
    notifyListeners();
    await mesh?.close(sayBye: sayBye);
    await room?.leave().catchError((Object _) {});
  }

  /// Out of the party, out of its voice: the server took this launcher out of the call already.
  void _partyChanged() {
    // A call with a friend is no party's.
    if (!active || _partyId == null) return;
    final party = parties.party;
    if (party == null || party.id != _partyId) {
      unawaited(_stop());
    } else if (party.callId == callId && party.callMedia == MediaRoute.sfu) {
      unawaited(_moveToServer());
    }
  }

  void _event(TogetherEvent event) {
    final mesh = _mesh;
    final data = event.json;
    if (!active) return;
    switch (event.type) {
      case 'call.media' when data['callId'] == callId && MediaRoute.parse(data['media']) == MediaRoute.sfu:
        unawaited(_moveToServer());
      case 'signal' when mesh != null && data['call'] == callId:
        unawaited(
          mesh
              .onSignal(data['from'] as String, data['device'] as String, data['kind'] as String, data['data'])
              .catchError((Object _) {}),
        );
      case 'call.left' when mesh != null && data['callId'] == callId:
        unawaited(mesh.drop(data['userId'] as String, sayBye: false).catchError((Object _) {}));
      case 'call.answered' when data['callId'] == callId && data['userId'] != account.user?.id && waiting:
        waiting = false;
        notifyListeners();
        if (friend case final Person person) onAnswered?.call(person);
      case 'call.updated' when data['callId'] == callId && data['userId'] is String:
        final userId = data['userId'] as String;
        if (data['muted'] == true) {
          mutedOthers = {...mutedOthers, userId};
        } else {
          mutedOthers = {...mutedOthers}..remove(userId);
        }
        if (data['deafened'] == true) {
          deafenedOthers = {...deafenedOthers, userId};
        } else {
          deafenedOthers = {...deafenedOthers}..remove(userId);
        }
        notifyListeners();
      case 'call.ended' when data['callId'] == callId:
        final person = friend;
        unawaited(_stop());
        if (person != null) onCallEnded?.call(person, data['reason'] as String?);
      // Joined on another device: quiet here and still in the party, so the same voice never
      // comes out of two devices. That device talks to everyone now: no goodbye from here.
      case 'call.moved' when data['callId'] == callId:
        final client = data['client'] as String? ?? '';
        movedTo = client;
        unawaited(_stop(sayBye: false));
        onMoved?.call(client);
    }
  }

  void dispose() {
    unawaited(_events.cancel());
    parties.removeListener(_partyChanged);
    unawaited(_stop());
  }
}
