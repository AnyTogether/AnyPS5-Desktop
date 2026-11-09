part of 'together_model.dart';

/// What can be chosen on a profile before its games: the theme it wears (Theme: name, to the Hub),
/// Compare trophies on someone else's, Edit showcase and Profile theme on the user's own.
enum ProfileAction { theme, compare, editShowcase, profileTheme }

/// Profiles (the user's own and friends') with games, play time and trophies; and playing with
/// friends: while a game runs the launcher opens an AnyTogether game session for it (when the
/// user lets friends join), and a friend's Join starts the same game here when the game version
/// and the engine build match.
extension TogetherProfiles on TogetherModel {
  /// How many can play in a session the launcher opens; the game itself may take fewer.
  static const sessionCapacity = 4;

  Future<void> openMyProfile() async {
    final me = user;
    if (me == null) return;
    await openProfile(
      me.handle,
      card: Person(id: me.id, handle: me.handle, displayName: me.displayName, avatar: me.avatar),
    );
    // The handle changed on the website: the page is read again under the new one.
    if (!profileFailed || app.overlay != Layer.profile) return;
    await hub.self.refreshIfOlder(Duration.zero);
    final now = user;
    if (now == null || now.id != me.id || now.handle == me.handle || app.overlay != Layer.profile) return;
    await openProfile(
      now.handle,
      card: Person(id: now.id, handle: now.handle, displayName: now.displayName, avatar: now.avatar),
    );
  }

  /// Someone's profile, read in full; the layer shows it as it comes.
  Future<void> openProfile(String handle, {Person? card}) async {
    // Back goes where the profile was opened: Settings › AnyTogether on its row, not Settings'
    // first section.
    profileReturn = app.overlay == Layer.profile ? profileReturn : app.spot;
    profile = null;
    profileCard = card;
    profileFailed = false;
    app.open(Layer.profile);
    profileIndex = 0;
    try {
      final page = await hub.profiles.page(handle, card: card);
      if (app.overlay != Layer.profile) return;
      profile = page;
      // The keys start on the first thing to do, past Theme: name.
      if (profileIndex == 0 && profileActions.length > 1 && profileActions.first == ProfileAction.theme) {
        profileIndex = 1;
      }
    } on Object {
      profileFailed = true;
    }
    app.refresh();
  }

  void closeProfile() {
    final back = profileReturn;
    profile = null;
    showcasePins = null;
    themeChoices = null;
    app.returnTo(back);
  }

  /// Someone else's profile, read: their trophies can be compared with the user's.
  bool get canCompare {
    final page = profile;
    return page != null && !page.profile.isMe;
  }

  /// The user's own profile, read, while signed in: its showcase and theme can be changed.
  bool get canEditProfile {
    final page = profile;
    return page != null && page.profile.isMe && signedIn;
  }

  /// What the keys reach before the games, in the order they show.
  List<ProfileAction> get profileActions => [
    if (profile?.profile.look.theme != null) ProfileAction.theme,
    if (canCompare) ProfileAction.compare,
    if (canEditProfile) ...[ProfileAction.editShowcase, ProfileAction.profileTheme],
  ];

  /// Where the games start among the items the keys move through: after the actions.
  int get profileGamesFrom => profileActions.length;

  /// The profile's accent: the one it picked, else its theme's; null for the launcher's own.
  Color? get profileAccent {
    final hex = profile?.profile.look.accentHex;
    if (hex == null) return null;
    return Color(0xFF000000 | int.parse(hex.substring(1), radix: 16));
  }

  /// Items the keys move through: the actions, the games, the trophies, then the recent
  /// activity.
  int get profileItems =>
      profileGamesFrom +
      (profile?.library.value?.length ?? 0) +
      (profile?.trophies.value?.length ?? 0) +
      (profile?.activity.value?.length ?? 0);

  /// The recent activity item at [index] of the keys' items, or null on anything else.
  Activity? profileActivityAt(int index) {
    final page = profile;
    if (page == null) return null;
    final at = index - profileGamesFrom - (page.library.value?.length ?? 0) - (page.trophies.value?.length ?? 0);
    final items = page.activity.value ?? const <Activity>[];
    return at >= 0 && at < items.length ? items[at] : null;
  }

