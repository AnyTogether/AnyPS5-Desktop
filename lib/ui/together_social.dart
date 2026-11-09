part of 'together_model.dart';

/// What the social screens show beyond the lists the hub keeps: where the keys are in the feed
/// and on a board, which board is open, what failed, and the layer each goes back to.
class SocialScreens {
  /// The activity feed: the item the keys are on, the reaction chosen on it, and whether the
  /// first page failed.
  int feedIndex = 0;
  int feedReaction = 0;
  bool feedFailed = false;
  PanelSpot? feedReturn;

  /// A leaderboard: the game's (null for overall trophy points), by what, among whom, what came
  /// back, the line the keys are on, and whether reading failed or the game has none.
  String? boardTitleId;
  String boardName = '';
  GameBoard boardKind = GameBoard.points;
  BoardScope boardScope = BoardScope.friends;
  Leaderboard? board;
  int boardIndex = 0;
  bool boardFailed = false;
  bool boardMissing = false;
  bool boardLoading = false;
  PanelSpot? boardReturn;

  /// Each read of a board counts up, so an answer to an older one is dropped.
  int boardReads = 0;

  /// The challenges over the board (together_challenges.dart): the game's, or the user's own
  /// over the overall board; whether the keys are on them, and on which.
  List<Challenge> boardChallenges = const [];
  bool boardOnChallenges = false;
  int boardChallenge = 0;
  int challengeReads = 0;

  /// One challenge: which, what came back, the standings row or button the keys are on, a join
  /// or leave on its way, and the screen it goes back to.
  String? challengeId;
  ChallengeDetail? challenge;
  bool challengeFailed = false;

  /// The challenge is no longer there (a 404): said instead of the failure.
  bool challengeGone = false;
  int challengeIndex = 0;
  bool challengeOnActions = false;
  int challengeAction = 0;
  bool challengeBusy = false;
  PanelSpot? challengeReturn;

  /// The notifications could not be read.
  bool noticesFailed = false;

  /// "How did it run?": the game asked about.
  Game? compatGame;

  /// The community's verdict per title ID on this platform; null inside while it is read.
  final Map<String, CompatSummary?> compat = {};

  /// When each game's verdict was asked for: once a run, or again a minute after a failure.
  final Map<String, DateTime> compatAsked = {};
  final Set<String> compatFailed = {};

  void clear() {
    feedIndex = 0;
    feedReaction = 0;
    feedFailed = false;
    board = null;
    boardIndex = 0;
    boardFailed = false;
    boardMissing = false;
    boardChallenges = const [];
    boardOnChallenges = false;
    boardChallenge = 0;
    challengeId = null;
    challenge = null;
    challengeFailed = false;
    challengeGone = false;
    challengeBusy = false;
    noticesFailed = false;
    compat.clear();
    compatAsked.clear();
    compatFailed.clear();
  }
}

/// AnyTogether's social screens, as the macOS launcher has them: friends' activity with its
/// four reactions, the leaderboards, and the notifications behind the bell.
extension TogetherSocial on TogetherModel {
  Social get social => hub.social;

  /// How close to the end of the feed the next, older page is read.
  static const feedPrefetch = 4;

  /// The Friends panel's rows for the feed and the boards.
  List<PanelRow> socialRows() => [
    PanelRow(
      id: 'friends-feed',
      title: T.text('socialFeedRow'),
      detail: T.text('socialFeedRowDetail'),
      kind: ActionRow(openFeed),
    ),
    // Captures need a server that keeps files.
    if (capturesOffered)
      PanelRow(
        id: 'friends-captures',
        title: T.text('capturesRow'),
        detail: T.text('capturesRowDetail'),
        kind: ActionRow(openCaptures),
      ),
    PanelRow(
      id: 'friends-board',
      title: T.text('socialBoardTitle'),
      detail: T.text('socialBoardRowDetail'),
      kind: ActionRow(() => openLeaderboard(null)),
    ),
  ];

