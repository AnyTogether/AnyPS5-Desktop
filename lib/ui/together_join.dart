part of 'together_model.dart';

/// What holds a join back, said whole in its own panel (a toast is one line): what differs (the
/// game version or the engine build), the host's and this copy's, each untruncated on its own
/// line, and what gets past it.
class JoinBlock {
  const JoinBlock.engine({
    required EngineAdvice this.advice,
    required this.hostName,
    required this.gameName,
    required this.host,
    required this.yours,
    this.rebuild,
  }) : youUpdate = false,
       tryAnyway = null;

  const JoinBlock.gameVersion({
    required this.youUpdate,
    required this.hostName,
    required this.gameName,
    required this.host,
    required this.yours,
    this.tryAnyway,
  }) : advice = null,
       rebuild = null;

  /// What gets past a different engine build; null when it is the game version that differs.
  final EngineAdvice? advice;

  /// A different game version: whether this side is the one behind.
  final bool youUpdate;
  final String hostName;
  final String gameName;

  /// The host's engine build or game version, and this copy's, as they are.
  final String host;
  final String yours;

  /// Rebuilds this copy and joins again, when that gets past it.
  final void Function()? rebuild;

  /// Joins with the game version as it is, when the host's rule lets a player try.
  final void Function()? tryAnyway;

  /// What differs, the sentence that says so, and what gets past it.
  ({String title, String detail, String advice}) get texts => switch (advice) {
    null => (
      title: T.text('togetherBlockedVersion'),
      detail: T.format('togetherBlockedVersionDetail', [hostName, gameName]),
      advice: youUpdate
          ? T.format('togetherVersionYou', [gameName, host, yours])
          : T.format('togetherVersionHost', [hostName, host, yours]),
    ),
    final EngineAdvice advice => (
      title: T.text('togetherBlockedEngine'),
      detail: T.format('togetherBlockedEngineDetail', [hostName, gameName]),
      advice: switch (advice) {
        EngineAdvice.rebuild => T.text('togetherAdviceRebuild'),
        EngineAdvice.updateYours => T.format('togetherAdviceUpdateYours', [hostName]),
        EngineAdvice.hostNightly => T.format('togetherAdviceHostNightly', [hostName]),
        EngineAdvice.updateHost => T.format('togetherAdviceUpdateHost', [hostName]),
        EngineAdvice.sameEngine => T.text('togetherAdviceSameEngine'),
      },
    ),
  };
}

/// A game being started from the library while someone the user knows plays it.
class JoinChoice {
  const JoinChoice({required this.game, required this.other, required this.name});
  final Game game;
  final JoinableGame other;

  /// Whose game it is, as the user knows them.
  final String name;
}

/// Being in a party is not being in the same game: the party is voice and chat, the game session
/// is what connects the games. Play on a game a party member or friend already hosts asks whether
/// to join theirs; the party and the quick menu say for each member whether they are in the
/// user's game; and a join that cannot go on says why in full (JoinChoice.swift on the Mac).
extension TogetherJoin on TogetherModel {
  // Join theirs, or start your own.

  /// How the user knows someone by id: a party member's or friend's shown name.
  String knownName(String userId) {
    final member = hub.parties.party?.members.where((person) => person.id == userId).firstOrNull;
    if (member != null) return TogetherModel.shown(member).name;
    final friend = hub.friends.friends.where((friend) => friend.person.id == userId).firstOrNull;
    if (friend != null) return TogetherModel.shown(friend.person).name;
    return hub.games.session?.players.where((player) => player.id == userId).firstOrNull?.displayName ?? '';
  }

  /// The game someone the user knows hosts that [game] could join instead of starting alone.
  JoinableGame? joinableGame(Game game) {
    final me = user;
    if (me == null) return null;
    return JoinableGame.find(
      titleId: game.titleId,
      me: me.id,
      mine: hub.games.session?.id,
      party: hub.parties.party,
      friends: hub.friends.friends,
    );
  }