  /// An activity item changed (the gateway's `feed.item`, a reaction in the feed): the profile
  /// shown takes it too.
  void profileActivityChanged(Activity item) {
    final page = profile;
    if (page == null) return;
    final next = page.withActivity(item);
    if (identical(next, page)) return;
    profile = next;
    app.refresh();
  }

  void runProfileAction(ProfileAction action) {
    switch (action) {
      case ProfileAction.theme:
        openWornThemeInHub();
      case ProfileAction.compare:
        compareProfile();
      case ProfileAction.editShowcase:
        openShowcaseEditor();
      case ProfileAction.profileTheme:
        openThemeChooser();
    }
  }

  void profileCommand(Command command) {
    switch (command) {
      case Command.up || Command.down:
        final next = (profileIndex + (command == Command.down ? 1 : -1)).clamp(
          0,
          profileItems == 0 ? 0 : profileItems - 1,
        );
        if (next != profileIndex) app.sounds.play(Cue.move);
        profileIndex = next;
        app.refresh();
      case Command.select when profileIndex < profileActions.length:
        runProfileAction(profileActions[profileIndex]);
      case Command.select:
        // A recent activity item: its game's hub, as the game's name links on the website.
        if (profileActivityAt(profileIndex) case final item? when item.game != null) openActivityGame(item);
      case Command.back || Command.options:
        closeProfile();
      default:
        break;
    }
  }

  // Editing the user's own profile.

  /// Back from Edit showcase or Profile theme to the profile, on the item that opened it.
  void backToProfile() {
    final from = app.overlay == Layer.profileTheme ? ProfileAction.profileTheme : ProfileAction.editShowcase;
    showcasePins = null;
    themeChoices = null;
    app.open(Layer.profile, cue: Cue.back);
    profileIndex = profileActions.indexOf(from).clamp(0, profileItems == 0 ? 0 : profileItems - 1);
    app.refresh();
  }

  /// Edit showcase: the user's trophies and games to pin, six in all.
  void openShowcaseEditor() {
    final page = profile;
    if (page == null || !canEditProfile) return;
    showcasePins = _savedPins = ShowcasePins.of(page.showcase.value);
    // What can be pinned stays put while choosing, whatever each save answers.
    final pinned = page.showcase.value;
    final earned = page.trophies.value ?? const <EarnedTrophy>[];
    final library = page.library.value ?? const <PlayedGame>[];
    _pinChoices = (
      trophies: [
        for (final trophy in pinned?.trophies ?? const <EarnedTrophy>[])
          if (!earned.any((other) => other.titleId == trophy.titleId && other.trophyId == trophy.trophyId)) trophy,
        ...earned,
      ],
      games: [
        for (final game in pinned?.games ?? const <PlayedGame>[])
          if (!library.any((other) => other.titleId == game.titleId)) game,
        ...library,
      ],
    );
    app.open(Layer.showcaseEdit);
  }

  /// The trophies to pin (the ones pinned that the recent list no longer has first), then the
  /// games; each a switch, the heading over the trophies saying how many may be pinned.
  List<PanelRow> showcaseRows() {
    final pins = showcasePins;
    final choices = _pinChoices;
    if (pins == null || choices == null) return const [];
    final language = T.language.code;
    final (:trophies, :games) = choices;
    return [
      PanelRow(id: 'pins-trophies', title: T.text('showcasePickTrophies'), kind: InfoRow(T.text('showcaseHint'))),
      if (trophies.isEmpty)
        PanelRow(id: 'pins-no-trophies', title: T.text('profileNoTrophies'), kind: const InfoRow('')),
      for (final trophy in trophies)
        PanelRow(
          id: 'pin-trophy-${trophy.titleId}-${trophy.trophyId}',
          title: trophy.name(language) ?? T.text('trophyHidden'),
          detail: [
            trophy.gameName(language),
            TogetherProfiles.rarity(trophy.rarityLabel),
          ].where((part) => part.isNotEmpty).join(' · '),
          kind: ToggleRow(
            pins.hasTrophy(trophy.titleId, trophy.trophyId),
            (_) => _pin(showcasePins?.toggleTrophy(trophy.titleId, trophy.trophyId)),
          ),
        ),
      PanelRow(id: 'pins-games', title: T.text('showcasePickGames'), kind: const InfoRow('')),
      if (games.isEmpty) PanelRow(id: 'pins-no-games', title: T.text('profileNoGames'), kind: const InfoRow('')),
      for (final game in games)
        PanelRow(
          id: 'pin-game-${game.titleId}',
          title:
              app.games.where((known) => known.titleId == game.titleId).firstOrNull?.nameFor([language]) ??
              game.name(language),
          detail: TogetherProfiles.playTime(game.secondsPlayed),
          kind: ToggleRow(pins.hasGame(game.titleId), (_) => _pin(showcasePins?.toggleGame(game.titleId))),
        ),
    ];
  }

