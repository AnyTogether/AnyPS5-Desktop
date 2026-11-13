import 'dart:async';

import '../core/now_playing.dart';
import 'app_model.dart';
import 'strings.dart';

/// Now playing: what a music or video player on this computer plays, as a card in the quick
/// menu over a game (previous, play or pause, next), and, when the user chose so, shown to
/// their AnyTogether friends ("Listening to …"). Read from the system's media session, which
/// every player that tells the system what it plays is part of: no account and no service of
/// its own. The session is followed only while the quick menu is open with the card on or while
/// friends are shown it, by the system's events.
class NowPlayingModel {
  NowPlayingModel(this.app) : source = app.services.nowPlaying?.call() {
    _changes = source?.changes.listen((_) => _changed());
  }

  final AppModel app;

  /// Null in the tests (unless they give one) and on a system with nothing to read it from.
  final NowPlayingSource? source;

  /// The time, for the minute a paused track is still shown to friends; the tests set it.
  DateTime Function() now = DateTime.now;

  StreamSubscription<void>? _changes;
  Timer? _pauseEnds;
  NowPlayingTrack? _last;
  DateTime? _pausedSince;
  bool _watching = false;
  bool _closed = false;

  /// Whether the session is followed now.
  bool get watching => _watching;

  /// Settings › Behaviour › Now playing in the quick menu.
  bool get cardOn => app.preferences.nowPlayingCard;

  /// Whether friends may be shown it at all: signed in to AnyTogether and not a profile under
  /// family limits (a child's), where the switch is not listed.
  bool get mayShare => app.together.signedIn && !app.together.family.restricted;

  /// Settings › Behaviour › Show friends what I'm listening to, where it may be.
  bool get sharing => app.preferences.nowPlayingShare && mayShare;

  bool get _wanted => source != null && !_closed && ((cardOn && app.overlay == Layer.quickMenu) || sharing);

  /// The track while the session is followed.
  NowPlayingTrack? get track => _watching ? source?.current : null;

  /// What friends are shown now.
  Listening? get shared => sharing ? Listening.shared(track, pausedSince: _pausedSince, now: now()) : null;

  /// The quick menu opened or closed, a setting or the account changed: the session is followed
  /// or let go, and friends are told what holds now.
  void update() {
    final source = this.source;
    if (source == null) return;
    final wanted = _wanted;
    if (wanted != _watching) {
      _watching = wanted;
      if (!wanted) {
        _last = null;
        _pausedSince = null;
      }
      unawaited(
        source.watch(wanted).then((_) {
          if (!_closed) _changed();
        }),
      );
    }
    _share();
  }

  /// The system said the track changed.
  void _changed() {
    final track = this.track;
    final before = _last;
    if (track == null || track.playing) {
      _pausedSince = null;
    } else if (before != null && before.sameSong(track)) {
      // Paused just now: friends still see it for a minute. A track found already paused is
      // not shown, since when it stopped is not known.
      if (before.playing) _pausedSince = now();
    } else {
      _pausedSince = null;
    }
    _last = track;
    _share();
    app.refresh();
  }

  void _share() {
    final next = shared;
    _pauseEnds?.cancel();
    _pauseEnds = null;
    final since = _pausedSince;
    if (next != null && since != null) {
      // The minute after a pause runs out with nothing else happening: told then.
      final left = Listening.pausedFor - now().difference(since) + const Duration(seconds: 1);
      _pauseEnds = Timer(left.isNegative ? Duration.zero : left, _share);
    }
    app.together.hub.socket.listening = next;
  }

  void previous() => unawaited(source?.previous());
  void playPause() => unawaited(source?.playPause());
  void next() => unawaited(source?.next());

  /// "Now playing in Rhythmbox", "Paused in Rhythmbox"; "Now playing" for a player with no name.
  static String label(NowPlayingTrack track) {
    final player = track.player;
    if (player == null || player.isEmpty) return T.text('nowPlaying');
    return T.format(track.playing ? 'nowPlayingIn' : 'nowPlayingPausedIn', [player]);
  }

  /// The quick menu's card, before Close game: nothing while no player has a session or the
  /// card is off.
  List<PanelRow> quickRows() {
    final track = cardOn ? this.track : null;
    if (track == null) return const [];
    return [
      PanelRow(
        id: 'nowPlaying',
        title: track.title,
        detail: track.artist,
        picture: track.artwork,
        kind: MediaRow(
          label: label(track),
          playing: track.playing,
          previous: previous,
          playPause: playPause,
          next: next,
        ),
      ),
    ];
  }

  /// "Listening to Title, Artist", as a friend's row and profile say it.
  static String listeningText(Listening listening) => listening.artist == null
      ? T.format('friendsListening', [listening.title])
      : T.format('friendsListeningBy', [listening.title, listening.artist!]);

  /// The settings rows (Settings › Behaviour, after Discord's, as on the Mac): the card, on by
  /// default, and showing friends, off by default and listed only where it may be.
  List<PanelRow> settingsRows() => [
    PanelRow(
      id: 'nowPlayingCard',
      title: T.text('nowPlayingCard'),
      detail: T.text('nowPlayingCardDetail'),
      kind: ToggleRow(app.preferences.nowPlayingCard, (value) {
        app.preferences.nowPlayingCard = value;
        app.savePreferences();
        update();
      }),
    ),
    if (mayShare)
      PanelRow(
        id: 'nowPlayingShare',
        title: T.text('nowPlayingShare'),
        detail: T.text('nowPlayingShareDetail'),
        kind: ToggleRow(app.preferences.nowPlayingShare, (value) {
          app.preferences.nowPlayingShare = value;
          app.savePreferences();
          update();
        }),
      ),
  ];

  /// The launcher quits: friends are shown nothing of it any more.
  Future<void> close() async {
    _closed = true;
    _watching = false;
    _pauseEnds?.cancel();
    await _changes?.cancel();
    await source?.close();
  }
}