  /// A game's settings, signed in: its leaderboard and how it runs for the community.
  List<PanelRow> gameSocialRows(Game game) {
    if (!signedIn) return const [];
    // Read after this draw, not during it.
    scheduleMicrotask(() => loadCompat(game.titleId));
    final summary = screens.compat[game.titleId];
    return [
      PanelRow(
        id: 'leaderboard',
        title: T.text('socialBoardTitle'),
        detail: T.text('socialBoardGameRowDetail'),
        kind: ActionRow(() => openLeaderboard(game)),
      ),
      PanelRow(
        id: 'compat',
        title: T.text('socialCompatReportRow'),
        detail: summary == null
            ? T.text('socialCompatNone')
            : '${T.text('socialCompatCommunity')}: ${compatText(summary)}',
        kind: ActionRow(() => openCompat(game)),
      ),
      if (matchmakingAllowed)
        PanelRow(
          id: 'find-players',
          title: T.format('discoverFindFor', [
            game.nameFor([T.language.code]),
          ]),
          detail: T.text('discoverFindForDetail'),
          kind: ActionRow(() => openLfgPost(game.titleId, game.nameFor([T.language.code]))),
        ),
      PanelRow(
        id: 'game-hub',
        title: T.format('discoverHubOf', [
          game.nameFor([T.language.code]),
        ]),
        detail: T.text('discoverHubDetail'),
        kind: ActionRow(() => openGameHub(game.titleId, game.nameFor([T.language.code]))),
      ),
    ];
  }

  // Relative times.

  /// "Just now", "25 min ago", "3 h ago", "2 d ago", then the date.
  static String ago(DateTime time, {DateTime? now}) {
    final passed = (now ?? DateTime.now()).difference(time);
    if (passed.inMinutes < 1) return T.text('socialAgoNow');
    if (passed.inHours < 1) return T.format('socialAgoMinutes', [passed.inMinutes]);
    if (passed.inDays < 1) return T.format('socialAgoHours', [passed.inHours]);
    if (passed.inDays < 7) return T.format('socialAgoDays', [passed.inDays]);
    return CompareView.day(time);
  }

  // The feed.

  void openFeed() {
    if (!signedIn) return;
    final from = app.overlay;
    if (from != null && from != Layer.feed && from != Layer.profile) screens.feedReturn = app.spot;
    screens
      ..feedIndex = 0
      ..feedReaction = _reactionIndex(social.feed.items.firstOrNull);
    app.open(Layer.feed);
    unawaited(loadFeed());
  }

  Future<void> loadFeed() async {
    try {
      await social.loadFeed();
      screens
        ..feedFailed = false
        ..feedIndex = screens.feedIndex.clamp(0, social.feed.items.isEmpty ? 0 : social.feed.items.length - 1)
        ..feedReaction = _reactionIndex(social.feed.items.elementAtOrNull(screens.feedIndex));
    } on Object {
      screens.feedFailed = !social.feed.loaded;
    }
    app.refresh();
  }

  void closeFeed() {
    final back = screens.feedReturn;
    screens.feedReturn = null;
    app.returnTo(back);
  }

  static int _reactionIndex(Activity? item) => item?.reactions.mine?.index ?? 0;

