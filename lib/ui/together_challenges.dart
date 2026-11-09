part of 'together_model.dart';

/// What can be done on a challenge's screen, in the order its buttons stand.
enum ChallengeAction { join, leave, website }

/// Challenges where the leaderboards are (the macOS launcher's TogetherChallenges): a strip over a
/// game's board with the game's running and coming ones, over the overall board the user's own;
/// a challenge's standings with Join and Leave. Making one happens on the website.
extension TogetherChallenges on TogetherModel {
  Challenges get challengeApi => Challenges(account);

  /// What "now" is for the time left and the window's track; the goldens fix it.
  static DateTime Function() clock = DateTime.now;

  // The strip over a board.

  /// The board's challenges, read again; none on a failure or a server without them, so no empty
  /// box and no error shows.
  Future<void> loadBoardChallenges() async {
    final read = ++screens.challengeReads;
    final titleId = screens.boardTitleId;
    List<Challenge> found;
    try {
      found = titleId == null ? await challengeApi.mine() : await challengeApi.forGame(titleId);
    } on Object {
      found = const [];
    }
    if (read != screens.challengeReads) return;
    screens.boardChallenges = found;
    screens.boardChallenge = screens.boardChallenge.clamp(0, found.isEmpty ? 0 : found.length - 1);
    if (found.isEmpty) screens.boardOnChallenges = false;
    app.refresh();
  }

  /// The keys while they are on the strip: left and right through the challenges, down back to
  /// the board, select opens one. Returns false for a key the board handles as usual.
  bool boardChallengeCommand(Command command, List<BoardLine> lines) {
    final list = screens.boardChallenges;
    if (!screens.boardOnChallenges || list.isEmpty) {
      screens.boardOnChallenges = false;
      return false;
    }
    switch (command) {
      case Command.left || Command.right:
        final next = screens.boardChallenge + (command == Command.right ? 1 : -1);
        if (next < 0 || next >= list.length) return true;
        screens.boardChallenge = next;
        app.sounds.play(Cue.move);
        app.refresh();
        return true;
      case Command.down:
        if (lines.isEmpty) return true;
        screens
          ..boardOnChallenges = false
          ..boardIndex = lines.indexWhere((line) => line is! BoardGap).clamp(0, lines.length - 1);
        app.sounds.play(Cue.move);
        app.refresh();
        return true;
      case Command.up:
        return true;
      case Command.select:
        openChallenge(list[screens.boardChallenge].id);
        return true;
      default:
        return false;
    }
  }

  /// Up past the board's first line: onto the strip, when there is one.
  bool enterBoardChallenges() {
    if (screens.boardChallenges.isEmpty) return false;
    screens.boardOnChallenges = true;
    app.sounds.play(Cue.move);
    app.refresh();
    return true;
  }

  /// A click on a challenge in the strip: the keys go there, and it opens.
  void tapBoardChallenge(int index) {
    if (index < 0 || index >= screens.boardChallenges.length) return;
    screens
      ..boardOnChallenges = true
      ..boardChallenge = index;
    openChallenge(screens.boardChallenges[index].id);
  }

  // One challenge.

  void openChallenge(String id) {
    if (!signedIn) return;
    final from = app.overlay;
    if (from != Layer.challenge && from != Layer.profile) screens.challengeReturn = app.spot;
    if (screens.challengeId != id) screens.challenge = null;
    screens
      ..challengeId = id
      ..challengeFailed = false
      ..challengeGone = false
      ..challengeIndex = 0
      ..challengeOnActions = false
      ..challengeAction = 0;
    app.open(Layer.challenge);
    unawaited(loadChallenge());
  }

