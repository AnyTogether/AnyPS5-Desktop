import 'package:anyps5_desktop/core/together/account.dart';
import 'package:anyps5_desktop/core/together/join_advice.dart';
import 'package:anyps5_desktop/core/together/messages.dart';
import 'package:anyps5_desktop/core/together/parties.dart';
import 'package:anyps5_desktop/core/together/people.dart';
import 'package:anyps5_desktop/core/together/profiles.dart';
import 'package:anyps5_desktop/ui/app_model.dart' hide Command, GameState;
import 'package:anyps5_desktop/ui/app_model.dart' as launcher show Command;
import 'package:anyps5_desktop/ui/launcher.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:anyps5_desktop/ui/together_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/ui_support.dart';

/// AnyTogether's screens, rendered headless. (The network tests are in together_test.dart: a
/// file with widget tests gets Flutter's HTTP stand-in, which answers every request with 400.)
void main() {
  late Fixture fixture;
  late AppModel model;

  int category(String id) => model.panelCategories().indexWhere((category) => category.id == id);

  void openTogether() {
    model.open(Layer.settings);
    model.selectCategory(category('together'));
  }

  group('interface', () {
    tearDown(() {
      T.language = Language.english;
      fixture.dispose();
    });

    testWidgets('golden: the AnyTogether settings, signed out', (tester) async {
      fixture = makeFixture();
      model = fixture.model;
      openTogether();
      model.handle(launcher.Command.down);
      await pumpLauncher(tester, model);
      await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/together_signin.png'));
    });

    testWidgets('golden: the code step, in Turkish', (tester) async {
      fixture = makeFixture(language: Language.byCode('tr'));
      model = fixture.model;
      model.together.account.step = const SignInCodeSent('utku@example.com');
      openTogether();
      await pumpLauncher(tester, model);
      expect(find.text('Maildeki kod'), findsOneWidget);
      await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/together_code_tr.png'));
    });

    testWidgets('Enter puts the cursor in the email field, the keys type, Esc gives them back', (tester) async {
      fixture = makeFixture();
      model = fixture.model;
      openTogether();
      await pumpLauncher(tester, model);
      while (model.panelCategories()[model.panelCategory].rows[model.panelRow].id != 'together-email') {
        await press(tester, LogicalKeyboardKey.arrowDown);
      }
      await press(tester, LogicalKeyboardKey.enter);
      expect(model.editingRow, 'together-email');
      // The row's own field (Settings' search field is in the heading).
      await tester.enterText(
        find.descendant(of: find.byKey(const ValueKey('row-together-email')), matching: find.byType(TextField)),
        'utku@example.com',
      );
      await settle(tester);
      expect(model.together.email, 'utku@example.com');
      // Backspace and space are the field's while typing, not Back and Select.
      await press(tester, LogicalKeyboardKey.backspace);
      expect(model.overlay, Layer.settings);
      await press(tester, LogicalKeyboardKey.escape);
      expect(model.editingRow, isNull);
      expect(model.overlay, Layer.settings);
      await press(tester, LogicalKeyboardKey.escape);
      expect(model.overlay, isNull);
    });

    testWidgets('golden: friends, with a request, one playing, one online, one offline', (tester) async {
      fixture = makeFixture();
      model = fixture.model;
      signedInPreview(model);
      model.open(Layer.friends);
      await pumpLauncher(tester, model);
      expect(find.text('@bora · Playing Neon Alley · 25 min · joinable · in a party 2/8'), findsOneWidget);
      await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/together_friends.png'));
    });

    testWidgets('golden: friends idle and on Do not disturb, and me on Do not disturb', (tester) async {
      fixture = makeFixture();
      model = fixture.model;
      signedInPreview(model);
      final friends = model.together.hub.friends;
      friends.friends = [
        ...friends.friends,
        const Friend(
          Person(id: 'u-deniz', handle: 'deniz', displayName: 'Deniz'),
          Presence(state: PresenceState.online, status: PresenceStatus.idle),
        ),
        const Friend(
          Person(id: 'u-ece', handle: 'ece', displayName: 'Ece'),
          Presence(state: PresenceState.online, status: PresenceStatus.dnd),
        ),
      ];
      model.together.hub.self.status = PresenceStatus.dnd;
      model.open(Layer.friends);
      // Down to the friends: Ece on Do not disturb, Deniz idle, Ana online above them.
      await pumpLauncher(tester, model);
      final ece = model.panelCategories().single.rows.indexWhere((row) => row.id == 'friend-u-ece');
      expect(ece, greaterThan(0));
      while (model.panelRow < ece) {
        await press(tester, LogicalKeyboardKey.arrowDown);
      }
      await settle(tester);
      expect(find.text('@deniz · Idle'), findsOneWidget);
      expect(find.text('@ece · Do not disturb'), findsOneWidget);
      await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/together_friends_statuses.png'));
    });

    testWidgets('golden: home with my own status, Idle, in Turkish', (tester) async {
      fixture = makeFixture(language: Language.byCode('tr'));
      model = fixture.model;
      signedInPreview(model);
      model.together.hub.self.status = PresenceStatus.idle;
      await pumpLauncher(tester, model);
      expect(find.text('Boşta'), findsOneWidget);
      await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/together_home_idle_tr.png'));
    });

    testWidgets('golden: home with the friends button and its badge, in Turkish', (tester) async {
      fixture = makeFixture(language: Language.byCode('tr'));
      model = fixture.model;
      signedInPreview(model);
      model.handle(launcher.Command.up);
      model.handle(launcher.Command.right);
      await pumpLauncher(tester, model);
      await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/together_home_tr.png'));
    });

    testWidgets('golden: messages, a conversation open with a quick reply focused', (tester) async {
      fixture = makeFixture();
      model = fixture.model;
      signedInPreview(model);
      const ana = Person(id: 'u-ana', handle: 'ana', displayName: 'Ana');
      const me = Person(id: 'u-me', handle: 'utku', displayName: 'Utku Halis');
      ChatMessage message(int seq, String author, String text, {bool failed = false}) => ChatMessage(
        id: 'm$seq',
        conversationId: 'c-ana',
        seq: seq,
        authorId: author,
        text: text,
        createdAt: DateTime.utc(2026, 10, 24, 20, seq),
        failed: failed,
      );
      final thread = [
        message(1, 'u-ana', 'Hi! Are you playing Neon Alley tonight?'),
        message(2, 'u-me', 'Yes, after dinner'),
        message(3, 'u-ana', 'Great, I will start a party'),
        message(4, 'u-me', 'look at this blocked link', failed: true),
      ];
      model.together.hub.messages
        ..conversations = [
          Conversation(
            id: 'c-ana',
            group: false,
            title: null,
            members: const [me, ana],
            lastSeq: 4,
            readSeq: 4,
            lastMessage: thread[2],
            updatedAt: DateTime.utc(2026, 10, 24),
          ),
          Conversation(
            id: 'c-group',
            group: true,
            title: 'Friday night',
            members: const [
              me,
              ana,
              Person(id: 'u-cem', handle: 'cem', displayName: 'Cem Yılmaz'),
            ],
            lastSeq: 9,
            readSeq: 6,
            lastMessage: message(9, 'u-cem', 'Who brings snacks?'),
            updatedAt: DateTime.utc(2026, 10, 23),
          ),
        ]
        ..unread = 3
        ..loaded = true
        ..openId = 'c-ana'
        ..thread = thread;
      model.open(Layer.messages);
      model.together
        ..messagesInThread = true
        ..messageFocus = 1;
      await pumpLauncher(tester, model);
      expect(find.text('Who brings snacks?'), findsNothing);
      expect(find.text('Cem Yılmaz: Who brings snacks?'), findsOneWidget);
      await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/together_messages.png'));
    });

    testWidgets('golden: a new group, in Turkish, two friends picked and a name typed', (tester) async {
      fixture = makeFixture(language: Language.byCode('tr'));
      model = fixture.model;
      signedInPreview(model);
      model.together.hub.messages
        ..conversations = []
        ..loaded = true;
      model.open(Layer.messages);
      final together = model.together;
      final at = together.messageTargets.indexWhere((target) => target is NewGroupTarget);
      expect(at, 0, reason: 'no conversations yet: the new group comes first');
      together
        ..messagesIndex = at
        ..messagesInThread = true
        ..groupName = 'Cuma akşamı'
        ..groupFocus = 2;
      together.groupPicked.addAll({'u-bora', 'u-ana'});
      await pumpLauncher(tester, model);
      expect(find.text('Yeni grup'), findsWidgets);
      expect(find.text('2 kişi seçildi'), findsOneWidget);
      expect(find.text('Grubu kur'), findsOneWidget);
      await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/together_messages_new_group_tr.png'));

      // A click on a friend picks them.
      await tester.tap(find.text('Cem Yılmaz').last);
      await tester.pump();
      expect(together.groupPicked, {'u-bora', 'u-ana', 'u-cem'});
      await settle(tester);
    });

    testWidgets('a conversation clicked in the list opens, with the cursor in its field', (tester) async {
      fixture = makeFixture();
      model = fixture.model;
      signedInPreview(model);
      const ana = Person(id: 'u-ana', handle: 'ana', displayName: 'Ana');
      const me = Person(id: 'u-me', handle: 'utku', displayName: 'Utku Halis');
      ChatMessage message(String conversation, int seq, String author, String text) => ChatMessage(
        id: '$conversation-$seq',
        conversationId: conversation,
        seq: seq,
        authorId: author,
        text: text,
        createdAt: DateTime.utc(2026, 10, 24, 20, seq),
      );
      model.together.hub.messages
        ..conversations = [
          Conversation(
            id: 'c-ana',
            group: false,
            title: null,
            members: const [me, ana],
            lastSeq: 1,
            readSeq: 1,
            lastMessage: message('c-ana', 1, 'u-ana', 'Hi!'),
            updatedAt: DateTime.utc(2026, 10, 24),
          ),
          Conversation(
            id: 'c-group',
            group: true,
            title: 'Friday night',
            members: const [me, ana],
            lastSeq: 1,
            readSeq: 1,
            lastMessage: message('c-group', 1, 'u-ana', 'Who brings snacks?'),
            updatedAt: DateTime.utc(2026, 10, 23),
          ),
        ]
        ..loaded = true
        ..openId = 'c-ana'
        ..thread = [message('c-ana', 1, 'u-ana', 'Hi!')];
      model.open(Layer.messages);
      await pumpLauncher(tester, model);
      expect(model.together.messagesInThread, isFalse);

      await tester.tap(find.text('Friday night').first);
      await tester.pump();
      // The one clicked is the one shown (and the one a reply goes to), not the one before.
      expect(model.together.hub.messages.openId, 'c-group');
      expect(TogetherMessages.targetKey(model.together.selectedTarget!), 'c-group');
      expect(model.together.messagesInThread, isTrue);
      expect(model.together.messageFocus, TogetherMessages.composer);
      await settle(tester);
    });

    testWidgets('golden: messages with reactions, a reply, the receipt, pinned and muted; then a message\'s menu', (
      tester,
    ) async {
      fixture = makeFixture();
      model = fixture.model;
      signedInPreview(model);
      const ana = Person(id: 'u-ana', handle: 'ana', displayName: 'Ana');
      const me = Person(id: 'u-me', handle: 'utku', displayName: 'Utku Halis');
      ChatMessage message(
        int seq,
        String author,
        String? text, {
        int? replyTo,
        List<ReactionCount> reactions = const [],
        bool deleted = false,
      }) => ChatMessage(
        id: 'm$seq',
        conversationId: 'c-ana',
        seq: seq,
        authorId: author,
        text: text,
        createdAt: DateTime.now(),
        replyTo: replyTo,
        reactions: reactions,
        deleted: deleted,
      );
      final thread = [
        message(
          1,
          'u-ana',
          'Hi! Are you playing Neon Alley tonight?',
          reactions: const [
            ReactionCount(name: 'gg', count: 2, userIds: ['u-me', 'u-cem']),
          ],
        ),
        message(2, 'u-ana', null, deleted: true),
        message(3, 'u-me', 'Yes, after dinner', replyTo: 1),
        message(4, 'u-ana', 'Great, I will start a party', replyTo: 3),
        message(5, 'u-me', 'See you there'),
      ];
      model.together.hub.messages
        ..conversations = [
          Conversation(
            id: 'c-ana',
            group: false,
            title: null,
            members: const [me, ana],
            lastSeq: 5,
            readSeq: 5,
            lastMessage: thread.last,
            updatedAt: DateTime.utc(2026, 10, 24),
            pinned: true,
            receipts: const [Receipt(userId: 'u-ana', readSeq: 5, deliveredSeq: 5)],
          ),
          Conversation(
            id: 'c-group',
            group: true,
            title: 'Friday night',
            members: const [
              me,
              ana,
              Person(id: 'u-cem', handle: 'cem', displayName: 'Cem Yılmaz'),
            ],
            lastSeq: 9,
            readSeq: 6,
            unread: 3,
            muted: true,
            lastMessage: ChatMessage(
              id: 'g9',
              conversationId: 'c-group',
              seq: 9,
              authorId: 'u-cem',
              text: 'Who brings snacks?',
              createdAt: DateTime.utc(2026, 10, 23),
            ),
            updatedAt: DateTime.utc(2026, 10, 23),
          ),
        ]
        ..loaded = true
        ..openId = 'c-ana'
        ..thread = thread;
      model.open(Layer.messages);
      model.together
        ..messagesInThread = true
        ..messageFocus = 5
        ..replyingTo = 4;
      await pumpLauncher(tester, model);
      expect(find.text('Read'), findsOneWidget);
      expect(find.text('Replying to Ana'), findsOneWidget);
      expect(find.text('Message removed'), findsOneWidget);
      await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/together_messages_actions.png'));

      model.together.replyingTo = null;
      model.together.focusMessage(thread[2]);
      model.handle(launcher.Command.select);
      model.handle(launcher.Command.right);
      await tester.pumpAndSettle();
      expect(find.text('Delete for everyone'), findsOneWidget);
      expect(find.text('Love'), findsOneWidget);
      await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/together_messages_menu.png'));
    });

    testWidgets('golden: a party, in Turkish, led by Utku with Ana muted in voice, a join code and a request', (
      tester,
    ) async {
      fixture = makeFixture(language: Language.byCode('tr'));
      model = fixture.model;
      signedInPreview(model);
      model.together.hub.parties.party = Party(
        id: 'p1',
        leaderId: 'u-me',
        open: true,
        members: [
          const Person(id: 'u-me', handle: 'utku', displayName: 'Utku Halis'),
          const Person(id: 'u-ana', handle: 'ana', displayName: 'Ana'),
        ],
        invited: [const Person(id: 'u-bora', handle: 'bora', displayName: 'Bora')],
        callId: 'call-1',
        inCall: {'u-ana'},
        muted: {'u-ana'},
        joinCode: JoinCode(
          code: 'K7QM3XPA',
          url: Uri(scheme: 'https', host: 'anytogether.net', path: '/join/K7QM3XPA'),
        ),
        discord: 'https://discord.gg/anyps5',
        requests: [const Person(id: 'u-cem', handle: 'cem', displayName: 'Cem')],
      );
      model.together.hub.parties.requestVia['u-cem'] = 'code';
      model.open(Layer.party);
      await pumpLauncher(tester, model);
      await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/together_party_tr.png'));
      // Further down: the join code and the Discord link.
      model.panelRow = model.panelCategories().single.rows.indexWhere((row) => row.id == 'party-code-new');
      model.refresh();
      await tester.pumpAndSettle();
      await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/together_party_code_tr.png'));
    });

    testWidgets('golden: a join held back by another engine build, both builds whole and what to do', (tester) async {
      fixture = makeFixture();
      model = fixture.model;
      signedInPreview(model);
      model.together.tell(
        const JoinBlock.engine(
          advice: EngineAdvice.updateHost,
          hostName: 'Ana',
          gameName: 'Greenhollow',
          host: '0.2.36-arm-nightly.20261110.1-a6fff1ba742d',
          yours: '0.2.36-arm-f75c475400e3',
        ),
      );
      await pumpLauncher(tester, model);
      expect(find.text('Different engine build'), findsOneWidget);
      expect(find.text('0.2.36-arm-nightly.20261110.1-a6fff1ba742d'), findsOneWidget, reason: 'whole');
      expect(find.text('0.2.36-arm-f75c475400e3'), findsOneWidget);
      expect(find.text('Check for updates'), findsNothing, reason: 'this launcher is the newer one');
      await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/together_join_blocked_en.png'));
    });

    testWidgets('golden: a stale copy offers Rebuild and join, in Turkish', (tester) async {
      fixture = makeFixture(language: Language.byCode('tr'));
      model = fixture.model;
      signedInPreview(model);
      model.together.tell(
        JoinBlock.engine(
          advice: EngineAdvice.rebuild,
          hostName: 'Ana',
          gameName: 'Greenhollow',
          host: '0.2.36-arm-f75c475400e3',
          yours: '0.2.36-arm-nightly.20261110.1-a6fff1ba742d',
          rebuild: () {},
        ),
      );
      await pumpLauncher(tester, model);
      expect(find.text('Yeniden hazırla ve katıl'), findsOneWidget);
      await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/together_join_blocked_rebuild_tr.png'));
    });

    testWidgets('golden: Play on a game a friend hosts asks to join theirs or start your own, in Turkish', (
      tester,
    ) async {
      fixture = makeFixture(language: Language.byCode('tr'));
      model = fixture.model;
      signedInPreview(model);
      final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
      model.together.joinChoice = JoinChoice(
        game: orbit,
        other: const JoinableGame(sessionId: 's1', titleId: 'PPSA01001', personId: 'u-ana', together: false),
        name: 'Ana',
      );
      model.open(Layer.joinOrHost);
      await pumpLauncher(tester, model);
      expect(find.text('Kendi oyunumu başlat'), findsOneWidget);
      expect(model.panelRow, 1, reason: 'Join is the default');
      await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/together_join_or_host_tr.png'));
    });

    /// A party of Utku (leading, in voice), Ana (talking) and Cem, with its chat.
    void partyWithChat(List<ChatMessage> messages) {
      model.together.hub.parties
        ..party = const Party(
          id: 'p1',
          leaderId: 'u-me',
          open: false,
          members: [
            Person(id: 'u-me', handle: 'utku', displayName: 'Utku Halis'),
            Person(id: 'u-ana', handle: 'ana', displayName: 'Ana'),
            Person(id: 'u-cem', handle: 'cem', displayName: 'Cem Yılmaz'),
          ],
          invited: [],
          callId: 'call-1',
          inCall: {'u-me', 'u-ana'},
          conversationId: 'chat-1',
        )
        ..notifyListeners();
      model.together.hub.partyChat
        ..thread = messages
        ..loaded = true;
    }

    ChatMessage said(int seq, String author, String text, {int? replyTo, List<ReactionCount> reactions = const []}) =>
        ChatMessage(
          id: 'pm$seq',
          conversationId: 'chat-1',
          seq: seq,
          authorId: author,
          text: text,
          createdAt: DateTime.now().subtract(Duration(minutes: 10 - seq)),
          replyTo: replyTo,
          reactions: reactions,
        );

    testWidgets('golden: a party with its chat beside the rows, the keys on a message', (tester) async {
      fixture = makeFixture();
      model = fixture.model;
      signedInPreview(model);
      partyWithChat([
        said(1, 'u-dan', 'Good luck tonight, I have to go'),
        said(2, 'u-ana', 'Boss at the bridge, who has potions?'),
        said(3, 'u-me', 'I have three', replyTo: 2),
        said(
          4,
          'u-cem',
          'Ready when you are',
          reactions: const [
            ReactionCount(name: 'gg', count: 2, userIds: ['u-me', 'u-ana']),
          ],
        ),
      ]);
      model.open(Layer.party);
      model.together.partyChatKeys
        ..focused = true
        ..cursor = 0;
      await pumpLauncher(tester, model);
      expect(find.text('Former member'), findsOneWidget);
      expect(find.text('Chat'), findsOneWidget);
      await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/together_party_chat_en.png'));
    });

    testWidgets('the Party tile has a dot for what others wrote, gone while the party screen is open', (tester) async {
      fixture = makeFixture();
      model = fixture.model;
      signedInPreview(model);
      partyWithChat(const []);
      model.together.hub.partyChat.unread = 2;
      await pumpLauncher(tester, model);
      expect(find.byKey(const ValueKey('home-dot-4')), findsOneWidget);
      model.open(Layer.party);
      await tester.pump();
      expect(model.together.partyChatUnread, 0);
    });

    testWidgets('golden: the chat empty, in Turkish, in a narrower window', (tester) async {
      fixture = makeFixture(language: Language.byCode('tr'));
      model = fixture.model;
      signedInPreview(model);
      partyWithChat(const []);
      model.open(Layer.party);
      await pumpLauncher(tester, model, size: const Size(1280, 900));
      expect(find.text('Bunu yalnız parti okur. Katılan herkes o ana kadarki mesajları görür.'), findsOneWidget);
      await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/together_party_chat_empty_tr.png'));
    });

    testWidgets('golden: reporting a message in the chat, in Turkish', (tester) async {
      fixture = makeFixture(language: Language.byCode('tr'));
      model = fixture.model;
      signedInPreview(model);
      final rude = said(2, 'u-cem', 'Hepiniz çok kötü oynuyorsunuz');
      partyWithChat([said(1, 'u-ana', 'Hazır mısınız?'), rude]);
      model.open(Layer.party);
      model.together.openPartyMessageMenu(rude);
      model.together.runPartyMenuItem('report');
      model.together.partyChatKeys.menu!.row = 1;
      await pumpLauncher(tester, model);
      expect(find.text('Bu mesajı bildir'), findsOneWidget);
      await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/together_party_chat_report_tr.png'));
    });

    testWidgets("golden: a friend's profile with games, play time and rare trophies", (tester) async {
      fixture = makeFixture();
      model = fixture.model;
      signedInPreview(model);
      model.open(Layer.friends);
      model.open(Layer.profile);
      model.together
        ..profileReturn = (layer: Layer.friends, category: null, row: null)
        // Compare trophies first, then the games: the second game.
        ..profileIndex = 2
        ..profile = ProfilePage(
          profile: const TogetherProfile(
            userId: 'u-bora',
            handle: 'bora',
            displayName: 'Bora',
            bio: 'Co-op nights, mostly. Say hi before you join.',
            country: 'TR',
            friendship: 'friends',
          ),
          library: SectionShown([
            PlayedGame(
              titleId: 'PPSA02002',
              names: const {'en': 'Neon Alley'},
              lastPlayedAt: DateTime(2026, 10, 24, 21),
              secondsPlayed: 152 * 60 + 3600 * 40,
              trophiesEarned: 18,
              trophiesTotal: 42,
              progress: 43,
              points: 690,
            ),
            PlayedGame(
              titleId: 'PPSA01001',
              names: const {'en': 'Orbit Runner'},
              lastPlayedAt: DateTime(2026, 10, 2),
              secondsPlayed: 3 * 3600,
              trophiesEarned: 5,
              trophiesTotal: 5,
              progress: 100,
              points: 435,
            ),
            const PlayedGame(titleId: 'PPSA07007', names: {'en': 'Harbor Lights'}, secondsPlayed: 25 * 60),
          ]),
          trophies: SectionShown([
            EarnedTrophy(
              titleId: 'PPSA01001',
              gameNames: const {'en': 'Orbit Runner'},
              trophyId: 0,
              grade: 'platinum',
              hidden: false,
              names: const {'en': 'Grand Tour'},
              earnedAt: DateTime(2026, 10, 2),
              rarity: 0.031,
              rarityLabel: 'ultra_rare',
            ),
            EarnedTrophy(
              titleId: 'PPSA02002',
              gameNames: const {'en': 'Neon Alley'},
              trophyId: 7,
              grade: 'silver',
              hidden: true,
              names: const {},
              earnedAt: DateTime(2026, 10, 24),
              rarity: 0.42,
              rarityLabel: 'common',
            ),
          ]),
        );
      await pumpLauncher(tester, model);
      expect(find.text('2 h 32 min'), findsNothing);
      expect(find.text('42 h 32 min · last played 2026-10-24'), findsOneWidget);
      await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/together_profile.png'));
    });
  });
}

/// Signed in as Utku with three friends and a request, without a server: for the screens.
void signedInPreview(AppModel model) {
  final together = model.together;
  together.account.user = const TogetherUser(id: 'u-me', handle: 'utku', displayName: 'Utku Halis');
  const cem = Person(id: 'u-cem', handle: 'cem', displayName: 'Cem Yılmaz');
  together.hub.friends
    ..incoming = [const Person(id: 'u-eda', handle: 'eda', displayName: 'Eda')]
    ..friends = [
      Friend(
        const Person(id: 'u-bora', handle: 'bora', displayName: 'Bora'),
        Presence(
          state: PresenceState.inGame,
          titleId: 'PPSA02002',
          since: DateTime.now().subtract(const Duration(minutes: 25, seconds: 20)),
          party: const PresenceParty(id: 'p1', size: 2, max: 8, open: true),
          game: const PresenceGame(sessionId: 's1', titleId: 'PPSA02002', joinable: true, players: 1, capacity: 4),
        ),
      ),
      const Friend(Person(id: 'u-ana', handle: 'ana', displayName: 'Ana'), Presence(state: PresenceState.online)),
      const Friend(cem, Presence()),
    ]
    ..loaded = true;
}
