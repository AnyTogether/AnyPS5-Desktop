import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/together/account.dart';
import 'package:anyps5_desktop/core/together/compat.dart';
import 'package:anyps5_desktop/core/together/levels.dart';
import 'package:anyps5_desktop/core/together/social.dart';
import 'package:anyps5_desktop/core/together/socket.dart';
import 'package:anyps5_desktop/core/together/token_store.dart';
import 'package:test/test.dart';

import '../support/fake_together.dart';

/// The activity feed, the leaderboards, the notifications and community compatibility, as
/// AnyTogether's API and gateway send them (the macOS launcher's TogetherFeed,
/// TogetherLeaderboards, TogetherNotifications and TogetherCompat).
void main() {
  Map<String, dynamic> person(String id, String name) => {
    'userId': id,
    'handle': name.toLowerCase(),
    'displayName': name,
    'avatar': null,
  };

  Map<String, dynamic> activity(String id, {String kind = 'trophy', Map<String, dynamic>? reactions}) => {
    'id': id,
    'kind': kind,
    'createdAt': '2026-10-24T20:00:00Z',
    'actor': person('u-bora', 'Bora'),
    'game': {
      'titleId': 'PPSA02002',
      'names': {'en': 'Neon Alley', 'tr': 'Neon Sokak'},
      'iconUrl': null,
    },
    'highlight': 'rare',
    'trophies': [
      {
        'trophyId': 7,
        'grade': 'gold',
        'hidden': false,
        'texts': {
          'en': {'name': 'Night Owl', 'detail': 'Play past midnight.'},
        },
        'rarity': 0.12,
        'rarityLabel': 'rare',
      },
      {'trophyId': 9, 'grade': 'silver', 'hidden': true, 'texts': null, 'rarity': null, 'rarityLabel': null},
    ],
    'trophyCount': 3,
    'reactions':
        reactions ??
        {
          'counts': {'fire': 2, 'heart': 0},
          'mine': null,
        },
  };

  Map<String, dynamic> notice(String id, String kind, {bool read = false, Map<String, dynamic>? data}) => {
    'id': id,
    'kind': kind,
    'actor': kind == 'warning' ? null : person('u-ana', 'Ana'),
    'subjectId': null,
    'data': data ?? <String, dynamic>{},
    'read': read,
    'createdAt': '2026-10-24T20:00:00Z',
    'updatedAt': '2026-10-24T20:05:00Z',
  };

  group('parsing', () {
    test('an activity item: the game, the trophies with hidden ones nameless, the reactions', () {
      final item = Activity.fromJson(activity('01-a'))!;
      expect(item.kind, ActivityKind.trophy);
      expect(item.game!.name('tr'), 'Neon Sokak');
      expect(item.game!.name('de'), 'Neon Alley');
      expect(item.trophies.first.name('en'), 'Night Owl');
      expect(item.trophies.last.name('en'), isNull, reason: 'a hidden trophy this user has not earned');
      expect(item.trophyCount, 3);
      expect(item.highlight, 'rare');
      expect(item.reactions.count(Reaction.fire), 2);
      expect(item.reactions.counts.containsKey(Reaction.heart), isFalse, reason: 'zero counts are left out');
      expect(Activity.fromJson({...activity('01-b'), 'kind': 'something_new'})!.kind, ActivityKind.other);
      expect(
        Activity.fromJson({
          ...activity('01-c'),
          'kind': 'level_up',
          'level': {'level': 12, 'tier': 'bronze', 'frame': 1},
        })!.level,
        LevelBadge.of(12),
      );
      expect(Activity.fromJson({'id': 'x'}), isNull);
    });

    test('a reaction: chosen, changed for another, and taken back', () {
      const none = Reactions(counts: {Reaction.fire: 2});
      final fire = none.choosing(Reaction.fire);
      expect(fire.mine, Reaction.fire);
      expect(fire.count(Reaction.fire), 3);
      final heart = fire.choosing(Reaction.heart);
      expect(heart.mine, Reaction.heart);
      expect(heart.count(Reaction.fire), 2);
      expect(heart.count(Reaction.heart), 1);
      final back = heart.choosing(Reaction.heart);
      expect(back.mine, isNull);
      expect(back, none);
      expect(back.total, 2);
    });

    test('the feed: newest first by ID, one item per ID, older pages after', () {
      final feed = FeedList()..load([Activity.fromJson(activity('03'))!, Activity.fromJson(activity('01'))!], 'next-1');
      feed.upsert(Activity.fromJson(activity('02'))!);
      expect(feed.items.map((item) => item.id), ['03', '02', '01']);
      feed.upsert(Activity.fromJson(activity('02', kind: 'platinum'))!);
      expect(feed.items.map((item) => item.id), ['03', '02', '01']);
      expect(feed.items[1].kind, ActivityKind.platinum);
      feed.loadOlder([Activity.fromJson(activity('00'))!], null);
      expect(feed.items.last.id, '00');
      expect(feed.next, isNull);
    });

    test('a board: the top, a gap, the people around the user, and the user when not listed', () {
      Map<String, dynamic> entry(int rank, String id) => {'rank': rank, 'user': person(id, id), 'value': 1000 - rank};
      final board = Leaderboard.fromJson({
        'board': 'points',
        'scope': 'global',
        'game': null,
        'entries': [entry(1, 'a'), entry(2, 'b')],
        'me': {'rank': 40, 'value': 960, 'listed': true},
        'around': [entry(39, 'c'), entry(40, 'u-me'), entry(41, 'd')],
        'total': 120,
        'updatedAt': '2026-10-24T20:00:00Z',
      });
      final lines = board.lines('u-me');
      expect(lines, hasLength(6));
      expect(lines[2], isA<BoardGap>());
      expect((lines[4] as BoardPerson).me, isTrue);
      // Right after the top: no gap.
      final close = Leaderboard.fromJson({
        'board': 'time',
        'scope': 'friends',
        'entries': [entry(1, 'a')],
        'me': {'rank': 2, 'value': 5, 'listed': true},
        'around': [entry(1, 'a'), entry(2, 'u-me')],
        'total': 2,
      });
      expect(close.lines('u-me').whereType<BoardGap>(), isEmpty);
      expect(close.lines('u-me'), hasLength(2));
      final unlisted = Leaderboard.fromJson({
        'board': 'points',
        'scope': 'global',
        'entries': [entry(1, 'a')],
        'me': {'rank': 7, 'value': 300, 'listed': false},
        'total': 1,
      });
      expect(unlisted.lines('u-me').last, isA<BoardUnlisted>());
      expect((unlisted.lines('u-me').last as BoardUnlisted).rank, 7);
    });

    test('notifications: kinds, the badge, read here and on another device', () {
      expect(NoticeKind.named('lfg_request'), NoticeKind.lfgRequest);
      expect(NoticeKind.named('family_request'), NoticeKind.other);
      expect(NoticeKind.message.toastsOnItsOwn, isTrue);
      expect(NoticeKind.friendRequest.toastsOnItsOwn, isFalse);
      final list = NoticeList()
        ..load(
          [
            Notice.fromJson(notice('02', 'message', data: {'count': 3, 'text': 'hi'}))!,
            Notice.fromJson(notice('01', 'warning'))!,
          ],
          unread: 2,
          more: true,
        );
      expect(list.items.first.count, 3);
      expect(list.items.last.actor, isNull);
      list.markRead('02');
      expect(list.unread, 1);
      list.markRead('02');
      expect(list.unread, 1, reason: 'read once, the badge drops once');
      list.readOn(['01'], 0);
      expect(list.items.every((item) => item.read), isTrue);
      final level = Notice.fromJson(notice('03', 'level_up', data: {'level': 12, 'tier': 'bronze', 'frame': 1}))!;
      expect(level.level, LevelBadge.of(12));
      expect(Notice.fromJson({...notice('04', 'message'), 'data': 'odd'})!.data, isEmpty);
    });

    test('a compatibility report: only what is known, cut to the server\'s lengths', () {
      final report = CompatReport(
        titleId: 'PPSA02002',
        name: '  Neon Alley ',
        platform: CompatReport.platformOf(HostSystem.windows),
        status: CompatStatus.ingame,
        launcherVersion: '0.1.17',
        engineVersion: 'v0.1.17 (arm)',
        machine: 'x' * 200,
        os: 'Windows 10.0.22631',
        fpsAvg: 2000,
      );
      expect(report.body, {
        'titleId': 'PPSA02002',
        'platform': 'windows',
        'status': 'ingame',
        'launcherVersion': '0.1.17',
        'name': 'Neon Alley',
        'engineVersion': 'v0.1.17arm',
        'machine': 'x' * 120,
        'os': 'Windows 10.0.22631',
      });
      expect(CompatReport.platformOf(HostSystem.linux), 'linux');
      expect(CompatReport.version('***'), isNull);
    });

    test('asked once per game and launcher version, after a session long enough to tell', () {
      bool ask(Duration played, Map<String, String> asked) =>
          CompatPrompt.shouldAsk(titleId: 'PPSA02002', played: played, launcherVersion: '0.1.17', asked: asked);
      expect(ask(const Duration(minutes: 5), {}), isTrue);
      expect(ask(const Duration(seconds: 30), {}), isFalse);
      expect(ask(const Duration(minutes: 5), {'PPSA02002': '0.1.17'}), isFalse);
      expect(ask(const Duration(minutes: 5), {'PPSA02002': '0.1.16'}), isTrue);
    });
  });

  group('client', () {
    late FakeTogether server;
    late TogetherAccount account;
    late TogetherSocket socket;
    late Social social;

    Future<void> until(bool Function() condition) async {
      for (var tries = 0; tries < 1000 && !condition(); tries++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(condition(), isTrue);
    }

    setUp(() async {
      server = await FakeTogether.start();
      account = TogetherAccount(base: server.base, store: MemoryTokenStore(), clientName: 'launcher-linux/0.1.0');
      await account.startEmail('utku@example.com');
      await account.verifyEmail('123456');
      socket = TogetherSocket(
        account: account,
        retryBase: const Duration(milliseconds: 10),
        retryMost: const Duration(milliseconds: 40),
      );
      social = Social(account: account, socket: socket);
    });

    tearDown(() async {
      social.dispose();
      socket.dispose();
      account.close();
      await server.close();
    });

    test('the feed reads a page, then the older one; a reaction shows at once and as the server says', () async {
      server.answers['me/feed'] = (
        200,
        {
          'items': [activity('02'), activity('01')],
          'next': '01',
        },
      );
      server.answers['me/feed?before=01'] = (
        200,
        {
          'items': [activity('00')],
          'next': null,
        },
      );
      await social.loadFeed();
      expect(social.feed.items.map((item) => item.id), ['02', '01']);
      await social.loadOlderFeed();
      expect(social.feed.items.map((item) => item.id), ['02', '01', '00']);
      expect(social.feed.next, isNull);

      server.answers['PUT activities/02/reaction'] = (
        200,
        {
          'counts': {'fire': 3},
          'mine': 'fire',
        },
      );
      await social.react('02', Reaction.fire);
      expect(server.callsTo('activities/02/reaction', method: 'PUT').single.body, {'reaction': 'fire'});
      expect(social.feed.items.first.reactions.mine, Reaction.fire);

      // The same again takes it back.
      server.answers['DELETE activities/02/reaction'] = (
        200,
        {
          'counts': {'fire': 2},
          'mine': null,
        },
      );
      await social.react('02', Reaction.fire);
      expect(social.feed.items.first.reactions.mine, isNull);

      // A failure puts the old ones back.
      server.answers['PUT activities/01/reaction'] = FakeTogether.problem(500, 'internal');
      await expectLater(social.react('01', Reaction.heart), throwsA(isA<TogetherProblem>()));
      expect(social.feed.items[1].reactions.mine, isNull);
      expect(social.feed.items[1].reactions.count(Reaction.fire), 2);
    });

    test('boards: overall points and one game by play time, among everyone', () async {
      server.answers['leaderboards/points?scope=friends'] = (
        200,
        {
          'board': 'points',
          'scope': 'friends',
          'game': null,
          'entries': [
            {'rank': 1, 'user': person('u-bora', 'Bora'), 'value': 1830},
          ],
          'me': {'rank': 2, 'value': 700, 'listed': true},
          'around': <Object>[],
          'total': 2,
        },
      );
      final points = await social.pointsBoard(BoardScope.friends);
      expect(points.entries.single.value, 1830);
      expect(points.myRank, 2);

      server.answers['games/PPSA02002/leaderboard?by=time&scope=global'] = FakeTogether.problem(404, 'not_found');
      await expectLater(
        social.gameBoard('PPSA02002', GameBoard.time, BoardScope.global),
        throwsA(isA<TogetherProblem>().having((problem) => problem.status, 'status', 404)),
      );
    });

    test('notifications: the list, the badge from the gateway, read one and all', () async {
      server.answers['me/notifications'] = (
        200,
        {
          'notifications': [
            notice('02', 'message', data: {'text': 'see you at nine'}),
            notice('01', 'friend_request'),
          ],
          'unread': 2,
          'more': false,
        },
      );
      await social.loadNotices();
      expect(social.notices.items, hasLength(2));
      expect(social.notices.unread, 2);

      server.answers['POST me/notifications/02/read'] = (200, {'unread': 1});
      await social.readNotice('02');
      expect(social.notices.unread, 1);
      expect(social.notices.items.first.read, isTrue);

      final toasts = <Notice>[];
      social.onNotice = toasts.add;
      server.answers['me/notifications/unread'] = (200, {'unread': 1});
      socket.start();
      await until(() => socket.status == SocketStatus.ready);
      server.push('notification', {
        'notification': notice('03', 'warning', data: {'reason': 'Spam'}),
        'unread': 2,
      });
      await until(() => social.notices.unread == 2);
      expect(social.notices.items.first.id, '03');
      expect(toasts.single.data['reason'], 'Spam');
      // A friend request has its own event: no second toast.
      server.push('notification', {'notification': notice('04', 'friend_request'), 'unread': 3});
      await until(() => social.notices.unread == 3);
      expect(toasts, hasLength(1));

      server.push('notification.read', {'ids': null, 'unread': 0});
      await until(() => social.notices.unread == 0);
      expect(social.notices.items.every((item) => item.read), isTrue);

      server.answers['POST me/notifications/read-all'] = (200, {'unread': 0});
      await social.readAllNotices();
      expect(server.callsTo('me/notifications/read-all', method: 'POST'), hasLength(1));
    });

    test('a feed item from the gateway goes in at its place once the feed is read', () async {
      server.answers['me/feed'] = (
        200,
        {
          'items': [activity('01')],
          'next': null,
        },
      );
      server.answers['me/notifications/unread'] = (200, {'unread': 0});
      await social.loadFeed();
      socket.start();
      await until(() => socket.status == SocketStatus.ready);
      server.push('feed.item', activity('02', kind: 'platinum'));
      await until(() => social.feed.items.length == 2);
      expect(social.feed.items.first.kind, ActivityKind.platinum);

      // The launcher's feed holds its focus around a new item: what goes in goes through it.
      var held = 0;
      social.holdFeedFocus = (change) {
        held++;
        change();
      };
      server.push('feed.item', activity('03', kind: 'platinum'));
      await until(() => social.feed.items.length == 3);
      expect(held, 1);
    });

    test('compatibility: a report gives the verdict, a game nobody reported is null', () async {
      server.answers['POST compat/reports'] = (
        201,
        {
          'id': 'r1',
          'summary': {'status': 'ingame', 'version': '0.1.17', 'testedAt': '2026-10-24T20:00:00Z', 'reports': 4},
        },
      );
      final summary = await Compat(account).report(
        const CompatReport(
          titleId: 'PPSA02002',
          platform: 'linux',
          status: CompatStatus.ingame,
          launcherVersion: '0.1.17',
        ),
      );
      expect(summary!.status, CompatStatus.ingame);
      expect(summary.reports, 4);
      expect(server.callsTo('compat/reports', method: 'POST').single.body['platform'], 'linux');

      server.answers['compat/PPSA02002'] = (
        200,
        {
          'titleId': 'PPSA02002',
          'name': 'Neon Alley',
          'platforms': {
            'macos': {'status': 'playable', 'version': '0.2.17', 'testedAt': '2026-10-24T20:00:00Z', 'reports': 9},
            'linux': {'status': 'menus', 'version': '0.1.17', 'testedAt': '2026-10-24T20:00:00Z', 'reports': 1},
          },
        },
      );
      final game = await Compat(account).game('PPSA02002');
      expect(game!.platforms['linux']!.status, CompatStatus.menus);
      expect(game.platforms['windows'], isNull);
      server.answers['compat/PPSA09009'] = FakeTogether.problem(404, 'not_found');
      expect(await Compat(account).game('PPSA09009'), isNull);
    });
  });
}
