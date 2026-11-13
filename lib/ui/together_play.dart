part of 'together_model.dart';

/// Play Together: in a party, the host picks a game and starts it for the party; the others get
/// "Mira started Minecraft — Join", Join checks they have the same game and version (unlocking or
/// updating it first where that helps) and starts it here in the same session with online play
/// on, so the peer mesh joins the virtual LAN and the host's game finds them by broadcast. The
/// party panel shows who plays and how each player is reached; it ends when the host quits.
extension TogetherPlay on TogetherModel {
  /// How many play together at most: the party's size.
  static const capacity = maxPartySize;

  /// This computer's copies of every game, for the join check.
  List<TogetherCopy> togetherCopies() => [
    for (final game in app.games)
      () {
        final unlocked = app.records[game.id] != null;
        final current = engineBuild(game);
        // The engine this game is unlocked with now: its own when it has one.
        final kit = app.engineVersionFor(game);
        final next = kit == null ? null : GameSession.cleanEngineBuild(kit);
        return TogetherCopy(
          id: game.id,
          titleId: game.titleId,
          gameVersion: gameVersion(game),
          engineBuild: current,
          unlocked: unlocked,
          nextEngineBuild: unlocked && next != current ? next : null,
        );
      }(),
  ];

  // Hosting.

  /// The host's Play Together: a LAN session in the party, then the game with online play on.
  /// A copy made by another engine than the one at hand is rebuilt first, so the session carries
  /// the build the party's up-to-date launchers have.
  Future<void> startPlayTogether(Game game) async {
    if (!signedIn || hub.parties.party == null) return;
    final running = app.running;
    if (running != null) return app.show(T.format('togetherCloseFirst', [running.$1.name]));
    if (app.stateOf(game) is! Installed) return app.show(T.format('gameUnlockFirst', [game.name]));
    app.rebuildFirst(game, () => unawaited(_hostPlayTogether(game)));
  }

  Future<void> _hostPlayTogether(Game game) async {
    if (!signedIn || hub.parties.party == null || app.running != null) return;
    app.show(T.format('togetherStarting', [game.name]));
    try {
      final session = await hub.games.startTogether(
        titleId: game.titleId,
        gameVersion: gameVersion(game),
        engineBuild: engineBuild(game),
        capacity: capacity,
      );
      app.show(T.format('togetherStarted', [game.name]));
      _enterTogether(session, game);
    } on TogetherProblem catch (problem) {
      app.show(
        problem.code == 'conflict'
            ? T.text('togetherAlready')
            : '${T.text('togetherStartFailed')}: ${message(problem)}',
      );
    } on Object catch (error) {
      app.show('${T.text('togetherStartFailed')}: ${message(error)}');
    }
  }

  /// In the session: the bridge file and the mesh follow it (the game session listener), online
  /// play is on for this game only, and the game starts. Once the game is over (or never ran),
  /// a session still held ends.
  void _enterTogether(GameSession session, Game game) {
    togetherSession = session.id;
    pollTogetherLinks();
    togetherOffers = togetherOffers.where((offer) => offer.sessionId != session.id).toList();
    if (app.overlay != null) app.closeOverlay();
    app.select(app.games.indexOf(game));
    unawaited(
      // The session carries this copy's engine build: it starts as it is.
      app.play(game, asItIs: true).whenComplete(() {
        if (hub.games.session?.id == session.id && app.running == null) {
          unawaited(hub.games.close(gameExited: true));
        }
      }),
    );
  }

  // Joining.

  /// Join from the party or the offer: the check first, then the game in the same session. After
  /// Try anyway the check looks past the game version (never the engine).
  Future<void> joinPlayTogether(PlayTogetherOffer offer, {bool afterUnlock = false}) async {
    final verdict = PlayTogetherCheck.verdict(
      offer,
      signedIn: signedIn,
      copies: togetherCopies(),
      running: app.running?.$1.name,
      overrideVersion: togetherTryAnyway.contains(offer.sessionId),
    );
    switch (verdict) {
      case JoinWith(:final gameId):
        final game = app.games.where((game) => game.id == gameId).firstOrNull;
        if (game != null) await _joinTogether(offer, game);
      case UnlockAndPlay(:final gameId) || UpdateAndPlay(:final gameId):
        final game = app.games.where((game) => game.id == gameId).firstOrNull;
        if (afterUnlock || game == null) return app.show(T.text('togetherStartFailed'));
        togetherAfterUnlock = (gameId, offer);
        app.show(T.format(verdict is UnlockAndPlay ? 'togetherUnlockingFirst' : 'togetherUpdatingFirst', [game.name]));
        app.unlock(game);
      case OtherGameVersion(:final have, :final need, :final youUpdate):
        tell(
          JoinBlock.gameVersion(
            youUpdate: youUpdate,
            hostName: offer.hostName,
            gameName: gameName(offer.titleId),
            host: need,
            yours: have,
            tryAnyway: canTryAnyway(offer) ? () => unawaited(tryAnywayPlayTogether(offer)) : null,
          ),
        );
      case OtherEngine(:final have, :final need):
        tell(engineBlock(hostName: offer.hostName, titleId: offer.titleId, host: need, yours: have));
      default:
        app.show(verdictText(verdict, offer) ?? '');
    }
  }