  /// A pin changed: shown at once and saved; a seventh is refused with the reason.
  void _pin(ShowcasePins? next) {
    if (showcasePins == null) return;
    if (next == null) {
      app.sounds.play(Cue.bump);
      app.show(T.text('showcaseHint'));
      return;
    }
    showcasePins = next;
    app.refresh();
    unawaited(_savePins(next));
  }

  /// PUT /me/showcase with both lists, one save at a time (the last pins win, even after the
  /// editor closed). A refused save puts back the pins saved last and says so; the profile shows
  /// what the server kept.
  Future<void> _savePins(ShowcasePins pins) async {
    _pinsToSave = pins;
    if (savingPins) return;
    savingPins = true;
    try {
      while (_pinsToSave != null) {
        final sending = _pinsToSave!;
        _pinsToSave = null;
        try {
          final saved = await hub.profiles.saveShowcase(sending);
          _savedPins = sending;
          final page = profile;
          if (page != null && page.profile.isMe) profile = page.copyWith(showcase: SectionShown(saved));
        } on Object {
          if (_pinsToSave == null) {
            if (showcasePins != null) showcasePins = _savedPins;
            app.show(T.text('showcaseSaveFailed'));
          }
        }
        app.refresh();
      }
    } finally {
      savingPins = false;
    }
  }

  /// Profile theme: the Hub's popular themes to wear, Take it off for the one worn.
  void openThemeChooser() {
    if (!canEditProfile) return;
    themeChoices = null;
    app.open(Layer.profileTheme);
    unawaited(_loadThemeChoices());
  }

  Future<void> _loadThemeChoices() async {
    themeChoices = null;
    app.refresh();
    Section<List<ProfileTheme>> read;
    try {
      read = SectionShown(await hub.profiles.popularThemes());
    } on Object {
      read = const SectionFailed();
    }
    if (app.overlay != Layer.profileTheme) return;
    themeChoices = read;
    app.refresh();
  }

  /// The theme on the user's profile: as the profile shown says, else as /me said.
  ProfileTheme? get wornTheme {
    final page = profile;
    if (page != null && page.profile.isMe) return page.profile.look.theme;
    return hub.self.wornTheme;
  }

  List<PanelRow> profileThemeRows() {
    final worn = wornTheme;
    final choices = themeChoices;
    return [
      if (worn != null)
        PanelRow(
          id: 'theme-off',
          title: T.text('themeTakeOff'),
          detail: T.format('themeWorn', [worn.name]),
          kind: ActionRow(() => unawaited(wearTheme(null))),
        ),
      ...switch (choices) {
        null => [PanelRow(id: 'theme-loading', title: T.text('hubLoading'), kind: const InfoRow(''))],
        SectionShown(:final items) when items.isEmpty && worn == null => [
          PanelRow(id: 'theme-empty', title: T.text('hubEmpty'), kind: const InfoRow('')),
        ],
        SectionShown(:final items) => [
          for (final theme in [if (worn != null && !items.any((theme) => theme.id == worn.id)) worn, ...items])
            PanelRow(
              id: 'theme-${theme.id}',
              title: theme.name,
              detail: theme.id == worn?.id
                  ? T.text('themeOnProfile')
                  : (theme.makerName == null ? null : T.format('themeBy', [theme.makerName!])),
              kind: ActionRow(() => unawaited(wearTheme(theme.id))),
            ),
        ],
        _ => [
          PanelRow(
            id: 'theme-retry',
            title: T.text('hubFailed'),
            kind: ActionRow(() => unawaited(_loadThemeChoices())),
          ),
        ],
      },
    ];
  }

