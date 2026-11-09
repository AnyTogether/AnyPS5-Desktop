import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/family/family_cache.dart';
import 'package:anyps5_desktop/core/installer.dart';
import 'package:anyps5_desktop/core/desktop/desktop.dart';
import 'package:anyps5_desktop/core/together/account.dart';
import 'package:anyps5_desktop/core/trophies.dart';
import 'package:anyps5_desktop/ui/app_model.dart' hide Command, GameState;
import 'package:anyps5_desktop/ui/family_gate.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:anyps5_desktop/ui/together_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_together.dart';
import '../support/family_signer.dart';
import '../support/ui_support.dart';

/// Family limits in the launcher: a child signed in on AnyTogether, the status the fake server
/// signs, and what the launcher does with it.
void main() {
  late FakeTogether server;
  late Fixture fixture;
  late AppModel model;
  final signer = FamilySigner('server key');
  final notices = <String>[];

  Future<void> until(bool Function() condition, {int tries = 300}) async {
    for (var tried = 0; tried < tries && !condition(); tried++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(condition(), isTrue);
  }

  /// What the server answers for the child from now on.
  void status(Map<String, Object?> json) => server.answers['GET me/family/restrictions'] = (200, signer.response(json));

  /// Every day [limit] minutes, [played] seconds of them played today.
  Map<String, Object?> limited({required int limit, int played = 0, String whenLimitReached = 'close'}) =>
      FamilySigner.childStatus(
        issuedAt: DateTime.now(),
        playTime: true,
        played: played,
        whenLimitReached: whenLimitReached,
        days: {
          for (final day in ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'])
            day: {'limitMinutes': limit, 'from': null, 'until': null},
        },
      );

  List<Map<String, dynamic>> requests() => [for (final call in server.callsTo('me/family/requests')) call.body];

  Future<void> signIn() async {
    model.together.email = 'kid@example.com';
    await model.together.sendCode();
    model.together.code = '123456';
    await model.together.verify();
    await until(() => model.together.family.restricted);
  }

  setUp(() async {
    server = await FakeTogether.start();
    server.me = {'id': 'u-kid', 'handle': 'kid', 'displayName': 'Kid'};
    server.answers['GET .well-known/jwks.json'] = (200, signer.jwks);
    server.answers['POST me/family/requests'] = (201, {'id': 'r-1', 'status': 'pending'});
    server.answers['POST me/family/limit-reached'] = (204, null);
    status(FamilySigner.childStatus(issuedAt: DateTime.now()));
    fixture = makeFixture(together: server.base);
    model = fixture.model;
    // Quiet Forest is rated 16 (12 in Germany); the others have no rating.
    final forest = model.games.firstWhere((game) => game.titleId == 'PPSA03003');
    final param = File(p.join(forest.folder, 'sce_sys', 'param.json'));
    final json = jsonDecode(param.readAsStringSync()) as Map<String, dynamic>;
    param.writeAsStringSync(
      jsonEncode({
        ...json,
        'ageLevel': {'default': 16, 'DE': 12},
      }),
    );
    model.rescan();
    notices.clear();
    model.together.family.notify = (title, body) => notices.add(body);
  });

  tearDown(() async {
    model.dispose();
    await server.close();
    T.language = Language.english;
    fixture.dispose();
  });

  test('with the family media setting off, no picture is taken for a trophy, as on the Mac', () async {
    model.dispose();
    fixture.dispose();
    final desktop = _CountingDesktop();
    fixture = makeFixture(
      together: server.base,
      desktop: desktop,
      renderTrophyCard: (trophy, scale) async => RgbaImage(1, 1, Uint8List.fromList([1, 2, 3, 4])),
    );
    model = fixture.model;
    await signIn();
    expect(model.together.family.mediaAllowed, isFalse);
    final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
    const trophy = Trophy(serviceLabel: 0, number: 3, grade: TrophyGrade.bronze, hidden: false, name: 'A', detail: '');
    await model.celebrate(orbit, trophy, 1);
    expect(desktop.captures, 0);
    expect(model.trophyShots, isEmpty);
  });

  test('a game rated above the limit is locked; asking a parent teaches its rating first', () async {
    await signIn();
    final forest = model.games.firstWhere((game) => game.titleId == 'PPSA03003');
    final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
    expect(model.stateOf(forest), isA<FamilyLocked>());
    expect(model.stateOf(orbit), isA<Installed>());
    model.primaryAction(forest);
    await until(() => requests().isNotEmpty);
    expect(requests().single, {'kind': 'play_game', 'titleId': 'PPSA03003', 'name': 'Quiet Forest'});
    expect(server.games['PPSA03003'], {
      'names': {'en': 'Quiet Forest'},
      'ageLevels': {'default': 16, 'DE': 12},
    });
    await until(() => model.toast == 'Asked a parent to let you play Quiet Forest');
    // The parent said yes: the game is allowed whatever its rating.
    final approved = FamilySigner.childStatus(issuedAt: DateTime.now());
    (approved['restrictions'] as Map<String, Object?>)['allowedTitles'] = ['PPSA03003'];
    status(approved);
    await model.together.family.refresh();
    expect(model.stateOf(forest), isNot(isA<FamilyLocked>()));
  });

  test('with the time used up, a game does not start: the family panel asks for more', () async {
    status(limited(limit: 30, played: 1800));
    await signIn();
    final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
    await model.play(orbit);
    expect(model.running, isNull);
    expect(model.starting, isNull);
    expect(model.toast, 'Ask a parent for more time');
    expect(model.overlay, Layer.family);
    final rows = model.panelCategories().single.rows;
    expect(rows.first.title, "Time's up for today");
    final ask = rows.firstWhere((row) => row.id == 'family-ask').kind as ActionRow;
    ask.run();
    await until(() => requests().isNotEmpty);
    expect(requests().single, {'kind': 'more_time', 'minutes': 30, 'titleId': 'PPSA01001'});
    await until(() => model.toast == 'Asked a parent for 30 more minutes');
    // The extra time came: the game starts, with the time left said.
    final more = limited(limit: 30, played: 1800);
    (more['today'] as Map<String, Object?>)['bonusMinutes'] = 30;
    status(more);
    await model.play(orbit);
    await until(() => model.running == null && model.starting == null);
    expect(server.callsTo('me/family/restrictions').length, greaterThanOrEqualTo(3));
  });

  test('time running out while playing, with no grace: the notice, the parents told, the game closed', () async {
    final json = limited(limit: 1, played: 57);
    ((json['restrictions'] as Map<String, Object?>)['playTime'] as Map<String, Object?>)['graceMinutes'] = 0;
    status(json);
    await signIn();
    final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
    final installed = Installer.installedFolder(orbit, model.root!);
    File(p.join(installed, 'app.elf')).writeAsStringSync('#!/bin/sh\nexec sleep 30\n');
    if (!Platform.isWindows) Process.runSync('chmod', ['755', p.join(installed, 'app.elf')]);
    final playing = model.play(orbit);
    await until(() => model.running != null);
    await until(() => model.running == null, tries: 1000);
    await playing;
    expect(notices, ['One minute left: time to save', "Time's up. The game closes now"]);
    expect(model.overlay, Layer.family);
    await until(() => server.callsTo('me/family/limit-reached').isNotEmpty);
    expect(server.callsTo('me/family/limit-reached').single.body, {'titleId': 'PPSA01001'});
    // The play counts here until the server has it.
    final kept = model.together.family.kept as FamilyCacheKept;
    expect(kept.plays, hasLength(1));
  });

  test("a parent's rule against messages hides the party chat, as on the Mac", () async {
    status(FamilySigner.childStatus(issuedAt: DateTime.now(), messages: 'nobody'));
    final ana = FakeTogether.card('u-ana', 'ana', 'Ana');
    server
      ..inParty([ana])
      ..partyChat('chat-1', texts: [('u-ana', 'Hi')]);
    await signIn();
    await until(() => model.together.hub.parties.party?.conversationId != null);
    expect(model.together.family.messagesAllowed, isFalse);
    expect(model.together.partyChatShown, isFalse);
    expect(model.together.partyChatUnread, 0);
  });

  test('friends through a parent, voice off, the server kept; a free account has none of it', () async {
    await signIn();
    final together = model.together;
    together.friendHandle = '@ana';
    await together.askFriend();
    expect(requests().single, {'kind': 'add_friend', 'handle': 'ana'});
    expect(server.callsTo('me/friends/requests', method: 'POST'), isEmpty);
    expect(model.toast, 'Asked a parent to add @ana');
    model.open(Layer.friends);
    expect(
      model.panelCategories().single.rows.firstWhere((row) => row.id == 'friends-ask').title,
      'Ask a parent to add them',
    );
    expect(together.family.voiceAllowed, isFalse);
    model.open(Layer.settings);
    final rows = model.panelCategories().firstWhere((category) => category.id == 'together').rows;
    expect(rows.map((row) => row.id), containsAll(['together-family', 'together-server']));
    expect(rows.map((row) => row.id), isNot(contains('together-server-use')));
    await together.useServer('https://my-own-server.example');
    expect(together.account.base, server.base);
    expect(model.toast, "A parent's settings keep this server.");
    // A family limit the server answers is said in words.
    expect(
      together.message(
        const TogetherProblem(403, 'restricted_by_family', 'No', extra: {'feature': 'voice_chat', 'side': 'self'}),
      ),
      'A parent has turned voice chat off.',
    );
    expect(
      together.message(
        const TogetherProblem(403, 'restricted_by_family', 'No', extra: {'feature': 'messages', 'side': 'other'}),
      ),
      "This person's family settings don't allow it",
    );
    // The gateway says the limits changed: fetched again at once.
    final before = server.callsTo('me/family/restrictions').length;
    await until(() => together.connected);
    server.push('family.updated', {'familyId': 'f-1'});
    await until(() => server.callsTo('me/family/restrictions').length > before);

    // A parent signs in on this computer: no limits.
    status(FamilySigner.freeStatus(issuedAt: DateTime.now(), userId: 'u-kid'));
    await together.family.refresh();
    expect(together.family.restricted, isFalse);
    expect(together.family.voiceAllowed, isTrue);
  });

  test('signed out the limits stay; a changed file locks play until a fresh status', () async {
    status(limited(limit: 30, played: 1800));
    await signIn();
    await model.together.signOut();
    expect(model.together.family.restricted, isTrue);
    final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
    expect(model.together.family.beforePlay(orbit), isFalse);

    // Read again on the next start.
    final file = File(FamilyCache.defaultFile(model.paths.config));
    final again = FamilyGate(model.together)..load();
    expect(again.restricted, isTrue);
    final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    file.writeAsStringSync(jsonEncode({...json, 'key': FamilySigner('mine').jwk['x']}));
    final changed = FamilyGate(model.together)..load();
    expect(changed.lockedOut, isTrue);
    expect(changed.voiceAllowed, isFalse);
  });
}

class _CountingDesktop extends NoDesktop {
  var captures = 0;

  @override
  Future<RgbaImage?> captureGame(int pid) async {
    captures++;
    return null;
  }
}