  Future<void> loadChallenge() async {
    final id = screens.challengeId;
    if (id == null) return;
    try {
      final detail = await challengeApi.detail(id);
      if (screens.challengeId != id) return;
      final first = screens.challenge == null;
      screens
        ..challenge = detail
        ..challengeFailed = false;
      _keepBoardChallenge(detail.challenge);
      if (first) {
        // Opens on the user's own row.
        final mine = challengeLines.indexWhere((line) => line?.me ?? false);
        screens.challengeIndex = mine < 0 ? 0 : mine;
      }
      screens.challengeIndex = screens.challengeIndex.clamp(0, challengeLines.isEmpty ? 0 : challengeLines.length - 1);
      screens.challengeAction = screens.challengeAction.clamp(0, challengeActions.length - 1);
    } on Object catch (error) {
      if (screens.challengeId != id) return;
      // Deleted meanwhile: said as gone, not as a failure to read it.
      if (error is TogetherProblem && error.status == 404) {
        screens.challengeGone = true;
      } else {
        screens.challengeFailed = screens.challenge == null;
      }
    }
    app.refresh();
  }

  /// The strip's copy of a challenge, as the newer answer has it.
  void _keepBoardChallenge(Challenge challenge) {
    final list = screens.boardChallenges;
    final at = list.indexWhere((item) => item.id == challenge.id);
    if (at < 0) return;
    screens.boardChallenges = [...list]..[at] = challenge;
  }

  void closeChallenge() {
    final back = screens.challengeReturn;
    screens.challengeReturn = null;
    app.returnTo(back);
  }

  /// The standings, then the user's neighbours past them; null stands for the places between.
  List<ChallengeStanding?> get challengeLines {
    final detail = screens.challenge;
    if (detail == null) return const [];
    final lines = <ChallengeStanding?>[...detail.standings];
    final rest = detail.around.where((row) => !detail.standings.any((top) => _same(top, row)));
    if (rest.isNotEmpty) {
      if (detail.standings.isNotEmpty && rest.first.rank > detail.standings.last.rank + 1) lines.add(null);
      lines.addAll(rest);
    }
    return lines;
  }

  static bool _same(ChallengeStanding a, ChallengeStanding b) =>
      a.rank == b.rank && a.value == b.value && a.user?.id == b.user?.id && a.me == b.me;

  /// Join while it is open and the user is not in it, Leave when they are and did not make it,
  /// and always the website, where challenges are made.
  List<ChallengeAction> get challengeActions {
    final challenge = screens.challenge?.challenge;
    return [
      if (challenge != null && challenge.state.open && !challenge.joined) ChallengeAction.join,
      if (challenge != null && challenge.state.open && challenge.joined && !challenge.mine) ChallengeAction.leave,
      ChallengeAction.website,
    ];
  }

  /// Up and down through the standings or the buttons, right to the buttons and left back,
  /// select opens someone's profile or presses the button, △ joins or leaves.
  void challengeCommand(Command command) {
    final lines = challengeLines;
    final actions = challengeActions;
    switch (command) {
      case Command.up || Command.down:
        final way = command == Command.down ? 1 : -1;
        if (screens.challengeOnActions) {
          final next = screens.challengeAction + way;
          if (next < 0 || next >= actions.length) return;
          screens.challengeAction = next;
        } else {
          var next = screens.challengeIndex + way;
          while (next >= 0 && next < lines.length && lines[next] == null) {
            next += way;
          }
          if (next < 0 || next >= lines.length) return;
          screens.challengeIndex = next;
        }
        app.sounds.play(Cue.move);
        app.refresh();
      case Command.right when !screens.challengeOnActions:
        screens
          ..challengeOnActions = true
          ..challengeAction = screens.challengeAction.clamp(0, actions.length - 1);
        app.sounds.play(Cue.move);
        app.refresh();
      case Command.left when screens.challengeOnActions && lines.isNotEmpty:
        screens.challengeOnActions = false;
        app.sounds.play(Cue.move);
        app.refresh();
      case Command.select:
        if (screens.challengeOnActions) {
          runChallengeAction(actions[screens.challengeAction.clamp(0, actions.length - 1)]);
        } else if (lines.elementAtOrNull(screens.challengeIndex)?.user case final user?) {
          unawaited(openProfile(user.handle, card: user));
        }
      case Command.options:
        if (actions.contains(ChallengeAction.join) || actions.contains(ChallengeAction.leave)) {
          unawaited(toggleChallenge());
        }
      case Command.back:
        closeChallenge();
      default:
        break;
    }
  }

