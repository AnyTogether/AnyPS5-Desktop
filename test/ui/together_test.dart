import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/installer.dart';
import 'package:anyps5_desktop/core/online/online_identity.dart';
import 'package:anyps5_desktop/core/online/online_wire.dart';
import 'package:anyps5_desktop/core/together/account.dart';
import 'package:anyps5_desktop/core/together/join_advice.dart';
import 'package:anyps5_desktop/core/together/messages.dart';
import 'package:anyps5_desktop/core/together/people.dart';
import 'package:anyps5_desktop/core/together/profiles.dart';
import 'package:anyps5_desktop/core/together/self.dart';
import 'package:anyps5_desktop/core/together/social.dart';
import 'package:anyps5_desktop/core/together/token_store.dart';
import 'package:anyps5_desktop/ui/app_model.dart' hide Command, GameState;
import 'package:anyps5_desktop/ui/app_model.dart' as launcher show Command;
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:anyps5_desktop/ui/together_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_together.dart';
import '../support/online_fakes.dart';
import '../support/phone/fake_phone.dart';
import '../support/phone/messages.dart';
import '../support/ui_support.dart';

/// AnyTogether in the launcher: signing in (email code, the website, the phone), the server,
/// signing out.
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

  int category(String id) => model.panelCategories().indexWhere((category) => category.id == id);

  List<String> rowIds() => model.panelCategories()[model.panelCategory].rows.map((row) => row.id).toList();

  void openTogether() {
    model.open(Layer.settings);
    model.selectCategory(category('together'));
  }

  group('signing in', () {
    setUp(() async {
      server = await FakeTogether.start();
      fixture = makeFixture(together: server.base);
      model = fixture.model;
    });

    tearDown(() async {
      model.dispose();
      await server.close();
      T.language = Language.english;
      fixture.dispose();
    });

    test('the settings offer the website and an email code; a code typed in signs in', () async {
      openTogether();
      expect(rowIds(), [
        'together-intro',
        'together-web',
        'together-email',
        'together-send',
        'together-server',
        'together-server-use',
      ]);
      final together = model.together;
      together.email = 'utku@example.com';
      await together.sendCode();
      expect(rowIds(), ['together-intro', 'together-sent', 'together-code', 'together-verify', 'together-other']);
      final code = model.panelCategories()[model.panelCategory].rows[2].kind as TextRow;
      code.set('123 456');
      await until(() => together.signedIn);
      expect(model.toast, 'Signed in as Utku');
      expect(rowIds(), [
        'together-user',
        'together-online',
        'together-presence',
        'together-receipts',
        'together-profile',
        'together-join',
        'together-online-play',
        'together-online-log',
        'together-signout',
        'together-server',
        'together-server-use',
      ]);

      await together.signOut();
      expect(together.signedIn, isFalse);
      expect(server.callsTo('auth/logout'), hasLength(1));
    });

    test('the public profile switch: saved with the website\'s call, refused for a child with its reason', () async {
      final together = model.together;
      together.email = 'utku@example.com';
      await together.sendCode();
      together.code = '123456';
      await together.verify();
      await until(() => together.signedIn);
      server.me['publicProfile'] = false;
      await together.hub.self.refresh();
      openTogether();
      PanelRow row() =>
          model.panelCategories()[model.panelCategory].rows.firstWhere((r) => r.id == 'together-public-profile');
      expect(row().title, 'Public profile');
      expect(row().detail, endsWith('While your profile is not public, Everyone works like Friends.'));
      expect((row().kind as ToggleRow).value, isFalse);
      (row().kind as ToggleRow).set(true);
      await until(() => server.callsTo('me/public-profile').isNotEmpty);
      expect(server.callsTo('me/public-profile').single.body, {'publicProfile': true});
      await until(() => (row().kind as ToggleRow).value);
      expect(row().detail, isNot(contains('While your profile')));
      server.answers['PATCH me/public-profile'] = (403, {'code': 'restricted_by_family'});
      (row().kind as ToggleRow).set(false);
      await until(() => model.toast == 'Your family settings keep your profile to friends.');
      expect((row().kind as ToggleRow).value, isTrue, reason: 'turned back when the server says no');
    });

    test('a wrong code says so and keeps the code row', () async {
      model.together.email = 'utku@example.com';
      await model.together.sendCode();
      model.together.code = '654321';
      await model.together.verify();
      expect(model.toast, 'That code is not right');
      expect(model.together.account.step, isA<SignInCodeSent>());
    });

    test('the website opens in the browser with the code, and signing in there signs in here', () async {
      openTogether();
      final signingIn = model.together.signInWithWebsite();
      await until(() => fixture.opened.isNotEmpty);
      expect(fixture.opened.single.queryParameters['code'], 'ABCD-EFGH');
      expect(rowIds(), ['together-intro', 'together-device', 'together-open', 'together-cancel']);
      expect(model.panelCategories()[model.panelCategory].rows[1].title, 'ABCD-EFGH');
      server.approveDevice();
      await signingIn;
      expect(model.together.user?.handle, 'utku');
      expect(server.callsTo('auth/device').single.headers.value('AnyTogether-Client'), startsWith('launcher-linux/'));
    });

    test('the paired phone approves the launcher, or says no', () async {
      await model.startPhoneServer();
      final phone = await FakePhone.connect(model.remote!.port!);
      phone.hello('phone-1', 'Pixel');
      await phone.next<Pairing>();
      await until(() => model.pairing != null);
      model.handle(launcher.Command.select);
      final welcome = await phone.next<Welcome>();
      expect(welcome.togetherServer, server.base.toString());
      openTogether();
      expect(rowIds(), contains('together-phone'));

      // No: the launcher goes back to the start.
      var signingIn = model.together.signInWithPhone();
      var asked = await phone.next<TogetherHandoff>();
      expect(asked.deviceName, 'Desk');
      expect(rowIds(), ['together-intro', 'together-onphone', 'together-cancel']);
      phone.send(TogetherHandoffAnswer(id: asked.id, approved: false));
      await signingIn;
      expect(model.toast, 'The phone did not approve; sign in to AnyTogether on the phone first');
      expect(model.together.signedIn, isFalse);

      // Yes: the phone approves on the server.
      signingIn = model.together.signInWithPhone();
      asked = await phone.next<TogetherHandoff>();
      server.approveHandoff(asked.id);
      await signingIn;
      expect(model.together.signedIn, isTrue);
      await phone.close();
      await model.stopPhoneServer();
    });

    test('a signed-in launcher approves its phone, a signed-out one turns it down', () async {
      await model.startPhoneServer();
      final phone = await FakePhone.connect(model.remote!.port!);
      phone.hello('phone-1', 'Pixel');
      await phone.next<Pairing>();
      await until(() => model.pairing != null);
      model.handle(launcher.Command.select);
      await phone.next<Welcome>();

      phone.send(const TogetherHandoff(id: 'handoff-x', deviceName: 'Pixel'));
      expect((await phone.next<TogetherHandoffAnswer>()).approved, isFalse);

      final phoneAccount = TogetherAccount(base: server.base, store: MemoryTokenStore(), clientName: 'phone/1.9.1');
      final handoff = await phoneAccount.startHandoff('Pixel', 'Desk');
      model.together.email = 'utku@example.com';
      await model.together.sendCode();
      model.together.code = '123456';
      await model.together.verify();
      phone.send(TogetherHandoff(id: handoff.id, deviceName: 'Pixel'));
      final answer = await phone.next<TogetherHandoffAnswer>();
      expect(answer.approved, isTrue);
      expect(answer.id, handoff.id);
      expect(model.toast, 'Pixel signed in to AnyTogether');
      expect((await phoneAccount.waitForPhone(handoff)).id, 'u-me');
      phoneAccount.close();
      await phone.close();
      await model.stopPhoneServer();
    });

    test('another server signs out of this one first; a bad address is refused', () async {
      model.together.email = 'utku@example.com';
      await model.together.sendCode();
      model.together.code = '123456';
      await model.together.verify();
      await model.together.useServer('http://example.org');
      expect(model.toast, 'Type an https:// address (http:// only for this computer or the home network)');
      expect(model.together.signedIn, isTrue);
      await model.together.useServer('https://together.example.org/');
      expect(model.together.signedIn, isFalse);
      expect(model.together.account.base, Uri.parse('https://together.example.org'));
      expect(model.preferences.togetherServer, 'https://together.example.org');
      expect(model.toast, 'Now using together.example.org');
    });

    test('a session kept from the last run is signed in at the start', () async {
      final store = MemoryTokenStore(
        SavedSession(
          accessToken: 'old',
          accessExpiry: DateTime.now().add(const Duration(hours: 1)),
          refreshToken: 'old-refresh',
          user: const TogetherUser(id: 'u-me', handle: 'utku', displayName: 'Utku'),
        ),
      );
      final again = makeFixture(together: server.base, togetherStore: store);
      await again.model.together.start();
      expect(again.model.together.user?.handle, 'utku');
      again.model.dispose();
      again.dispose();
    });
  });

  group('friends and presence', () {
    setUp(() async {
      server = await FakeTogether.start();
      server
        ..friend('u-ana', 'ana', 'Ana', presence: {'state': 'online'})
        ..friend('u-bora', 'bora', 'Bora', presence: {'state': 'in_game', 'titleId': 'PPSA02002'})
        ..person('u-deniz', 'deniz', 'Deniz');
      server.incoming.add(FakeTogether.card('u-cem', 'cem', 'Cem'));
      fixture = makeFixture(together: server.base);
      model = fixture.model;
      model.together.email = 'utku@example.com';
      await model.together.sendCode();
      model.together.code = '123456';
      await model.together.verify();
      await until(() => model.together.hub.friends.loaded);
    });

    tearDown(() async {
      model.dispose();
      await server.close();
      T.language = Language.english;
      fixture.dispose();
    });

    test('the friends panel: requests, adding by handle, friends by what they do', () async {
      model.open(Layer.friends);
      expect(rowIds(), [
        'friends-me',
        'friends-find',
        'friends-feed',
        'friends-captures',
        'friends-board',
        'accept-u-cem',
        'decline-u-cem',
        'friends-handle',
        'friends-ask',
        'friend-u-bora',
        'friend-call-u-bora',
        'friend-u-ana',
        'friend-call-u-ana',
      ]);
      final rows = model.panelCategories().single.rows.skip(5).toList();
      expect(rows[4].detail, '@bora · Playing Neon Alley');
      expect(rows[4].person?.status, PersonStatus.playing);
      expect(model.together.hub.badge, 1);

      (rows[0].kind as ActionRow).run();
      await until(() => model.together.hub.friends.byId('u-cem') != null);
      expect(model.toast, 'You and Cem are friends');

      model.together.friendHandle = '@deniz';
      await model.together.askFriend();
      expect(model.toast, 'Request sent to deniz');
      expect(rowIds().reversed.take(2), ['unsend-u-deniz', 'waiting-u-deniz']);
      // Taken back, as on the website.
      final unsend = model.panelCategories().single.rows.firstWhere((row) => row.id == 'unsend-u-deniz');
      expect(unsend.title, 'Cancel request to Deniz');
      (unsend.kind as ActionRow).run();
      await until(() => model.together.hub.friends.outgoing.isEmpty);
      expect(server.outgoing, isEmpty);
      expect(model.toast, 'Request to Deniz withdrawn');
      expect(rowIds(), isNot(contains('waiting-u-deniz')));
      model.together.friendHandle = 'nobody';
      await model.together.askFriend();
      expect(model.toast, 'No one is called nobody');
    });

    test('a friend opens their options; removing them takes them off', () async {
      model.open(Layer.friends);
      final ana = model.panelCategories().single.rows.firstWhere((row) => row.id == 'friend-u-ana');
      (ana.kind as ActionRow).run();
      expect(model.overlay, Layer.friendOptions);
      expect(rowIds(), [
        'friend-card',
        'friend-profile',
        'friend-compare',
        'friend-message',
        'friend-remove',
        'friend-back',
      ]);
      model.handle(launcher.Command.back);
      expect(model.overlay, Layer.friends);
      (ana.kind as ActionRow).run();
      final remove = model.panelCategories().single.rows.firstWhere((row) => row.id == 'friend-remove');
      (remove.kind as ActionRow).run();
      // It asks first.
      expect(server.callsTo('me/friends/u-ana', method: 'DELETE'), isEmpty);
      final sure = model.panelCategories().single.rows.firstWhere((row) => row.id == 'friend-remove-yes');
      (sure.kind as ActionRow).run();
      await until(() => model.together.hub.friends.byId('u-ana') == null);
      expect(model.overlay, Layer.friends);
      expect(server.callsTo('me/friends/u-ana', method: 'DELETE'), hasLength(1));
    });

    test('a request on the socket shows and comes into the list', () async {
      server.incoming.add(FakeTogether.card('u-eda', 'eda', 'Eda'));
      server.push('friend.request', FakeTogether.card('u-eda', 'eda', 'Eda'));
      await until(() => model.together.hub.badge == 2);
      expect(model.toast, 'Eda wants to be friends');
    });

    test('friends see the game played, then the launcher online again', () async {
      await server.nextFrame('heartbeat', test: (frame) => (frame['presence'] as Map)['state'] == 'online');
      final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
      final installed = Installer.installedFolder(orbit, model.root!);
      File(p.join(installed, 'app.elf')).writeAsStringSync('#!/bin/sh\nsleep 0.4\n');
      if (!Platform.isWindows) Process.runSync('chmod', ['755', p.join(installed, 'app.elf')]);
      final playing = model.play(orbit);
      final inGame = await server.nextFrame(
        'heartbeat',
        test: (frame) => (frame['presence'] as Map)['state'] == 'in_game',
      );
      expect((inGame['presence'] as Map)['titleId'], 'PPSA01001');
      expect(DateTime.parse((inGame['presence'] as Map)['since'] as String).isBefore(DateTime.now()), isTrue);
      await playing;
      await server.nextFrame('heartbeat', test: (frame) => (frame['presence'] as Map)['state'] == 'online');
    });

    test('a name or handle changed on the website shows when the launcher comes back or a screen opens', () async {
      await until(() => model.together.connected);
      await until(() => model.together.hub.self.loaded);
      expect(model.together.myCard.name, 'Utku');
      server.me
        ..['displayName'] = 'Utku H'
        ..['handle'] = 'utku_h';
      // Read a moment ago: opening the friends panel again soon does not ask once more.
      final reads = server.callsTo('me', method: 'GET').length;
      model.open(Layer.friends);
      expect(server.callsTo('me', method: 'GET').length, reads);
      // Some time later the launcher comes back in front.
      model.together.hub.self.readAt = DateTime.now().subtract(const Duration(minutes: 1));
      model.setActive(false);
      model.setActive(true);
      await until(() => model.together.user?.displayName == 'Utku H');
      expect(model.together.user?.handle, 'utku_h');
      expect(model.together.myCard.name, 'Utku H');
      final me = model.panelCategories().single.rows.firstWhere((row) => row.id == 'friends-me');
      expect(me.person?.name, 'Utku H');
      // And with the friends panel opened later on.
      server.me['displayName'] = 'Utku Halis';
      model.together.hub.self.readAt = DateTime.now().subtract(const Duration(minutes: 1));
      model.open(Layer.friends);
      await until(() => model.together.user?.displayName == 'Utku Halis');
    });

    test('signed out on another device: signed out here too', () async {
      await until(() => model.together.connected);
      await server.dropSockets(4003);
      await until(() => !model.together.signedIn);
      expect(model.together.hub.friends.friends, isEmpty);
    });
  });

  group('play and trophies', () {
    setUp(() async {
      server = await FakeTogether.start();
      fixture = makeFixture(together: server.base);
      model = fixture.model;
    });

    tearDown(() async {
      model.dispose();
      await server.close();
      fixture.dispose();
    });

    test('signing in sends every game\'s trophies; a session played goes up', () async {
      // Signed out, nothing is kept for AnyTogether.
      final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
      model.together.recordPlay(orbit, DateTime.now().subtract(const Duration(hours: 1)), DateTime.now());
      expect(model.together.sync.sessions, isEmpty);

      model.together.email = 'utku@example.com';
      await model.together.sendCode();
      model.together.code = '123456';
      await model.together.verify();
      await until(() => server.earned.length == 2);
      expect(server.devices.values.single['platform'], 'linux');
      expect(server.devices.values.single['name'], 'Desk');
      expect(server.games['PPSA01001'], {
        'names': {'en': 'Orbit Runner'},
      });
      final set = server.trophySets.keys.single;
      expect(set, startsWith('PPSA01001/'));
      expect(server.earned.keys.toSet(), {'PPSA01001/1', 'PPSA01001/2'});

      model.together.recordPlay(
        orbit,
        DateTime.now().subtract(const Duration(minutes: 40)),
        DateTime.now(),
        exit: 'killed',
      );
      await until(() => server.playSessions.isNotEmpty);
      expect(server.playSessions.values.single['titleId'], 'PPSA01001');
      expect(server.playSessions.values.single['exit'], 'killed');
      // The server keeps the session before its answer reaches the outbox.
      await until(() => model.together.sync.isEmpty);
    });
  });

  group('messages and the party', () {
    setUp(() async {
      server = await FakeTogether.start();
      server
        ..friend('u-ana', 'ana', 'Ana', presence: {'state': 'online'})
        ..friend('u-bora', 'bora', 'Bora');
      server.conversation(
        'c-ana',
        [FakeTogether.card('u-ana', 'ana', 'Ana')],
        texts: [('u-ana', 'Hi!'), ('u-ana', 'Playing tonight?')],
      );
      fixture = makeFixture(together: server.base);
      model = fixture.model;
      model.together.email = 'utku@example.com';
      await model.together.sendCode();
      model.together.code = '123456';
      await model.together.verify();
      await until(() => model.together.hub.friends.loaded && model.together.hub.messages.loaded);
    });

    tearDown(() async {
      model.dispose();
      await server.close();
      T.language = Language.english;
      fixture.dispose();
    });

    test('the conversations, then friends to start one with; opening reads it; quick replies and typing', () async {
      final together = model.together;
      await until(() => together.unread == 2);
      await together.openMessages();
      expect(model.overlay, Layer.messages);
      final targets = together.messageTargets;
      expect(targets.first, isA<ConversationTarget>());
      expect((targets.last as FriendTarget).friend.person.handle, 'bora');
      await until(() => together.hub.messages.thread.length == 2);
      await until(() => server.callsTo('conversations/c-ana/read').isNotEmpty);
      expect(together.unread, 0);

      // Into the thread: the field first, a quick reply to its left.
      model.handle(launcher.Command.right);
      expect(together.messagesInThread, isTrue);
      model.handle(launcher.Command.left);
      model.handle(launcher.Command.select);
      await until(() => server.threads['c-ana']!.length == 3);
      expect(server.threads['c-ana']!.last['text'], 'One sec');

      // Typing: the others are told, Enter sends.
      model.handle(launcher.Command.right);
      model.handle(launcher.Command.select);
      expect(model.editingRow, 'message-draft');
      final field = together.draftField.kind as TextRow;
      field.set('See you at nine');
      final typing = await server.nextFrame('typing');
      expect(typing['conversation'], 'c-ana');
      field.submit!();
      await until(() => server.threads['c-ana']!.length == 4);
      expect(together.draft, isEmpty);

      // Someone typing, then their message.
      server.push('typing', {'conversationId': 'c-ana', 'userId': 'u-ana'});
      await until(() => together.hub.messages.typingIn('c-ana').isNotEmpty);
      server.receive('c-ana', 'u-ana', 'Great');
      await until(() => together.hub.messages.thread.length == 5);
      expect(together.hub.messages.typingIn('c-ana'), isEmpty);

      model.handle(launcher.Command.back);
      model.handle(launcher.Command.back);
      expect(model.overlay, isNull);
      server.receive('c-ana', 'u-ana', 'Are you there?');
      await until(() => model.toast == 'Ana: Are you there?');
    });

    test('a link the server blocks is said so; a friend without a conversation gets one', () async {
      final together = model.together;
      await together.openMessages();
      await until(() => together.hub.messages.openId == 'c-ana');
      await together.sendMessage('look https://blocked.example/x');
      expect(model.toast, "That link can't be sent");
      expect(together.hub.messages.thread.last.failed, isTrue);

      // Past New group, to Bora.
      model.handle(launcher.Command.down);
      model.handle(launcher.Command.down);
      model.handle(launcher.Command.select);
      await until(() => server.callsTo('conversations', method: 'POST').isNotEmpty);
      expect(server.callsTo('conversations', method: 'POST').single.body, {
        'members': ['u-bora'],
      });
      await until(() => together.hub.messages.openId != 'c-ana' && together.hub.messages.openId != null);
      expect(together.messagesInThread, isTrue);
    });

    test('a party: start it, invite from a friend\'s options, join its voice, choose the talk key', () async {
      final together = model.together;
      model.open(Layer.party);
      expect(rowIds(), ['party-start', 'party-open', 'party-find', 'party-code-enter']);
      await together.startParty();
      expect(rowIds(), [
        'voice-join',
        'together-about',
        'together-start',
        'party-members',
        'party-member-u-me',
        'party-privacy',
        'party-code-new',
        'party-public',
        'party-discord',
        'party-invite-title',
        'party-invite-u-ana',
        'party-invite-u-bora',
        'party-code-enter',
        'party-leave',
      ]);

      model.open(Layer.friends);
      (model.panelCategories().single.rows.firstWhere((row) => row.id == 'friend-u-ana').kind as ActionRow).run();
      expect(rowIds(), contains('friend-party'));
      (model.panelCategories().single.rows.firstWhere((row) => row.id == 'friend-party').kind as ActionRow).run();
      await until(() => server.callsTo('parties/${together.hub.parties.party!.id}/invites').isNotEmpty);
      await until(() => model.toast == 'Ana is invited');

      model.open(Layer.party);
      await together.joinVoice();
      expect(model.toast, "You're in voice");
      expect(rowIds().take(6), ['voice-mic', 'voice-noise', 'voice-deafen', 'voice-ptt', 'voice-key', 'voice-leave']);
      final mic = model.panelCategories().single.rows.first;
      expect(mic.detail, 'V turns the microphone on and off, in a game too.');

      // Deafen: nobody heard, the microphone off, and the others are told.
      PanelRow voiceRow(String id) => model.panelCategories().single.rows.firstWhere((row) => row.id == id);
      expect(voiceRow('voice-deafen').title, 'Deafen');
      expect(voiceRow('voice-deafen').detail, 'Hear nobody, and your microphone is off.');
      (voiceRow('voice-deafen').kind as ToggleRow).set(true);
      expect(together.hub.voice.deafened, isTrue);
      expect((voiceRow('voice-deafen').kind as ToggleRow).value, isTrue);
      expect((voiceRow('voice-mic').kind as ToggleRow).value, isFalse);
      final callId = together.hub.voice.callId;
      await until(() => server.callsTo('calls/$callId/mute').isNotEmpty);
      expect(server.callsTo('calls/$callId/mute').last.body, {'muted': true, 'deafened': true});
      // The microphone on hears everyone again.
      (voiceRow('voice-mic').kind as ToggleRow).set(true);
      expect(together.hub.voice.deafened, isFalse);

      together.captureTalkKey();
      expect(together.capturingTalkKey, isTrue);
      expect(together.chooseTalkKey(0x4F), isFalse, reason: 'an arrow is not a talk key');
      together.captureTalkKey();
      expect(together.chooseTalkKey(0x0A), isTrue);
      expect(model.preferences.talkKey, 0x0A);
      expect(model.toast, 'Talk key: G');

      // Noise suppression: on by default, off in the call as it is, kept for the next one.
      final noise = voiceRow('voice-noise');
      expect(noise.title, 'Noise suppression');
      expect(noise.detail, 'Background noise is filtered out of your microphone.');
      expect((noise.kind as ToggleRow).value, isTrue);
      (noise.kind as ToggleRow).set(false);
      await until(() => !together.hub.voice.noiseSuppression);
      expect(model.preferences.noiseSuppression, isFalse);
      expect(model.preferences.toJson()['noiseSuppression'], isFalse);
      expect(voiceRow('voice-noise').detail, 'Your microphone goes as it is: for music, or a quiet room.');
      expect(together.hub.voice.active, isTrue, reason: 'still in the same call');
      together.setNoiseSuppression(true);

      together.setPushToTalk(true);
      expect(model.preferences.pushToTalk, isTrue);
      expect(rowIds().take(5), ['voice-noise', 'voice-deafen', 'voice-ptt', 'voice-key', 'voice-leave']);
      expect(voiceRow('voice-ptt').detail, 'Hold G to talk, in a game too.');
      // Without a desktop key reader, the launcher's own keys hold it.
      expect(together.talkKeyInWindow(0x0A, down: true), isTrue);
      expect(together.hub.voice.sending, isTrue);
      expect(together.talkKeyInWindow(0x0A, down: false), isTrue);
      expect(together.hub.voice.sending, isFalse);

      await together.leaveParty();
      expect(together.hub.voice.active, isFalse);
      expect(together.hub.parties.party, isNull);
    });

    PanelRow row(String id) => model.panelCategories()[model.panelCategory].rows.firstWhere((row) => row.id == id);

    void run(String id) => (row(id).kind as ActionRow).run();

    test('removing someone, leaving the party and removing a friend ask first; Back answers Cancel', () async {
      final ana = FakeTogether.card('u-ana', 'ana', 'Ana');
      server.inParty([ana], leader: 'u-me');
      await model.together.hub.parties.refresh();
      final partyId = model.together.hub.parties.party!.id;
      model.open(Layer.party);
      run('party-kick-u-ana');
      expect(rowIds(), containsAllInOrder(['party-kick-u-ana-ask', 'party-kick-u-ana-yes', 'party-kick-u-ana-cancel']));
      expect(rowIds(), isNot(contains('party-kick-u-ana')));
      expect(row('party-kick-u-ana-ask').title, 'Remove Ana from the party? They need a new invite to come back.');
      expect(rowIds()[model.panelRow], 'party-kick-u-ana-cancel', reason: 'Cancel takes the focus');
      expect(server.callsTo('parties/$partyId/kick'), isEmpty);
      model.handle(launcher.Command.back);
      expect(model.overlay, Layer.party, reason: 'Back answers the question, the panel stays');
      expect(rowIds(), contains('party-kick-u-ana'));
      expect(rowIds()[model.panelRow], 'party-kick-u-ana');
      // Handing the party over asks first too, then Ana leads and the leader's rows go.
      run('party-lead-u-ana');
      expect(row('party-lead-u-ana-ask').title, 'Make Ana the party leader? Only they can give it back.');
      run('party-lead-u-ana-yes');
      await until(() => model.together.hub.parties.party?.leaderId == 'u-ana');
      expect(server.callsTo('parties/$partyId/leader').single.body, {'userId': 'u-ana'});
      expect(rowIds(), isNot(contains('party-kick-u-ana')));
      server.party!['leaderId'] = 'u-me';
      await model.together.hub.parties.refresh();
      run('party-kick-u-ana');
      run('party-kick-u-ana-yes');
      await until(() => server.callsTo('parties/$partyId/kick').isNotEmpty);

      run('party-leave');
      expect(rowIds(), containsAllInOrder(['party-leave-ask', 'party-leave-yes', 'party-leave-cancel']));
      expect(server.callsTo('parties/$partyId/leave'), isEmpty);
      run('party-leave-cancel');
      expect(rowIds(), contains('party-leave'));
      run('party-leave');
      run('party-leave-yes');
      await until(() => model.together.hub.parties.party == null);

      model.together.openFriend(model.together.hub.friends.friends.firstWhere((f) => f.person.id == 'u-ana'));
      run('friend-remove');
      expect(
        row('friend-remove-ask').title,
        'Remove Ana from your friends? You need a new request to be friends again.',
      );
      expect(server.callsTo('me/friends/u-ana', method: 'DELETE'), isEmpty);
      model.handle(launcher.Command.back);
      expect(model.overlay, Layer.friendOptions, reason: 'Back answers the question first');
      run('friend-remove');
      run('friend-remove-yes');
      await until(() => server.callsTo('me/friends/u-ana', method: 'DELETE').isNotEmpty);

      T.language = Language.byCode('tr');
      model.open(Layer.party);
      expect(T.format('askKick', ['Ana']), 'Ana partiden çıkarılsın mı? Geri gelmek için yeni bir davet gerekir.');
    });

    test('AnyTogether retiring this version opens Update required once, with the update', () async {
      server.answers['me/friends'] = (
        426,
        {
          'code': 'client_too_old',
          'status': 426,
          'title': 'This version is too old. Update to 9.0.0 or newer.',
          'client': 'launcher-linux',
          'current': '0.1.7',
          'minimum': '9.0.0',
          'downloadUrl': 'https://anytogether.test/download',
        },
      );
      await model.together.hub.friends.refresh().catchError((Object _) {});
      await until(() => model.overlay == Layer.updateRequired);
      expect(model.panelCategories().single.title, 'Update required');
      expect(rowIds().first, 'required-why');
      expect(row('required-why').title, contains('0.1.7'));
      expect(rowIds(), contains('required-later'));
      expect(rowIds(), contains('required-download'), reason: 'no newer release found here: the downloads page');
      run('required-download');
      expect(fixture.opened.last, Uri.parse('https://anytogether.test/download'));
      model.handle(launcher.Command.back);
      expect(model.overlay, isNull);
      await model.together.hub.friends.refresh().catchError((Object _) {});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(model.overlay, isNull, reason: 'once is enough');
    });

    /// The party as the server would send it in party.updated, with [changes].
    Map<String, dynamic> partyView(Map<String, dynamic> changes) => {...server.party!, ...changes};

    test('a join code: make it, copy the code and the link, a new one, stop it', () async {
      final together = model.together;
      model.open(Layer.party);
      await together.startParty();
      final id = together.hub.parties.party!.id;
      expect(rowIds(), isNot(contains('party-code')));
      expect(row('party-code-new').title, 'Make a join code');

      run('party-code-new');
      await until(() => together.hub.parties.party!.joinCode != null);
      expect(server.callsTo('parties/$id/code', method: 'POST'), hasLength(1));
      expect(row('party-code').title, 'K7QM-3XPA');
      expect(rowIds().where((id) => id.startsWith('party-code')), [
        'party-code',
        'party-code-copy',
        'party-code-link',
        'party-code-new',
        'party-code-stop',
        'party-code-enter',
      ]);
      expect(row('party-code-new').title, 'New code');

      run('party-code-copy');
      expect(fixture.copied.last, 'K7QM-3XPA');
      expect(model.toast, 'Code copied');
      run('party-code-link');
      expect(fixture.copied.last, 'https://anytogether.net/join/K7QM3XPA');
      expect(model.toast, 'Link copied');

      run('party-code-new');
      await until(() => together.hub.parties.party!.joinCode?.code == 'H8NZ4WRB');
      expect(row('party-code').title, 'H8NZ-4WRB');

      run('party-code-stop');
      await until(() => server.callsTo('parties/$id/code', method: 'DELETE').isNotEmpty);
      expect(together.hub.parties.party!.joinCode, isNull);
      expect(rowIds(), isNot(contains('party-code')));
      expect(rowIds(), contains('party-code-new'));

      T.language = Language.byCode('tr');
      expect(row('party-code-new').title, 'Katılma kodu oluştur');
    });

    test('join requests: the leader is told, lets them in or turns them down; members see none', () async {
      final together = model.together;
      model.open(Layer.party);
      await together.startParty();
      final id = together.hub.parties.party!.id;

      server.push('party.request', {'partyId': id, 'from': FakeTogether.card('u-cem', 'cem', 'Cem'), 'via': 'code'});
      await until(() => together.hub.parties.party!.requests.length == 1);
      expect(model.toast, 'Cem asks to join your party', reason: "the Mac's words, the row says it was the code");
      server.push('party.request', {
        'partyId': id,
        'from': FakeTogether.card('u-deniz', 'deniz', 'Deniz'),
        'via': 'list',
      });
      await until(() => together.hub.parties.party!.requests.length == 2);
      expect(model.toast, 'Deniz asks to join your party');
      expect(together.partyBadge, 2);
      expect(rowIds().take(4), [
        'party-request-u-cem',
        'party-request-decline-u-cem',
        'party-request-u-deniz',
        'party-request-decline-u-deniz',
      ]);
      expect(row('party-request-u-cem').title, 'Let Cem in');
      expect(row('party-request-u-cem').detail, '@cem · asked with your code');
      expect(row('party-request-u-deniz').detail, '@deniz · asks to join');
      expect(row('party-request-decline-u-deniz').title, 'Turn down Deniz');

      run('party-request-u-cem');
      await until(() => server.callsTo('parties/$id/requests/u-cem/accept', method: 'POST').isNotEmpty);
      expect(model.toast, 'Cem is invited');
      run('party-request-decline-u-deniz');
      await until(() => server.callsTo('parties/$id/requests/u-deniz/decline', method: 'POST').isNotEmpty);
      expect(together.hub.parties.party!.requests, isEmpty);
      expect(rowIds().where((id) => id.startsWith('party-request')), isEmpty);
      expect(together.partyBadge, 0);

      // The party view carries the requests too.
      server.push(
        'party.updated',
        partyView({
          'requests': [FakeTogether.card('u-emre', 'emre', 'Emre')],
        }),
      );
      await until(() => rowIds().contains('party-request-u-emre'));
      expect(row('party-request-u-emre').detail, '@emre · asks to join');

      // A member who does not lead sees no requests and no code.
      server.push(
        'party.updated',
        partyView({
          'leaderId': 'u-ana',
          'requests': [FakeTogether.card('u-emre', 'emre', 'Emre')],
          'joinCode': {'code': 'K7QM3XPA', 'url': 'https://anytogether.net/join/K7QM3XPA'},
        }),
      );
      await until(() => together.hub.parties.party!.leaderId == 'u-ana');
      // Joining someone else's with a code is still there, as on the Mac.
      expect(rowIds().where((id) => id.startsWith('party-request') || id.startsWith('party-code')), [
        'party-code-enter',
      ]);
      expect(together.partyBadge, 0);

      // Asking with a code and being turned down.
      server.push('party.request_answered', {'partyId': 'p-other', 'answer': 'declined'});
      await until(() => model.toast == 'Your request to join was turned down');
    });

    test('the Discord link: the leader sets it, a wrong one is refused, everyone opens it', () async {
      final together = model.together;
      model.open(Layer.party);
      await together.startParty();
      final id = together.hub.parties.party!.id;
      expect(rowIds(), isNot(contains('party-discord-open')));
      final field = row('party-discord').kind as TextRow;
      expect(field.hint, 'https://discord.gg/…');

      field.set('https://example.com/x');
      field.submit!();
      await until(() => model.toast == 'Use a discord.gg or discord.com link');
      expect(together.hub.parties.party!.discord, isNull);

      (row('party-discord').kind as TextRow).set('https://discord.gg/abc');
      (row('party-discord').kind as TextRow).submit!();
      await until(() => together.hub.parties.party!.discord == 'https://discord.gg/abc');
      expect(server.callsTo('parties/$id', method: 'PATCH').last.body, {'discord': 'https://discord.gg/abc'});
      expect((row('party-discord').kind as TextRow).value, 'https://discord.gg/abc');
      expect(row('party-discord-open').title, 'Open in Discord');

      run('party-discord-open');
      expect(fixture.opened.last, Uri.parse('https://discord.gg/abc'));

      run('party-discord-clear');
      await until(() => together.hub.parties.party!.discord == null);
      expect(server.callsTo('parties/$id', method: 'PATCH').last.body, {'discord': null});
      expect(rowIds(), isNot(contains('party-discord-open')));

      // A member sees the link to open, not to change.
      server.push('party.updated', partyView({'leaderId': 'u-ana', 'discord': 'https://discord.com/invite/xyz'}));
      await until(() => together.hub.parties.party!.leaderId == 'u-ana');
      expect(rowIds(), contains('party-discord-open'));
      expect(rowIds(), isNot(contains('party-discord')));
      expect(rowIds(), isNot(contains('party-discord-clear')));
      run('party-discord-open');
      expect(fixture.opened.last, Uri.parse('https://discord.com/invite/xyz'));
    });

    test('joining with a code: what it opens, then asking to join', () async {
      final together = model.together;
      server.joinPreviews['K7QM3XPA'] = {
        'code': 'K7QM3XPA',
        'kind': 'party',
        'id': 'p-cem',
        'host': {'userId': 'u-cem', 'handle': 'cem', 'displayName': 'Cem', 'avatar': null},
        'game': {'titleId': 'PPSA01001', 'title': 'Orbit Runner', 'names': <String, String>{}, 'iconUrl': null},
        'size': 3,
        'max': 8,
        'expiresAt': '2026-10-26T20:00:00Z',
        'state': 'none',
      };
      model.open(Layer.party);

      PanelRow enter() => row('party-code-enter');

      // Not a code at all: said so, without asking.
      (enter().kind as TextRow).set('hello');
      expect(enter().detail, 'Type or paste a code or its link.');
      expect(server.callsTo('join/HELLO'), isEmpty);
      (enter().kind as TextRow).set('NOPE-NOPE');
      expect(enter().detail, 'A code is 8 letters and numbers');
      expect(server.callsTo('join/NOPENOPE'), isEmpty);

      // A code that works nowhere: looked up a moment after typing stops.
      (enter().kind as TextRow).set('ABCD-EFGH');
      expect(enter().detail, 'Looking it up…');
      await until(() => server.callsTo('join/ABCDEFGH').isNotEmpty);
      await until(() => enter().detail == 'No such code, or it no longer works');

      final field = enter().kind as TextRow;
      expect(field.hint, 'XXXX-XXXX');
      field.set('k7qm-3xpa');
      field.submit!();
      await until(() => together.joinEntry.info != null);
      expect(rowIds(), containsAllInOrder(['party-code-enter', 'party-code-preview', 'party-code-ask']));
      expect(row('party-code-preview').title, "Cem's party");
      expect(row('party-code-preview').detail, 'Orbit Runner · 3 of 8 in it');

      run('party-code-ask');
      await until(() => server.callsTo('join/K7QM3XPA', method: 'POST').isNotEmpty);
      await until(() => model.toast == "Asked. You'll hear when the leader answers");
      expect(rowIds(), containsAllInOrder(['party-code-preview', 'party-code-asked']));
      expect(rowIds(), isNot(contains('party-code-ask')));

      // A Share Play code asks to watch too, as on the Mac: it comes back as an invite to watch.
      server.joinPreviews['H8NZ4WRB'] = {
        'code': 'H8NZ4WRB',
        'kind': 'share_play',
        'id': 's-1',
        'host': {'userId': 'u-cem', 'handle': 'cem', 'displayName': 'Cem', 'avatar': null},
        'game': null,
        'size': 1,
        'max': 4,
        'state': 'none',
      };
      (enter().kind as TextRow).set('https://anytogether.net/join/H8NZ4WRB');
      await until(() => together.joinEntry.info?.kind == 'share_play');
      expect(row('party-code-preview').title, 'Cem is sharing');
      expect(row('party-code-preview').detail, '1 of 4 in it');
      run('party-code-ask');
      await until(() => server.callsTo('join/H8NZ4WRB', method: 'POST').isNotEmpty);
      await until(() => model.toast == "Asked. You'll hear when the host answers");

      // A code for a share play that is full says so.
      server.joinPreviews['H8NZ5WRB'] = {
        ...server.joinPreviews['H8NZ4WRB'] as Map<String, dynamic>,
        'code': 'H8NZ5WRB',
        'size': 4,
        'state': 'none',
      };
      (enter().kind as TextRow).set('H8NZ-5WRB');
      await until(() => together.joinEntry.info?.code == 'H8NZ5WRB');
      expect(row('party-code-state').title, 'Every slot is taken');
      expect(rowIds(), isNot(contains('party-code-ask')));
    });

    test('the leader is told when they lead, and that someone was made leader or removed', () async {
      final together = model.together;
      model.open(Layer.party);
      await together.startParty();
      const ana = Person(id: 'u-ana', handle: 'ana', displayName: 'Ana');
      (server.party!['members'] as List<Map<String, dynamic>>).add(FakeTogether.card('u-ana', 'ana', 'Ana'));
      await together.hub.parties.refresh();
      await together.makeLeader(ana);
      expect(model.toast, 'Ana leads the party now');
      await until(() => !together.hub.parties.party!.leads('u-me'));

      // The lead handed back: it says so once.
      server.push('party.updated', partyView({'leaderId': 'u-me'}));
      await until(() => model.toast == 'You lead the party now');
      expect(together.hub.parties.party!.leads('u-me'), isTrue);

      // Removing someone says who.
      await together.kick(ana);
      expect(model.toast, 'Ana was removed from the party');
    });

    test('an invite shows, can be accepted; a full party says so', () async {
      final together = model.together;
      final invite = {'partyId': 'p-ana', 'from': FakeTogether.card('u-ana', 'ana', 'Ana'), 'size': 2};
      server.partyInvites.add(invite);
      server.push('party.invite', invite);
      await until(() => together.partyBadge == 1);
      expect(model.toast, 'Ana invites you to a party');
      model.open(Layer.party);
      expect(rowIds().take(2), ['party-accept-p-ana', 'party-decline-p-ana']);
      expect(model.panelCategories().single.rows.first.detail, '2 of 8 in it');
      (model.panelCategories().single.rows.first.kind as ActionRow).run();
      await until(() => together.hub.parties.party?.id == 'p-ana');
      expect(rowIds(), contains('party-member-u-ana'));

      server.partyInvites.add({...invite, 'partyId': 'p-full', 'full': true});
      await together.joinParty('p-full');
      expect(model.toast, 'The party is full');
    });

    test("a party bigger than the mesh: the server's size, and voice through the media server", () async {
      final together = model.together;
      await together.startParty();
      server.party!['max'] = 24;
      server.push('party.updated', server.party);
      await until(() => together.hub.parties.party?.max == 24);
      model.open(Layer.party);
      expect(row('party-members').title, 'In the party · 1/24');

      server.answers['POST calls'] = (
        201,
        {
          'call': {'id': 'c-big', 'kind': 'party', 'partyId': server.party!['id'], 'media': 'sfu', 'in': const []},
          'iceServers': const [],
          'expiresAt': null,
          'sfu': {'url': 'wss://media.example.org', 'token': 'jwt', 'room': 'call-c-big', 'identity': 'u-me'},
        },
      );
      await together.joinVoice();
      expect(model.toast, "You're in voice");
      expect(together.hub.voice.viaServer, isTrue);
      expect(row('voice-leave').detail, 'Through the media server');
    });
  });

  group('message actions, receipts, pins', () {
    setUp(() async {
      server = await FakeTogether.start();
      server
        ..friend('u-ana', 'ana', 'Ana', presence: {'state': 'online'})
        ..friend('u-bora', 'bora', 'Bora')
        ..friend('u-cem', 'cem', 'Cem');
      // Sent just now, so the user's own can still be edited.
      server.messageTime = (seq) => DateTime.now().toUtc().subtract(Duration(seconds: 60 - seq)).toIso8601String();
      server.conversation(
        'c-ana',
        [FakeTogether.card('u-ana', 'ana', 'Ana')],
        texts: [('u-ana', 'Hi!'), ('u-me', 'Hey'), ('u-ana', 'Playing tonight?')],
        updatedAt: '2026-10-24T21:00:00Z',
      );
      server.conversation(
        'c-group',
        [FakeTogether.card('u-ana', 'ana', 'Ana'), FakeTogether.card('u-cem', 'cem', 'Cem')],
        texts: [('u-me', 'Who is in?'), ('u-cem', 'Me')],
        readSeq: 1,
      );
      server.conversation('c-bora', [FakeTogether.card('u-bora', 'bora', 'Bora')], updatedAt: '2026-10-24T19:00:00Z');
      fixture = makeFixture(together: server.base);
      model = fixture.model;
      model.together.email = 'utku@example.com';
      await model.together.sendCode();
      model.together.code = '123456';
      await model.together.verify();
      await until(() => model.together.hub.friends.loaded && model.together.hub.messages.loaded);
    });

    tearDown(() async {
      model.dispose();
      await server.close();
      T.language = Language.english;
      fixture.dispose();
    });

    TextRow field() => model.together.draftField.kind as TextRow;

    test('the server counts what is unread; the list keeps its order, pinned first', () async {
      final messages = model.together.hub.messages;
      expect(messages.conversations.map((c) => c.id), ['c-ana', 'c-group', 'c-bora']);
      expect(messages.byId('c-ana')!.unread, 2, reason: "Ana's two, not mine");
      expect(messages.byId('c-group')!.unread, 1);
      expect(messages.unread, 3);
      expect(messages.byId('c-ana')!.receipts!.single.deliveredSeq, 0);
      expect(messages.byId('c-group')!.receipts!.length, 2);
    });

    test('a message: react (and take it back), reply; the reactions others add come in', () async {
      final together = model.together;
      final messages = together.hub.messages;
      await together.openMessages();
      await until(() => messages.thread.length == 3);
      model.handle(launcher.Command.right);
      model.handle(launcher.Command.up);
      expect(together.focusedMessage!.seq, 3);
      model.handle(launcher.Command.select);
      expect(together.messageMenuItems, ['react', 'reply', 'report'], reason: "Ana's: no edit, no unsend, a report");
      // 👍 ❤️ 😂: the third.
      model.handle(launcher.Command.right);
      model.handle(launcher.Command.right);
      model.handle(launcher.Command.select);
      expect(together.messageMenu, isNull);
      await until(() => messages.thread.last.reactions.isNotEmpty);
      expect(server.callsTo('conversations/c-ana/messages/3/reactions/laugh', method: 'PUT'), hasLength(1));
      expect(messages.thread.last.reacted('laugh', 'u-me'), isTrue);
      expect(messages.byId('c-ana')!.lastMessage!.reactions.single.name, 'laugh');

      // The chip again takes it back.
      await together.toggleReaction(messages.thread.last, 'laugh');
      expect(server.callsTo('conversations/c-ana/messages/3/reactions/laugh', method: 'DELETE'), hasLength(1));
      expect(messages.thread.last.reactions, isEmpty);

      server.push('message.reactions', {
        'conversationId': 'c-ana',
        'seq': 3,
        'reactions': [
          {
            'reaction': 'fire',
            'count': 2,
            'userIds': ['u-ana', 'u-cem'],
          },
        ],
      });
      await until(() => messages.thread.last.reactions.isNotEmpty);
      expect(messages.thread.last.reactions.single.count, 2);
      expect(messages.byId('c-ana')!.lastMessage!.reactions.single.name, 'fire');

      // Reply: the composer says to whom, Back drops it, the message sent quotes it.
      model.handle(launcher.Command.select);
      model.handle(launcher.Command.down);
      model.handle(launcher.Command.select);
      expect(together.replyingTo, 3);
      expect(model.editingRow, 'message-draft');
      expect(together.composerNote, ('Replying to Ana', 'Playing tonight?'));
      model.stopEditing();
      model.handle(launcher.Command.back);
      expect(together.replyingTo, isNull);
      expect(together.messagesInThread, isTrue);

      model.handle(launcher.Command.up);
      model.handle(launcher.Command.select);
      model.handle(launcher.Command.down);
      model.handle(launcher.Command.select);
      field().set('Yes, at nine');
      field().submit!();
      model.stopEditing();
      await until(() => server.threads['c-ana']!.length == 4);
      expect(server.callsTo('conversations/c-ana/messages', method: 'POST').last.body, {
        'clientId': messages.thread.last.id,
        'text': 'Yes, at nine',
        'replyTo': 3,
      });
      expect(together.replyingTo, isNull);
      await until(() => messages.thread.last.seq == 4);
      expect(messages.thread.last.replyTo, 3);
      expect(together.quoteOf(messages.thread.last), ('Ana', 'Playing tonight?'));
      // A quote of one not loaded, or removed.
      expect(together.quoteOf(messages.thread.last.copyWith(replyTo: 99)), ('', 'An earlier message'));
    });

    test('my own message: edit it, the edit limit, unsend it after asking', () async {
      final together = model.together;
      final messages = together.hub.messages;
      await together.openMessages();
      await until(() => messages.thread.length == 3);
      model.handle(launcher.Command.right);
      model.handle(launcher.Command.up);
      model.handle(launcher.Command.up);
      expect(together.focusedMessage!.text, 'Hey');
      model.handle(launcher.Command.select);
      expect(together.messageMenuItems, ['react', 'reply', 'edit', 'unsend']);
      model.handle(launcher.Command.down);
      model.handle(launcher.Command.down);
      model.handle(launcher.Command.select);
      expect(together.editingMessage!.seq, 2);
      expect(together.draft, 'Hey');
      expect(together.composerNote, ('Edit', 'Hey'));
      field().set('Hey there');
      field().submit!();
      model.stopEditing();
      await until(() => messages.thread[1].text == 'Hey there');
      expect(server.callsTo('conversations/c-ana/messages/2', method: 'PATCH').single.body, {'text': 'Hey there'});
      expect(messages.thread[1].edited, isTrue);
      expect(messages.thread[1].editCount, 1);
      expect(together.editingMessage, isNull);
      expect(together.draft, isEmpty);

      // The server says no more edits.
      server.answers['PATCH conversations/c-ana/messages/2'] = FakeTogether.problem(409, 'edit_limit');
      together.startEdit(messages.thread[1]);
      field().set('Hey there!');
      field().submit!();
      model.stopEditing();
      await until(() => model.toast == "This message can't be edited any more.");
      expect(messages.thread[1].text, 'Hey there');

      // Unsend: asked first; Cancel keeps it.
      together.focusMessage(messages.thread[1]);
      model.handle(launcher.Command.select);
      model.handle(launcher.Command.down);
      model.handle(launcher.Command.down);
      model.handle(launcher.Command.down);
      model.handle(launcher.Command.select);
      expect(together.messageMenu!.confirming, isTrue);
      expect(together.messageMenuItems, ['unsend-confirm', 'cancel']);
      model.handle(launcher.Command.down);
      model.handle(launcher.Command.select);
      expect(together.messageMenu, isNull);
      expect(server.callsTo('conversations/c-ana/messages/2', method: 'DELETE'), isEmpty);
      model.handle(launcher.Command.select);
      for (var i = 0; i < 3; i++) {
        model.handle(launcher.Command.down);
      }
      model.handle(launcher.Command.select);
      model.handle(launcher.Command.select);
      await until(() => messages.thread[1].deleted);
      expect(server.callsTo('conversations/c-ana/messages/2', method: 'DELETE'), hasLength(1));
      expect(messages.thread[1].text, isNull);
      // A removed one has nothing to do.
      model.handle(launcher.Command.select);
      expect(together.messageMenu, isNull);
      expect(T.text('messagesDeleted'), 'Message removed');
    });

    test("receipts: Ana's delivered and read marks, the group's, mine from another device", () async {
      final together = model.together;
      final messages = together.hub.messages;
      await together.openMessages();
      await until(() => messages.thread.length == 3);
      final mine = messages.thread[1];
      expect(together.receiptText(messages.byId('c-ana')!, mine), 'Sent');
      server.push('conversation.delivered', {'conversationId': 'c-ana', 'userId': 'u-ana', 'upToSeq': 2});
      await until(() => messages.byId('c-ana')!.receipts!.single.deliveredSeq == 2);
      expect(together.receiptText(messages.byId('c-ana')!, mine), 'Delivered');
      server.push('conversation.delivered', {'conversationId': 'c-ana', 'userId': 'u-ana', 'upToSeq': 1});
      server.push('conversation.read', {'conversationId': 'c-ana', 'userId': 'u-ana', 'upToSeq': 3});
      await until(() => messages.byId('c-ana')!.receipts!.single.readSeq == 3);
      expect(messages.byId('c-ana')!.receipts!.single.deliveredSeq, 3, reason: 'read is delivered too, never lower');
      expect(together.receiptText(messages.byId('c-ana')!, mine), 'Read');
      expect(together.receiptText(messages.byId('c-ana')!, messages.thread[0]), isNull, reason: "Ana's own");
      expect(together.receiptFor(messages.byId('c-ana')!)?.seq, 2, reason: 'under my newest one only');

      // The group: seen by some, then everyone.
      final group = messages.byId('c-group')!;
      final asked = ChatMessage.fromJson(server.threads['c-group']!.first);
      expect(together.receiptText(group, asked), 'Sent');
      server.push('conversation.read', {'conversationId': 'c-group', 'userId': 'u-cem', 'upToSeq': 2});
      await until(() => together.receiptText(messages.byId('c-group')!, asked) == 'Seen by 1');
      server.push('conversation.read', {'conversationId': 'c-group', 'userId': 'u-ana', 'upToSeq': 1});
      await until(() => together.receiptText(messages.byId('c-group')!, asked) == 'Seen by everyone');

      // Read on my phone: the group's count is the server's.
      final counted = server.callsTo('me/conversations/unread').length;
      server.conversations['c-group']!['readSeq'] = 2;
      server.push('conversation.read', {'conversationId': 'c-group', 'userId': 'u-me', 'upToSeq': 2, 'unread': 0});
      await until(() => messages.byId('c-group')!.unread == 0);
      expect(messages.byId('c-group')!.readSeq, 2);
      await until(() => server.callsTo('me/conversations/unread').length > counted);
      await until(() => messages.unread == 0);
    });

    test('a removed message I had not read is not unread any more', () async {
      final messages = model.together.hub.messages;
      expect(messages.byId('c-group')!.unread, 1);
      final removed = server.threads['c-group']![1]
        ..['text'] = null
        ..['deletedAt'] = '2026-10-24T21:00:00Z';
      server.conversations['c-group']!['lastMessage'] = removed;
      server.push('message.deleted', removed);
      await until(() => messages.byId('c-group')!.unread == 0);
      expect(messages.byId('c-group')!.lastMessage!.deleted, isTrue);
      await until(() => messages.unread == 2);
    });

    test('a direct message that arrives off screen is marked delivered; the open one is read instead', () async {
      final together = model.together;
      final messages = together.hub.messages;
      await together.openMessages();
      await until(() => messages.openId == 'c-ana' && messages.thread.length == 3);
      server.receive('c-bora', 'u-bora', 'Yo');
      await until(() => server.callsTo('conversations/c-bora/delivered').isNotEmpty);
      expect(server.callsTo('conversations/c-bora/delivered').single.body, {'upToSeq': 1});
      server.receive('c-group', 'u-cem', 'Anyone?');
      server.receive('c-ana', 'u-ana', 'Here?');
      await until(() => server.callsTo('conversations/c-ana/read').any((call) => call.body['upToSeq'] == 4));
      expect(server.callsTo('conversations/c-group/delivered'), isEmpty, reason: 'groups have no delivered');
      expect(server.callsTo('conversations/c-ana/delivered'), isEmpty);
    });

    test('a conversation: pin it to the top (five at most), mute it', () async {
      final together = model.together;
      final messages = together.hub.messages;
      await together.openMessages();
      model.handle(launcher.Command.down);
      model.handle(launcher.Command.options);
      expect(together.messageMenu!.conversationId, 'c-group');
      expect(together.messageMenuItems, ['pin', 'mute']);
      expect(together.menuLabel('pin'), 'Pin to top');
      model.handle(launcher.Command.select);
      await until(() => messages.byId('c-group')!.pinned);
      expect(server.callsTo('conversations/c-group/pin').single.body, {'pinned': true});
      expect(messages.conversations.map((c) => c.id), ['c-group', 'c-ana', 'c-bora']);
      expect((together.selectedTarget as ConversationTarget).conversation.id, 'c-group', reason: 'the keys follow it');

      // A message elsewhere does not pass a pinned one.
      server.receive('c-bora', 'u-bora', 'Yo');
      await until(() => messages.byId('c-bora')!.lastSeq == 1);
      expect(messages.conversations.map((c) => c.id), ['c-group', 'c-bora', 'c-ana']);

      server.answers['PUT conversations/c-bora/pin'] = FakeTogether.problem(409, 'full');
      await together.setPinned(messages.byId('c-bora')!, true);
      expect(model.toast, 'You can pin up to 5 conversations.');
      expect(messages.byId('c-bora')!.pinned, isFalse);

      // Mute: no word on screen for it any more.
      together.openConversationMenu(messages.byId('c-group')!);
      expect(together.menuLabel('pin'), 'Unpin');
      expect(together.menuLabel('mute'), 'Mute notifications');
      model.handle(launcher.Command.down);
      model.handle(launcher.Command.select);
      await until(() => messages.byId('c-group')!.muted);
      expect(server.callsTo('conversations/c-group/mute').single.body, {'muted': true});
      model.handle(launcher.Command.back);
      expect(model.overlay, isNull);
      model.toast = null;
      server.receive('c-group', 'u-cem', 'Quiet one');
      await until(() => messages.byId('c-group')!.lastSeq == 3);
      expect(model.toast, isNull);
      server.receive('c-ana', 'u-ana', 'Loud one');
      await until(() => model.toast == 'Ana: Loud one');
    });

    test('a conversation clicked in the list is the one shown and answered', () async {
      final together = model.together;
      final messages = together.hub.messages;
      await together.openMessages();
      await until(() => messages.openId == 'c-ana' && messages.thread.length == 3);
      final bora = together.messageTargets.firstWhere((t) => TogetherMessages.targetKey(t) == 'c-bora');
      await together.pickMessageTarget(bora);
      expect(messages.openId, 'c-bora');
      expect(together.messagesInThread, isTrue);
      expect(together.messageFocus, TogetherMessages.composer);
      expect(TogetherMessages.targetKey(together.selectedTarget!), 'c-bora');
      await together.sendMessage('Hi Bora');
      await until(() => server.threads['c-bora']!.isNotEmpty);
      expect(server.threads['c-bora']!.last['text'], 'Hi Bora');
      expect(server.threads['c-ana']!.length, 3, reason: 'not to the conversation shown before');
    });

    test('a message in another conversation moves the list, not the conversation chosen', () async {
      final together = model.together;
      final messages = together.hub.messages;
      await together.openMessages();
      await until(() => messages.openId == 'c-ana');
      model.handle(launcher.Command.down);
      await until(() => messages.openId == 'c-group' && messages.thread.length == 2);
      model.handle(launcher.Command.right);
      expect(together.messagesInThread, isTrue);
      // Bora writes: his conversation goes to the top, above the one chosen.
      server.receive('c-bora', 'u-bora', 'Up for a game?');
      await until(() => messages.conversations.first.id == 'c-bora');
      expect(TogetherMessages.targetKey(together.selectedTarget!), 'c-group');
      expect(messages.openId, 'c-group');
      await together.sendMessage('Count me in');
      await until(() => server.threads['c-group']!.length == 3);
      expect(server.threads['c-bora']!.length, 1);
    });

    test('a message notification opens its conversation, with the keys in the field', () async {
      final together = model.together;
      final messages = together.hub.messages;
      together.openNotice(
        Notice(
          id: 'n-1',
          kind: NoticeKind.message,
          kindName: 'message',
          data: const {'conversationId': 'c-group', 'count': 1, 'text': 'Me'},
          createdAt: DateTime.now(),
        ),
      );
      await until(() => messages.openId == 'c-group' && messages.thread.length == 2);
      expect(model.overlay, Layer.messages);
      expect(TogetherMessages.targetKey(together.selectedTarget!), 'c-group');
      expect(together.messagesInThread, isTrue);
      expect(together.messageFocus, TogetherMessages.composer);
    });

    test('the toast of a message that came takes a click to its conversation', () async {
      final together = model.together;
      server.receive('c-bora', 'u-bora', 'You there?');
      await until(() => model.toast == 'Bora: You there?');
      expect(model.toastTap, isNotNull);
      model.toastTap!();
      await until(() => together.hub.messages.openId == 'c-bora');
      expect(model.overlay, Layer.messages);
      expect(TogetherMessages.targetKey(together.selectedTarget!), 'c-bora');
      expect(together.messagesInThread, isTrue);
      model.show('Something else');
      expect(model.toastTap, isNull, reason: 'other toasts go nowhere');
    });

    test('a new group: friends picked, a name, then Start the group opens it to write in', () async {
      final together = model.together;
      await together.openMessages();
      final targets = together.messageTargets;
      final at = targets.indexWhere((target) => target is NewGroupTarget);
      expect(at, greaterThan(0));
      expect(targets.sublist(0, at), everyElement(isA<ConversationTarget>()), reason: 'after the conversations');
      expect(
        targets.sublist(at + 1),
        everyElement(isA<FriendTarget>()),
        reason: 'before the friends to start one with',
      );
      while (together.messagesIndex < at) {
        model.handle(launcher.Command.down);
      }
      model.handle(launcher.Command.select);
      expect(together.messagesInThread, isTrue);
      expect(together.groupFocus, 0);

      // Nobody picked: it says so.
      await together.startGroup();
      expect(model.toast, 'Pick at least one friend first');
      expect(server.callsTo('conversations', method: 'POST'), isEmpty);

      // The name first, then the friends in their order, then Start the group.
      model.handle(launcher.Command.select);
      expect(model.editingRow, TogetherMessages.groupNameRow);
      (together.groupNameField.kind as TextRow).set('Friday night');
      model.stopEditing();
      final friends = together.groupFriends;
      void focus(int row) {
        while (together.groupFocus < row) {
          model.handle(launcher.Command.down);
        }
        while (together.groupFocus > row) {
          model.handle(launcher.Command.up);
        }
      }

      final bora = friends.indexWhere((friend) => friend.person.id == 'u-bora') + 1;
      final cem = friends.indexWhere((friend) => friend.person.id == 'u-cem') + 1;
      focus(bora);
      model.handle(launcher.Command.select);
      focus(cem);
      model.handle(launcher.Command.select);
      expect(together.groupPicked, {'u-bora', 'u-cem'});
      // Picked twice is out again.
      model.handle(launcher.Command.select);
      expect(together.groupPicked, {'u-bora'});
      model.handle(launcher.Command.select);
      focus(friends.length + 1);
      // Past the last row the keys stay on Start the group.
      model.handle(launcher.Command.down);
      expect(together.groupFocus, friends.length + 1);
      model.handle(launcher.Command.select);
      await until(() => server.callsTo('conversations', method: 'POST').isNotEmpty);
      final body = server.callsTo('conversations', method: 'POST').single.body;
      expect(body['group'], isTrue);
      expect(body['title'], 'Friday night');
      expect((body['members'] as List).toSet(), {'u-bora', 'u-cem'});
      await until(() => model.toast == 'Friday night is ready');
      final opened = together.selectedTarget;
      expect(opened, isA<ConversationTarget>());
      expect((opened! as ConversationTarget).conversation.title, 'Friday night');
      expect(together.hub.messages.openId, (opened as ConversationTarget).conversation.id);
      expect(together.messagesInThread, isTrue);
      expect(model.editingRow, 'message-draft', reason: 'ready to write in');
      expect(together.groupPicked, isEmpty);
      expect(together.groupName, isEmpty);
    });

    test('read receipts: the setting from the server, changed here and on another device', () async {
      final together = model.together;
      server.me['readReceipts'] = false;
      await together.hub.self.refresh();
      openTogether();
      PanelRow row() =>
          model.panelCategories()[model.panelCategory].rows.firstWhere((r) => r.id == 'together-receipts');
      expect(row().title, 'Send read receipts');
      expect(row().detail, startsWith("When off, people don't see"));
      expect((row().kind as ToggleRow).value, isFalse);
      (row().kind as ToggleRow).set(true);
      await until(() => server.callsTo('me/read-receipts').isNotEmpty);
      expect(server.callsTo('me/read-receipts').single.body, {'readReceipts': true});
      await until(() => (row().kind as ToggleRow).value);
      final lists = server.callsTo('me/conversations').length;
      server.push('messages.settings', {'readReceipts': false});
      await until(() => !(row().kind as ToggleRow).value);
      // What the others' receipts show depends on it: the list again.
      await until(() => server.callsTo('me/conversations').length > lists);
    });

    test('your profile: the name, bio and country saved, the handle changed, as on the Mac', () async {
      final together = model.together;
      server.me.addAll({'bio': 'Night owl', 'country': 'TR'});
      await together.hub.self.refresh();
      openTogether();
      PanelRow row(String id) => model.panelCategories()[model.panelCategory].rows.firstWhere((r) => r.id == id);
      expect(rowIds(), contains('together-public-profile'));
      expect(
        rowIds(),
        containsAllInOrder([
          'together-profile',
          'together-edit',
          'together-name',
          'together-bio',
          'together-country',
          'together-save',
          'together-handle',
          'together-handle-save',
          'private-title',
        ]),
      );
      expect(row('together-edit').title, 'Your profile');
      expect((row('together-name').kind as TextRow).value, 'Utku');
      expect((row('together-bio').kind as TextRow).value, 'Night owl');
      // The country by its name, on a row that opens the list: no code to type.
      expect(row('together-country').kind, isA<ActionRow>());
      expect(row('together-country').detail, 'Türkiye');
      expect(row('together-handle').detail, 'Can change once every 30 days.');

      // Only what changed goes; the country in capitals.
      (row('together-name').kind as TextRow).set('Utku Halis');
      (row('together-country').kind as ActionRow).run();
      expect(model.overlay, Layer.countryPicker);
      (row(TogetherModel.countrySearchRow).kind as TextRow).set('germ');
      expect(rowIds(), [TogetherModel.countrySearchRow, 'country-DE']);
      (row('country-DE').kind as ActionRow).run();
      expect(model.overlay, Layer.settings, reason: 'chosen: back where the list was opened from');
      expect(row('together-country').detail, 'Germany');
      (row('together-save').kind as ActionRow).run();
      await until(() => model.toast == 'Profile saved');
      expect(server.callsTo('me/profile').single.body, {'displayName': 'Utku Halis', 'country': 'DE'});
      expect(together.user!.displayName, 'Utku Halis');
      expect(row('together-country').detail, 'Germany');
      // A blank bio clears it.
      (row('together-bio').kind as TextRow).set('  ');
      await together.saveProfile();
      expect(server.callsTo('me/profile').last.body, {'bio': null});
      expect(together.hub.self.bio, isNull);

      // The handle: a bad one, one taken, then a new one and the next change's day.
      server.person('u-ana', 'ana', 'Ana');
      (row('together-handle').kind as TextRow).set('a!');
      (row('together-handle-save').kind as ActionRow).run();
      await until(() => model.toast == '3–20 characters: a–z, 0–9, _ and .');
      (row('together-handle').kind as TextRow).set('ana');
      await together.changeHandle();
      expect(model.toast, 'That handle is taken');
      (row('together-handle').kind as TextRow).set('@Utku.H');
      await together.changeHandle();
      expect(server.callsTo('me/handle').last.body, {'handle': 'utku.h'});
      expect(model.toast, 'You are @utku.h now');
      expect(together.user!.handle, 'utku.h');
      expect(row('together-handle').detail, startsWith('Can change again on 20'));
      // Again too soon: the day it may.
      (row('together-handle').kind as TextRow).set('utku2');
      await together.changeHandle();
      expect(model.toast, startsWith('Can change again on 20'));
    });

    test('who sees what: a choice per part, shown at once and put back when the server says no', () async {
      final together = model.together;
      server.me['privacy'] = {
        'library': 'everyone',
        'trophies': 'friends',
        'friends': 'nobody',
        'presence': 'friends',
        'search': 'nobody',
        'gallery': 'friends',
      };
      await together.hub.self.refresh();
      openTogether();
      PanelRow row(String id) => model.panelCategories()[model.panelCategory].rows.firstWhere((r) => r.id == id);
      expect(
        rowIds(),
        containsAllInOrder([
          'private-title',
          'together-privacy',
          'privacy-library',
          'privacy-trophies',
          'privacy-friends',
          'privacy-presence',
          'privacy-search',
        ]),
      );
      expect(rowIds(), isNot(contains('privacy-gallery')), reason: 'this server keeps no files');
      expect(row('together-privacy').title, 'Who sees what');
      final library = row('privacy-library');
      expect(library.title, 'Games and play time');
      expect((library.kind as ChoiceRow).options, ['Everyone', 'Friends', 'Only me']);
      expect((library.kind as ChoiceRow).selected, 0);
      expect((row('privacy-friends').kind as ChoiceRow).selected, 2);
      // Being found by name: nobody, not "only me".
      expect((row('privacy-search').kind as ChoiceRow).options.last, 'Nobody');

      (row('privacy-trophies').kind as ChoiceRow).set(0);
      expect((row('privacy-trophies').kind as ChoiceRow).selected, 0, reason: 'shown at once');
      await until(() => server.callsTo('me/privacy').isNotEmpty);
      expect(server.callsTo('me/privacy').single.body, {'trophies': 'everyone'});
      expect(together.hub.self.privacy[PrivacySection.trophies], ProfileVisibility.everyone);

      server.answers['PATCH me/privacy'] = FakeTogether.problem(403, 'forbidden', 'Not allowed');
      await together.setPrivacy(PrivacySection.presence, ProfileVisibility.everyone);
      expect((row('privacy-presence').kind as ChoiceRow).selected, 1, reason: 'put back');
      expect(model.toast, 'You\'re not allowed to do that.', reason: 'the launcher\'s words, not the server\'s');
    });
  });

  group('profiles and playing together', () {
    late Map<String, dynamic> ana;

    setUp(() async {
      server = await FakeTogether.start();
      server.friend('u-ana', 'ana', 'Ana', presence: {'state': 'online'});
      ana = FakeTogether.card('u-ana', 'ana', 'Ana');
      server.profiles['utku'] = {
        'userId': 'u-me',
        'handle': 'utku',
        'displayName': 'Utku',
        'bio': 'Plays at night',
        'country': 'TR',
        'friendship': 'me',
      };
      server.libraries['utku'] = [
        {
          'titleId': 'PPSA01001',
          'names': {'en': 'Orbit Runner'},
          'lastPlayedAt': '2026-10-24T21:00:00Z',
          'secondsPlayed': 12000,
          'trophiesEarned': 2,
          'trophiesTotal': 5,
          'progress': 40,
          'points': 45,
        },
        {
          'titleId': 'PPSA09999',
          'names': {'en': 'Elsewhere', 'tr': 'Başka Yerde'},
          'secondsPlayed': 600,
          'trophiesEarned': null,
          'trophiesTotal': null,
          'progress': null,
          'points': null,
        },
      ];
      server.trophyLists['utku'] = [
        {
          'titleId': 'PPSA01001',
          'gameNames': {'en': 'Orbit Runner'},
          'trophyId': 2,
          'grade': 'gold',
          'hidden': false,
          'texts': {
            'en': {'name': 'Far Side'},
          },
          'earnedAt': '2026-10-24T21:00:00Z',
          'rarity': 0.04,
          'rarityLabel': 'very_rare',
        },
      ];
      server.profiles['ana'] = {'userId': 'u-ana', 'handle': 'ana', 'displayName': 'Ana', 'friendship': 'friends'};
      fixture = makeFixture(together: server.base);
      model = fixture.model;
      model.together.email = 'utku@example.com';
      await model.together.sendCode();
      model.together.code = '123456';
      await model.together.verify();
      await until(() => model.together.hub.friends.loaded);
    });

    tearDown(() async {
      model.dispose();
      await server.close();
      T.language = Language.english;
      fixture.dispose();
    });

    test('my profile: games, play time, trophies and totals; back to where it was opened', () async {
      model.open(Layer.friends);
      final mine = model.panelCategories().single.rows.first;
      expect(mine.id, 'friends-me');
      (mine.kind as ActionRow).run();
      expect(model.overlay, Layer.profile);
      await until(() => model.together.profile != null);
      final page = model.together.profile!;
      expect(page.profile.isMe, isTrue);
      expect(page.totals, (games: 2, seconds: 12600, trophies: 2, points: 45));
      expect(page.library.value!.last.name('tr'), 'Başka Yerde');
      expect(page.trophies.value!.single.name('en'), 'Far Side');
      expect(TogetherProfiles.playTime(12000), '3 h 20 min');
      expect(TogetherProfiles.playTime(7200), '2 h');
      expect(TogetherProfiles.playTime(600), '10 min');
      model.handle(launcher.Command.down);
      model.handle(launcher.Command.down);
      expect(model.together.profileIndex, 2);
      model.handle(launcher.Command.back);
      expect(model.overlay, Layer.friends);
    });

    test("a friend's profile keeps what they keep private; details fall back to their card", () async {
      server.privateParts['ana'] = {'profile', 'library'};
      await model.together.openProfile(
        'ana',
        card: const Person(id: 'u-ana', handle: 'ana', displayName: 'Ana'),
      );
      final page = model.together.profile!;
      expect(page.detailsPrivate, isTrue);
      expect(page.profile.displayName, 'Ana');
      expect(page.library, isA<SectionPrivate<List<PlayedGame>>>());
      expect(page.trophies, isA<SectionShown<List<EarnedTrophy>>>());
      expect(page.totals, isNull);
    });

    test('while a game runs, friends see a session they can join; it ends with the game', () async {
      final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
      final installed = Installer.installedFolder(orbit, model.root!);
      File(p.join(installed, 'app.elf')).writeAsStringSync('#!/bin/sh\nenv | grep ^ANYPS5_TOGETHER\nsleep 0.6\n');
      if (!Platform.isWindows) Process.runSync('chmod', ['755', p.join(installed, 'app.elf')]);
      final playing = model.play(orbit);
      await until(() => model.together.hub.games.session != null);
      expect(server.callsTo('game-sessions', method: 'POST').single.body, {
        'titleId': 'PPSA01001',
        'gameVersion': '01.000.000',
        'engineBuild': 'toolkit-1',
        'capacity': 4,
        'joinable': true,
      });
      final bridge = File(model.together.hub.games.bridgeFile);
      final written = jsonDecode(bridge.readAsStringSync()) as Map<String, dynamic>;
      expect(written['role'], 'host');
      expect(written['userId'], 'u-me');

      // Friends join only when it is let.
      await model.together.setFriendsJoin(false);
      expect(server.callsTo('game-sessions/${written['session']['id']}', method: 'PATCH').single.body, {
        'joinable': false,
      });
      await playing;
      await until(() => model.together.hub.games.session == null);
      await until(() => server.callsTo('game-sessions/${written['session']['id']}', method: 'DELETE').isNotEmpty);
      expect(bridge.existsSync(), isFalse);
      expect(
        File(model.paths.logFile('PPSA01001')).readAsStringSync(),
        contains('ANYPS5_TOGETHER_SESSION=${bridge.path}'),
      );
    });

    test('online play: off by default; on, the game is started with the bridge and signed in as the user', () async {
      final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
      final installed = Installer.installedFolder(orbit, model.root!);
      File(p.join(installed, 'app.elf')).writeAsStringSync('#!/bin/sh\nenv | grep ^ANYPS5_ONLINE\nsleep 0.4\n');
      if (!Platform.isWindows) Process.runSync('chmod', ['755', p.join(installed, 'app.elf')]);
      expect(model.preferences.onlinePlay, isFalse, reason: 'off by default');
      await model.play(orbit);
      expect(File(model.paths.logFile('PPSA01001')).readAsStringSync(), isNot(contains('ANYPS5_ONLINE')));

      openTogether();
      final row = model.panelCategories()[model.panelCategory].rows.firstWhere(
        (row) => row.id == 'together-online-play',
      );
      expect(row.title, 'Online play (experimental)');
      expect(row.detail, contains('@utku'));
      expect(row.detail, contains('never Sony'));
      (row.kind as ToggleRow).set(true);
      expect(model.preferences.onlinePlay, isTrue);
      expect(model.preferences.toJson()['onlinePlay'], isTrue);
      final log = model.panelCategories()[model.panelCategory].rows.firstWhere(
        (row) => row.id == 'together-online-log',
      );
      (log.kind as ActionRow).run();
      expect(fixture.folders, [model.paths.onlineLogs]);
      expect(Directory(model.paths.onlineLogs).existsSync(), isTrue);
      expect(model.paths.onlineLogs, endsWith(p.join('.local', 'state', 'AnyPS5', 'online')));

      // The game connects to the launcher's bridge with the secret it was started with.
      File(p.join(installed, 'app.elf')).writeAsStringSync('#!/bin/sh\nenv | grep ^ANYPS5_ONLINE\nsleep 3\n');
      final playing = model.play(orbit);
      final logFile = File(model.paths.logFile('PPSA01001'));
      String? line(String name) =>
          RegExp('^$name=(.*)\$', multiLine: true).allMatches(logFile.readAsStringSync()).lastOrNull?.group(1);
      await until(() => line('ANYPS5_ONLINE_SECRET') != null && model.together.online.running != null);
      expect(line('ANYPS5_ONLINE'), '127.0.0.1:${model.together.online.running!.bridge.port}');
      expect(line('ANYPS5_ONLINE_SECRET'), hasLength(64));
      expect(line('ANYPS5_ONLINE_LOG'), p.join(model.paths.onlineLogs, 'PPSA01001.jsonl'));
      final engine = (await FakeEngine.fromEnvironment({
        'ANYPS5_ONLINE': line('ANYPS5_ONLINE')!,
        'ANYPS5_ONLINE_SECRET': line('ANYPS5_ONLINE_SECRET')!,
      }))!;
      expect(engine.account?.signedIn, isTrue);
      expect(engine.account?.onlineId, 'utku');
      expect(engine.account?.accountId, OnlineIdentity.accountId('u-me'));
      final friends = await engine.web(
        WireWebRequest(userId: 0x10000000, apiGroup: 'userProfile', path: '/v1/users/me/friends', method: 'GET'),
      );
      expect(friends?.status, 200);
      expect((friends!.json! as Map)['friends'], [OnlineIdentity.account('u-ana')], reason: 'AnyTogether friends');
      await engine.close();
      await playing;
      await until(() => model.together.online.running == null);
    });

    test("joining a friend's game: the same version and engine, then the game starts", () async {
      server.hostSession('gs-ana', ana);
      final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
      final installed = Installer.installedFolder(orbit, model.root!);
      File(p.join(installed, 'app.elf')).writeAsStringSync('#!/bin/sh\nsleep 0.4\n');
      if (!Platform.isWindows) Process.runSync('chmod', ['755', p.join(installed, 'app.elf')]);
      await model.together.joinFriendGame('gs-ana', titleId: 'PPSA01001', host: 'Ana');
      expect(model.toast, 'Starting Orbit Runner with Ana');
      expect(server.callsTo('game-sessions/gs-ana/join').single.body, {
        'gameVersion': '01.000.000',
        'engineBuild': 'toolkit-1',
      });
      final written = jsonDecode(File(model.together.hub.games.bridgeFile).readAsStringSync()) as Map<String, dynamic>;
      expect(written['role'], 'guest');
      final session = written['session'] as Map<String, dynamic>;
      expect(session['properties'], {'mode': 'coop'});
      expect(((session['members'] as List).first as Map)['properties'], {'address': 'relay:1'});
      await until(() => model.running != null);
      await until(() => model.running == null);
      await until(() => server.callsTo('game-sessions/gs-ana/leave').isNotEmpty);
      expect(server.callsTo('game-sessions', method: 'POST'), isEmpty, reason: 'a guest opens no session of its own');
    });

    test('the version guard, a game not here or locked, a full game', () async {
      PanelRow row(String id) => model.panelCategories().single.rows.firstWhere((row) => row.id == id);
      String words(String id) => (row(id).kind as InfoRow).text;
      // What differs is named, and both versions are whole on lines of their own.
      server.hostSession('gs-v', ana, gameVersion: '01.001.000');
      await model.together.joinFriendGame('gs-v', titleId: 'PPSA01001', host: 'Ana');
      expect(model.overlay, Layer.joinBlocked);
      expect(row('blocked-what').title, 'Different game version');
      expect(
        words('blocked-what'),
        'Ana and you have different versions of Orbit Runner.\n'
        'You need Orbit Runner version 01.001.000; you have 01.000.000. Add the update to your library',
      );
      expect([row('blocked-host').title, words('blocked-host')], ['Ana', '01.001.000']);
      expect([row('blocked-you').title, words('blocked-you')], ['You', '01.000.000']);
      server.hostSession('gs-e', ana, engineBuild: '0.2.13-a1b2c3d4e5f6');
      await model.together.joinFriendGame('gs-e', titleId: 'PPSA01001', host: 'Ana');
      expect(model.overlay, Layer.joinBlocked);
      expect(row('blocked-what').title, 'Different engine build');
      expect(
        words('blocked-what'),
        'Ana and you run Orbit Runner on different builds of the AnyPS5 engine, so the two games cannot connect.\n'
        'The two engines are not the same build. Use the same engine on both',
      );
      expect(words('blocked-host'), '0.2.13-a1b2c3d4e5f6', reason: 'whole, not "0.2.13 (a1b2c3)"');
      expect(words('blocked-you'), 'toolkit-1');
      expect(row('blocked-what').wraps && row('blocked-host').wraps && row('blocked-you').wraps, isTrue);
      expect(rowIds(), ['blocked-what', 'blocked-host', 'blocked-you', 'blocked-close'], reason: 'no "update"');
      (row('blocked-close').kind as ActionRow).run();
      expect(model.overlay, isNull);
      expect(server.calls.where((call) => call.path.endsWith('/join')), isEmpty);

      await model.together.joinFriendGame('gs-x', titleId: 'PPSA09999', host: 'Ana');
      expect(model.toast, 'PPSA09999 is not in your library');
      await model.together.joinFriendGame('gs-x', titleId: 'PPSA02002', host: 'Ana');
      expect(model.toast, 'Unlock Neon Alley first');

      final full = server.hostSession('gs-full', ana);
      full['capacity'] = 1;
      await model.together.joinFriendGame('gs-full', titleId: 'PPSA01001', host: 'Ana');
      expect(model.toast, 'This game is full');
    });

    test('Play together: the host starts the selected game for the party with online play on for it only', () async {
      server.inParty([ana]);
      await model.together.hub.parties.refresh();
      final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
      model.select(model.games.indexOf(orbit));
      final installed = Installer.installedFolder(orbit, model.root!);
      File(p.join(installed, 'app.elf')).writeAsStringSync('#!/bin/sh\nenv | grep ^ANYPS5_ONLINE=\nsleep 0.6\n');
      if (!Platform.isWindows) Process.runSync('chmod', ['755', p.join(installed, 'app.elf')]);
      expect(model.preferences.onlinePlay, isFalse);
      model.open(Layer.party);
      final start = model.panelCategories().single.rows.firstWhere((row) => row.id == 'together-start');
      expect(start.title, 'Play together: Orbit Runner');
      (start.kind as ActionRow).run();
      await until(() => model.together.hub.games.session != null);
      final session = model.together.hub.games.session!;
      expect(session.together, isTrue);
      expect(server.callsTo('game-sessions', method: 'POST').single.body, {
        'kind': 'lan',
        'titleId': 'PPSA01001',
        'gameVersion': '01.000.000',
        'engineBuild': 'toolkit-1',
        'capacity': 8,
        'versionRule': 'exact',
      });
      await until(() => model.running != null);
      await model.together.hub.parties.refresh();
      model.open(Layer.party);
      expect(
        rowIds(),
        containsAllInOrder(['together-title', 'together-player-u-me', 'together-code', 'together-leave']),
      );
      final code = model.panelCategories().single.rows.firstWhere((row) => row.id == 'together-code');
      (code.kind as ActionRow).run();
      await until(() => model.toast == 'Join code K7QM-3XPA copied');
      await until(() => model.running == null);
      // The game exited: the session ends with it, and online play goes back to the setting.
      await until(() => server.callsTo('game-sessions/${session.id}?reason=game_exited', method: 'DELETE').isNotEmpty);
      expect(File(model.paths.logFile('PPSA01001')).readAsStringSync(), contains('ANYPS5_ONLINE=127.0.0.1:'));
      expect(model.preferences.onlinePlay, isFalse, reason: "the user's setting stays as it was");
      expect(model.together.togetherSession, isNull);
    });

    test("Play together: the party hears it start, and Join starts the same game in the host's session", () async {
      server.inParty([ana], leader: 'u-ana');
      await model.together.hub.parties.refresh();
      final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
      final installed = Installer.installedFolder(orbit, model.root!);
      File(p.join(installed, 'app.elf')).writeAsStringSync('#!/bin/sh\nenv | grep ^ANYPS5_ONLINE=\nsleep 0.4\n');
      if (!Platform.isWindows) Process.runSync('chmod', ['755', p.join(installed, 'app.elf')]);
      final lan = server.hostSession('gs-lan', ana, kind: 'lan');
      server.push('game_session.started', {'partyId': server.party!['id'], 'session': lan});
      await until(() => model.toast == 'Ana started Orbit Runner — Join');
      model.open(Layer.friends);
      expect(rowIds(), contains('together-offer-gs-lan'));
      await until(() => model.together.hub.parties.party?.together != null);
      model.open(Layer.party);
      expect(rowIds(), containsAllInOrder(['together-title', 'together-player-u-ana', 'together-join']));
      final join = model.panelCategories().single.rows.firstWhere((row) => row.id == 'together-join');
      expect(join.title, "Join Ana's Orbit Runner");
      (join.kind as ActionRow).run();
      await until(() => server.callsTo('game-sessions/gs-lan/join').isNotEmpty);
      expect(server.callsTo('game-sessions/gs-lan/join').single.body, {
        'gameVersion': '01.000.000',
        'engineBuild': 'toolkit-1',
      });
      await until(() => model.running != null);
      await until(() => model.running == null);
      expect(File(model.paths.logFile('PPSA01001')).readAsStringSync(), contains('ANYPS5_ONLINE=127.0.0.1:'));
      await until(() => server.callsTo('game-sessions/gs-lan/leave').isNotEmpty);
      model.open(Layer.friends);
      expect(rowIds(), isNot(contains('together-offer-gs-lan')), reason: 'joined, the offer is gone');
    });

    test(
      'Play together: Try anyway joins with another game version, never another engine; who tried is shown',
      () async {
        server.inParty([ana], leader: 'u-ana');
        server.hostSession('gs-v', ana, kind: 'lan', gameVersion: '01.001.000');
        (server.party!['together'] as Map)['versionOverrides'] = ['u-ana'];
        await model.together.hub.parties.refresh();
        model.open(Layer.party);
        List<String> ids() => model.panelCategories().single.rows.map((row) => row.id).toList();
        PanelRow row(String id) => model.panelCategories().single.rows.firstWhere((row) => row.id == id);
        expect(ids(), containsAllInOrder(['together-join', 'together-try-anyway']));
        expect(row('together-try-anyway').title, 'Try anyway');
        expect(row('together-player-u-ana').detail, contains('Tried anyway'));
        (row('together-try-anyway').kind as ActionRow).run();
        await until(() => server.callsTo('game-sessions/gs-v/join').isNotEmpty);
        expect(server.callsTo('game-sessions/gs-v/join').single.body, {
          'gameVersion': '01.000.000',
          'engineBuild': 'toolkit-1',
          'overrideVersion': true,
        });

        server.gameSessions.remove('gs-v');
        server.hostSession('gs-e', ana, kind: 'lan', gameVersion: '01.001.000', engineBuild: '0.2.13-a1b2c3d4e5f6');
        await model.together.hub.parties.refresh();
        model.open(Layer.party);
        expect(ids(), isNot(contains('together-try-anyway')), reason: 'another engine is never tried anyway');
      },
    );

    test('Play together: a different version or engine is named, a locked copy is unlocked first', () async {
      server.inParty([ana], leader: 'u-ana');
      server.hostSession('gs-v', ana, kind: 'lan', gameVersion: '01.001.000');
      await model.together.hub.parties.refresh();
      model.open(Layer.party);
      final join = model.panelCategories().single.rows.firstWhere((row) => row.id == 'together-join');
      expect(
        join.detail,
        'You need Orbit Runner version 01.001.000; you have 01.000.000. Add the update to your library',
      );
      (join.kind as ActionRow).run();
      await until(() => model.overlay == Layer.joinBlocked);
      expect(rowIds(), ['blocked-what', 'blocked-host', 'blocked-you', 'blocked-try-anyway', 'blocked-close']);
      expect(model.panelCategories().single.rows.first.title, 'Different game version');
      expect(server.calls.where((call) => call.path.endsWith('/join')), isEmpty);

      server.gameSessions.remove('gs-v');
      server.hostSession('gs-neon', ana, kind: 'lan', titleId: 'PPSA02002');
      await model.together.hub.parties.refresh();
      model.open(Layer.party);
      final unlock = model.panelCategories().single.rows.firstWhere((row) => row.id == 'together-join');
      expect(unlock.title, 'Unlock and play');

      server.gameSessions.remove('gs-neon');
      server.hostSession('gs-e', ana, kind: 'lan', engineBuild: '0.2.13-a1b2c3d4e5f6');
      await model.together.hub.parties.refresh();
      model.open(Layer.party);
      final engine = model.panelCategories().single.rows.firstWhere((row) => row.id == 'together-join');
      expect(
        engine.detail,
        'Different engine build\nThe two engines are not the same build. Use the same engine on both',
      );
      expect(engine.wraps, isTrue);

      T.language = Language.byCode('tr');
      expect(
        model.together.presenceText(
          Presence.fromJson({
            'state': 'in_game',
            'titleId': 'PPSA01001',
            'game': {
              'sessionId': 's',
              'titleId': 'PPSA01001',
              'kind': 'lan',
              'joinable': false,
              'players': 2,
              'capacity': 8,
            },
          }),
        ),
        'Yörünge Koşucusu birlikte oynanıyor (2/8)',
      );
    });

    test("an invite to a friend's game shows in the friends panel and can be declined", () async {
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
      expect(model.toast, 'Ana invites you to Orbit Runner');
      expect(model.together.hub.badge, 1);
      model.open(Layer.friends);
      // After My Profile, Find players, Activity, Captures and Leaderboard.
      expect(rowIds().skip(5).take(2), ['game-accept-gs-ana', 'game-decline-gs-ana']);
      (model.panelCategories().single.rows[6].kind as ActionRow).run();
      await until(() => server.callsTo('game-sessions/gs-ana/decline').isNotEmpty);
      expect(model.together.hub.badge, 0);
    });

    /// Ana hosts Orbit Runner in a session of her own, as her presence says it to her friends.
    Future<void> anaHostsOrbit({bool playing = true}) async {
      if (playing) server.hostSession('gs-ana', ana);
      server.friends.firstWhere((friend) => friend['userId'] == 'u-ana')['presence'] = playing
          ? {
              'state': 'in_game',
              'titleId': 'PPSA01001',
              'game': {
                'sessionId': 'gs-ana',
                'titleId': 'PPSA01001',
                'kind': 'online',
                'hostId': 'u-ana',
                'joinable': true,
                'players': 1,
                'capacity': 4,
              },
            }
          : {'state': 'online'};
      await model.together.hub.friends.refresh();
    }

    test('Play on a game a party member already hosts asks: join theirs (first), or start your own', () async {
      server.inParty([ana], leader: 'u-ana');
      await model.together.hub.parties.refresh();
      await anaHostsOrbit();
      final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
      final installed = Installer.installedFolder(orbit, model.root!);
      File(p.join(installed, 'app.elf')).writeAsStringSync('#!/bin/sh\nsleep 0.4\n');
      if (!Platform.isWindows) Process.runSync('chmod', ['755', p.join(installed, 'app.elf')]);
      PanelRow row(String id) => model.panelCategories().single.rows.firstWhere((row) => row.id == id);

      model.select(model.games.indexOf(orbit));
      model.primaryAction(orbit);
      expect(model.overlay, Layer.joinOrHost);
      expect(model.starting, isNull);
      expect(rowIds(), ['choice-ask', 'choice-join', 'choice-own']);
      expect((row('choice-ask').kind as InfoRow).text, 'Ana is playing this. Join their game, or start your own?');
      expect(model.panelRow, 1, reason: 'Join is the default');
      expect(row('choice-join').title, "Join Ana's Orbit Runner");
      expect(row('choice-own').title, 'Start my own game');
      expect(row('choice-own').detail, 'A separate session. Ana will not be in it.');

      model.handle(launcher.Command.select);
      await until(() => server.callsTo('game-sessions/gs-ana/join').isNotEmpty);
      await until(() => model.running != null);
      await until(() => model.running == null);
      await until(() => server.callsTo('game-sessions/gs-ana/leave').isNotEmpty);
      expect(
        server.callsTo('game-sessions', method: 'POST'),
        isEmpty,
        reason: 'the two are in one session: no second one was opened',
      );
    });

    test('starting your own game anyway says a separate session was made', () async {
      await anaHostsOrbit();
      final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
      final installed = Installer.installedFolder(orbit, model.root!);
      File(p.join(installed, 'app.elf')).writeAsStringSync('#!/bin/sh\nsleep 0.4\n');
      if (!Platform.isWindows) Process.runSync('chmod', ['755', p.join(installed, 'app.elf')]);
      model.select(model.games.indexOf(orbit));
      model.primaryAction(orbit);
      expect(model.overlay, Layer.joinOrHost);
      final own = model.panelCategories().single.rows.firstWhere((row) => row.id == 'choice-own');
      (own.kind as ActionRow).run();
      expect(model.overlay, isNull);
      expect(model.toast, 'You started a separate game. Ana is not in it');
      await until(() => model.running != null);
      await until(() => model.running == null);
      expect(server.callsTo('game-sessions/gs-ana/join'), isEmpty);

      // Nobody playing it, a full game or another title asks nothing.
      await anaHostsOrbit(playing: false);
      expect(model.together.joinableGame(orbit), isNull);
    });

    test('the party says for each member whose game they are in, with Join right there', () async {
      server.inParty([ana], leader: 'u-ana');
      await model.together.hub.parties.refresh();
      await anaHostsOrbit();
      PanelRow row(String id) => model.panelCategories().single.rows.firstWhere((row) => row.id == id);
      model.open(Layer.party);
      expect(
        (row('together-about').kind as InfoRow).text,
        'A party is voice and chat. A game session is what connects your games',
      );
      expect(row('party-member-u-ana').detail, endsWith('Playing Orbit Runner'));
      expect(rowIds(), containsAllInOrder(['party-member-u-ana', 'party-member-join-u-ana']));
      expect(row('party-member-join-u-ana').title, "Join Ana's Orbit Runner");
      expect(row('party-member-u-me').detail, isNot(contains('game')), reason: "the user's own row says nothing of it");
      // The quick menu has the same member, as the Join itself.
      final quick = model.together.partyGameRows();
      expect(quick.map((row) => row.id), ['party-game-u-ana']);
      expect(quick.single.title, "Join Ana's Orbit Runner");
      expect(quick.single.kind, isA<ActionRow>());

      final together = model.together;
      expect(together.memberGameText(const InYourGame()), 'In your game');
      expect(
        together.memberGameText(
          const InOtherGame(
            sessionId: 's',
            titleId: 'PPSA01001',
            hostId: 'u-ana',
            joinable: true,
            together: false,
            sameTitle: true,
          ),
        ),
        'In another game of Orbit Runner',
      );

      await anaHostsOrbit(playing: false);
      model.open(Layer.party);
      expect(row('party-member-u-ana').detail, endsWith('Not in a game'));
      expect(rowIds(), isNot(contains('party-member-join-u-ana')));
      expect((together.partyGameRows().single.kind as InfoRow).text, 'Not in a game');
    });

    test('a join held back names what differs, shows both builds whole and offers the action that fits', () {
      const nightly = '0.2.36-arm-nightly.20261110.1-a6fff1ba742d';
      const stable = '0.2.36-arm-f75c475400e3';
      final together = model.together;
      String advice(List<PanelRow> rows) => (rows.first.kind as InfoRow).text.split('\n').last;
      List<String> ids(List<PanelRow> rows) => [for (final row in rows) row.id];
      JoinBlock block(EngineAdvice advice, String host, String yours, {void Function()? rebuild}) => JoinBlock.engine(
        advice: advice,
        hostName: 'Mira',
        gameName: 'Greenhollow',
        host: host,
        yours: yours,
        rebuild: rebuild,
      );

      // Both launchers current, the host's copy still the nightly's: nobody here is told to update.
      final newer = together.joinBlockedRows(block(EngineAdvice.updateHost, nightly, stable));
      expect(newer.first.title, 'Different engine build');
      expect(advice(newer), 'This AnyPS5 is newer. Ask Mira to update AnyPS5 and start the game again');
      expect((newer[1].kind as InfoRow).text, nightly);
      expect((newer[2].kind as InfoRow).text, stable);
      expect(ids(newer), ['blocked-what', 'blocked-host', 'blocked-you', 'blocked-close']);

      var rebuilt = false;
      final stale = together.joinBlockedRows(
        block(EngineAdvice.rebuild, stable, nightly, rebuild: () => rebuilt = true),
      );
      expect(advice(stale), 'Your copy was made with another engine. Rebuild it and you can join');
      expect(ids(stale), ['blocked-what', 'blocked-host', 'blocked-you', 'blocked-rebuild', 'blocked-close']);
      expect(stale[3].title, 'Rebuild and join');
      together.tell(block(EngineAdvice.rebuild, stable, nightly));
      (stale[3].kind as ActionRow).run();
      expect(rebuilt, isTrue);
      expect(model.overlay, isNull);

      final older = together.joinBlockedRows(block(EngineAdvice.updateYours, stable, '0.2.35-arm-0123456789ab'));
      expect(advice(older), 'Mira plays on a newer AnyPS5. Update this one, then join');
      expect(ids(older), ['blocked-what', 'blocked-host', 'blocked-you', 'blocked-update', 'blocked-close']);
      expect(older[3].title, 'Check for updates');

      final channel = together.joinBlockedRows(
        block(EngineAdvice.hostNightly, '0.2.37-arm-nightly.20261112.1-0123456789ab', stable),
      );
      expect(
        advice(channel),
        'Mira plays on a nightly build newer than this release. Use the same update channel on both',
      );
      expect(ids(channel), isNot(contains('blocked-update')));

      // The advice comes from the two builds and the engine at hand.
      expect(
        together.engineBlock(hostName: 'Mira', titleId: 'PPSA01001', host: 'toolkit-2', yours: 'toolkit-1').advice,
        EngineAdvice.sameEngine,
      );
    });
  });
}
