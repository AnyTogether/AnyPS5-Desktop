import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show RTCVideoView, RTCVideoViewObjectFit;

import '../core/capture/game_sound.dart';
import '../core/capture/stream_packet.dart';
import '../core/capture/video_encoders.dart';
import '../core/capture/wayland_capture.dart';
import '../core/controllers/pad_info.dart';
import '../core/desktop/desktop.dart';
import '../core/remote/remote_server.dart';
import '../core/together/account.dart';
import '../core/together/discover.dart' show DiscoverLanguages, PublicJoin;
import '../core/together/media.dart';
import '../core/together/people.dart';
import '../core/together/share_host.dart';
import '../core/together/share_play.dart';
import '../core/together/share_viewer.dart';
import '../core/together/share_watch.dart';
import '../core/together/socket.dart';
import 'app_model.dart';
import 'livekit_room.dart';
import 'share_speaker.dart';
import 'share_webrtc.dart';
import 'strings.dart';
import 'together_model.dart';

/// Pads go nowhere: no phone server, so no bridges to the game.
class _NoBridges implements SharePadBridges {
  @override
  int? reservePadBridge() => null;
  @override
  void releasePadBridge(int bridge) {}
  @override
  void sendPad(Uint8List data, int bridge) {}
}

/// Share play, as the Mac launcher has it. Hosting: while a game runs, friends watch it live in a
/// browser, on their phone or in their launcher, and a viewer the user lets play joins in as
/// player 2, 3 or 4. Picture and sound go from this computer straight to each viewer (WebRTC);
/// AnyTogether introduces them. In the quick menu while a game plays. Watching: a friend's share
/// play full screen here, its sound, and the user's controller as their player once they let the
/// user play; from an invite, a friend sharing in the Friends panel, or Find Players' Live now.
class SharePlayModel {
  SharePlayModel(this.app);

  final AppModel app;

  /// Tests: a stand-in for flutter_webrtc, the game's sound, the speaker and the server.
  ShareEngine Function()? engineOverride;
  WatchEngine Function()? watchEngineOverride;
  GameSound Function(int pid)? soundOverride;
  ShareSoundOut Function()? speakerOverride;
  PadState? Function()? padOverride;
  SharePlayClient? clientOverride;

  SharePlayClient get _client => clientOverride ?? SharePlayClient(app.together.account);

  /// What the server holds (a media server or not, and how many it lets watch); the mesh's four
  /// until it answers.
  MediaLimits? mediaLimits;

  /// The hosted picture and sound out on the media server, while the share play goes through it.
  SfuPublisher? _publisher;
  bool _publisherTried = false;
  bool get hostingViaServer => _publisher?.connected ?? false;

  /// People who asked to watch with the code: their request row says so.
  final Set<String> codeAskers = {};

  /// Asks the server what it holds, once it is reachable.
  Future<void> loadMediaLimits() async {
    if (!app.together.signedIn) return;
    final limits = await MediaServerClient(app.together.account).limits();
    mediaLimits = limits;
    maxViewers = ShareMedia.clampViewers(maxViewers, limits);
    app.refresh();
  }

  ShareHostSession? _session;
  SharePlay? hosting;
  bool starting = false;
  Timer? _renewal;
  Timer? _measure;
  GameSound? _sound;

  /// Friends may walk in without an invite; how many may watch at once.
  bool openToFriends = true;
  int maxViewers = 2;

  bool get active => _session != null;

  /// Why share play cannot start here, or null when it can.
  String? get unavailable {
    if (!app.together.signedIn) return T.text('sharePlaySignInFirst');
    if (!(app.together.family.rules?.sharePlay ?? true)) return T.text('familyNoSharePlay');
    if (engineOverride == null && !ScreenGrab.supported(app.system, app.services.environment ?? Platform.environment)) {
      return T.text(
        WaylandCapture.applies(app.system, app.services.environment ?? Platform.environment)
            ? 'sharePlayNoWayland'
            : 'replayNoScreen',
      );
    }
    return null;
  }