  /// Play from the library: a game someone the user knows already hosts asks first, so the two do
  /// not end up in separate sessions without a word; anything else starts.
  void playOrJoin(Game game) {
    final other = joinableGame(game);
    if (other == null) return unawaited(app.play(game));
    joinChoice = JoinChoice(game: game, other: other, name: knownName(other.personId));
    app.open(Layer.joinOrHost);
  }

  /// Joins the game a choice or a member's row names: the party's Play Together game as one, a
  /// friend's own session as a friend's game.
  void joinKnownGame(JoinableGame other, String name) {
    final party = hub.parties.party;
    final together = party?.together;
    if (other.together && party != null && together != null && together.sessionId == other.sessionId) {
      final offer = PlayTogetherOffer.fromParty(
        together,
        party.members,
        name: (person) => TogetherModel.shown(person).name,
      );
      unawaited(joinPlayTogether(offer));
    } else {
      unawaited(joinFriendGame(other.sessionId, titleId: other.titleId, host: name));
    }
  }

  /// The question's rows: what is asked, Join first (the default), then a game of one's own.
  List<PanelRow> joinOrHostRows(JoinChoice choice) => [
    PanelRow(
      id: 'choice-ask',
      title: T.text('togetherPick'),
      kind: InfoRow(T.format('togetherAskJoin', [choice.name])),
      wraps: true,
    ),
    PanelRow(
      id: 'choice-join',
      title: T.format('togetherJoinRow', [choice.name, choice.game.name]),
      detail: T.text('togetherJoinDetail'),
      kind: ActionRow(() {
        app.closeOverlay();
        joinChoice = null;
        joinKnownGame(choice.other, choice.name);
      }),
    ),
    PanelRow(
      id: 'choice-own',
      title: T.text('togetherAskOwn'),
      detail: T.format('togetherAskOwnDetail', [choice.name]),
      kind: ActionRow(() {
        app.closeOverlay();
        joinChoice = null;
        app.show(T.format('togetherSeparate', [choice.name]));
        unawaited(app.play(choice.game));
      }),
    ),
  ];

  // A join held back.

  /// The engine build unlocking [titleId]'s copy again would give, when that differs from the
  /// one it was made with.
  String? rebuildGives(String titleId) => togetherCopies()
      .where((copy) => copy.titleId == titleId && copy.nextEngineBuild != null)
      .firstOrNull
      ?.nextEngineBuild;

  /// The block a different engine build makes: who is behind is read from the two releases.
  JoinBlock engineBlock({
    required String hostName,
    required String titleId,
    required String host,
    required String yours,
    void Function()? rebuild,
  }) {
    final advice = EngineAdvice.of(yours: yours, host: host, rebuildGives: rebuildGives(titleId));
    return JoinBlock.engine(
      advice: advice,
      hostName: hostName,
      gameName: gameName(titleId),
      host: host,
      yours: yours,
      rebuild: advice == EngineAdvice.rebuild ? rebuild : null,
    );
  }

  /// The server's refusal of a join as the panel says it: its two versions or builds whole.
  JoinBlock refusalBlock(
    JoinRefusal refusal, {
    required String hostName,
    required String titleId,
    void Function()? rebuild,
    void Function()? tryAnyway,
  }) => refusal.engine
      ? engineBlock(
          hostName: hostName,
          titleId: titleId,
          host: refusal.expected,
          yours: refusal.actual,
          rebuild: rebuild,
        )
      : JoinBlock.gameVersion(
          youUpdate: refusal.youUpdate,
          hostName: hostName,
          gameName: gameName(titleId),
          host: refusal.expected,
          yours: refusal.actual,
          tryAnyway: refusal.overridable ? tryAnyway : null,
        );

  /// Says a held-back join whole, in its panel.
  void tell(JoinBlock block) {
    joinBlock = block;
    app.open(Layer.joinBlocked, cue: Cue.back);
  }

