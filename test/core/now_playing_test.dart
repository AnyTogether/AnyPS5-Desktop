import 'dart:io';

import 'package:anyps5_desktop/core/now_playing.dart';
import 'package:anyps5_desktop/core/now_playing_mpris.dart';
import 'package:dbus/dbus.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// An MPRIS player on the test's own bus: its Player properties, the PropertiesChanged it emits
/// and the calls it was sent.
class FakePlayer extends DBusObject {
  FakePlayer(this.identity) : super(DBusObjectPath('/org/mpris/MediaPlayer2'));

  static const player = 'org.mpris.MediaPlayer2.Player';

  final String identity;
  String status = 'Stopped';
  String? title;
  List<String> artists = [];
  String? artUrl;
  final List<String> calls = [];

  Map<String, DBusValue> get properties => {
    'PlaybackStatus': DBusString(status),
    'Metadata': DBusDict.stringVariant({
      'mpris:trackid': DBusObjectPath('/track/1'),
      if (title != null) 'xesam:title': DBusString(title!),
      'xesam:artist': DBusArray.string(artists),
      if (artUrl != null) 'mpris:artUrl': DBusString(artUrl!),
    }),
    'Volume': const DBusDouble(1),
  };

  Map<String, DBusValue> _all(String interface) =>
      interface == player ? properties : {'Identity': DBusString(identity)};

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async => DBusGetAllPropertiesResponse(_all(interface));

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    final value = _all(interface)[name];
    return value == null ? DBusMethodErrorResponse.unknownProperty() : DBusGetPropertyResponse(value);
  }

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.interface != player) return DBusMethodErrorResponse.unknownInterface();
    calls.add(methodCall.name);
    return DBusMethodSuccessResponse();
  }

  /// The player changes and says so, as players do.
  Future<void> change({String? status, String? title, List<String>? artists, String? artUrl}) async {
    this.status = status ?? this.status;
    this.title = title ?? this.title;
    this.artists = artists ?? this.artists;
    this.artUrl = artUrl ?? this.artUrl;
    await emitPropertiesChanged(player, changedProperties: properties);
  }

  /// Something Now playing does not follow (the volume).
  Future<void> turnDown() => emitPropertiesChanged(player, changedProperties: {'Volume': const DBusDouble(0.5)});
}

