import 'dart:io';

import 'package:anyps5_desktop/core/together/account.dart';
import 'package:anyps5_desktop/core/together/discover.dart';
import 'package:anyps5_desktop/core/together/share_play.dart';
import 'package:anyps5_desktop/ui/app_model.dart' hide GameState;
import 'package:anyps5_desktop/ui/launcher.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:anyps5_desktop/ui/together_model.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_together.dart';
import '../support/ui_support.dart';

/// Find players as the macOS launcher has it: the looking-for-group board with its filters, the
/// user's posts with who wants in, public parties, people to meet, the post form and a game's
/// hub. Goldens rendered headless, each in one language.
void main() {
  late Fixture fixture;
  late AppModel model;

  tearDown(() {
    T.language = Language.english;
    fixture.dispose();
  });

  void signedIn() {
    model.together.account.user = const TogetherUser(id: 'u-me', handle: 'utku', displayName: 'Utku Halis');
  }

  Map<String, dynamic> card(String id, String name) => {
    'userId': id,
    'handle': name.toLowerCase(),
    'displayName': name,
    'avatar': null,
  };

  String later(Duration time) => DateTime.now().add(time).toUtc().toIso8601String();

  LfgPost post(
    String id,
    String author, {
    String titleId = 'PPSA02002',
    String purpose = 'coop',
    Duration? starts,
    List<String> languages = const ['en'],
    int slots = 3,
    int filled = 0,
    String? note,
    bool mine = false,
    Map<String, dynamic>? myRequest,
    List<Map<String, dynamic>>? requests,
    String status = 'open',
  }) => LfgPost.fromJson({
    'id': id,
    'author': mine ? card('u-me', 'Utku Halis') : card('u-${author.toLowerCase()}', author),
    'titleId': titleId,
    'game': {
      'names': {
        'en': switch (titleId) {
          'PPSA02002' => 'Neon Alley',
          'PPSA01001' => 'Orbit Runner',
          _ => 'Quiet Forest',
        },
      },
    },
    'purpose': purpose,
    'startsAt': starts == null ? null : later(starts + const Duration(seconds: 20)),
    'languages': languages,
    'slots': slots,
    'filled': filled,
    'note': note,
    'expiresAt': later(const Duration(hours: 3)),
    'status': status,
    'mine': mine,
    'myRequest': myRequest,
    'requests': ?requests,
  })!;

  void board() {
    model.together.findState
      ..loaded = true
      ..games = const [
        LfgGame(titleId: 'PPSA01001', posts: 2, names: {'en': 'Orbit Runner'}),
      ]
      ..board = [
        post('p4', 'Bora', note: 'Chill run, mics optional', languages: ['en', 'tr']),
        post('p3', 'Ana', purpose: 'trophies', starts: const Duration(minutes: 30), slots: 2, filled: 1),
        post(
          'p2',
          'Deniz',
          titleId: 'PPSA01001',
          purpose: 'party',
          slots: 5,
          myRequest: {'status': 'pending', 'invite': null},
        ),
        post('p1', 'Eren', titleId: 'PPSA01001', purpose: 'online', slots: 1, filled: 1),
      ]
      ..more = true;
  }

  group('goldens', () {
    testWidgets('golden: the looking-for-group board with its filters (en)', (tester) async {
      fixture = makeFixture();
      model = fixture.model;
      signedIn();
      model.selected = model.games.indexWhere((game) => game.titleId == 'PPSA02002');
      board();
      model.open(Layer.findPlayers);
      model.panelRow = 6;
      await pumpLauncher(tester, model);
      expect(find.text('Neon Alley: ${T.text('discoverPurposeCoop')}'), findsOneWidget);
      expect(find.text(T.format('discoverFindFor', ['Neon Alley'])), findsOneWidget);
      await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/find_players_en.png'));
    });

    testWidgets('golden: my posts with someone who wants in (tr)', (tester) async {
      fixture = makeFixture(language: Language.byCode('tr'));
      model = fixture.model;
      signedIn();
      model.together.findState
        ..loaded = true
        ..mine = [
          post(
            'm1',
            'Utku',
            mine: true,
            filled: 1,
            note: 'Bölüm 4, gizli kapı',
            languages: ['tr'],
            requests: [
              {'user': card('u-ana', 'Ana'), 'status': 'pending', 'invite': null},
              {
                'user': card('u-bora', 'Bora'),
                'status': 'accepted',
                'invite': {'kind': 'party', 'id': 'party-1'},
              },
            ],
          ),
        ];
      model.open(Layer.findPlayers);
      model.selectCategory(1);
      model.panelRow = 2;
      await pumpLauncher(tester, model);
      expect(find.text(T.format('discoverLetIn', ['Ana'])), findsOneWidget);
      expect(find.text('${T.text('discoverMyPosts')} (1)'), findsOneWidget);
      await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/find_players_mine_tr.png'));
    });

    testWidgets('golden: how many are online now, by the heading (tr)', (tester) async {
      fixture = makeFixture(language: Language.byCode('tr'));
      model = fixture.model;
      signedIn();
      board();
      model.together.findState.online = 1234;
      model.open(Layer.findPlayers);
      await pumpLauncher(tester, model);
      expect(find.text('Şu an 1.234 oyuncu çevrimiçi'), findsOneWidget);
      expect(find.byTooltip('Görünmez olanlar ve durumunu gizleyenler sayılmaz.'), findsOneWidget);
      await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/find_players_online_tr.png'));
    });

    testWidgets('golden: the post form (en)', (tester) async {
      fixture = makeFixture();
      model = fixture.model;
      signedIn();
      model.together.findState.discovery = const Discovery(discoverable: true, languages: ['en', 'tr']);
      model.together.openLfgPost('PPSA02002', 'Neon Alley');
      model.together.findState.draft!.setStart(30);
      model.panelRow = 4;
      await pumpLauncher(tester, model);
      expect(model.together.findState.draft!.languages, ['en', 'tr']);
      await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/find_players_post_en.png'));
    });
  });

  group('behaviour', () {
    test('Friends offers Find players; a game\'s settings post for it; a parent\'s settings can keep it off', () {
      fixture = makeFixture();
      model = fixture.model;
      signedIn();
      model.open(Layer.friends);
      expect(model.panelCategories().single.rows.map((row) => row.id), contains('friends-find'));
      model.selected = model.games.indexWhere((game) => game.titleId == 'PPSA02002');
      model.open(Layer.gameSettings);
      expect(model.panelCategories().single.rows.map((row) => row.id), contains('find-players'));
    });

    test('Live now lists share plays to watch here, to ask to watch, and those asked', () {
      fixture = makeFixture();
      model = fixture.model;
      signedIn();
      PublicShare listed(String id, String join, {bool requested = false}) => PublicShare.fromJson({
        'id': id,
        'host': card('u-$id', 'Host $id'),
        'titleId': 'PPSA02002',
        'title': 'Neon Alley',
        'game': {
          'names': {'en': 'Neon Alley'},
        },
        'language': 'tr',
        'join': join,
        'live': true,
        'viewers': 1,
        'maxViewers': 3,
        'requested': requested,
      })!;
      model.together.findState.live = [listed('a', 'open'), listed('b', 'request'), listed('c', 'request', requested: true)];
      model.open(Layer.findPlayers);
      final parties = model.panelCategories().firstWhere((category) => category.id == 'parties');
      expect(parties.title, T.text('discoverLiveAndParties'));
      final rows = {for (final row in parties.rows) row.id: row};
      expect(rows['live-a']!.title, T.format('sharePlayWatchFriend', ['Host a', 'Neon Alley']));
      expect(rows['live-a']!.detail, contains(T.format('sharePlayWatching', [1, 3])));
      expect(rows['live-b']!.title, T.format('discoverAskToWatch', ['Host b', 'Neon Alley']));
      expect(rows['live-c']!.title, T.format('discoverAskedToWatch', ['Host c', 'Neon Alley']));
      expect(rows['live-c']!.kind, isA<InfoRow>());
      model.together.findState.live = const [];
      expect(
        model.panelCategories().firstWhere((category) => category.id == 'parties').rows.map((row) => row.id),
        containsAllInOrder(['live-title', 'live-none', 'pub-title']),
      );
    });

    test('a post\'s row follows where the user stands with it', () {
      fixture = makeFixture();
      model = fixture.model;
      signedIn();
      final together = model.together;
      expect(together.postRow(post('a', 'Bora')).kind, isA<ActionRow>());
      expect(together.postRow(post('a', 'Bora')).detail, contains(T.text('discoverSelectImIn')));
      expect(
        together.postRow(post('a', 'Bora', myRequest: {'status': 'declined'})).detail,
        contains(T.format('discoverSaidNo', ['Bora'])),
      );
      expect(together.postRow(post('a', 'Bora', status: 'closed')).kind, isA<InfoRow>());
      expect(
        together.postRow(post('a', 'Bora', starts: const Duration(minutes: 30))).detail,
        contains(T.format('discoverInMinutes', [30])),
      );
    });

    test('the online count says one or many, and nothing without a count or with nobody', () {
      fixture = makeFixture();
      model = fixture.model;
      signedIn();
      final together = model.together;
      expect(together.onlineNowText, isNull);
      together.findState.online = 0;
      expect(together.onlineNowText, isNull);
      together.findState.online = 1;
      expect(together.onlineNowText, '1 player online now');
      together.findState.online = 12;
      expect(together.onlineNowText, '12 players online now');
      together.findState.clear();
      expect(together.findState.online, isNull);
    });

    test('back from the post form returns to the game\'s settings it came from', () {
      fixture = makeFixture();
      model = fixture.model;
      signedIn();
      model.selected = model.games.indexWhere((game) => game.titleId == 'PPSA02002');
      model.open(Layer.gameSettings);
      model.together.openLfgPost('PPSA02002', 'Neon Alley');
      expect(model.overlay, Layer.lfgPost);
      model.handle(Command.back);
      expect(model.overlay, Layer.gameSettings);
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

    Future<void> until(bool Function() condition) async {
      for (var tries = 0; tries < 1000 && !condition(); tries++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(condition(), isTrue);
    }

    Future<void> signInForReal() async {
      final together = model.together;
      together.email = 'utku@example.com';
      await together.sendCode();
      together.code = '123456';
      await together.verify();
      await until(() => together.signedIn);
    }

    test('posting goes to My posts; I\'m in tells the poster', () async {
      fixture = makeFixture(together: server.base);
      model = fixture.model;
      await signInForReal();
      server.answers['lfg'] = (200, {'posts': <Object>[], 'more': false});
      server.answers['lfg/games'] = (200, {'games': <Object>[]});
      server.answers['me/lfg'] = (200, {'posts': <Object>[], 'asked': <Object>[]});
      server.answers['parties/public'] = (200, {'parties': <Object>[]});
      server.answers['discover/suggestions'] = (200, {'suggestions': <Object>[]});
      server.answers['me/discovery'] = (
        200,
        {
          'discoverable': true,
          'chosen': null,
          'languages': ['tr'],
        },
      );
      server.answers['POST lfg'] = (
        201,
        {
          'id': 'new',
          'author': card('u-me', 'Utku'),
          'titleId': 'PPSA02002',
          'purpose': 'coop',
          'languages': ['tr'],
          'slots': 1,
          'filled': 0,
          'expiresAt': later(const Duration(hours: 3)),
          'status': 'open',
          'mine': true,
        },
      );
      server.answers['stats/online'] = (200, {'online': 7});
      final together = model.together;
      together.openFindPlayers();
      await until(() => together.findState.discovery != null);
      // How many are online now comes with the lists.
      await until(() => together.findState.online == 7);
      expect(together.onlineNowText, '7 players online now');
      together.openLfgPost('PPSA02002', 'Neon Alley');
      expect(together.findState.draft!.languages, ['tr']);
      final send = model.panelCategories().single.rows.firstWhere((row) => row.id == 'post-send');
      (send.kind as ActionRow).run();
      await until(() => model.overlay == Layer.findPlayers && model.panelCategory == 1);
      expect(model.toast, T.format('discoverPosted', ['Neon Alley']));
      expect(server.callsTo('lfg', method: 'POST').single.body['titleId'], 'PPSA02002');
      // The board and the lists are listened to while Find players is open.
      await until(() => server.frames.any((frame) => frame['op'] == 'watch'));

      server.answers['POST lfg/p7/requests'] = (
        201,
        {
          'id': 'p7',
          'author': card('u-bora', 'Bora'),
          'titleId': 'PPSA02002',
          'purpose': 'coop',
          'languages': ['en'],
          'slots': 3,
          'filled': 0,
          'expiresAt': later(const Duration(hours: 3)),
          'status': 'open',
          'myRequest': {'status': 'pending', 'invite': null},
        },
      );
      await together.imIn(post('p7', 'Bora'));
      expect(model.toast, T.format('discoverToldThem', ['Bora']));
      expect(together.findState.asked.single.standing(), LfgStanding.waiting);
    });

    test('a party\'s leader lists it in public, about the selected game', () async {
      fixture = makeFixture(together: server.base);
      model = fixture.model;
      await signInForReal();
      final together = model.together;
      model.selected = model.games.indexWhere((game) => game.titleId == 'PPSA02002');
      await together.startParty();
      model.open(Layer.party);
      PanelRow row(String id) => model.panelCategories().single.rows.firstWhere((row) => row.id == id);
      expect(model.panelCategories().single.rows.map((row) => row.id), isNot(contains('party-public-game')));
      (row('party-public').kind as ChoiceRow).set(2);
      await until(() => together.hub.parties.party?.listing != null);
      expect(server.callsTo('parties/${together.hub.parties.party!.id}', method: 'PATCH').last.body, {
        'public': {'join': 'open', 'titleId': 'PPSA02002', 'language': null},
      });
      expect(together.hub.parties.party!.listing!.open, isTrue);
      expect((row('party-public-game').kind as ChoiceRow).selected, 1);
      (row('party-public').kind as ChoiceRow).set(0);
      await until(() => together.hub.parties.party?.listing == null);
    });
  });
}
