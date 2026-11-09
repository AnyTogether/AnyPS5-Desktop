import 'package:anyps5_desktop/ui/app_model.dart' hide Command, GameState;
import 'package:anyps5_desktop/ui/app_model.dart' as launcher show Command;
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:anyps5_desktop/ui/together_model.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_together.dart';
import '../support/ui_support.dart';

/// Calls with one friend in the launcher, as on the Mac: a call ringing here (Enter answers,
/// Back declines, unanswered it is a missed call), calling an online friend from the Friends
/// panel, and the call's rows there with Hang up.
void main() {
  late FakeTogether server;
  late Fixture fixture;
  late AppModel model;

  Future<void> until(bool Function() condition) async {
    for (var tries = 0; tries < 300 && !condition(); tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(condition(), isTrue);
  }

  Map<String, dynamic> joined(String id) => {
    'call': {
      'id': id,
      'kind': 'direct',
      'partyId': null,
      'in': [
        {'userId': 'u-ana', 'device': 'device-ana', 'muted': false, 'deafened': false},
      ],
    },
    'iceServers': const [],
    'expiresAt': null,
  };

  List<String> rowIds() => model.panelCategories().single.rows.map((row) => row.id).toList();

  PanelRow row(String id) => model.panelCategories().single.rows.firstWhere((row) => row.id == id);

  setUp(() async {
    server = await FakeTogether.start();
    server
      ..friend('u-ana', 'ana', 'Ana', presence: {'state': 'online'})
      ..friend('u-cem', 'cem', 'Cem');
    fixture = makeFixture(together: server.base);
    model = fixture.model;
    model.together.email = 'utku@example.com';
    await model.together.sendCode();
    model.together.code = '123456';
    await model.together.verify();
    await until(() => model.together.hub.friends.loaded && model.together.hub.socket.status.name == 'ready');
  });

  tearDown(() async {
    model.dispose();
    await server.close();
    T.language = Language.english;
    fixture.dispose();
  });

  Map<String, dynamic> ringing(String id) => {
    'callId': id,
    'from': FakeTogether.card('u-ana', 'ana', 'Ana'),
    'device': 'device-ana',
  };

  test('a call rings here: Enter answers it, and the Friends panel has the call with Hang up', () async {
    final together = model.together;
    server.push('call.ringing', ringing('call-1'));
    await until(() => together.ringing != null);
    expect(together.ringing!.from.displayName, 'Ana');
    server.answers['POST calls/call-1/answer'] = (200, joined('call-1'));
    model.handle(launcher.Command.select);
    await until(() => together.hub.voice.active);
    expect(together.ringing, isNull);
    expect(server.callsTo('calls/call-1/answer'), hasLength(1));
    await until(() => model.toast == 'In a call with Ana');

    model.open(Layer.friends);
    expect(rowIds().take(5), ['call-u-ana', 'voice-mic', 'voice-noise', 'voice-deafen', 'voice-ptt']);
    expect(row('call-u-ana').title, 'In a call with Ana');
    expect(row('voice-leave').title, 'Hang up');
    expect(rowIds(), isNot(contains('friend-call-u-ana')), reason: 'in a call with her already');
    (row('voice-leave').kind as ActionRow).run();
    await until(() => server.callsTo('calls/call-1/leave').isNotEmpty);
    expect(together.hub.voice.active, isFalse);
  });

  test('Back declines; a call that stops ringing unanswered is a missed call', () async {
    final together = model.together;
    server.answers['POST calls/call-2/decline'] = (204, null);
    server.push('call.ringing', ringing('call-2'));
    await until(() => together.ringing != null);
    model.handle(launcher.Command.back);
    expect(together.ringing, isNull);
    await until(() => server.callsTo('calls/call-2/decline').isNotEmpty);

    server.push('call.ringing', ringing('call-3'));
    await until(() => together.ringing?.callId == 'call-3');
    server.push('call.ended', {'callId': 'call-3', 'reason': 'missed'});
    await until(() => together.ringing == null);
    expect(model.toast, 'Missed call from Ana');

    // Answered on another device: it stops here and says nothing.
    server.push('call.ringing', ringing('call-4'));
    await until(() => together.ringing?.callId == 'call-4');
    model.show('Something else');
    server.push('call.answered', {'callId': 'call-4', 'userId': 'u-me'});
    await until(() => together.ringing == null);
    expect(model.toast, 'Something else');
  });

  test('an online friend can be called from the Friends panel; a decline is said', () async {
    final together = model.together;
    model.open(Layer.friends);
    expect(rowIds(), containsAllInOrder(['friend-u-ana', 'friend-call-u-ana']));
    expect(rowIds(), isNot(contains('friend-call-u-cem')), reason: 'Cem is offline');
    expect(row('friend-call-u-ana').title, 'Call Ana');
    server.answers['POST calls'] = (201, joined('call-5'));
    (row('friend-call-u-ana').kind as ActionRow).run();
    await until(() => together.hub.voice.active);
    expect(server.callsTo('calls').single.body, {'userId': 'u-ana'});
    expect(model.toast, 'Calling Ana…');
    expect(row('call-u-ana').title, 'Calling Ana…');
    server.push('call.answered', {'callId': 'call-5', 'userId': 'u-ana'});
    await until(() => !together.hub.voice.waiting);
    expect(model.toast, 'In a call with Ana');
    server.push('call.ended', {'callId': 'call-5', 'reason': 'declined'});
    await until(() => !together.hub.voice.active);
    expect(model.toast, 'Ana declined the call');
  });
}