void main() {
  group('what friends are shown', () {
    test('title and artist are trimmed and cut to 120, never through a character', () {
      expect(Listening.clean('  Night Drive \n'), 'Night Drive');
      expect(Listening.clean(''), isNull);
      expect(Listening.clean('   '), isNull);
      expect(Listening.clean(null), isNull);
      expect(Listening.clean('a' * 120), 'a' * 120);
      expect(Listening.clean('a' * 121), 'a' * 120);
      expect(Listening.clean('${'a' * 119} b'), 'a' * 119, reason: 'no space left at the end of the cut');
      // 𝄞 is two UTF-16 units: the cut never leaves half of it.
      final clef = Listening.clean('${'a' * 119}𝄞')!;
      expect(clef, 'a' * 119);
      expect(Listening.clean('${'a' * 118}𝄞')!.length, 120);
      expect(Listening.clean('ş' * 200)!.length, 120);
    });

    test('a song is a title, with the artist when there is one', () {
      expect(Listening.of('Night Drive', 'The Lanterns')!.json, {'title': 'Night Drive', 'artist': 'The Lanterns'});
      expect(Listening.of(' Radio ', '  ')!.json, {'title': 'Radio'});
      expect(Listening.of('', 'The Lanterns'), isNull);
      expect(Listening.of('t' * 300, 'a' * 300)!.json, {'title': 't' * 120, 'artist': 'a' * 120});
      expect(
        Listening.fromJson({'title': 'Night Drive', 'artist': 'The Lanterns'}),
        const Listening('Night Drive', 'The Lanterns'),
      );
      expect(Listening.fromJson({'title': 7}), isNull);
      expect(Listening.fromJson({'artist': 'The Lanterns'}), isNull);
      expect(Listening.fromJson(null), isNull);
      expect(Listening.fromJson('Night Drive'), isNull);
    });

    test('nothing with no track, and a paused one for a minute from when it stopped', () {
      final now = DateTime(2026, 11, 11, 20);
      const song = NowPlayingTrack(title: 'Night Drive', artist: 'The Lanterns', player: 'Rhythmbox');
      final paused = song.copyWith(playing: false);
      expect(Listening.shared(null, now: now), isNull);
      expect(Listening.shared(song, now: now), const Listening('Night Drive', 'The Lanterns'));
      expect(Listening.shared(paused, pausedSince: now.subtract(const Duration(seconds: 60)), now: now), isNotNull);
      expect(Listening.shared(paused, pausedSince: now.subtract(const Duration(seconds: 61)), now: now), isNull);
      expect(Listening.shared(paused, now: now), isNull, reason: 'paused since nobody knows when');
    });
  });

  group('MPRIS', () {
    MprisPlayer player(String name, String status, {String? title = 'Song', int active = 0}) =>
        MprisPlayer(name: '${MprisNowPlaying.prefix}$name', status: status, title: title, active: active);

    test('the player shown: one that plays, else the most recently active', () {
      expect(MprisPlayer.choose(const []), isNull);
      expect(MprisPlayer.choose([player('a', 'Stopped')]), isNull);
      expect(MprisPlayer.choose([player('a', 'Playing', title: null)]), isNull, reason: 'nothing to show');
      expect(
        MprisPlayer.choose([player('a', 'Paused', active: 9), player('b', 'Playing', active: 1)])!.name,
        endsWith('b'),
      );
      expect(
        MprisPlayer.choose([player('a', 'Playing', active: 1), player('b', 'Paused', active: 9)])!.name,
        endsWith('a'),
      );
      expect(
        MprisPlayer.choose([player('a', 'Paused', active: 3), player('b', 'Paused', active: 7)])!.name,
        endsWith('b'),
      );
      expect(
        MprisPlayer.choose([player('a', 'Playing', active: 8), player('b', 'Playing', active: 2)])!.name,
        endsWith('a'),
      );
      expect(
        MprisPlayer.choose([player('a', 'Stopped', active: 99), player('b', 'Paused', active: 1)])!.name,
        endsWith('b'),
      );
    });

    test('a player\'s properties: status, title, the artists joined, the cover\'s address', () {
      const start = MprisPlayer(name: 'org.mpris.MediaPlayer2.vlc.instance4123');
      expect(start.shownName, 'vlc');
      final playing = start.applying({
        'PlaybackStatus': const DBusString('Playing'),
        'Metadata': DBusDict.stringVariant({
          'xesam:title': const DBusString(' Night Drive '),
          'xesam:artist': DBusArray.string(['The Lanterns', 'Ana']),
          'mpris:artUrl': const DBusString('file:///tmp/cover.png'),
          'mpris:length': const DBusInt64(1000),
        }),
      }, 5);
      expect(playing.playing, isTrue);
      expect(playing.title, 'Night Drive');
      expect(playing.artist, 'The Lanterns, Ana');
      expect(playing.artUrl, 'file:///tmp/cover.png');
      expect(playing.active, 5);
      // The volume alone is no activity; a pause is.
      expect(playing.applying({'Volume': const DBusDouble(0.4)}, 6).active, 5);
      final paused = playing.applying({'PlaybackStatus': const DBusString('Paused')}, 7);
      expect(paused.status, 'Paused');
      expect(paused.title, 'Night Drive', reason: 'what a signal leaves out stays');
      expect(paused.active, 7);
      // A player that says an artist as one text, and one with empty metadata.
      final single = start.applying({
        'Metadata': DBusDict.stringVariant({
          'xesam:title': const DBusString('Radio'),
          'xesam:artist': const DBusString('Ana'),
        }),
      }, 1);
      expect(single.artist, 'Ana');
      final empty = playing.applying({'Metadata': DBusDict.stringVariant(const {})}, 8);
      expect(empty.title, isNull);
      expect(empty.artist, isNull);
      expect(start.named('VLC media player').shownName, 'VLC media player');
    });

    group('on a bus', () {
      late DBusServer bus;
      late DBusAddress address;
      late Directory temp;
      final clients = <DBusClient>[];
      late MprisNowPlaying source;
      var changes = 0;

      Future<void> until(bool Function() condition) async {
        for (var tries = 0; tries < 300 && !condition(); tries++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(condition(), isTrue);
      }

      Future<(FakePlayer, DBusClient)> start(String name, FakePlayer player) async {
        final client = DBusClient(address);
        clients.add(client);
        await client.registerObject(player);
        await client.requestName('${MprisNowPlaying.prefix}$name');
        return (player, client);
      }

      setUp(() async {
        temp = Directory.systemTemp.createTempSync('mpris');
        bus = DBusServer();
        address = await bus.listenAddress(DBusAddress.unix(dir: temp));
        changes = 0;
        source = MprisNowPlaying(client: () => DBusClient(address));
        source.changes.listen((_) => changes++);
      });

      tearDown(() async {
        await source.close();
        for (final client in clients) {
          await client.close();
        }
        clients.clear();
        await bus.close();
        temp.deleteSync(recursive: true);
      });

      test('nothing is read before it is watched, and no players is no track', () async {
        await start(
          'vlc',
          FakePlayer('VLC media player')
            ..status = 'Playing'
            ..title = 'Old Song',
        );
        expect(source.current, isNull);
        expect(source.players, isEmpty);
        await source.watch(true);
        expect(source.current?.title, 'Old Song');
        await source.watch(false);
        expect(source.current, isNull);
        expect(source.players, isEmpty);
      });

      test('players come, change, are chosen and go, by their signals; the commands go to the one shown', () async {
        final (vlc, vlcClient) = await start(
          'vlc',
          FakePlayer('VLC media player')
            ..status = 'Paused'
            ..title = 'Old Song',
        );
        await source.watch(true);
        expect(source.current?.title, 'Old Song');
        expect(source.current?.playing, isFalse);
        expect(source.current?.player, 'VLC media player');
        expect(source.current?.artist, isNull);

        // A second player starts while watched, playing: it is the one shown.
        final (rhythmbox, _) = await start(
          'rhythmbox',
          FakePlayer('Rhythmbox')
            ..status = 'Playing'
            ..title = 'Night Drive'
            ..artists = ['The Lanterns', 'Ana'],
        );
        await until(() => source.current?.title == 'Night Drive' && source.current?.player == 'Rhythmbox');
        expect(source.current?.artist, 'The Lanterns, Ana');
        expect(source.current?.playing, isTrue);

        // It pauses: both are paused, and it was active last.
        await rhythmbox.change(status: 'Paused');
        await until(() => source.current?.playing == false);
        expect(source.current?.title, 'Night Drive');
        // The volume is not a change of the track.
        final before = changes;
        await rhythmbox.turnDown();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(changes, before);

        // The first one plays again: shown, and the commands go to it.
        await vlc.change(status: 'Playing', title: 'New Song', artists: ['Ana']);
        await until(() => source.current?.title == 'New Song');
        expect(source.current?.artist, 'Ana');
        await source.next();
        await source.playPause();
        await source.previous();
        expect(vlc.calls, ['Next', 'PlayPause', 'Previous']);
        expect(rhythmbox.calls, isEmpty);

        // It closes: the other one, still paused, is shown again.
        await vlcClient.close();
        clients.remove(vlcClient);
        await until(() => source.current?.title == 'Night Drive');
        await source.playPause();
        expect(rhythmbox.calls, ['PlayPause']);
      });

      test('a cover named by a file\'s address is read once and comes with the track', () async {
        final cover = File(p.join(temp.path, 'cover.png'))..writeAsBytesSync([1, 2, 3, 4]);
        await start(
          'vlc',
          FakePlayer('VLC media player')
            ..status = 'Playing'
            ..title = 'Night Drive'
            ..artUrl = cover.uri.toString(),
        );
        await source.watch(true);
        await until(() => source.current?.artwork != null);
        expect(source.current!.artwork, [1, 2, 3, 4]);
        expect(source.current!.title, 'Night Drive');
      });

      test('no session bus: no track, no error, and asked again the next time', () async {
        final none = MprisNowPlaying(client: () => DBusClient(DBusAddress.unix(path: p.join(temp.path, 'nothing'))));
        await none.watch(true);
        expect(none.current, isNull);
        await none.next();
        await none.watch(false);
        await none.close();
        var asked = 0;
        final broken = MprisNowPlaying(
          client: () {
            asked++;
            throw StateError('no bus');
          },
        );
        await broken.watch(true);
        await broken.watch(true);
        expect(asked, 2);
        expect(broken.current, isNull);
        await broken.close();
      });
    });
  });
}
