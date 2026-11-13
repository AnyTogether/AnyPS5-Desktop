import 'dart:async';

import 'package:dbus/dbus.dart';

import 'now_playing.dart';

/// One MPRIS player on the session bus, as far as Now playing needs it.
class MprisPlayer {
  const MprisPlayer({
    required this.name,
    this.identity,
    this.status = 'Stopped',
    this.title,
    this.artist,
    this.artUrl,
    this.active = 0,
  });

  /// Its bus name (org.mpris.MediaPlayer2.vlc).
  final String name;

  /// What it calls itself ("VLC media player").
  final String? identity;

  /// PlaybackStatus: Playing, Paused or Stopped.
  final String status;
  final String? title;
  final String? artist;

  /// Where its cover is (mpris:artUrl): a file or a web address.
  final String? artUrl;

  /// When it last started, paused or changed its song: a count that only grows, the highest the
  /// most recent.
  final int active;

  bool get playing => status == 'Playing';

  /// The name shown: its own, else the end of its bus name without an instance's number.
  String? get shownName {
    final own = identity?.trim() ?? '';
    if (own.isNotEmpty) return own;
    final short = name.startsWith(MprisNowPlaying.prefix) ? name.substring(MprisNowPlaying.prefix.length) : name;
    final first = short.split('.').first;
    return first.isEmpty ? null : first;
  }

  /// The player Now playing shows: one that plays before one that is paused, and among those
  /// the most recently active. Stopped players and players with no title are passed over.
  static MprisPlayer? choose(Iterable<MprisPlayer> players) {
    MprisPlayer? best;
    for (final player in players) {
      if (player.title == null || (player.status != 'Playing' && player.status != 'Paused')) continue;
      if (best == null ||
          (player.playing && !best.playing) ||
          (player.playing == best.playing && player.active > best.active)) {
        best = player;
      }
    }
    return best;
  }

  /// This player with what a PropertiesChanged signal or a GetAll of its Player interface says
  /// ([properties]); [clock] becomes [active] when its state or song changed.
  MprisPlayer applying(Map<String, DBusValue> properties, int clock) {
    var status = this.status;
    var title = this.title;
    var artist = this.artist;
    var artUrl = this.artUrl;
    if (properties['PlaybackStatus'] case final DBusString value) status = value.value;
    if (properties['Metadata'] case final DBusDict value) {
      final metadata = <String, DBusValue>{};
      for (final entry in value.children.entries) {
        if (entry.key case final DBusString key) {
          final item = entry.value;
          metadata[key.value] = item is DBusVariant ? item.value : item;
        }
      }
      title = Listening.clean(_text(metadata['xesam:title']));
      artist = _text(metadata['xesam:artist']);
      artUrl = _text(metadata['mpris:artUrl']);
    }
    final changed = status != this.status || title != this.title || artist != this.artist;
    return MprisPlayer(
      name: name,
      identity: identity,
      status: status,
      title: title,
      artist: artist,
      artUrl: artUrl,
      active: changed ? clock : active,
    );
  }

  MprisPlayer named(String? identity) => MprisPlayer(
    name: name,
    identity: identity,
    status: status,
    title: title,
    artist: artist,
    artUrl: artUrl,
    active: active,
  );

  /// A text, or a list of texts joined with commas (xesam:artist is a list).
  static String? _text(DBusValue? value) {
    final text = switch (value) {
      DBusString(:final value) => value,
      DBusArray(:final children) => children.whereType<DBusString>().map((item) => item.value).join(', '),
      _ => '',
    }.trim();
    return text.isEmpty ? null : text;
  }
}

/// Now playing on Linux: the MPRIS players on the session bus (org.mpris.MediaPlayer2.*), which
/// nearly every music and video player and the browsers are. Followed by their signals
/// (PropertiesChanged, and NameOwnerChanged as players come and go): nothing is polled.
class MprisNowPlaying implements NowPlayingSource {
  MprisNowPlaying({DBusClient Function()? client, NowPlayingArt? art})
    : _newClient = client ?? DBusClient.session,
      _art = art ?? NowPlayingArt();

  static const prefix = 'org.mpris.MediaPlayer2.';
  static const _root = 'org.mpris.MediaPlayer2';
  static const _playerInterface = 'org.mpris.MediaPlayer2.Player';
  static final _path = DBusObjectPath('/org/mpris/MediaPlayer2');