  Future<void> start() async {
    final playing = app.running;
    if (playing == null || active || starting) return;
    final reason = unavailable;
    if (reason != null) return app.show(reason);
    final desktop = app.desktop;
    final title = desktop is GameAreas ? (desktop as GameAreas).gameTitle(playing.$2.pid) : null;
    starting = true;
    app.refresh();
    final engine = engineOverride?.call() ?? WebRtcShare();
    try {
      if (title == null || !await engine.start(windowTitle: title)) {
        await engine.stop();
        app.show(T.text('sharePlayNoWindow'));
        return;
      }
      final game = playing.$1;
      if (mediaLimits == null) await loadMediaLimits();
      final started = await _client.start(
        titleId: game.titleId,
        title: game.name,
        open: openToFriends,
        maxViewers: ShareMedia.clampViewers(maxViewers, mediaLimits),
      );
      if (app.running?.$2.pid != playing.$2.pid) {
        await engine.stop();
        unawaited(_client.end(started.sharePlay.id).catchError((Object _) {}));
        return;
      }
      final remote = app.remote;
      final SharePadBridges bridges = remote ?? _NoBridges();
      final session = ShareHostSession(
        id: started.sharePlay.id,
        engine: engine,
        iceServers: started.iceServers,
        router: SharePadRouter(bridges),
        signal: (to, device, kind, data) => app.together.hub.socket.send(
          ShareSignal.frame(to: to, device: device, share: started.sharePlay.id, kind: kind, data: data),
        ),
        changed: app.refresh,
      );
      _session = session;
      remote?.padOutput = session.padOutput;
      _renew(started.expiresAt);
      _measure = Timer.periodic(const Duration(seconds: 2), (_) => unawaited(session.measure()));
      await _apply(started.sharePlay, access: started.sfu);
      app.show(T.format('sharePlayStarted', [game.name]));
      await _startSound(session, playing.$2.pid);
      final opus = engine.hasSound ? 'Opus track on request' : 'no Opus track';
      app.addRecentLine('${DateTime.now().toIso8601String()} share play: $opus, PCM ${_sound?.reach.name ?? 'none'}');
    } on Object catch (error) {
      await engine.stop();
      // More viewers than this server takes without a media server: said on its own, as the Mac.
      final serverOff = error is TogetherProblem && error.code == 'media_server_off';
      final message = app.together.message(error);
      app.show(serverOff ? message : '${T.text('sharePlayCouldNotStart')}: $message');
    } finally {
      starting = false;
      app.refresh();
    }
  }

  /// The game's sound for viewers who take PCM (the phone app, older launchers, any viewer
  /// until their Opus track is taken): the launcher's own capture of the game, in 5 ms packets.
  Future<void> _startSound(ShareHostSession session, int pid) async {
    final sound = soundOverride?.call(pid) ?? app.media.soundOf(pid);
    final chunker = SoundChunker();
    final clock = Stopwatch()..start();
    _sound = sound;
    try {
      await sound.start((samples) {
        if (_session != session) return;
        for (final packet in chunker.add(samples, clock.elapsedMilliseconds)) {
          session.pushSound(packet);
        }
      });
    } on Object {
      // No way to hear the game here: viewers who ask still get the Opus track, if any.
    }
  }

  /// The share play as the server has it now. Once it goes through the media server ("sfu",
  /// above four viewers), the picture and sound are published there once.
  Future<void> _apply(SharePlay sharePlay, {SfuAccess? access}) async {
    final session = _session;
    if (session == null || session.id != sharePlay.id) return;
    hosting = sharePlay;
    await session.apply(sharePlay);
    if (sharePlay.media == MediaRoute.sfu) unawaited(_publish(session, access));
    app.refresh();
  }

  /// The picture and sound published once to the media server, with the access starting gave or
  /// a fresh one; tried once per share play.
  Future<void> _publish(ShareHostSession session, SfuAccess? access) async {
    if (_publisher != null || _publisherTried) return;
    _publisherTried = true;
    final publisher = session.engine.mediaServer(app.refresh);
    if (publisher == null) return;
    _publisher = publisher;
    try {
      final given = access != null && access.fresh()
          ? access
          : await MediaServerClient(app.together.account).sharePlay(session.id);
      if (_session != session) return unawaited(publisher.close());
      await publisher.start(given);
      app.addRecentLine('${DateTime.now().toIso8601String()} share play: published to the media server');
    } on Object catch (error) {
      app.addRecentLine('${DateTime.now().toIso8601String()} share play: media server: $error');
      if (_session != session) return;
      _publisher = null;
      app.show(T.text('sharePlayMediaServerFailed'));
    }
    app.refresh();
  }

  /// New relay credentials ten minutes before the old ones end.
  void _renew(DateTime? expiresAt) {
    _renewal?.cancel();
    if (expiresAt == null) return;
    final wait = expiresAt.difference(DateTime.now()) - const Duration(minutes: 10);
    _renewal = Timer(wait.isNegative ? const Duration(seconds: 1) : wait, () async {
      final session = _session;
      if (session == null) return;
      try {
        final renewed = await _client.iceServers(session.id);
        await session.renew(renewed.iceServers);
        _renew(renewed.expiresAt);
      } on Object {
        // The connections keep their relays until they run out.
      }
    });
  }

