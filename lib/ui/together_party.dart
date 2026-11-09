part of 'together_model.dart';

/// Parties on AnyTogether: start one (invite only, or open to friends), invite friends, see who is
/// in it, accept an invite or walk into a friend's open party, leave; a join code for people who
/// are not friends to ask with, their requests, the party's Discord link; and its voice, with the
/// microphone, push-to-talk and the talk key.
extension TogetherParty on TogetherModel {
  int get partyBadge {
    final party = hub.parties.party;
    final requests = party != null && party.leads(user?.id ?? '') ? party.requests.length : 0;
    return hub.parties.invites.where((invite) => invite.partyId != party?.id).length + requests;
  }

  List<PanelRow> partyRows() {
    final me = user;
    if (me == null) {
      return [
        PanelRow(id: 'party-out', title: T.text('friendsSignIn'), kind: InfoRow(T.text('togetherIntroDetail'))),
        PanelRow(id: 'party-signin', title: T.text('togetherSignIn'), kind: ActionRow(openSettings)),
      ];
    }
    final parties = hub.parties;
    final party = parties.party;
    final rows = <PanelRow>[
      for (final invite in parties.invites)
        if (invite.partyId != party?.id) ...[
          PanelRow(
            id: 'party-accept-${invite.partyId}',
            title: T.format('partyJoinOf', [invite.from?.displayName ?? '?']),
            detail: invite.size == null ? null : T.format('partySize', [invite.size!, maxPartySize]),
            person: invite.from == null ? null : TogetherModel.card(invite.from!),
            kind: ActionRow(() => unawaited(joinParty(invite.partyId))),
          ),
          PanelRow(
            id: 'party-decline-${invite.partyId}',
            title: T.format('partyDecline', [invite.from?.displayName ?? '?']),
            kind: ActionRow(() => unawaited(declineParty(invite.partyId)), destructive: true),
          ),
        ],
    ];
    if (party == null) {
      rows.addAll([
        ...codePreviewRows(),
        PanelRow(
          id: 'party-start',
          title: T.text('partyStart'),
          detail: T.text('partyStartDetail'),
          kind: ActionRow(() => unawaited(startParty())),
        ),
        PanelRow(
          id: 'party-open',
          title: T.text('partyOpen'),
          detail: T.text('partyOpenDetail'),
          kind: ToggleRow(partyStartsOpen, (value) {
            partyStartsOpen = value;
            app.refresh();
          }),
        ),
        if (codePreview == null) ...[
          PanelRow(
            id: 'party-code-enter',
            title: T.text('partyCodeEnter'),
            kind: TextRow(
              joinCodeDraft,
              (text) => joinCodeDraft = text,
              submit: () => unawaited(lookUpCode()),
              hint: 'XXXX-XXXX',
            ),
          ),
          PanelRow(
            id: 'party-code-look',
            title: T.text('partyCodeLook'),
            kind: ActionRow(() => unawaited(lookUpCode())),
          ),
        ],
        // Friends whose party is open to them.
        for (final friend in hub.friends.friends)
          if (friend.presence.party case final PresenceParty open when open.open && open.size < open.max)
            PanelRow(
              id: 'party-walkin-${open.id}',
              title: T.format('partyJoinOf', [friend.person.displayName]),
              detail: T.format('partySize', [open.size, open.max]),
              person: TogetherModel.card(friend.person, status: TogetherModel.status(friend.presence)),
              kind: ActionRow(() => unawaited(joinParty(open.id))),
            ),
        if (matchmakingAllowed)
          PanelRow(
            id: 'party-find',
            title: T.text('discoverFindParty'),
            detail: T.text('discoverFindPartyDetail'),
            kind: ActionRow(() => openFindPlayers(category: 2)),
          ),
      ]);
      return rows;
    }
    final voice = hub.voice;
    final leader = party.leads(me.id);
    rows.addAll([
      if (leader)
        for (final person in party.requests) ...[
          PanelRow(
            id: 'party-request-${person.id}',
            title: T.format('partyRequestLet', [person.displayName]),
            detail:
                '@${person.handle} · ${hub.parties.requestVia[person.id] == 'code' ? T.text('partyRequestWithCode') : T.text('partyRequestAsks')}',
            person: TogetherModel.card(person),
            kind: ActionRow(() => unawaited(answerRequest(person, accept: true))),
          ),
          PanelRow(
            id: 'party-request-decline-${person.id}',
            title: T.format('partyRequestTurnDown', [person.displayName]),
            kind: ActionRow(() => unawaited(answerRequest(person, accept: false)), destructive: true),
          ),
        ],
      ...voiceRows(party),
      ...togetherRows(party, me.id),
      PanelRow(
        id: 'party-members',
        title: T.format('partyMembers', [party.members.length, party.max]),
        kind: const InfoRow(''),
      ),
      for (final member in party.members)
        PanelRow(
          id: 'party-member-${member.id}',
          // A friend's friends-only name, with the handle (and public name) beside.
          title: member.id == me.id
              ? '${member.displayName} (${T.text('profileYou')})'
              : TogetherModel.shown(member).name,
          detail: [
            if (member.id == me.id) '@${member.handle}' else TogetherModel.shown(member).handleLine,
            if (party.leads(member.id)) T.text('partyLeader'),
            if (party.inCall.contains(member.id)) T.text('partyInVoice'),
            if (party.deafened.contains(member.id))
              T.text('joinDeafened')
            else if (party.muted.contains(member.id))
              T.text('voiceMuted'),
          ].join(' · '),
          person: TogetherModel.card(
            member,
            status: party.inCall.contains(member.id) ? PersonStatus.online : null,
            speaking: member.id == me.id ? voice.speaking : voice.speakingOf(member.id),
          ),
          kind: const InfoRow(''),
        ),
      if (leader)
        for (final member in party.members)
          if (member.id != me.id)
            ...askingFirst(
              PanelRow(
                id: 'party-kick-${member.id}',
                title: T.format('partyKick', [TogetherModel.shown(member).name]),
                kind: ActionRow(() => unawaited(kick(member)), destructive: true),
              ),
              T.format('askKick', [TogetherModel.shown(member).name]),
            ),
      // Handing the party over asks first: only the new leader can give it back.
      if (leader)
        for (final member in party.members)
          if (member.id != me.id)
            ...askingFirst(
              PanelRow(
                id: 'party-lead-${member.id}',
                title: T.format('partyMakeLeader', [TogetherModel.shown(member).name]),
                kind: ActionRow(() => unawaited(makeLeader(member))),
              ),
              T.format('askMakeLeader', [TogetherModel.shown(member).name]),
            ),
      if (leader)
        PanelRow(
          id: 'party-privacy',
          title: T.text('partyOpen'),
          detail: T.text('partyOpenDetail'),
          kind: ToggleRow(party.open, (value) => unawaited(setPartyOpen(value))),
        ),
      if (leader) ...joinCodeRows(party),
      if (leader) ...partyListingRows(party),
      ...discordRows(party, leader: leader),
    ]);
    final invitable = hub.friends.friends.where((friend) => !party.has(friend.person.id)).toList();
    final invited = {for (final person in party.invited) person.id};
    if (invitable.isNotEmpty && !party.full) {
      rows.add(PanelRow(id: 'party-invite-title', title: T.text('partyInviteFriends'), kind: const InfoRow('')));
      for (final friend in invitable) {
        final status = TogetherModel.status(friend.presence);
        rows.add(
          invited.contains(friend.person.id)
              ? PanelRow(
                  id: 'party-invited-${friend.person.id}',
                  title: TogetherModel.shown(friend.person).name,
                  detail: '${TogetherModel.shown(friend.person).handleLine} · ${T.text('partyInvited')}',

                  person: TogetherModel.card(friend.person, status: status),
                  kind: const InfoRow(''),
                )
              : PanelRow(
                  id: 'party-invite-${friend.person.id}',
                  title: T.format('partyInvite', [TogetherModel.shown(friend.person).name]),
                  detail: '${TogetherModel.shown(friend.person).handleLine} · ${presenceText(friend.presence)}',

                  person: TogetherModel.card(friend.person, status: status),
                  kind: ActionRow(() => unawaited(inviteToParty(friend.person))),
                ),
        );
      }
    }
    rows.addAll(
      askingFirst(
        PanelRow(
          id: 'party-leave',
          title: T.text('partyLeave'),
          kind: ActionRow(() => unawaited(leaveParty()), destructive: true),
        ),
        T.text('askLeaveParty'),
      ),
    );
    return rows;
  }

