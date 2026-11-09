part of 'together_model.dart';

/// A friend calling this user (call.ringing): the call, who, and the device they call from.
class Ringing {
  const Ringing({required this.callId, required this.from, this.device = ''});

  static Ringing? fromJson(Map<String, dynamic> json) {
    final id = json['callId'];
    final from = json['from'];
    if (id is! String || from is! Map<String, dynamic>) return null;
    try {
      return Ringing(callId: id, from: Person.fromJson(from), device: json['device'] as String? ?? '');
    } on Object {
      return null;
    }
  }

  final String callId;
  final Person from;
  final String device;
}

/// Calls with one friend: the call ringing here, how long it has rung, and the keys that answer
/// it over a game.
class CallState {
  Ringing? ringing;
  Timer? ringTimer;
  Timer? keyTimer;
  Timer? noAnswer;
  DateTime? ringSince;
}

/// Calls with one friend on AnyTogether, as on the Mac. A call to the user rings: a card in the
/// launcher, or over a game a desktop notice with Alt+A to answer and Alt+D to decline;
/// unanswered, it gives up after a while and says it was missed. The user calls an online friend
/// from the Friends panel and hangs up there. The voice is the party's (the same mesh,
/// microphone, deafen and push-to-talk).
extension TogetherCalls on TogetherModel {
  /// How long a call rings before it counts as not answered (the Mac's TogetherVoice.ringFor).
  static const ringFor = Duration(seconds: 45);

  /// How often the ring sounds while it rings.
  static const ringEvery = Duration(milliseconds: 2400);

  /// Over a game: Alt with A answers, Alt with D declines (HID usages).
  static const altKeys = [0xE2, 0xE6];
  static const answerKey = 0x04;
  static const declineKey = 0x07;

  Ringing? get ringing => calls.ringing;

  /// call.ringing, call.answered and call.ended for a call with one friend.
  void callEvent(TogetherEvent event) {
    final data = event.json;
    switch (event.type) {
      case 'call.ringing':
        final call = Ringing.fromJson(data);
        if (call == null || call.callId == hub.voice.callId) return;
        ring(call);
      case 'call.answered':
        // Answered on another of the user's devices.
        if (ringing?.callId == data['callId'] && data['userId'] == user?.id) stopRinging();
      case 'call.ended':
        final call = ringing;
        if (call == null || call.callId != data['callId']) return;
        stopRinging();
        // Declined here or on another device says nothing; the caller giving up is a missed call.
        if (data['reason'] != 'declined') missedCall(call.from);
    }
  }

  /// Rings until answered, declined, or long enough to count as not answered.
  void ring(Ringing call) {
    if (!family.voiceAllowed) return;
    stopRinging();
    calls
      ..ringing = call
      ..ringSince = DateTime.now();
    void sound() {
      app.sounds.play(Cue.ring);
      app.vibrate(HapticCue.ring);
    }

    sound();
    calls.ringTimer = Timer.periodic(ringEvery, (timer) {
      if (calls.ringing?.callId != call.callId) return timer.cancel();
      if (DateTime.now().difference(calls.ringSince!) >= ringFor) {
        // Not answered: it ends for the caller too.
        declineRinging(quiet: true);
        missedCall(call.from);
        return;
      }
      sound();
    });
    // Over a game: a desktop notice, and the keys that answer without leaving it.
    if (!app.launcherInFront) {
      final reader = talkWatch?.reader;
      // The card (the Mac's), the ring already sounding: no sound of its own.
      unawaited(
        app.noticeOverGame(
          T.format('callIsCalling', [TogetherModel.shown(call.from).name]),
          detail: reader == null ? '@${call.from.handle}' : T.text('callKeys'),
          symbol: Icons.call_rounded,
          sound: false,
        ),
      );
      if (reader != null) {
        calls.keyTimer = Timer.periodic(const Duration(milliseconds: 40), (_) {
          if (!altKeys.any(reader.isDown)) return;
          if (reader.isDown(answerKey)) unawaited(acceptRinging());
          if (reader.isDown(declineKey)) declineRinging();
        });
      }
    }
    app.refresh();
  }

  void stopRinging() {
    calls.ringTimer?.cancel();
    calls.keyTimer?.cancel();
    calls
      ..ringTimer = null
      ..keyTimer = null;
    if (calls.ringing == null) return;
    calls.ringing = null;
    app.refresh();
  }

