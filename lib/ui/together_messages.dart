part of 'together_model.dart';

/// Something the messages list holds: a conversation, or a friend without one yet.
sealed class MessageTarget {
  const MessageTarget();
}

class ConversationTarget extends MessageTarget {
  const ConversationTarget(this.conversation);
  final Conversation conversation;
}

class FriendTarget extends MessageTarget {
  const FriendTarget(this.friend);
  final Friend friend;
}

/// A group to start: friends picked and a name.
class NewGroupTarget extends MessageTarget {
  const NewGroupTarget();
}

/// The menu over the thread: a message's (react, reply, edit, unsend, then asked again) or a
/// conversation's (pin, mute); the row the keys are on and, on the reactions, which one.
class MessageMenu {
  MessageMenu.message(ChatMessage this.message) : conversationId = message.conversationId;
  MessageMenu.conversation(this.conversationId) : message = null;

  final ChatMessage? message;
  final String conversationId;
  int row = 0;
  int reaction = 0;
  bool confirming = false;

  /// Reporting the message: the reasons are the rows.
  bool reporting = false;
}

/// Why a message is reported, as the server knows the reasons.
const reportReasons = ['spam', 'harassment', 'hate', 'sexual', 'other'];

/// Messages on AnyTogether: the conversations (and friends to start one with) on the left, the
/// thread on the right with quick replies a controller can send and a field to type in.
extension TogetherMessages on TogetherModel {
  static List<String> get quickReplies => [
    T.text('quickHello'),
    'GG',
    T.text('quickOnMyWay'),
    T.text('quickJoinMe'),
    T.text('quickOneSec'),
  ];

  /// The composer's place among the thread's buttons: after the quick replies.
  static int get composer => quickReplies.length;

  static const draftRow = 'message-draft';
  static const groupNameRow = 'group-name';

  int get unread => hub.messages.unread;

  List<MessageTarget> get messageTargets {
    final me = user?.id;
    final conversations = hub.messages.conversations;
    final talking = {
      for (final conversation in conversations)
        if (!conversation.group) ...conversation.others(me).map((person) => person.id),
    };
    return [
      for (final conversation in conversations) ConversationTarget(conversation),
      if (hub.friends.friends.isNotEmpty) const NewGroupTarget(),
      for (final friend in hub.friends.friends)
        if (!talking.contains(friend.person.id)) FriendTarget(friend),
    ];
  }

  MessageTarget? get selectedTarget {
    final targets = messageTargets;
    return targets.isEmpty ? null : targets[messagesIndex.clamp(0, targets.length - 1)];
  }

  /// What a target is known by while the list moves: the conversation's ID, or the friend's.
  static String targetKey(MessageTarget target) => switch (target) {
    ConversationTarget(:final conversation) => conversation.id,
    FriendTarget(:final friend) => 'friend:${friend.person.id}',
    NewGroupTarget() => 'new-group',
  };

  /// The keys onto the target at [index], remembered by what it is, not where it is.
  void _selectTarget(int index) {
    final targets = messageTargets;
    messagesIndex = targets.isEmpty ? 0 : index.clamp(0, targets.length - 1);
    messagesSelectedKey = targets.isEmpty ? null : targetKey(targets[messagesIndex]);
  }

  /// A message came in, a conversation was pinned, a friend added: the list moved, and the keys
  /// stay on the conversation they were on (the one the thread shows), not on its old place.
  void followMessagesSelection() {
    final key = messagesSelectedKey;
    if (key == null) return;
    final at = messageTargets.indexWhere((target) => targetKey(target) == key);
    if (at >= 0) messagesIndex = at;
  }

  Future<void> openMessages() async {
    _selectTarget(0);
    messagesInThread = false;
    _resetThread();
    messageFocus = composer;
    app.open(Layer.messages);
    if (!signedIn) return;
    try {
      if (!hub.messages.loaded) await hub.messages.refresh();
      _selectTarget(messagesIndex);
      await _showSelected();
    } on Object {
      // The list shows what it has; the socket brings the rest.
    }
  }

  /// The conversation with [person], made the first time, opened with the keys in it.
  Future<void> messageFriend(Person person) async {
    app.open(Layer.messages);
    _resetThread();
    messagesInThread = true;
    messageFocus = composer;
    try {
      await hub.messages.withFriend(person.id);
      final at = messageTargets.indexWhere(
        (target) => target is ConversationTarget && target.conversation.id == hub.messages.openId,
      );
      if (at >= 0) _selectTarget(at);
      app.refresh();
    } on Object catch (error) {
      app.show(message(error));
    }
  }