  /// The leader's join code: the code, copying it or its link, a new one, stopping it.
  List<PanelRow> joinCodeRows(Party party) {
    final code = party.joinCode;
    if (code == null) {
      return [
        PanelRow(
          id: 'party-code-new',
          title: T.text('partyCodeMake'),
          detail: T.text('partyCodeMakeDetail'),
          kind: ActionRow(() => unawaited(newJoinCode())),
        ),
      ];
    }
    return [
      PanelRow(id: 'party-code', title: code.shown, detail: T.text('partyCodeDetail'), kind: const InfoRow('')),
      PanelRow(
        id: 'party-code-copy',
        title: T.text('partyCodeCopy'),
        kind: ActionRow(() => copy(code.shown, T.text('partyCodeCopied'))),
      ),
      PanelRow(
        id: 'party-code-link',
        title: T.text('partyCodeCopyLink'),
        kind: ActionRow(() => copy(code.url.toString(), T.text('partyLinkCopied'))),
      ),
      PanelRow(id: 'party-code-new', title: T.text('partyCodeNew'), kind: ActionRow(() => unawaited(newJoinCode()))),
      PanelRow(
        id: 'party-code-stop',
        title: T.text('partyCodeStop'),
        kind: ActionRow(() => unawaited(stopJoinCode()), destructive: true),
      ),
    ];
  }

