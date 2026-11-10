import 'dart:io';

import 'package:anyps5_desktop/core/together/account.dart';
import 'package:anyps5_desktop/core/together/compat.dart';
import 'package:anyps5_desktop/core/together/levels.dart';
import 'package:anyps5_desktop/core/together/profiles.dart';
import 'package:anyps5_desktop/core/together/social.dart';
import 'package:anyps5_desktop/ui/app_model.dart' hide GameState;
import 'package:anyps5_desktop/ui/feed_view.dart';
import 'package:anyps5_desktop/ui/home.dart';
import 'package:anyps5_desktop/ui/launcher.dart';
import 'package:anyps5_desktop/ui/leaderboard_view.dart';
import 'package:anyps5_desktop/ui/panels.dart' show PersonAvatar;
import 'package:anyps5_desktop/ui/profile_view.dart' show ProfileView;
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:anyps5_desktop/ui/together_model.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_together.dart';
import '../support/ui_support.dart';

/// AnyTogether's social screens as the macOS launcher has them: friends' activity with its
/// reactions, the leaderboards, the notifications behind the bell, and "How did it run?". The
/// goldens are rendered headless, each in one language.
void main() {
  late Fixture fixture;
  late AppModel model;

  tearDown(() {
    T.language = Language.english;
    fixture.dispose();
  });

  void signedIn() {
    model.together.account.user = const TogetherUser(id: 'u-me', handle: 'utku', displayName: 'Utku Halis');
    model.together.hub.self
      ..level = TrophyLevel.fromJson({
        'level': 12,
        'tier': 'bronze',
        'frame': 1,
        'points': 700,
        'levelPoints': 660,
        'nextLevelPoints': 720,
        'progress': 66,
      })
      ..loaded = true;
  }

  Map<String, dynamic> card(String id, String name) => {
    'userId': id,
    'handle': name.toLowerCase().split(' ').first,
    'displayName': name,
    'avatar': null,
  };

  String ago(Duration time) => DateTime.now().subtract(time).toUtc().toIso8601String();

  List<Activity> feed() => [
    Activity.fromJson({
      'id': '05',
      'kind': 'platinum',
      'createdAt': ago(const Duration(minutes: 25)),
      'actor': card('u-bora', 'Bora'),
      'game': {
        'titleId': 'PPSA01001',
        'names': {'en': 'Orbit Runner'},
      },
      'highlight': 'platinum',
      'trophies': [
        {
          'trophyId': 0,
          'grade': 'platinum',
          'texts': {
            'en': {'name': 'Grand Tour'},
            'tr': {'name': 'Büyük Tur'},
          },
          'rarity': 0.03,
          'rarityLabel': 'ultra_rare',
        },
      ],
      'reactions': {
        'counts': {'fire': 4, 'clap': 2},
        'mine': 'fire',
      },
    })!,
    Activity.fromJson({
      'id': '04',
      'kind': 'trophy',
      'createdAt': ago(const Duration(hours: 3)),
      'actor': card('u-ana', 'Ana'),
      'game': {
        'titleId': 'PPSA02002',
        'names': {'en': 'Neon Alley'},
      },
      'highlight': 'rare',
      'trophies': [
        {
          'trophyId': 7,
          'grade': 'gold',
          'texts': {
            'en': {'name': 'Night Owl'},
            'tr': {'name': 'Gece Kuşu'},
          },
          'rarity': 0.12,
          'rarityLabel': 'very_rare',
        },
        {
          'trophyId': 3,
          'grade': 'bronze',
          'texts': {
            'en': {'name': 'First Lap'},
            'tr': {'name': 'İlk Tur'},
          },
          'rarity': 0.6,
        },
      ],
      'trophyCount': 5,
      'reactions': {
        'counts': {'heart': 1},
        'mine': null,
      },
    })!,
    Activity.fromJson({
      'id': '03',
      'kind': 'long_session',
      'createdAt': ago(const Duration(days: 1, hours: 2)),
      'actor': card('u-cem', 'Cem Yılmaz'),
      'game': {
        'titleId': 'PPSA03003',
        'names': {'en': 'Quiet Forest'},
      },
      'seconds': 3 * 3600 + 20 * 60,
      'reactions': {'counts': <String, int>{}, 'mine': null},
    })!,
    Activity.fromJson({
      'id': '02',
      'kind': 'milestone',
      'createdAt': ago(const Duration(days: 3)),
      'actor': card('u-ana', 'Ana'),
      'milestone': {'kind': 'trophies', 'value': 250},
      'reactions': {
        'counts': {'wow': 3},
        'mine': 'wow',
      },
    })!,
  ];

  Leaderboard board() {
    Map<String, dynamic> entry(int rank, String id, String name, int value, [int? level]) => {
      'rank': rank,
      'user': card(id, name),
      'value': value,
      'level': ?(level == null ? null : {'level': level}),
    };
    return Leaderboard.fromJson({
      'board': 'points',
      'scope': 'global',
      'game': {
        'titleId': 'PPSA02002',
        'names': {'en': 'Neon Alley'},
      },
      'entries': [
        entry(1, 'u-ana', 'Ana', 4210, 640),
        entry(2, 'u-bora', 'Bora', 3990, 142),
        entry(3, 'u-deniz', 'Deniz', 3105),
        entry(4, 'u-eren', 'Eren', 2870, 88),
      ],
      'me': {'rank': 18, 'value': 1830, 'listed': true},
      'around': [
        entry(17, 'u-fatma', 'Fatma', 1880),
        entry(18, 'u-me', 'Utku Halis', 1830, 12),
        entry(19, 'u-gul', 'Gül', 1795),
      ],
      'total': 240,
    });
  }

  Map<String, dynamic> notice(String id, String kind, Duration time, {bool read = false, Map<String, dynamic>? data}) =>
      {
        'id': id,
        'kind': kind,
        'actor': switch (kind) {
          'warning' => null,
          'level_up' => card('u-me', 'Utku Halis'),
          _ => card('u-bora', 'Bora'),
        },
        'data': data ?? <String, dynamic>{},
        'read': read,
        'createdAt': ago(time),
        'updatedAt': ago(time),
      };

  List<Notice> notices() => [
    Notice.fromJson(
      notice('05', 'message', const Duration(minutes: 4), data: {'count': 3, 'text': 'Neon Alley tonight at nine?'}),
    )!,
    Notice.fromJson(notice('04', 'friend_request', const Duration(minutes: 40)))!,
    Notice.fromJson(notice('03', 'game_invite', const Duration(hours: 2), data: {'titleId': 'PPSA02002'}))!,
    Notice.fromJson(
      notice('02', 'level_up', const Duration(days: 1), read: true, data: {'level': 12, 'tier': 'bronze', 'frame': 1}),
    )!,
    Notice.fromJson(notice('01', 'party_invite', const Duration(days: 2), read: true))!,
  ];

  group('goldens', () {
    testWidgets('golden: the activity feed, a reaction chosen on the second item (en)', (tester) async {
      fixture = makeFixture();
      model = fixture.model;
      signedIn();
      model.together.hub.social.feed.load(feed(), 'older');
      model.open(Layer.feed);
      model.together.screens
        ..feedIndex = 1
        ..feedReaction = Reaction.clap.index;
      await pumpLauncher(tester, model);
      expect(find.textContaining(T.format('socialFeedTrophies', ['Neon Alley', 5])), findsOneWidget);
      expect(find.text(T.format('socialFeedAndMore', [3])), findsOneWidget);
      expect(find.text(T.format('socialAgoMinutes', [25])), findsOneWidget);
      await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/social_feed_en.png'));
    });

    testWidgets('golden: a friend\'s profile with their recent activity, one item focused (en)', (tester) async {
      fixture = makeFixture();
      model = fixture.model;
      signedIn();
      final mine = [
        for (final item in feed())
          if (item.actor.id == 'u-ana') item,
      ];
      model.open(Layer.profile);
      model.together
        ..profileIndex = 2
        ..profile = ProfilePage(
          profile: const TogetherProfile(userId: 'u-ana', handle: 'ana', displayName: 'Ana', friendship: 'friends'),
          library: const SectionShown([]),
          trophies: const SectionShown([]),
          activity: SectionShown(mine),
        );
      await pumpLauncher(tester, model);
      expect(find.text(T.text('profileRecentActivity')), findsOneWidget);
      expect(find.byType(ProfileActivityRow), findsNWidgets(2));
      await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/social_profile_activity_en.png'));
    });

    test('a profile takes an activity item the gateway updates; the keys reach its items', () {
      fixture = makeFixture();
      model = fixture.model;
      signedIn();
      final items = feed();
      model.together.profile = ProfilePage(
        profile: const TogetherProfile(userId: 'u-ana', handle: 'ana', displayName: 'Ana', friendship: 'friends'),
        library: const SectionShown([]),
        trophies: const SectionShown([]),
        activity: SectionShown([items[1]]),
      );
      expect(model.together.profileItems, 2);
      final changed = Activity.fromJson({
        'id': '04',
        'kind': 'trophy',
        'createdAt': items[1].createdAt.toIso8601String(),
        'actor': card('u-ana', 'Ana'),
        'reactions': {
          'counts': {'heart': 6},
          'mine': null,
        },
      })!;
      model.together.profileActivityChanged(changed);
      expect(model.together.profile!.activity.value!.single.reactions.count(Reaction.heart), 6);
      // An item the profile does not hold leaves it as it is.
      final before = model.together.profile;
      model.together.profileActivityChanged(items[0]);
      expect(identical(model.together.profile, before), isTrue);
    });

    test('one player reads in the singular, and the count stays plural from two up', () {
      fixture = makeFixture();
      model = fixture.model;
      expect(T.format('socialBoardPlayers', [2]), '2 players');
      expect(T.format('socialBoardPlayersOne', [1]), '1 player');
      expect(T.format('discoverPlayersOne', [1]), '1 player on AnyTogether');
      expect(T.format('gamePlayersOne', [1, 1]), '1 of 1 player');
    });

    testWidgets('a board of one player says one player, not one players', (tester) async {
      fixture = makeFixture();
      model = fixture.model;
      signedIn();
      final neon = model.games.firstWhere((game) => game.titleId == 'PPSA02002');
      model.together.screens
        ..boardTitleId = neon.titleId
        ..boardName = neon.name
        ..boardScope = BoardScope.global
        ..board = Leaderboard.fromJson({
          'board': 'points',
          'scope': 'global',
          'total': 1,
          'game': {
            'titleId': 'PPSA02002',
            'names': {'en': 'Neon Alley'},
          },
          'entries': [
            {'rank': 1, 'user': card('u-ana', 'Ana'), 'value': 4210},
          ],
          'me': {'rank': null, 'value': 0, 'listed': false},
          'around': <Object>[],
        })
        ..boardIndex = 0;
      model.open(Layer.leaderboard);
      await pumpLauncher(tester, model);
      expect(find.text('1 player'), findsOneWidget);
      expect(find.text('1 players'), findsNothing);
    });

    testWidgets('a leaderboard is read by its tabs and its rows', (tester) async {
      final semantics = tester.ensureSemantics();
      fixture = makeFixture();
      model = fixture.model;
      signedIn();
      final neon = model.games.firstWhere((game) => game.titleId == 'PPSA02002');
      model.together.screens
        ..boardTitleId = neon.titleId
        ..boardName = neon.name
        ..boardScope = BoardScope.global
        ..board = board()
        ..boardIndex = 0;
      model.open(Layer.leaderboard);
      await pumpLauncher(tester, model);
      expect(find.bySemanticsLabel(RegExp('^1, Ana, ')), findsOneWidget);
      expect(find.bySemanticsLabel(T.text('socialScopeFriends')), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('golden: a game\'s leaderboard with the gap and the user\'s place (tr)', (tester) async {
      fixture = makeFixture(language: Language.byCode('tr'));
      model = fixture.model;
      signedIn();
      final neon = model.games.firstWhere((game) => game.titleId == 'PPSA02002');
      model.together.screens
        ..boardTitleId = neon.titleId
        ..boardName = neon.name
        ..boardScope = BoardScope.global
        ..board = board()
        ..boardIndex = 6;
      model.open(Layer.leaderboard);
      await pumpLauncher(tester, model);
      expect(find.text('#18'), findsOneWidget);
      expect(find.text(T.format('socialBoardOf', [240])), findsOneWidget);
      expect(find.text(T.format('socialBoardPlayers', [240])), findsOneWidget);
      expect(
        find.descendant(of: find.byType(LeaderboardView), matching: find.byIcon(Icons.more_horiz_rounded)),
        findsOneWidget,
        reason: 'the places between the top and the user',
      );
      await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/social_leaderboard_tr.png'));
    });

    testWidgets('golden: the notifications behind the bell (en)', (tester) async {
      fixture = makeFixture();
      model = fixture.model;
      signedIn();
      model.together.hub.social.notices.load(notices(), unread: 3, more: true);
      model.open(Layer.notifications);
      model.panelRow = 1;
      await pumpLauncher(tester, model);
      expect(find.text(T.format('socialNotifMessages', ['Bora', 3])), findsOneWidget);
      expect(find.text(T.format('socialNotifUnread', [3])), findsOneWidget);
      await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/social_notifications_en.png'));
    });

    testWidgets('golden: How did it run? after a game (tr)', (tester) async {
      fixture = makeFixture(language: Language.byCode('tr'));
      model = fixture.model;
      signedIn();
      model.together.screens.compatGame = model.games.firstWhere((game) => game.titleId == 'PPSA02002');
      model.open(Layer.compat);
      model.panelRow = 1;
      await pumpLauncher(tester, model);
      expect(find.text(T.format('socialCompatAsk', ['Neon Alley'])), findsOneWidget);
      await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/social_compat_tr.png'));
    });
  });

  group('behaviour', () {
    test('the feed: up and down move, left and right pick a reaction, △ opens the profile, back returns', () async {
      fixture = makeFixture();
      model = fixture.model;
      signedIn();
      model.open(Layer.friends);
      final together = model.together;
      together.hub.social.feed.load(feed(), null);
      together.screens.feedReturn = (layer: Layer.friends, category: null, row: null);
      model.overlay = Layer.feed;
      model.handle(Command.down);
      expect(together.screens.feedIndex, 1);
      model.handle(Command.right);
      model.handle(Command.right);
      expect(together.screens.feedReaction, 2);
      model.handle(Command.up);
      expect(together.screens.feedIndex, 0);
      expect(together.screens.feedReaction, Reaction.fire.index, reason: 'the item\'s own reaction');
      model.handle(Command.back);
      expect(model.overlay, Layer.friends);
    });

    test('a game in a profile\'s recent activity: select opens its hub, back returns to the profile', () {
      fixture = makeFixture();
      model = fixture.model;
      signedIn();
      final items = feed();
      final together = model.together;
      model.open(Layer.profile);
      together.profile = ProfilePage(
        profile: const TogetherProfile(userId: 'u-ana', handle: 'ana', displayName: 'Ana', friendship: 'friends'),
        library: const SectionShown([]),
        trophies: const SectionShown([]),
        activity: SectionShown([items[1], items[3]]),
      );
      final first = together.profileGamesFrom;
      // A milestone has no game: select stays on the profile.
      together.profileIndex = first + 1;
      model.handle(Command.select);
      expect(model.overlay, Layer.profile);
      together.profileIndex = first;
      model.handle(Command.select);
      expect(model.overlay, Layer.gameHub);
      expect(together.findState.hubTitle, 'PPSA02002');
      expect(together.findState.hubName, 'Neon Alley');
      model.handle(Command.back);
      expect(model.overlay, Layer.profile);
      expect(together.profile?.profile.handle, 'ana');
    });

    testWidgets('the feed\'s pictures, rarities and hidden trophies, and reactions where someone chose them', (
      tester,
    ) async {
      fixture = makeFixture();
      model = fixture.model;
      signedIn();
      ProfileView.pictureFor = (_) => MemoryImage(png(4, 4, (x, y) => 0xE8505BFF));
      addTearDown(() => ProfileView.pictureFor = NetworkImage.new);
      Map<String, dynamic> item(String id, String kind, Map<String, Object?> extra) => {
        'id': id,
        'kind': kind,
        'createdAt': ago(const Duration(hours: 1)),
        'actor': card('u-ana', 'Ana'),
        'reactions': {'counts': <String, int>{}, 'mine': null},
        ...extra,
      };
      model.together.hub.social.feed.load([
        ...feed(),
        Activity.fromJson(item('a4', 'friendship', {'friend': card('u-cem', 'Cem Yılmaz')}))!,
        Activity.fromJson(
          item('a3', 'milestone', {
            'milestone': {'kind': 'hours', 'value': 500},
          }),
        )!,
        Activity.fromJson(
          item('a2', 'trophy', {
            'game': {
              'titleId': 'ZZZZ00001',
              'names': {'en': 'Far Away'},
              'iconUrl': 'https://together.test/far-away.png',
            },
          }),
        )!,
        Activity.fromJson(
          item('a1', 'trophy', {
            'game': {
              'titleId': 'PPSA02002',
              'names': {'en': 'Neon Alley'},
            },
            'trophies': [
              {'trophyId': 9, 'grade': 'gold', 'hidden': true, 'rarity': 0.043, 'rarityLabel': 'very_rare'},
            ],
          }),
        )!,
      ], null);
      model.open(Layer.feed);
      await pumpLauncher(tester, model);
      Finder inItem(String id, Finder inside) =>
          find.descendant(of: find.byKey(ValueKey('activity-$id')), matching: inside);
      // The first item has the focus: all four, whether or not anyone chose them.
      expect(inItem('a4', find.text(Reaction.fire.emoji)), findsOneWidget);
      expect(inItem('a4', find.text(Reaction.heart.emoji)), findsOneWidget);
      // Elsewhere only those someone chose.
      expect(inItem('04', find.text(Reaction.heart.emoji)), findsOneWidget);
      expect(inItem('04', find.text(Reaction.fire.emoji)), findsNothing);
      // The new friend's picture, the milestone's sign, the game's picture from the server.
      expect(
        find.descendant(of: find.byKey(const ValueKey('activity-a4')), matching: find.byType(PersonAvatar)),
        findsNWidgets(2),
        reason: 'the one who did it, and the new friend',
      );
      expect(inItem('a3', find.byIcon(Icons.schedule_rounded)), findsOneWidget);
      expect(inItem('a2', find.byType(Image)), findsWidgets);
      // A hidden trophy is labelled, with its rarity.
      expect(inItem('a1', find.text(T.text('trophyHidden'))), findsOneWidget);
      expect(inItem('a1', find.text(T.percent(T.decimal(4.3, 1)))), findsOneWidget);
    });

    test('a new item coming in above leaves the focus on the item it is on', () {
      fixture = makeFixture();
      model = fixture.model;
      final together = model.together;
      final social = together.hub.social;
      social.feed.load(feed(), null);
      together.screens.feedIndex = 1;
      final on = social.feed.items[1].id;
      Activity newer(String id) => Activity.fromJson({
        'id': id,
        'kind': 'platinum',
        'createdAt': ago(const Duration(seconds: 5)),
        'actor': card('u-bora', 'Bora'),
      })!;
      together.keepFeedFocus(() => social.feed.upsert(newer('09')));
      expect(together.screens.feedIndex, 2, reason: 'one more above');
      expect(social.feed.items[together.screens.feedIndex].id, on);
      // An item that lands below moves nothing.
      together.keepFeedFocus(() => social.feed.upsert(newer('00')));
      expect(social.feed.items[together.screens.feedIndex].id, on);
      // Nothing focused yet: nothing to hold.
      social.feed.load(const [], null);
      together.screens.feedIndex = 0;
      together.keepFeedFocus(() => social.feed.upsert(newer('10')));
      expect(together.screens.feedIndex, 0);
    });

    testWidgets('a game\'s trophies reach its leaderboard: Enter without a picture, and the chip', (tester) async {
      fixture = makeFixture();
      model = fixture.model;
      signedIn();
      final orbit = model.games.indexWhere((game) => game.titleId == 'PPSA01001');
      model.select(orbit);
      model.open(Layer.trophies);
      await pumpLauncher(tester, model);
      expect(find.byKey(const ValueKey('trophy-leaderboard')), findsOneWidget);
      model.handle(Command.select);
      expect(model.overlay, Layer.leaderboard);
      expect(model.together.screens.boardTitleId, 'PPSA01001');
      await tester.pump(const Duration(milliseconds: 400));
      model.handle(Command.back);
      expect(model.overlay, Layer.trophies);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('trophy-leaderboard')));
      await tester.pump();
      expect(model.overlay, Layer.leaderboard);
      await tester.pump(const Duration(milliseconds: 400));
      model.handle(Command.back);

      // Signed out: neither the chip nor Enter goes there.
      model.together.account.user = null;
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('trophy-leaderboard')), findsNothing);
      model.handle(Command.select);
      expect(model.overlay, Layer.trophies);
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('a game\'s name in the feed opens its hub when clicked', (tester) async {
      fixture = makeFixture();
      model = fixture.model;
      signedIn();
      model.together.hub.social.feed.load(feed(), null);
      model.open(Layer.feed);
      await pumpLauncher(tester, model);
      final line = tester.widget<RichText>(
        find.descendant(
          of: find.byKey(const ValueKey('activity-04')),
          matching: find.byWidgetPredicate(
            (widget) => widget is RichText && widget.text.toPlainText().contains('Neon Alley'),
          ),
        ),
      );
      TapGestureRecognizer? tap;
      line.text.visitChildren((span) {
        if (span is TextSpan && span.text == 'Neon Alley') tap = span.recognizer as TapGestureRecognizer?;
        return tap == null;
      });
      expect(tap, isNotNull, reason: 'the game\'s name is its own span, with a click');
      tap!.onTap!();
      expect(model.overlay, Layer.gameHub);
      expect(model.together.findState.hubTitle, 'PPSA02002');
      // Back is the feed it came from.
      model.handle(Command.back);
      expect(model.overlay, Layer.feed);
    });

    test('the friends panel offers the feed and the leaderboard; a game\'s settings its board and how it runs', () {
      fixture = makeFixture();
      model = fixture.model;
      signedIn();
      model.open(Layer.friends);
      final ids = model.panelCategories().single.rows.map((row) => row.id).toList();
      expect(ids.sublist(0, 5), ['friends-me', 'friends-find', 'friends-feed', 'friends-captures', 'friends-board']);
      model.selected = model.games.indexWhere((game) => game.titleId == 'PPSA02002');
      model.open(Layer.gameSettings);
      final rows = model.panelCategories().single.rows.map((row) => row.id).toList();
      expect(rows, containsAll(['leaderboard', 'compat', 'game-hub']));
      // The game's hub, from its options, as on the Mac.
      final hubRow = model.panelCategories().single.rows.firstWhere((row) => row.id == 'game-hub');
      expect(hubRow.title, 'Neon Alley hub');
      (hubRow.kind as ActionRow).run();
      expect(model.overlay, Layer.gameHub);
      expect(model.together.findState.hubTitle, 'PPSA02002');
      model.open(Layer.gameSettings);
      // Signed out: neither.
      model.together.account.user = null;
      expect(model.panelCategories().single.rows.map((row) => row.id), isNot(contains('compat')));
    });

    test("a family notification says what it's about, as on the Mac", () {
      fixture = makeFixture();
      model = fixture.model;
      signedIn();
      final together = model.together;
      String text(String kind, Map<String, dynamic> data) =>
          together.noticeText(Notice.fromJson(notice('a', kind, const Duration(minutes: 1), data: data))!);

      expect(text('family_request', {'kind': 'more_time', 'minutes': 15}), 'Bora asks for 15 more minutes');
      expect(text('family_request', {'kind': 'play_game', 'gameName': 'Neon Alley'}), 'Bora asks to play Neon Alley');
      expect(text('family_request', {'kind': 'friend'}), 'Bora asks to add a friend');
      expect(
        text('family_answer', {'kind': 'more_time', 'approved': true, 'minutes': 15}),
        'A parent gave you 15 more minutes',
      );
      expect(text('family_answer', {'kind': 'play_game', 'approved': true}), 'A parent said yes: the game is open');
      expect(text('family_answer', {'kind': 'friend', 'approved': true}), 'A parent said yes to your new friend');
      expect(text('family_answer', {'approved': false}), 'A parent said no this time');
      expect(text('family_alert', {'event': 'limit_reached'}), "Bora reached today's play time");
      expect(text('family_alert', {'event': 'child_declined'}), 'Bora did not join your family');
      expect(text('family_alert', {'event': 'joined'}), 'Bora joined your family');
      expect(text('family_invite', {'familyName': 'Yılmaz'}), 'Bora invites you to the family Yılmaz');
      expect(text('family_summary', {}), "Your family's week in games");
      expect(text('something_new', {}), T.text('socialNotifOther'));
    });

    testWidgets('the bell shows only while signed in, with the unread count', (tester) async {
      fixture = makeFixture();
      model = fixture.model;
      await pumpLauncher(tester, model);
      expect(find.byIcon(Icons.notifications_rounded), findsNothing);
      expect(find.byIcon(Icons.notifications_active_rounded), findsNothing);
      signedIn();
      model.together.hub.social.notices.unread = 2;
      model.refresh();
      await tester.pump();
      expect(
        find.descendant(of: find.byType(TopBar), matching: find.byIcon(Icons.notifications_active_rounded)),
        findsOneWidget,
      );
      expect(find.descendant(of: find.byType(TopBar), matching: find.text('2')), findsOneWidget);
    });
  });

  group('with the server', () {
    late FakeTogether server;

    setUp(() async {
      // The widget tests above put in Flutter's fake HTTP client: the fake server needs the real one.
      HttpOverrides.global = null;
      server = await FakeTogether.start();
    });

    tearDown(() async {
      model.dispose();
      await server.close();
    });

    Future<void> signInForReal() async {
      final together = model.together;
      together.email = 'utku@example.com';
      await together.sendCode();
      together.code = '123456';
      await together.verify();
      for (var tries = 0; tries < 1000 && !together.signedIn; tries++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(together.signedIn, isTrue, reason: model.toast);
    }

    test('a notification opened is read and goes where it points; Mark all as read empties the badge', () async {
      fixture = makeFixture(together: server.base);
      model = fixture.model;
      await signInForReal();
      server.answers['me/notifications'] = (
        200,
        {
          'notifications': [
            notice('02', 'party_invite', const Duration(minutes: 5)),
            notice('01', 'friend_request', const Duration(hours: 1)),
          ],
          'unread': 2,
          'more': false,
        },
      );
      server.answers['POST me/notifications/02/read'] = (200, {'unread': 1});
      server.answers['POST me/notifications/read-all'] = (200, {'unread': 0});
      final together = model.together;
      together.openNotifications();
      await together.loadNotifications();
      final rows = model.panelCategories().single.rows;
      expect(rows.map((row) => row.id), ['notes-all', 'note-02', 'note-01']);
      (rows[1].kind as ActionRow).run();
      expect(model.overlay, Layer.party);
      for (var tries = 0; tries < 100 && server.callsTo('me/notifications/02/read').isEmpty; tries++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(together.hub.social.notices.unread, 1);
      together.openNotifications();
      await together.loadNotifications();
      (model.panelCategories().single.rows.first.kind as ActionRow).run();
      expect(together.hub.social.notices.unread, 0);
      // All read: the heading says so once, and no row repeats it.
      expect(model.panelCategories().single.title, 'Nothing new');
      expect(model.panelCategories().single.rows.map((row) => row.id), isNot(contains('notes-none')));
      // None at all: the row says it, the heading stays quiet.
      together.hub.social.notices.load(const [], unread: 0, more: false);
      expect(model.panelCategories().single.title, '');
      expect(model.panelCategories().single.rows.single.title, 'Nothing new');
    });

    test('How did it run? asks once per game and version, and the report goes with the system', () async {
      fixture = makeFixture(together: server.base);
      model = fixture.model;
      await signInForReal();
      final together = model.together;
      final neon = model.games.firstWhere((game) => game.titleId == 'PPSA02002');
      server.answers['POST compat/reports'] = (
        201,
        {
          'summary': {
            'status': 'playable',
            'version': launcherVersion,
            'testedAt': '2026-10-24T20:00:00Z',
            'reports': 1,
          },
        },
      );
      together.askHowItRan(neon, const Duration(seconds: 20));
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(model.overlay, isNull, reason: 'too short to tell');
      together.askHowItRan(neon, const Duration(minutes: 30));
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(model.overlay, Layer.compat);
      expect(model.preferences.compatAsked[neon.titleId], launcherVersion);
      final playable = model.panelCategories().single.rows.first;
      expect(playable.id, 'compat-playable');
      (playable.kind as ActionRow).run();
      expect(model.overlay, isNull);
      for (var tries = 0; tries < 100 && model.toast != T.text('socialCompatThanks'); tries++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(model.toast, T.text('socialCompatThanks'));
      final body = server.callsTo('compat/reports', method: 'POST').single.body;
      expect(body['platform'], 'linux');
      expect(body['status'], 'playable');
      expect(body['titleId'], 'PPSA02002');
      expect(body['launcherVersion'], launcherVersion);
      expect(together.screens.compat['PPSA02002']!.status, CompatStatus.playable);
      // Asked about this version: not again.
      together.askHowItRan(neon, const Duration(minutes: 30));
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(model.overlay, isNull);
    });

    test('a leaderboard opens on the user\'s line; △ switches to everyone, a game without one says so', () async {
      fixture = makeFixture(together: server.base);
      model = fixture.model;
      await signInForReal();
      server.answers['leaderboards/points?scope=friends'] = (
        200,
        {
          'board': 'points',
          'scope': 'friends',
          'entries': [
            {'rank': 1, 'user': card('u-bora', 'Bora'), 'value': 900},
            {'rank': 2, 'user': card('u-me', 'Utku'), 'value': 700},
          ],
          'me': {'rank': 2, 'value': 700, 'listed': true},
          'around': <Object>[],
          'total': 2,
        },
      );
      server.answers['leaderboards/points?scope=global'] = (
        200,
        {
          'board': 'points',
          'scope': 'global',
          'entries': [
            {'rank': 1, 'user': card('u-ana', 'Ana'), 'value': 4000},
          ],
          'me': {'rank': 50, 'value': 700, 'listed': false},
          'around': <Object>[],
          'total': 1,
        },
      );
      final together = model.together;
      together.openLeaderboard(null);
      await together.loadLeaderboard();
      expect(together.screens.boardIndex, 1);
      model.handle(Command.options);
      expect(together.screens.boardScope, BoardScope.global);
      await together.loadLeaderboard();
      expect(together.boardLines.last, isA<BoardUnlisted>());
      model.handle(Command.back);
      expect(model.overlay, isNull);

      final neon = model.games.firstWhere((game) => game.titleId == 'PPSA02002');
      server.answers['games/PPSA02002/leaderboard?by=points&scope=global'] = FakeTogether.problem(404, 'not_found');
      together.openLeaderboard(neon);
      await together.loadLeaderboard();
      expect(together.screens.boardMissing, isTrue);
    });
  });
}