  /// An unlock finished: the join waiting on it goes on (or is dropped when it failed).
  void togetherUnlockDone(String gameId, bool succeeded) {
    final waiting = togetherAfterUnlock;
    if (waiting == null || waiting.$1 != gameId) return;
    togetherAfterUnlock = null;
    if (succeeded) unawaited(joinPlayTogether(waiting.$2, afterUnlock: true));
  }

  /// Try anyway: the user chose to join with a game version that does not fit; the server
  /// records it and still checks the engine.
  Future<void> tryAnywayPlayTogether(PlayTogetherOffer offer) {
    togetherTryAnyway.add(offer.sessionId);
    return joinPlayTogether(offer);
  }

  /// Only the game version keeps this computer out, here or as the server said.
  bool canTryAnyway(PlayTogetherOffer offer) {
    final copies = togetherCopies();
    final running = app.running?.$1.name;
    if (PlayTogetherCheck.tryAnyway(offer, signedIn: signedIn, copies: copies, running: running) != null) return true;
    if (!togetherVersionRefused.contains(offer.sessionId)) return false;
    final anyway = PlayTogetherCheck.verdict(
      offer,
      signedIn: signedIn,
      copies: copies,
      running: running,
      overrideVersion: true,
    );
    return anyway is JoinWith || anyway is UnlockAndPlay || anyway is UpdateAndPlay;
  }

  /// The Try Anyway row for an offer, when it can help.
  PanelRow? tryAnywayRow(PlayTogetherOffer offer, String id) => !canTryAnyway(offer)
      ? null
      : PanelRow(
          id: id,
          title: T.text('togetherTryAnyway'),
          detail: T.text('togetherTryAnywayDetail'),
          kind: ActionRow(() => unawaited(tryAnywayPlayTogether(offer))),
        );

  Future<void> _joinTogether(PlayTogetherOffer offer, Game game) async {
    final anyway = togetherTryAnyway.contains(offer.sessionId);
    app.show(
      anyway ? T.format('togetherTryingAnyway', [game.name]) : T.format('togetherJoining', [offer.hostName, game.name]),
    );
    try {
      final joined = await hub.games.join(
        offer.sessionId,
        gameVersion: gameVersion(game),
        engineBuild: engineBuild(game),
        overrideVersion: anyway,
      );
      togetherTryAnyway.remove(offer.sessionId);
      _enterTogether(joined, game);
    } on TogetherProblem catch (problem) {
      final refusal = JoinRefusal.of(problem);
      if (refusal != null) {
        // The party panel offers Try Anyway for a version the server would let by on request.
        if (refusal.overridable && !anyway) togetherVersionRefused.add(offer.sessionId);
        // The host's build changed since the check here: this copy rebuilt may fit it now.
        tell(
          refusalBlock(
            refusal,
            hostName: offer.hostName,
            titleId: offer.titleId,
            rebuild: () => app.rebuildFirst(game, () => unawaited(joinPlayTogether(offer, afterUnlock: true))),
            tryAnyway: anyway ? null : () => unawaited(tryAnywayPlayTogether(offer)),
          ),
        );
      } else {
        app.show(problem.code == 'full' ? T.text('togetherFull') : message(problem));
      }
    } on Object catch (error) {
      app.show(message(error));
    }
  }