  /// The party's Discord link: the leader types or removes it; everyone opens it.
  List<PanelRow> discordRows(Party party, {required bool leader}) {
    final link = party.discord;
    return [
      if (leader)
        PanelRow(
          id: 'party-discord',
          title: T.text('partyDiscord'),
          detail: T.text('partyDiscordDetail'),
          kind: TextRow(
            discordDraft ?? link ?? '',
            (text) => discordDraft = text,
            submit: () => unawaited(setDiscord(discordDraft ?? link ?? '')),
            hint: 'https://discord.gg/…',
          ),
        ),
      if (link != null)
        PanelRow(
          id: 'party-discord-open',
          title: T.text('partyDiscordOpen'),
          detail: link,
          kind: ActionRow(() => openDiscord(link)),
        ),
      if (leader && link != null)
        PanelRow(
          id: 'party-discord-clear',
          title: T.text('partyDiscordClear'),
          kind: ActionRow(() => unawaited(setDiscord('')), destructive: true),
        ),
    ];
  }

  /// What the code looked up opens, and asking to join it.
  List<PanelRow> codePreviewRows() {
    final preview = codePreview;
    if (preview == null) return const [];
    final host = preview.host?.displayName ?? '?';
    final game = preview.game;
    final gameText = game == null
        ? null
        : app.games.any((known) => known.titleId == game.titleId)
        ? gameName(game.titleId)
        : game.name(T.language.code);
    return [
      PanelRow(
        id: 'party-code-preview',
        title: T.format('partyCodeOf', [host]),
        detail: preview.party
            ? [
                T.format('partySize', [preview.size, preview.max]),
                ?gameText,
              ].join(' · ')
            : T.text('partyCodeSharePlay'),
        person: preview.host == null ? null : TogetherModel.card(preview.host!),
        kind: const InfoRow(''),
      ),
      if (preview.party)
        switch (preview.state) {
          'requested' => PanelRow(
            id: 'party-code-asked',
            title: T.format('partyCodeWaiting', [host]),
            kind: const InfoRow(''),
          ),
          'invited' => PanelRow(id: 'party-code-state', title: T.text('partyCodeInvited'), kind: const InfoRow('')),
          'member' => PanelRow(id: 'party-code-state', title: T.text('partyCodeMember'), kind: const InfoRow('')),
          _ => PanelRow(
            id: 'party-code-ask',
            title: T.text('partyCodeAsk'),
            kind: ActionRow(() => unawaited(askWithCode())),
          ),
        },
      PanelRow(id: 'party-code-cancel', title: T.text('cancel'), kind: ActionRow(closeCodePreview)),
    ];
  }

