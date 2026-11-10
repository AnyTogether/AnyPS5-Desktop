part of 'together_model.dart';

/// What "Find players", a game's hub and the post form show (together_find.dart).
class FindState {
  LfgFilter filter = const LfgFilter();
  List<LfgPost> board = const [];
  bool more = false;
  bool loaded = false;
  bool failed = false;

  /// Games with open posts, for the game filter.
  List<LfgGame> games = const [];
  List<LfgPost> mine = const [];
  List<LfgPost> asked = const [];
  List<PublicParty> parties = const [];
  List<DiscoveredPerson> suggestions = const [];

  /// Share plays under Live now (anyone may watch, or ask to), and those the user asked to.
  List<PublicShare> live = const [];
  Set<String> askedToWatch = {};

  /// Friend requests sent from here, so the row says so at once.
  Set<String> askedFriends = {};
  Discovery? discovery;

  /// How many are online now, by the heading (invisible accounts are not in it).
  int? online;

  /// The hub open: its game, what came back, and whether reading it failed.
  String? hubTitle;
  String hubName = '';
  GameHub? hub;
  bool hubFailed = false;

  /// The post being written, and the game's name to show.
  LfgDraft? draft;
  String draftName = '';
  bool posting = false;

  /// Where the post form and the hub go back to, and the section there.
  Layer? returnTo;
  int returnCategory = 0;
  Timer? reload;

  /// Each read of the lists counts up, so an answer to an older one is dropped.
  int reads = 0;

  void clear() {
    filter = const LfgFilter();
    board = const [];
    more = false;
    loaded = false;
    failed = false;
    games = const [];
    mine = const [];
    asked = const [];
    parties = const [];
    suggestions = const [];
    live = const [];
    askedToWatch = {};
    askedFriends = {};
    discovery = null;
    online = null;
    hubTitle = null;
    hub = null;
    draft = null;
    returnTo = null;
    reload?.cancel();
  }
}

/// Finding people beyond friends on AnyTogether, as the macOS launcher's FindPlayers: the
/// looking-for-group board with its filters, posting from a game's settings, "I'm in", one's own
/// posts and their requests, public parties, people to meet, and a game's hub. The board and the
/// lists are read again when the gateway's public topics say they changed.
extension TogetherFind on TogetherModel {
  Discover get discover => Discover(account);

  /// A parent's settings let the child find strangers (public matchmaking) and be found.
  bool get matchmakingAllowed => family.rules?.publicMatchmaking ?? true;
  bool get discoveryAllowed => family.rules?.discovery ?? true;

  String get _lang => T.language.code;

  // Opening.

  void openFindPlayers({int category = 0}) {
    if (!signedIn) return openSettings();
    if (!matchmakingAllowed) return app.show(FamilyGate.restrictedText('public_matchmaking'));
    app.open(Layer.findPlayers);
    app.selectCategory(category);
    _watch();
    unawaited(loadDiscover());
    if (findState.discovery == null) unawaited(loadDiscovery());
  }

  /// "Find players for" a game: the form, back to where it was opened.
  void openLfgPost(String titleId, String name) {
    if (!signedIn) return openSettings();
    if (!matchmakingAllowed) return app.show(FamilyGate.restrictedText('public_matchmaking'));
    final chosen = findState.discovery?.languages ?? const <String>[];
    final language = DiscoverLanguages.common.contains(_lang.split('-').first) ? _lang.split('-').first : 'en';
    findState
      ..returnTo = app.overlay
      ..returnCategory = app.panelCategory
      ..draft = LfgDraft(titleId: titleId, languages: chosen.isNotEmpty ? chosen.take(2).toList() : [language])
      ..draftName = name;
    app.open(Layer.lfgPost);
  }

  void openGameHub(String titleId, String name) {
    if (!signedIn) return openSettings();
    if (!discoveryAllowed) return app.show(FamilyGate.restrictedText('discovery'));
    if (app.overlay != Layer.gameHub) {
      findState
        ..returnTo = app.overlay
        ..returnCategory = app.panelCategory;
    }
    if (findState.hubTitle != titleId) findState.hub = null;
    findState
      ..hubTitle = titleId
      ..hubName = name
      ..hubFailed = false;
    app.open(Layer.gameHub);
    _watch();
    unawaited(loadHub(titleId));
    unawaited(loadCompat(titleId));
  }

  /// Back from the form or the hub to the panel it was opened from.
  void backFromFind() {
    final back = findState.returnTo;
    findState.returnTo = null;
    if (back == null || back == app.overlay) {
      app.closeOverlay();
      _watch();
      return;
    }
    app.open(back, cue: Cue.back);
    if (findState.returnCategory > 0) app.selectCategory(findState.returnCategory);
    _watch();
    if (back == Layer.findPlayers) unawaited(loadDiscover());
  }

  /// Which public topics the socket listens to: the board and the lists while they are open.
  void _watch() => hub.socket.watch(switch (app.overlay) {
    Layer.findPlayers => DiscoverTopics.of(findState.filter.titleId),
    Layer.gameHub => DiscoverTopics.of(findState.hubTitle),
    _ => const [],
  });

  /// The find screens closed some other way: nothing to listen to.
  void findClosed() {
    if (hub.socket.watching.isNotEmpty) hub.socket.watch(const []);
  }

  // Reading.