  void runChallengeAction(ChallengeAction action) {
    switch (action) {
      case ChallengeAction.join || ChallengeAction.leave:
        unawaited(toggleChallenge());
      case ChallengeAction.website:
        openChallengeWebsite();
    }
  }

  /// A click on a button: the keys go there, and it runs.
  void tapChallengeAction(ChallengeAction action) {
    final at = challengeActions.indexOf(action);
    if (at < 0) return;
    screens
      ..challengeOnActions = true
      ..challengeAction = at;
    runChallengeAction(action);
  }

  /// Joins, or leaves when in it; then the standings are read again. One at a time.
  Future<void> toggleChallenge() async {
    final challenge = screens.challenge?.challenge;
    if (challenge == null || screens.challengeBusy || !challenge.state.open) return;
    if (challenge.joined && challenge.mine) return;
    screens.challengeBusy = true;
    app.sounds.play(Cue.select);
    app.refresh();
    try {
      final now = challenge.joined ? await challengeApi.leave(challenge.id) : await challengeApi.join(challenge.id);
      _keepBoardChallenge(now);
      final detail = screens.challenge;
      if (detail != null && detail.challenge.id == now.id) {
        screens.challenge = ChallengeDetail(
          challenge: now,
          standings: detail.standings,
          around: detail.around,
          updatedAt: detail.updatedAt,
        );
      }
      app.show(T.format(now.joined ? 'challengeJoined' : 'challengeLeft', [now.title]));
      await loadChallenge();
    } on Object catch (error) {
      app.show(_challengeProblem(error));
      // A 409 means it changed while it was on the screen: read what it is now.
      if (error is TogetherProblem && error.status == 409) await loadChallenge();
    } finally {
      screens.challengeBusy = false;
      app.refresh();
    }
  }

  String _challengeProblem(Object error) => switch (error) {
    TogetherProblem(code: 'full') => T.text('challengeFull'),
    TogetherProblem(code: 'conflict') => T.text('challengeOverAlready'),
    TogetherProblem(status: 404) => T.text('challengeGone'),
    _ => message(error),
  };

  /// The website's challenges page, with the form open; only when the user chose it.
  void openChallengeWebsite() {
    final base = account.base.toString().replaceAll(RegExp(r'/+$'), '');
    app.services.openUrl?.call(Uri.parse('$base/challenges?new=1'));
  }

  // Words.

  /// "Ends in 2 days", "Starts in 5 h", "Over, final within the hour", "Ended 2 d ago",
  /// "Called off".
  static String when(Challenge challenge, {DateTime? now}) {
    final at = now ?? clock();
    return switch (challenge.state) {
      ChallengeState.upcoming => T.format('challengeStartsIn', [span(challenge.startsAt.difference(at))]),
      ChallengeState.active => T.format('challengeEndsIn', [span(challenge.endsAt.difference(at))]),
      ChallengeState.ended when !challenge.isFinal => T.text('challengeSettling'),
      ChallengeState.ended => T.format('challengeEndedAgo', [TogetherSocial.ago(challenge.endsAt, now: at)]),
      ChallengeState.cancelled => T.text('challengeCancelled'),
      ChallengeState.other => '',
    };
  }

  /// Days from two on, then hours, then minutes (at least one).
  static String span(Duration left) {
    if (left.inHours >= 48) return T.format('challengeDays', [left.inDays]);
    if (left.inHours >= 1) return T.format('challengeHours', [left.inHours]);
    final minutes = (left.inSeconds / 60).ceil();
    return T.format('challengeMinutes', [minutes < 1 ? 1 : minutes]);
  }

  /// A value as the metric reads: "1,830 pts", "5 trophies", "1 h 15 min".
  static String value(int value, ChallengeMetric metric) => switch (metric) {
    ChallengeMetric.time => TogetherProfiles.playTime(value),
    ChallengeMetric.trophies => T.format(value == 1 ? 'challengeTrophyValue' : 'challengeTrophiesValue', [
      T.number(value),
    ]),
    ChallengeMetric.points => T.format('socialBoardPointsValue', [T.number(value)]),
    ChallengeMetric.other => T.number(value),
  };

