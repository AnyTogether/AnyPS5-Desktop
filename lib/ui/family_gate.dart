import 'dart:async';

import 'package:flutter/material.dart' show Icons;

import '../core/family/family_cache.dart';
import '../core/family/family_policy.dart';
import '../core/family/family_rules.dart';
import '../core/family/play_time_session.dart';
import '../core/game_library.dart';
import '../core/together/family.dart';
import 'app_model.dart';
import 'strings.dart';
import 'together_model.dart';

/// Family limits in the launcher: the last verified status from AnyTogether (kept offline, even
/// signed out), the age lock on games, the play time of the running game with its warnings, the
/// notice and the close, asking a parent, and which social features are on.
class FamilyGate {
  FamilyGate(this.together) : cache = FamilyCache(FamilyCache.defaultFile(together.app.paths.config)) {
    client = FamilyClient(together.account);
  }

  final TogetherModel together;
  final FamilyCache cache;
  late final FamilyClient client;

  AppModel get app => together.app;

  /// A card over the game as on the Mac, or a notice on the desktop (replaced in tests).
  late void Function(String title, String body) notify = (title, body) =>
      unawaited(app.noticeOverGame(body, symbol: Icons.hourglass_bottom_rounded));

  /// The clock (replaced in tests).
  DateTime Function() now = DateTime.now;

  /// How often the status is fetched again while signed in.
  static const refreshEvery = Duration(minutes: 5);

  /// How long a start waits for a fresh status before going on with the kept one.
  static const startWait = Duration(seconds: 4);

  FamilyCacheRead kept = const FamilyCacheEmpty();
  Timer? _refreshing;
  PlayTimeSession? _session;
  Game? _watching;
  DateTime? _since;
  bool _checking = false;

  /// The game last refused for the time, which more time is asked for.
  Game? _refused;

  /// The big notice once the time is up, shown in the family panel.
  String? notice;

  /// Minutes asked for in the family panel.
  static const askChoices = [15, 30, 60, 120];
  int askIndex = 1;

  // What applies.

  /// The kept status was changed on this computer: no play until a fresh one.
  bool get lockedOut => kept is FamilyCacheTampered;

  FamilyPolicy? get policy => switch (kept) {
    FamilyCacheKept(:final document, :final plays) => FamilyPolicy(document.status, plays: plays),
    _ => null,
  };

  /// The limits that apply: the careful defaults while locked out, none for a free account.
  FamilyRestrictions? get rules => lockedOut ? FamilyRestrictions.defaults() : policy?.restrictions;

  bool get restricted => rules != null;

  bool get stale => policy?.staleAt(now()) ?? false;

  /// Today's play time, the running game counted in; null without a time limit.
  Allowance? today() {
    final current = policy;
    if (current == null || !current.restricted || !current.restrictions!.playTime.enabled) return null;
    return current.allowanceAt(now(), runningSince: _since);
  }

  bool get voiceAllowed => rules?.voiceChat ?? true;

  /// Photos and clips may be shared (posts, chats, the gallery).
  bool get mediaAllowed => rules?.mediaSharing ?? true;
  bool get messagesAllowed => rules == null || rules!.messages != MessageRule.nobody;

  /// Friend requests go through a parent (approved contacts only, or nobody).
  bool get friendsThroughParent =>
      rules != null && const {FriendRequestRule.approved, FriendRequestRule.nobody}.contains(rules!.friendRequests);

  /// A child may not move to another server (and away from the limits).
  bool get serverLocked => restricted;

  /// The age lock on [game], when its rating keeps it from the child.
  FamilyLocked? ageLock(Game game) {
    final verdict = policy?.verdict(game.titleId, game.ageLevels) ?? TitleVerdict.allowed;
    return verdict == TitleVerdict.allowed ? null : FamilyLocked(verdict);
  }

  // Keeping the status.

  /// The kept status, from the last run.
  void load() {
    kept = cache.load();
    if (kept case final FamilyCacheKept read) kept = read.withPlays(PlaySpan.prune(read.plays, now()));
  }

  /// Fetches the status (sending the play that waits first, so the server's count has it) and
  /// keeps it when it verifies; offline, the kept one stays.
  Future<void> refresh() async {
    if (!together.signedIn) return;
    try {
      await together.sync.flush();
    } on Object {
      // The status is still worth having.
    }
    try {
      final document = await client.fetch();
      final server = together.account.base.toString();
      if (!FamilyCache.mayReplace(kept, document, server: server)) return;
      final previous = kept;
      final plays = previous is FamilyCacheKept && previous.document.status.userId == document.status.userId
          ? PlaySpan.prune(previous.plays, now())
          : const <PlaySpan>[];
      final next = FamilyCacheKept(document, server: server, plays: plays);
      kept = next;
      cache.save(next);
      app.refresh();
    } on Object {
      // Offline, or a status that does not verify: the kept one applies.
    }
  }