  Future<void> loadDiscover() async {
    if (!signedIn) return;
    final read = ++findState.reads;
    final filter = findState.filter;
    // Read side by side; a list that fails keeps what it had and is read again next time.
    Future<V?> quiet<V>(Future<V> future) => future.then<V?>((value) => value, onError: (Object _) => null);
    final board = discover.board(filter);
    final games = quiet(discover.games());
    final mine = quiet(discover.mine());
    final parties = quiet(discover.parties());
    final suggestions = quiet(discover.suggestions());
    final online = quiet(discover.online());
    // Share plays only where the family lets the user watch them.
    final live = (family.rules?.sharePlay ?? true)
        ? quiet(SharePlayClient(account).public(live: true))
        : Future<List<PublicShare>?>.value(const []);
    try {
      final (posts, more) = await board;
      if (read == findState.reads && findState.filter == filter) {
        findState
          ..board = posts
          ..more = more
          ..loaded = true
          ..failed = false;
      }
    } on Object {
      if (read == findState.reads) findState.failed = true;
    }
    app.refresh();
    final (gamesRead, mineRead, partiesRead, suggestionsRead) = (
      await games,
      await mine,
      await parties,
      await suggestions,
    );
    if (read != findState.reads) return;
    if (gamesRead != null) findState.games = gamesRead;
    if (mineRead != null) {
      findState
        ..mine = mineRead.$1
        ..asked = mineRead.$2;
    }
    if (partiesRead != null) findState.parties = partiesRead;
    if (suggestionsRead != null) findState.suggestions = suggestionsRead;
    final liveRead = await live;
    if (read != findState.reads) return;
    if (liveRead != null) findState.live = liveRead;
    final onlineRead = await online;
    if (read != findState.reads) return;
    if (onlineRead != null) findState.online = onlineRead;
    app.refresh();
  }

  /// "12 players online now" by Find players' heading, as on the Mac and the website; nothing
  /// while there is no count or nobody is counted.
  String? get onlineNowText {
    final count = findState.online;
    if (count == null || count < 1) return null;
    return T.format(count == 1 ? 'discoverOnlineNowOne' : 'discoverOnlineNowMany', [T.number(count)]);
  }

  Future<void> loadMoreBoard() async {
    final last = findState.board.lastOrNull?.id;
    if (last == null) return;
    final filter = findState.filter;
    try {
      final (posts, more) = await discover.board(filter, before: last);
      if (findState.filter != filter) return;
      final known = {for (final post in findState.board) post.id};
      findState
        ..board = [
          ...findState.board,
          for (final post in posts)
            if (!known.contains(post.id)) post,
        ]
        ..more = more;
      app.refresh();
    } on Object catch (error) {
      app.show(discoverMessage(error));
    }
  }

  Future<void> loadHub(String titleId) async {
    try {
      final read = await discover.hub(titleId);
      if (findState.hubTitle != titleId) return;
      findState
        ..hub = read
        ..hubFailed = false;
    } on Object {
      if (findState.hubTitle != titleId) return;
      findState.hubFailed = true;
    }
    app.refresh();
  }

  Future<void> loadDiscovery() async {
    try {
      findState.discovery = await discover.discovery();
      app.refresh();
    } on Object {
      // The rows wait for it.
    }
  }

  /// The lists again, a moment after the last "changed" (a busy board sends many).
  void reloadDiscoverSoon() {
    findState.reload?.cancel();
    findState.reload = Timer(const Duration(milliseconds: 600), () {
      switch (app.overlay) {
        case Layer.findPlayers:
          unawaited(loadDiscover());
        case Layer.gameHub when findState.hubTitle != null:
          unawaited(loadHub(findState.hubTitle!));
        default:
          break;
      }
    });
  }

  void setBoardFilter(LfgFilter next) {
    if (next == findState.filter) return;
    findState
      ..filter = next
      ..loaded = false;
    _watch();
    unawaited(loadDiscover());
    app.refresh();
  }

  // Texts.

  static String purposeName(LfgPurpose purpose) => switch (purpose) {
    LfgPurpose.coop => T.text('discoverPurposeCoop'),
    LfgPurpose.online => T.text('discoverPurposeOnline'),
    LfgPurpose.party => T.text('discoverPurposeParty'),
    LfgPurpose.trophies => T.text('discoverPurposeTrophies'),
  };

  static String _languages(List<String> codes) => codes.map(DiscoverLanguages.name).join(' & ');

  /// "Now", "In 30 min", "In 2 h".
  static String startText(int minutes) => minutes == 0
      ? T.text('discoverNow')
      : minutes < 120
      ? T.format('discoverInMinutes', [minutes])
      : T.format('discoverInHours', [(minutes + 30) ~/ 60]);

  String postName(LfgPost post) =>
      app.games.where((game) => game.titleId == post.titleId).firstOrNull?.nameFor([_lang]) ?? post.name(_lang);

  /// "Mira, now, English and Türkçe, 1 of 3 in" on the first line; what pressing does (or the
  /// post's state) and the note on the next.
  String postDetail(LfgPost post, String status, {bool author = true}) {
    final facts = [
      if (author) TogetherModel.shown(post.author).name,
      startText(post.startsIn()),
      _languages(post.languages),
      T.format('discoverFilled', [post.filled, post.slots]),
    ];
    final note = post.note?.trim();
    return [facts.join(', '), status, if (note != null && note.isNotEmpty) '“$note”'].join('\n');
  }

  /// A post on the board: what pressing it does follows where the user stands with it.
  PanelRow postRow(LfgPost post, {String prefix = 'post'}) {
    final title = '${postName(post)}: ${purposeName(post.purpose)}';
    final person = TogetherModel.card(post.author);
    final author = TogetherModel.shown(post.author).name;
    final id = '$prefix-${post.id}';
    return switch (post.standing()) {
      LfgStanding.canAsk => PanelRow(
        id: id,
        title: title,
        detail: postDetail(post, T.text('discoverSelectImIn')),
        person: person,
        kind: ActionRow(() => unawaited(imIn(post))),
      ),
      LfgStanding.waiting => PanelRow(
        id: id,
        title: title,
        detail: postDetail(post, T.format('discoverWaitingFor', [author])),
        person: person,
        kind: ActionRow(() => unawaited(takeBack(post))),
      ),
      LfgStanding.accepted => PanelRow(
        id: id,
        title: title,
        detail: postDetail(
          post,
          T.text(post.myInvite?.isSharePlay == true ? 'discoverInSharePlay' : 'discoverInParty'),
        ),
        person: person,
        kind: ActionRow(() => followInvite(post.myInvite)),
      ),
      LfgStanding.declined => PanelRow(
        id: id,
        title: title,
        detail: postDetail(post, T.format('discoverSaidNo', [author])),
        person: person,
        kind: const InfoRow(''),
      ),
      LfgStanding.closed => PanelRow(
        id: id,
        title: title,
        detail: postDetail(post, T.text('discoverClosed')),
        person: person,
        kind: const InfoRow(''),
      ),
      LfgStanding.own => PanelRow(
        id: id,
        title: title,
        detail: postDetail(post, T.format('discoverWaitingCount', [post.pending.length]), author: false),
        kind: ActionRow(() => openFindPlayers(category: 1)),
      ),
    };
  }