  /// One conversation, opened with the keys in its field: a message notification clicked. The
  /// list is read again first when the conversation is new to it.
  Future<void> openConversation(String id) async {
    if (app.overlay != Layer.messages) app.open(Layer.messages);
    _resetThread();
    messageFocus = composer;
    if (!signedIn) return;
    try {
      if (hub.messages.byId(id) == null) await hub.messages.refresh();
      final at = messageTargets.indexWhere((target) => target is ConversationTarget && target.conversation.id == id);
      if (at < 0) {
        // Gone (left, removed): the list as it is.
        _selectTarget(0);
        messagesInThread = false;
        app.refresh();
        await _showSelected();
        return;
      }
      _selectTarget(at);
      messagesInThread = true;
      app.refresh();
      if (hub.messages.openId != id) await hub.messages.show(id);
    } on Object {
      // The list shows what it has; the socket brings the rest.
    }
  }

  /// A row of the list clicked: that conversation shown, the keys in its field (a friend's
  /// first conversation is made now).
  Future<void> pickMessageTarget(MessageTarget target) async {
    final key = targetKey(target);
    final at = messageTargets.indexWhere((t) => targetKey(t) == key);
    if (at < 0) return;
    if (key != messagesSelectedKey) _resetThread();
    _selectTarget(at);
    await _enterThread();
  }

  Future<void> _showSelected() async {
    final target = selectedTarget;
    switch (target) {
      case ConversationTarget(:final conversation) when hub.messages.openId != conversation.id:
        await hub.messages.show(conversation.id);
      case FriendTarget() || NewGroupTarget():
        hub.messages.hide();
      default:
        break;
    }
  }

  /// Into the thread: the conversation chosen is the one shown (and answered), and a friend's
  /// first conversation is made now.
  Future<void> _enterThread() async {
    final target = selectedTarget;
    if (target == null) return;
    messagesInThread = true;
    messageFocus = composer;
    app.sounds.play(Cue.select);
    if (target is NewGroupTarget) {
      groupFocus = 0;
      app.refresh();
      return;
    }
    app.refresh();
    if (target is FriendTarget) {
      await messageFriend(target.friend.person);
    } else {
      await _showSelected();
    }
  }

  /// Sends [text] to the conversation shown, as the answer to the message being replied to.
  Future<void> sendMessage(String text) async {
    if (text.trim().isEmpty) return;
    // Encrypted, and nobody on the other side can read it now: nothing goes out.
    if (openLock?.state == EncryptionState.noDevice) {
      app.show(T.format('e2eeNoDevice', [partnerName]));
      return;
    }
    app.sounds.play(Cue.select);
    final reply = replyingTo;
    replyingTo = null;
    if (hub.messages.openId == null) {
      final target = selectedTarget;
      if (target is! FriendTarget) return;
      await messageFriend(target.friend.person);
    }
    await hub.messages.send(text, replyTo: reply);
  }

  void messagesCommand(Command command) {
    // A picture or clip over the whole screen: ✕, ○ and △ close it, as on the Mac.
    if (chatViewing != null) {
      if (command == Command.back || command == Command.select || command == Command.options) closeChatViewer();
      return;
    }
    if (lockSheet) return _lockSheetCommand(command);
    if (messageMenu != null) return _menuCommand(command);
    final targets = messageTargets;
    if (!messagesInThread) {
      switch (command) {
        case Command.up || Command.down:
          final next = (messagesIndex + (command == Command.down ? 1 : -1)).clamp(
            0,
            targets.isEmpty ? 0 : targets.length - 1,
          );
          if (next == messagesIndex) return;
          _selectTarget(next);
          _resetThread();
          app.sounds.play(Cue.move);
          app.refresh();
          unawaited(_showSelected().catchError((Object _) {}));
        case Command.right || Command.select:
          unawaited(_enterThread().catchError((Object _) {}));
        // △ on a conversation: pin it, mute it.
        case Command.options when selectedTarget is ConversationTarget:
          openConversationMenu((selectedTarget as ConversationTarget).conversation);
        case Command.back || Command.options:
          _resetThread();
          hub.messages.hide();
          app.closeOverlay();
        default:
          break;
      }
      return;
    }
    if (selectedTarget is NewGroupTarget) return _groupCommand(command);
    final focused = focusedMessage;
    if (focused != null) return _onMessage(command, focused);
    switch (command) {
      case Command.left:
        if (messageFocus == 0) {
          _leaveThread();
        } else {
          messageFocus--;
          app.sounds.play(Cue.move);
        }
        app.refresh();
      case Command.right:
        final next = (messageFocus + 1).clamp(0, composer);
        if (next != messageFocus) app.sounds.play(Cue.move);
        messageFocus = next;
        app.refresh();
      case Command.up:
        // Up from the field: onto the newest message, then older ones.
        if (hub.messages.thread.isEmpty) {
          unawaited(hub.messages.older().catchError((Object _) {}));
        } else {
          messageCursor = 0;
          app.sounds.play(Cue.move);
          app.refresh();
        }
      case Command.select:
        final failed = hub.messages.thread.where((message) => message.failed).lastOrNull;
        if (messageFocus == composer) {
          if (failed != null && draft.isEmpty && editingMessage == null) {
            unawaited(hub.messages.retry(failed));
          } else {
            app.startEditing(draftRow);
          }
        } else {
          unawaited(sendMessage(quickReplies[messageFocus]));
        }
      case Command.options:
        if (hub.messages.open case final Conversation conversation) openConversationMenu(conversation);
      case Command.back:
        // A reply or an edit is dropped first.
        if (replyingTo != null || editingMessage != null) {
          cancelComposerNote();
          app.sounds.play(Cue.back);
        } else {
          _leaveThread();
        }
        app.refresh();
      default:
        break;
    }
  }

