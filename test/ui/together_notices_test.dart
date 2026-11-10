import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/desktop/desktop.dart';
import 'package:anyps5_desktop/core/installer.dart';
import 'package:anyps5_desktop/core/together/people.dart';
import 'package:anyps5_desktop/ui/app_model.dart' hide Command, GameState;
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:anyps5_desktop/ui/together_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_together.dart';
import '../support/ui_support.dart';
import 'desktop_features_test.dart' show FakeDesktop;

/// The social words the Mac puts over a game (its TrophyBanner notices): a friend request, a
/// party invite, someone in for a post or asking to join the party led here, the answer to one's
/// own "I'm in", a message and a share play invite. Over a game they are the card; with no game
/// to draw it over, the desktop notice; with the launcher in front, the toast alone. Do Not
/// Disturb keeps off what the Mac keeps off.
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
    server.conversation('c-ana', [ana]);
    desktop = FakeDesktop()..focused = focused;
    fixture = makeFixture(
      together: server.base,
      desktop: desktop,
      renderNoticeCard: (title, detail, symbol, scale) async {
        desktop.noticeCards.add((title, detail));
        return RgbaImage(1, 1, Uint8List.fromList([1, 2, 3, 4]));
      },
    );
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

  void friendAsks() => server.push('friend.request', FakeTogether.card('u-eda', 'eda', 'Eda'));

  void partyInvites() => server.push('party.invite', {'partyId': 'p-ana', 'from': ana, 'size': 2});

  void inForPost() => server.push('lfg.request', {'postId': 'lfg-1', 'from': ana, 'titleId': 'PPSA01001'});

  void letIn() => server.push('lfg.answered', {'postId': 'lfg-2', 'answer': 'accepted'});

  void sharesWithYou() => server.push('share_play.invite', {
    'sharePlayId': 'sp-9',
    'from': ana,
    'titleId': 'PPSA02002',
    'title': 'Neon Alley',
  });

  Future<void> asksToJoin() async {
    await model.together.startParty();
    final id = model.together.hub.parties.party!.id;
    server.push('party.request', {'partyId': id, 'from': FakeTogether.card('u-cem', 'cem', 'Cem'), 'via': 'code'});
    await until(() => model.together.hub.parties.party!.requests.isNotEmpty);
  }

  Future<void> said((String, String) notice) => until(() => desktop.notified.contains(notice));

  test('a friend request is said over a game with the handle, as on the Mac', () async {
    await signedIn();
    friendAsks();
    await said(('Eda wants to be friends', '@eda'));
    expect(model.toast, 'Eda wants to be friends');
  });

  test('a party invite is said over a game', () async {
    await signedIn();
    partyInvites();
    await said(('Ana invites you to a party', T.text('partyTitle')));
  });

  test('someone in for a post, and being let in from one, are said over a game', () async {
    await signedIn();
    inForPost();
    await said(('Ana is in for Orbit Runner', T.text('discoverFindPlayers')));
    letIn();
    await said((T.text('discoverYoureInParty'), T.text('discoverFindPlayers')));
  });

  test("someone asking to join the party led here: the Mac's words, over a game too", () async {
    await signedIn();
    await asksToJoin();
    expect(model.toast, 'Cem asks to join your party');
    await said(('Cem asks to join your party', T.text('partyTitle')));
  });

  test('a message is said over a game: who wrote it, and what', () async {
    await signedIn();
    server.receive('c-ana', 'u-ana', 'Up for a round?');
    await said(('Ana', 'Up for a round?'));
    expect(model.toast, 'Ana: Up for a round?');
  });

  test('a share play invite is said over a game', () async {
    await signedIn();
    sharesWithYou();
    await said(('Ana shares Neon Alley with you', T.text('friendsTitle')));
  });

  test(
    'Do Not Disturb keeps requests, invites and messages off the game; asks and answers come, as on the Mac',
    () async {
      await signedIn();
      model.together.hub.self.status = PresenceStatus.dnd;
      friendAsks();
      partyInvites();
      sharesWithYou();
      server.receive('c-ana', 'u-ana', 'Up for a round?');
      await until(() => model.together.hub.parties.invites.isNotEmpty && model.sharePlay.invites.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(desktop.notified, isEmpty);
      // The Mac says these through Do Not Disturb: someone answering what the user asked for.
      inForPost();
      await said(('Ana is in for Orbit Runner', T.text('discoverFindPlayers')));
      letIn();
      await said((T.text('discoverYoureInParty'), T.text('discoverFindPlayers')));
      await asksToJoin();
      await said(('Cem asks to join your party', T.text('partyTitle')));
    },
  );

  test('with the launcher in front, the toast alone', () async {
    await signedIn(focused: true);
    friendAsks();
    partyInvites();
    inForPost();
    sharesWithYou();
    server.receive('c-ana', 'u-ana', 'Up for a round?');
    await asksToJoin();
    await until(() => model.sharePlay.invites.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(desktop.notified, isEmpty);
    expect(desktop.noticeCards, isEmpty);
  });

  test('with a game in front they are the card over it, not a desktop notice', () async {
    await signedIn();
    final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
    final installed = Installer.installedFolder(orbit, model.root!);
    File(p.join(installed, 'app.elf')).writeAsStringSync('#!/bin/sh\nsleep 6\n');
    Process.runSync('chmod', ['755', p.join(installed, 'app.elf')]);
    final playing = model.play(orbit);
    await until(() => model.running != null);
    desktop.focused = false;
    friendAsks();
    await until(() => desktop.noticeCards.contains(('Eda wants to be friends', '@eda')));
    partyInvites();
    await until(() => desktop.noticeCards.contains(('Ana invites you to a party', T.text('partyTitle'))));
    server.receive('c-ana', 'u-ana', 'Up for a round?');
    await until(() => desktop.noticeCards.contains(('Ana', 'Up for a round?')));
    expect(desktop.notified, isEmpty, reason: 'the card, and no desktop notice as well');
    model.stopGame();
    await playing;
  }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);
}