  // The board.

  List<PanelRow> boardRows() {
    final filter = findState.filter;
    final selected = app.selectedGame;
    // The game filter: all, the selected game, then games with open posts.
    final titles = <(String?, String)>[(null, T.text('discoverAllGames'))];
    if (selected != null) titles.add((selected.titleId, selected.nameFor([_lang])));
    for (final game in findState.games) {
      if (titles.any((known) => known.$1 == game.titleId)) continue;
      final local = app.games.where((known) => known.titleId == game.titleId).firstOrNull;
      titles.add((game.titleId, '${local?.nameFor([_lang]) ?? game.name(_lang)} (${game.posts})'));
    }
    if (filter.titleId case final chosen? when !titles.any((known) => known.$1 == chosen)) {
      titles.add((chosen, gameName(chosen)));
    }
    final purposes = <LfgPurpose?>[null, ...LfgPurpose.values];
    final languages = <String?>[null, ...DiscoverLanguages.common];
    final game = filter.titleId != null
        ? (filter.titleId!, gameName(filter.titleId!))
        : selected == null
        ? null
        : (selected.titleId, selected.nameFor([_lang]));
    return [
      PanelRow(
        id: 'lfg-game',
        title: T.text('discoverGame'),
        kind: ChoiceRow(
          [for (final title in titles) title.$2],
          titles.indexWhere((title) => title.$1 == filter.titleId).clamp(0, titles.length - 1),
          (index) => setBoardFilter(filter.copyWith(titleId: () => titles[index].$1)),
        ),
      ),
      PanelRow(
        id: 'lfg-purpose',
        title: T.text('discoverPurpose'),
        kind: ChoiceRow(
          [for (final purpose in purposes) purpose == null ? T.text('discoverAnyPurpose') : purposeName(purpose)],
          purposes.indexOf(filter.purpose).clamp(0, purposes.length - 1),
          (index) => setBoardFilter(filter.copyWith(purpose: () => purposes[index])),
        ),
      ),
      PanelRow(
        id: 'lfg-language',
        title: T.text('discoverLanguage'),
        kind: ChoiceRow(
          [for (final code in languages) code == null ? T.text('discoverAnyLanguage') : DiscoverLanguages.name(code)],
          languages.indexOf(filter.language).clamp(0, languages.length - 1),
          (index) => setBoardFilter(filter.copyWith(language: () => languages[index])),
        ),
      ),
      PanelRow(
        id: 'lfg-now',
        title: T.text('discoverStartingSoon'),
        detail: T.text('discoverStartingSoonDetail'),
        kind: ToggleRow(filter.now, (value) => setBoardFilter(filter.copyWith(now: value))),
      ),
      if (game != null) ...[
        PanelRow(
          id: 'lfg-post',
          title: T.format('discoverFindFor', [game.$2]),
          detail: T.text('discoverFindForDetail'),
          kind: ActionRow(() => openLfgPost(game.$1, game.$2)),
        ),
        if (discoveryAllowed)
          PanelRow(
            id: 'lfg-hub',
            title: T.format('discoverHubOf', [game.$2]),
            detail: T.text('discoverHubDetail'),
            kind: ActionRow(() => openGameHub(game.$1, game.$2)),
          ),
      ],
      if (!findState.loaded)
        PanelRow(
          id: 'lfg-loading',
          title: findState.failed ? T.text('togetherUnreachable') : T.text('discoverLoading'),
          kind: const InfoRow(''),
        )
      else ...[
        if (findState.board.isEmpty)
          PanelRow(id: 'lfg-empty', title: T.text('discoverNoPosts'), kind: InfoRow(T.text('discoverNoPostsDetail'))),
        for (final post in findState.board) postRow(post),
        if (findState.more)
          PanelRow(id: 'lfg-more', title: T.text('discoverMore'), kind: ActionRow(() => unawaited(loadMoreBoard()))),
      ],
    ];
  }

  // My posts.