  void missedCall(Person from) {
    final text = T.format('callMissed', [TogetherModel.shown(from).name]);
    app.show(text);
    unawaited(app.noticeOverGame(text, detail: '@${from.handle}', symbol: Icons.call_missed_rounded));
  }

  /// Answered here: out of any other voice, into this call.
  Future<void> acceptRinging() async {
    final call = ringing;
    if (call == null) return;
    stopRinging();
    if (hub.voice.active) await hub.voice.leave();
    try {
      await hub.voice.answer(call.callId, call.from);
      app.sounds.play(Cue.select);
      app.show(T.format('callWith', [TogetherModel.shown(call.from).name]));
    } on VoiceDenied {
      unawaited(hub.voice.decline(call.callId).catchError((Object _) {}));
      app.show(T.text('voiceNoMic'));
    } on TogetherProblem catch (problem) {
      app.show(problem.status == 409 ? T.text('callAnsweredElsewhere') : message(problem));
    } on Object catch (error) {
      app.show(message(error));
    }
  }

  void declineRinging({bool quiet = false}) {
    final call = ringing;
    if (call == null) return;
    stopRinging();
    if (!quiet) app.sounds.play(Cue.back);
    unawaited(hub.voice.decline(call.callId).catchError((Object _) {}));
  }

  /// Rings the friend; the call is joined here already and waits for them to answer.
  Future<void> startCall(Person person) async {
    if (!signedIn || !family.voiceAllowed) return;
    if (hub.voice.active) await hub.voice.leave();
    try {
      await hub.voice.callFriend(person);
      app.sounds.play(Cue.select);
      app.show(T.format('callCalling', [TogetherModel.shown(person).name]));
      final call = hub.voice.callId;
      calls.noAnswer?.cancel();
      calls.noAnswer = Timer(ringFor + const Duration(seconds: 5), () {
        if (hub.voice.callId != call || !hub.voice.waiting) return;
        unawaited(hub.voice.leave());
        app.show(T.format('callNoAnswer', [TogetherModel.shown(person).name]));
      });
    } on VoiceDenied {
      app.show(T.text('voiceNoMic'));
    } on Object catch (error) {
      app.show(message(error));
    }
    app.refresh();
  }

  /// What the server said of a call with a friend: they picked up, or it ended.
  void callAnswered(Person friend) {
    app.show(T.format('callWith', [TogetherModel.shown(friend).name]));
  }

  void callEnded(Person friend, String? reason) {
    calls.noAnswer?.cancel();
    app.show(T.format(reason == 'declined' ? 'callDeclined' : 'callEnded', [TogetherModel.shown(friend).name]));
  }

  /// The Friends panel's rows while in a call with a friend: who, then the microphone, deafen,
  /// push-to-talk and hanging up.
  List<PanelRow> callRows() {
    final voice = hub.voice;
    final friend = voice.friend;
    if (friend == null || !voice.active) return const [];
    final speaking = voice.speakingOf(friend.id);
    final details = [
      if (voice.deafenedOthers.contains(friend.id))
        T.text('joinDeafened')
      else if (voice.mutedOthers.contains(friend.id))
        T.text('voiceMuted'),
      if (speaking) T.text('voiceSpeaking'),
    ];
    return [
      PanelRow(
        id: 'call-${friend.id}',
        title: T.format(voice.waiting ? 'callCalling' : 'callWith', [TogetherModel.shown(friend).name]),
        detail: details.isEmpty ? '@${friend.handle}' : details.join(' · '),
        person: TogetherModel.card(friend, status: voice.waiting ? null : PersonStatus.online, speaking: speaking),
        kind: const InfoRow(''),
      ),
      ...voiceControlRows(),
    ];
  }

  /// Online friends can be called, unless the user is in a call with them already.
  PanelRow? callRow(Friend friend) {
    if (friend.presence.state == PresenceState.offline || !family.voiceAllowed) return null;
    if (hub.voice.friend?.id == friend.person.id) return null;
    return PanelRow(
      id: 'friend-call-${friend.person.id}',
      title: T.format('callFriend', [TogetherModel.shown(friend.person).name]),
      kind: ActionRow(() => unawaited(startCall(friend.person))),
    );
  }
}