  static String metricName(ChallengeMetric metric) => switch (metric) {
    ChallengeMetric.points => T.text('challengeMetricPoints'),
    ChallengeMetric.trophies => T.text('challengeMetricTrophies'),
    ChallengeMetric.time => T.text('challengeMetricTime'),
    ChallengeMetric.other => T.text('challengeMetricOther'),
  };

  /// "For friends", "For Night Owls", "For everyone".
  static String audience(Challenge challenge) => switch (challenge.audience) {
    ChallengeAudience.community when challenge.community != null => T.format('challengeForCommunity', [
      challenge.community!.name,
    ]),
    ChallengeAudience.public => T.text('challengeForEveryone'),
    _ => T.text('challengeForFriends'),
  };

  /// The state in a word: "Running", "Coming", "Over", "Final", "Called off".
  static String stateName(Challenge challenge) => switch (challenge.state) {
    ChallengeState.upcoming => T.text('challengeStateUpcoming'),
    ChallengeState.active => T.text('challengeStateActive'),
    ChallengeState.ended when challenge.isFinal => T.text('challengeStateFinal'),
    ChallengeState.ended => T.text('challengeStateEnded'),
    _ => T.text('challengeCancelled'),
  };

  /// How far through its window it is, 0 to 1.
  static double progress(Challenge challenge, {DateTime? now}) {
    final total = challenge.endsAt.difference(challenge.startsAt).inSeconds;
    if (total <= 0) return challenge.state == ChallengeState.upcoming ? 0 : 1;
    final gone = (now ?? clock()).difference(challenge.startsAt).inSeconds;
    return (gone / total).clamp(0, 1).toDouble();
  }

  /// A game as this library names it, else as the server does.
  String challengeGame(SocialGame game) =>
      app.games.where((known) => known.titleId == game.titleId).firstOrNull?.nameFor([T.language.code]) ??
      game.name(T.language.code);

  /// A standing's name: the friends-only one when there, "Hidden player" for someone not shown.
  static String standingName(ChallengeStanding standing) =>
      standing.user == null ? T.text('challengeHidden') : TogetherModel.shown(standing.user!).name;

  // Notifications.

  /// What a challenge notification carries.
  static String noticeTitle(Notice note) => note.data['title'] is String ? note.data['title'] as String : '';

  static String? noticeChallengeId(Notice note) {
    final id = note.data['challengeId'] ?? note.subjectId;
    return id is String && id.isNotEmpty ? id : null;
  }

  /// "You won Weekend race", "Weekend race is over: you placed 3 of 6".
  static String endedText(Notice note) {
    final rank = (note.data['rank'] as num?)?.toInt() ?? 0;
    final score = (note.data['value'] as num?)?.toInt() ?? 0;
    final entrants = (note.data['entrants'] as num?)?.toInt() ?? 0;
    if (rank == 1 && score > 0) return T.format('notifChallengeWon', [noticeTitle(note)]);
    if (rank <= 0 || entrants <= 0) return T.format('notifChallengeOver', [noticeTitle(note)]);
    return T.format('notifChallengeEnded', [noticeTitle(note), rank, entrants]);
  }

  /// The winner, when it was someone else; else the game.
  String? challengeNoticeDetail(Notice note) {
    final winner = note.data['winner'];
    final rank = (note.data['rank'] as num?)?.toInt() ?? 0;
    final score = (note.data['value'] as num?)?.toInt() ?? 0;
    final won = rank == 1 && score > 0;
    if (note.kind == NoticeKind.challengeEnded && !won && winner is Map && winner['displayName'] is String) {
      final metric = ChallengeMetric.named(note.data['metric']);
      final best = (winner['value'] as num?)?.toInt() ?? 0;
      return '${T.text('challengeWinner')}: ${winner['displayName']} · ${value(best, metric)}';
    }
    final game = _challengeNoticeGame(note);
    return game.isEmpty ? null : game;
  }

  String _challengeNoticeGame(Notice note) {
    final titleId = note.titleId;
    if (titleId == null) return '';
    final local = app.games.where((game) => game.titleId == titleId).firstOrNull;
    return local?.nameFor([T.language.code]) ?? pickName(namesOf(note.data['gameNames']), T.language.code) ?? titleId;
  }
}