  List<PanelRow> myPostRows() {
    final selected = app.selectedGame;
    final open = findState.mine.where((post) => post.isOpen()).length;
    return [
      if (selected != null && open < 3)
        PanelRow(
          id: 'mine-post',
          title: T.format('discoverFindFor', [
            selected.nameFor([_lang]),
          ]),
          detail: T.text('discoverFindForDetail'),
          kind: ActionRow(() => openLfgPost(selected.titleId, selected.nameFor([_lang]))),
        ),
      if (findState.mine.isEmpty && findState.asked.isEmpty)
        PanelRow(id: 'mine-none', title: T.text('discoverNoMine'), kind: InfoRow(T.text('discoverNoMineDetail'))),
      for (final post in findState.mine) ...[
        PanelRow(
          id: 'mine-${post.id}',
          title: '${postName(post)}: ${purposeName(post.purpose)}',
          detail: postDetail(
            post,
            post.isOpen()
                ? T.format('discoverWaitingCount', [post.pending.length])
                : T.text(post.status == 'full' ? 'discoverFull' : 'discoverClosed'),
            author: false,
          ),
          kind: const InfoRow(''),
        ),
        for (final request in post.requests ?? const <LfgRequest>[])
          ...switch (request.status) {
            'pending' when post.isOpen() => [
              PanelRow(
                id: 'mine-accept-${post.id}-${request.user.id}',
                title: T.format('discoverLetIn', [TogetherModel.shown(request.user).name]),
                detail:
                    '@${request.user.handle}\n${T.text(post.purpose == LfgPurpose.coop ? 'discoverLetInCoop' : 'discoverLetInParty')}',
                person: TogetherModel.card(request.user),
                kind: ActionRow(() => unawaited(answerPost(post, request.user, accept: true))),
              ),
              PanelRow(
                id: 'mine-decline-${post.id}-${request.user.id}',
                title: T.format('discoverNotNow', [TogetherModel.shown(request.user).name]),
                kind: ActionRow(() => unawaited(answerPost(post, request.user, accept: false)), destructive: true),
              ),
            ],
            'accepted' => [
              PanelRow(
                id: 'mine-in-${post.id}-${request.user.id}',
                title: TogetherModel.shown(request.user).name,
                detail: T.text(request.invite?.isSharePlay == true ? 'discoverTheyShare' : 'discoverTheyParty'),
                person: TogetherModel.card(request.user),
                kind: const InfoRow(''),
              ),
            ],
            _ => const <PanelRow>[],
          },
        if (post.isOpen())
          ...askingFirst(
            PanelRow(
              id: 'mine-close-${post.id}',
              title: T.text('discoverClosePost'),
              kind: ActionRow(() => unawaited(closePost(post)), destructive: true),
            ),
            T.text('askClosePost'),
          ),
      ],
      if (findState.asked.isNotEmpty) ...[
        PanelRow(id: 'asked-title', title: T.text('discoverAskedTitle'), kind: const InfoRow('')),
        for (final post in findState.asked) postRow(post, prefix: 'asked'),
      ],
    ];
  }

  // Public parties.

  PanelRow partyRow(PublicParty listed, {String prefix = 'pub'}) {
    final host = listed.host == null ? '?' : TogetherModel.shown(listed.host!).name;
    final local = listed.titleId == null ? null : app.games.where((game) => game.titleId == listed.titleId).firstOrNull;
    final facts = [
      if (listed.titleId != null) local?.nameFor([_lang]) ?? pickName(listed.names, _lang) ?? listed.titleId!,
      T.format('partySize', [listed.size, listed.max]),
      if (listed.language != null) DiscoverLanguages.name(listed.language!),
    ];
    final person = listed.host == null ? null : TogetherModel.card(listed.host!, status: PersonStatus.online);
    final id = '$prefix-${listed.id}';
    if (hub.parties.party?.id == listed.id) {
      return PanelRow(
        id: id,
        title: T.text('discoverYourParty'),
        detail: facts.join(', '),
        person: person,
        kind: const InfoRow(''),
      );
    }
    if (listed.full) {
      return PanelRow(
        id: id,
        title: T.format('partyJoinOf', [host]),
        detail: '${facts.join(', ')}\n${T.text('partyFull')}',
        person: person,
        kind: const InfoRow(''),
      );
    }
    if (listed.join == PublicJoin.open) {
      return PanelRow(
        id: id,
        title: T.format('partyJoinOf', [host]),
        detail: facts.join(', '),
        person: person,
        kind: ActionRow(() => unawaited(joinParty(listed.id))),
      );
    }
    if (listed.requested) {
      return PanelRow(
        id: id,
        title: T.format('discoverAskedParty', [host]),
        detail: '${facts.join(', ')}\n${T.text('discoverSelectTakeBack')}',
        person: person,
        kind: ActionRow(() => unawaited(cancelPartyAsk(listed))),
      );
    }
    return PanelRow(
      id: id,
      title: T.format('discoverAskParty', [host]),
      detail: facts.join(', '),
      person: person,
      kind: ActionRow(() => unawaited(askToJoinParty(listed))),
    );
  }

  /// Live now: share plays anyone may watch (here, full screen) or ask the host to watch.
  List<PanelRow> liveRows() {
    if (!(family.rules?.sharePlay ?? true)) return const [];
    return [
      PanelRow(id: 'live-title', title: T.text('discoverLiveNow'), kind: InfoRow(T.text('discoverLiveDetail'))),
      if (findState.live.isEmpty) PanelRow(id: 'live-none', title: T.text('discoverNoLive'), kind: const InfoRow('')),
      for (final share in findState.live) shareRow(share),
    ];
  }

  PanelRow shareRow(PublicShare share) {
    final host = share.host == null ? '?' : TogetherModel.shown(share.host!).name;
    final name =
        app.games.where((game) => game.titleId == share.titleId).firstOrNull?.nameFor([_lang]) ??
        pickName(share.names, _lang) ??
        share.title ??
        share.titleId;
    final detail = [
      T.format('sharePlayWatching', [share.viewers, share.maxViewers]),
      if (share.language case final language?) DiscoverLanguages.name(language),
    ].join(' · ');
    final person = share.host == null ? null : TogetherModel.card(share.host!, status: PersonStatus.playing);
    if (share.open) {
      return PanelRow(
        id: 'live-${share.id}',
        title: T.format('sharePlayWatchFriend', [host, name]),
        detail: detail,
        person: person,
        kind: ActionRow(() => unawaited(app.sharePlay.watch(share.id))),
      );
    }
    if (share.requested || findState.askedToWatch.contains(share.id)) {
      return PanelRow(
        id: 'live-${share.id}',
        title: T.format('discoverAskedToWatch', [host, name]),
        detail: detail,
        person: person,
        kind: const InfoRow(''),
      );
    }
    return PanelRow(
      id: 'live-${share.id}',
      title: T.format('discoverAskToWatch', [host, name]),
      detail: detail,
      person: person,
      kind: ActionRow(() => unawaited(askToWatch(share, host))),
    );
  }