  /// Up and down through the items, left and right through the reactions, select reacts, △ opens
  /// the person's profile.
  void feedCommand(Command command) {
    final items = social.feed.items;
    switch (command) {
      case Command.up || Command.down:
        if (items.isEmpty) return;
        final next = (screens.feedIndex + (command == Command.down ? 1 : -1)).clamp(0, items.length - 1);
        if (next == screens.feedIndex) return;
        screens
          ..feedIndex = next
          ..feedReaction = items[next].reactions.mine?.index ?? screens.feedReaction;
        if (next >= items.length - feedPrefetch) unawaited(social.loadOlderFeed().catchError((Object _) {}));
        app.sounds.play(Cue.move);
        app.refresh();
      case Command.left || Command.right:
        if (items.isEmpty) return;
        final next = (screens.feedReaction + (command == Command.right ? 1 : -1)).clamp(0, Reaction.values.length - 1);
        if (next == screens.feedReaction) return;
        screens.feedReaction = next;
        app.sounds.play(Cue.move);
        app.refresh();
      case Command.select:
        final item = items.elementAtOrNull(screens.feedIndex);
        if (item != null) unawaited(react(item, Reaction.values[screens.feedReaction]));
      case Command.options:
        final item = items.elementAtOrNull(screens.feedIndex);
        if (item != null) unawaited(openProfile(item.actor.handle, card: item.actor));
      case Command.back:
        closeFeed();
      default:
        break;
    }
  }

  /// [change] with the focus held on the item it is on: a new item coming in above it does not
  /// move what the keys are on.
  void keepFeedFocus(void Function() change) {
    final focused = social.feed.items.elementAtOrNull(screens.feedIndex)?.id;
    change();
    if (focused == null) return;
    final at = social.feed.items.indexWhere((item) => item.id == focused);
    if (at >= 0) screens.feedIndex = at;
  }

  /// A click on an item: the keys go there.
  void focusFeedItem(int index) {
    final item = social.feed.items.elementAtOrNull(index);
    if (item == null || index == screens.feedIndex) return;
    screens
      ..feedIndex = index
      ..feedReaction = item.reactions.mine?.index ?? screens.feedReaction;
    app.refresh();
  }

  /// Shows the reaction at once, then what the server says; a failure puts the old ones back.
  Future<void> react(Activity item, Reaction reaction) async {
    final at = social.feed.items.indexWhere((known) => known.id == item.id);
    if (at >= 0) {
      screens
        ..feedIndex = at
        ..feedReaction = reaction.index;
    }
    app.sounds.play(Cue.select);
    try {
      await social.react(item.id, reaction);
    } on Object catch (error) {
      app.show(message(error));
    }
    app.refresh();
  }

  /// What the item says after the person's name: "earned the platinum in Neon Alley".
  String activityText(Activity item) {
    final game = item.game == null ? '' : _socialGameName(item.game!);
    return switch (item.kind) {
      ActivityKind.trophy when (item.trophyCount ?? item.trophies.length) > 1 => T.format('socialFeedTrophies', [
        game,
        item.trophyCount ?? item.trophies.length,
      ]),
      ActivityKind.trophy => T.format('socialFeedTrophy', [game]),
      ActivityKind.platinum => T.format('socialFeedPlatinum', [game]),
      ActivityKind.firstPlay => T.format('socialFeedFirstPlay', [game]),
      ActivityKind.longSession => T.format('socialFeedLongSession', [
        game,
        TogetherProfiles.playTime(item.seconds ?? 0),
      ]),
      ActivityKind.friendship => T.format('socialFeedFriendship', [
        item.friend == null ? '' : TogetherModel.shown(item.friend!).name,
      ]),
      ActivityKind.milestone => switch (item.milestoneKind) {
        'trophies' => T.format('socialFeedMilestoneTrophies', [item.milestoneValue ?? 0]),
        'platinums' => T.format('socialFeedMilestonePlatinums', [item.milestoneValue ?? 0]),
        'games' => T.format('socialFeedMilestoneGames', [item.milestoneValue ?? 0]),
        'hours' => T.format('socialFeedMilestoneHours', [item.milestoneValue ?? 0]),
        _ => T.text('socialFeedOther'),
      },
      ActivityKind.levelUp when item.level != null => T.format('socialFeedLevelUp', [item.level!.level]),
      _ => T.text('socialFeedOther'),
    };
  }

  /// The game's name as [activityText] writes it, to find it there; null without a game.
  String? activityGameName(Activity item) => item.game == null ? null : _socialGameName(item.game!);

