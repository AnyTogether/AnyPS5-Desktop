import 'package:anyps5_desktop/core/online/online_peer_mesh.dart';
import 'package:anyps5_desktop/core/together/people.dart';
import 'package:anyps5_desktop/ui/app_model.dart' hide Command, GameState;
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:anyps5_desktop/ui/together_model.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_together.dart';
import '../support/ui_support.dart';
import 'desktop_features_test.dart' show FakeDesktop;

/// Play Together as on the Mac: the words over a game for an offer or an invite, and how a
/// player is reached.
void main() {
  late FakeTogether server;
  late Fixture fixture;
  late AppModel model;
  late FakeDesktop desktop;

  final ana = FakeTogether.card('u-ana', 'ana', 'Ana');

  Future<void> until(bool Function() condition) async {
    for (var tries = 0; tries < 300 && !condition(); tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(condition(), isTrue);
  }

  Future<void> signedIn({bool focused = false}) async {
    server = await FakeTogether.start();
    server.friend('u-ana', 'ana', 'Ana', presence: {'state': 'online'});
    desktop = FakeDesktop()..focused = focused;
    fixture = makeFixture(together: server.base, desktop: desktop);
    model = fixture.model;
    model.together.email = 'utku@example.com';
    await model.together.sendCode();
    model.together.code = '123456';
    await model.together.verify();
    await until(() => model.together.hub.parties.loaded && model.together.hub.messages.loaded);
    addTearDown(() async {
      model.dispose();
      await server.close();
      fixture.dispose();
    });
  }

  Future<void> offerArrives() async {
    server.inParty([ana], leader: 'u-ana');
    await model.together.hub.parties.refresh();
    final lan = server.hostSession('gs-lan', ana, kind: 'lan');
    server.push('game_session.started', {'partyId': server.party!['id'], 'session': lan});
    await until(() => model.toast == 'Ana started Orbit Runner — Join');
  }

  Future<void> inviteArrives() async {
    final invite = {
      'sessionId': 'gs-ana',
      'from': ana,
      'titleId': 'PPSA01001',
      'gameVersion': '01.000.000',
      'engineBuild': 'toolkit-1',
    };
    server.gameInvites.add(invite);
    server.push('game_session.invite', invite);
    await until(() => model.together.hub.games.invites.isNotEmpty);
  }

  test('a Play Together offer is said over a game', () async {
    await signedIn();
    await offerArrives();
    await until(() => desktop.calls.contains('notify ${T.text('togetherOfferDetail')}'));
  });

  test('a game invite is said over a game', () async {
    await signedIn();
    await inviteArrives();
    await until(() => desktop.calls.contains('notify ${T.text('friendsTitle')}'));
  });

  test('Do Not Disturb keeps them off the game', () async {
    await signedIn();
    model.together.hub.self.status = PresenceStatus.dnd;
    await offerArrives();
    await inviteArrives();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(desktop.calls.where((call) => call.startsWith('notify')), isEmpty);
  });

  test('with the launcher in front nothing more is added', () async {
    await signedIn(focused: true);
    await offerArrives();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(desktop.calls.where((call) => call.startsWith('notify')), isEmpty);
  });

  test('a connected player reads Direct or Relay with the round trip, and only what the statistics said', () {
    expect(TogetherPlay.linkWords(const PeerPath(PeerRoute.direct, 23)), 'Direct · 23 ms');
    expect(TogetherPlay.linkWords(const PeerPath(PeerRoute.relay)), 'Relay');
    expect(TogetherPlay.linkWords(const PeerPath(PeerRoute.connected)), 'Connected');
    expect(TogetherPlay.linkWords(null), 'Connected');
    addTearDown(() => T.language = Language.english);
    T.language = Language.byCode('tr');
    expect(TogetherPlay.linkWords(const PeerPath(PeerRoute.direct, 23)), 'Doğrudan · 23 ms');
  });
}