  /// The friends a new group can have, in the order the composer lists them.
  List<Friend> get groupFriends => hub.friends.friends;

  /// The new group's rows: its name (0), each friend to pick, then Start the group.
  void _groupCommand(Command command) {
    final last = groupFriends.length + 1;
    switch (command) {
      case Command.up || Command.down:
        final next = (groupFocus + (command == Command.down ? 1 : -1)).clamp(0, last);
        if (next == groupFocus) return;
        groupFocus = next;
        app.sounds.play(Cue.move);
        app.refresh();
      case Command.select:
        if (groupFocus == 0) {
          app.startEditing(groupNameRow);
        } else if (groupFocus == last) {
          unawaited(startGroup());
        } else {
          toggleGroupFriend(groupFriends[groupFocus - 1].person.id);
        }
      case Command.back || Command.left:
        _leaveThread();
        app.refresh();
      case Command.options:
        app.closeOverlay();
      default:
        break;
    }
  }

  /// A friend in the new group, or out of it again.
  void toggleGroupFriend(String userId) {
    if (!groupPicked.remove(userId)) groupPicked.add(userId);
    app.sounds.play(Cue.move);
    app.refresh();
  }

  /// The field for the new group's name.
  PanelRow get groupNameField => PanelRow(
    id: groupNameRow,
    title: '',
    kind: TextRow(groupName, (text) => groupName = text, hint: T.text('messagesGroupName')),
  );

  /// The group with the friends picked, opened to write in.
  Future<void> startGroup() async {
    if (!family.messagesAllowed) return;
    final members = [
      for (final friend in groupFriends)
        if (groupPicked.contains(friend.person.id)) friend.person.id,
    ];
    if (members.isEmpty) return app.show(T.text('messagesGroupPick'));
    try {
      final group = await hub.messages.startGroup(members, title: groupName);
      groupPicked.clear();
      groupName = '';
      final at = messageTargets.indexWhere(
        (target) => target is ConversationTarget && target.conversation.id == group.id,
      );
      if (at >= 0) _selectTarget(at);
      messagesInThread = true;
      messageFocus = composer;
      app.sounds.play(Cue.select);
      app.startEditing(draftRow);
      app.show(T.format('messagesGroupMade', [group.name(user?.id)]));
    } on Object catch (error) {
      app.show(message(error));
    }
  }

  /// The keys on a message: up and down through the thread, its menu on Enter or △.
  void _onMessage(Command command, ChatMessage message) {
    final thread = hub.messages.thread;
    switch (command) {
      case Command.up:
        if (messageCursor! < thread.length - 1) {
          messageCursor = messageCursor! + 1;
          app.sounds.play(Cue.move);
          app.refresh();
        } else {
          unawaited(hub.messages.older().catchError((Object _) {}));
        }
      case Command.down:
        messageCursor = messageCursor! == 0 ? null : messageCursor! - 1;
        app.sounds.play(Cue.move);
        app.refresh();
      case Command.left:
        _leaveThread();
        app.refresh();
      case Command.select || Command.options:
        if (message.failed) {
          unawaited(hub.messages.retry(message));
        } else {
          openMessageMenu(message);
        }
      case Command.back:
        messageCursor = null;
        app.sounds.play(Cue.back);
        app.refresh();
      default:
        break;
    }
  }

  void _leaveThread() {
    messagesInThread = false;
    messageCursor = null;
    app.sounds.play(Cue.back);
  }

  /// A reply, an edit, the message the keys were on and an open menu belong to one conversation:
  /// moving to another drops them.
  void _resetThread() {
    messageCursor = null;
    messageMenu = null;
    lockSheet = false;
    replyingTo = null;
    if (editingMessage != null) {
      editingMessage = null;
      draft = '';
    }
  }

  /// The message the keys are on, if they are on one.
  ChatMessage? get focusedMessage {
    final cursor = messageCursor;
    final thread = hub.messages.thread;
    if (!messagesInThread || cursor == null || thread.isEmpty) return null;
    return thread[thread.length - 1 - cursor.clamp(0, thread.length - 1)];
  }

  /// The keys onto [message] (clicked, or for the tests).
  void focusMessage(ChatMessage message) {
    final thread = hub.messages.thread;
    final at = thread.indexWhere((m) => m.id == message.id);
    if (at < 0) return;
    messagesInThread = true;
    messageCursor = thread.length - 1 - at;
    app.refresh();
  }

