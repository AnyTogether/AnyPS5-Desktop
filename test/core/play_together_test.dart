import 'package:anyps5_desktop/core/together/account.dart';
import 'package:anyps5_desktop/core/together/game_sessions.dart';
import 'package:anyps5_desktop/core/together/parties.dart';
import 'package:anyps5_desktop/core/together/people.dart';
import 'package:anyps5_desktop/core/together/play_together.dart';
import 'package:anyps5_desktop/core/together/socket.dart';
import 'package:anyps5_desktop/core/together/token_store.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../support/fake_together.dart';
import '../support/fixtures.dart';

Map<String, dynamic> card(String id, String name) => {'userId': id, 'handle': name.toLowerCase(), 'displayName': name};

Map<String, dynamic> lan({String rule = 'exact'}) => {
  'id': 's1',
  'kind': 'lan',
  'partyId': 'p1',
  'host': card('u1', 'Mira'),
  'titleId': 'PPSA17221',
  'gameVersion': '01.044.000',
  'engineBuild': '0.2.21-4194',
  'versionRule': rule,
  'capacity': 8,
  'joinable': true,
  'players': [card('u1', 'Mira')],
};

void main() {
  group('Play Together on the wire', () {
    test('a LAN session carries its kind, party and version rule; an older one reads as online', () {
      final session = GameSession.fromJson(lan(rule: 'major'));
      expect(session.kind, SessionKind.lan);
      expect(session.together, isTrue);
      expect(session.partyId, 'p1');
      expect(session.versionRule, 'major');
      expect(
        session.mismatch(gameVersion: '01.050.000', engineBuild: '0.2.21-4194'),
        isNull,
        reason: 'major fits',
      );
      final older = GameSession.fromJson(
        {...lan()}
          ..remove('kind')
          ..remove('partyId')
          ..remove('versionRule'),
      );
      expect(older.kind, SessionKind.online);
      expect(older.together, isFalse);
      expect(older.versionRule, 'exact');
      expect(GameSession.fromJson({...lan(), 'kind': 'hovercraft'}).kind, SessionKind.online);
    });

    test("the party carries its Play Together game; a friend's presence says they play together", () {
      final party = Party.fromJson({
        'id': 'p1',
        'leaderId': 'u1',
        'privacy': 'invite',
        'members': [card('u1', 'Mira'), card('u2', 'Utku')],
        'invited': [],
        'call': null,
        'together': {
          'sessionId': 's1',
          'hostId': 'u1',
          'titleId': 'PPSA17221',
          'gameVersion': '01.044.000',
          'engineBuild': '0.2.21-4194',
          'versionRule': 'exact',
          'players': ['u1'],
          'capacity': 8,
          'startedAt': '2026-10-26T00:00:00.000Z',
        },
      });
      expect(party.together?.sessionId, 's1');
      expect(party.together?.players, ['u1']);
      expect(party.together?.versionOverrides, isEmpty, reason: 'an older server says nothing of it');
      expect(
        PartyTogether.fromJson({
          'sessionId': 's1',
          'players': ['u1', 'u2'],
          'versionOverrides': ['u2'],
        })?.versionOverrides,
        ['u2'],
      );
      expect(party.copyWith(open: true).together?.sessionId, 's1');
      expect(Party.fromJson({'id': 'p2', 'members': [], 'invited': []}).together, isNull);

      final presence = Presence.fromJson({
        'state': 'in_game',
        'game': {
          'sessionId': 's1',
          'titleId': 'PPSA17221',
          'kind': 'lan',
          'hostId': 'u1',
          'joinable': false,
          'players': 2,
          'capacity': 8,
        },
      });
      expect(presence.game?.together, isTrue);
      expect(presence.game?.hostId, 'u1');
      expect(
        Presence.fromJson({
          'state': 'in_game',
          'game': {'sessionId': 's1', 'titleId': 'PPSA01234', 'joinable': true, 'players': 1, 'capacity': 4},
        }).game?.together,
        isFalse,
      );
    });

    test('a refused join says why and who should update', () {
      const refused = TogetherProblem(
        409,
        'version_mismatch',
        'This game needs version 01.044.000',
        extra: {'reason': 'game_version', 'expected': '01.044.000', 'actual': '01.008.000', 'update': 'you'},
      );
      final refusal = JoinRefusal.of(refused)!;
      expect(refusal.engine, isFalse);
      expect(refusal.expected, '01.044.000');
      expect(refusal.actual, '01.008.000');
      expect(refusal.youUpdate, isTrue);
      const engine = TogetherProblem(
        409,
        'version_mismatch',
        'x',
        extra: {'reason': 'engine', 'expected': '0.2.20-1', 'actual': '0.2.21-4194', 'update': 'host'},
      );
      expect(JoinRefusal.of(engine)!.engine, isTrue);
      expect(JoinRefusal.of(engine)!.youUpdate, isFalse);
      expect(refusal.overridable, isTrue, reason: 'an older server: a game version can be tried anyway');
      expect(JoinRefusal.of(engine)!.overridable, isFalse, reason: 'an engine never');
      const said = TogetherProblem(
        409,
        'version_mismatch',
        'x',
        extra: {'reason': 'game_version', 'expected': '1', 'actual': '2', 'update': 'you', 'overridable': false},
      );
      expect(JoinRefusal.of(said)!.overridable, isFalse, reason: 'the server says');
      expect(JoinRefusal.of(const TogetherProblem(409, 'full', 'Full')), isNull);
      expect(JoinRefusal.of(const TogetherProblem(409, 'version_mismatch', 'old server')), isNull);
    });
  });

  group('the join check', () {
    const offer = PlayTogetherOffer(
      sessionId: 's1',
      hostId: 'u1',
      hostName: 'Mira',
      titleId: 'PPSA17221',
      gameVersion: '01.044.000',
      engineBuild: '0.2.21-4194',
      versionRule: 'exact',
      players: 1,
      capacity: 8,
    );
    TogetherCopy copy({
      String id = 'g1',
      String version = '01.044.000',
      String engine = '0.2.21-4194',
      bool unlocked = true,
      String? next,
    }) => TogetherCopy(
      id: id,
      titleId: 'PPSA17221',
      gameVersion: version,
      engineBuild: engine,
      unlocked: unlocked,
      nextEngineBuild: next,
    );
    PlayTogetherVerdict check(
      List<TogetherCopy> copies, {
      bool signedIn = true,
      String? running,
      PlayTogetherOffer o = offer,
    }) => PlayTogetherCheck.verdict(o, signedIn: signedIn, copies: copies, running: running);

    test('trying anyway looks past the game version, never the engine', () {
      PlayTogetherVerdict? anyway(List<TogetherCopy> copies, {String? running}) =>
          PlayTogetherCheck.tryAnyway(offer, signedIn: true, copies: copies, running: running);
      expect(anyway([copy(version: '01.008.000')]), const JoinWith('g1'));
      expect(anyway([copy(version: '02.000.000', unlocked: false)]), const UnlockAndPlay('g1'));
      expect(anyway([copy()]), isNull, reason: 'nothing to try: it fits');
      expect(
        anyway([copy(version: '01.008.000', engine: '0.2.20-1')]),
        isNull,
        reason: 'another engine',
      );
      expect(
        anyway([copy(version: '01.008.000')], running: 'Stray'),
        isNull,
        reason: 'close the game first',
      );
      expect(anyway([]), isNull);
      expect(
        PlayTogetherCheck.verdict(offer, signedIn: true, copies: [copy(version: '01.008.000')], overrideVersion: true),
        const JoinWith('g1'),
      );
    });

    test('the same game version and engine joins', () {
      expect(check([copy()]), const JoinWith('g1'));
    });

    test('each blocker names what is missing, in order', () {
      expect(check([copy()], signedIn: false), const SignInFirst());
      expect(check([]), const MissingGame('PPSA17221'));
      expect(
        check([copy(version: '01.008.000')]),
        const OtherGameVersion(have: '01.008.000', need: '01.044.000', youUpdate: true),
      );
      expect(
        check([copy(version: '01.050.000')]),
        const OtherGameVersion(have: '01.050.000', need: '01.044.000', youUpdate: false),
      );
      expect(
        check([copy(engine: '0.2.22-1')]),
        const OtherEngine(have: '0.2.22-1', need: '0.2.21-4194', youUpdate: false),
      );
      expect(check([copy()], running: 'Stray'), const CloseFirst('Stray'));
      expect(check([copy()], o: offer.copyWith(players: 8)), const SessionFull());
    });

    test('another copy with the right version is picked', () {
      expect(check([copy(id: 'old', version: '01.008.000'), copy(id: 'new')]), const JoinWith('new'));
    });

    test('a locked copy is unlocked first, an older engine updated first', () {
      expect(check([copy(unlocked: false)]), const UnlockAndPlay('g1'));
      expect(check([copy(engine: '0.2.20-1', next: '0.2.21-4194')]), const UpdateAndPlay('g1'));
      expect(
        check([copy(engine: '0.2.20-1')]),
        const OtherEngine(have: '0.2.20-1', need: '0.2.21-4194', youUpdate: true),
      );
    });

    test("the host's version rule", () {
      expect(check([copy(version: '01.050.000')], o: offer.copyWith(versionRule: 'major')), const JoinWith('g1'));
      expect(versionFits('major', '01.044.000', '02.000.000'), isFalse);
      expect(versionFits('any', '01.044.000', '09.000.000'), isTrue);
      expect(versionFits('exact', '01.044.000', '01.044.001'), isFalse);
      expect(compareVersions('01.010', '01.9'), 1);
      expect(compareVersions('0.2.21-4194', '0.2.20-5000'), 1);
    });

    test('an offer from a session, and from the party', () {
      final made = PlayTogetherOffer.fromSession(GameSession.fromJson(lan()));
      expect(made.hostName, 'Mira');
      expect(made.players, 1);
      expect(made.capacity, 8);
      const together = PartyTogether(
        sessionId: 's1',
        hostId: 'u1',
        titleId: 'PPSA17221',
        gameVersion: '01.044.000',
        engineBuild: '0.2.21-4194',
        players: ['u1', 'u2'],
        capacity: 8,
      );
      final fromParty = PlayTogetherOffer.fromParty(together, const [
        Person(id: 'u1', handle: 'mira', displayName: 'Mira'),
      ]);
      expect(fromParty.hostName, 'Mira');
      expect(fromParty.players, 2);
      final named = PlayTogetherOffer.fromParty(together, const [
        Person(id: 'u1', handle: 'mira', displayName: 'Mira'),
      ], name: (person) => 'Mira T.');
      expect(named.hostName, 'Mira T.', reason: "the friend's private name, as shown here");
    });
  });

  test('trying anyway sends the override with the join, only when asked', () async {
    final server = await FakeTogether.start();
    final folder = temporaryFolder('anyway');
    final account = TogetherAccount(
      base: server.base,
      store: MemoryTokenStore(),
      clientName: 'launcher-linux/0.1.0 (test)',
    );
    addTearDown(() async {
      account.close();
      await server.close();
    });
    await account.startEmail('utku@example.com');
    await account.verifyEmail('123456');
    server.answers['POST game-sessions/s1/join'] = (200, lan());
    final games = GameSessions(
      account: account,
      socket: TogetherSocket(account: account),
      bridgeFile: path.join(folder.path, 'game-session.json'),
    );
    await games.join('s1', gameVersion: '01.008.000', engineBuild: '0.2.21-4194', overrideVersion: true);
    expect(server.callsTo('game-sessions/s1/join').last.body, {
      'gameVersion': '01.008.000',
      'engineBuild': '0.2.21-4194',
      'overrideVersion': true,
    });
    await games.join('s1', gameVersion: '01.044.000', engineBuild: '0.2.21-4194');
    expect(server.callsTo('game-sessions/s1/join').last.body.containsKey('overrideVersion'), isFalse);
  });
}