  /// An activity item's game: its hub, as the website links a game's name to its page.
  void openActivityGame(Activity item) {
    final game = item.game;
    if (game == null) return;
    openGameHub(game.titleId, _socialGameName(game));
  }

  /// A game as this library names it, else as the server does.
  String _socialGameName(SocialGame game) =>
      app.games.where((known) => known.titleId == game.titleId).firstOrNull?.nameFor([T.language.code]) ??
      game.name(T.language.code);

  // Leaderboards.

  /// A game's board (from a game in this library), or overall points with null.
  void openLeaderboard(Game? game) {
    if (!signedIn) return;
    final from = app.overlay;
    if (from != null && from != Layer.leaderboard && from != Layer.profile) screens.boardReturn = app.spot;
    if (screens.boardTitleId != game?.titleId || screens.board == null) {
      screens
        ..boardKind = GameBoard.points
        ..board = null
        ..boardChallenges = const []
        ..boardChallenge = 0;
    }
    screens
      ..boardTitleId = game?.titleId
      ..boardName = game?.nameFor([T.language.code]) ?? ''
      ..boardIndex = 0
      ..boardOnChallenges = false;
    app.open(Layer.leaderboard);
    unawaited(loadLeaderboard());
    unawaited(loadBoardChallenges());
  }

  Future<void> loadLeaderboard() async {
    final read = ++screens.boardReads;
    final titleId = screens.boardTitleId;
    screens
      ..boardFailed = false
      ..boardMissing = false
      ..boardLoading = true;
    app.refresh();
    try {
      final board = titleId == null
          ? await social.pointsBoard(screens.boardScope)
          : await social.gameBoard(titleId, screens.boardKind, screens.boardScope);
      if (read != screens.boardReads) return;
      screens.board = board;
      // Opens on the user's own line.
      final lines = board.lines(user?.id ?? '');
      final mine = lines.indexWhere((line) => line is BoardPerson && line.me);
      screens.boardIndex = mine < 0 ? 0 : mine;
    } on TogetherProblem catch (problem) {
      if (read != screens.boardReads) return;
      screens
        ..board = null
        ..boardMissing = problem.status == 404
        ..boardFailed = problem.status != 404;
    } on Object {
      if (read != screens.boardReads) return;
      screens
        ..board = null
        ..boardFailed = true;
    } finally {
      if (read == screens.boardReads) screens.boardLoading = false;
    }
    app.refresh();
  }

  void closeLeaderboard() {
    screens.boardReads++;
    screens.challengeReads++;
    final back = screens.boardReturn;
    screens.boardReturn = null;
    app.returnTo(back);
  }

  List<BoardLine> get boardLines => screens.board?.lines(user?.id ?? '') ?? const [];

  /// Up and down through the people, left and right through a game's boards, △ between friends
  /// and everyone, select opens someone's profile. Up past the first line reaches the
  /// challenges over the board, where left and right move through them.
  void leaderboardCommand(Command command) {
    final lines = boardLines;
    if (boardChallengeCommand(command, lines)) return;
    switch (command) {
      case Command.up || Command.down:
        final way = command == Command.down ? 1 : -1;
        // The gap is passed over.
        var next = screens.boardIndex + way;
        while (next >= 0 && next < lines.length && lines[next] is BoardGap) {
          next += way;
        }
        if (next < 0 && enterBoardChallenges()) return;
        if (next < 0 || next >= lines.length) return;
        screens.boardIndex = next;
        app.sounds.play(Cue.move);
        app.refresh();
      case Command.left || Command.right:
        if (screens.boardTitleId == null) return;
        final next = screens.boardKind.index + (command == Command.right ? 1 : -1);
        if (next < 0 || next >= GameBoard.values.length) return;
        setBoardKind(GameBoard.values[next]);
      case Command.options:
        setBoardScope(screens.boardScope == BoardScope.friends ? BoardScope.global : BoardScope.friends);
      case Command.select:
        if (lines.elementAtOrNull(screens.boardIndex) case BoardPerson(:final entry)) {
          unawaited(openProfile(entry.user.handle, card: entry.user));
        }
      case Command.back:
        closeLeaderboard();
      default:
        break;
    }
  }