  /// A message as the thread has it now (its reactions may have changed since the menu opened).
  ChatMessage _current(ChatMessage message) =>
      hub.messages.thread.where((m) => m.id == message.id).firstOrNull ?? message;

  /// What a message can have done to it: react and reply; the user's own edited (while it may
  /// be) and unsent. Nothing for one removed or still on its way.
  void openMessageMenu(ChatMessage message) {
    if (message.deleted || message.seq <= 0) return;
    focusMessage(message);
    messageMenu = MessageMenu.message(message);
    app.sounds.play(Cue.select);
    app.refresh();
  }

  void openConversationMenu(Conversation conversation) {
    messageMenu = MessageMenu.conversation(conversation.id);
    app.sounds.play(Cue.select);
    app.refresh();
  }

  void closeMessageMenu() {
    messageMenu = null;
    app.sounds.play(Cue.back);
    app.refresh();
  }

  /// The menu's rows by id: `react` (the seven reactions, left and right), `reply`, `edit`,
  /// `unsend`, then asked again (`unsend-confirm`, `cancel`); a conversation's `pin` and `mute`.
  List<String> get messageMenuItems {
    final menu = messageMenu;
    if (menu == null) return const [];
    final shown = menu.message;
    if (shown == null) {
      final lock = hub.messages.lockOf(menu.conversationId);
      return [
        if (lock != null) 'lock',
        // As on the Mac: any conversation with a device to send to, where the family allows it.
        if (family.mediaAllowed && lock?.state != EncryptionState.noDevice && app.services.pickPictures != null)
          'photo',
        'pin',
        'mute',
      ];
    }
    if (menu.confirming) return const ['unsend-confirm', 'cancel'];
    if (menu.reporting) return [for (final reason in reportReasons) 'report-$reason', 'cancel'];
    final message = _current(shown);
    final me = user?.id;
    final readable = !message.encrypted || message.seal == SealState.opened;
    return [
      'react',
      'reply',
      if ((message.attachment != null || message.media?.kind == 'voice') && message.media?.gone != true) 'open',
      if (Messages.canEdit(message, me, DateTime.now()) && readable) 'edit',
      if (message.authorId == me) 'unsend',
      if (message.authorId != me && readable) 'report',
    ];
  }

  String menuLabel(String item) {
    final conversation = hub.messages.byId(messageMenu?.conversationId);
    return switch (item) {
      'react' => T.text('messagesReact'),
      'reply' => T.text('messagesReply'),
      'edit' => T.text('messagesEdit'),
      'unsend' || 'unsend-confirm' => T.text('messagesUnsend'),
      'pin' => T.text(conversation?.pinned == true ? 'conversationUnpin' : 'conversationPin'),
      'lock' => T.text(hub.messages.lockOf(conversation?.id)?.state == EncryptionState.off ? 'e2eeOff' : 'e2eeOn'),
      'photo' => T.text('messagesSendPhoto'),
      'open' => T.text('messagesOpenAttachment'),
      'report' => T.text('messagesReport'),
      'report-spam' => T.text('reportReasonSpam'),
      'report-harassment' => T.text('reportReasonHarassment'),
      'report-hate' => T.text('reportReasonHate'),
      'report-sexual' => T.text('reportReasonSexual'),
      'report-other' => T.text('reportReasonOther'),
      'mute' => T.text(conversation?.muted == true ? 'conversationUnmute' : 'conversationMute'),
      _ => T.text('cancel'),
    };
  }

  /// The words a reaction has, for the menu.
  static String reactionLabel(String name) => switch (name) {
    'like' => T.text('reactionLike'),
    'love' => T.text('reactionLove'),
    'laugh' => T.text('reactionLaugh'),
    'wow' => T.text('reactionWow'),
    'sad' => T.text('reactionSad'),
    'fire' => T.text('reactionFire'),
    _ => T.text('reactionGg'),
  };

  void _menuCommand(Command command) {
    final menu = messageMenu!;
    final items = messageMenuItems;
    switch (command) {
      case Command.up || Command.down:
        final next = (menu.row + (command == Command.down ? 1 : -1)).clamp(0, items.length - 1);
        if (next == menu.row) return;
        menu.row = next;
        app.sounds.play(Cue.move);
        app.refresh();
      case Command.left || Command.right when items[menu.row] == 'react':
        final next = (menu.reaction + (command == Command.right ? 1 : -1)).clamp(0, messageReactions.length - 1);
        if (next == menu.reaction) return;
        menu.reaction = next;
        app.sounds.play(Cue.move);
        app.refresh();
      case Command.select:
        runMenuItem(items[menu.row.clamp(0, items.length - 1)]);
      case Command.back || Command.options:
        closeMessageMenu();
      default:
        break;
    }
  }