  /// The gateway's share play events (from TogetherModel), for the share play hosted and the
  /// one watched, and the invites.
  void event(TogetherEvent event) {
    final data = event.json;
    if (_watchEvent(event)) return;
    final session = _session;
    switch (event.type) {
      case 'live.ready':
        unawaited(loadInvites());
      case 'share_play.invite':
        final invite = ShareInvite.fromJson(data);
        if (invite == null) return;
        invites = [...invites.where((known) => known.sharePlayId != invite.sharePlayId), invite];
        final text = T.format('sharePlayInvitedYou', [
          invite.from?.displayName ?? '',
          _gameName(invite.titleId, invite.title),
        ]);
        // Behind another window the notice's sound, as for any other invite (none on Do Not
        // Disturb), as on the Mac.
        app.together.disturbingSound();
        app.show(text);
        // Over a game the card, unless the user asked not to be disturbed, as on the Mac.
        if (!app.together.doNotDisturb) {
          unawaited(app.noticeOverGame(text, detail: T.text('friendsTitle'), symbol: Icons.screen_share_rounded));
        }
        app.refresh();
      case 'share_play.updated' when session != null:
        try {
          unawaited(_apply(SharePlay.fromJson(data)));
        } on Object {
          // Not a share play: nothing to follow.
        }
      case 'share_play.request' when session != null && data['sharePlayId'] == session.id:
        // Someone asked to watch, from the public list or with the code: said, and listed.
        final from = data['from'];
        if (from is! Map<String, dynamic> || from['userId'] is! String) return;
        final person = Person.fromJson(from);
        if (data['via'] == 'code') codeAskers.add(person.id);
        final current = hosting;
        if (current != null) {
          hosting = current.copyWith(requests: [...current.requests.where((known) => known.id != person.id), person]);
        }
        final text = T.format('discoverAsksWatch', [TogetherModel.shown(person).name]);
        app.show(text);
        // Over the game being shared, the card (Do Not Disturb or not, as on the Mac).
        unawaited(app.noticeOverGame(text, detail: T.text('friendsTitle'), symbol: Icons.back_hand_rounded));
        app.refresh();
      case 'share_play.signal' when session != null:
        final signal = ShareSignal.fromJson(data);
        if (signal != null) unawaited(session.receive(signal));
      case 'share_play.ended':
        final id = data['sharePlayId'];
        if (invites.any((invite) => invite.sharePlayId == id)) {
          invites = [...invites.where((invite) => invite.sharePlayId != id)];
          app.refresh();
        }
        // Ended from elsewhere (the website, another launcher): this one lets go too.
        if (session != null && id == session.id) unawaited(_end());
    }
  }

  Future<void> stop() async {
    final session = _session;
    if (session == null) return;
    unawaited(_client.end(session.id).catchError((Object _) {}));
    await _end();
    app.show(T.text('sharePlayStopped'));
  }

  Future<void> _end() async {
    final session = _session;
    _session = null;
    hosting = null;
    final publisher = _publisher;
    _publisher = null;
    _publisherTried = false;
    codeAskers.clear();
    if (publisher != null) unawaited(publisher.close().catchError((Object _) {}));
    _renewal?.cancel();
    _measure?.cancel();
    _measure = null;
    final sound = _sound;
    _sound = null;
    unawaited(sound?.stop().catchError((Object _) {}));
    final remote = app.remote;
    if (remote is RemoteServer) remote.padOutput = null;
    await session?.close();
    app.refresh();
  }

  /// A share play only while its game runs.
  void gameEnded() {
    if (active) unawaited(stop());
  }

  Future<void> _call(Future<SharePlay?> Function(String id) change) async {
    final session = _session;
    if (session == null) return;
    try {
      final updated = await change(session.id);
      if (updated != null) await _apply(updated);
    } on Object catch (error) {
      app.show(app.together.message(error));
    }
  }

  void letPlay(ShareViewer viewer) {
    final pad = ShareRoster.freePad(hosting?.viewers ?? const []);
    if (pad == null) return app.show(T.text('sharePlayNoPadFree'));
    unawaited(
      _call((id) async {
        final updated = await _client.setPad(id, viewer.user.id, pad);
        app.show(T.format('sharePlayNowPlays', [viewer.user.displayName, pad]));
        return updated;
      }),
    );
  }

  void stopPlaying(ShareViewer viewer) => unawaited(_call((id) => _client.setPad(id, viewer.user.id, null)));

  void remove(ShareViewer viewer) => unawaited(
    _call((id) async {
      await _client.remove(id, viewer.user.id);
      return null;
    }),
  );