  void setBoardKind(GameBoard kind) {
    if (kind == screens.boardKind) return;
    screens.boardKind = kind;
    app.sounds.play(Cue.move);
    unawaited(loadLeaderboard());
  }

  void setBoardScope(BoardScope scope) {
    if (scope == screens.boardScope) return;
    screens.boardScope = scope;
    app.sounds.play(Cue.move);
    unawaited(loadLeaderboard());
  }

  /// A board's value as it reads: "1,830 pts", "12 h 30 min", "64%".
  static String boardValue(int value, String board) => switch (board) {
    'time' => TogetherProfiles.playTime(value),
    'completion' => T.percent(value),
    _ => T.format('socialBoardPointsValue', [T.number(value)]),
  };

  static String boardName(GameBoard kind) => switch (kind) {
    GameBoard.points => T.text('socialBoardPoints'),
    GameBoard.time => T.text('socialBoardTime'),
    GameBoard.completion => T.text('socialBoardCompletion'),
  };

  // Notifications.

  void openNotifications() {
    if (!signedIn) return;
    app.open(Layer.notifications);
    // The first one, past "mark all as read".
    final rows = notificationRows();
    final first = rows.indexWhere((row) => row.id.startsWith('note-'));
    if (first >= 0) app.panelRow = first;
    unawaited(loadNotifications());
  }

  /// The list and the badge, read again.
  Future<void> loadNotifications() async {
    try {
      await social.loadNotices();
      screens.noticesFailed = false;
    } on Object {
      screens.noticesFailed = !social.notices.loaded;
    }
    app.refresh();
  }

  /// The count of unread ones, or "Nothing new" over notifications all read. An empty list says
  /// it once, in its own row, so the heading stays quiet.
  String get notificationsSubtitle {
    final center = social.notices;
    if (center.unread > 0) return T.format('socialNotifUnread', [center.unread]);
    return center.loaded && center.items.isNotEmpty ? T.text('socialNotifEmpty') : '';
  }

  List<PanelRow> notificationRows() {
    final center = social.notices;
    return [
      if (center.unread > 0)
        PanelRow(id: 'notes-all', title: T.text('socialNotifMarkAll'), kind: ActionRow(readAllNotifications)),
      if (!center.loaded)
        PanelRow(
          id: 'notes-state',
          title: T.text(screens.noticesFailed ? 'socialNotifFailed' : 'socialNotifLoading'),
          kind: const InfoRow(''),
        )
      else if (center.items.isEmpty)
        PanelRow(id: 'notes-none', title: T.text('socialNotifEmpty'), kind: const InfoRow('')),
      for (final note in center.items)
        PanelRow(
          id: 'note-${note.id}',
          title: noticeText(note),
          // An unread one says so before when it came.
          detail: [
            ?noticeDetail(note),
            note.read ? ago(note.updatedAt) : T.format('socialNotifNew', [ago(note.updatedAt)]),
          ].join('\n'),
          person: note.actor == null || note.kind == NoticeKind.challengeStarted
              ? null
              : TogetherModel.card(note.actor!),
          icon: switch (note.kind) {
            NoticeKind.challengeStarted => PanelIcon.flag,
            NoticeKind.challengeEnded => PanelIcon.trophy,
            _ => null,
          },
          level: note.kind == NoticeKind.levelUp ? note.level : null,
          kind: ActionRow(() => openNotice(note)),
        ),
      if (center.more)
        PanelRow(
          id: 'notes-more',
          title: T.text('socialNotifMore'),
          kind: ActionRow(() => unawaited(social.loadOlderNotices().catchError((Object _) {}))),
        ),
    ];
  }