  /// Puts the Theme Hub theme [id] on the user's profile, or takes the one worn off (null). From
  /// Profile theme it goes back to the profile, which shows it; from the Hub the Hub stays.
  Future<void> wearTheme(String? id) async {
    try {
      final look = await hub.profiles.wearTheme(id);
      hub.self.wornTheme = look.theme;
      final page = profile;
      if (page != null && page.profile.isMe) profile = page.copyWith(profile: page.profile.withLook(look));
      app.show(look.theme == null ? T.text('themeTakenOff') : T.format('themeWornNow', [look.theme!.name]));
      if (app.overlay == Layer.profileTheme) return backToProfile();
    } on Object {
      app.show(T.text('profileThemeFailed'));
    }
    app.refresh();
  }

  /// Theme: name on a profile: the Theme Hub (Settings › Appearance › Themes), on the theme when
  /// it is listed; Back comes back to the profile.
  void openWornThemeInHub() {
    final theme = profile?.profile.look.theme;
    if (theme == null) return;
    hubFromProfile = profileIndex;
    app.open(Layer.themes);
    final rows = app.panelCategories().firstOrNull?.rows ?? const <PanelRow>[];
    final at = rows.indexWhere((row) => row.id == 'hub-${theme.id}');
    if (at >= 0) app.panelRow = at;
    app.refresh();
  }

  /// Back from the Hub opened from a profile; false when it was not.
  bool backFromHubToProfile() {
    final index = hubFromProfile;
    if (index == null || profile == null) return false;
    hubFromProfile = null;
    app.open(Layer.profile, cue: Cue.back);
    profileIndex = index;
    app.refresh();
    return true;
  }

  /// Compare trophies, from the profile shown.
  void compareProfile() {
    final page = profile;
    if (page == null || page.profile.isMe) return;
    final shown = page.profile;
    unawaited(
      openCompare(Person(id: shown.userId, handle: shown.handle, displayName: shown.displayName, avatar: shown.avatar)),
    );
  }

  // Comparing trophies.

  /// The games [person] and the user have trophies in, both-play first; the layer shows them as
  /// they come.
  Future<void> openCompare(Person person) async {
    compareReturn = app.overlay == Layer.compare ? compareReturn : app.spot;
    compareWith = person;
    compareGames = null;
    compareIndex = 0;
    compareTitleId = null;
    comparison = null;
    comparisonIndex = 0;
    app.open(Layer.compare);
    final games = await hub.profiles.compareGames(person.handle);
    if (app.overlay != Layer.compare || compareWith?.id != person.id) return;
    compareGames = games;
    app.refresh();
  }

  /// One game's trophies side by side.
  Future<void> openComparedGame(ComparedGame game) async {
    final person = compareWith;
    if (person == null) return;
    app.sounds.play(Cue.select);
    compareTitleId = game.titleId;
    comparison = null;
    comparisonIndex = 0;
    app.refresh();
    final view = await hub.profiles.compareGame(person.handle, game.titleId);
    if (app.overlay != Layer.compare || compareTitleId != game.titleId) return;
    comparison = view;
    app.refresh();
  }

  void closeCompare() {
    if (compareTitleId != null) {
      compareTitleId = null;
      comparison = null;
      app.sounds.play(Cue.back);
      app.refresh();
      return;
    }
    final back = compareReturn;
    compareWith = null;
    compareGames = null;
    if (back == null) {
      app.closeOverlay();
    } else {
      // Back on the profile it came from, as it was.
      final index = profileIndex;
      app.returnTo(back);
      profileIndex = index;
      if (back.layer == Layer.friendOptions) {
        app.panelRow = app.panelCategories().firstOrNull?.rows.indexWhere((row) => row.id == 'friend-compare') ?? 0;
      }
      app.refresh();
    }
  }