  /// Asks the host of a share play under Live now to let the user watch; their yes comes as an
  /// invite in the Friends panel.
  Future<void> askToWatch(PublicShare share, String host) async {
    try {
      await SharePlayClient(account).askToWatch(share.id);
      findState.askedToWatch = {...findState.askedToWatch, share.id};
      app.show(T.format('discoverAskedToWatchToast', [host]));
    } on Object catch (error) {
      app.show(message(error));
    }
    app.refresh();
  }

  List<PanelRow> publicPartyRows() => [
    PanelRow(
      id: 'pub-title',
      title: T.text('discoverPublicParties'),
      kind: InfoRow(T.text('discoverPublicPartiesDetail')),
    ),
    if (findState.parties.isEmpty)
      PanelRow(id: 'pub-none', title: T.text('discoverNoParties'), kind: const InfoRow('')),
    for (final listed in findState.parties) partyRow(listed),
  ];

  // People.

  String reasonText(List<DiscoverReason> reasons) => [
    for (final reason in reasons)
      ?switch (reason.kind) {
        'game' => T.format('discoverBothPlay', [
          app.games.where((game) => game.titleId == reason.titleId).firstOrNull?.nameFor([_lang]) ??
              pickName(reason.names, _lang) ??
              reason.titleId ??
              '',
        ]),
        'friends' => T.format('discoverFriendsInCommon', [reason.count ?? 0]),
        'language' => T.format('discoverSpeaks', [DiscoverLanguages.name(reason.language ?? '')]),
        _ => null,
      },
  ].join(', ');

  PanelRow personRow(DiscoveredPerson found, {required String prefix, required String detail}) {
    final user = found.user;
    final status = switch (found.state) {
      'in_game' => PersonStatus.playing,
      'offline' => PersonStatus.offline,
      null => null,
      _ => PersonStatus.online,
    };
    final person = TogetherModel.card(user, status: status);
    final name = TogetherModel.shown(user).name;
    final text = ['@${user.handle}', if (detail.isNotEmpty) detail].join('\n');
    if (found.canAsk && !findState.askedFriends.contains(user.id)) {
      return PanelRow(
        id: '$prefix-${user.id}',
        title: T.format('discoverAddFriend', [name]),
        detail: text,
        person: person,
        kind: ActionRow(() => unawaited(addDiscovered(user))),
      );
    }
    final state = switch (found.friendship) {
      'friends' => T.text('discoverAlreadyFriends'),
      'pending_in' => T.text('friendsWantsToBe'),
      _ => T.text('friendsWaiting'),
    };
    return PanelRow(
      id: '$prefix-${user.id}',
      title: name,
      detail: '$text\n$state',
      person: person,
      kind: ActionRow(() => unawaited(openProfile(user.handle, card: user))),
    );
  }

  List<PanelRow> peopleRows() {
    final shown = findState.discovery?.discoverable;
    return [
      PanelRow(
        id: 'people-discovery',
        title: T.text('discoverySettings'),
        detail: shown == null ? T.text('discoveryDetail') : T.text(shown ? 'discoverYouShow' : 'discoverYouHide'),
        kind: ActionRow(openDiscoverySettings),
      ),
      if (findState.suggestions.isEmpty)
        PanelRow(
          id: 'people-none',
          title: T.text('discoverNoSuggestions'),
          kind: InfoRow(T.text('discoverNoSuggestionsDetail')),
        ),
      for (final found in findState.suggestions) personRow(found, prefix: 'people', detail: reasonText(found.reasons)),
    ];
  }

  List<PanelCategory> findPlayersCategories() {
    final waiting = findState.mine.fold(0, (sum, post) => sum + post.pending.length);
    return [
      PanelCategory(id: 'board', title: T.text('discoverBoard'), rows: boardRows()),
      PanelCategory(
        id: 'mine',
        title: waiting > 0 ? '${T.text('discoverMyPosts')} ($waiting)' : T.text('discoverMyPosts'),
        rows: myPostRows(),
      ),
      PanelCategory(
        id: 'parties',
        title: T.text((family.rules?.sharePlay ?? true) ? 'discoverLiveAndParties' : 'discoverPublicParties'),
        rows: [...liveRows(), ...publicPartyRows()],
      ),
      PanelCategory(id: 'people', title: T.text('discoverPeople'), rows: peopleRows()),
    ];
  }

  // A game's hub.

