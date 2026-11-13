import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/capture/game_sound.dart';
import 'package:anyps5_desktop/core/controllers/pad_info.dart';
import 'package:anyps5_desktop/core/desktop/desktop.dart';
import 'package:anyps5_desktop/core/gamepad/pad_navigation.dart';
import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/installer.dart';
import 'package:anyps5_desktop/ui/app_model.dart' hide GameState;
import 'package:anyps5_desktop/ui/share_speaker.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../core/share_play_test.dart' show FakeEngine;
import '../core/share_viewer_test.dart' show FakeWatchEngine;
import '../support/fake_sfu.dart';
import '../support/fake_together.dart';
import '../support/ui_support.dart';
import 'desktop_features_test.dart' show FakeDesktop;

/// A desktop that knows the game's window and its title.
class TitledDesktop extends FakeDesktop implements GameAreas {
  @override
  ScreenArea? gameArea(int pid) => const ScreenArea(0, 0, 1280, 720);
  @override
  String? gameTitle(int pid) => 'Orbit Runner';
}

class FakeSpeaker implements ShareSoundOut {
  final packets = <Uint8List>[];
  bool stopped = false;
  @override
  void push(Uint8List packet) => packets.add(packet);
  @override
  void stop() => stopped = true;
}

/// Hosting share play from the quick menu: start, a friend comes in, Let Them Play, stop. And
/// watching a friend's: from their invite in the Friends panel, full screen, the controller once
/// they hand it over, PS to leave.
void main() {
  late FakeTogether server;
  late Fixture fixture;
  late AppModel model;
  late FakeEngine engine;
  late List<FakeSfuRoom> rooms;
  late TitledDesktop desktop;

  Future<void> until(bool Function() condition) async {
    for (var tries = 0; tries < 500 && !condition(); tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(condition(), isTrue);
  }

  Map<String, Object?> sharePlay(List<Map<String, Object?>> viewers) => {
    'id': 'sp-1',
    'hostDevice': 'me-device',
    'titleId': 'PPSA01001',
    'title': 'Orbit Runner',
    'open': true,
    'maxViewers': 2,
    'viewers': viewers,
  };

  final ana = {
    'user': {'userId': 'u-ana', 'handle': 'ana', 'displayName': 'Ana'},
    'device': 'ana-browser',
  };

  setUp(() async {
    server = await FakeTogether.start();
    server.friend('u-ana', 'ana', 'Ana', presence: {'state': 'online'});
    rooms = [];
    desktop = TitledDesktop();
    fixture = makeFixture(
      together: server.base,
      desktop: desktop,
      renderNoticeCard: (title, detail, symbol, scale) async {
        desktop.noticeCards.add((title, detail));
        return RgbaImage(1, 1, Uint8List.fromList([1, 2, 3, 4]));
      },
      sfuRoom: () {
        final room = FakeSfuRoom();
        rooms.add(room);
        return room;
      },
    );
    model = fixture.model;
    engine = FakeEngine();
    model.sharePlay.engineOverride = () => engine;
    model.sharePlay.soundOverride = (_) => SilentGameSound();
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

  Game orbit() => model.games.firstWhere((game) => game.titleId == 'PPSA01001');

  Future<({Future<void> done})> play() async {
    final installed = Installer.installedFolder(orbit(), model.root!);
    File(p.join(installed, 'app.elf')).writeAsStringSync('#!/bin/sh\nsleep 5\n');
    Process.runSync('chmod', ['755', p.join(installed, 'app.elf')]);
    File(p.join(installed, Installer.recordName)).writeAsStringSync(
      '{"date":"2026-10-24T12:00:00Z","source":${jsonEncode(orbit().folder)},"system":"linux",'
      '"titleID":"PPSA01001","toolkit":"arm-5ca076a87"}',
    );
    model.rescan();
    // The copy as it is: these are about the engine it was made with, not about rebuilding it.
    final playing = model.play(orbit(), asItIs: true);
    await until(() => model.running != null);
    return (done: playing);
  }

  List<String> quickRows() {
    model.open(Layer.quickMenu);
    return model.panelCategories().single.rows.map((row) => row.id).toList();
  }

  PanelRow quickRow(String id) {
    model.open(Layer.quickMenu);
    return model.panelCategories().single.rows.firstWhere((row) => row.id == id);
  }

  void choose(String id) {
    final row = model.panelCategories().expand((category) => category.rows).firstWhere((row) => row.id == id);
    switch (row.kind) {
      case ActionRow(:final run):
        run();
      default:
        fail('$id is no action');
    }
  }

  test('share the game, a friend comes in, plays as player 2, then it stops', () async {
    final playing = (await play()).done;
    expect(quickRows(), contains('share-start'));
    server.answers['POST share-plays'] = (201, {'sharePlay': sharePlay([]), 'iceServers': <Object>[], 'expiresAt': null});
    choose('share-start');
    await until(() => model.sharePlay.active);
    expect(model.toast, T.format('sharePlayStarted', ['Orbit Runner']));
    expect(server.calls.where((call) => call.path == 'share-plays').single.body['titleId'], 'PPSA01001');
    expect(quickRows(), containsAllInOrder(['share-on', 'share-open', 'share-max', 'share-invite-u-ana', 'share-stop']));

    // Ana comes in: she is offered a connection through the gateway.
    server.push('share_play.updated', sharePlay([ana]));
    await until(() => engine.links.isNotEmpty);
    await until(() => server.frames.any((frame) => frame['op'] == 'signal' && frame['kind'] == 'offer'));
    final offer = server.frames.firstWhere((frame) => frame['op'] == 'signal');
    expect(offer['to'], 'u-ana');
    expect(offer['device'], 'ana-browser');
    expect(offer['share'], 'sp-1');
    expect(quickRows(), containsAllInOrder(['share-on', 'share-play-u-ana', 'share-remove-u-ana']));

    server.answers['PUT share-plays/sp-1/viewers/u-ana/slot'] = (200, sharePlay([{...ana, 'slot': 2}]));
    choose('share-play-u-ana');
    await until(() => quickRows().contains('share-stop-u-ana'));
    expect(model.toast, T.format('sharePlayNowPlays', ['Ana', 2]));

    // As on the Mac: a guest with a pad helps player 1 instead of playing their own.
    PanelRow assist() => quickRow('share-assist-u-ana');
    expect(assist().title, 'Assist Player 1');
    expect(assist().detail, 'Ana helps you play player 1 instead of playing their own.');
    expect((assist().kind as ToggleRow).value, isFalse);
    (assist().kind as ToggleRow).set(true);
    expect((assist().kind as ToggleRow).value, isTrue);

    // Stop and Remove ask first, in place, Cancel focused, as on the Mac: Back answers Cancel.
    model.open(Layer.quickMenu);
    List<String> rowsNow() => model.panelCategories().single.rows.map((row) => row.id).toList();
    String focusedRow() => rowsNow()[model.panelRow];
    choose('share-remove-u-ana');
    expect(rowsNow(), containsAllInOrder(['share-remove-u-ana-ask', 'share-remove-u-ana-yes', 'share-remove-u-ana-cancel']));
    expect(focusedRow(), 'share-remove-u-ana-cancel');
    model.command(Command.back);
    expect(model.overlay, Layer.quickMenu, reason: 'Back cancels the question, not the menu');
    expect(rowsNow(), contains('share-remove-u-ana'));
    expect(focusedRow(), 'share-remove-u-ana');

    choose('share-stop');
    expect(rowsNow(), containsAllInOrder(['share-stop-ask', 'share-stop-yes', 'share-stop-cancel']));
    expect(model.sharePlay.active, isTrue, reason: 'nothing stops at the question');
    expect(focusedRow(), 'share-stop-cancel');
    choose('share-stop-cancel');
    expect(rowsNow(), contains('share-stop'));

    server.answers['DELETE share-plays/sp-1'] = (204, null);
    choose('share-stop');
    choose('share-stop-yes');
    await until(() => engine.stopped);
    expect(model.sharePlay.active, isFalse);
    expect(engine.links.single.closed, isTrue);
    expect(server.frames.where((frame) => frame['op'] == 'signal').last['kind'], 'bye');
    expect(quickRows(), contains('share-start'));
    model.stopGame();
    await playing;
  }, skip: Platform.isWindows ? 'the stand-in game is a shell script' : false);

  test('someone asking to watch, with the game in front, is the card over it as on the Mac', () async {
    final playing = (await play()).done;
    expect(quickRows(), contains('share-start'));
    server.answers['POST share-plays'] = (201, {'sharePlay': sharePlay([]), 'iceServers': <Object>[], 'expiresAt': null});
    choose('share-start');
    await until(() => model.sharePlay.active);
    desktop.focused = false;
    server.push('share_play.request', {
      'sharePlayId': 'sp-1',
      'from': {'userId': 'u-gu', 'handle': 'gu', 'displayName': 'Gu'},
      'via': 'list',
    });
    await until(() => desktop.noticeCards.contains((T.format('discoverAsksWatch', ['Gu']), T.text('friendsTitle'))));
    expect(model.toast, T.format('discoverAsksWatch', ['Gu']));
    expect(desktop.calls.where((call) => call.startsWith('notify')), isEmpty, reason: 'the card, no desktop notice as well');
    desktop.focused = null;
    server.answers['DELETE share-plays/sp-1'] = (204, null);
    expect(quickRows(), contains('share-stop'));
    choose('share-stop');
    choose('share-stop-yes');
    await until(() => engine.stopped);
    model.stopGame();
    await playing;
  }, skip: Platform.isWindows ? 'the stand-in game is a shell script' : false);

  test('with the media server: more than four may watch, the picture goes there once, listing, asks and the code', () async {
    server.answers['GET media-server'] = (200, {'sfu': true, 'maxShareViewers': 16, 'maxPartySize': 32});
    // Asked again, as signing in asks it (before this server had a media server).
    await model.sharePlay.loadMediaLimits();
    expect(model.sharePlay.mediaLimits?.maxShareViewers, 16);
    final playing = (await play()).done;
    model.sharePlay.maxViewers = 8;
    server.answers['POST share-plays'] = (201, {'sharePlay': {...sharePlay([]), 'maxViewers': 8}, 'iceServers': <Object>[], 'expiresAt': null});
    expect(quickRows(), contains('share-start'));
    choose('share-start');
    await until(() => model.sharePlay.active);
    expect(server.calls.where((call) => call.path == 'share-plays').single.body['maxViewers'], 8);
    PanelRow row(String id) => model.panelCategories().expand((category) => category.rows).firstWhere((row) => row.id == id);
    final max = row('share-max');
    expect((max.kind as StepperRow).max, 16, reason: 'the server\'s limit, as the Mac decides it');
    expect(max.detail, T.text('sharePlayMaxViewersServerDetail'));
    expect(quickRows(), containsAllInOrder(['share-on', 'share-code-make', 'share-open', 'share-max', 'share-public']));

    // Six come in and the share play goes through the media server: Ana with a pad keeps her
    // link here, the rest watch from there, and the picture is published once.
    final others = [
      for (final name in ['bo', 'cy', 'di', 'ed', 'fe'])
        {
          'user': {'userId': 'u-$name', 'handle': name, 'displayName': name.toUpperCase()},
          'device': '$name-browser',
        },
    ];
    server.answers['GET share-plays/sp-1/sfu'] = (
      200,
      {'url': 'wss://media.example.org', 'token': 'host-token', 'room': 'share-sp-1', 'identity': 'u-me'},
    );
    server.push('share_play.updated', {
      ...sharePlay([{...ana, 'slot': 2}, ...others]),
      'maxViewers': 8,
      'media': 'sfu',
    });
    await until(() => engine.publisher?.connected ?? false);
    expect(engine.publisher!.access!.token, 'host-token');
    expect(model.sharePlay.hostingViaServer, isTrue);
    expect(engine.links, hasLength(1), reason: 'only the pad holder on the mesh');
    expect(row('share-play-u-bo').detail, '${T.text('sharePlayOnlyWatches')} · ${T.text('mediaViaServer')}');
    server.push('share_play.updated', {
      ...sharePlay([{...ana, 'slot': 2}, ...others]),
      'maxViewers': 8,
      'media': 'sfu',
    });
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(server.callsTo('share-plays/sp-1/sfu'), hasLength(1), reason: 'published once');

    // Listed in public for anyone to watch, under Live now, in Turkish.
    final listed = {...sharePlay([{...ana, 'slot': 2}, ...others]), 'maxViewers': 8, 'media': 'sfu'};
    server.answers['PATCH share-plays/sp-1'] = (200, {...listed, 'public': {'join': 'open', 'language': null, 'live': true}});
    (row('share-public').kind as ChoiceRow).set(2);
    await until(() => quickRows().contains('share-live'));
    expect(server.callsTo('share-plays/sp-1', method: 'PATCH').last.body['public'], {'join': 'open', 'language': null, 'live': true});
    expect((row('share-live').kind as ToggleRow).value, isTrue);
    server.answers['PATCH share-plays/sp-1'] = (200, {...listed, 'public': {'join': 'open', 'language': 'tr', 'live': true}});
    (row('share-language').kind as ChoiceRow).set(2);
    await until(() => model.sharePlay.hosting?.listing?.language == 'tr');

    // Someone asks with the code: said, listed, let in.
    server.push('share_play.request', {
      'sharePlayId': 'sp-1',
      'from': {'userId': 'u-gu', 'handle': 'gu', 'displayName': 'Gu'},
      'via': 'code',
    });
    await until(() => quickRows().contains('share-request-accept-u-gu'));
    expect(model.toast, T.format('discoverAsksWatch', ['Gu']));
    expect(row('share-request-accept-u-gu').detail, '@gu · ${T.text('partyRequestWithCode')}');
    expect(quickRows(), contains('share-request-decline-u-gu'));
    server.answers['POST share-plays/sp-1/requests/u-gu/accept'] = (200, listed);
    choose('share-request-accept-u-gu');
    await until(() => server.callsTo('share-plays/sp-1/requests/u-gu/accept').isNotEmpty);
    await until(() => !quickRows().contains('share-request-accept-u-gu'));

    // A code: made, copied, stopped.
    server.answers['POST share-plays/sp-1/code'] = (
      201,
      {'code': 'K7QM3XPA', 'url': 'https://anytogether.net/join/K7QM3XPA', 'expiresAt': '2099-01-01T00:00:00Z'},
    );
    choose('share-code-make');
    await until(() => quickRows().contains('share-code-copy'));
    expect(row('share-code').title, 'K7QM-3XPA');
    expect(model.toast, T.format('joinCodeMade', ['K7QM-3XPA']));
    server.answers['DELETE share-plays/sp-1/code'] = (204, null);
    choose('share-code-stop');
    await until(() => quickRows().contains('share-code-make'));

    server.answers['DELETE share-plays/sp-1'] = (204, null);
    choose('share-stop');
    choose('share-stop-yes');
    await until(() => engine.stopped);
    expect(engine.publisher!.closed, isTrue);
    model.stopGame();
    await playing;
  }, skip: Platform.isWindows ? 'the stand-in game is a shell script' : false);

  test('without a media server the host keeps four at most', () async {
    final playing = (await play()).done;
    server.answers['POST share-plays'] = (201, {'sharePlay': sharePlay([]), 'iceServers': <Object>[], 'expiresAt': null});
    expect(quickRows(), contains('share-start'));
    choose('share-start');
    await until(() => model.sharePlay.active);
    final max = model.panelCategories().expand((category) => category.rows).firstWhere((row) => row.id == 'share-max');
    expect((max.kind as StepperRow).max, 4);
    expect(max.detail, T.text('sharePlayMaxViewersDetail'));
    server.answers['DELETE share-plays/sp-1'] = (204, null);
    choose('share-stop');
    choose('share-stop-yes');
    await until(() => engine.stopped);
    model.stopGame();
    await playing;
  }, skip: Platform.isWindows ? 'the stand-in game is a shell script' : false);

  group('watching', () {
    late FakeWatchEngine watcher;
    late FakeSpeaker speaker;
    var pad = const PadState();

    Map<String, Object?> anas(List<Map<String, Object?>> viewers) => {
      'id': 'sp-9',
      'host': {'userId': 'u-ana', 'handle': 'ana', 'displayName': 'Ana'},
      'hostDevice': 'ana-mac',
      'titleId': 'PPSA02002',
      'title': 'Neon Alley',
      'open': false,
      'maxViewers': 2,
      'viewers': viewers,
    };
    final me = {
      'user': {'userId': 'u-me', 'handle': 'utku', 'displayName': 'Utku'},
      'device': 'my-device',
    };

    setUp(() {
      watcher = FakeWatchEngine();
      speaker = FakeSpeaker();
      model.sharePlay.watchEngineOverride = () => watcher;
      model.sharePlay.speakerOverride = () => speaker;
      model.sharePlay.padOverride = () => pad;
    });

    List<String> friendRows() {
      model.open(Layer.friends);
      return model.panelCategories().expand((category) => category.rows).map((row) => row.id).toList();
    }

    Future<void> watchFromInvite() async {
      server.push('share_play.invite', {
        'sharePlayId': 'sp-9',
        'from': {'userId': 'u-ana', 'handle': 'ana', 'displayName': 'Ana'},
        'titleId': 'PPSA02002',
        'title': 'Neon Alley',
      });
      await until(() => model.sharePlay.invites.isNotEmpty);
      expect(model.toast, T.format('sharePlayInvitedYou', ['Ana', 'Neon Alley']));
      expect(friendRows(), containsAllInOrder(['share-watch-sp-9', 'share-decline-sp-9']));
      server.answers['POST share-plays/sp-9/join'] = (201, {'sharePlay': anas([me]), 'iceServers': <Object>[], 'expiresAt': null});
      choose('share-watch-sp-9');
      await until(() => model.overlay == Layer.shareWatch);
      await until(() => server.frames.any((frame) => frame['op'] == 'signal' && frame['kind'] == 'renegotiate'));
    }

    test('an invite in the Friends panel, the host\'s offer answered, the pad once handed over, PS leaves', () async {
      await watchFromInvite();
      final ask = server.frames.firstWhere((frame) => frame['op'] == 'signal');
      expect(ask['to'], 'u-ana');
      expect(ask['device'], 'ana-mac');
      expect(ask['share'], 'sp-9');
      expect(model.sharePlay.invites, isEmpty);

      server.push('share_play.signal', {
        'sharePlayId': 'sp-9',
        'from': 'u-ana',
        'device': 'ana-mac',
        'kind': 'offer',
        'data': {'type': 'offer', 'sdp': 'o1'},
      });
      await until(() => server.frames.any((frame) => frame['kind'] == 'answer'));
      final link = watcher.links.single;
      link.opened!('audio');
      expect(link.texts.single.$2, contains('audio-hello'));
      link.binary!('audio', Uint8List(976));
      expect(speaker.packets, hasLength(1));

      // While only watching, ○ leaves too; with the pad, only PS does.
      server.push('share_play.updated', anas([{...me, 'slot': 2}]));
      await until(() => model.sharePlay.watchSlot == 2);
      expect(model.toast, T.format('sharePlayYouPlay', [2]));
      pad = const PadState(pressed: {PadButton.south});
      await until(() => link.binaries.any((sent) => sent.$1 == 'pad'));
      model.handle(Command.back);
      expect(model.overlay, Layer.shareWatch);

      server.answers['POST share-plays/sp-9/leave'] = (204, null);
      model.handle(Command.home);
      await until(() => model.overlay != Layer.shareWatch);
      expect(model.sharePlay.isWatching, isFalse);
      expect(link.closed, isTrue);
      expect(speaker.stopped, isTrue);
      await until(() => server.callsTo('share-plays/sp-9/leave').isNotEmpty);
      expect(server.frames.where((frame) => frame['op'] == 'signal').last['kind'], 'bye');
    });

    test('the host stopping ends the watch with a word; a full share play says so', () async {
      await watchFromInvite();
      server.push('share_play.ended', {'sharePlayId': 'sp-9', 'reason': 'ended'});
      await until(() => !model.sharePlay.isWatching);
      expect(model.toast, T.format('sharePlayHostStopped', ['Ana']));
      expect(model.overlay, isNot(Layer.shareWatch));

      server.answers['POST share-plays/sp-9/join'] = (409, {'status': 409, 'code': 'full', 'title': 'Full'});
      await model.sharePlay.watch('sp-9');
      expect(model.toast, T.text('sharePlayFull'));
      expect(model.sharePlay.isWatching, isFalse);
    });

    test('through the media server: watched from there without a pad, from the host with one', () async {
      server.answers['POST share-plays/sp-9/join'] = (
        201,
        {
          'sharePlay': {...anas([me]), 'media': 'sfu', 'maxViewers': 12},
          'iceServers': <Object>[],
          'expiresAt': null,
          'sfu': {
            'url': 'wss://media.example.org',
            'token': 'viewer-token',
            'room': 'share-sp-9',
            'identity': 'u-me',
            'expiresAt': DateTime.now().add(const Duration(minutes: 10)).toUtc().toIso8601String(),
          },
        },
      );
      await model.sharePlay.watch('sp-9');
      await until(() => rooms.isNotEmpty && rooms.single.connected);
      expect(rooms.single.access!.token, 'viewer-token', reason: 'the join answer\'s room while fresh');
      expect(model.sharePlay.watchViaServer, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(server.frames.where((frame) => frame['op'] == 'signal'), isEmpty, reason: 'no direct connection asked for');
      expect(model.sharePlay.watchConnected, isFalse);
      rooms.single.tracks['u-ana'] = {'game', 'game-audio'};
      rooms.single.changed?.call();
      expect(model.sharePlay.watchConnected, isTrue, reason: 'the host\'s picture came from the media server');

      // Ana hands over pad 2: out of the room, onto her connection.
      server.push('share_play.updated', {
        ...anas([{...me, 'slot': 2}]),
        'media': 'sfu',
        'maxViewers': 12,
      });
      await until(() => rooms.single.left);
      await until(() => server.frames.any((frame) => frame['op'] == 'signal' && frame['kind'] == 'renegotiate'));
      expect(model.sharePlay.watchViaServer, isFalse);

      // And takes it back: a fresh room.
      server.answers['GET share-plays/sp-9/sfu'] = (
        200,
        {'url': 'wss://media.example.org', 'token': 'fresh-token', 'room': 'share-sp-9', 'identity': 'u-me'},
      );
      server.push('share_play.updated', {...anas([me]), 'media': 'sfu', 'maxViewers': 12});
      await until(() => rooms.length == 2 && rooms.last.connected);
      expect(rooms.last.access!.token, 'fresh-token');

      server.answers['POST share-plays/sp-9/leave'] = (204, null);
      model.handle(Command.home);
      await until(() => !model.sharePlay.isWatching);
      await until(() => rooms.last.left);
    });

    test('a friend sharing who lets friends in is in the Friends panel', () async {
      server.push('presence.updated', {
        'userId': 'u-ana',
        'state': 'in_game',
        'titleId': 'PPSA02002',
        'share': {'sharePlayId': 'sp-9', 'titleId': 'PPSA02002', 'title': 'Neon Alley', 'open': true, 'viewers': 1, 'maxViewers': 3},
      });
      await until(() => model.together.hub.friends.friends.any((friend) => friend.presence.share != null));
      expect(friendRows(), contains('share-friend-sp-9'));
    });
  });

  test('signed out, the quick menu offers no share play', () async {
    final playing = (await play()).done;
    await model.together.signOut();
    await until(() => !model.together.signedIn);
    expect(quickRows(), isNot(contains('share-start')));
    model.stopGame();
    await playing;
  }, skip: Platform.isWindows ? 'the stand-in game is a shell script' : false);
}