  /// The party's voice: joining, the microphone, push-to-talk and its key, leaving.
  List<PanelRow> voiceRows(Party party) {
    final voice = hub.voice;
    if (!family.voiceAllowed && !voice.active) {
      return [PanelRow(id: 'voice-off', title: T.text('familyNoVoice'), kind: InfoRow(T.text('familyNoVoiceDetail')))];
    }
    // In a call with a friend, the party's voice is joined in its place.
    if (!voice.active || voice.friend != null) {
      final elsewhere = voice.movedTo;
      if (elsewhere != null && party.inCall.contains(user?.id)) {
        return [
          PanelRow(
            id: 'voice-join',
            title: T.text('voiceTakeBack'),
            detail: T.text(elsewhere == 'phone' ? 'voiceOnPhone' : 'voiceOnOtherDevice'),
            kind: ActionRow(() => unawaited(joinVoice())),
          ),
        ];
      }
      final others = party.inCall.where((id) => id != user?.id).length;
      return [
        PanelRow(
          id: 'voice-join',
          title: T.text('voiceJoin'),
          detail: others > 0 ? T.format('voiceInCall', [others]) : T.text('voiceJoinDetail'),
          kind: ActionRow(() => unawaited(joinVoice())),
        ),
      ];
    }
    return voiceControlRows();
  }

  /// The microphone, deafen, push-to-talk and its key, and leaving: the same in the party's
  /// voice and a call with a friend.
  List<PanelRow> voiceControlRows() {
    final voice = hub.voice;
    final key = talkKeyName;
    return [
      if (!voice.pushToTalk)
        PanelRow(
          id: 'voice-mic',
          title: T.text('voiceMic'),
          detail: T.format('voicePushToTalkOff', [key]),
          kind: ToggleRow(!voice.muted, (value) => voice.setMuted(!value)),
        ),
      PanelRow(
        id: 'voice-noise',
        title: T.text('noiseSuppression'),
        detail: T.text(voice.noiseSuppression ? 'noiseSuppressionOn' : 'noiseSuppressionOff'),
        kind: ToggleRow(voice.noiseSuppression, setNoiseSuppression),
      ),
      PanelRow(
        id: 'voice-deafen',
        title: T.text('joinDeafen'),
        detail: T.text('joinDeafenDetail'),
        kind: ToggleRow(voice.deafened, voice.setDeafened),
      ),
      PanelRow(
        id: 'voice-ptt',
        title: T.text('voicePushToTalk'),
        detail: voice.pushToTalk ? T.format('voicePushToTalkOn', [key]) : null,
        kind: ToggleRow(voice.pushToTalk, setPushToTalk),
      ),
      PanelRow(
        id: 'voice-key',
        title: T.text('voiceTalkKey'),
        detail: talkWatch == null ? T.text('voiceTalkKeyHere') : T.text('voiceTalkKeyDetail'),
        kind: KeysRow(['KEY:$key'], capturing: capturingTalkKey, capture: captureTalkKey),
      ),
      PanelRow(
        id: 'voice-leave',
        title: T.text(voice.friend == null ? 'voiceLeave' : 'callHangUp'),
        detail: voice.viaServer ? T.text('mediaViaServer') : null,
        kind: ActionRow(() => unawaited(hub.voice.leave()), destructive: true),
      ),
    ];
  }

  String get talkKeyName => Controls.keyName(talkKey) ?? '?';

  Future<void> _partyCall(Future<void> Function() call) async {
    try {
      await call();
    } on TogetherProblem catch (problem) {
      app.show(problem.code == 'full' ? T.text('partyFull') : message(problem));
    } on Object catch (error) {
      app.show(message(error));
    }
  }

  Future<void> startParty() => _partyCall(() => hub.parties.create(open: partyStartsOpen));

  Future<void> joinParty(String id) => _partyCall(() => hub.parties.join(id));

  Future<void> declineParty(String id) => _partyCall(() => hub.parties.decline(id));

  Future<void> setPartyOpen(bool open) => _partyCall(() => hub.parties.setOpen(open));

  Future<void> kick(Person person) => _partyCall(() => hub.parties.kick(person.id));

  Future<void> makeLeader(Person person) => _partyCall(() => hub.parties.makeLeader(person.id));

  Future<void> inviteToParty(Person person) => _partyCall(() async {
    if (hub.parties.party == null) await hub.parties.create(open: partyStartsOpen);
    await hub.parties.invite([person.id]);
    app.show(T.format('gameInvited', [person.displayName]));
  });

  Future<void> newJoinCode() {
    // A code the user makes again: Discord's Join button may use one again too.
    if (hub.parties.party case final party?) app.discord.codeMadeByUser(party.id);
    return _partyCall(() => hub.parties.newCode());
  }

  Future<void> stopJoinCode() {
    // Stopped here: no code is made for Discord's Join button in its place.
    if (hub.parties.party case final party?) app.discord.codeStoppedByUser(party.id);
    return _partyCall(() => hub.parties.stopCode());
  }