  /// Reads it (here at once, then on the server) and goes where it points.
  void openNotice(Notice note) {
    if (!note.read) unawaited(social.readNotice(note.id).catchError((Object _) {}));
    switch (note.kind) {
      case NoticeKind.friendRequest || NoticeKind.friendAccepted || NoticeKind.gameInvite || NoticeKind.missedCall:
        app.open(Layer.friends);
      case NoticeKind.partyInvite:
        app.open(Layer.party);
      case NoticeKind.lfgAccepted:
        followInvite(LfgInvite.fromJson(note.data['invite']));
      case NoticeKind.lfgRequest:
        openFindPlayers(category: 1);
      case NoticeKind.levelUp:
        unawaited(openMyProfile());
      case NoticeKind.message:
        // The conversation it is about, not the first in the list.
        final conversation = note.data['conversationId'];
        unawaited(conversation is String ? openConversation(conversation) : openMessages());
      case NoticeKind.challengeInvite || NoticeKind.challengeStarted || NoticeKind.challengeEnded:
        final id = TogetherChallenges.noticeChallengeId(note);
        if (id != null) openChallenge(id);
      case NoticeKind.warning || NoticeKind.other:
        app.refresh();
    }
  }

  void readAllNotifications() {
    app.panelRow = 0;
    app.sounds.play(Cue.select);
    unawaited(social.readAllNotices().catchError((Object _) {}));
    app.refresh();
  }

  /// A new notification nothing else announces: a toast while the launcher is in front, the
  /// notice's sound while it is behind.
  void noticeArrived(Notice note) {
    if (app.overlay == Layer.notifications) return;
    if (!app.active) _noticeSound();
    app.show([noticeText(note), ?noticeDetail(note)].join(': '));
  }

  String noticeText(Notice note) {
    final name = note.actor == null ? '' : TogetherModel.shown(note.actor!).name;
    return switch (note.kind) {
      NoticeKind.friendRequest => T.format('socialNotifFriendRequest', [name]),
      NoticeKind.friendAccepted => T.format('socialNotifFriendAccepted', [name]),
      NoticeKind.message when (note.count ?? 1) > 1 => T.format('socialNotifMessages', [name, note.count!]),
      NoticeKind.message => T.format('socialNotifMessage', [name]),
      NoticeKind.partyInvite => T.format('socialNotifPartyInvite', [name]),
      NoticeKind.gameInvite => T.format('socialNotifGameInvite', [name, gameName(note.titleId ?? '')]),
      NoticeKind.missedCall => T.format('socialNotifMissedCall', [name]),
      NoticeKind.lfgRequest => T.format('discoverNotifLfgRequest', [name, _noticeGame(note)]),
      NoticeKind.lfgAccepted => T.format('discoverNotifLfgAccepted', [name, _noticeGame(note)]),
      NoticeKind.levelUp => T.format('notifLevelUp', [note.level?.level ?? hub.self.level?.level ?? 0]),
      NoticeKind.challengeInvite => T.format('notifChallengeInvite', [name, TogetherChallenges.noticeTitle(note)]),
      NoticeKind.challengeStarted => T.format('notifChallengeStarted', [TogetherChallenges.noticeTitle(note)]),
      NoticeKind.challengeEnded => TogetherChallenges.endedText(note),
      NoticeKind.warning => T.text('socialNotifWarning'),
      NoticeKind.other => familyNoticeText(note) ?? T.text('socialNotifOther'),
    };
  }

