import 'package:anyps5_desktop/core/together/people.dart';
import 'package:anyps5_desktop/ui/app_model.dart' hide Command, GameState;
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_audio.dart';
import '../support/fake_together.dart';
import '../support/ui_support.dart';
import 'desktop_features_test.dart' show FakeDesktop;

/// The sounds of what friends do, as on the Mac: a message ticks, and behind another window a
/// request, an invite or a message brings the notice's sound. Do Not Disturb keeps those quiet,
/// as the Mac does (its message tick and its notices are skipped then); someone answering what
/// the user asked for still sounds.
void main() {
  late FakeTogether server;
  late Fixture fixture;
  late AppModel model;
  late FakeAudio audio;

  final ana = FakeTogether.card('u-ana', 'ana', 'Ana');

  Future<void> until(bool Function() condition) async {
    for (var tries = 0; tries < 300 && !condition(); tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(condition(), isTrue);
  }

  setUp(() async {
    server = await FakeTogether.start();
    server.friend('u-ana', 'ana', 'Ana', presence: {'state': 'online'});
    server.conversation('c-ana', [ana]);
    audio = FakeAudio();
    fixture = makeFixture(together: server.base, desktop: FakeDesktop()..focused = false, audio: audio);
    model = fixture.model;
    await model.startAudio();
    model.together.email = 'utku@example.com';
    await model.together.sendCode();
    model.together.code = '123456';
    await model.together.verify();
    await until(() => model.together.hub.parties.loaded && model.together.hub.messages.loaded);
    // Behind another window, no game running: the interface sounds are not muted.
    model.setActive(false);
    audio.voices.clear();
  });

  tearDown(() async {
    model.dispose();
    await server.close();
    fixture.dispose();
  });

  Future<void> messageArrives() async {
    server.receive('c-ana', 'u-ana', 'Up for a round?');
    await until(() => model.toast == 'Ana: Up for a round?');
  }

  Future<void> everyoneAsks() async {
    server.inParty([ana], leader: 'u-ana');
    await model.together.hub.parties.refresh();
    server.push('game_session.started', {
      'partyId': server.party!['id'],
      'session': server.hostSession('gs-lan', ana, kind: 'lan'),
    });
    await until(() => model.toast == 'Ana started Orbit Runner — Join');
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
    server.push('friend.request', FakeTogether.card('u-eda', 'eda', 'Eda'));
    await until(() => model.toast == 'Eda wants to be friends');
    server.push('party.invite', {'partyId': 'p-ana', 'from': ana, 'size': 2});
    await until(() => model.together.hub.parties.invites.isNotEmpty);
    server.push('share_play.invite', {
      'sharePlayId': 'sp-9',
      'from': ana,
      'titleId': 'PPSA02002',
      'title': 'Neon Alley',
    });
    await until(() => model.sharePlay.invites.isNotEmpty);
    await messageArrives();
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }

  test('a message behind another window: the tick and the notice sound', () async {
    await messageArrives();
    expect(audio.cues, ['move', 'unlocked']);
  });

  test('a share play invite behind another window brings the notice sound, as on the Mac', () async {
    server.push('share_play.invite', {
      'sharePlayId': 'sp-9',
      'from': ana,
      'titleId': 'PPSA02002',
      'title': 'Neon Alley',
    });
    await until(() => model.sharePlay.invites.isNotEmpty);
    expect(audio.cues, ['unlocked']);
  });

  test('Do Not Disturb: messages, requests and invites come without a sound, as on the Mac', () async {
    model.together.hub.self.status = PresenceStatus.dnd;
    await everyoneAsks();
    expect(audio.cues, isEmpty);
    expect(model.toast, 'Ana: Up for a round?', reason: 'the toast still says it');
  });

  test('Do Not Disturb: someone in for a post still sounds, as on the Mac', () async {
    model.together.hub.self.status = PresenceStatus.dnd;
    server.push('lfg.request', {'postId': 'lfg-1', 'from': ana, 'titleId': 'PPSA01001'});
    await until(() => model.toast == 'Ana is in for Orbit Runner');
    expect(audio.cues, ['unlocked']);
  });
}