  void invite(String userId, String name) => unawaited(
    _call((id) async {
      await _client.invite(id, [userId]);
      app.show(T.format('sharePlayInvited', [name]));
      return null;
    }),
  );

  void setOpen(bool open) {
    openToFriends = open;
    unawaited(_call((id) => _client.update(id, open: open)));
  }

  void setMaxViewers(int count) {
    maxViewers = count;
    if ((hosting?.viewers.length ?? 0) > count) return app.refresh();
    unawaited(_call((id) => _client.update(id, maxViewers: count)));
  }

  // Listing in public, people asking to watch, the code.

  /// Lists the share play in public, or takes it off (null).
  void list(ShareListing? listing) => unawaited(_call((id) => _client.setListing(id, listing)));

  /// Lets someone who asked to watch in, or not.
  void answer(Person person, {required bool accept}) => unawaited(
    _call((id) async {
      final updated = await _client.answerRequest(id, person.id, accept: accept);
      codeAskers.remove(person.id);
      if (accept) app.show(T.format('sharePlayInvited', [person.displayName]));
      return updated;
    }),
  );

  /// A new code to ask to watch with; the old one stops working.
  void makeCode() => unawaited(
    _call((id) async {
      final code = await _client.makeCode(id);
      final current = hosting;
      if (current == null || current.id != id) return null;
      app.show(T.format('joinCodeMade', [code.shown]));
      return current.copyWith(joinCode: () => code);
    }),
  );

  /// The code stops working.
  void stopCode() => unawaited(
    _call((id) async {
      try {
        await _client.stopCode(id);
      } on TogetherProblem catch (problem) {
        // Stopped already.
        if (problem.status != 404) rethrow;
      }
      final current = hosting;
      if (current == null || current.id != id) return null;
      app.show(T.text('joinCodeStopped'));
      return current.copyWith(joinCode: () => null);
    }),
  );

  /// Who asked to watch: Let them watch, Not now. The Mac's shareRequestRows.
  List<PanelRow> requestRows(SharePlay sharing) => [
    for (final person in sharing.requests) ...[
      PanelRow(
        id: 'share-request-accept-${person.id}',
        title: T.format('discoverLetWatch', [TogetherModel.shown(person).name]),
        detail: ['@${person.handle}', if (codeAskers.contains(person.id)) T.text('partyRequestWithCode')].join(' · '),
        person: TogetherModel.card(person),
        kind: ActionRow(() => answer(person, accept: true)),
      ),
      PanelRow(
        id: 'share-request-decline-${person.id}',
        title: T.format('discoverNotNow', [TogetherModel.shown(person).name]),
        kind: ActionRow(() => answer(person, accept: false), destructive: true),
      ),
    ],
  ];

  /// The code anyone may ask to watch with: the code, copying it or its link, a new one,
  /// stopping it; making one where the family lets the user be found.
  List<PanelRow> codeRows(SharePlay sharing) {
    final code = sharing.joinCode;
    if (code != null && (code.expiresAt == null || code.expiresAt!.isAfter(DateTime.now()))) {
      return [
        PanelRow(id: 'share-code', title: code.shown, detail: T.text('partyCodeDetail'), kind: const InfoRow('')),
        PanelRow(
          id: 'share-code-copy',
          title: T.text('partyCodeCopy'),
          kind: ActionRow(() => app.together.copy(code.shown, T.text('partyCodeCopied'))),
        ),
        PanelRow(
          id: 'share-code-link',
          title: T.text('partyCodeCopyLink'),
          kind: ActionRow(() => app.together.copy(code.url.toString(), T.text('partyLinkCopied'))),
        ),
        PanelRow(id: 'share-code-new', title: T.text('partyCodeNew'), kind: ActionRow(makeCode)),
        PanelRow(id: 'share-code-stop', title: T.text('partyCodeStop'), kind: ActionRow(stopCode, destructive: true)),
      ];
    }
    if (!app.together.matchmakingAllowed) return const [];
    return [
      PanelRow(
        id: 'share-code-make',
        title: T.text('partyCodeMake'),
        detail: T.text('shareCodeMakeDetail'),
        kind: ActionRow(makeCode),
      ),
    ];
  }

