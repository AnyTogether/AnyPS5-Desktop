part of 'together_model.dart';

/// The party chat's keys and field: whether the keys are in it, the message they are on (counted
/// from the newest; null while they are on the field), the menu open over it, and what the field
/// holds: a reply (its seq), an edit, the words.
class PartyChatKeys {
  bool focused = false;
  int? cursor;
  PartyChatMenu? menu;
  int? replyingTo;
  ChatMessage? editing;
  String draft = '';

  /// Which of the quick replies and the field the keys are on, as in Messages; the field first.
  int place = TogetherMessages.composer;

  /// Everything but the words: the party screen opened again.
  void reset() {
    focused = false;
    cursor = null;
    menu = null;
    place = TogetherMessages.composer;
  }
}

/// The menu over the party chat: what can be done with a message, asking before it is unsent,
/// and why it is reported.
class PartyChatMenu {
  PartyChatMenu(this.message);

  final ChatMessage message;
  int row = 0;
  int reaction = 0;

  /// null: what can be done; `unsend`: asked again; `report`: the reasons.
  String? step;
}

/// The party's chat beside its voice (party_chat.dart): the keys go into it with → from the
/// party's rows and come back with ← or Back; a message's menu reacts, replies, edits, unsends
/// and reports, as the messages screen does.
extension TogetherPartyChat on TogetherModel {
  static const draftRow = 'party-chat-draft';

  /// The chat shows on the party screen: a party with a chat (an older server sends none).
  /// A parent's rule against messages hides it, as on the Mac.
  bool get partyChatShown => signedIn && hub.parties.party?.conversationId != null && family.messagesAllowed;

  /// Others' messages in the party's chat since the party screen was last shown: the dot on the
  /// Party tile, as on the Mac.
  int get partyChatUnread => app.overlay == Layer.party || !family.messagesAllowed ? 0 : hub.partyChat.unread;

  /// The party screen opened: the keys on its rows, the chat's newest messages, read.
  void partyScreenOpened() {
    partyChatKeys.reset();
    unawaited(hub.partyChat.show().catchError((Object _) {}));
  }

  /// A command on the party screen the chat takes: everything while the keys are in it, and →
  /// from a row that does not use it. False to leave it to the rows.
  bool partyChatCommand(Command command) {
    final keys = partyChatKeys;
    if (!partyChatShown) {
      keys.reset();
      return false;
    }
    if (!keys.focused) {
      if (command != Command.right) return false;
      final rows = app.panelCategories().firstOrNull?.rows ?? const <PanelRow>[];
      final row = app.panelRow < rows.length ? rows[app.panelRow] : null;
      if (row?.kind is ToggleRow || row?.kind is ChoiceRow || row?.kind is StepperRow) return false;
      enterPartyChat();
      return true;
    }
    if (keys.menu != null) {
      _menuCommand(command);
      return true;
    }
    final focused = focusedPartyMessage;
    if (focused != null) {
      _onMessage(command, focused);
      return true;
    }
    switch (command) {
      case Command.left:
        if (keys.place > 0) {
          keys.place--;
          app.sounds.play(Cue.move);
          app.refresh();
        } else {
          leavePartyChat();
        }
      case Command.right:
        if (keys.place < TogetherMessages.composer) {
          keys.place++;
          app.sounds.play(Cue.move);
          app.refresh();
        }
      case Command.up:
        // Up from the field: onto the newest message, then older ones.
        if (hub.partyChat.thread.isEmpty) {
          unawaited(hub.partyChat.older().catchError((Object _) {}));
        } else {
          keys.cursor = 0;
          app.sounds.play(Cue.move);
          app.refresh();
        }
      case Command.select:
        if (keys.place < TogetherMessages.composer) {
          unawaited(sendPartyMessage(TogetherMessages.quickReplies[keys.place]));
          return true;
        }
        final failed = hub.partyChat.thread.where((message) => message.failed).lastOrNull;
        if (failed != null && keys.draft.isEmpty && keys.editing == null) {
          unawaited(hub.partyChat.retry(failed));
        } else {
          app.startEditing(draftRow);
        }
      case Command.back:
        // A reply or an edit is dropped first.
        if (keys.replyingTo != null || keys.editing != null) {
          cancelPartyComposerNote();
          app.sounds.play(Cue.back);
        } else {
          leavePartyChat();
        }
      default:
        break;
    }
    return true;
  }

  void enterPartyChat() {
    partyChatKeys
      ..focused = true
      ..cursor = null
      ..place = TogetherMessages.composer;
    app.sounds.play(Cue.move);
    app.refresh();
  }

  void leavePartyChat() {
    partyChatKeys
      ..focused = false
      ..cursor = null
      ..menu = null;
    app.sounds.play(Cue.back);
    app.refresh();
  }