  /// What a family notification says (the Mac's familyNotificationText); null for any other kind.
  String? familyNoticeText(Notice note) {
    final name = note.actor == null ? '' : TogetherModel.shown(note.actor!).name;
    final data = note.data;
    final minutes = (data['minutes'] as num?)?.toInt() ?? 0;
    final gameTitle = data['gameName'] as String? ?? (note.titleId == null ? '' : gameName(note.titleId!));
    switch (note.kindName) {
      case 'family_request':
        return switch (data['kind']) {
          'more_time' => T.format('familyNotifAsksTime', [name, minutes]),
          'play_game' => T.format('familyNotifAsksGame', [name, gameTitle]),
          _ => T.format('familyNotifAsksFriend', [name]),
        };
      case 'family_answer':
        if (data['approved'] != true) return T.text('familyNotifSaidNo');
        return switch (data['kind']) {
          'more_time' => T.format('familyNotifGaveTime', [minutes]),
          'play_game' => T.text('familyNotifGameYes'),
          _ => T.text('familyNotifFriendYes'),
        };
      case 'family_alert':
        return switch (data['event']) {
          'limit_reached' => T.format('familyNotifReachedLimit', [name]),
          'child_declined' => T.format('familyNotifDeclinedFamily', [name]),
          _ => T.format('familyNotifJoinedFamily', [name]),
        };
      case 'family_invite':
        return T.format('familyNotifFamilyInvite', [name, data['familyName'] as String? ?? '']);
      case 'family_summary':
        return T.text('familyNotifSummary');
      default:
        return null;
    }
  }

  /// The game a looking-for-group notification is about, as this library or the server names it.
  String _noticeGame(Notice note) {
    final titleId = note.titleId;
    if (titleId == null) return '';
    final local = app.games.where((game) => game.titleId == titleId).firstOrNull;
    return local?.nameFor([T.language.code]) ?? pickName(namesOf(note.data['gameNames']), T.language.code) ?? titleId;
  }

  /// The message's words (and its group), or the warning's reason.
  String? noticeDetail(Notice note) {
    switch (note.kind) {
      case NoticeKind.message:
        // A sealed message's notification carries no words ("Ana wrote to you" says it all).
        final words = note.data['sealed'] == true ? null : note.text;
        final text = words == null ? null : (words.length > 80 ? '${words.substring(0, 80)}…' : words);
        final group = note.data['group'] == true && note.data['title'] is String ? note.data['title'] as String : null;
        final joined = [?group, ?text].join(': ');
        return joined.isEmpty ? null : joined;
      case NoticeKind.warning:
        return note.data['reason'] is String ? note.data['reason'] as String : null;
      case NoticeKind.challengeInvite || NoticeKind.challengeStarted || NoticeKind.challengeEnded:
        return challengeNoticeDetail(note);
      default:
        return null;
    }
  }

  // Compatibility.

  /// After a session: asks once per game and launcher version, unless turned off; once the
  /// launcher is back over the home screen.
  void askHowItRan(Game game, Duration played) {
    if (!signedIn || app.preferences.compatNever) return;
    if (!CompatPrompt.shouldAsk(
      titleId: game.titleId,
      played: played,
      launcherVersion: launcherVersion,
      asked: app.preferences.compatAsked,
    )) {
      return;
    }
    Timer(const Duration(seconds: 1), () {
      if (app.overlay != null || app.running != null || app.starting != null) return;
      openCompat(game);
    });
  }

  void openCompat(Game game) {
    if (!signedIn) return;
    app.preferences.compatAsked = {...app.preferences.compatAsked, game.titleId: launcherVersion};
    app.savePreferences();
    screens.compatGame = game;
    app.open(Layer.compat);
  }

  String get compatTitle => T.format('socialCompatAsk', [
    screens.compatGame?.nameFor([T.language.code]) ?? '',
  ]);

  List<PanelRow> compatRows() {
    final game = screens.compatGame;
    if (game == null) return const [];
    return [
      for (final status in CompatStatus.values.reversed)
        PanelRow(
          id: 'compat-${status.name}',
          title: compatName(status),
          detail: compatDetail(status),
          kind: ActionRow(() => unawaited(reportCompat(game, status))),
        ),
      PanelRow(id: 'compat-later', title: T.text('socialCompatLater'), kind: ActionRow(app.closeOverlay)),
      PanelRow(
        id: 'compat-never',
        title: T.text('socialCompatNever'),
        detail: T.text('socialCompatNeverDetail'),
        kind: ToggleRow(app.preferences.compatNever, (value) {
          app.preferences.compatNever = value;
          app.savePreferences();
          app.refresh();
        }),
      ),
      PanelRow(id: 'compat-what', title: T.text('socialCompatWhat'), kind: InfoRow(compatSent(game))),
    ];
  }