  /// Listing in public: off, anyone may ask, anyone may watch; Live now once open; its language.
  /// The Mac's shareListingRows.
  List<PanelRow> listingRows(SharePlay sharing) {
    if (!app.together.matchmakingAllowed) return const [];
    final listing = sharing.listing;
    final joins = <PublicJoin?>[null, PublicJoin.request, PublicJoin.open];
    final rows = [
      PanelRow(
        id: 'share-public',
        title: T.text('discoverListPublic'),
        detail: T.text('discoverListPublicDetail'),
        kind: ChoiceRow(
          [T.text('discoverListOff'), T.text('discoverListAsk'), T.text('discoverListOpenWatch')],
          joins.indexOf(listing?.join).clamp(0, joins.length - 1),
          (index) {
            final join = joins[index];
            list(
              join == null
                  ? null
                  : ShareListing(
                      join: join,
                      language: listing?.language,
                      live: listing?.live ?? join == PublicJoin.open,
                    ),
            );
          },
        ),
      ),
    ];
    if (listing == null) return rows;
    if (listing.join == PublicJoin.open) {
      rows.add(
        PanelRow(
          id: 'share-live',
          title: T.text('discoverLiveToggle'),
          detail: T.text('discoverLiveToggleDetail'),
          kind: ToggleRow(
            listing.live,
            (value) => list(ShareListing(join: listing.join, language: listing.language, live: value)),
          ),
        ),
      );
    }
    final languages = <String?>[null, ...DiscoverLanguages.common];
    rows.add(
      PanelRow(
        id: 'share-language',
        title: T.text('discoverListLanguage'),
        kind: ChoiceRow(
          [for (final code in languages) code == null ? T.text('discoverAnyLanguage') : DiscoverLanguages.name(code)],
          languages.indexOf(listing.language).clamp(0, languages.length - 1),
          (index) => list(ShareListing(join: listing.join, language: languages[index], live: listing.live)),
        ),
      ),
    );
    return rows;
  }

  /// The quick menu's share play rows: start, or who watches and plays, friends to invite, stop.
  List<PanelRow> rows() {
    final playing = app.running;
    final sharing = hosting;
    if (sharing == null) {
      if (playing == null || unavailable != null) return const [];
      return [
        PanelRow(
          id: 'share-start',
          title: starting ? T.text('sharePlayStarting') : T.format('sharePlayStart', [playing.$1.name]),
          detail: T.text('sharePlayStartDetail'),
          kind: ActionRow(() => unawaited(start())),
        ),
      ];
    }
    final links = _session?.links ?? const {};
    final stats = _session?.stats ?? const {};
    final rows = <PanelRow>[
      PanelRow(
        id: 'share-on',
        title: T.format('sharePlaySharing', [sharing.title ?? playing?.$1.name ?? sharing.titleId]),
        kind: InfoRow(T.format('sharePlayWatching', [sharing.viewers.length, sharing.maxViewers])),
      ),
      ...requestRows(sharing),
      ...codeRows(sharing),
    ];
    for (final viewer in sharing.viewers) {
      final name = viewer.user.displayName;
      // Watching from the media server: no connection here to show.
      final viaServer = sharing.media == MediaRoute.sfu && !links.containsKey(viewer.user.id) && viewer.slot == null;
      final detail = linkText(
        connected: links[viewer.user.id] == 'connected',
        stats: stats[viewer.user.id],
        pad: viewer.slot,
        viaServer: viaServer,
      );
      if (viewer.slot != null) {
        rows.add(
          PanelRow(
            id: 'share-stop-${viewer.user.id}',
            title: T.format('sharePlayStopPlaying', [name]),
            detail: detail,
            person: PanelPerson(name: name, avatar: viewer.user.avatar, status: PersonStatus.playing),
            kind: ActionRow(() => stopPlaying(viewer)),
          ),
        );
        if (assistRow(viewer.user.id, name) case final row?) rows.add(row);
      } else {
        rows.add(
          PanelRow(
            id: 'share-play-${viewer.user.id}',
            title: T.format('sharePlayLetPlay', [name, ShareRoster.freePad(sharing.viewers) ?? 0]),
            detail: detail,
            person: PanelPerson(name: name, avatar: viewer.user.avatar, status: PersonStatus.online),
            kind: ActionRow(() => letPlay(viewer)),
          ),
        );
      }
      // Asked first, as on the Mac: the viewer needs a new invite to watch again.
      rows.addAll(
        app.together.askingFirst(
          PanelRow(
            id: 'share-remove-${viewer.user.id}',
            title: T.format('sharePlayRemove', [name]),
            kind: ActionRow(() => remove(viewer), destructive: true),
          ),
          T.format('askRemoveViewer', [name]),
        ),
      );
    }
    final choices = ShareMedia.viewerChoices(
      mediaLimits,
      watching: sharing.viewers.length,
      current: sharing.maxViewers,
    );
    rows
      ..add(
        PanelRow(
          id: 'share-open',
          title: T.text('sharePlayOpenToFriends'),
          detail: T.text('sharePlayOpenToFriendsDetail'),
          kind: ToggleRow(sharing.open, setOpen),
        ),
      )
      ..add(
        PanelRow(
          id: 'share-max',
          title: T.text('sharePlayMaxViewers'),
          detail: T.text(
            choices.max > ShareRoster.maxViewers ? 'sharePlayMaxViewersServerDetail' : 'sharePlayMaxViewersDetail',
          ),
          kind: StepperRow(
            value: sharing.maxViewers,
            min: choices.min,
            max: choices.max,
            step: 1,
            format: (count) => '$count',
            set: setMaxViewers,
          ),
        ),
      )
      ..addAll(listingRows(sharing));
    final watching = {for (final viewer in sharing.viewers) viewer.user.id};
    final invited = {for (final person in sharing.invited) person.id};
    for (final friend in app.together.hub.friends.friends) {
      if (!friend.presence.online || watching.contains(friend.person.id)) continue;
      final name = friend.person.displayName;
      rows.add(
        PanelRow(
          id: 'share-invite-${friend.person.id}',
          title: T.format('sharePlayInvite', [name]),
          detail: invited.contains(friend.person.id) ? T.text('sharePlayInvitedAlready') : null,
          person: PanelPerson(
            name: name,
            avatar: friend.person.avatar,
            status: friend.presence.playing ? PersonStatus.playing : PersonStatus.online,
          ),
          kind: ActionRow(() => invite(friend.person.id, name)),
        ),
      );
    }
    // Asked first, as on the Mac: stopping lets everyone watching go.
    rows.addAll(
      app.together.askingFirst(
        PanelRow(
          id: 'share-stop',
          title: T.text('sharePlayStop'),
          kind: ActionRow(() => unawaited(stop()), destructive: true),
        ),
        T.text('askStopShare'),
      ),
    );
    return rows;
  }