  Future<void> answerRequest(Person person, {required bool accept}) => _partyCall(() async {
    await hub.parties.answerRequest(person.id, accept: accept);
    if (accept) app.show(T.format('gameInvited', [person.displayName]));
  });

  void copy(String text, String said) {
    app.services.copyText?.call(text);
    app.show(said);
  }

  void openDiscord(String link) {
    final url = Uri.tryParse(link);
    if (url != null) app.services.openUrl?.call(url);
  }

  /// The leader's Discord link; empty removes it. The server says which links are Discord's.
  Future<void> setDiscord(String text) async {
    final link = text.trim();
    try {
      await hub.parties.setDiscord(link.isEmpty ? null : link);
      discordDraft = null;
      app.show(link.isEmpty ? T.text('partyDiscordRemoved') : T.text('partyDiscordSaved'));
    } on TogetherProblem catch (problem) {
      app.show(problem.status == 400 ? T.text('partyDiscordWrong') : message(problem));
    } on Object catch (error) {
      app.show(message(error));
    }
  }

  /// What the typed join code opens.
  Future<void> lookUpCode() async {
    final code = JoinCode.clean(joinCodeDraft);
    if (code == null) return app.show(T.text('partyCodeWrong'));
    try {
      codePreview = await hub.parties.preview(code);
      joinCodeDraft = '';
      app.refresh();
    } on TogetherProblem catch (problem) {
      app.show(problem.status == 404 ? T.text('partyCodeWrong') : message(problem));
    } on Object catch (error) {
      app.show(message(error));
    }
  }

  /// Asks the code's party leader to let this account in; their yes is an invite.
  Future<void> askWithCode() async {
    final preview = codePreview;
    if (preview == null) return;
    final host = preview.host?.displayName ?? '?';
    try {
      final state = await hub.parties.askToJoin(preview.code);
      codePreview = preview.withState(state);
      app.show(state == 'invited' ? T.text('partyCodeInvited') : T.format('partyCodeAsked', [host]));
    } on TogetherProblem catch (problem) {
      if (problem.status == 409) {
        codePreview = preview.withState('member');
        return app.show(T.text('partyCodeMember'));
      }
      app.show(problem.status == 404 ? T.text('partyCodeWrong') : message(problem));
    } on Object catch (error) {
      app.show(message(error));
    }
  }

  void closeCodePreview() {
    codePreview = null;
    app.refresh();
  }

  Future<void> leaveParty() => _partyCall(() async {
    await hub.voice.leave();
    await hub.parties.leave();
  });

  Future<void> joinVoice() async {
    // Out of a call with a friend first.
    if (hub.voice.friend != null) await hub.voice.leave();
    await hub.voice.join();
    switch (hub.voice.problem) {
      case VoiceProblem.microphone:
        app.show(T.text('voiceNoMic'));
      case VoiceProblem.failed:
        app.show(T.text('togetherUnreachable'));
      case null:
        if (hub.voice.active) app.show(T.text('voiceJoined'));
    }
  }

  /// Noise suppression on or off, in the call now too (nothing reconnects).
  void setNoiseSuppression(bool on) {
    app.preferences.noiseSuppression = on;
    unawaited(hub.voice.setNoiseSuppression(on));
    app.savePreferences();
  }

  void setPushToTalk(bool on) {
    app.preferences.pushToTalk = on;
    hub.voice.setPushToTalk(on);
    app.savePreferences();
  }

  void captureTalkKey() {
    capturingTalkKey = true;
    app.refresh();
  }

  /// A key pressed while the talk key is being chosen; false when it cannot be one.
  bool chooseTalkKey(int usage) {
    capturingTalkKey = false;
    if (!TalkKeys.supported(usage)) {
      app.refresh();
      return false;
    }
    app.preferences.talkKey = usage & 0xFFFF;
    talkWatch?.usage = talkKey;
    app.savePreferences();
    app.show(T.format('voiceTalkKeySet', [talkKeyName]));
    return true;
  }

  /// The talk key while the launcher has the keyboard, where it cannot be read from the desktop.
  bool talkKeyInWindow(int usage, {required bool down}) {
    if (talkWatch != null || !hub.voice.active || (usage & 0xFFFF) != talkKey) return false;
    hub.voice.talkKey(down);
    return true;
  }
}
