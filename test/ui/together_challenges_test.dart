import 'dart:io';

import 'package:anyps5_desktop/core/together/account.dart';
import 'package:anyps5_desktop/core/together/challenges.dart';
import 'package:anyps5_desktop/core/together/levels.dart';
import 'package:anyps5_desktop/core/together/social.dart';
import 'package:anyps5_desktop/ui/app_model.dart' hide GameState;
import 'package:anyps5_desktop/ui/challenge_view.dart';
import 'package:anyps5_desktop/ui/launcher.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:anyps5_desktop/ui/together_model.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_together.dart';
import '../support/language_files.dart';
import '../support/ui_support.dart';

/// Challenges where the leaderboards are: a strip over a game's board (or the user's own over
/// the overall one), hidden when there are none or the server has none; a challenge's standings
/// with Join and Leave; the three challenge notifications. The goldens are rendered headless.
void main() {
  late Fixture fixture;
  late AppModel model;

  // One fixed now for the fixtures and the screens, so the time left and the tracks draw the same
  // on every run.
  final now = DateTime.now();
  setUp(() => TogetherChallenges.clock = () => now);

  tearDown(() {
    T.language = Language.english;
    TogetherChallenges.clock = DateTime.now;
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

  String from(Duration time) => now.add(time).toUtc().toIso8601String();

  Map<String, dynamic> view(
    String id, {
    String title = 'Weekend race',
    String metric = 'points',
    String state = 'active',
    String audience = 'friends',
    bool joined = false,
    bool mine = false,
    bool isFinal = false,
    Duration starts = const Duration(hours: -20),
    Duration ends = const Duration(days: 2, hours: 3),
    int entrants = 6,
    Map<String, dynamic>? leader,
    Map<String, dynamic>? myStanding,
  }) => {
    'id': id,
    'title': title,
    'description': null,
    'game': {
      'titleId': 'PPSA02002',
      'names': {'en': 'Neon Alley'},
      'iconUrl': null,
    },
    'metric': metric,
    'audience': audience,
    'community': audience == 'community'
        ? {'id': 'c-1', 'name': 'Night Owls', 'icon': 'owl', 'iconUrl': 'https://example.com/owl.png'}
        : null,
    'creator': card('u-ana', 'Ana'),
    'startsAt': from(starts),
    'endsAt': from(ends),
    'state': state,
    'final': isFinal,
    'entrants': entrants,
    'joined': joined,
    'mine': mine,
    'canCancel': mine,
    'leader': leader ?? {'rank': 1, 'user': card('u-bora', 'Bora'), 'value': 420, 'me': false},
    'myStanding': myStanding,
    'createdAt': from(const Duration(days: -2)),
  };

  List<Map<String, dynamic>> standings() => [
    {'rank': 1, 'user': card('u-bora', 'Bora'), 'value': 420, 'me': false},
    {'rank': 2, 'user': null, 'value': 300, 'me': false},
    {'rank': 2, 'user': card('u-cem', 'Cem Yılmaz'), 'value': 300, 'me': false},
    {'rank': 4, 'user': card('u-me', 'Utku Halis'), 'value': 135, 'me': true},
    {'rank': 5, 'user': card('u-deniz', 'Deniz'), 'value': 45, 'me': false},
  ];

  Map<String, dynamic> detail(Map<String, dynamic> view, [List<Map<String, dynamic>>? rows]) => {
    ...view,
    'standings': rows ?? standings(),
    'around': <Object>[],
    'updatedAt': from(Duration.zero),
  };

  Map<String, dynamic> notice(String id, String kind, {Map<String, dynamic>? extra, bool read = false}) => {
    'id': id,
    'kind': kind,
    'actor': kind == 'challenge_invite' ? card('u-ana', 'Ana') : null,
    'subjectId': 'ch-$id',
    'data': {
      'challengeId': 'ch-$id',
      'title': 'Weekend race',
      'titleId': 'PPSA02002',
      'gameNames': {'en': 'Neon Alley'},
      'metric': 'points',
      'endsAt': from(const Duration(days: 2)),
      ...?extra,
    },
    'read': read,
    // The notifications' "30 min ago" reads the real clock.
    'createdAt': DateTime.now().subtract(const Duration(minutes: 30)).toUtc().toIso8601String(),
    'updatedAt': DateTime.now().subtract(const Duration(minutes: 30)).toUtc().toIso8601String(),
  };

  group('words', () {
    test('time left: days past two, then hours, then minutes; coming, over and called off', () {
      fixture = makeFixture();
      final now = DateTime.utc(2026, 11, 6, 12);
      Challenge at(
        String state, {
        Duration starts = const Duration(hours: -1),
        Duration ends = Duration.zero,
        bool isFinal = false,
      }) => Challenge.fromJson({
        'id': 'x',
        'title': 'x',
        'game': {'titleId': 'PPSA02002'},
        'metric': 'points',
        'audience': 'friends',
        'state': state,
        'final': isFinal,
        'startsAt': now.add(starts).toIso8601String(),
        'endsAt': now.add(ends).toIso8601String(),
      })!;
      String when(Challenge challenge) => TogetherChallenges.when(challenge, now: now);
      expect(when(at('active', ends: const Duration(days: 2, hours: 10))), 'Ends in 2 days');
      expect(when(at('active', ends: const Duration(hours: 47))), 'Ends in 47 h');
      expect(when(at('active', ends: const Duration(minutes: 25, seconds: 20))), 'Ends in 26 min');
      expect(when(at('active', ends: const Duration(seconds: 20))), 'Ends in 1 min');
      expect(when(at('upcoming', starts: const Duration(days: 3), ends: const Duration(days: 4))), 'Starts in 3 days');
      expect(when(at('ended', ends: const Duration(minutes: -20))), 'Over, final within the hour');
      expect(when(at('ended', ends: const Duration(days: -2), isFinal: true)), 'Ended 2 d ago');
      expect(when(at('cancelled', ends: const Duration(days: 1))), 'Called off');

      expect(TogetherChallenges.value(1830, ChallengeMetric.points), '1,830 pts');
      expect(TogetherChallenges.value(5, ChallengeMetric.trophies), '5 trophies');
      expect(TogetherChallenges.value(4500, ChallengeMetric.time), '1 h 15 min');
      expect(TogetherChallenges.metricName(ChallengeMetric.time), 'Play time');

      T.language = Language.byCode('tr');
      expect(when(at('active', ends: const Duration(days: 2, hours: 10))), '2 gün sonra bitiyor');
      expect(TogetherChallenges.metricName(ChallengeMetric.points), 'Kupa puanı');
      expect(TogetherChallenges.metricName(ChallengeMetric.trophies), 'Kupalar');
      expect(TogetherChallenges.metricName(ChallengeMetric.time), 'Oynama süresi');
    });

    test('every challenge text is in all 28 of the launcher\'s languages, translated', () {
      fixture = makeFixture();
      final codes = [
        for (final file in Directory('assets/l10n').listSync().whereType<File>())
          if (file.path.endsWith('.json')) file.uri.pathSegments.last.replaceAll('.json', ''),
      ];
      expect(codes, hasLength(28));
      final english = languageFile('en');
      final keys = english.keys
          .where((key) => key.startsWith('challenge') || key.startsWith('notifChallenge'))
          .toList();
      expect(keys.length, greaterThan(30));
      for (final code in codes) {
        final texts = languageFile(code);
        for (final key in keys) {
          expect(texts[key], isNotNull, reason: '$key in $code');
          final placeholders = RegExp(r'%(?:\d\$)?[@d]');
          expect(
            placeholders.allMatches(texts[key]!).length,
            placeholders.allMatches(english[key]!).length,
            reason: '$key in $code keeps its placeholders',
          );
        }
        // Names and numbers alone may read the same; the sentences may not.
        if (code != 'en') {
          for (final key in ['challengeJoinNote', 'challengeMakeOnWeb', 'notifChallengeStarted']) {
            expect(texts[key], isNot(english[key]), reason: '$key in $code is still English');
          }
        }
      }
    });
  });

  group('goldens', () {
    testWidgets('golden: a game\'s board with its challenges over it, one chosen (en)', (tester) async {
      fixture = makeFixture();
      model = fixture.model;
      signedIn();
      final neon = model.games.firstWhere((game) => game.titleId == 'PPSA02002');
      model.together.screens
        ..boardTitleId = neon.titleId
        ..boardName = neon.name
        ..boardScope = BoardScope.friends
        ..board = Leaderboard.fromJson({
          'board': 'points',
          'scope': 'friends',
          'entries': [
            {'rank': 1, 'user': card('u-ana', 'Ana'), 'value': 4210},
            {'rank': 2, 'user': card('u-bora', 'Bora'), 'value': 3990},
            {'rank': 3, 'user': card('u-me', 'Utku Halis'), 'value': 1830},
          ],
          'me': {'rank': 3, 'value': 1830, 'listed': true},
          'around': <Object>[],
          'total': 3,
        })
        ..boardChallenges = [
          Challenge.fromJson(view('ch-1', joined: true, myStanding: {'rank': 4, 'value': 135}, entrants: 6))!,
          Challenge.fromJson(
            view(
              'ch-2',
              title: 'Night shift marathon',
              metric: 'time',
              state: 'upcoming',
              audience: 'community',
              starts: const Duration(days: 3, hours: 2),
              ends: const Duration(days: 5),
              entrants: 14,
            )..['leader'] = null,
          )!,
          Challenge.fromJson(
            view('ch-3', title: 'Trophy hunt', metric: 'trophies', audience: 'public', entrants: 212),
          )!,
        ]
        ..boardOnChallenges = true
        ..boardChallenge = 0;
      model.open(Layer.leaderboard);
      await pumpLauncher(tester, model);
      expect(find.byType(ChallengeStrip), findsOneWidget);
      expect(find.text('Weekend race'), findsOneWidget);
      expect(
        find.text(
          T.format('challengeEndsIn', [
            T.format('challengeDays', [2]),
          ]),
        ),
        findsWidgets,
      );
      await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/challenges_board_en.png'));
    });

    testWidgets('golden: a running challenge, joined, with a hidden player and the user\'s row (tr)', (tester) async {
      fixture = makeFixture(language: Language.byCode('tr'));
      model = fixture.model;
      signedIn();
      model.together.screens
        ..challengeId = 'ch-1'
        ..challenge = ChallengeDetail.fromJson(
          detail(view('ch-1', joined: true, entrants: 5, myStanding: {'rank': 4, 'value': 135})),
        )
        ..challengeIndex = 0;
      model.open(Layer.challenge);
      await pumpLauncher(tester, model);
      expect(find.byType(ChallengeDetailView), findsOneWidget);
      expect(find.text(T.text('challengeHidden')), findsOneWidget);
      expect(find.text(T.text('challengeLeave')), findsWidgets);
      // The current leader shows on the page too, before it is final.
      expect(find.text(T.upper(T.text('challengeLeading'))), findsOneWidget);
      await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/challenge_detail_tr.png'));
    });

    testWidgets('golden: a challenge over and final, with its winner (en)', (tester) async {
      fixture = makeFixture();
      model = fixture.model;
      signedIn();
      model.together.screens
        ..challengeId = 'ch-1'
        ..challenge = ChallengeDetail.fromJson(
          detail(
            view(
              'ch-1',
              state: 'ended',
              isFinal: true,
              joined: true,
              starts: const Duration(days: -4),
              ends: const Duration(days: -1),
              myStanding: {'rank': 4, 'value': 135},
            ),
          ),
        )
        ..challengeIndex = 3;
      model.open(Layer.challenge);
      await pumpLauncher(tester, model);
      expect(find.text(T.upper(T.text('challengeWinner'))), findsOneWidget);
      expect(find.text(T.text('challengeLeave')), findsNothing);
      expect(find.text(T.text('challengeJoin')), findsNothing);
      await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/challenge_final_en.png'));
    });

    testWidgets('golden: the three challenge notifications (en)', (tester) async {
      fixture = makeFixture();
      model = fixture.model;
      signedIn();
      model.together.hub.social.notices.load(
        [
          Notice.fromJson(notice('03', 'challenge_invite'))!,
          Notice.fromJson(notice('02', 'challenge_started'))!,
          Notice.fromJson(
            notice(
              '01',
              'challenge_ended',
              read: true,
              extra: {
                'rank': 1,
                'value': 420,
                'entrants': 6,
                'winner': {'displayName': 'Utku Halis', 'handle': 'utku', 'value': 420},
              },
            ),
          )!,
        ],
        unread: 2,
        more: false,
      );
      model.open(Layer.notifications);
      model.panelRow = 1;
      await pumpLauncher(tester, model);
      expect(find.text(T.format('notifChallengeInvite', ['Ana', 'Weekend race'])), findsOneWidget);
      expect(find.text(T.format('notifChallengeWon', ['Weekend race'])), findsOneWidget);
      await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/challenges_notifications_en.png'));
    });
  });

  group('behaviour', () {
    testWidgets('no challenges: no strip, no empty box', (tester) async {
      fixture = makeFixture();
      model = fixture.model;
      signedIn();
      model.together.screens
        ..boardTitleId = null
        ..board = Leaderboard.fromJson({
          'board': 'points',
          'scope': 'friends',
          'entries': [
            {'rank': 1, 'user': card('u-me', 'Utku Halis'), 'value': 700},
          ],
          'me': {'rank': 1, 'value': 700, 'listed': true},
          'total': 1,
        });
      model.open(Layer.leaderboard);
      await pumpLauncher(tester, model);
      expect(find.byType(ChallengeStrip), findsNothing);
      expect(find.text(T.upper(T.text('challengeTitle'))), findsNothing);
    });

    test('the ended notification: won, placed, or nobody scored; opening one opens the challenge', () {
      fixture = makeFixture();
      model = fixture.model;
      signedIn();
      final together = model.together;
      final won = Notice.fromJson(
        notice('01', 'challenge_ended', extra: {'rank': 1, 'value': 420, 'entrants': 6, 'winner': null}),
      )!;
      expect(won.kind, NoticeKind.challengeEnded);
      expect(together.noticeText(won), T.format('notifChallengeWon', ['Weekend race']));
      final placed = Notice.fromJson(
        notice(
          '02',
          'challenge_ended',
          extra: {
            'rank': 3,
            'value': 90,
            'entrants': 6,
            'winner': {'displayName': 'Bora', 'handle': 'bora', 'value': 420},
          },
        ),
      )!;
      expect(together.noticeText(placed), T.format('notifChallengeEnded', ['Weekend race', 3, 6]));
      expect(together.noticeDetail(placed), '${T.text('challengeWinner')}: Bora · 420 pts');
      final nothing = Notice.fromJson(notice('03', 'challenge_ended', extra: {'rank': 1, 'value': 0, 'entrants': 2}))!;
      expect(together.noticeText(nothing), isNot(T.format('notifChallengeWon', ['Weekend race'])));
      final started = Notice.fromJson(notice('04', 'challenge_started'))!;
      expect(together.noticeText(started), T.format('notifChallengeStarted', ['Weekend race']));
      expect(together.noticeDetail(started), 'Neon Alley');
      expect(NoticeKind.challengeInvite.toastsOnItsOwn, isTrue, reason: 'nothing else announces it');

      model.open(Layer.notifications);
      together.openNotice(started);
      expect(model.overlay, Layer.challenge);
      expect(together.screens.challengeId, 'ch-04');
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

    Map<String, dynamic> board(String scope) => {
      'board': 'points',
      'scope': scope,
      'entries': [
        {'rank': 1, 'user': card('u-bora', 'Bora'), 'value': 900},
        {'rank': 2, 'user': card('u-me', 'Utku'), 'value': 700},
      ],
      'me': {'rank': 2, 'value': 700, 'listed': true},
      'around': <Object>[],
      'total': 2,
    };

    test('a game\'s board reads its challenges; up from the top reaches them, Enter opens one', () async {
      fixture = makeFixture(together: server.base);
      model = fixture.model;
      await signInForReal();
      server.answers['games/PPSA02002/leaderboard?by=points&scope=friends'] = (200, board('friends'));
      server.answers['challenges?titleId=PPSA02002'] = (
        200,
        {
          'challenges': [view('ch-1'), view('ch-2', title: 'Second')],
        },
      );
      server.answers['challenges/ch-2'] = (200, detail(view('ch-2', title: 'Second')));
      final together = model.together;
      final neon = model.games.firstWhere((game) => game.titleId == 'PPSA02002');
      together.openLeaderboard(neon);
      await together.loadLeaderboard();
      await together.loadBoardChallenges();
      expect(together.screens.boardChallenges.map((item) => item.id), ['ch-1', 'ch-2']);
      expect(together.screens.boardIndex, 1, reason: 'the board still opens on the user\'s line');
      model.handle(Command.up);
      expect(together.screens.boardOnChallenges, isFalse);
      model.handle(Command.up);
      expect(together.screens.boardOnChallenges, isTrue);
      model.handle(Command.right);
      expect(together.screens.boardChallenge, 1);
      expect(together.screens.boardKind, GameBoard.points, reason: 'left and right move through the challenges here');
      model.handle(Command.select);
      expect(model.overlay, Layer.challenge);
      await together.loadChallenge();
      expect(together.screens.challenge!.challenge.title, 'Second');
      model.handle(Command.back);
      expect(model.overlay, Layer.leaderboard);
      expect(together.screens.boardOnChallenges, isTrue, reason: 'back where it was');
      model.handle(Command.down);
      expect(together.screens.boardOnChallenges, isFalse);
      expect(together.screens.boardIndex, 0);
    });

    testWidgets('the page: no one ahead yet, an unknown metric, and a challenge that is gone', (tester) async {
      fixture = makeFixture();
      model = fixture.model;
      signedIn();
      final together = model.together;
      // No score yet: said where the leader is.
      together.screens
        ..challengeId = 'ch-1'
        ..challenge = ChallengeDetail.fromJson(detail({...view('ch-1'), 'leader': null}, standings()));
      model.open(Layer.challenge);
      await pumpLauncher(tester, model);
      expect(find.text(T.text('challengeNoLeader')), findsOneWidget);

      // A metric this launcher does not know: a plain number under its own name.
      expect(ChallengeMetric.named('kills'), ChallengeMetric.other);
      expect(TogetherChallenges.metricName(ChallengeMetric.other), T.text('challengeMetricOther'));
      expect(TogetherChallenges.value(7, ChallengeMetric.other), T.number(7));
      expect(TogetherChallenges.value(1, ChallengeMetric.trophies), T.format('challengeTrophyValue', [1]));
      expect(TogetherChallenges.value(4, ChallengeMetric.trophies), T.format('challengeTrophiesValue', [4]));

      // Deleted: gone, not a failure.
      together.screens
        ..challenge = null
        ..challengeGone = true;
      model.refresh();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(T.text('challengeGone')), findsOneWidget);
      expect(find.text(T.text('challengeFailed')), findsNothing);
    });

    test('a server without challenges (404) shows none; the overall board reads the user\'s own', () async {
      fixture = makeFixture(together: server.base);
      model = fixture.model;
      await signInForReal();
      server.answers['leaderboards/points?scope=friends'] = (200, board('friends'));
      final together = model.together;
      together.openLeaderboard(null);
      await together.loadLeaderboard();
      await together.loadBoardChallenges();
      expect(server.callsTo('me/challenges'), isNotEmpty);
      expect(together.screens.boardChallenges, isEmpty);
      model.handle(Command.up);
      model.handle(Command.up);
      expect(together.screens.boardOnChallenges, isFalse, reason: 'nothing up there');

      server.answers['me/challenges'] = (
        200,
        {
          'challenges': [view('ch-1')],
        },
      );
      await together.loadBoardChallenges();
      expect(together.screens.boardChallenges.single.id, 'ch-1');
      server.answers['me/challenges'] = (502, {'code': 'bad_gateway', 'title': 'Bad gateway'});
      await together.loadBoardChallenges();
      expect(together.screens.boardChallenges, isEmpty, reason: 'a failure hides the strip too');
    });

    test('join and leave: △ or the button, the standings read again; the maker cannot leave', () async {
      fixture = makeFixture(together: server.base);
      model = fixture.model;
      await signInForReal();
      final together = model.together;
      server.answers['challenges/ch-1'] = (200, detail(view('ch-1')));
      together.openChallenge('ch-1');
      await together.loadChallenge();
      expect(together.challengeActions, [ChallengeAction.join, ChallengeAction.website]);

      server.answers['POST challenges/ch-1/join'] = (200, view('ch-1', joined: true));
      server.answers['challenges/ch-1'] = (200, detail(view('ch-1', joined: true)));
      model.handle(Command.options);
      for (
        var tries = 0;
        tries < 200 && (!(together.screens.challenge?.challenge.joined ?? false) || together.screens.challengeBusy);
        tries++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(server.callsTo('challenges/ch-1/join', method: 'POST'), hasLength(1));
      expect(together.screens.challenge!.challenge.joined, isTrue);
      expect(together.challengeActions, [ChallengeAction.leave, ChallengeAction.website]);

      // The actions column: right, then select on Leave.
      server.answers['POST challenges/ch-1/leave'] = (200, view('ch-1'));
      server.answers['challenges/ch-1'] = (200, detail(view('ch-1')));
      model.handle(Command.right);
      expect(together.screens.challengeOnActions, isTrue);
      model.handle(Command.select);
      for (
        var tries = 0;
        tries < 200 && (together.screens.challenge!.challenge.joined || together.screens.challengeBusy);
        tries++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(server.callsTo('challenges/ch-1/leave', method: 'POST'), hasLength(1));

      // Full: said plainly.
      server.answers['POST challenges/ch-1/join'] = FakeTogether.problem(409, 'full');
      await together.toggleChallenge();
      expect(model.toast, T.text('challengeFull'));

      // A 409 means it changed under the screen: it is read again at once.
      final reads = server.callsTo('challenges/ch-1').length;
      server.answers['POST challenges/ch-1/join'] = FakeTogether.problem(409, 'conflict');
      await together.toggleChallenge();
      expect(model.toast, T.text('challengeOverAlready'));
      expect(server.callsTo('challenges/ch-1').length, reads + 1);

      // The website, only when chosen.
      expect(fixture.opened, isEmpty);
      model.handle(Command.down);
      model.handle(Command.select);
      expect(fixture.opened.single.toString(), '${server.base}/challenges?new=1');

      server.answers['challenges/ch-9'] = (200, detail(view('ch-9', joined: true, mine: true)));
      together.openChallenge('ch-9');
      await together.loadChallenge();
      expect(together.challengeActions, [ChallengeAction.website]);
      server.answers['challenges/ch-8'] = (200, detail(view('ch-8', state: 'ended', joined: true)));
      together.openChallenge('ch-8');
      await together.loadChallenge();
      expect(together.challengeActions, [ChallengeAction.website]);

      // Deleted meanwhile: gone, not a failure; opening another starts anew.
      server.answers['challenges/ch-5'] = FakeTogether.problem(404, 'not_found');
      together.openChallenge('ch-5');
      await together.loadChallenge();
      expect(together.screens.challengeGone, isTrue);
      expect(together.screens.challengeFailed, isFalse);
      together.openChallenge('ch-8');
      expect(together.screens.challengeGone, isFalse);
      await together.loadChallenge();
    });
  });
}