  /// A viewer's line, as the Mac writes it: player or watching, then the path, its round trip
  /// and the picture once connected.
  static String linkText({required bool connected, ShareLinkStats? stats, int? pad, bool viaServer = false}) {
    final parts = [
      if (pad != null) T.format('sharePlayPlayer', [pad]) else T.text('sharePlayOnlyWatches'),
    ];
    if (viaServer) return [...parts, T.text('mediaViaServer')].join(' · ');
    if (!connected) return [...parts, T.text('sharePlayConnecting')].join(' · ');
    if (stats?.relayed case final relayed?) parts.add(T.text(relayed ? 'sharePlayRelayed' : 'sharePlayDirect'));
    if (stats?.roundTripMs case final roundTrip?) parts.add(T.format('sharePlayRoundTrip', [roundTrip.round()]));
    if ((stats?.framesPerSecond, stats?.frameHeight) case (final fps?, final height?)) {
      parts.add('${height}p${fps.round()}');
    }
    return parts.join(' · ');
  }

  String _gameName(String titleId, String? title) =>
      app.games.where((game) => game.titleId == titleId).firstOrNull?.name ?? title ?? titleId;

  // Watching.

  ShareWatchSession? _watch;

  /// How the picture comes, as the Mac's watcher decides it: from the media server without a pad
  /// in a share play that goes through it, else straight from the host ([_watch]).
  ShareWatch? _route;
  WatchEngine? _watchEngine;
  ShareSoundOut? _speaker;
  SharePadPump? _pump;
  Timer? _watchStatsTimer;
  bool joining = false;

  /// The share play watched, as the server has it now.
  SharePlay? watching;
  WatchStats? watchStats;

  /// Invites waiting, newest last.
  List<ShareInvite> invites = const [];

  /// Where the watch was opened from, to go back to.
  PanelSpot? _watchReturn;

  bool get isWatching => _watch != null;
  bool get watchConnected => (_watch?.connected ?? false) || (_route?.hasPicture ?? false);

  /// Watching from the media server now.
  bool get watchViaServer => _route?.path == ShareWatchPath.sfu;

  /// The pad the host handed the user, null while they only watch.
  int? get watchSlot {
    final me = app.together.user?.id;
    return watching?.viewers.where((viewer) => viewer.user.id == me).firstOrNull?.slot;
  }

  /// The host's picture, drawn by flutter_webrtc; nothing in tests.
  Widget? watchVideo() {
    final route = _route;
    final host = watching?.host?.id;
    if (route != null && route.path == ShareWatchPath.sfu && host != null) {
      return ServerPicture(room: route.server, host: host, placeholder: const SizedBox.shrink());
    }
    final engine = _watchEngine;
    if (engine is! WebRtcWatch) return null;
    return RTCVideoView(engine.renderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain);
  }