  /// What blocks a join, in words; null for a way in. A different engine build says what differs
  /// and what gets past it; Join opens the panel with both builds whole.
  String? verdictText(PlayTogetherVerdict verdict, PlayTogetherOffer offer) {
    final name = gameName(offer.titleId);
    return switch (verdict) {
      JoinWith() || UnlockAndPlay() || UpdateAndPlay() => null,
      SignInFirst() => T.text('togetherSignInFirst'),
      MissingGame() => T.format('togetherMissing', [name]),
      OtherGameVersion(:final have, :final need, :final youUpdate) =>
        youUpdate
            ? T.format('togetherVersionYou', [name, need, have])
            : T.format('togetherVersionHost', [offer.hostName, need, have]),
      OtherEngine(:final have, :final need) => () {
        final texts = engineBlock(hostName: offer.hostName, titleId: offer.titleId, host: need, yours: have).texts;
        return '${texts.title}\n${texts.advice}';
      }(),
      CloseFirst(:final running) => T.format('togetherCloseFirst', [running]),
      SessionFull() => T.text('togetherFull'),
    };
  }

  // Leaving.

  /// The host ends it for everyone; a player leaves it (their game keeps running, alone).
  Future<void> leavePlayTogether() async {
    final session = hub.games.session;
    if (session == null || !session.together) return;
    await hub.games.close();
    app.show(T.text('togetherEndedYours'));
  }

  /// The host's join code for the game, copied for someone outside the party.
  Future<void> shareTogetherCode() async {
    final session = hub.games.session;
    if (session == null || !session.together) return;
    try {
      final code = await hub.games.code();
      app.services.copyText?.call(code.url.isEmpty ? code.code : code.url);
      app.show(T.format('playTogetherCodeCopied', [JoinCode.show(code.code)]));
    } on Object catch (error) {
      app.show(message(error));
    }
  }

  // Peers.

  /// How each other player is reached, every few seconds while the user plays together.
  void pollTogetherLinks() {
    _linkPoll?.cancel();
    _linkPoll = Timer.periodic(const Duration(seconds: 3), (_) => unawaited(_readTogetherLinks()));
    unawaited(_readTogetherLinks());
  }

  Future<void> _readTogetherLinks() async {
    if (hub.games.session?.together != true) {
      _linkPoll?.cancel();
      _linkPoll = null;
      togetherLinks = const {};
      return;
    }
    final transport = online.running?.transport;
    if (transport is! OnlinePeerMesh) return;
    final links = await transport.paths();
    if (_linkPoll == null) return;
    togetherLinks = links;
    if (app.overlay == Layer.party) app.refresh();
  }

  /// "Direct · 23 ms", "Relay · 80 ms", "Connecting…": how another player is reached. Where the
  /// statistics do not say how (see [PeerPath.of]), "Connected" and no number.
  String linkText(String userId) {
    final transport = online.running?.transport;
    final state = transport is OnlinePeerMesh ? transport.states[userId] : null;
    if (state == null || state == PeerState.connecting) return T.text('playTogetherConnecting');
    if (state != PeerState.connected) return T.text('playTogetherUnreachable');
    return linkWords(togetherLinks[userId]);
  }

  /// A connected player's route in words; only what the statistics said.
  static String linkWords(PeerPath? path) {
    final route = switch (path?.route) {
      PeerRoute.direct => T.text('playTogetherDirect'),
      PeerRoute.relay => T.text('playTogetherRelay'),
      _ => T.text('playTogetherConnected'),
    };
    final millis = path?.rttMs;
    return millis == null ? route : '$route · ${T.format('playTogetherMs', [millis])}';
  }

  // Rows.

