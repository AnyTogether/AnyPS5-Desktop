import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// What a media player on this computer plays or has paused, as the system's media session
/// says it (Windows: the system media transport controls, Linux: MPRIS).
class NowPlayingTrack {
  const NowPlayingTrack({required this.title, this.artist, this.player, this.playing = true, this.artwork});

  final String title;
  final String? artist;

  /// The player's own name ("Rhythmbox"), when the system knows one.
  final String? player;

  /// False while paused.
  final bool playing;

  /// The cover as the player gives it (PNG or JPEG), when it gives one.
  final Uint8List? artwork;

  NowPlayingTrack copyWith({bool? playing, Uint8List? Function()? artwork}) => NowPlayingTrack(
    title: title,
    artist: artist,
    player: player,
    playing: playing ?? this.playing,
    artwork: artwork == null ? this.artwork : artwork(),
  );

  /// A cover as a channel hands it over: its bytes, or none when it is not that or is empty.
  static Uint8List? cover(Object? value) => value is Uint8List && value.isNotEmpty ? value : null;

  /// The same song from the same player, whatever its state and cover.
  bool sameSong(NowPlayingTrack? other) =>
      other != null && other.title == title && other.artist == artist && other.player == player;

  @override
  bool operator ==(Object other) =>
      other is NowPlayingTrack &&
      sameSong(other) &&
      other.playing == playing &&
      (other.artwork?.length ?? -1) == (artwork?.length ?? -1);

  @override
  int get hashCode => Object.hash(title, artist, player, playing, artwork?.length);
}

/// Where the track comes from; the tests give a fake.
abstract class NowPlayingSource {
  /// The track while [watch] is on: null when no player has a session.
  NowPlayingTrack? get current;

  /// Fires when [current] changed (the system's own events, never a busy poll).
  Stream<void> get changes;

  /// Follows the system's media session, or stops: nothing is read while off.
  Future<void> watch(bool on);

  Future<void> previous();
  Future<void> playPause();
  Future<void> next();
  Future<void> close();
}

/// What friends are shown of it (the gateway heartbeat's `presence.listening`): a title and,
/// when there is one, the artist, each trimmed and at most [most] UTF-16 units long.
class Listening {
  const Listening(this.title, [this.artist]);

  static const most = 120;

  /// How long a paused track is still shown to friends.
  static const pausedFor = Duration(minutes: 1);

  final String title;
  final String? artist;

  /// [text] trimmed and cut to [most] units, never through the middle of a character outside
  /// the basic plane; null when nothing is left.
  static String? clean(String? text) {
    var cut = (text ?? '').trim();
    if (cut.length > most) {
      cut = cut.substring(0, most);
      final last = cut.codeUnitAt(cut.length - 1);
      if (last >= 0xD800 && last <= 0xDBFF) cut = cut.substring(0, cut.length - 1);
      cut = cut.trimRight();
    }
    return cut.isEmpty ? null : cut;
  }

  static Listening? of(String? title, String? artist) {
    final name = clean(title);
    return name == null ? null : Listening(name, clean(artist));
  }

  /// What a friend's presence carries, as the server sends it; null when it says nothing usable.
  static Listening? fromJson(Object? json) => json is Map
      ? of(
          json['title'] is String ? json['title'] as String : null,
          json['artist'] is String ? json['artist'] as String : null,
        )
      : null;

  /// What goes to friends for [track]: nothing without one, and nothing once it has been
  /// paused for longer than [pausedFor] ([pausedSince] is when it stopped playing).
  static Listening? shared(NowPlayingTrack? track, {DateTime? pausedSince, required DateTime now}) {
    if (track == null) return null;
    if (!track.playing && (pausedSince == null || now.difference(pausedSince) > pausedFor)) return null;
    return of(track.title, track.artist);
  }

  Map<String, Object?> get json => {'title': title, 'artist': ?artist};

  @override
  bool operator ==(Object other) => other is Listening && other.title == title && other.artist == artist;

  @override
  int get hashCode => Object.hash(title, artist);
}

/// A cover a player names by address rather than hands over (MPRIS's `mpris:artUrl`): a file
/// on this computer or a picture on the web, read once and kept for the song.
class NowPlayingArt {
  NowPlayingArt({HttpClient Function()? client}) : _client = client ?? HttpClient.new;

  /// No cover is bigger than this; a larger one is left out.
  static const most = 4 * 1024 * 1024;

  final HttpClient Function() _client;
  String? _address;
  Uint8List? _bytes;

  /// Whether [address] needs no reading: there is none, or it is the one kept.
  bool has(String? address) => address == null || address.isEmpty || address == _address;

  /// The picture kept for [address], when it is the one last read.
  Uint8List? kept(String? address) => address != null && address == _address ? _bytes : null;

  /// The picture at [address], null when it cannot be read; the last one asked for is kept.
  Future<Uint8List?> read(String? address) async {
    if (address == null || address.isEmpty) return null;
    if (address == _address) return _bytes;
    final bytes = await _fetch(address);
    _address = address;
    _bytes = bytes;
    return bytes;
  }

  Future<Uint8List?> _fetch(String address) async {
    final uri = Uri.tryParse(address);
    if (uri == null) return null;
    try {
      if (uri.scheme == 'file') {
        final file = File(uri.toFilePath());
        if (await file.length() > most) return null;
        return await file.readAsBytes();
      }
      if (uri.scheme != 'https' && uri.scheme != 'http') return null;
      final client = _client()..connectionTimeout = const Duration(seconds: 5);
      try {
        final request = await client.getUrl(uri).timeout(const Duration(seconds: 5));
        final response = await request.close().timeout(const Duration(seconds: 5));
        if (response.statusCode != 200 || response.contentLength > most) {
          await response.drain<void>();
          return null;
        }
        final out = BytesBuilder(copy: false);
        await for (final chunk in response.timeout(const Duration(seconds: 10))) {
          out.add(chunk);
          if (out.length > most) return null;
        }
        return out.takeBytes();
      } finally {
        client.close(force: true);
      }
    } on Object {
      return null;
    }
  }
}