  /// Does what a row of the open menu says.
  void runMenuItem(String item) {
    final menu = messageMenu;
    if (menu == null) return;
    final message = menu.message == null ? null : _current(menu.message!);
    final conversation = hub.messages.byId(menu.conversationId);
    switch (item) {
      case 'react' when message != null:
        messageMenu = null;
        app.sounds.play(Cue.select);
        unawaited(toggleReaction(message, messageReactions[menu.reaction]));
      case 'reply' when message != null:
        startReply(message);
      case 'edit' when message != null:
        startEdit(message);
      case 'unsend':
        menu
          ..confirming = true
          ..row = 0;
        app.sounds.play(Cue.select);
      case 'unsend-confirm' when message != null:
        messageMenu = null;
        app.sounds.play(Cue.select);
        unawaited(unsendMessage(message));
      case 'lock':
        openLockSheet();
        return;
      case 'photo':
        messageMenu = null;
        app.sounds.play(Cue.select);
        if (conversation != null) unawaited(pickPictures(conversation));
      case 'open' when message != null:
        messageMenu = null;
        app.sounds.play(Cue.select);
        if (message.attachment != null) {
          unawaited(openAttachment(message));
        } else if (message.media case final media?) {
          viewChatMedia(media);
        }
      case 'report':
        menu
          ..reporting = true
          ..row = 0;
        app.sounds.play(Cue.select);
      case final String reason when reason.startsWith('report-') && message != null:
        messageMenu = null;
        app.sounds.play(Cue.select);
        unawaited(reportMessage(message, reason.substring('report-'.length)));
      case 'pin' when conversation != null:
        messageMenu = null;
        app.sounds.play(Cue.select);
        unawaited(setPinned(conversation, !conversation.pinned));
      case 'mute' when conversation != null:
        messageMenu = null;
        app.sounds.play(Cue.select);
        unawaited(setMuted(conversation, !conversation.muted));
      default:
        closeMessageMenu();
        return;
    }
    app.refresh();
  }

  /// Answers [message]: the composer says to whom, and the cursor goes into it.
  void startReply(ChatMessage message) {
    if (editingMessage != null) draft = '';
    editingMessage = null;
    replyingTo = message.seq;
    _toComposer();
  }

  /// New words for a message of the user's: its text into the composer.
  void startEdit(ChatMessage message) {
    replyingTo = null;
    editingMessage = message;
    draft = message.words ?? '';
    _toComposer();
  }

  void _toComposer() {
    messageMenu = null;
    messageCursor = null;
    messagesInThread = true;
    messageFocus = composer;
    app.sounds.play(Cue.select);
    app.startEditing(draftRow);
    app.refresh();
  }

  /// The reply or the edit dropped; an edit's words with it.
  void cancelComposerNote() {
    replyingTo = null;
    if (editingMessage != null) {
      editingMessage = null;
      draft = '';
    }
    app.refresh();
  }

  /// What the line above the composer says while it answers or edits: the title (Replying to
  /// Ana, Edit) and the words.
  (String, String)? get composerNote {
    final editing = editingMessage;
    if (editing != null) return (T.text('messagesEdit'), editing.words ?? '');
    final seq = replyingTo;
    if (seq == null) return null;
    final target = hub.messages.inThread(seq);
    final name = authorName(hub.messages.open, target?.authorId);
    return (T.format('messagesReplyingTo', [name]), _quoted(target));
  }

  /// The message [message] answers, as its quote shows it: who wrote it and what (an earlier
  /// message when it is not loaded, Message removed when it is gone).
  (String, String)? quoteOf(ChatMessage message) {
    final seq = message.replyTo;
    if (seq == null) return null;
    final target = hub.messages.inThread(seq);
    if (target == null) return ('', T.text('messagesEarlier'));
    return (authorName(hub.messages.byId(message.conversationId), target.authorId), _quoted(target));
  }

  static String _quoted(ChatMessage? target) => target == null
      ? T.text('messagesEarlier')
      : target.deleted
      ? T.text('messagesDeleted')
      : target.encrypted && target.seal != SealState.opened
      ? shownText(target)
      : (target.words ?? previewText(target));

  /// The message of the user's that gets the receipt line: their newest one in the thread.
  ChatMessage? receiptFor(Conversation conversation) {
    if (hub.messages.openId != conversation.id) return null;
    final me = user?.id;
    return hub.messages.thread.where((m) => m.authorId == me && m.seq > 0).lastOrNull;
  }

  /// Sent, Delivered, Read; Seen by 2, Seen by everyone; nothing for someone else's message or
  /// from a server without receipts.
  String? receiptText(Conversation conversation, ChatMessage message) {
    final receipt = Messages.receiptOf(conversation, message, user?.id);
    if (receipt == null) return null;
    return switch (receipt.kind) {
      ReceiptKind.sent => T.text('receiptSent'),
      ReceiptKind.delivered => T.text('receiptDelivered'),
      ReceiptKind.read => T.text('receiptRead'),
      ReceiptKind.seen when receipt.everyone => T.text('receiptSeenByEveryone'),
      ReceiptKind.seen => T.format('receiptSeenBy', [receipt.count]),
    };
  }

