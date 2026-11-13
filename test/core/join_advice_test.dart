import 'package:anyps5_desktop/core/together/game_sessions.dart';
import 'package:anyps5_desktop/core/together/join_advice.dart';
import 'package:anyps5_desktop/core/together/parties.dart';
import 'package:anyps5_desktop/core/together/people.dart';
import 'package:anyps5_desktop/core/together/play_together.dart';
import 'package:test/test.dart';

/// Two launchers on the same release could not play Greenhollow together: one copy had been made
/// by the nightly engine before the launcher was updated and was started as it was, the message
/// read "arm-ni … arm-f7, update" although both launchers were current, and Play from the library
/// while in a party opened a second session instead of joining the friend's (JoinAdviceTests on
/// the Mac).
void main() {
  const nightly = '0.2.36-arm-nightly.20261110.1-a6fff1ba742d';
  const stable = '0.2.36-arm-f75c475400e3';
  const me = Person(id: 'me', handle: 'robin', displayName: 'Robin');
  const mira = Person(id: 'u1', handle: 'mira', displayName: 'Mira');

  GameSession session(String id, Person host, List<Person> players, {String title = 'FAKE18847'}) => GameSession(
    id: id,
    host: host,
    titleId: title,
    gameVersion: '01.000',
    engineBuild: stable,
    capacity: 4,
    joinable: true,
    players: players,
  );

  PresenceGame game(
    String id, {
    String title = 'FAKE18847',
    bool joinable = true,
    int players = 1,
    String? kind = 'online',
    String? hostId,
  }) => PresenceGame(
    sessionId: id,
    titleId: title,
    joinable: joinable,
    players: players,
    capacity: 4,
    kind: kind,
    hostId: hostId,
  );

  Friend friend(String id, PresenceGame? playing) =>
      Friend(Person(id: id, handle: id, displayName: id), Presence(state: PresenceState.online, game: playing));

  Party party(List<Person> members, {PartyTogether? together}) => Party(
    id: 'p1',
    leaderId: 'me',
    open: false,
    members: members,
    invited: const [],
    callId: null,
    inCall: const {},
    together: together,
  );

  test('a copy made by another engine than the one at hand is rebuilt', () {
    expect(
      StaleCopy.needsRebuild(built: nightly, current: stable),
      isTrue,
      reason: 'the engine was updated since the copy was made',
    );
    expect(StaleCopy.needsRebuild(built: stable, current: stable), isFalse);
    expect(
      StaleCopy.needsRebuild(built: stable, current: '0.2.35-arm-0123456789ab'),
      isTrue,
      reason: "a game's own older engine counts as well",
    );
    expect(StaleCopy.needsRebuild(built: null, current: stable), isFalse, reason: 'not unlocked: nothing to rebuild');
    expect(StaleCopy.needsRebuild(built: nightly, current: null), isFalse, reason: 'no engine at hand');
  });

  test('the release of a build is the build without its fingerprint', () {
    expect(engineRelease(stable), '0.2.36-arm');
    expect(engineRelease(nightly), '0.2.36-arm-nightly.20261110.1');
    expect(engineRelease('upstream-v0.1.3'), 'upstream-v0.1.3');
    expect(engineRelease('toolkit-1'), 'toolkit-1');
  });

  test('a stale copy against the engine at hand is rebuilt, never updated', () {
    final advice = EngineAdvice.of(yours: nightly, host: stable, rebuildGives: stable);
    expect(advice, EngineAdvice.rebuild);
    expect(advice.youUpdate, isFalse);
  });

  test('who is behind is read from the releases, not the fingerprints', () {
    // The joiner on the release, the host's copy still the nightly's: the host is behind.
    expect(EngineAdvice.of(yours: stable, host: nightly), EngineAdvice.updateHost);
    // Comparing every number in the two builds called the release older ("update").
    expect(compareVersions(stable, nightly), lessThan(0));
    expect(EngineAdvice.of(yours: nightly, host: stable), EngineAdvice.updateYours);
    expect(EngineAdvice.of(yours: '0.2.35-arm-0123456789ab', host: stable), EngineAdvice.updateYours);
    expect(
      EngineAdvice.of(yours: stable, host: '0.2.37-arm-nightly.20261112.1-0123456789ab'),
      EngineAdvice.hostNightly,
    );
    expect(
      EngineAdvice.of(yours: stable, host: '0.2.36-arm-0123456789ab'),
      EngineAdvice.sameEngine,
      reason: 'one release, two builds: nobody updates',
    );
    expect(EngineAdvice.of(yours: 'local-0123456789ab', host: stable), EngineAdvice.sameEngine);
    expect(EngineAdvice.of(yours: 'toolkit-1', host: '0.2.13-a1b2c3d4e5f6'), EngineAdvice.sameEngine);
    // A stale copy whose rebuild still would not reach the host's: the engine at hand counts.
    expect(
      EngineAdvice.of(yours: nightly, host: '0.2.37-arm-0123456789ab', rebuildGives: stable),
      EngineAdvice.updateYours,
    );
    expect(
      EngineAdvice.of(yours: nightly, host: '0.2.35-arm-0123456789ab', rebuildGives: stable),
      EngineAdvice.updateHost,
    );
  });

  test('the check no longer tells the newer side to update', () {
    const offer = PlayTogetherOffer(
      sessionId: 's1',
      hostId: 'u1',
      hostName: 'Mira',
      titleId: 'FAKE18847',
      gameVersion: '01.000',
      engineBuild: nightly,
      versionRule: 'exact',
      players: 1,
      capacity: 4,
    );
    const mine = TogetherCopy(
      id: 'g1',
      titleId: 'FAKE18847',
      gameVersion: '01.000',
      engineBuild: stable,
      unlocked: true,
    );
    expect(
      PlayTogetherCheck.verdict(offer, signedIn: true, copies: const [mine]),
      const OtherEngine(have: stable, need: nightly, youUpdate: false),
    );
    // The other way round, the stale copy is rebuilt and joins in one press.
    const current = PlayTogetherOffer(
      sessionId: 's1',
      hostId: 'u1',
      hostName: 'Mira',
      titleId: 'FAKE18847',
      gameVersion: '01.000',
      engineBuild: stable,
      versionRule: 'exact',
      players: 1,
      capacity: 4,
    );
    const stale = TogetherCopy(
      id: 'g1',
      titleId: 'FAKE18847',
      gameVersion: '01.000',
      engineBuild: nightly,
      unlocked: true,
      nextEngineBuild: stable,
    );
    expect(PlayTogetherCheck.verdict(current, signedIn: true, copies: const [stale]), const UpdateAndPlay('g1'));
  });

  test('a member is in your game, in another one, or in none', () {
    final mine = session('s1', me, const [me]);
    final theirs = game('s2', hostId: 'u1');
    // Both in the party, each hosting a session of the same title: the case that went unsaid.
    expect(
      MemberGame.of('u1', mine: mine, together: null, presence: theirs, friend: true),
      const InOtherGame(
        sessionId: 's2',
        titleId: 'FAKE18847',
        hostId: 'u1',
        joinable: true,
        together: false,
        sameTitle: true,
      ),
    );
    expect(
      MemberGame.of('u1', mine: session('s1', me, const [me, mira]), together: null, presence: null, friend: true),
      const InYourGame(),
    );
    expect(
      MemberGame.of('u1', mine: null, together: null, presence: theirs, friend: true),
      const InOtherGame(
        sessionId: 's2',
        titleId: 'FAKE18847',
        hostId: 'u1',
        joinable: true,
        together: false,
        sameTitle: false,
      ),
    );
    expect(MemberGame.of('u1', mine: mine, together: null, presence: null, friend: true), const InNoGame());
    expect(
      MemberGame.of('u1', mine: mine, together: null, presence: null, friend: false),
      isNull,
      reason: 'nothing is known of someone who is no friend',
    );
    const together = PartyTogether(
      sessionId: 's3',
      hostId: 'u1',
      titleId: 'PPSA17221',
      gameVersion: '01.000',
      engineBuild: stable,
      players: ['u1'],
      capacity: 2,
    );
    expect(
      MemberGame.of('u1', mine: mine, together: together, presence: null, friend: false),
      const InOtherGame(
        sessionId: 's3',
        titleId: 'PPSA17221',
        hostId: 'u1',
        joinable: true,
        together: true,
        sameTitle: false,
      ),
    );
    expect(
      MemberGame.of('u1', mine: null, together: null, presence: game('s2', players: 4, kind: null), friend: true),
      const InOtherGame(
        sessionId: 's2',
        titleId: 'FAKE18847',
        hostId: 'u1',
        joinable: false,
        together: false,
        sameTitle: false,
      ),
    );
  });

  test('Play on a game a friend hosts offers theirs', () {
    final hosting = [friend('u1', game('s2', hostId: 'u1'))];
    expect(
      JoinableGame.find(titleId: 'FAKE18847', me: 'me', mine: null, party: party(const [me, mira]), friends: hosting),
      const JoinableGame(sessionId: 's2', titleId: 'FAKE18847', personId: 'u1', together: false),
    );
    expect(
      JoinableGame.find(titleId: 'PPSA17221', me: 'me', mine: null, party: null, friends: hosting),
      isNull,
      reason: 'another title',
    );
    expect(
      JoinableGame.find(titleId: 'FAKE18847', me: 'me', mine: 's2', party: null, friends: hosting),
      isNull,
      reason: 'already in it',
    );
  });

  test('only a game with room that lets others in is offered', () {
    final friends = [
      friend('u1', game('s2', joinable: false)),
      friend('u2', game('s3', players: 4)),
      friend('u3', null),
    ];
    expect(JoinableGame.find(titleId: 'FAKE18847', me: 'me', mine: null, party: null, friends: friends), isNull);
  });

  test("the party's Play Together game comes first, then a party member's, then any friend's", () {
    const together = PartyTogether(
      sessionId: 's9',
      hostId: 'u1',
      titleId: 'FAKE18847',
      gameVersion: '01.000',
      engineBuild: stable,
      players: ['u1'],
      capacity: 8,
    );
    final friends = [friend('u7', game('s4')), friend('u1', game('s2'))];
    expect(
      JoinableGame.find(
        titleId: 'FAKE18847',
        me: 'me',
        mine: null,
        party: party(const [me, mira], together: together),
        friends: friends,
      ),
      const JoinableGame(sessionId: 's9', titleId: 'FAKE18847', personId: 'u1', together: true),
    );
    expect(
      JoinableGame.find(
        titleId: 'FAKE18847',
        me: 'me',
        mine: null,
        party: party(const [me, mira]),
        friends: friends,
      )?.sessionId,
      's2',
      reason: 'the party member before another friend',
    );
    expect(
      JoinableGame.find(titleId: 'FAKE18847', me: 'me', mine: null, party: null, friends: friends)?.sessionId,
      's4',
    );
    // The user's own Play Together game is never offered back to them.
    const own = PartyTogether(
      sessionId: 's9',
      hostId: 'me',
      titleId: 'FAKE18847',
      gameVersion: '01.000',
      engineBuild: stable,
      players: ['me'],
      capacity: 8,
    );
    expect(
      JoinableGame.find(
        titleId: 'FAKE18847',
        me: 'me',
        mine: null,
        party: party(const [me, mira], together: own),
        friends: const [],
      ),
      isNull,
    );
  });
}