  List<PanelCategory> hubCategories() {
    final titleId = findState.hubTitle;
    if (titleId == null) return const [];
    final name = findState.hubName;
    final local = app.games.where((game) => game.titleId == titleId).firstOrNull;
    final read = findState.hub;
    final summary = screens.compat[titleId];
    final now = <PanelRow>[
      if (read == null)
        PanelRow(
          id: 'hub-loading',
          title: findState.hubFailed ? T.text('togetherUnreachable') : T.text('discoverLoading'),
          kind: const InfoRow(''),
        )
      else ...[
        PanelRow(
          id: 'hub-count',
          title: T.format('discoverPlayingNow', [read.playingTotal]),
          kind: InfoRow(T.format(read.players == 1 ? 'discoverPlayersOne' : 'discoverPlayers', [read.players])),
        ),
        for (final player in read.playing)
          PanelRow(
            id: 'hub-playing-${player.user.id}',
            title: TogetherModel.shown(player.user).name,
            detail: [
              '@${player.user.handle}',
              if (player.since != null)
                T.format('discoverForMinutes', [DateTime.now().difference(player.since!).inMinutes.clamp(1, 1 << 30)]),
            ].join(', '),
            person: TogetherModel.card(player.user, status: PersonStatus.playing),
            kind: ActionRow(() => unawaited(openProfile(player.user.handle, card: player.user))),
          ),
      ],
      if (matchmakingAllowed)
        PanelRow(
          id: 'hub-post',
          title: T.format('discoverFindFor', [name]),
          detail: T.text('discoverFindForDetail'),
          kind: ActionRow(() => openLfgPost(titleId, name)),
        ),
      if (local != null)
        PanelRow(
          id: 'hub-board',
          title: T.text('socialBoardTitle'),
          detail: T.text('socialBoardGameRowDetail'),
          kind: ActionRow(() => openLeaderboard(local)),
        ),
      PanelRow(
        id: 'hub-compat',
        title: T.text('socialCompatCommunity'),
        detail: summary == null ? T.text('socialCompatNone') : compatText(summary),
        kind: local == null ? const InfoRow('') : ActionRow(() => openCompat(local)),
      ),
    ];
    final posts = [for (final post in read?.lfg ?? const <LfgPost>[]) postRow(post, prefix: 'hub-post')];
    final parties = [
      for (final listed in read?.parties ?? const <PublicParty>[]) partyRow(listed, prefix: 'hub-party'),
    ];
    final players = [
      for (final found in read?.recentPlayers ?? const <DiscoveredPerson>[])
        personRow(
          found,
          prefix: 'hub-player',
          detail: found.lastPlayedAt == null
              ? ''
              : T.format('discoverPlayed', [TogetherSocial.ago(found.lastPlayedAt!)]),
        ),
    ];
    return [
      PanelCategory(id: 'hub-now', title: T.text('discoverOverview'), rows: now),
      PanelCategory(
        id: 'hub-posts',
        title: T.text('discoverBoard'),
        rows: posts.isNotEmpty
            ? posts
            : [
                PanelRow(
                  id: 'hub-noposts',
                  title: T.text('discoverNoPosts'),
                  kind: InfoRow(T.text('discoverNoPostsDetail')),
                ),
              ],
      ),
      PanelCategory(
        id: 'hub-parties',
        title: T.text('discoverPublicParties'),
        rows: parties.isNotEmpty
            ? parties
            : [PanelRow(id: 'hub-noparties', title: T.text('discoverNoParties'), kind: const InfoRow(''))],
      ),
      PanelCategory(
        id: 'hub-players',
        title: T.text('discoverPeople'),
        rows: players.isNotEmpty
            ? players
            : [
                PanelRow(
                  id: 'hub-noplayers',
                  title: T.text('discoverNoPlayers'),
                  kind: InfoRow(T.text('discoverNoPlayersDetail')),
                ),
              ],
      ),
    ];
  }

  // The post form.

  List<PanelRow> lfgPostRows() {
    final draft = findState.draft;
    if (draft == null) return const [];
    const languages = DiscoverLanguages.common;
    final first = draft.languages.firstOrNull ?? 'en';
    final second = draft.languages.length > 1 ? draft.languages[1] : null;
    final also = <String?>[
      null,
      for (final code in languages)
        if (code != first) code,
    ];
    const starts = LfgDraft.startChoices;
    void changed() => app.refresh();
    return [
      PanelRow(
        id: 'post-purpose',
        title: T.text('discoverPurpose'),
        detail: T.text(draft.purpose == LfgPurpose.coop ? 'discoverCoopDetail' : 'discoverPartyDetail'),
        kind: ChoiceRow([for (final purpose in LfgPurpose.values) purposeName(purpose)], draft.purpose.index, (index) {
          draft.setPurpose(LfgPurpose.values[index]);
          changed();
        }),
      ),
      PanelRow(
        id: 'post-slots',
        title: T.text('discoverSlots'),
        kind: StepperRow(
          value: draft.slots,
          min: 1,
          max: draft.purpose.maxSlots,
          step: 1,
          format: (value) => '$value',
          set: (value) {
            draft.slots = value;
            changed();
          },
        ),
      ),
      PanelRow(
        id: 'post-language',
        title: T.text('discoverLanguage'),
        kind: ChoiceRow(
          [for (final code in languages) DiscoverLanguages.name(code)],
          languages.indexOf(first).clamp(0, languages.length - 1),
          (index) {
            final pick = languages[index];
            draft.languages = [pick, if (second != null && second != pick) second];
            changed();
          },
        ),
      ),
      PanelRow(
        id: 'post-also',
        title: T.text('discoverAlsoIn'),
        kind: ChoiceRow(
          [for (final code in also) code == null ? T.text('discoverNoOther') : DiscoverLanguages.name(code)],
          also.indexOf(second).clamp(0, also.length - 1),
          (index) {
            draft.languages = [first, ?also[index]];
            changed();
          },
        ),
      ),
      PanelRow(
        id: 'post-start',
        title: T.text('discoverStarts'),
        kind: ChoiceRow(
          [for (final minutes in starts) startText(minutes)],
          starts.indexOf(draft.startsIn).clamp(0, starts.length - 1),
          (index) {
            draft.setStart(starts[index]);
            changed();
          },
        ),
      ),
      PanelRow(
        id: 'post-hours',
        title: T.text('discoverStaysUp'),
        detail: T.text('discoverStaysUpDetail'),
        kind: StepperRow(
          value: draft.hours,
          min: 1,
          max: draft.maxStay,
          step: 1,
          format: (value) => T.format('discoverHours', [value]),
          set: (value) {
            draft.hours = value;
            changed();
          },
        ),
      ),
      PanelRow(
        id: 'post-note',
        title: T.text('discoverNoteTitle'),
        detail: T.text('discoverNoteDetail'),
        kind: TextRow(
          draft.note,
          (text) => draft.note = text.length > LfgDraft.maxNote ? text.substring(0, LfgDraft.maxNote) : text,
          submit: () => unawaited(sendPost()),
        ),
      ),
      PanelRow(
        id: 'post-send',
        title: T.text(findState.posting ? 'discoverPosting' : 'discoverPost'),
        detail: T.text('discoverPostDetail'),
        kind: ActionRow(() => unawaited(sendPost())),
      ),
      PanelRow(id: 'post-cancel', title: T.text('cancel'), kind: ActionRow(backFromFind)),
    ];
  }

  // Actions.