  Future<void> toggleReaction(ChatMessage message, String name) async {
    try {
      await hub.messages.react(_current(message), name);
    } on Object catch (error) {
      app.show(this.message(error));
    }
  }

  Future<void> unsendMessage(ChatMessage message) async {
    try {
      await hub.messages.unsend(message);
    } on Object catch (error) {
      app.show(this.message(error));
    }
  }

  Future<void> _finishEdit(ChatMessage editing, String text) async {
    if (text.trim().isEmpty || text.trim() == (editing.words ?? '').trim()) return;
    try {
      await hub.messages.edit(editing, text);
    } on TogetherProblem catch (problem) {
      app.show(
        problem.code == 'edit_limit' || problem.code == 'forbidden' ? T.text('messagesEditLimit') : message(problem),
      );
    } on Object catch (error) {
      app.show(message(error));
    }
  }

  /// Pinned to the top or not (five at most); the keys stay on the conversation they were on.
  Future<void> setPinned(Conversation conversation, bool pinned) =>
      _keepingSelection(() => hub.messages.setPinned(conversation, pinned));

  Future<void> setMuted(Conversation conversation, bool muted) =>
      _keepingSelection(() => hub.messages.setMuted(conversation, muted));

  Future<void> _keepingSelection(Future<void> Function() change) async {
    final selected = selectedTarget;
    try {
      await change();
    } on TogetherProblem catch (problem) {
      app.show(problem.code == 'full' ? T.format('conversationPinFull', [Messages.maxPinned]) : message(problem));
    } on Object catch (error) {
      app.show(message(error));
    }
    if (selected is ConversationTarget) {
      final at = messageTargets.indexWhere(
        (target) => target is ConversationTarget && target.conversation.id == selected.conversation.id,
      );
      if (at >= 0) _selectTarget(at);
    }
    app.refresh();
  }

  /// The composer as a text row, for the field the thread shows; Enter sends, or saves an edit.
  PanelRow get draftField => PanelRow(
    id: draftRow,
    title: '',
    kind: TextRow(
      draft,
      (text) {
        draft = text;
        if (editingMessage == null) hub.messages.typing();
      },
      submit: () {
        final text = draft;
        draft = '';
        final editing = editingMessage;
        if (editing != null) {
          editingMessage = null;
          unawaited(_finishEdit(editing, text));
        } else {
          unawaited(sendMessage(text));
        }
        app.refresh();
      },
      hint: T.text('messagesWrite'),
    ),
  );

  /// Who someone in a conversation is, for the thread.
  String authorName(Conversation? conversation, String? userId) =>
      conversation?.author(userId)?.displayName ?? hub.friends.byId(userId ?? '')?.person.displayName ?? '';

  /// "Ayşe is typing…" for the people in [typing], everyone's name as on the Mac; null for none.
  String? typingText(Conversation conversation, List<String> typing) {
    final names = [
      for (final id in typing)
        if (authorName(conversation, id) case final name when name.isNotEmpty) name,
    ];
    if (names.isEmpty) return null;
    return names.length == 1
        ? T.format('messagesTyping', [names.single])
        : T.format('messagesTypingMany', [names.join(', ')]);
  }

  /// A message that came while its conversation is not on screen: a word at the bottom.
  void _messageArrived(Map<String, dynamic> data) {
    final author = data['authorId'];
    if (author == null || author == user?.id) return;
    final conversation = data['conversationId'];
    if (app.overlay == Layer.messages && hub.messages.openId == conversation) return;
    // Muted: it comes in, unread, without a word.
    if (hub.messages.byId(conversation as String?)?.muted == true) return;
    // A sealed one says no more than that it came.
    final text = data['sealed'] != null ? T.text('e2eeNotification') : data['text'];
    if (text is! String) return;
    final name =
        hub.messages.byId(conversation)?.author(author as String?)?.displayName ??
        hub.friends.byId(author as String)?.person.displayName ??
        '';
    // Its sounds, unless the user asked not to be disturbed, as on the Mac.
    if (!doNotDisturb) app.sounds.play(Cue.move);
    disturbingSound();
    // A click on it opens the conversation.
    app.show(
      T.format('messagesFrom', [name, text.length > 80 ? '${text.substring(0, 80)}…' : text]),
      onTap: conversation == null ? null : () => unawaited(openConversation(conversation)),
    );
    // Over a game the card: who wrote it, and what, unless the user asked not to be disturbed,
    // as on the Mac.
    if (!doNotDisturb) unawaited(app.noticeOverGame(name, detail: text, symbol: Icons.chat_bubble_rounded));
  }

  // End-to-end encryption.

  /// The open direct conversation's lock as last worked out; null for a group, before it is
  /// known, or on a server without encryption.
  ConversationLock? get openLock => hub.messages.lockOf(hub.messages.openId);

  /// The other person's name in the open conversation, for the encryption texts.
  String get partnerName {
    final conversation = hub.messages.open;
    return authorName(conversation, conversation?.partner(user?.id));
  }

