part of 'messages_view.dart';

/// The party's chat beside its rows on the party screen: who reads it (lit while they talk in
/// voice), the thread with the messages screen's bubbles, reactions and quotes, who is typing,
/// and a field. Text only: no pictures, clips or voice notes go in a party's chat.
class PartyChatPane extends StatelessWidget {
  const PartyChatPane({super.key, required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final together = model.together;
    final chat = together.hub.partyChat;
    final party = together.hub.parties.party;
    final keys = together.partyChatKeys;
    final me = together.user?.id;
    final accent = model.accentChoice.color;
    final thread = chat.thread;
    final focused = keys.focused ? together.focusedPartyMessage : null;
    final menu = keys.menu;
    final note = together.partyComposerNote;
    final typing = chat.typingNow;
    final voice = together.hub.voice;
    return AnimatedContainer(
      duration: Motion.focus,
      curve: Motion.settle,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.045),
        borderRadius: BorderRadius.circular(22 * scale),
        // Where the keys are: the chat's edge takes the accent while they are in it.
        border: Border.all(
          color: keys.focused ? accent.withValues(alpha: 0.55) : Colors.white.withValues(alpha: 0.08),
          width: 1.2 * scale,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22 * scale),
        child: Stack(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(20 * scale, 18 * scale, 20 * scale, 18 * scale),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Text(T.text('partyChat'), style: AppText.display(22 * scale, weight: FontWeight.w600)),
                      const Spacer(),
                      // Who reads it: the party, each lit while they talk.
                      if (party != null)
                        _Readers(
                          people: [
                            for (final member in party.members)
                              TogetherModel.card(
                                member,
                                speaking: member.id == me ? voice.speaking : voice.speakingOf(member.id),
                              ),
                          ],
                        ),
                    ],
                  ),
                  SizedBox(height: 12 * scale),
                  Expanded(
                    child: thread.isEmpty
                        ? _ChatEmpty(loading: chat.loading, accent: accent)
                        : ListView(
                            reverse: true,
                            padding: EdgeInsets.symmetric(horizontal: 6 * scale, vertical: 6 * scale),
                            children: [
                              for (final message in thread.reversed)
                                KeepVisible(
                                  active: focused?.id == message.id,
                                  child: _Bubble(
                                    model: model,
                                    message: message,
                                    mine: message.authorId == me,
                                    me: me,
                                    author: together.partyAuthorName(message.authorId),
                                    accent: accent,
                                    focused: focused?.id == message.id && menu == null,
                                    quote: together.partyQuoteOf(message),
                                    maxWidth: 400,
                                    onTap: () {
                                      if (message.failed) {
                                        unawaited(chat.retry(message));
                                      } else {
                                        together.openPartyMessageMenu(message);
                                      }
                                    },
                                    onReaction: (name) => unawaited(together.togglePartyReaction(message, name)),
                                  ),
                                ),
                            ],
                          ),
                  ),
                  SizedBox(
                    height: 24 * scale,
                    child: typing.isEmpty
                        ? null
                        : Align(
                            alignment: AlignmentDirectional.centerStart,
                            child: Text(
                              T.format('messagesTyping', [together.partyAuthorName(typing.first)]),
                              style: AppText.display(13 * scale, color: Colors.white.withValues(alpha: 0.6)),
                            ),
                          ),
                  ),
                  if (note != null)
                    _ComposerNote(
                      title: note.$1,
                      text: note.$2,
                      accent: accent,
                      onCancel: together.cancelPartyComposerNote,
                    ),
                  // Quick replies a controller can send, as in Messages and on the Mac.
                  SizedBox(
                    height: 46 * scale,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        for (var index = 0; index < TogetherMessages.quickReplies.length; index++)
                          Padding(
                            padding: EdgeInsetsDirectional.only(end: 10 * scale),
                            child: Center(
                              child: KeepVisible(
                                active: keys.focused && focused == null && menu == null && keys.place == index,
                                child: _Chip(
                                  label: TogetherMessages.quickReplies[index],
                                  focused:
                                      keys.focused &&
                                      focused == null &&
                                      menu == null &&
                                      model.editingRow == null &&
                                      keys.place == index,
                                  onTap: () =>
                                      unawaited(together.sendPartyMessage(TogetherMessages.quickReplies[index])),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  SizedBox(height: 8 * scale),
                  FocusRing(
                    focused:
                        keys.focused &&
                        focused == null &&
                        menu == null &&
                        model.editingRow == null &&
                        keys.place == TogetherMessages.composer,
                    radius: 12 * scale,
                    child: RowTextField(
                      model: model,
                      row: together.partyDraftField,
                      kind: together.partyDraftField.kind as TextRow,
                      focused: false,
                      // From the party's rows → comes here.
                      trailing: keys.focused || model.editingRow == TogetherPartyChat.draftRow
                          ? null
                          : const _KeyCap(label: '→'),
                    ),
                  ),
                ],
              ),
            ),
            if (menu != null)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: together.closePartyMessageMenu,
                  child: ColoredBox(
                    color: Colors.black.withValues(alpha: 0.4),
                    child: Center(
                      child: GestureDetector(
                        onTap: () {},
                        child: Padding(
                          padding: EdgeInsets.all(16 * scale),
                          child: _PartyMenuCard(model: model, menu: menu),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The party's pictures in a row, overlapping, each ringed while that member talks in voice.
class _Readers extends StatelessWidget {
  const _Readers({required this.people});

  final List<PanelPerson> people;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final size = 26 * scale;
    final step = size * 0.72;
    return SizedBox(
      width: people.isEmpty ? 0 : size + step * (people.length - 1),
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (var index = 0; index < people.length; index++)
            PositionedDirectional(
              start: step * index,
              child: Semantics(
                label: people[index].name,
                child: DecoratedBox(
                  // A dark edge keeps each picture apart from the one under it.
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: const Color(0xFF14161C), width: 2 * scale),
                  ),
                  child: PersonAvatar(person: people[index], size: size - 4 * scale),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// No messages yet: who reads them, and that someone who joins reads them too.
class _ChatEmpty extends StatelessWidget {
  const _ChatEmpty({required this.loading, required this.accent});

  final bool loading;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 340 * scale),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56 * scale,
              height: 56 * scale,
              decoration: BoxDecoration(shape: BoxShape.circle, color: accent.withValues(alpha: 0.16)),
              child: Icon(Icons.forum_rounded, size: 26 * scale, color: accent),
            ),
            SizedBox(height: 16 * scale),
            Text(
              loading ? T.text('profileLoading') : T.text('partyChatEmpty'),
              textAlign: TextAlign.center,
              style: AppText.display(15 * scale, color: Colors.white.withValues(alpha: 0.6), height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}

/// A key drawn as on the hints: the way into the chat from the party's rows.
class _KeyCap extends StatelessWidget {
  const _KeyCap({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 7 * scale, vertical: 2 * scale),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(5 * scale),
      ),
      child: Text(
        label,
        style: AppText.display(12 * scale, weight: FontWeight.w700, color: Colors.white.withValues(alpha: 0.7)),
      ),
    );
  }
}

/// The menu over the party's chat: the reactions and what can be done with a message, asking
/// before it is unsent, and the reasons when it is reported.
class _PartyMenuCard extends StatelessWidget {
  const _PartyMenuCard({required this.model, required this.menu});

  final AppModel model;
  final PartyChatMenu menu;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final together = model.together;
    final items = together.partyMenuItems;
    final me = together.user?.id;
    final (heading, detail) = together.partyMenuHeading;
    final asking = menu.step != null;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: 420 * scale),
      child: Glass(
        floating: true,
        radius: 22 * scale,
        opacity: 0.85,
        padding: EdgeInsets.all(18 * scale),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(6 * scale, 0, 6 * scale, 12 * scale),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    heading,
                    maxLines: asking ? 4 : 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.display(
                      asking ? 16 * scale : 14 * scale,
                      weight: asking ? FontWeight.w600 : FontWeight.w400,
                      color: Colors.white.withValues(alpha: asking ? 0.95 : 0.6),
                      height: 1.3,
                    ),
                  ),
                  if (detail != null) ...[
                    SizedBox(height: 6 * scale),
                    Text(
                      detail,
                      style: AppText.display(13 * scale, color: Colors.white.withValues(alpha: 0.6), height: 1.35),
                    ),
                  ],
                ],
              ),
            ),
            for (var index = 0; index < items.length; index++)
              if (items[index] == 'react')
                _ReactionPicker(
                  message: menu.message,
                  me: me,
                  focused: menu.row == index,
                  chosen: menu.reaction,
                  onPick: (at) {
                    menu
                      ..row = index
                      ..reaction = at;
                    together.runPartyMenuItem('react');
                  },
                )
              else
                _MenuRow(
                  label: together.partyMenuLabel(items[index]),
                  focused: menu.row == index,
                  destructive: items[index] == 'unsend' || items[index] == 'unsend-confirm',
                  onTap: () {
                    menu.row = index;
                    together.runPartyMenuItem(items[index]);
                  },
                ),
          ],
        ),
      ),
    );
  }
}