  /// Signed in: fetched now and every few minutes; signed out: the kept status stays.
  void signedInChanged() {
    _refreshing?.cancel();
    _refreshing = null;
    if (!together.signedIn) return;
    unawaited(refresh());
    _refreshing = Timer.periodic(refreshEvery, (_) => unawaited(refresh()));
  }

  // Playing.

  /// Before [game] starts: whether it may start now; when not, says why and offers to ask a
  /// parent. A child's status is fetched again first when online (a free account's every few
  /// minutes is enough, and its games start at once).
  FutureOr<bool> beforePlay(Game game) {
    if (_checking) return false;
    if (!together.signedIn || !restricted) return _mayStart(game);
    _checking = true;
    return refresh()
        .timeout(startWait)
        .catchError((Object _) {})
        .whenComplete(() => _checking = false)
        .then((_) => _mayStart(game));
  }

  bool _mayStart(Game game) {
    if (lockedOut) {
      app.show(T.text('familyLockedOut'));
      return false;
    }
    if (ageLock(game) != null) {
      app.show(T.text('familyNoAge'));
      return false;
    }
    final time = today();
    if (time != null && !time.allowed) {
      _refused = game;
      notice = whyNot(time);
      app.open(Layer.family);
      app.show(T.text('familyAskMoreTime'));
      return false;
    }
    notice = null;
    if (time?.remainingSeconds case final int left) app.show(T.format('familyLeftToday', [duration(left)]));
    return true;
  }

  /// The running game changed: its play time is watched while it runs.
  void followGame() {
    final running = app.running;
    if (running == null) {
      _session?.stop();
      _session = null;
      _watching = null;
      _since = null;
      return;
    }
    if (_watching == running.$1 && _session != null) return;
    _session?.stop();
    _watching = running.$1;
    _since = running.$2.started;
    _session = PlayTimeSession(check: _check, onEvent: _event, now: now)..start();
  }

  PlayTimeCheck? _check(DateTime at) {
    final current = policy;
    if (current == null || !current.restricted) return null;
    final playTime = current.restrictions!.playTime;
    if (!playTime.enabled) return null;
    return PlayTimeCheck.of(current.allowanceAt(at, runningSince: _since), playTime);
  }

  void _event(PlayTimeEvent event, int? remaining) {
    final playTime = rules?.playTime;
    final game = _watching;
    switch (event) {
      case PlayTimeEvent.warnTen:
        _say(T.format('familyMinutesLeft', [((remaining ?? 600) / 60).ceil()]));
      case PlayTimeEvent.warnOne:
        _say(T.text('familyOneMinute'));
      case PlayTimeEvent.reached:
        final grace = playTime?.graceMinutes ?? 0;
        notice = playTime?.whenLimitReached == LimitAction.close
            ? (grace > 0 ? T.format('familyClosesIn', [grace]) : T.text('familyClosesNow'))
            : T.text('familyTimeUpNotify');
        _say(notice!);
        app.open(Layer.family);
        if (playTime?.notifyParents ?? false) {
          if (together.signedIn) unawaited(client.limitReached(titleId: game?.titleId).catchError((Object _) {}));
        }
      case PlayTimeEvent.close:
        app.show(T.text('familyClosing'));
        unawaited(app.closeGame());
      case PlayTimeEvent.kill:
        app.killGame();
    }
  }

  void _say(String text) {
    app.show(text);
    notify('AnyPS5', text);
  }

  /// A game was played from [start] to [end]: counted until the server has it ([reported]: it went
  /// to AnyTogether's outbox).
  void played(DateTime start, DateTime end, {required bool reported}) {
    final current = kept;
    if (current is! FamilyCacheKept || !current.document.status.restricted) return;
    final next = current.withPlays(
      PlaySpan.prune([...current.plays, PlaySpan(start.toUtc(), end.toUtc(), reported: reported)], now()),
    );
    kept = next;
    cache.save(next);
  }

  // Asking a parent.

  Future<void> _ask(Future<void> Function() call, String done) async {
    if (!together.signedIn) {
      app.show(T.text('familySignInToAsk'));
      return;
    }
    try {
      await call();
      app.show(done);
    } on Object catch (error) {
      app.show(together.message(error));
    }
  }

  /// A game the age rating keeps from the child: the catalogue learns its rating, then a parent
  /// is asked.
  Future<void> askToPlay(Game game) async {
    if (together.signedIn) {
      together.sync.teachGame(titleId: game.titleId, gameName: game.name, ageLevels: game.ageLevels);
      try {
        await together.sync.flush();
      } on Object {
        // The request still goes.
      }
    }
    final name = game.nameFor([T.language.code]);
    await _ask(() => client.askToPlay(game.titleId, name: name), T.format('familyAskedToPlay', [name]));
  }