  /// The encryption sheet's rows: "We compared them" while the number is not marked, OK for a
  /// devices-changed notice, and the way back.
  List<String> get lockSheetRows {
    final lock = openLock;
    return [
      if (lock?.safetyNumber != null && lock?.compared != true) 'compared',
      if (lock?.notice != null) 'dismiss',
      'close',
    ];
  }

  /// The sheet with what the lock means, the safety number and both people's devices.
  void openLockSheet() {
    if (openLock == null) return;
    messageMenu = null;
    lockSheet = true;
    lockSheetRow = 0;
    app.sounds.play(Cue.select);
    app.refresh();
  }

  void closeLockSheet() {
    lockSheet = false;
    app.sounds.play(Cue.back);
    app.refresh();
  }

  void runLockSheetRow(String row) {
    final id = hub.messages.openId;
    switch (row) {
      case 'compared' when id != null:
        hub.e2ee?.markCompared(id);
        app.sounds.play(Cue.select);
      case 'dismiss' when id != null:
        hub.e2ee?.dismissNotice(id);
        app.sounds.play(Cue.select);
      default:
        closeLockSheet();
        return;
    }
    lockSheetRow = lockSheetRow.clamp(0, lockSheetRows.length - 1);
    app.refresh();
  }

  /// The devices-changed notice's OK, from the thread.
  void dismissLockNotice() {
    final id = hub.messages.openId;
    if (id == null) return;
    hub.e2ee?.dismissNotice(id);
    app.refresh();
  }

  void _lockSheetCommand(Command command) {
    final rows = lockSheetRows;
    switch (command) {
      case Command.up || Command.down || Command.left || Command.right:
        final forward = command == Command.down || command == Command.right;
        final next = (lockSheetRow + (forward ? 1 : -1)).clamp(0, rows.length - 1);
        if (next == lockSheetRow) return;
        lockSheetRow = next;
        app.sounds.play(Cue.move);
        app.refresh();
      case Command.select:
        runLockSheetRow(rows[lockSheetRow.clamp(0, rows.length - 1)]);
      case Command.back || Command.options:
        closeLockSheet();
      default:
        break;
    }
  }

  /// The words a message shows: its text, or why a sealed one shows none.
  static String shownText(ChatMessage message) {
    if (message.deleted) return T.text('messagesDeleted');
    return switch (message.seal) {
      SealState.beforeDevice => T.text('e2eeBeforeDevice'),
      SealState.undecryptable => T.text('e2eeUndecryptable'),
      SealState.opening => '…',
      // A photo or clip sent as it is: its caption under the picture, not the "[photo]" the
      // server writes for older clients.
      _ when message.media != null && !message.encrypted && message.kind != 'text' => message.caption ?? '',
      _ => message.text ?? '',
    };
  }

  /// A sealed message's list preview: what it says once opened, Encrypted message otherwise.
  static String previewText(ChatMessage message) {
    if (message.encrypted && message.seal != SealState.opened) return T.text('e2eePreview');
    if (message.encrypted && (message.text ?? '').isEmpty && message.attachment != null) {
      return switch (message.attachment!.kind) {
        'clip' => T.text('messagesClip'),
        'voice' => T.text('messagesVoice'),
        _ => T.text('messagesPhoto'),
      };
    }
    // A photo or clip sent as it is: its caption, or what it is when no words came with it (the
    // server's text for it is a "[photo]" stand-in).
    if (message.media != null && !message.encrypted && message.kind != 'text' && (message.caption ?? '').isNotEmpty) {
      return message.caption!;
    }
    if (message.media != null && ((message.text ?? '').isEmpty || (!message.encrypted && message.kind != 'text'))) {
      return switch (message.media!.kind) {
        'clip' => T.text('messagesClip'),
        'voice' => T.text('messagesVoice'),
        _ => T.text('messagesPhoto'),
      };
    }
    return message.text ?? '';
  }

  /// A conversation's options › Send a photo: picture files chosen on this computer (several at
  /// once, as on the Mac), each drawn again here and sent.
  Future<void> pickPictures(Conversation conversation) async {
    final pick = app.services.pickPictures;
    if (pick == null) return;
    final files = await pick();
    if (files == null || files.isEmpty) return;
    await sendPictures(files, conversation);
  }

  /// Files dropped on the open conversation: its pictures go, anything else is said no to, as on
  /// the Mac.
  void dropPictures(List<String> files) {
    final conversation = hub.messages.byId(hub.messages.openId);
    if (conversation == null || !family.mediaAllowed || files.isEmpty) return;
    final pictures = files.where(SealedPhoto.isPictureFile).toList();
    if (pictures.length < files.length) app.show(T.text('cloudBadMedia'));
    unawaited(sendPictures(pictures, conversation));
  }

  void setChatDropping(bool dropping) {
    if (chatDropping == dropping) return;
    chatDropping = dropping;
    app.refresh();
  }