  void _onMessage(Command command, ChatMessage message) {
    final keys = partyChatKeys;
    final thread = hub.partyChat.thread;
    switch (command) {
      case Command.up:
        if (keys.cursor! < thread.length - 1) {
          keys.cursor = keys.cursor! + 1;
          app.sounds.play(Cue.move);
          app.refresh();
        } else {
          unawaited(hub.partyChat.older().catchError((Object _) {}));
        }
      case Command.down:
        keys.cursor = keys.cursor! == 0 ? null : keys.cursor! - 1;
        app.sounds.play(Cue.move);
        app.refresh();
      case Command.left:
        leavePartyChat();
      case Command.select || Command.options:
        if (message.failed) {
          unawaited(hub.partyChat.retry(message));
        } else {
          openPartyMessageMenu(message);
        }
      case Command.back:
        keys.cursor = null;
        app.sounds.play(Cue.back);
        app.refresh();
      default:
        break;
    }
  }

  /// The message the keys are on, if they are on one.
  ChatMessage? get focusedPartyMessage {
    final keys = partyChatKeys;
    final cursor = keys.cursor;
    final thread = hub.partyChat.thread;
    if (!keys.focused || cursor == null || thread.isEmpty) return null;
    return thread[thread.length - 1 - cursor.clamp(0, thread.length - 1)];
  }

  ChatMessage _current(ChatMessage message) =>
      hub.partyChat.thread.where((m) => m.id == message.id).firstOrNull ?? message;

  /// A message's menu (clicked, or Enter on it): nothing for one removed or on its way.
  void openPartyMessageMenu(ChatMessage message) {
    if (message.deleted || message.seq <= 0) return;
    final thread = hub.partyChat.thread;
    final at = thread.indexWhere((m) => m.id == message.id);
    if (at < 0) return;
    partyChatKeys
      ..focused = true
      ..cursor = thread.length - 1 - at
      ..menu = PartyChatMenu(message);
    app.sounds.play(Cue.select);
    app.refresh();
  }

  void closePartyMessageMenu() {
    partyChatKeys.menu = null;
    app.sounds.play(Cue.back);
    app.refresh();
  }

  /// The menu's rows: `react` (left and right through the seven), `reply`, `edit` and `unsend`
  /// for the user's own, `report` for someone else's; asked again before unsending
  /// (`unsend-confirm`, `cancel`); the reasons when reporting (`reason-spam` …, `cancel`).
  List<String> get partyMenuItems {
    final menu = partyChatKeys.menu;
    if (menu == null) return const [];
    if (menu.step == 'unsend') return const ['unsend-confirm', 'cancel'];
    if (menu.step == 'report') return [for (final reason in messageReportReasons) 'reason-$reason', 'cancel'];
    final message = _current(menu.message);
    final me = user?.id;
    return [
      'react',
      'reply',
      if (Messages.canEdit(message, me, DateTime.now())) 'edit',
      if (message.authorId == me) 'unsend' else 'report',
    ];
  }

  String partyMenuLabel(String item) => switch (item) {
    'react' => T.text('messagesReact'),
    'reply' => T.text('messagesReply'),
    'edit' => T.text('messagesEdit'),
    'unsend' || 'unsend-confirm' => T.text('messagesUnsend'),
    'report' => T.text('messagesReport'),
    'reason-spam' => T.text('reportReasonSpam'),
    'reason-harassment' => T.text('reportReasonHarassment'),
    'reason-hate' => T.text('reportReasonHate'),
    'reason-sexual' => T.text('reportReasonSexual'),
    'reason-other' => T.text('reportReasonOther'),
    _ => T.text('cancel'),
  };

  /// What the menu says over its rows: the message, the question, or who reads a report.
  (String, String?) get partyMenuHeading {
    final menu = partyChatKeys.menu;
    if (menu == null) return ('', null);
    return switch (menu.step) {
      'unsend' => (T.text('messagesUnsendConfirm'), null),
      'report' => (T.text('messagesReportTitle'), T.text('messagesReportDetail')),
      _ => (_current(menu.message).words ?? '', null),
    };
  }