  final DBusClient Function() _newClient;
  final NowPlayingArt _art;
  final _changes = StreamController<void>.broadcast();
  final Map<String, MprisPlayer> _players = {};
  final Map<String, StreamSubscription<void>> _signals = {};
  DBusClient? _client;
  StreamSubscription<void>? _names;
  NowPlayingTrack? _current;
  String? _reading;
  int _clock = 0;
  bool _watching = false;

  /// The players followed now, for the tests.
  List<MprisPlayer> get players => List.unmodifiable(_players.values);

  @override
  NowPlayingTrack? get current => _current;

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<void> watch(bool on) async {
    if (on == _watching) return;
    _watching = on;
    if (!on) {
      await _stop();
      _publish();
      return;
    }
    DBusClient? made;
    try {
      final client = made = _client = _newClient();
      // Asked first: with no session bus this fails here, where it is caught, before anything
      // listens to it.
      final names = await client.listNames();
      if (client != _client) return;
      _names = client.nameOwnerChanged.listen((event) {
        if (!event.name.startsWith(prefix)) return;
        if (event.newOwner == null) {
          _forget(event.name);
          _publish();
        } else {
          unawaited(_follow(client, event.name));
        }
      }, onError: (Object _) {});
      for (final name in names) {
        if (name.startsWith(prefix)) await _follow(client, name);
      }
    } on Object {
      // No session bus (or it went away): no player, as on a system without one. Asked again
      // the next time the quick menu opens.
      if (made == null || made == _client) {
        _watching = false;
        await _stop();
      }
    }
    _publish();
  }

  Future<void> _follow(DBusClient client, String name) async {
    if (client != _client) return;
    _forget(name);
    final object = DBusRemoteObject(client, name: name, path: _path);
    _players[name] = MprisPlayer(name: name);
    _signals[name] = object.propertiesChanged.listen((signal) {
      final player = _players[name];
      if (player == null || signal.propertiesInterface != _playerInterface) return;
      _players[name] = player.applying(signal.changedProperties, ++_clock);
      _publish();
    }, onError: (Object _) {});
    try {
      final properties = await object.getAllProperties(_playerInterface);
      if (client != _client || !_players.containsKey(name)) return;
      _players[name] = _players[name]!.applying(properties, ++_clock);
      _publish();
      final identity = await object.getProperty(_root, 'Identity');
      if (client != _client || !_players.containsKey(name)) return;
      if (identity case DBusString(:final value)) _players[name] = _players[name]!.named(value);
    } on Object {
      // Not a player after all, one that left again, or one with no Identity.
    }
    _publish();
  }

  void _forget(String name) {
    _players.remove(name);
    unawaited(_signals.remove(name)?.cancel());
  }

  Future<void> _stop() async {
    final client = _client;
    _client = null;
    await _names?.cancel();
    _names = null;
    for (final signal in _signals.values) {
      await signal.cancel();
    }
    _signals.clear();
    _players.clear();
    try {
      await client?.close();
    } on Object {
      // Already gone.
    }
  }

  /// What the chosen player plays, told when it differs from what was said last. A cover named
  /// by address is read once and the track told again with it.
  void _publish() {
    final chosen = _watching ? MprisPlayer.choose(_players.values) : null;
    NowPlayingTrack? next;
    if (chosen != null) {
      final address = chosen.artUrl;
      next = NowPlayingTrack(
        title: chosen.title!,
        artist: chosen.artist,
        player: chosen.shownName,
        playing: chosen.playing,
        artwork: _art.kept(address),
      );
      if (!_art.has(address) && _reading != address) {
        _reading = address;
        unawaited(
          _art.read(address).whenComplete(() {
            if (_reading == address) _reading = null;
            if (!_changes.isClosed) _publish();
          }),
        );
      }
    }
    if (next == _current) return;
    _current = next;
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<void> _send(String method) async {
    final client = _client;
    final chosen = MprisPlayer.choose(_players.values);
    if (client == null || chosen == null) return;
    try {
      await DBusRemoteObject(
        client,
        name: chosen.name,
        path: _path,
      ).callMethod(_playerInterface, method, const [], replySignature: DBusSignature(''));
    } on Object {
      // A player that cannot (CanGoNext false) or has just left: nothing happens.
    }
  }

  @override
  Future<void> previous() => _send('Previous');

  @override
  Future<void> playPause() => _send('PlayPause');

  @override
  Future<void> next() => _send('Next');

  @override
  Future<void> close() async {
    _watching = false;
    await _stop();
    _current = null;
    await _changes.close();
  }
}