  Future<void> sendPost() async {
    final draft = findState.draft;
    if (draft == null || findState.posting) return;
    findState.posting = true;
    app.refresh();
    try {
      await discover.post(draft);
      app.show(T.format('discoverPosted', [findState.draftName]));
      findState.draft = null;
      if (findState.returnTo == Layer.findPlayers || findState.returnTo == null) {
        findState.returnTo = null;
        openFindPlayers(category: 1);
      } else {
        backFromFind();
      }
    } on Object catch (error) {
      app.show(discoverMessage(error));
    } finally {
      findState.posting = false;
      app.refresh();
    }
  }

  Future<void> imIn(LfgPost post) async {
    try {
      final updated = await discover.join(post.id);
      if (updated != null) _replacePost(updated);
      app.show(T.format('discoverToldThem', [TogetherModel.shown(post.author).name]));
    } on Object catch (error) {
      app.show(discoverMessage(error));
      reloadDiscoverSoon();
    }
  }

  Future<void> takeBack(LfgPost post) async {
    try {
      await discover.takeBack(post.id);
      final updated = await discover.read(post.id);
      if (updated != null) _replacePost(updated);
      app.sounds.play(Cue.back);
    } on Object catch (error) {
      app.show(discoverMessage(error));
    }
  }

  Future<void> answerPost(LfgPost post, Person user, {required bool accept}) async {
    try {
      final updated = await discover.answer(post.id, user.id, accept: accept);
      if (updated != null) _replacePost(updated);
      if (accept) {
        app.show(
          T.format(post.purpose == LfgPurpose.coop ? 'discoverLetInDoneCoop' : 'discoverLetInDone', [
            TogetherModel.shown(user).name,
          ]),
        );
        unawaited(hub.parties.refresh().catchError((Object _) {}));
      }
    } on Object catch (error) {
      app.show(discoverMessage(error));
      reloadDiscoverSoon();
    }
  }

  Future<void> closePost(LfgPost post) async {
    try {
      await discover.close(post.id);
      final (posts, asked) = await discover.mine();
      findState
        ..mine = posts
        ..asked = asked;
      app.sounds.play(Cue.back);
    } on Object catch (error) {
      app.show(discoverMessage(error));
    }
    app.refresh();
  }

  /// A post as it is now, wherever it shows.
  void _replacePost(LfgPost post) {
    List<LfgPost> swap(List<LfgPost> list) => [for (final known in list) known.id == post.id ? post : known];
    findState
      ..board = swap(findState.board)
      ..mine = swap(findState.mine)
      ..asked = findState.asked.any((known) => known.id == post.id)
          ? swap(findState.asked)
          : post.myStatus != null
          ? [post, ...findState.asked]
          : findState.asked
      ..hub = findState.hub?.withPost(post);
    app.refresh();
  }

  /// Let in: to the party (its invite waits there), or watching the share play.
  void followInvite(LfgInvite? invite) {
    if (invite == null) return;
    if (invite.isSharePlay) return unawaited(app.sharePlay.watch(invite.id));
    if (hub.parties.party?.id == invite.id) return app.open(Layer.party);
    unawaited(joinParty(invite.id));
  }

  Future<void> askToJoinParty(PublicParty listed) async {
    try {
      await discover.askToJoin(listed.id);
      app.show(
        T.format('discoverAskedPartyToast', [listed.host == null ? '' : TogetherModel.shown(listed.host!).name]),
      );
      reloadDiscoverSoon();
    } on Object catch (error) {
      app.show(discoverMessage(error));
    }
  }

  Future<void> cancelPartyAsk(PublicParty listed) async {
    try {
      await discover.cancelAsk(listed.id);
      app.sounds.play(Cue.back);
    } on Object catch (error) {
      app.show(discoverMessage(error));
    }
    reloadDiscoverSoon();
  }

  Future<void> addDiscovered(Person user) async {
    try {
      final now = await hub.friends.add(user.handle);
      findState.askedFriends = {...findState.askedFriends, user.id};
      app.show(T.format(now ? 'friendsNowFriends' : 'friendsRequestSent', [TogetherModel.shown(user).name]));
    } on Object catch (error) {
      app.show(message(error));
    }
    app.refresh();
  }

  String discoverMessage(Object error) {
    if (error is! TogetherProblem) return message(error);
    return switch (error.code) {
      'full' => T.text('discoverFull'),
      'rate_limited' => T.text('discoverSlowDown'),
      'conflict' when error.title.contains('open posts') => T.text('discoverTooManyPosts'),
      'conflict' when error.title.contains('closed') => T.text('discoverClosed'),
      _ => message(error),
    };
  }

  // Events.

  /// The board and public lists changed, or someone asked, took it back or answered.
  void findEvent(TogetherEvent event) {
    final data = event.json;
    final from = data['from'];
    final name = from is Map<String, dynamic> && from['userId'] is String
        ? TogetherModel.shown(Person.fromJson(from)).name
        : '';
    switch (event.type) {
      case 'lfg.changed' || 'discover.changed':
        reloadDiscoverSoon();
      // Someone is in for a post, and the answer to one's own "I'm in": over a game the card,
      // Do Not Disturb or not, as on the Mac.
      case 'lfg.request':
        _noticeSound();
        final text = T.format('discoverWantsIn', [name, gameName(data['titleId'] as String? ?? '')]);
        app.show(text);
        unawaited(app.noticeOverGame(text, detail: T.text('discoverFindPlayers'), symbol: Icons.back_hand_rounded));
        unawaited(_refreshMine());
      case 'lfg.request_cancelled':
        unawaited(_refreshMine());
      case 'lfg.answered':
        if (data['answer'] == 'accepted') {
          _noticeSound();
          final invite = LfgInvite.fromJson(data['invite']);
          final text = T.text(invite?.isSharePlay == true ? 'discoverYoureInShare' : 'discoverYoureInParty');
          app.show(text);
          unawaited(
            app.noticeOverGame(text, detail: T.text('discoverFindPlayers'), symbol: Icons.check_circle_rounded),
          );
          unawaited(hub.parties.refresh().catchError((Object _) {}));
        } else {
          app.show(T.text('discoverNotThisTime'));
        }
        unawaited(_refreshMine());
      case 'party.request_answered':
        reloadDiscoverSoon();
    }
  }