  /// A sealed attachment's file (or poster) opened in memory, once per message.
  Future<Uint8List> sealedFile(ChatMessage message, {bool poster = false}) {
    final key = '${message.id}:${message.sealed?.sig}:${poster ? 'poster' : 'file'}';
    final known = sealedFiles[key];
    if (known != null) return known;
    if (sealedFiles.length >= 40) sealedFiles.remove(sealedFiles.keys.first);
    final loading = hub.messages.attachmentBytes(message, poster: poster);
    sealedFiles[key] = loading;
    // A failure is tried again the next time it is asked for.
    loading.then(
      (_) {},
      onError: (Object _) {
        sealedFiles.remove(key);
      },
    );
    return loading;
  }

  /// A photo or clip sent as it is, over the whole screen (a clip plays in the launcher, as on
  /// the Mac); a voice note plays in its bubble.
  void viewChatMedia(MediaLink media) {
    final link = media.url;
    if (media.gone || link == null) return;
    if (media.kind == 'clip') {
      chatViewing = ViewedMedia.clip(link, poster: media.poster, aspect: media.aspect);
    } else if (media.kind == 'image') {
      chatViewing = ViewedMedia.picture(link: link);
    } else {
      playVoiceNote(media.id, () async => link);
      return;
    }
    app.sounds.play(Cue.select);
    app.refresh();
  }

  void closeChatViewer() {
    chatViewing = null;
    app.sounds.play(Cue.back);
    app.refresh();
  }

  /// A sealed attachment: a photo over the whole screen from memory; a clip from a temporary
  /// file only this user can read, playing in the launcher; a voice note in its bubble.
  Future<void> openAttachment(ChatMessage message) async {
    final attachment = message.attachment;
    if (attachment == null) return;
    final aspect = mediaAspect(attachment.width, attachment.height);
    if (attachment.kind == 'image') {
      chatViewing = ViewedMedia.picture(bytes: sealedFile(message), aspect: aspect);
      app.refresh();
      return;
    }
    if (attachment.kind == 'voice') {
      playVoiceNote(attachment.mediaId, () => _openedFile(message));
      return;
    }
    try {
      final path = await _openedFile(message);
      chatViewing = ViewedMedia.clip(
        path,
        posterBytes: attachment.poster == null ? null : sealedFile(message, poster: true),
        aspect: aspect,
      );
      app.refresh();
    } on Object {
      app.show(T.text('messagesAttachmentFailed'));
    }
  }

  /// A sealed clip or voice note, opened to a temporary file only this user can read.
  Future<String> _openedFile(ChatMessage message) async {
    final bytes = await sealedFile(message);
    final folder = Directory(p.join(Directory.systemTemp.path, 'anyps5-attachments'))..createSync(recursive: true);
    Posix.chmod(folder.path, 448); // 0700
    // What was opened an hour ago and more goes first.
    for (final old in folder.listSync()) {
      if (old is File && DateTime.now().difference(old.statSync().modified) > const Duration(hours: 1)) {
        try {
          old.deleteSync();
        } on FileSystemException {
          // Still open in a viewer.
        }
      }
    }
    final extension = switch (message.attachment?.type) {
      'image/png' => 'png',
      'image/jpeg' => 'jpg',
      'image/webp' => 'webp',
      'video/mp4' => 'mp4',
      'audio/ogg' => 'ogg',
      'audio/webm' => 'webm',
      'audio/mp4' || 'audio/aac' => 'm4a',
      _ => 'bin',
    };
    final path = p.join(folder.path, '${uuidv7()}.$extension');
    writePrivately(path, bytes);
    return path;
  }

  /// Plays a voice note, or pauses the one playing: in the launcher, one at a time, as on the
  /// Mac; in the system's player when the launcher has no player or cannot open it.
  void playVoiceNote(String id, Future<String> Function() source) {
    unawaited(voiceNotes.toggle(id, source));
  }

  /// A voice note's bubble left the screen: it stops, as on the Mac.
  void stopVoiceNote(String id) => unawaited(voiceNotes.stopNote(id));

  /// A voice note the launcher's player could not open: as a file or a link for the system's
  /// player, as before.
  void _voiceInSystemPlayer(String source) {
    final link = Uri.tryParse(source);
    final url = link != null && link.hasScheme ? link : Uri.file(source);
    app.services.openUrl?.call(url);
  }

  Future<void> reportMessage(ChatMessage message, String reason) async {
    try {
      await hub.messages.report(_current(message), reason);
      app.show(T.text('messagesReported'));
    } on Object {
      app.show(T.text('messagesReportFailed'));
    }
  }

  void sendFailed(Object error) {
    if (error is E2eeUnavailable) {
      app.show(T.format('e2eeNoDevice', [partnerName]));
      return;
    }
    app.show(
      error is TogetherProblem && error.code == 'link_blocked'
          ? T.text('messagesLinkBlocked')
          : isFamilyRestriction(error)
          ? FamilyGate.restrictedText(familyFeature(error), side: familySide(error))
          : T.text('messagesFailed'),
    );
  }
}