  /// What goes with the report, said plainly: the launcher's version, the engine's, the computer
  /// and the system.
  String compatSent(Game game) =>
      [launcherVersion, ?engineVersionOf(game), ?TogetherModel.machineModel(app.system), osName].join(', ');

  String? engineVersionOf(Game game) => CompatReport.version(app.records[game.id]?.toolkit ?? app.toolkit?.version);

  /// "Windows 10.0.22631", "Linux 6.8.0": the system as the report names it.
  String get osName {
    final version = Platform.operatingSystemVersion;
    if (app.system == HostSystem.windows) {
      final build = RegExp(r'(\d+\.\d+\.\d+)').firstMatch(version)?.group(1);
      return build == null ? 'Windows' : 'Windows $build';
    }
    final release = RegExp(r'(\d+\.\d+(\.\d+)?)').firstMatch(version)?.group(1);
    return release == null ? 'Linux' : 'Linux $release';
  }

  Future<void> reportCompat(Game game, CompatStatus status) async {
    app.closeOverlay();
    final report = CompatReport(
      titleId: game.titleId,
      name: game.name,
      platform: CompatReport.platformOf(app.system),
      status: status,
      launcherVersion: launcherVersion,
      engineVersion: engineVersionOf(game),
      machine: TogetherModel.machineModel(app.system),
      os: osName,
      gameVersion: game.version,
    );
    try {
      final summary = await Compat(account).report(report);
      if (summary != null) screens.compat[game.titleId] = summary;
      app.show(T.text('socialCompatThanks'));
    } on Object catch (error) {
      app.show(message(error));
    }
  }

  /// The community's verdict for a game on this platform, read once a run (signed in only).
  Future<void> loadCompat(String titleId) async {
    final asked = screens.compatAsked[titleId];
    if (!signedIn) return;
    if (asked != null &&
        (!screens.compatFailed.contains(titleId) || DateTime.now().difference(asked) < const Duration(minutes: 1))) {
      return;
    }
    screens.compatAsked[titleId] = DateTime.now();
    screens.compatFailed.remove(titleId);
    try {
      final game = await Compat(account).game(titleId);
      final summary = game?.platforms[CompatReport.platformOf(app.system)];
      if (summary == null) return;
      screens.compat[titleId] = summary;
      app.refresh();
    } on Object {
      // Asked again a minute later, when the game's settings show next.
      screens.compatFailed.add(titleId);
    }
  }

  /// "In game, 0.1.17, 7 reports".
  String compatText(CompatSummary summary) => [
    summary.status == null ? summary.statusName : compatName(summary.status!),
    summary.version,
    T.format('socialCompatReports', [summary.reports]),
  ].join(', ');

  static String compatName(CompatStatus status) => switch (status) {
    CompatStatus.nothing => T.text('socialCompatNothing'),
    CompatStatus.boots => T.text('socialCompatBoots'),
    CompatStatus.menus => T.text('socialCompatMenus'),
    CompatStatus.ingame => T.text('socialCompatIngame'),
    CompatStatus.playable => T.text('socialCompatPlayable'),
  };

  static String compatDetail(CompatStatus status) => switch (status) {
    CompatStatus.nothing => T.text('socialCompatNothingDetail'),
    CompatStatus.boots => T.text('socialCompatBootsDetail'),
    CompatStatus.menus => T.text('socialCompatMenusDetail'),
    CompatStatus.ingame => T.text('socialCompatIngameDetail'),
    CompatStatus.playable => T.text('socialCompatPlayableDetail'),
  };
}
