import 'dart:typed_data';

import 'package:anyps5_desktop/core/gamepad/pad_navigation.dart';
import 'package:anyps5_desktop/core/now_playing.dart';
import 'package:anyps5_desktop/core/together/people.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/now_playing_channel.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_now_playing.dart';
import '../support/fake_process.dart';
import '../support/fake_together.dart';
import '../support/family_signer.dart';
import '../support/ui_support.dart';

/// Now playing: the quick menu's card over a game (what a media player on this computer plays,
/// with previous, play or pause and next), its two settings, and "Listening to …" for friends
/// in the gateway's heartbeat. The media session is a fake the tests drive.
void main() {
  late FakeTogether server;
  late Fixture fixture;
  late AppModel model;
  late FakeNowPlaying player;
  final signer = FamilySigner('server key');

  const song = NowPlayingTrack(title: 'Night Drive', artist: 'The Lanterns', player: 'Rhythmbox');

  Future<void> until(bool Function() condition) async {
    for (var tries = 0; tries < 300 && !condition(); tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(condition(), isTrue);
  }

  /// Lets a watch that was asked for start.
  Future<void> turn() => Future<void>.delayed(const Duration(milliseconds: 5));

  Future<void> signIn({String email = 'utku@example.com'}) async {
    model.together.email = email;
    await model.together.sendCode();
    model.together.code = '123456';
    await model.together.verify();
    await until(() => model.together.connected);
  }

  void inGame() {
    model.running = (model.games.firstWhere((game) => game.titleId == 'PPSA01001'), runningFor(FakeGameProcess()));
  }

  List<PanelRow> quick() => model.panelCategories().single.rows;

  List<PanelRow> general() {
    model.open(Layer.settings);
    model.selectCategory(model.panelCategories().indexWhere((category) => category.id == 'general'));
    return model.panelCategories()[model.panelCategory].rows;
  }

  ToggleRow toggle(String id) => general().firstWhere((row) => row.id == id).kind as ToggleRow;

  /// The next heartbeat with or without `listening`, as [listening] says.
  Future<Map<String, dynamic>> beat({required bool listening}) =>
      server.nextFrame('heartbeat', test: (frame) => (frame['presence'] as Map).containsKey('listening') == listening);

  /// The same for a heartbeat [act] causes: the ones before it are put aside first.
  Future<Map<String, dynamic>> beatAfter(void Function() act, {required bool listening}) {
    server.frames.clear();
    act();
    return beat(listening: listening);
  }

  setUp(() async {
    server = await FakeTogether.start();
    player = FakeNowPlaying();
    fixture = makeFixture(together: server.base, nowPlaying: () => player);
    model = fixture.model;
  });

  tearDown(() async {
    model.running = null;
    model.dispose();
    await server.close();
    T.language = Language.english;
    fixture.dispose();
  });

  group('the quick menu', () {
    test('nothing is read until the quick menu opens, and no card shows with no media session', () async {
      player.system = song;
      inGame();
      await turn();
      expect(player.watching, isFalse, reason: 'a game alone reads nothing');
      player.system = null;
      model.open(Layer.quickMenu);
      await turn();
      expect(player.watching, isTrue);
      expect(quick().map((row) => row.id), isNot(contains('nowPlaying')));
      expect(quick().first.id, 'resume');
      expect(quick().last.id, 'closeGame');
    });

    test('a player with a song: the card before Close game, with its title, artist, player and cover', () async {
      inGame();
      model.open(Layer.quickMenu);
      await turn();
      final cover = iconArt(0x7A3DFF, 0x1B0B5C);
      player.play(NowPlayingTrack(title: 'Night Drive', artist: 'The Lanterns', player: 'Rhythmbox', artwork: cover));
      final ids = quick().map((row) => row.id).toList();
      expect(ids, containsAllInOrder(['resume', 'gameSettings', 'nowPlaying', 'closeGame']));
      expect(ids.indexOf('nowPlaying'), ids.length - 2, reason: 'the last row before Close game');
      final row = quick().firstWhere((row) => row.id == 'nowPlaying');
      expect(row.title, 'Night Drive');
      expect(row.detail, 'The Lanterns');
      expect(row.picture, cover);
      final kind = row.kind as MediaRow;
      expect(kind.label, 'Now playing in Rhythmbox');
      expect(kind.playing, isTrue);

      // Paused: still there, said so. No artist and no player's name: the card says less.
      player.play(song.copyWith(playing: false));
      expect((quick().firstWhere((row) => row.id == 'nowPlaying').kind as MediaRow).label, 'Paused in Rhythmbox');
      player.play(const NowPlayingTrack(title: 'A stream'));
      final bare = quick().firstWhere((row) => row.id == 'nowPlaying');
      expect(bare.detail, isNull);
      expect(bare.picture, isNull);
      expect((bare.kind as MediaRow).label, 'Now playing');

      // The player closes: the card goes. The menu closes: nothing is read any more.
      player.stop();
      expect(quick().map((row) => row.id), isNot(contains('nowPlaying')));
      model.closeOverlay();
      await turn();
      expect(player.watching, isFalse);
    });

    test('in Turkish', () async {
      T.language = Language.byCode('tr');
      inGame();
      model.open(Layer.quickMenu);
      await turn();
      player.play(song);
      expect(
        (quick().firstWhere((row) => row.id == 'nowPlaying').kind as MediaRow).label,
        'Rhythmbox uygulamasında çalıyor',
      );
      player.play(song.copyWith(playing: false));
      expect(
        (quick().firstWhere((row) => row.id == 'nowPlaying').kind as MediaRow).label,
        'Rhythmbox uygulamasında duraklatıldı',
      );
    });

    test('the keys: ← previous, → next, Enter plays or pauses, and ↑ ↓ pass over it as any row', () async {
      inGame();
      model.open(Layer.quickMenu);
      await turn();
      player.play(song);
      final index = quick().indexWhere((row) => row.id == 'nowPlaying');
      model.panelRow = index - 1;
      model.handle(Command.down);
      expect(quick()[model.panelRow].id, 'nowPlaying');
      model.handle(Command.right);
      model.handle(Command.left);
      model.handle(Command.select);
      expect(player.commands, ['next', 'previous', 'playPause']);
      expect(model.overlay, Layer.quickMenu, reason: 'playing or pausing leaves the menu open');
      model.handle(Command.down);
      expect(quick()[model.panelRow].id, 'closeGame');
    });

    test('a controller: left and right at once, with no edit mode, and ✕ plays or pauses', () async {
      inGame();
      model.open(Layer.quickMenu);
      await turn();
      player.play(song);
      model.panelRow = quick().indexWhere((row) => row.id == 'nowPlaying') - 1;
      model.padCommand(PadCommand.down);
      expect(quick()[model.panelRow].id, 'nowPlaying');
      model.padCommand(PadCommand.right);
      model.padCommand(PadCommand.left);
      model.padCommand(PadCommand.select);
      expect(player.commands, ['next', 'previous', 'playPause']);
      expect(model.editingValue, isNull);
    });

    test('the mouse: the three buttons do the same and give the card the focus', () async {
      inGame();
      model.open(Layer.quickMenu);
      await turn();
      player.play(song);
      final index = quick().indexWhere((row) => row.id == 'nowPlaying');
      model.stepRow(index, -1);
      model.stepRow(index, 1);
      model.activateRow(index);
      expect(player.commands, ['previous', 'next', 'playPause']);
      expect(model.panelRow, index);
    });
  });

  group('the settings', () {
    test(
      'Now playing in the quick menu follows Discord\'s rows, on by default; off, no card and nothing read',
      () async {
        final ids = general().map((row) => row.id).toList();
        expect(ids.indexOf('nowPlayingCard'), ids.indexOf('discordJoin') + 1);
        final row = general().firstWhere((row) => row.id == 'nowPlayingCard');
        expect(row.title, 'Now playing in the quick menu');
        expect(row.detail, contains('any player'));
        expect((row.kind as ToggleRow).value, isTrue);
        expect(model.preferences.toJson()['nowPlayingCard'], isTrue);

        toggle('nowPlayingCard').set(false);
        expect(model.preferences.nowPlayingCard, isFalse);
        player.system = song;
        inGame();
        model.open(Layer.quickMenu);
        await turn();
        expect(player.watching, isFalse);
        expect(quick().map((row) => row.id), isNot(contains('nowPlaying')));
        // Kept across a restart.
        expect(Preferences.fromJson(model.preferences.toJson()).nowPlayingCard, isFalse);
      },
    );

    test('Show friends what I\'m listening to: not listed while signed out', () {
      expect(general().map((row) => row.id), isNot(contains('nowPlayingShare')));
      expect(model.nowPlaying.mayShare, isFalse);
    });

    test('signed in: listed after the card\'s row, off by default', () async {
      await signIn();
      final ids = general().map((row) => row.id).toList();
      expect(ids.indexOf('nowPlayingShare'), ids.indexOf('nowPlayingCard') + 1);
      final row = general().firstWhere((row) => row.id == 'nowPlayingShare');
      expect(row.title, 'Show friends what I\'m listening to');
      expect((row.kind as ToggleRow).value, isFalse);
      expect(model.preferences.toJson()['nowPlayingShare'], isFalse);
      expect(Preferences.fromJson(const {}).nowPlayingShare, isFalse);
      expect(player.watching, isFalse, reason: 'nothing is read for friends until it is on');
    });

    test('a profile under family limits: not listed, and nothing is sent even if it was on before', () async {
      server.me = {'id': 'u-kid', 'handle': 'kid', 'displayName': 'Kid'};
      server.answers['GET .well-known/jwks.json'] = (200, signer.jwks);
      server.answers['GET me/family/restrictions'] = (
        200,
        signer.response(FamilySigner.childStatus(issuedAt: DateTime.now())),
      );
      model.preferences.nowPlayingShare = true;
      player.system = song;
      await signIn(email: 'kid@example.com');
      await until(() => model.together.family.restricted);
      model.nowPlaying.update();
      await turn();
      expect(general().map((row) => row.id), isNot(contains('nowPlayingShare')));
      expect(general().map((row) => row.id), contains('nowPlayingCard'));
      expect(model.nowPlaying.sharing, isFalse);
      expect(model.nowPlaying.shared, isNull);
      expect(model.together.hub.socket.listening, isNull);
      expect(model.together.hub.socket.presenceFrame.containsKey('listening'), isFalse);
    });
  });

  group('friends', () {
    test('on: the heartbeat carries the title and artist; a pause of over a minute and off take it away', () async {
      await signIn();
      await beat(listening: false);
      player.system = song;
      toggle('nowPlayingShare').set(true);
      model.closeOverlay();
      await turn();
      expect(player.watching, isTrue, reason: 'followed for friends with no menu open');
      await until(() => model.together.hub.socket.listening != null);
      expect((await beat(listening: true))['presence'], {
        'state': 'online',
        'listening': {'title': 'Night Drive', 'artist': 'The Lanterns'},
      });

      // Paused: friends still see it for a minute, then no more.
      final paused = DateTime(2026, 11, 11, 20);
      model.nowPlaying.now = () => paused;
      player.play(song.copyWith(playing: false));
      expect(model.nowPlaying.shared, const Listening('Night Drive', 'The Lanterns'));
      model.nowPlaying.now = () => paused.add(const Duration(seconds: 59));
      model.nowPlaying.update();
      expect(model.together.hub.socket.listening, isNotNull);
      model.nowPlaying.now = () => paused.add(const Duration(seconds: 61));
      final gone = await beatAfter(model.nowPlaying.update, listening: false);
      expect(model.together.hub.socket.listening, isNull);
      expect(gone['presence'], {'state': 'online'});

      // Playing again, then a song with no artist: the field has no artist.
      model.nowPlaying.now = DateTime.now;
      await beatAfter(() => player.play(song), listening: true);
      final radio = await beatAfter(() => player.play(const NowPlayingTrack(title: '  Radio  ')), listening: true);
      expect((radio['presence'] as Map)['listening'], {'title': 'Radio'});

      // The player closes: nothing. Off: nothing, and the session is let go.
      await beatAfter(player.stop, listening: false);
      await beatAfter(() => player.play(song), listening: true);
      await beatAfter(() => toggle('nowPlayingShare').set(false), listening: false);
      model.closeOverlay();
      await turn();
      expect(player.watching, isFalse);
      expect(model.preferences.nowPlayingShare, isFalse);
    });

    test('a track found already paused is not shown, and signing out stops it', () async {
      await signIn();
      player.system = song.copyWith(playing: false);
      toggle('nowPlayingShare').set(true);
      model.closeOverlay();
      await turn();
      expect(model.nowPlaying.track, isNotNull);
      expect(model.together.hub.socket.listening, isNull);
      player.play(song);
      expect(model.together.hub.socket.listening, const Listening('Night Drive', 'The Lanterns'));
      await model.together.signOut();
      await until(() => !model.together.signedIn);
      model.nowPlaying.update();
      await turn();
      expect(model.nowPlaying.sharing, isFalse);
      expect(model.together.hub.socket.listening, isNull);
      expect(player.watching, isFalse);
    });

    test('a friend\'s row says what they listen to, after what they do', () async {
      server.friend(
        'u-ana',
        'ana',
        'Ana',
        presence: {
          'state': 'online',
          'listening': {'title': 'Night Drive', 'artist': 'The Lanterns'},
        },
      );
      await signIn();
      await until(() => model.together.hub.friends.loaded);
      model.open(Layer.friends);
      final row = model.panelCategories().single.rows.firstWhere((row) => row.id == 'friend-u-ana');
      expect(row.detail, '@ana · Online · Listening to Night Drive, The Lanterns');

      final together = model.together;
      expect(
        together.presenceText(
          Presence.fromJson({
            'state': 'in_game',
            'titleId': 'PPSA02002',
            'listening': {'title': 'Radio'},
          }),
        ),
        'Playing Neon Alley · Listening to Radio',
      );
      expect(
        together.presenceText(
          Presence.fromJson({
            'state': 'online',
            'listening': {'title': '  '},
          }),
        ),
        'Online',
      );
      expect(together.presenceText(Presence.fromJson({'state': 'online', 'listening': 'no'})), 'Online');
      expect(
        together.presenceText(
          Presence.fromJson({
            'state': 'offline',
            'listening': {'title': 'Radio'},
          }),
        ),
        'Offline',
      );
      T.language = Language.byCode('tr');
      expect(
        together.presenceText(
          Presence.fromJson({
            'state': 'online',
            'listening': {'title': 'Night Drive', 'artist': 'The Lanterns'},
          }),
        ),
        'Çevrimiçi · Night Drive, The Lanterns dinliyor',
      );
    });
  });

  group('Windows\' channel', () {
    test('the runner\'s track: empty texts are none, no title is no track', () {
      expect(ChannelNowPlaying.parse(null), isNull);
      expect(ChannelNowPlaying.parse({'title': '', 'artist': 'x', 'playing': true}), isNull);
      final cover = Uint8List.fromList([1, 2, 3]);
      final track = ChannelNowPlaying.parse({
        'title': 'Night Drive',
        'artist': '',
        'player': 'Media Player',
        'playing': false,
        'artwork': cover,
      })!;
      expect(track.title, 'Night Drive');
      expect(track.artist, isNull);
      expect(track.player, 'Media Player');
      expect(track.playing, isFalse);
      expect(track.artwork, cover);
      expect(ChannelNowPlaying.parse({'title': 'T', 'artwork': Uint8List(0)})!.artwork, isNull);
    });
  });
}