  /// The party panel's Play Together: the game running (who plays, how each is reached, Join,
  /// Unlock and Play or Update and Play, Leave or End, the host's code), or Play Together for the
  /// game selected on Home.
  List<PanelRow> togetherRows(Party party, String me) {
    final together = party.together;
    // A party is not a game session: said once, over whatever Play Together shows.
    final about = PanelRow(
      id: 'together-about',
      title: T.text('togetherPick'),
      kind: InfoRow(T.text('togetherAbout')),
      wraps: true,
    );
    if (together == null) {
      final game = app.selectedGame;
      if (game == null || app.running != null) {
        return [
          PanelRow(
            id: 'together-pick',
            title: T.text('togetherPick'),
            kind: InfoRow('${T.text('togetherAbout')}\n${T.text('togetherPickDetail')}'),
            wraps: true,
          ),
        ];
      }
      return [
        about,
        PanelRow(
          id: 'together-start',
          title: T.format('togetherStart', [game.name]),
          detail: T.text('togetherStartDetail'),
          kind: ActionRow(() => unawaited(startPlayTogether(game))),
        ),
      ];
    }
    final offer = PlayTogetherOffer.fromParty(
      together,
      party.members,
      name: (person) => TogetherModel.shown(person).name,
    );
    final mine = hub.games.session?.id == together.sessionId;
    final hosting = together.hostId == me;
    final people = {for (final person in party.members) person.id: person};
    final rows = <PanelRow>[
      about,
      PanelRow(
        id: 'together-title',
        title: T.format('togetherTitle', [gameName(together.titleId), together.players.length, together.capacity]),
        kind: InfoRow(T.format('togetherTitleDetail', [offer.hostName, together.gameVersion])),
      ),
      for (final userId in together.players)
        if (people[userId] ?? hub.games.session?.players.where((p) => p.id == userId).firstOrNull
            case final Person person)
          PanelRow(
            id: 'together-player-$userId',
            title: userId == me ? person.displayName : TogetherModel.shown(person).name,
            detail: [
              if (userId != me) TogetherModel.shown(person).handleLine,
              if (userId == together.hostId) T.text('togetherHost'),
              userId == me ? T.text('togetherYou') : (mine ? linkText(userId) : T.text('togetherInGame')),
              if (together.versionOverrides.contains(userId)) T.text('togetherTriedAnyway'),
            ].join(' · '),
            person: TogetherModel.card(person, status: PersonStatus.playing),
            kind: const InfoRow(''),
          ),
    ];
    if (!mine) {
      final verdict = PlayTogetherCheck.verdict(
        offer,
        signedIn: true,
        copies: togetherCopies(),
        running: app.running?.$1.name,
      );
      rows.add(
        PanelRow(
          id: 'together-join',
          title: switch (verdict) {
            UnlockAndPlay() => T.text('togetherUnlockAndPlay'),
            UpdateAndPlay() => T.text('togetherUpdateAndPlay'),
            _ => T.format('togetherJoinRow', [offer.hostName, gameName(together.titleId)]),
          },
          detail: verdictText(verdict, offer) ?? T.text('togetherJoinDetail'),
          kind: ActionRow(() => unawaited(joinPlayTogether(offer))),
          wraps: true,
        ),
      );
      if (tryAnywayRow(offer, 'together-try-anyway') case final PanelRow anyway) rows.add(anyway);
    } else {
      if (hosting) {
        rows.add(
          PanelRow(
            id: 'together-code',
            title: T.text('playTogetherCode'),
            detail: T.text('playTogetherCodeDetail'),
            kind: ActionRow(() => unawaited(shareTogetherCode())),
          ),
        );
      }
      rows.addAll(
        askingFirst(
          PanelRow(
            id: 'together-leave',
            title: hosting ? T.text('togetherEnd') : T.text('togetherLeave'),
            kind: ActionRow(() => unawaited(leavePlayTogether()), destructive: true),
          ),
          T.text(hosting ? 'askEndTogether' : 'askLeaveTogether'),
        ),
      );
    }
    return rows;
  }

  /// The friends panel's offers: "Mira started Minecraft — Join".
  List<PanelRow> togetherOfferRows() => [
    for (final offer in togetherOffers)
      if (offer.sessionId != hub.games.session?.id) ...[
        PanelRow(
          id: 'together-offer-${offer.sessionId}',
          title: T.format('togetherOffer', [offer.hostName, gameName(offer.titleId)]),
          detail: T.text('togetherJoinDetail'),
          kind: ActionRow(() => unawaited(joinPlayTogether(offer))),
        ),
        ?tryAnywayRow(offer, 'together-offer-anyway-${offer.sessionId}'),
      ],
  ];

  // Events.

  /// Someone in the party started Play Together: the offer, a toast and the notice sound.
  void togetherStarted(GameSession session) {
    final offer = PlayTogetherOffer.fromSession(session);
    togetherOffers = [...togetherOffers.where((known) => known.sessionId != offer.sessionId), offer];
    disturbingSound();
    inviteRing();
    final text = T.format('togetherOffer', [offer.hostName, gameName(offer.titleId)]);
    app.show(text);
    // A game in front hears of it over the game, unless the user asked not to be disturbed.
    if (!doNotDisturb) {
      unawaited(app.noticeOverGame(text, detail: T.text('togetherOfferDetail'), symbol: Icons.group_rounded));
    }
    unawaited(hub.parties.refresh().catchError((Object _) {}));
  }

  /// A session ended: its offer goes.
  void togetherEnded(String sessionId) {
    if (!togetherOffers.any((offer) => offer.sessionId == sessionId)) return;
    togetherOffers = togetherOffers.where((offer) => offer.sessionId != sessionId).toList();
    app.refresh();
  }
}