  void _menuCommand(Command command) {
    final menu = partyChatKeys.menu!;
    final items = partyMenuItems;
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
        runPartyMenuItem(items[menu.row.clamp(0, items.length - 1)]);
      case Command.back || Command.options:
        closePartyMessageMenu();
      default:
        break;
    }
  }

  /// Does what a row of the open menu says.
  void runPartyMenuItem(String item) {
    final keys = partyChatKeys;
    final menu = keys.menu;
    if (menu == null) return;
    final message = _current(menu.message);
    switch (item) {
      case 'react':
        keys.menu = null;
        app.sounds.play(Cue.select);
        unawaited(togglePartyReaction(message, messageReactions[menu.reaction]));
      case 'reply':
        startPartyReply(message);
      case 'edit':
        startPartyEdit(message);
      case 'unsend' || 'report':
        menu
          ..step = item
          ..row = 0;
        app.sounds.play(Cue.select);
      case 'unsend-confirm':
        keys.menu = null;
        app.sounds.play(Cue.select);
        unawaited(unsendPartyMessage(message));
      case final String reason when reason.startsWith('reason-'):
        keys.menu = null;
        app.sounds.play(Cue.select);
        unawaited(reportPartyMessage(message, reason.substring('reason-'.length)));
      default:
        closePartyMessageMenu();
        return;
    }
    app.refresh();
  }

  void startPartyReply(ChatMessage message) {
    final keys = partyChatKeys;
    if (keys.editing != null) keys.draft = '';
    keys
      ..editing = null
      ..replyingTo = message.seq;
    _toField();
  }

  void startPartyEdit(ChatMessage message) {
    partyChatKeys
      ..replyingTo = null
      ..editing = message
      ..draft = message.words ?? '';
    _toField();
  }

  void _toField() {
    partyChatKeys
      ..menu = null
      ..cursor = null
      ..focused = true;
    app.sounds.play(Cue.select);
    app.startEditing(draftRow);
    app.refresh();
  }

  void cancelPartyComposerNote() {
    final keys = partyChatKeys;
    keys.replyingTo = null;
    if (keys.editing != null) {
      keys
        ..editing = null
        ..draft = '';
    }
    app.refresh();
  }

  /// The line above the field while it answers or edits: the title (Replying to Ana, Edit) and
  /// the words.
  (String, String)? get partyComposerNote {
    final keys = partyChatKeys;
    final editing = keys.editing;
    if (editing != null) return (T.text('messagesEdit'), editing.words ?? '');
    final seq = keys.replyingTo;
    if (seq == null) return null;
    final target = hub.partyChat.inThread(seq);
    return (T.format('messagesReplyingTo', [partyAuthorName(target?.authorId)]), _quoted(target));
  }

  /// The message [message] answers, as its quote shows it.
  (String, String)? partyQuoteOf(ChatMessage message) {
    final seq = message.replyTo;
    if (seq == null) return null;
    final target = hub.partyChat.inThread(seq);
    if (target == null) return ('', T.text('messagesEarlier'));
    return (partyAuthorName(target.authorId), _quoted(target));
  }

  static String _quoted(ChatMessage? target) => target == null
      ? T.text('messagesEarlier')
      : target.deleted
      ? T.text('messagesDeleted')
      : (target.words ?? '');

  /// Who wrote in the chat: a member (a friend by their friends-only name), someone seen in the
  /// party earlier, else a former member.
  String partyAuthorName(String? userId) {
    final person = hub.partyChat.author(userId);
    if (person == null) return userId == user?.id ? (user?.displayName ?? '') : T.text('partyChatFormer');
    return TogetherModel.shown(person).name;
  }

  /// The field as a text row: typing tells the others, Enter sends, or saves an edit.
  PanelRow get partyDraftField => PanelRow(
    id: draftRow,
    title: '',
    kind: TextRow(
      partyChatKeys.draft,
      (text) {
        partyChatKeys.draft = text;
        if (partyChatKeys.editing == null) hub.partyChat.typing();
      },
      submit: () {
        final keys = partyChatKeys;
        final text = keys.draft;
        keys.draft = '';
        final editing = keys.editing;
        if (editing != null) {
          keys.editing = null;
          unawaited(_finishEdit(editing, text));
        } else {
          unawaited(sendPartyMessage(text));
        }
        app.refresh();
      },
      hint: T.text('partyChatWrite'),
    ),
  );

  Future<void> sendPartyMessage(String text) async {
    if (text.trim().isEmpty) return;
    app.sounds.play(Cue.select);
    final reply = partyChatKeys.replyingTo;
    partyChatKeys.replyingTo = null;
    await hub.partyChat.send(text, replyTo: reply);
  }

  Future<void> _finishEdit(ChatMessage editing, String text) async {
    if (text.trim().isEmpty || text.trim() == (editing.words ?? '').trim()) return;
    try {
      await hub.partyChat.edit(editing, text);
    } on TogetherProblem catch (problem) {
      app.show(
        problem.code == 'edit_limit' || problem.code == 'forbidden' ? T.text('messagesEditLimit') : message(problem),
      );
    } on Object catch (error) {
      app.show(message(error));
    }
  }

  Future<void> togglePartyReaction(ChatMessage message, String name) async {
    try {
      await hub.partyChat.react(_current(message), name);
    } on Object catch (error) {
      app.show(this.message(error));
    }
  }

  Future<void> unsendPartyMessage(ChatMessage message) async {
    try {
      await hub.partyChat.unsend(message);
    } on Object catch (error) {
      app.show(this.message(error));
    }
  }

  Future<void> reportPartyMessage(ChatMessage message, String reason) async {
    try {
      await hub.partyChat.report(message, reason);
      app.show(T.text('messagesReported'));
    } on Object catch (error) {
      app.show(this.message(error));
    }
  }

  /// A message that did not get there: a blocked link, too many at once, a family rule, else
  /// not sent.
  void partySendFailed(Object error) {
    if (error is TogetherProblem && error.code == 'rate_limited') return app.show(T.text('togetherTooMany'));
    sendFailed(error);
  }
}
