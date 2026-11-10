import 'package:anyps5_desktop/core/gamepad/pad_navigation.dart';
import 'package:anyps5_desktop/core/together/people.dart';
import 'package:anyps5_desktop/ui/app_model.dart' hide Command, GameState;
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_audio.dart';
import '../support/fake_together.dart';
import '../support/ui_support.dart';
import 'desktop_features_test.dart' show FakeDesktop, FakePads;

/// A game invite, a party invite and a Play Together offer ring on the controller, as on the
/// Mac; none of them on Do Not Disturb, and nothing with Controller Vibration off.
void main() {
  late FakeTogether server;
  late Fixture fixture;
  late AppModel model;
  late FakePads pads;

  final ana = FakeTogether.card('u-ana', 'ana', 'Ana');

  /// The ring's two beats on the pad, each followed by its stop.
  const ring = ['pad 0.7 0.3 80', 'pad 0.0 0.0 0', 'pad 0.25 0.35 50', 'pad 0.0 0.0 0'];

  Future<void> until(bool Function() condition) async {
    for (var tries = 0; tries < 300 && !condition(); tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(condition(), isTrue);
  }

  /// What the motors were set to since the last look, once the longest pattern has ended.
  Future<List<String>> felt() async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final seen = [...pads.rumbles];
    pads.rumbles.clear();
    return seen;
  }

  setUp(() async {
    server = await FakeTogether.start();
    server.friend('u-ana', 'ana', 'Ana', presence: {'state': 'online'});
    pads = FakePads();
    fixture = makeFixture(together: server.base, desktop: FakeDesktop(), pads: () => pads, audio: FakeAudio());
    model = fixture.model..startPads();
    await model.startAudio();
    model.together.email = 'utku@example.com';
    await model.together.sendCode();
    model.together.code = '123456';
    await model.together.verify();
    await until(() => model.together.hub.parties.loaded);
    // The launcher in front with the controller in hand.
    pads.press(PadButton.dpadRight);
    await felt();
  });

  tearDown(() async {
    model.dispose();
    await server.close();
    fixture.dispose();
  });

  Future<void> gameInvite() async {
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

  Future<void> partyInvite() async {
    server.push('party.invite', {'partyId': 'p-ana', 'from': ana, 'size': 2});
    await until(() => model.together.hub.parties.invites.isNotEmpty);
  }

  Future<void> playTogetherOffer() async {
    server.inParty([ana], leader: 'u-ana');
    await model.together.hub.parties.refresh();
    server.push('game_session.started', {
      'partyId': server.party!['id'],
      'session': server.hostSession('gs-lan', ana, kind: 'lan'),
    });
    await until(() => model.toast == 'Ana started Orbit Runner — Join');
  }

  // In the order the Do Not Disturb sounds test brings them.
  final invites = {'Play Together offer': playTogetherOffer, 'game invite': gameInvite, 'party invite': partyInvite};

  test('every invite rings on the controller', () async {
    for (final MapEntry(key: name, value: arrives) in invites.entries) {
      await arrives();
      expect(await felt(), ring, reason: name);
    }
  });

  test('Do Not Disturb keeps the controller still, as on the Mac', () async {
    model.together.hub.self.status = PresenceStatus.dnd;
    for (final MapEntry(key: name, value: arrives) in invites.entries) {
      await arrives();
      expect(await felt(), isEmpty, reason: name);
    }
    expect(model.together.hub.games.invites, isNotEmpty, reason: 'the invite still comes in');
  });

  test('Controller Vibration off keeps the controller still', () async {
    model.open(Layer.settings);
    final behaviour = model.panelCategories().firstWhere((category) => category.id == 'general');
    (behaviour.rows.firstWhere((row) => row.id == 'vibration').kind as ToggleRow).set(false);
    expect(model.preferences.controllerVibration, isFalse);
    model.closeOverlay();
    await felt();
    for (final MapEntry(key: name, value: arrives) in invites.entries) {
      await arrives();
      expect(await felt(), isEmpty, reason: name);
    }
  });
}