  /// The panel's rows: what differs and what to do, the host's build and this one's whole, then
  /// the action that fits (rebuild and join, check for updates, try anyway) and Close.
  List<PanelRow> joinBlockedRows(JoinBlock block) {
    final texts = block.texts;
    final rebuild = block.rebuild;
    final tryAnyway = block.tryAnyway;
    void close() {
      app.closeOverlay();
      joinBlock = null;
    }

    return [
      PanelRow(id: 'blocked-what', title: texts.title, kind: InfoRow('${texts.detail}\n${texts.advice}'), wraps: true),
      PanelRow(id: 'blocked-host', title: block.hostName, kind: InfoRow(block.host), wraps: true),
      PanelRow(id: 'blocked-you', title: T.text('togetherYou'), kind: InfoRow(block.yours), wraps: true),
      if (rebuild != null)
        PanelRow(
          id: 'blocked-rebuild',
          title: T.text('togetherRebuildAndJoin'),
          kind: ActionRow(() {
            close();
            rebuild();
          }),
        ),
      // Update is only offered when this side's release is the older one.
      if (block.advice == EngineAdvice.updateYours)
        PanelRow(
          id: 'blocked-update',
          title: T.text('checkForUpdatesNow'),
          detail: T.text('checkForUpdatesDetail'),
          kind: ActionRow(() {
            close();
            unawaited(app.updates.check());
          }),
        ),
      if (tryAnyway != null)
        PanelRow(
          id: 'blocked-try-anyway',
          title: T.text('togetherTryAnyway'),
          detail: T.text('togetherTryAnywayDetail'),
          kind: ActionRow(() {
            close();
            tryAnyway();
          }),
        ),
      PanelRow(id: 'blocked-close', title: T.text('close'), kind: ActionRow(close)),
    ];
  }

  // Who is in whose game.

  /// What a party member plays next to the user's own game; null when nothing is known of them.
  MemberGame? memberGame(Person member, Party party) {
    final friend = hub.friends.friends.where((friend) => friend.person.id == member.id).firstOrNull;
    return MemberGame.of(
      member.id,
      mine: hub.games.session,
      together: party.together,
      presence: friend?.presence.game,
      friend: friend != null,
    );
  }

  /// "In your game", "In another game of Greenhollow", "Playing Greenhollow", "Not in a game".
  String memberGameText(MemberGame state) => switch (state) {
    InYourGame() => T.text('partyInYourGame'),
    InOtherGame(:final titleId, :final sameTitle) => T.format(sameTitle ? 'partyInOtherGame' : 'friendsPlaying', [
      gameName(titleId),
    ]),
    InNoGame() => T.text('partyNotInGame'),
  };

  /// The Join row for a member in another game that takes players; null for anyone else. The
  /// party's own Play Together game has its Join in the Play Together rows above.
  PanelRow? memberJoinRow(Person member, Party party, String id) {
    final state = memberGame(member, party);
    if (state is! InOtherGame || !state.joinable) return null;
    final name = TogetherModel.shown(member).name;
    return PanelRow(
      id: id,
      title: T.format('togetherJoinRow', [name, gameName(state.titleId)]),
      detail: memberGameText(state),
      person: TogetherModel.card(member, status: PersonStatus.playing),
      kind: ActionRow(
        () => joinKnownGame(
          JoinableGame(
            sessionId: state.sessionId,
            titleId: state.titleId,
            personId: state.hostId,
            together: state.together,
          ),
          name,
        ),
      ),
    );
  }

  /// The quick menu's party: each other member with what they play; one in another game that
  /// takes players is the Join itself.
  List<PanelRow> partyGameRows() {
    final me = user;
    final party = hub.parties.party;
    if (me == null || party == null) return const [];
    final joins = <String>{};
    final rows = <PanelRow>[];
    for (final member in party.members) {
      if (member.id == me.id) continue;
      final state = memberGame(member, party);
      if (state == null) continue;
      final join = state is InOtherGame && state.joinable && joins.add(state.sessionId)
          ? memberJoinRow(member, party, 'party-game-${member.id}')
          : null;
      rows.add(
        join ??
            PanelRow(
              id: 'party-game-${member.id}',
              title: TogetherModel.shown(member).name,
              person: TogetherModel.card(member, status: state is InNoGame ? null : PersonStatus.playing),
              kind: InfoRow(memberGameText(state)),
            ),
      );
    }
    return rows;
  }
}