  Future<void> askForTime() {
    final minutes = askChoices[askIndex.clamp(0, askChoices.length - 1)];
    final titleId = (_watching ?? _refused ?? app.selectedGame)?.titleId;
    return _ask(() => client.askForTime(minutes, titleId: titleId), T.format('familyAskedTime', [minutes]));
  }

  Future<void> askToAddFriend(String handle) =>
      _ask(() => client.askToAddFriend(handle), T.format('familyAskedFriend', [handle.replaceFirst('@', '')]));

  // Texts.

  /// 1 h 20 min, rounded up to the minute.
  static String duration(int seconds) => TogetherProfiles.playTime(((seconds + 59) ~/ 60) * 60);

  static String whyNot(Allowance time) => time.reason == AllowanceReason.window && time.from != null
      ? T.format('familyOutsideWindow', [time.from!, time.until!])
      : T.text('familyTimeUp');

  /// The line about today a child sees.
  String? todayLine() {
    if (lockedOut) return T.text('familyLockedOut');
    if (!restricted) return null;
    final time = today();
    if (time == null || time.remainingSeconds == null && time.allowed) return T.text('familyNoLimitToday');
    if (!time.allowed) return whyNot(time);
    return T.format('familyLeftToday', [duration(time.remainingSeconds!)]);
  }

  /// What a refusal for a family [feature] means, in words.
  static String restrictedText(String? feature, {String? side}) => T.text(switch (feature) {
    _ when side == 'other' => 'familyOtherSide',
    'friend_requests' => 'familyNoFriendRequests',
    'messages' => 'familyNoMessages',
    'voice_chat' => 'familyNoVoiceDetail',
    'share_play' => 'familyNoSharePlay',
    'public_matchmaking' => 'familyNoPublic',
    'profile_visibility' => 'familyNoProfile',
    'discovery' || 'communities' => 'familyNoDiscovery',
    'media_sharing' => 'familyNoMedia',
    'age_rating' => 'familyNoAge',
    _ => 'familyNotAllowed',
  });

  /// The family panel: today, why not, asking for more time, checking again.
  List<PanelRow> rows() {
    final kept = this.kept;
    final issued = kept is FamilyCacheKept ? kept.document.status.issuedAt.toLocal() : null;
    final time = today();
    return [
      PanelRow(
        id: 'family-today',
        title: todayLine() ?? T.text('familyNoLimitToday'),
        detail: stale && issued != null
            ? T.format('familyStale', ['${issued.year}-${_two(issued.month)}-${_two(issued.day)}'])
            : null,
        kind: InfoRow(lockedOut ? T.text('familyLockedOutDetail') : ''),
      ),
      if (notice case final String text) PanelRow(id: 'family-notice', title: text, kind: const InfoRow('')),
      if (time != null && (time.limitMinutes != null || !time.allowed)) ...[
        PanelRow(
          id: 'family-minutes',
          title: T.text('familyAskMinutes'),
          kind: ChoiceRow(
            [
              for (final minutes in askChoices) T.format('profileMinutes', [minutes]),
            ],
            askIndex,
            (index) {
              askIndex = index;
              app.refresh();
            },
          ),
        ),
        PanelRow(
          id: 'family-ask',
          title: T.text('familyAskTime'),
          detail: together.signedIn ? T.text('familyAskTimeDetail') : T.text('familySignInToAsk'),
          kind: ActionRow(() => unawaited(askForTime())),
        ),
      ],
      if (together.signedIn)
        PanelRow(
          id: 'family-refresh',
          title: T.text('familyRefresh'),
          kind: ActionRow(() async {
            await refresh();
            if (!lockedOut) app.show(T.text('familyUpToDate'));
          }),
        )
      else
        PanelRow(id: 'family-signin', title: T.text('togetherSignIn'), kind: ActionRow(together.openSettings)),
      PanelRow(id: 'family-back', title: T.text('back'), kind: ActionRow(app.closeOverlay)),
    ];
  }

  /// The AnyTogether settings' row about the family limits, for a child.
  PanelRow? settingsRow() {
    final line = todayLine();
    if (line == null) return null;
    return PanelRow(
      id: 'together-family',
      title: T.text('familyTitle'),
      detail: line,
      kind: ActionRow(() => app.open(Layer.family)),
    );
  }

  static String _two(int value) => value.toString().padLeft(2, '0');

  void dispose() {
    _refreshing?.cancel();
    _session?.stop();
  }
}