  Future<void> _refreshMine() async {
    if (!signedIn) return;
    try {
      final (posts, asked) = await discover.mine();
      findState
        ..mine = posts
        ..asked = asked;
      app.refresh();
    } on Object {
      // Read again with the lists.
    }
    reloadDiscoverSoon();
  }

  // Discovery settings.

  /// Settings › AnyTogether: whether people who don't know the user find them, and their languages.
  List<PanelRow> discoveryRows() {
    final discovery = findState.discovery;
    if (discovery == null || !discoveryAllowed) return const [];
    final choice = switch (discovery.chosen) {
      null => 0,
      true => 1,
      false => 2,
    };
    final offered = DiscoverLanguages.common.take(8).toList();
    return [
      PanelRow(
        id: 'discovery-show',
        title: T.text('discoverShowMe'),
        detail:
            '${T.text('discoverShowMeDetail')} ${T.text(discovery.discoverable ? 'discoverYouShow' : 'discoverYouHide')}.',
        kind: ChoiceRow(
          [T.text('discoverFollowLibrary'), T.text('discoverOn'), T.text('discoverOff')],
          choice,
          (index) => unawaited(
            setDiscovery(
              () => switch (index) {
                1 => true,
                2 => false,
                _ => null,
              },
            ),
          ),
        ),
      ),
      PanelRow(
        id: 'discovery-languages',
        title: T.text('discoverLanguagesTitle'),
        kind: InfoRow(T.text('discoverLanguagesDetail')),
      ),
      for (final code in [
        ...offered,
        for (final code in discovery.languages)
          if (!offered.contains(code)) code,
      ])
        PanelRow(
          id: 'discovery-language-$code',
          title: DiscoverLanguages.name(code),
          kind: ToggleRow(discovery.languages.contains(code), (_) => unawaited(toggleDiscoveryLanguage(code))),
        ),
    ];
  }

  void openDiscoverySettings() {
    openSettings();
    final rows = app.panelCategories()[app.panelCategory].rows;
    final at = rows.indexWhere((row) => row.id == 'discovery-show');
    if (at >= 0) app.panelRow = at;
    app.refresh();
  }

  Future<void> setDiscovery(bool? Function() choice) async {
    try {
      findState.discovery = await discover.setDiscovery(discoverable: choice);
    } on Object catch (error) {
      app.show(message(error));
    }
    app.refresh();
  }

  Future<void> toggleDiscoveryLanguage(String code) async {
    final discovery = findState.discovery;
    if (discovery == null) return;
    final languages = discovery.toggling(code);
    if (languages == null) return app.show(T.text('discoverLanguagesFull'));
    // At once here; the server's answer follows.
    findState.discovery = Discovery(
      discoverable: discovery.discoverable,
      chosen: discovery.chosen,
      languages: languages,
    );
    app.refresh();
    try {
      findState.discovery = await discover.setDiscovery(languages: languages);
    } on Object catch (error) {
      findState.discovery = discovery;
      app.show(message(error));
    }
    app.refresh();
  }

  // Listing the party in public.

  /// The game a public party is about: the one running, else the one selected.
  Game? get listingGame => app.running?.$1 ?? app.selectedGame;

  /// Listing the party in public: off, anyone may ask, anyone may walk in; its game and language.
  List<PanelRow> partyListingRows(Party party) {
    if (!matchmakingAllowed) return const [];
    final listing = party.listing;
    final join = listing == null ? null : (listing.open ? PublicJoin.open : PublicJoin.request);
    final joins = <PublicJoin?>[null, PublicJoin.request, PublicJoin.open];
    final rows = [
      PanelRow(
        id: 'party-public',
        title: T.text('discoverListPublic'),
        detail: T.text('discoverListPublicDetail'),
        kind: ChoiceRow(
          [T.text('discoverListOff'), T.text('discoverListAsk'), T.text('discoverListOpen')],
          joins.indexOf(join).clamp(0, joins.length - 1),
          (index) => unawaited(
            listParty(joins[index], titleId: listing?.titleId ?? listingGame?.titleId, language: listing?.language),
          ),
        ),
      ),
    ];
    if (listing == null) return rows;
    final titles = <String?>[null, ?listingGame?.titleId];
    if (listing.titleId case final title? when !titles.contains(title)) titles.add(title);
    final languages = <String?>[null, ...DiscoverLanguages.common];
    return [
      ...rows,
      PanelRow(
        id: 'party-public-game',
        title: T.text('discoverListGame'),
        kind: ChoiceRow(
          [for (final title in titles) title == null ? T.text('discoverListNoGame') : gameName(title)],
          titles.indexOf(listing.titleId).clamp(0, titles.length - 1),
          (index) => unawaited(listParty(join, titleId: titles[index], language: listing.language)),
        ),
      ),
      PanelRow(
        id: 'party-public-language',
        title: T.text('discoverListLanguage'),
        kind: ChoiceRow(
          [for (final code in languages) code == null ? T.text('discoverAnyLanguage') : DiscoverLanguages.name(code)],
          languages.indexOf(listing.language).clamp(0, languages.length - 1),
          (index) => unawaited(listParty(join, titleId: listing.titleId, language: languages[index])),
        ),
      ),
    ];
  }

  Future<void> listParty(PublicJoin? join, {String? titleId, String? language}) async {
    final id = hub.parties.party?.id;
    if (id == null) return;
    try {
      await discover.listParty(id, join: join, titleId: titleId, language: language);
      await hub.parties.refresh();
    } on Object catch (error) {
      app.show(message(error));
    }
    app.refresh();
  }
}