  void compareCommand(Command command) {
    final games = compareGames?.value ?? const <ComparedGame>[];
    final trophies = comparison?.value?.trophies ?? const <ComparedTrophy>[];
    final inGame = compareTitleId != null;
    switch (command) {
      case Command.up || Command.down:
        final count = inGame ? trophies.length : games.length;
        final current = inGame ? comparisonIndex : compareIndex;
        final next = (current + (command == Command.down ? 1 : -1)).clamp(0, count == 0 ? 0 : count - 1);
        if (next != current) app.sounds.play(Cue.move);
        if (inGame) {
          comparisonIndex = next;
        } else {
          compareIndex = next;
        }
        app.refresh();
      case Command.select when !inGame && compareIndex < games.length:
        unawaited(openComparedGame(games[compareIndex]));
      case Command.back || Command.options:
        closeCompare();
      default:
        break;
    }
  }

  /// 3 h 20 min, 4 h, 35 min.
  static String playTime(int seconds) {
    final minutes = seconds ~/ 60;
    final hours = minutes ~/ 60;
    if (hours == 0) return T.format('profileMinutes', [minutes]);
    if (minutes % 60 == 0) return T.format('profileHoursOnly', [hours]);
    return T.format('profileHoursMinutes', [hours, minutes % 60]);
  }

  static String rarity(String? label) => switch (label) {
    'common' => T.text('rarityCommon'),
    'uncommon' => T.text('rarityUncommon'),
    'rare' => T.text('rarityRare'),
    'very_rare' => T.text('rarityVeryRare'),
    'ultra_rare' => T.text('rarityUltraRare'),
    _ => '',
  };

  // Playing together.

  /// The engine a game was unlocked with: only the same build is relied on to talk to itself.
  String engineBuild(Game game) =>
      GameSession.cleanEngineBuild(app.records[game.id]?.toolkit ?? app.toolkit?.version ?? launcherVersion);

  String gameVersion(Game game) => GameSession.cleanGameVersion(game.version);

  /// A session while a game runs (when friends may join), none after; called whenever what runs
  /// changes.
  void followGameSession() {
    if (!signedIn) return;
    final running = app.running;
    final games = hub.games;
    if (running != null) {
      if (!app.preferences.friendsJoin || games.session != null || openingSession) return;
      final game = running.$1;
      openingSession = true;
      unawaited(() async {
        try {
          final session = await games.open(
            titleId: game.titleId,
            gameVersion: gameVersion(game),
            engineBuild: engineBuild(game),
            capacity: sessionCapacity,
          );
          // The game ended while the session was being opened.
          if (app.running?.$1.id != game.id && games.session?.id == session.id) await games.close();
        } on Object {
          // Played alone, then.
        } finally {
          openingSession = false;
        }
      }());
    } else if (games.session != null && app.starting == null) {
      // The game ended: the host's session ends with it (a Play Together game says the game
      // exited), a player leaves theirs.
      unawaited(games.close(gameExited: true));
    } else {
      // Left from a launcher that stopped without ending it.
      games.writeBridge();
    }
  }

  /// "Let friends join my game" turned on or off: a session open now follows.
  Future<void> setFriendsJoin(bool on) async {
    app.preferences.friendsJoin = on;
    app.savePreferences();
    final games = hub.games;
    if (games.session == null || !games.hosting) return followGameSession();
    try {
      await games.setJoinable(on);
    } on Object catch (error) {
      app.show(message(error));
    }
  }