  /// Invites waiting, and a share play a launcher that quit left behind (ended).
  Future<void> loadInvites() async {
    if (!app.together.signedIn) return;
    unawaited(loadMediaLimits());
    try {
      final mine = await _client.mine();
      invites = mine.invites;
      final stale = mine.hosting;
      if (stale != null && stale.id != _session?.id) unawaited(_client.end(stale.id).catchError((Object _) {}));
      app.refresh();
    } on Object {
      // Offline: the invites come with the next connection.
    }
  }

  void decline(ShareInvite invite) {
    invites = [...invites.where((known) => known.sharePlayId != invite.sharePlayId)];
    app.refresh();
    unawaited(_client.decline(invite.sharePlayId).catchError((Object _) {}));
  }

  /// Watches [id] here, full screen.
  Future<void> watch(String id) async {
    if (!(app.together.family.rules?.sharePlay ?? true)) return app.show(T.text('familyNoSharePlay'));
    final me = app.together.user;
    if (me == null) return app.show(T.text('sharePlaySignInFirst'));
    if (_watch?.id == id) return app.open(Layer.shareWatch);
    if (joining) return;
    await leaveWatching();
    joining = true;
    app.refresh();
    try {
      final joined = await _client.join(id);
      final host = joined.sharePlay.host;
      if (host == null) return;
      final engine = watchEngineOverride?.call() ?? WebRtcWatch();
      final speaker = speakerOverride?.call() ?? SoloudShareSound();
      ShareWatchSession mesh() => ShareWatchSession(
        id: id,
        hostId: host.id,
        hostDevice: joined.sharePlay.hostDevice,
        engine: engine,
        iceServers: joined.iceServers,
        signal: (to, device, kind, data) =>
            app.together.hub.socket.send(ShareSignal.frame(to: to, device: device, share: id, kind: kind, data: data)),
        onSound: speaker.push,
        changed: app.refresh,
      );
      final session = mesh();
      _watch = session;
      _watchEngine = engine;
      _speaker = speaker;
      watching = joined.sharePlay;
      watchStats = null;
      invites = [...invites.where((invite) => invite.sharePlayId != id)];
      _watchReturn = app.overlay == Layer.shareWatch ? _watchReturn : app.spot;
      unawaited(app.startSound());
      app.open(Layer.shareWatch);
      // The direct connection to the host only while the route says so: on the mesh, or with a
      // pad; from the media server otherwise, as on the Mac.
      var started = false;
      final route = ShareWatch(
        me: me.id,
        room: app.services.sfuRoom ?? LiveKitRoom.new,
        access: (shareId) => MediaServerClient(app.together.account).sharePlay(shareId),
        onMesh: (on) {
          final current = _watch;
          if (current == null || current.id != id) return;
          if (on && !started) {
            started = true;
            current.start();
          } else if (!on && started) {
            // The pad taken back: off the host's connection, a fresh one ready for the next.
            started = false;
            _pump?.stop();
            _pump = null;
            final fresh = mesh();
            _watch = fresh;
            unawaited(current.close());
          }
          app.refresh();
        },
        changed: app.refresh,
      );
      _route = route;
      await route.start(joined);
      _followSlot();
      _watchStatsTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
        final current = _watch;
        if (current == null || current.id != id) return;
        final stats = await current.stats();
        if (_watch != current) return;
        watchStats = stats;
        app.refresh();
      });
    } on TogetherProblem catch (problem) {
      app.show(
        problem.code == 'full'
            ? T.text('sharePlayFull')
            : '${T.text('sharePlayCouldNotWatch')}: ${app.together.message(problem)}',
      );
    } on Object catch (error) {
      app.show('${T.text('sharePlayCouldNotWatch')}: ${app.together.message(error)}');
    } finally {
      joining = false;
      app.refresh();
    }
  }

  /// The controller goes to the host while they let the user play, and stops when they take it.
  void _followSlot() {
    final session = _watch;
    if (session == null) return;
    if (watchSlot == null) {
      _pump?.stop();
      _pump = null;
      return;
    }
    _pump ??= SharePadPump(read: padOverride ?? _readPad, send: session.sendPad)..start();
  }

  /// Player 1's controller now, as the controller test reads it.
  PadState? _readPad() {
    final controllers = app.controllers;
    final pad = controllers.playerOne;
    if (pad == null) return null;
    return controllers.inventory?.state(pad.id);
  }

  Future<void> leaveWatching({bool tellServer = true}) async {
    final session = _watch;
    if (session == null) return;
    _watch = null;
    final route = _route;
    _route = null;
    if (route != null) unawaited(route.stop().catchError((Object _) {}));
    _pump?.stop();
    _pump = null;
    _watchStatsTimer?.cancel();
    _speaker?.stop();
    _speaker = null;
    final engine = _watchEngine;
    _watchEngine = null;
    watching = null;
    watchStats = null;
    await session.close();
    if (engine is WebRtcWatch) unawaited(engine.dispose());
    if (tellServer) unawaited(_client.leave(session.id).catchError((Object _) {}));
    if (app.overlay == Layer.shareWatch) app.returnTo(_watchReturn);
    app.refresh();
  }

  /// The share play watched changed (a pad handed over or taken back), a signal came, or it
  /// ended; false for anything else.
  bool _watchEvent(TogetherEvent event) {
    final session = _watch;
    if (session == null) return false;
    final data = event.json;
    switch (event.type) {
      case 'share_play.updated' when data['id'] == session.id:
        final SharePlay sharePlay;
        try {
          sharePlay = SharePlay.fromJson(data);
        } on Object {
          return false;
        }
        final before = watchSlot;
        watching = sharePlay;
        final now = watchSlot;
        if (now != before) app.show(now == null ? T.text('sharePlayYouWatch') : T.format('sharePlayYouPlay', [now]));
        // The route follows: a pad handed over moves to the host's connection, taken back to the
        // media server.
        final route = _route;
        if (route != null) {
          unawaited(route.apply(sharePlay).then((_) => _followSlot(), onError: (Object _) {}));
        } else {
          _followSlot();
        }
        app.refresh();
        return true;
      case 'share_play.signal' when data['sharePlayId'] == session.id:
        final signal = ShareSignal.fromJson(data);
        if (signal != null) unawaited(session.receive(signal));
        return true;
      case 'share_play.ended' when data['sharePlayId'] == session.id:
        final host = watching?.host?.displayName ?? '';
        unawaited(leaveWatching(tellServer: false));
        app.show(T.format(data['reason'] == 'removed' ? 'sharePlayTookYouOut' : 'sharePlayHostStopped', [host]));
        return true;
    }
    return false;
  }

  /// While watching the controller is the game's: only PS (Esc and ○ too while only watching,
  /// or without a controller) leaves.
  void watchCommand(Command command) {
    final noPad = app.controllers.playerOne == null && padOverride == null;
    if (command == Command.home || (command == Command.back && (watchSlot == null || noPad))) {
      unawaited(leaveWatching());
    }
  }

  /// A share play guest with a pad: help player 1 rather than play their own, as on the Mac.
  PanelRow? assistRow(String userId, String name) {
    final router = _session?.router;
    if (router == null) return null;
    return PanelRow(
      id: 'share-assist-$userId',
      title: T.text('assistShare'),
      detail: T.format('assistShareDetail', [name]),
      kind: ToggleRow(router.assist.contains(userId), (on) {
        on ? router.assist.add(userId) : router.assist.remove(userId);
        app.refresh();
      }),
    );
  }

  /// The Friends panel's rows: invites to watch (and to decline), and friends sharing who let
  /// friends walk in.
  List<PanelRow> watchRows() {
    if (!(app.together.family.rules?.sharePlay ?? true)) return const [];
    final rows = <PanelRow>[];
    for (final invite in invites) {
      final from = invite.from?.displayName ?? '';
      rows
        ..add(
          PanelRow(
            id: 'share-watch-${invite.sharePlayId}',
            title: T.format('sharePlayWatchFriend', [from, _gameName(invite.titleId, invite.title)]),
            detail: T.text('sharePlayWatchDetail'),
            person: invite.from == null
                ? null
                : PanelPerson(name: from, avatar: invite.from!.avatar, status: PersonStatus.playing),
            kind: ActionRow(() => unawaited(watch(invite.sharePlayId))),
          ),
        )
        ..add(
          PanelRow(
            id: 'share-decline-${invite.sharePlayId}',
            title: T.format('sharePlayDecline', [from]),
            kind: ActionRow(() => decline(invite), destructive: true),
          ),
        );
    }
    for (final friend in app.together.hub.friends.friends) {
      final shared = friend.presence.share;
      if (shared == null || !shared.open || invites.any((invite) => invite.sharePlayId == shared.sharePlayId)) continue;
      final name = friend.person.displayName;
      rows.add(
        PanelRow(
          id: 'share-friend-${shared.sharePlayId}',
          title: T.format('sharePlayWatchFriend', [name, _gameName(shared.titleId, shared.title)]),
          detail: T.format('sharePlayWatching', [shared.viewers, shared.maxViewers]),
          person: PanelPerson(name: name, avatar: friend.person.avatar, status: PersonStatus.playing),
          kind: ActionRow(() => unawaited(watch(shared.sharePlayId))),
        ),
      );
    }
    return rows;
  }

  void dispose() {
    if (active) unawaited(stop());
    if (isWatching) unawaited(leaveWatching());
  }
}
