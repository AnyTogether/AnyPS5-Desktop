import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';

import '../core/together/e2ee.dart' show DeviceKind, safetyGroups;
import '../core/together/e2ee_client.dart';
import '../core/together/messages.dart';
import '../core/together/people.dart' show Friend;
import 'app_model.dart';
import 'captures_view.dart' show RemotePicture;
import 'clip_player.dart';
import 'components.dart';
import 'glass.dart';
import 'panels.dart';
import 'strings.dart';
import 'theme.dart';
import 'together_model.dart';
import 'voice_note_player.dart';

part 'party_chat_view.dart';

/// Messages: the conversations and friends on the left, the thread on the right with the quick
/// replies a controller can send and a field to type in.
class MessagesView extends StatelessWidget {
  const MessagesView({super.key, required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final together = model.together;
    final targets = together.messageTargets;
    final selected = together.selectedTarget;
    return LayerScrim(
      opacity: 0.62,
      child: Padding(
        padding: EdgeInsets.fromLTRB(80 * scale, 60 * scale, 80 * scale, 50 * scale),
        // The title has the whole top line to itself, so the way back sits level with it, and the
        // list and the conversation start together under it.
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(T.text('messagesTitle'), style: AppText.display(40 * scale, weight: FontWeight.w300)),
            SizedBox(height: 24 * scale),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 440 * scale,
                    child: targets.isEmpty
                        ? Text(
                            together.signedIn ? T.text('messagesNone') : T.text('friendsSignIn'),
                            style: AppText.display(16 * scale, color: Colors.white.withValues(alpha: 0.6)),
                          )
                        : SingleChildScrollView(
                            child: Column(
                              children: [
                                for (var index = 0; index < targets.length; index++)
                                  KeepVisible(
                                    active: index == together.messagesIndex,
                                    child: _TargetRow(
                                      model: model,
                                      target: targets[index],
                                      selected: index == together.messagesIndex,
                                      focused: index == together.messagesIndex && !together.messagesInThread,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                  ),
                  SizedBox(width: 36 * scale),
                  Expanded(
                    child: Glass(
                      radius: 26 * scale,
                      opacity: 0.45,
                      padding: EdgeInsets.all(28 * scale),
                      child: switch (selected) {
                        null => const SizedBox.expand(),
                        NewGroupTarget() => _GroupComposer(model: model),
                        _ => _Thread(model: model, target: selected),
                      },
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TargetRow extends StatelessWidget {
  const _TargetRow({required this.model, required this.target, required this.selected, required this.focused});

  final AppModel model;
  final MessageTarget target;
  final bool selected;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final together = model.together;
    final me = together.user?.id;
    final conversation = target is ConversationTarget ? (target as ConversationTarget).conversation : null;
    final (String name, String detail, int unread, PanelPerson? person) = switch (target) {
      ConversationTarget(:final conversation) => (
        conversation.name(me),
        _preview(conversation, me),
        conversation.unread,
        PanelPerson(
          name: conversation.name(me),
          avatar: conversation.group ? null : conversation.others(me).firstOrNull?.avatar,
          status: conversation.group
              ? null
              : together.hub.friends
                    .byId(conversation.others(me).firstOrNull?.id ?? '')
                    ?.presence
                    .let(TogetherModel.status),
        ),
      ),
      FriendTarget(:final friend) => (
        friend.person.displayName,
        T.text('messagesSayHello'),
        0,
        TogetherModel.card(friend.person, status: TogetherModel.status(friend.presence)),
      ),
      NewGroupTarget() => (T.text('messagesNewGroup'), T.text('messagesNewGroupDetail'), 0, null),
    };
    final color = focused ? Colors.black : Colors.white;
    final muted = conversation?.muted == true;
    return GestureDetector(
      // Clicked: this conversation shown, the cursor in its field to answer.
      onTap: () => unawaited(together.pickMessageTarget(target).catchError((Object _) {})),
      // Right-click: pin it, mute it.
      onSecondaryTap: conversation == null ? null : () => together.openConversationMenu(conversation),
      child: AnimatedContainer(
        duration: Motion.focus,
        curve: Motion.settle,
        margin: EdgeInsets.only(bottom: 6 * scale),
        padding: EdgeInsets.symmetric(horizontal: 16 * scale, vertical: 12 * scale),
        decoration: BoxDecoration(
          color: focused ? Colors.white : Colors.white.withValues(alpha: selected ? 0.12 : 0.05),
          borderRadius: BorderRadius.circular(14 * scale),
        ),
        child: Row(
          children: [
            if (person != null)
              PersonAvatar(person: person, size: 42 * scale, focused: focused)
            else
              Container(
                width: 42 * scale,
                height: 42 * scale,
                decoration: BoxDecoration(shape: BoxShape.circle, color: color.withValues(alpha: 0.1)),
                child: Icon(Icons.group_add_rounded, size: 20 * scale, color: color),
              ),
            SizedBox(width: 14 * scale),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.display(16 * scale, weight: FontWeight.w600, color: color),
                        ),
                      ),
                      if (conversation?.pinned == true)
                        _Mark(icon: Icons.push_pin_rounded, label: T.text('conversationPinned'), color: color),
                      if (muted)
                        _Mark(icon: Icons.notifications_off_rounded, label: T.text('conversationMuted'), color: color),
                    ],
                  ),
                  SizedBox(height: 3 * scale),
                  Text(
                    detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.display(13 * scale, color: color.withValues(alpha: 0.6)),
                  ),
                ],
              ),
            ),
            if (unread > 0)
              Container(
                constraints: BoxConstraints(minWidth: 22 * scale),
                height: 22 * scale,
                padding: EdgeInsets.symmetric(horizontal: 6 * scale),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  // Muted: counted, quietly.
                  color: muted ? color.withValues(alpha: 0.18) : model.accentChoice.color,
                  borderRadius: BorderRadius.circular(11 * scale),
                ),
                child: Text(
                  unread > 99 ? '99+' : '$unread',
                  style: AppText.display(
                    12 * scale,
                    weight: FontWeight.w700,
                    color: muted ? color : LookScope.inkOnAccent(context, model.accentChoice.color, Colors.black),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static String _preview(Conversation conversation, String? me) {
    final last = conversation.lastMessage;
    if (last == null) return T.text('messagesSayHello');
    if (last.deleted) return T.text('messagesDeleted');
    final text = TogetherMessages.previewText(last);
    if (last.authorId == me) return T.format('messagesYou', [text]);
    if (conversation.group) {
      return T.format('messagesFrom', [conversation.author(last.authorId)?.displayName ?? '', text]);
    }
    return text;
  }
}

extension<T> on T {
  R let<R>(R Function(T) transform) => transform(this);
}

class _Thread extends StatelessWidget {
  const _Thread({required this.model, required this.target});

  final AppModel model;
  final MessageTarget target;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final together = model.together;
    final messages = together.hub.messages;
    final me = together.user?.id;
    final listed = target is ConversationTarget ? (target as ConversationTarget).conversation : null;
    // The list's copy can be a moment older than the one the events keep.
    final conversation = messages.byId(listed?.id) ?? listed;
    final title = switch (target) {
      ConversationTarget(:final conversation) => conversation.name(me),
      FriendTarget(:final friend) => friend.person.displayName,
      NewGroupTarget() => T.text('messagesNewGroup'),
    };
    final showing = conversation != null && messages.openId == conversation.id;
    final thread = showing ? messages.thread : const <ChatMessage>[];
    final typing = showing ? messages.typingIn(conversation.id) : const <String>[];
    final inThread = together.messagesInThread;
    final accent = model.accentChoice.color;
    final focused = inThread ? together.focusedMessage : null;
    final receiptOn = showing ? together.receiptFor(conversation) : null;
    final note = showing ? together.composerNote : null;
    final menu = together.messageMenu;
    final lock = showing ? messages.lockOf(conversation.id) : null;
    return DropTarget(
      // As on the Mac: files dropped on the open conversation are sent.
      enable: showing && together.family.mediaAllowed,
      onDragEntered: (_) => together.setChatDropping(true),
      onDragExited: (_) => together.setChatDropping(false),
      onDragDone: (details) {
        together.setChatDropping(false);
        together.dropPictures([for (final file in details.files) file.path]);
      },
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.display(26 * scale, weight: FontWeight.w400),
                    ),
                  ),
                  // △: the conversation's options, or the message's the keys are on.
                  if (conversation != null)
                    Hint(keys: 'O', glyph: PadGlyph.triangle, label: T.text('hintOptions'), action: HintAction.options),
                ],
              ),
              if (lock != null) ...[
                SizedBox(height: 6 * scale),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: _LockLine(lock: lock, accent: accent, onTap: together.openLockSheet),
                ),
              ],
              if (lock?.notice != null) ...[
                SizedBox(height: 12 * scale),
                _DevicesNotice(
                  text: lock!.notice == DevicesChange.mine
                      ? T.text('e2eeMyDevicesChanged')
                      : T.format('e2eeDevicesChanged', [together.partnerName]),
                  accent: accent,
                  onCompare: together.openLockSheet,
                  onDismiss: together.dismissLockNotice,
                ),
              ],
              SizedBox(height: 14 * scale),
              Expanded(
                child: thread.isEmpty
                    ? Center(
                        child: Text(
                          messages.loadingThread ? T.text('profileLoading') : T.text('messagesEmptyThread'),
                          style: AppText.display(16 * scale, color: Colors.white.withValues(alpha: 0.5)),
                        ),
                      )
                    : ListView(
                        reverse: true,
                        // Room for the focus ring of a message at the edge.
                        padding: EdgeInsets.symmetric(horizontal: 6 * scale, vertical: 6 * scale),
                        children: [
                          for (final message in thread.reversed)
                            KeepVisible(
                              // By message: a new one doesn't take over another's playing note.
                              key: ValueKey(message.id),
                              active: focused?.id == message.id,
                              child: _Bubble(
                                model: model,
                                message: message,
                                mine: message.authorId == me,
                                me: me,
                                author: conversation?.group == true
                                    ? together.authorName(conversation, message.authorId)
                                    : null,
                                accent: accent,
                                focused: focused?.id == message.id && menu == null,
                                quote: together.quoteOf(message),
                                receipt: receiptOn?.id == message.id && conversation != null
                                    ? together.receiptText(conversation, message)
                                    : null,
                                onTap: () {
                                  if (message.failed) {
                                    unawaited(messages.retry(message));
                                  } else {
                                    together.openMessageMenu(message);
                                  }
                                },
                                onReaction: (name) => unawaited(together.toggleReaction(message, name)),
                              ),
                            ),
                        ],
                      ),
              ),
              SizedBox(
                height: 26 * scale,
                child: typing.isEmpty
                    ? null
                    : Text(
                        together.typingText(conversation!, typing) ?? '',
                        style: AppText.display(13 * scale, color: Colors.white.withValues(alpha: 0.6)),
                      ),
              ),
              if (note != null)
                _ComposerNote(title: note.$1, text: note.$2, accent: accent, onCancel: together.cancelComposerNote),
              if (lock?.state == EncryptionState.noDevice)
                _NoDeviceNote(text: T.format('e2eeNoDevice', [together.partnerName]))
              else
                Row(
                  children: [
                    for (var index = 0; index < TogetherMessages.quickReplies.length; index++) ...[
                      _Chip(
                        label: TogetherMessages.quickReplies[index],
                        focused: inThread && focused == null && together.messageFocus == index,
                        onTap: () => together.sendMessage(TogetherMessages.quickReplies[index]),
                      ),
                      SizedBox(width: 10 * scale),
                    ],
                    Expanded(
                      child: FocusRing(
                        focused:
                            inThread &&
                            focused == null &&
                            together.messageFocus == TogetherMessages.composer &&
                            model.editingRow == null,
                        radius: 12 * scale,
                        child: RowTextField(
                          model: model,
                          row: together.draftField,
                          kind: together.draftField.kind as TextRow,
                          focused: false,
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
          if (together.lockSheet && lock != null)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: together.closeLockSheet,
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: 0.35),
                  child: Center(
                    child: GestureDetector(
                      onTap: () {},
                      child: _LockSheet(model: model, lock: lock),
                    ),
                  ),
                ),
              ),
            ),
          if (together.chatViewing case final viewing?)
            Positioned.fill(
              child: _ChatViewer(model: model, media: viewing),
            ),
          if (menu != null)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: together.closeMessageMenu,
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: 0.35),
                  child: Center(
                    child: GestureDetector(
                      onTap: () {},
                      child: _MenuCard(model: model, menu: menu),
                    ),
                  ),
                ),
              ),
            ),
          if (together.chatDropping)
            Positioned.fill(
              child: IgnorePointer(child: _DropOverlay(accent: accent)),
            ),
        ],
      ),
    );
  }
}