  /// A friend's game, from their presence or an invite: the same game here, checked first.
  Future<void> joinFriendGame(String sessionId, {required String titleId, required String host}) async {
    if (!signedIn) return;
    final game = app.games.where((game) => game.titleId == titleId).firstOrNull;
    if (game == null) return app.show(T.format('gameNotHere', [titleId]));
    final running = app.running;
    if (running != null) return app.show(T.format('gameCloseFirst', [running.$1.name]));
    if (app.stateOf(game) is! Installed) return app.show(T.format('gameUnlockFirst', [game.name]));
    final version = gameVersion(game);
    final engine = engineBuild(game);
    try {
      final session = await hub.games.get(sessionId);
      switch (session.mismatch(gameVersion: version, engineBuild: engine)) {
        case SessionMismatch.gameVersion:
          return app.show(T.format('gameVersionMismatch', [host, session.gameVersion, version]));
        case SessionMismatch.engineBuild:
          return app.show(
            T.format('gameEngineMismatch', [
              host,
              GameSession.release(session.engineBuild),
              GameSession.release(engine),
            ]),
          );
        case null:
          break;
      }
      await hub.games.join(sessionId, gameVersion: version, engineBuild: engine);
      app.show(T.format('gameJoined', [host, game.name]));
      if (app.overlay != null) app.closeOverlay();
      app.select(app.games.indexOf(game));
      unawaited(app.play(game));
    } on TogetherProblem catch (problem) {
      app.show(switch (problem.code) {
        'full' => T.text('gameSessionFull'),
        'version_mismatch' => problem.title,
        _ => message(problem),
      });
    } on Object catch (error) {
      app.show(message(error));
    }
  }

  Future<void> inviteToGame(Friend friend) async {
    try {
      await hub.games.invite([friend.person.id]);
      app.show(T.format('gameInvited', [friend.person.displayName]));
    } on Object catch (error) {
      app.show(message(error));
    }
  }

  /// Friends panel rows: invites to answer, friends' games to join, and (while hosting) friends
  /// to invite.
  List<PanelRow> gameRows() {
    final games = hub.games;
    final session = games.session;
    final rows = <PanelRow>[
      ...togetherOfferRows(),
      for (final invite in games.invites) ...[
        PanelRow(
          id: 'game-accept-${invite.sessionId}',
          title: T.format('gameJoin', [invite.from?.displayName ?? '', gameName(invite.titleId)]),
          detail: T.text('gameInvitedDetail'),
          person: invite.from == null ? null : TogetherModel.card(invite.from!, status: PersonStatus.playing),
          kind: ActionRow(
            () => unawaited(
              joinFriendGame(invite.sessionId, titleId: invite.titleId, host: invite.from?.displayName ?? ''),
            ),
          ),
        ),
        PanelRow(
          id: 'game-decline-${invite.sessionId}',
          title: T.format('gameDecline', [invite.from?.displayName ?? '']),
          kind: ActionRow(
            () => unawaited(games.decline(invite.sessionId).catchError((Object _) {})),
            destructive: true,
          ),
        ),
      ],
      for (final friend in hub.friends.friends)
        if (friend.presence.game case final PresenceGame game
            when game.joinable &&
                game.sessionId != session?.id &&
                !games.invites.any((invite) => invite.sessionId == game.sessionId))
          PanelRow(
            id: 'game-join-${game.sessionId}',
            title: T.format('gameJoin', [friend.person.displayName, gameName(game.titleId)]),
            detail: T.format('gamePlayers', [game.players, game.capacity]),
            person: TogetherModel.card(friend.person, status: PersonStatus.playing),
            kind: ActionRow(
              () => unawaited(joinFriendGame(game.sessionId, titleId: game.titleId, host: friend.person.displayName)),
            ),
          ),
    ];
    if (session != null && games.hosting) {
      final inside = {for (final player in session.players) player.id};
      final invitable = hub.friends.friends.where(
        (friend) => friend.presence.online && !inside.contains(friend.person.id),
      );
      if (invitable.isNotEmpty) {
        rows.add(
          PanelRow(
            id: 'game-invite-title',
            title: T.format('gameInviteTitle', [gameName(session.titleId)]),
            kind: InfoRow(T.format('gamePlayers', [session.players.length, session.capacity])),
          ),
        );
        for (final friend in invitable) {
          rows.add(
            PanelRow(
              id: 'game-invite-${friend.person.id}',
              title: T.format('partyInvite', [friend.person.displayName]),
              detail: presenceText(friend.presence),
              person: TogetherModel.card(friend.person, status: TogetherModel.status(friend.presence)),
              kind: ActionRow(() => unawaited(inviteToGame(friend))),
            ),
          );
        }
      }
    }
    return rows;
  }
}