/// A new group: its name, the friends to pick (a tick on each one picked) and Start the group.
class _GroupComposer extends StatelessWidget {
  const _GroupComposer({required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final together = model.together;
    final friends = together.groupFriends;
    final inside = together.messagesInThread;
    final accent = model.accentChoice.color;
    final ready = together.groupPicked.isNotEmpty;
    final startFocused = inside && together.groupFocus == friends.length + 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(
              width: 52 * scale,
              height: 52 * scale,
              decoration: BoxDecoration(shape: BoxShape.circle, color: accent.withValues(alpha: 0.85)),
              child: Icon(
                Icons.groups_rounded,
                size: 26 * scale,
                color: LookScope.inkOnAccent(context, accent, Colors.white),
              ),
            ),
            SizedBox(width: 16 * scale),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(T.text('messagesNewGroup'), style: AppText.display(24 * scale, weight: FontWeight.w600)),
                  SizedBox(height: 2 * scale),
                  Text(
                    T.format('messagesGroupPicked', [together.groupPicked.length]),
                    style: AppText.display(14 * scale, color: Colors.white.withValues(alpha: 0.55)),
                  ),
                ],
              ),
            ),
          ],
        ),
        SizedBox(height: 18 * scale),
        FocusRing(
          focused: inside && together.groupFocus == 0 && model.editingRow == null,
          radius: 12 * scale,
          child: RowTextField(
            model: model,
            row: together.groupNameField,
            kind: together.groupNameField.kind as TextRow,
            focused: false,
          ),
        ),
        SizedBox(height: 14 * scale),
        Expanded(
          child: SingleChildScrollView(
            padding: EdgeInsets.all(4 * scale),
            child: Column(
              children: [
                for (var index = 0; index < friends.length; index++)
                  KeepVisible(
                    active: inside && together.groupFocus == index + 1,
                    child: _GroupFriendRow(
                      model: model,
                      friend: friends[index],
                      picked: together.groupPicked.contains(friends[index].person.id),
                      focused: inside && together.groupFocus == index + 1,
                      onTap: () {
                        together.groupFocus = index + 1;
                        together.toggleGroupFriend(friends[index].person.id);
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
        SizedBox(height: 14 * scale),
        Semantics(
          button: true,
          label: T.text('messagesGroupCreate'),
          child: Pressable(
            onTap: () => unawaited(together.startGroup()),
            builder: (context, hovering) => AnimatedContainer(
              duration: Motion.focus,
              curve: Motion.settle,
              padding: EdgeInsets.symmetric(vertical: 13 * scale),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: startFocused
                    ? Colors.white
                    : ready
                    ? accent.withValues(alpha: hovering ? 0.95 : 0.8)
                    : Colors.white.withValues(alpha: hovering ? 0.1 : 0.06),
                borderRadius: BorderRadius.circular(24 * scale),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.forum_rounded,
                    size: 17 * scale,
                    color: startFocused
                        ? Colors.black
                        : ready
                        ? LookScope.inkOnAccent(context, accent, Colors.white)
                        : Colors.white.withValues(alpha: 0.45),
                  ),
                  SizedBox(width: 10 * scale),
                  Text(
                    T.text('messagesGroupCreate'),
                    style: AppText.display(
                      16 * scale,
                      weight: FontWeight.w600,
                      color: startFocused
                          ? Colors.black
                          : ready
                          ? LookScope.inkOnAccent(context, accent, Colors.white)
                          : Colors.white.withValues(alpha: 0.45),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _GroupFriendRow extends StatelessWidget {
  const _GroupFriendRow({
    required this.model,
    required this.friend,
    required this.picked,
    required this.focused,
    required this.onTap,
  });

  final AppModel model;
  final Friend friend;
  final bool picked;
  final bool focused;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final color = focused ? Colors.black : Colors.white;
    final accent = model.accentChoice.color;
    return Semantics(
      checked: picked,
      label: friend.person.displayName,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: Motion.focus,
          curve: Motion.settle,
          margin: EdgeInsets.only(bottom: 6 * scale),
          padding: EdgeInsets.symmetric(horizontal: 14 * scale, vertical: 9 * scale),
          decoration: BoxDecoration(
            color: focused ? Colors.white : Colors.white.withValues(alpha: picked ? 0.1 : 0.04),
            borderRadius: BorderRadius.circular(14 * scale),
          ),
          child: Row(
            children: [
              PersonAvatar(person: TogetherModel.card(friend.person), size: 38 * scale, focused: focused),
              SizedBox(width: 14 * scale),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      TogetherModel.shown(friend.person).name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.display(15 * scale, weight: FontWeight.w600, color: color),
                    ),
                    Text(
                      '@${friend.person.handle}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.display(12 * scale, color: color.withValues(alpha: 0.55)),
                    ),
                  ],
                ),
              ),
              AnimatedSwitcher(
                duration: Motion.focus,
                child: Icon(
                  picked ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                  key: ValueKey(picked),
                  size: 22 * scale,
                  color: picked ? (focused ? Colors.black : accent) : color.withValues(alpha: focused ? 0.4 : 0.35),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A small mark beside a conversation's name: pinned, muted.
class _Mark extends StatelessWidget {
  const _Mark({required this.icon, required this.label, required this.color});

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return Padding(
      padding: EdgeInsetsDirectional.only(start: 6 * scale),
      child: Semantics(
        label: label,
        child: Icon(icon, size: 14 * scale, color: color.withValues(alpha: 0.55)),
      ),
    );
  }
}

/// Above the composer while it answers a message or edits one: what, and a way out.
class _ComposerNote extends StatelessWidget {
  const _ComposerNote({required this.title, required this.text, required this.accent, required this.onCancel});

  final String title;
  final String text;
  final Color accent;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return Container(
      margin: EdgeInsets.only(bottom: 10 * scale),
      padding: EdgeInsetsDirectional.fromSTEB(14 * scale, 8 * scale, 8 * scale, 8 * scale),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12 * scale),
        border: Border(
          left: BorderSide(color: accent, width: 3 * scale),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: AppText.display(12 * scale, weight: FontWeight.w700, color: accent),
                ),
                SizedBox(height: 2 * scale),
                Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.display(13 * scale, color: Colors.white.withValues(alpha: 0.7)),
                ),
              ],
            ),
          ),
          Semantics(
            button: true,
            label: T.text('cancel'),
            child: Pressable(
              onTap: onCancel,
              builder: (context, hovering) => Padding(
                padding: EdgeInsets.all(6 * scale),
                child: Icon(
                  Icons.close_rounded,
                  size: 18 * scale,
                  color: Colors.white.withValues(alpha: hovering ? 0.9 : 0.5),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The menu over the thread: a message's reactions and what can be done with it, asking before
/// it is unsent; or a conversation's pin and mute.
class _MenuCard extends StatelessWidget {
  const _MenuCard({required this.model, required this.menu});

  final AppModel model;
  final MessageMenu menu;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final together = model.together;
    final items = together.messageMenuItems;
    final message = menu.message;
    final conversation = together.hub.messages.byId(menu.conversationId);
    final me = together.user?.id;
    final heading = menu.confirming
        ? T.text('messagesUnsendConfirm')
        : menu.reporting
        ? [T.text('messagesReportWhy'), if (message?.encrypted == true) T.text('e2eeReportNote')].join('\n')
        : message != null
        ? (message.encrypted && message.seal != SealState.opened
              ? TogetherMessages.shownText(message)
              : (message.words ?? TogetherMessages.previewText(message)))
        : conversation?.name(me) ?? '';
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
              child: Text(
                heading,
                maxLines: menu.confirming || menu.reporting ? 4 : 2,
                overflow: TextOverflow.ellipsis,
                style: AppText.display(
                  menu.confirming ? 16 * scale : 14 * scale,
                  weight: menu.confirming || menu.reporting ? FontWeight.w600 : FontWeight.w400,
                  color: Colors.white.withValues(alpha: menu.confirming || menu.reporting ? 0.95 : 0.6),
                  height: 1.3,
                ),
              ),
            ),
            for (var index = 0; index < items.length; index++)
              if (items[index] == 'react')
                _ReactionPicker(
                  message: message!,
                  me: me,
                  focused: menu.row == index,
                  chosen: menu.reaction,
                  onPick: (at) {
                    menu
                      ..row = index
                      ..reaction = at;
                    together.runMenuItem('react');
                  },
                )
              else
                _MenuRow(
                  label: together.menuLabel(items[index]),
                  focused: menu.row == index,
                  destructive: items[index] == 'unsend' || items[index] == 'unsend-confirm',
                  onTap: () {
                    menu.row = index;
                    together.runMenuItem(items[index]);
                  },
                ),
          ],
        ),
      ),
    );
  }
}

class _ReactionPicker extends StatelessWidget {
  const _ReactionPicker({
    required this.message,
    required this.me,
    required this.focused,
    required this.chosen,
    required this.onPick,
  });

  final ChatMessage message;
  final String? me;
  final bool focused;
  final int chosen;
  final void Function(int index) onPick;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final name = messageReactions[chosen];
    return Padding(
      padding: EdgeInsets.only(bottom: 10 * scale),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (var index = 0; index < messageReactions.length; index++)
                Semantics(
                  button: true,
                  label: TogetherMessages.reactionLabel(messageReactions[index]),
                  child: Pressable(
                    onTap: () => onPick(index),
                    builder: (context, hovering) {
                      final on = focused && index == chosen;
                      final mine = message.reacted(messageReactions[index], me);
                      return AnimatedContainer(
                        duration: Motion.focus,
                        curve: Motion.settle,
                        width: 46 * scale,
                        height: 46 * scale,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: on
                              ? Colors.white
                              : Colors.white.withValues(alpha: mine ? 0.22 : (hovering ? 0.14 : 0.06)),
                        ),
                        child: Text(
                          reactionGlyphs[messageReactions[index]]!,
                          style: AppText.display(
                            messageReactions[index] == 'gg' ? 15 * scale : 21 * scale,
                            weight: FontWeight.w800,
                            color: on ? Colors.black : Colors.white,
                          ),
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
          SizedBox(height: 6 * scale),
          Text(
            focused ? TogetherMessages.reactionLabel(name) : T.text('messagesReact'),
            textAlign: TextAlign.center,
            style: AppText.display(12 * scale, color: Colors.white.withValues(alpha: 0.55)),
          ),
        ],
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.label, required this.focused, required this.destructive, required this.onTap});

  final String label;
  final bool focused;
  final bool destructive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final ink = destructive ? Palette.danger : Colors.white;
    return Pressable(
      onTap: onTap,
      builder: (context, hovering) => AnimatedContainer(
        duration: Motion.focus,
        curve: Motion.settle,
        margin: EdgeInsets.only(top: 4 * scale),
        padding: EdgeInsets.symmetric(horizontal: 16 * scale, vertical: 12 * scale),
        decoration: BoxDecoration(
          color: focused ? Colors.white : Colors.white.withValues(alpha: hovering ? 0.1 : 0),
          borderRadius: BorderRadius.circular(12 * scale),
        ),
        child: Text(
          label,
          style: AppText.display(
            15 * scale,
            weight: FontWeight.w600,
            color: focused ? (destructive ? const Color(0xFFB3261E) : Colors.black) : ink,
          ),
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.model,
    required this.message,
    required this.mine,
    required this.me,
    required this.accent,
    required this.focused,
    required this.onTap,
    required this.onReaction,
    this.author,
    this.quote,
    this.receipt,
    this.maxWidth = 560,
  });

  final AppModel model;
  final ChatMessage message;
  final bool mine;
  final String? me;
  final Color accent;
  final String? author;
  final bool focused;

  /// Who wrote the message it answers, and what.
  final (String, String)? quote;

  /// Under the user's newest message: Sent, Delivered, Read, Seen by.
  final String? receipt;

  /// How wide a bubble grows at most (the party's narrower chat keeps them narrower).
  final double maxWidth;
  final VoidCallback onTap;
  final void Function(String name) onReaction;

  @override
  Widget build(BuildContext context) {
    // Words on the accent: dark ink on a light one (Glass, or the Ice accent).
    final mineInk = LookScope.inkOnAccent(context, accent, Colors.black);
    final scale = LayoutScale.of(context);
    final ink = mine ? mineInk : Colors.white;
    final text = TogetherMessages.shownText(message);
    // Removed, or a sealed one this device cannot read: said quietly, in italics.
    final unread = message.deleted || message.seal == SealState.beforeDevice || message.seal == SealState.undecryptable;
    final attachment = message.deleted || message.seal != SealState.opened ? null : message.attachment;
    final foot = [
      if (message.failed) T.text('messagesRetry'),
      if (message.edited && !message.deleted) T.text('messagesEdited'),
    ];
    final radius = BorderRadius.only(
      topLeft: Radius.circular(18 * scale),
      topRight: Radius.circular(18 * scale),
      bottomLeft: Radius.circular((mine ? 18 : 5) * scale),
      bottomRight: Radius.circular((mine ? 5 : 18) * scale),
    );
    return Padding(
      padding: EdgeInsets.only(bottom: 8 * scale),
      child: Column(
        crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth * scale),
            child: FocusRing(
              focused: focused,
              radius: 18 * scale,
              child: GestureDetector(
                onTap: onTap,
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: 16 * scale, vertical: 10 * scale),
                  decoration: BoxDecoration(
                    color: message.deleted
                        ? Colors.white.withValues(alpha: 0.04)
                        : mine
                        ? accent.withValues(alpha: message.pending ? 0.45 : 0.85)
                        : Colors.white.withValues(alpha: 0.1),
                    borderRadius: radius,
                    border: message.failed
                        ? Border.all(color: Palette.danger, width: 1.5 * scale)
                        : message.deleted
                        ? Border.all(color: Colors.white.withValues(alpha: 0.14), width: 1 * scale)
                        : null,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (author != null && !mine)
                        Padding(
                          padding: EdgeInsets.only(bottom: 3 * scale),
                          child: Text(
                            author!,
                            style: AppText.display(12 * scale, weight: FontWeight.w700, color: accent),
                          ),
                        ),
                      if (quote != null && !message.deleted)
                        Container(
                          margin: EdgeInsets.only(bottom: 6 * scale),
                          padding: EdgeInsetsDirectional.fromSTEB(10 * scale, 4 * scale, 8 * scale, 4 * scale),
                          decoration: BoxDecoration(
                            border: Border(
                              left: BorderSide(color: ink.withValues(alpha: 0.45), width: 2.5 * scale),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (quote!.$1.isNotEmpty)
                                Text(
                                  quote!.$1,
                                  style: AppText.display(
                                    12 * scale,
                                    weight: FontWeight.w700,
                                    color: ink.withValues(alpha: 0.75),
                                  ),
                                ),
                              Text(
                                quote!.$2,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: AppText.display(13 * scale, color: ink.withValues(alpha: 0.65), height: 1.25),
                              ),
                            ],
                          ),
                        ),
                      if (attachment != null)
                        Padding(
                          padding: EdgeInsets.only(bottom: text.isEmpty ? 0 : 8 * scale, top: 4 * scale),
                          child: _SealedAttachmentView(model: model, message: message, ink: ink),
                        )
                      else if (message.media case final media? when !media.sealed)
                        Padding(
                          padding: EdgeInsets.only(bottom: text.isEmpty ? 0 : 8 * scale, top: 4 * scale),
                          child: _PlainMediaView(model: model, media: media, ink: ink),
                        ),
                      if (text.isNotEmpty || (attachment == null && (message.media == null || message.media!.sealed)))
                        Text(
                          text,
                          style: AppText.display(
                            16 * scale,
                            color: unread
                                ? (mine ? mineInk.withValues(alpha: 0.7) : Colors.white.withValues(alpha: 0.5))
                                : mine
                                ? mineInk
                                : Colors.white.withValues(alpha: 0.95),
                            height: 1.3,
                          ).copyWith(fontStyle: unread ? FontStyle.italic : null),
                        ),
                      if (foot.isNotEmpty)
                        Padding(
                          padding: EdgeInsets.only(top: 4 * scale),
                          child: Text(
                            foot.join(' · '),
                            style: AppText.display(11 * scale, color: ink.withValues(alpha: 0.6)),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (message.reactions.isNotEmpty && !message.deleted)
            Padding(
              padding: EdgeInsets.only(top: 4 * scale),
              child: Wrap(
                spacing: 6 * scale,
                runSpacing: 4 * scale,
                children: [
                  for (final reaction in message.reactions)
                    _ReactionChip(
                      reaction: reaction,
                      mine: reaction.userIds.contains(me),
                      accent: accent,
                      onTap: () => onReaction(reaction.name),
                    ),
                ],
              ),
            ),
          if (receipt != null)
            Padding(
              padding: EdgeInsetsDirectional.only(top: 3 * scale, end: 4 * scale),
              child: Text(
                receipt!,
                style: AppText.display(11 * scale, weight: FontWeight.w500, color: Colors.white.withValues(alpha: 0.5)),
              ),
            ),
        ],
      ),
    );
  }
}

/// A reaction under a bubble: its glyph and how many (when more than one), lit when it is the
/// user's; clicked, added or taken back.
class _ReactionChip extends StatelessWidget {
  const _ReactionChip({required this.reaction, required this.mine, required this.accent, required this.onTap});

  final ReactionCount reaction;
  final bool mine;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return Semantics(
      button: true,
      label: TogetherMessages.reactionLabel(reaction.name),
      child: Pressable(
        onTap: onTap,
        builder: (context, hovering) => AnimatedContainer(
          duration: Motion.focus,
          curve: Motion.settle,
          padding: EdgeInsets.symmetric(horizontal: 8 * scale, vertical: 3 * scale),
          decoration: BoxDecoration(
            color: mine ? accent.withValues(alpha: 0.28) : Colors.white.withValues(alpha: hovering ? 0.16 : 0.09),
            borderRadius: BorderRadius.circular(12 * scale),
            border: Border.all(
              color: mine ? accent.withValues(alpha: 0.9) : Colors.white.withValues(alpha: 0.12),
              width: 1 * scale,
            ),
          ),
          child: Text(
            reaction.count > 1 ? '${reactionGlyphs[reaction.name]} ${reaction.count}' : reactionGlyphs[reaction.name]!,
            style: AppText.display(12 * scale, weight: FontWeight.w700, color: Colors.white),
          ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.focused, required this.onTap});

  final String label;
  final bool focused;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: Motion.focus,
        curve: Motion.settle,
        padding: EdgeInsets.symmetric(horizontal: 16 * scale, vertical: 11 * scale),
        decoration: BoxDecoration(
          color: focused ? Colors.white : Colors.white.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(22 * scale),
          boxShadow: [
            BoxShadow(
              color: Colors.white.withValues(alpha: focused ? 0.3 : 0),
              blurRadius: 12 * scale,
            ),
          ],
        ),
        child: Text(
          label,
          style: AppText.display(15 * scale, weight: FontWeight.w600, color: focused ? Colors.black : Colors.white),
        ),
      ),
    );
  }
}

/// Under the conversation's name: end-to-end encrypted (a lock in the accent) or not (an open
/// lock, quietly); clicked, the sheet with what it means.
class _LockLine extends StatelessWidget {
  const _LockLine({required this.lock, required this.accent, required this.onTap});

  final ConversationLock lock;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final on = lock.state != EncryptionState.off;
    final ink = on ? accent : Colors.white.withValues(alpha: 0.55);
    final label = T.text(on ? 'e2eeOn' : 'e2eeOff');
    return Semantics(
      button: true,
      label: label,
      child: Pressable(
        onTap: onTap,
        builder: (context, hovering) => AnimatedContainer(
          duration: Motion.focus,
          curve: Motion.settle,
          padding: EdgeInsetsDirectional.fromSTEB(9 * scale, 4 * scale, 11 * scale, 4 * scale),
          decoration: BoxDecoration(
            color: (on ? accent : Colors.white).withValues(alpha: hovering ? 0.18 : 0.08),
            borderRadius: BorderRadius.circular(12 * scale),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(on ? Icons.lock_rounded : Icons.lock_open_rounded, size: 14 * scale, color: ink),
              SizedBox(width: 6 * scale),
              Text(
                label,
                style: AppText.display(12.5 * scale, weight: FontWeight.w600, color: ink),
              ),
              if (lock.compared) ...[
                SizedBox(width: 6 * scale),
                Icon(Icons.verified_rounded, size: 14 * scale, color: ink),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Someone's devices changed: said in the thread until it is dismissed, with the way to the
/// safety number.
class _DevicesNotice extends StatelessWidget {
  const _DevicesNotice({required this.text, required this.accent, required this.onCompare, required this.onDismiss});

  final String text;
  final Color accent;
  final VoidCallback onCompare;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return Container(
      padding: EdgeInsetsDirectional.fromSTEB(14 * scale, 10 * scale, 10 * scale, 10 * scale),
      decoration: BoxDecoration(
        color: Palette.warning.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(14 * scale),
        border: Border.all(color: Palette.warning.withValues(alpha: 0.35), width: 1 * scale),
      ),
      child: Row(
        children: [
          Icon(Icons.devices_other_rounded, size: 18 * scale, color: Palette.warning),
          SizedBox(width: 10 * scale),
          Expanded(
            child: Text(
              text,
              style: AppText.display(13.5 * scale, color: Colors.white.withValues(alpha: 0.9), height: 1.3),
            ),
          ),
          SizedBox(width: 10 * scale),
          _PillButton(label: T.text('e2eeCompare'), strong: true, onTap: onCompare),
          SizedBox(width: 6 * scale),
          _PillButton(label: T.text('e2eeDismiss'), onTap: onDismiss),
        ],
      ),
    );
  }
}

/// A small pill for the notice: white when [strong] (or focused), glass otherwise.
class _PillButton extends StatelessWidget {
  const _PillButton({required this.label, required this.onTap, this.strong = false, this.focused = false});

  final String label;
  final VoidCallback onTap;
  final bool strong;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return Semantics(
      button: true,
      label: label,
      child: Pressable(
        onTap: onTap,
        builder: (context, hovering) {
          final lit = strong || focused;
          return AnimatedContainer(
            duration: Motion.focus,
            curve: Motion.settle,
            padding: EdgeInsets.symmetric(horizontal: 14 * scale, vertical: 7 * scale),
            decoration: BoxDecoration(
              color: lit
                  ? Colors.white.withValues(alpha: hovering ? 0.9 : 1)
                  : Colors.white.withValues(alpha: hovering ? 0.16 : 0.08),
              borderRadius: BorderRadius.circular(16 * scale),
              boxShadow: [
                BoxShadow(
                  color: Colors.white.withValues(alpha: focused ? 0.3 : 0),
                  blurRadius: 12 * scale,
                ),
              ],
            ),
            child: Text(
              label,
              style: AppText.display(13 * scale, weight: FontWeight.w600, color: lit ? Colors.black : Colors.white),
            ),
          );
        },
      ),
    );
  }
}

/// In place of the composer when the conversation is encrypted and nobody on the other side
/// can read it now.
class _NoDeviceNote extends StatelessWidget {
  const _NoDeviceNote({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 16 * scale, vertical: 13 * scale),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12 * scale),
      ),
      child: Row(
        children: [
          Icon(Icons.lock_clock_rounded, size: 18 * scale, color: Colors.white.withValues(alpha: 0.6)),
          SizedBox(width: 10 * scale),
          Expanded(
            child: Text(
              text,
              style: AppText.display(14 * scale, color: Colors.white.withValues(alpha: 0.75), height: 1.3),
            ),
          ),
        ],
      ),
    );
  }
}

/// What the lock means: end-to-end encrypted, the safety number in twelve groups of five to
/// compare with the other person, "We compared them", and both people's devices.
class _LockSheet extends StatelessWidget {
  const _LockSheet({required this.model, required this.lock});

  final AppModel model;
  final ConversationLock lock;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final together = model.together;
    final name = together.partnerName;
    final accent = model.accentChoice.color;
    final rows = together.lockSheetRows;
    final row = together.lockSheetRow.clamp(0, rows.length - 1);
    final on = lock.state != EncryptionState.off;
    final number = lock.safetyNumber;
    final detail = switch (lock.state) {
      EncryptionState.on => T.format('e2eeOnDetail', [name]),
      EncryptionState.off => T.format('e2eeOffDetail', [name]),
      EncryptionState.noDevice => T.format('e2eeNoDevice', [name]),
    };
    final faint = Colors.white.withValues(alpha: 0.6);
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: 560 * scale),
      child: Glass(
        floating: true,
        radius: 24 * scale,
        opacity: 0.86,
        padding: EdgeInsets.fromLTRB(26 * scale, 24 * scale, 26 * scale, 20 * scale),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 34 * scale,
                  height: 34 * scale,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: (on ? accent : Colors.white).withValues(alpha: 0.16),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    on ? Icons.lock_rounded : Icons.lock_open_rounded,
                    size: 18 * scale,
                    color: on ? accent : faint,
                  ),
                ),
                SizedBox(width: 12 * scale),
                Expanded(
                  child: Text(
                    T.text(on ? 'e2eeOn' : 'e2eeOff'),
                    style: AppText.display(22 * scale, weight: FontWeight.w600, height: 1.1),
                  ),
                ),
              ],
            ),
            SizedBox(height: 10 * scale),
            Text(detail, style: AppText.display(14 * scale, color: Colors.white.withValues(alpha: 0.78), height: 1.35)),
            if (number != null) ...[
              SizedBox(height: 18 * scale),
              Row(
                children: [
                  Text(
                    T.text('e2eeSafetyNumber'),
                    style: AppText.display(12.5 * scale, weight: FontWeight.w700, color: faint),
                  ),
                  const Spacer(),
                  if (lock.compared)
                    Row(
                      children: [
                        Icon(Icons.verified_rounded, size: 14 * scale, color: Palette.success),
                        SizedBox(width: 4 * scale),
                        Text(
                          T.text('e2eeCompared'),
                          style: AppText.display(12 * scale, weight: FontWeight.w600, color: Palette.success),
                        ),
                      ],
                    ),
                ],
              ),
              SizedBox(height: 8 * scale),
              _SafetyGrid(digits: number, accent: accent, compared: lock.compared),
              SizedBox(height: 10 * scale),
              Text(T.format('e2eeSafetyHow', [name]), style: AppText.display(13 * scale, color: faint, height: 1.35)),
            ],
            if (lock.notice != null) ...[
              SizedBox(height: 12 * scale),
              Text(
                lock.notice == DevicesChange.mine
                    ? T.text('e2eeMyDevicesChanged')
                    : T.format('e2eeDevicesChanged', [name]),
                style: AppText.display(13 * scale, weight: FontWeight.w600, color: Palette.warning, height: 1.35),
              ),
            ],
            if (on) ...[
              SizedBox(height: 18 * scale),
              Text(
                T.text('e2eeDevices'),
                style: AppText.display(12.5 * scale, weight: FontWeight.w700, color: faint),
              ),
              SizedBox(height: 8 * scale),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _DeviceList(title: T.text('e2eeYou'), devices: lock.mine),
                  ),
                  SizedBox(width: 16 * scale),
                  Expanded(
                    child: _DeviceList(title: name, devices: lock.theirs),
                  ),
                ],
              ),
              SizedBox(height: 10 * scale),
              Text(
                T.text('e2eeNewDeviceNote'),
                style: AppText.display(12 * scale, color: Colors.white.withValues(alpha: 0.5), height: 1.35),
              ),
            ],
            SizedBox(height: 18 * scale),
            Wrap(
              spacing: 8 * scale,
              runSpacing: 8 * scale,
              children: [
                for (var index = 0; index < rows.length; index++)
                  _PillButton(
                    label: switch (rows[index]) {
                      'compared' => T.text('e2eeMarkCompared'),
                      'dismiss' => T.text('e2eeDismiss'),
                      _ => T.text('back'),
                    },
                    focused: index == row,
                    onTap: () {
                      together.lockSheetRow = index;
                      together.runLockSheetRow(rows[index]);
                    },
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The 60 digits as twelve groups of five, four to a line, in figures of one width so the two
/// people can read them out to each other group by group.
class _SafetyGrid extends StatelessWidget {
  const _SafetyGrid({required this.digits, required this.accent, required this.compared});

  final String digits;
  final Color accent;
  final bool compared;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final groups = safetyGroups(digits);
    final style = AppText.display(
      19 * scale,
      weight: FontWeight.w500,
      color: Colors.white.withValues(alpha: 0.95),
    ).copyWith(fontFeatures: const [FontFeature.tabularFigures()], letterSpacing: 1.6 * scale);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 16 * scale, vertical: 12 * scale),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(14 * scale),
        border: Border.all(color: (compared ? Palette.success : accent).withValues(alpha: 0.35), width: 1 * scale),
      ),
      child: Column(
        children: [
          for (var line = 0; line < 3; line++)
            Padding(
              padding: EdgeInsets.symmetric(vertical: 3 * scale),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  for (var at = line * 4; at < line * 4 + 4 && at < groups.length; at++) Text(groups[at], style: style),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _DeviceList extends StatelessWidget {
  const _DeviceList({required this.title, required this.devices});

  final String title;
  final UserDevices devices;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppText.display(13 * scale, weight: FontWeight.w700),
        ),
        SizedBox(height: 4 * scale),
        // Each device as its kind and the day it was added: never the name its app registered
        // (often the computer's own) or its ID.
        for (final device in devices.active)
          Padding(
            padding: EdgeInsets.only(top: 4 * scale),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: EdgeInsets.only(top: 1 * scale),
                  child: Icon(
                    deviceKindIcon(device.kind),
                    size: 14 * scale,
                    color: Colors.white.withValues(alpha: 0.5),
                  ),
                ),
                SizedBox(width: 7 * scale),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        deviceKindText(device.kind),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.display(12.5 * scale, color: Colors.white.withValues(alpha: 0.8)),
                      ),
                      if (device.createdAt case final added?)
                        Text(
                          T.format('e2eeDeviceAdded', [_day(added)]),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.display(11 * scale, color: Colors.white.withValues(alpha: 0.45)),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  static String _day(DateTime date) {
    final local = date.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)}';
  }
}

/// What a device is, in words: "Windows PC", "iPhone", "Device".
String deviceKindText(DeviceKind kind) => T.text(switch (kind) {
  DeviceKind.windows => 'e2eeDeviceWindows',
  DeviceKind.mac => 'e2eeDeviceMac',
  DeviceKind.linux => 'e2eeDeviceLinux',
  DeviceKind.iphone => 'e2eeDeviceIphone',
  DeviceKind.ipad => 'e2eeDeviceIpad',
  DeviceKind.android => 'e2eeDeviceAndroid',
  DeviceKind.browser => 'e2eeDeviceBrowser',
  DeviceKind.device => 'e2eeDeviceOther',
});

IconData deviceKindIcon(DeviceKind kind) => switch (kind) {
  DeviceKind.windows => Icons.desktop_windows_rounded,
  DeviceKind.mac => Icons.laptop_mac_rounded,
  DeviceKind.linux => Icons.computer_rounded,
  DeviceKind.iphone || DeviceKind.android => Icons.smartphone_rounded,
  DeviceKind.ipad => Icons.tablet_mac_rounded,
  DeviceKind.browser => Icons.language_rounded,
  DeviceKind.device => Icons.devices_rounded,
};

/// A photo or clip sent as it is (from the gallery's Share, here or on the Mac): its picture or
/// the clip's poster with a play mark; clicked, shown over the whole screen (a clip plays). A
/// voice note plays in its bubble.
class _PlainMediaView extends StatelessWidget {
  const _PlainMediaView({required this.model, required this.media, required this.ink});

  final AppModel model;
  final MediaLink media;
  final Color ink;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final link = media.url;
    if (media.gone || link == null) {
      return Text(
        T.text('messagesDeleted'),
        style: AppText.display(14 * scale, weight: FontWeight.w600, color: ink),
      );
    }
    if (media.kind == 'voice') {
      return _VoiceNoteView(
        model: model,
        id: media.id,
        durationMs: media.durationMs,
        ink: ink,
        onTap: () => model.together.viewChatMedia(media),
      );
    }
    final still = media.kind == 'image' ? link : media.poster;
    return Pressable(
      onTap: () => model.together.viewChatMedia(media),
      builder: (context, hovering) => ClipRRect(
        borderRadius: BorderRadius.circular(12 * scale),
        child: SizedBox(
          width: 320 * scale,
          child: AspectRatio(
            aspectRatio: media.aspect,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(color: Colors.black.withValues(alpha: 0.3)),
                if (still != null)
                  FutureBuilder<Uint8List>(
                    future: model.together.picture(still),
                    builder: (context, snapshot) => snapshot.hasData
                        ? Image.memory(snapshot.data!, fit: BoxFit.cover, gaplessPlayback: true)
                        : const SizedBox.shrink(),
                  ),
                if (media.kind == 'clip')
                  Center(
                    child: Icon(
                      Icons.play_circle_fill_rounded,
                      size: 40 * scale,
                      color: Colors.white.withValues(alpha: hovering ? 1 : 0.85),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A sealed attachment in a bubble: a photo opened in memory, a clip's poster with a play mark,
/// a voice note to play; clicked, a photo or clip over the whole screen (a clip plays).
class _SealedAttachmentView extends StatelessWidget {
  const _SealedAttachmentView({required this.model, required this.message, required this.ink});

  final AppModel model;
  final ChatMessage message;
  final Color ink;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final attachment = message.attachment!;
    final together = model.together;
    void open() => unawaited(together.openAttachment(message));
    final seconds = ((attachment.durationMs ?? 0) / 1000).round();
    final length = '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
    if (message.media?.gone == true) {
      return Text(
        T.text('messagesDeleted'),
        style: AppText.display(14 * scale, weight: FontWeight.w600, color: ink),
      );
    }
    if (attachment.kind == 'voice') {
      return _VoiceNoteView(
        model: model,
        id: attachment.mediaId,
        durationMs: attachment.durationMs,
        ink: ink,
        onTap: open,
      );
    }
    final width = (attachment.width ?? 16).toDouble();
    final height = (attachment.height ?? 9).toDouble();
    final aspect = (width / height).clamp(0.5, 2.4);
    final picture = attachment.kind == 'image'
        ? together.sealedFile(message)
        : (attachment.poster == null ? null : together.sealedFile(message, poster: true));
    return Pressable(
      onTap: open,
      builder: (context, hovering) => ClipRRect(
        borderRadius: BorderRadius.circular(12 * scale),
        child: SizedBox(
          width: 320 * scale,
          child: AspectRatio(
            aspectRatio: aspect,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(color: Colors.black.withValues(alpha: 0.3)),
                if (picture != null)
                  FutureBuilder<Uint8List>(
                    future: picture,
                    builder: (context, snapshot) => snapshot.hasData
                        ? Image.memory(snapshot.data!, fit: BoxFit.cover, gaplessPlayback: true)
                        : Center(
                            child: Icon(
                              snapshot.hasError ? Icons.broken_image_rounded : Icons.lock_rounded,
                              size: 22 * scale,
                              color: Colors.white.withValues(alpha: 0.4),
                            ),
                          ),
                  ),
                if (attachment.kind == 'clip')
                  Center(
                    child: Container(
                      width: 46 * scale,
                      height: 46 * scale,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: hovering ? 0.65 : 0.5),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(Icons.play_arrow_rounded, size: 28 * scale, color: Colors.white),
                    ),
                  ),
                if (attachment.kind == 'clip')
                  PositionedDirectional(
                    end: 8 * scale,
                    bottom: 6 * scale,
                    child: Text(length, style: AppText.display(12 * scale, weight: FontWeight.w700)),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Files dragged over the open conversation: a dashed frame in the accent and what letting go
/// does, as on the Mac.
class _DropOverlay extends StatelessWidget {
  const _DropOverlay({required this.accent});

  final Color accent;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return CustomPaint(
      painter: _DashedFrame(color: accent, radius: 24 * scale, width: 3 * scale, dash: 10 * scale, gap: 8 * scale),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(24 * scale),
        ),
        child: Center(
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 22 * scale, vertical: 12 * scale),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.add_photo_alternate_rounded, size: 22 * scale, color: Colors.white),
                SizedBox(width: 10 * scale),
                Text(T.text('messagesSendPhoto'), style: AppText.display(20 * scale, weight: FontWeight.w600)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DashedFrame extends CustomPainter {
  const _DashedFrame({
    required this.color,
    required this.radius,
    required this.width,
    required this.dash,
    required this.gap,
  });

  final Color color;
  final double radius;
  final double width;
  final double dash;
  final double gap;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(width / 2);
    final path = Path()..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(radius)));
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = width;
    for (final metric in path.computeMetrics()) {
      for (var at = 0.0; at < metric.length; at += dash + gap) {
        canvas.drawPath(metric.extractPath(at, math.min(at + dash, metric.length)), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedFrame old) =>
      old.color != color || old.radius != radius || old.width != width || old.dash != dash || old.gap != gap;
}

/// A voice note in a bubble, as on the Mac: a round play or pause, bars standing for the sound
/// filled as it plays, and its length (or how far it has got). It plays one at a time; leaving
/// the screen stops it.
class _VoiceNoteView extends StatefulWidget {
  const _VoiceNoteView({
    required this.model,
    required this.id,
    required this.durationMs,
    required this.ink,
    required this.onTap,
  });

  final AppModel model;
  final String id;
  final int? durationMs;
  final Color ink;
  final VoidCallback onTap;

  @override
  State<_VoiceNoteView> createState() => _VoiceNoteViewState();
}

class _VoiceNoteViewState extends State<_VoiceNoteView> {
  @override
  void didUpdateWidget(_VoiceNoteView old) {
    super.didUpdateWidget(old);
    if (old.id != widget.id) old.model.together.stopVoiceNote(old.id);
  }

  @override
  void dispose() {
    widget.model.together.stopVoiceNote(widget.id);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final seed = widget.id.runes.fold(0, (sum, rune) => sum + rune) % 7;
    final seconds = (widget.durationMs ?? 0) / 1000;
    return ValueListenableBuilder<VoiceNoteState>(
      valueListenable: widget.model.together.voiceNotes.state,
      builder: (context, state, _) {
        final mine = state.id == widget.id;
        final playing = mine && state.playing;
        final progress = mine ? state.progress : 0.0;
        final shown = Duration(seconds: (playing ? seconds * progress : seconds).round());
        return Semantics(
          button: true,
          label: T.text('messagesVoice'),
          child: Pressable(
            onTap: widget.onTap,
            builder: (context, hovering) => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 36 * scale,
                  height: 36 * scale,
                  decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                  child: Icon(
                    playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    size: 22 * scale,
                    color: Colors.black,
                  ),
                ),
                SizedBox(width: 12 * scale),
                for (var bar = 0; bar < 24; bar++) ...[
                  if (bar > 0) SizedBox(width: 3 * scale),
                  Container(
                    width: 3 * scale,
                    height: (6 + 16 * math.sin(bar * 1.7 + seed).abs()) * scale,
                    decoration: BoxDecoration(
                      color: widget.ink.withValues(alpha: bar / 24 < progress ? 1 : 0.38),
                      borderRadius: BorderRadius.circular(2 * scale),
                    ),
                  ),
                ],
                SizedBox(width: 12 * scale),
                Text(
                  ClipState.clock(shown),
                  style: AppText.display(
                    13 * scale,
                    weight: FontWeight.w600,
                    color: widget.ink.withValues(alpha: 0.85),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// A chat's picture or clip over the whole screen (the macOS launcher's MediaViewer): a click on
/// the picture, or around the clip, closes it; the clip plays in the launcher.
class _ChatViewer extends StatelessWidget {
  const _ChatViewer({required this.model, required this.media});

  final AppModel model;
  final ViewedMedia media;

  Widget _picture(String? link, Future<Uint8List>? bytes) {
    if (link != null) return RemotePicture(model: model, link: link, fit: BoxFit.contain);
    if (bytes == null) return const SizedBox.shrink();
    return FutureBuilder<Uint8List>(
      future: bytes,
      builder: (context, snapshot) => snapshot.hasData
          ? Image.memory(snapshot.data!, fit: BoxFit.contain, gaplessPlayback: true)
          : Center(
              child: Icon(
                snapshot.hasError ? Icons.broken_image_rounded : Icons.lock_rounded,
                size: 28,
                color: Colors.white.withValues(alpha: 0.4),
              ),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final together = model.together;
    final clip = media.clip;
    final hasPoster = media.poster != null || media.posterBytes != null;
    return ColoredBox(
      key: const ValueKey('chat-viewer'),
      color: Colors.black.withValues(alpha: 0.94),
      child: WithBackPill(
        onBack: together.closeChatViewer,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: together.closeChatViewer,
          child: Padding(
            padding: EdgeInsets.fromLTRB(70 * scale, 80 * scale, 70 * scale, 40 * scale),
            child: clip == null
                ? _picture(media.link, media.bytes)
                : Center(
                    child: AspectRatio(
                      aspectRatio: media.aspect,
                      child: GestureDetector(
                        onTap: () {},
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(14 * scale),
                          child: ClipPlayerView(
                            source: clip,
                            create: model.services.clipPlayback,
                            onFailed: model.playClipOutside,
                            accent: model.accentChoice.color,
                            poster: hasPoster ? _picture(media.poster, media.posterBytes) : null,
                          ),
                        ),
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
