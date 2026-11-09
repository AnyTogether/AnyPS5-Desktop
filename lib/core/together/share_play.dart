import 'dart:typed_data';

import '../remote/remote_protocol.dart';
import 'account.dart';
import 'discover.dart' show PublicJoin;
import 'media.dart';
import 'parties.dart' show JoinCode;
import 'people.dart';

/// Share play: the game the user runs, streamed to friends who watch it live (WebRTC, one peer
/// connection per viewer); a viewer the host hands a pad plays along as player 2, 3 or 4. The
/// server introduces them and relays the signalling; picture, sound and pads go between them.
/// The macOS launcher's TogetherSharePlay.swift, with the same server calls.
class SharePlay {
  const SharePlay({
    required this.id,
    required this.hostDevice,
    required this.titleId,
    required this.open,
    required this.maxViewers,
    required this.viewers,
    this.host,
    this.title,
    this.invited = const [],
    this.media = MediaRoute.mesh,
    this.listing,
    this.requests = const [],
    this.joinCode,
  });

  factory SharePlay.fromJson(Map<String, dynamic> json) => SharePlay(
    id: json['id'] as String,
    host: json['host'] is Map<String, dynamic> ? Person.fromJson(json['host'] as Map<String, dynamic>) : null,
    hostDevice: json['hostDevice'] as String? ?? '',
    titleId: json['titleId'] as String? ?? '',
    title: json['title'] as String?,
    open: json['open'] == true,
    maxViewers: (json['maxViewers'] as num?)?.toInt() ?? 2,
    media: MediaRoute.parse(json['media']),
    viewers: [
      for (final viewer in json['viewers'] as List? ?? const [])
        if (viewer is Map<String, dynamic>) ShareViewer.fromJson(viewer),
    ],
    invited: [
      for (final person in json['invited'] as List? ?? const [])
        if (person is Map<String, dynamic>) Person.fromJson(person),
    ],
    listing: ShareListing.fromJson(json['public']),
    requests: [
      for (final person in json['requests'] as List? ?? const [])
        if (person is Map<String, dynamic>) Person.fromJson(person),
    ],
    joinCode: JoinCode.fromJson(json['joinCode']),
  );

  final String id;
  final Person? host;

  /// The host's device: where a viewer's signals go.
  final String hostDevice;
  final String titleId;
  final String? title;
  final bool open;
  final int maxViewers;

  /// The mesh (the host streams to each viewer), or the media server: viewers without a pad
  /// watch from there, viewers with one keep their direct connection to the host.
  final MediaRoute media;
  final List<ShareViewer> viewers;

  /// Invited and not here yet; only the host is told.
  final List<Person> invited;

  /// In the public list, and how; null when it is not listed.
  final ShareListing? listing;

  /// People who asked to watch, from the public list or with the code; only the host is told.
  final List<Person> requests;

  /// The code anyone may ask to watch with, while one works; only the host is told.
  final JoinCode? joinCode;

  /// The same share play with another code (null: none) or other people asking.
  SharePlay copyWith({JoinCode? Function()? joinCode, List<Person>? requests}) => SharePlay(
    id: id,
    host: host,
    hostDevice: hostDevice,
    titleId: titleId,
    title: title,
    open: open,
    maxViewers: maxViewers,
    viewers: viewers,
    invited: invited,
    media: media,
    listing: listing,
    requests: requests ?? this.requests,
    joinCode: joinCode == null ? this.joinCode : joinCode(),
  );
}

/// How a share play is listed in public (the server's "public"): who may come in (request: they
/// ask and the host lets them in, open: anyone may watch), its language, and whether it is also
/// under Live now, which only an open one can be. The Mac's TogetherShareListing.
class ShareListing {
  ShareListing({required this.join, this.language, bool live = false}) : live = live && join == PublicJoin.open;

  static ShareListing? fromJson(Object? json) {
    if (json is! Map) return null;
    return ShareListing(
      join: json['join'] == 'open' ? PublicJoin.open : PublicJoin.request,
      language: json['language'] as String?,
      live: json['live'] == true,
    );
  }

  final PublicJoin join;
  final String? language;
  final bool live;

  Map<String, dynamic> toJson() => {'join': join.name, 'language': language, 'live': live};
}

class ShareViewer {
  const ShareViewer({required this.user, required this.device, this.slot});

  factory ShareViewer.fromJson(Map<String, dynamic> json) => ShareViewer(
    user: Person.fromJson(json['user'] as Map<String, dynamic>),
    device: json['device'] as String? ?? '',
    slot: (json['slot'] as num?)?.toInt(),
  );

  final Person user;

  /// The device (session) they watch on: where the host's signals for them go.
  final String device;

  /// The pad they play with (2-4), null while they only watch.
  final int? slot;
}

/// What starting and joining give: the share play, the servers to reach each other through, and
/// its media server room while it is "sfu".
class SharePlayStart {
  const SharePlayStart(this.sharePlay, this.iceServers, this.expiresAt, {this.sfu});
  final SharePlay sharePlay;
  final List<Map<String, dynamic>> iceServers;
  final DateTime? expiresAt;

  /// The host may publish to it, a viewer only watch; null on the mesh.
  final SfuAccess? sfu;

  factory SharePlayStart.fromJson(Map<String, dynamic> json) => SharePlayStart(
    SharePlay.fromJson(json['sharePlay'] as Map<String, dynamic>),
    [
      for (final server in json['iceServers'] as List? ?? const [])
        if (server is Map<String, dynamic>) server,
    ],
    json['expiresAt'] is String ? DateTime.tryParse(json['expiresAt'] as String) : null,
    sfu: SfuAccess.fromJson(json['sfu']),
  );
}

/// A signal between the host and a viewer, relayed by the gateway (`share_play.signal`).
class ShareSignal {
  const ShareSignal({
    required this.sharePlayId,
    required this.from,
    required this.device,
    required this.kind,
    this.data,
  });

  static ShareSignal? fromJson(Map<String, dynamic> json) {
    final id = json['sharePlayId'];
    final from = json['from'];
    final device = json['device'];
    final kind = json['kind'];
    if (id is! String || from is! String || device is! String || kind is! String) return null;
    return ShareSignal(sharePlayId: id, from: from, device: device, kind: kind, data: json['data']);
  }

  final String sharePlayId;
  final String from;
  final String device;

  /// offer, answer, candidate, bye, renegotiate.
  final String kind;
  final Object? data;

  /// The gateway frame that sends a signal to one device of a viewer.
  static Map<String, dynamic> frame({
    required String to,
    required String device,
    required String share,
    required String kind,
    Object? data,
  }) => {'op': 'signal', 'to': to, 'device': device, 'share': share, 'kind': kind, 'data': data};
}

/// A friend's invite to watch their share play (`share_play.invite`, and `me/share-play`).
class ShareInvite {
  const ShareInvite({required this.sharePlayId, required this.titleId, this.from, this.title});

  static ShareInvite? fromJson(Object? json) {
    if (json is! Map<String, dynamic> || json['sharePlayId'] is! String) return null;
    return ShareInvite(
      sharePlayId: json['sharePlayId'] as String,
      from: json['from'] is Map<String, dynamic> ? Person.fromJson(json['from'] as Map<String, dynamic>) : null,
      titleId: json['titleId'] as String? ?? '',
      title: json['title'] as String?,
    );
  }

  final String sharePlayId;
  final Person? from;
  final String titleId;
  final String? title;
}

/// A share play listed in public, or under Live now (`share-plays/public`).
class PublicShare {
  const PublicShare({
    required this.id,
    required this.titleId,
    required this.join,
    required this.live,
    required this.viewers,
    required this.maxViewers,
    required this.requested,
    this.host,
    this.title,
    this.names = const {},
    this.language,
  });

  static PublicShare? fromJson(Object? json) {
    if (json is! Map<String, dynamic> || json['id'] is! String) return null;
    final game = json['game'];
    return PublicShare(
      id: json['id'] as String,
      host: json['host'] is Map<String, dynamic> ? Person.fromJson(json['host'] as Map<String, dynamic>) : null,
      titleId: json['titleId'] as String? ?? '',
      title: json['title'] as String?,
      names: {
        if (game is Map && game['names'] is Map)
          for (final entry in (game['names'] as Map).entries)
            if (entry.value is String) '${entry.key}': entry.value as String,
      },
      language: json['language'] as String?,
      join: json['join'] as String? ?? 'request',
      live: json['live'] == true,
      viewers: (json['viewers'] as num? ?? 0).toInt(),
      maxViewers: (json['maxViewers'] as num? ?? 2).toInt(),
      requested: json['requested'] == true,
    );
  }

  final String id;
  final Person? host;
  final String titleId;
  final String? title;
  final Map<String, String> names;
  final String? language;

  /// open (anyone may walk in) or request (the host lets them in).
  final String join;
  final bool live;
  final int viewers;
  final int maxViewers;

  /// The user asked to watch and waits for the host.
  final bool requested;

  bool get open => join == 'open';
}

/// The server's share play calls.
class SharePlayClient {
  SharePlayClient(this.account);
  final TogetherAccount account;

  /// Shares the game this launcher runs (ending any share play the user had).
  Future<SharePlayStart> start({
    required String titleId,
    String? title,
    required bool open,
    required int maxViewers,
  }) async => SharePlayStart.fromJson(
    await account.call('POST', 'share-plays', {
      'titleId': titleId,
      'open': open,
      'maxViewers': maxViewers,
      if (title != null && title.isNotEmpty) 'title': title.length > 80 ? title.substring(0, 80) : title,
    }),
  );

  /// The share play the user hosts, if a launcher that quit left one behind.
  Future<SharePlay?> hosting() async {
    final json = await account.call('GET', 'me/share-play');
    return json['hosting'] is Map<String, dynamic> ? SharePlay.fromJson(json['hosting'] as Map<String, dynamic>) : null;
  }

  /// What the user has: the share play they host or watch, and the invites waiting.
  Future<({SharePlay? hosting, SharePlay? watching, List<ShareInvite> invites})> mine() async {
    final json = await account.call('GET', 'me/share-play');
    SharePlay? play(Object? value) => value is Map<String, dynamic> ? SharePlay.fromJson(value) : null;
    return (
      hosting: play(json['hosting']),
      watching: play(json['watching']),
      invites: [for (final invite in json['invites'] as List? ?? const []) ?ShareInvite.fromJson(invite)],
    );
  }

  Future<void> decline(String id) async {
    await account.call('POST', 'share-plays/${Uri.encodeComponent(id)}/decline', const {});
  }

  /// Share plays listed in public; [live] only those under Live now.
  Future<List<PublicShare>> public({bool live = false}) async {
    final json = await account.call('GET', 'share-plays/public${live ? '?live=1' : ''}');
    return [for (final share in json['sharePlays'] as List? ?? const []) ?PublicShare.fromJson(share)];
  }

  /// Asks the host of a public share play to let the user watch.
  Future<void> askToWatch(String id) async {
    await account.call('POST', 'share-plays/${Uri.encodeComponent(id)}/requests', const {});
  }

  Future<SharePlay> update(String id, {bool? open, int? maxViewers}) async =>
      SharePlay.fromJson(await account.call('PATCH', 'share-plays/$id', {'open': ?open, 'maxViewers': ?maxViewers}));

  /// Lists the share play the user hosts in public, or takes it off (null).
  Future<SharePlay> setListing(String id, ShareListing? listing) async =>
      SharePlay.fromJson(await account.call('PATCH', 'share-plays/$id', {'public': listing?.toJson()}));

  /// Lets someone who asked to watch in, or not.
  Future<SharePlay> answerRequest(String id, String userId, {required bool accept}) async => SharePlay.fromJson(
    await account.call('POST', 'share-plays/$id/requests/$userId/${accept ? 'accept' : 'decline'}', const {}),
  );

  /// A new code to ask to watch with (the old one stops working).
  Future<JoinCode> makeCode(String id) async =>
      JoinCode.fromJson(await account.call('POST', 'share-plays/$id/code', const {})) ??
      (throw const FormatException('No code in the answer'));

  /// The code stops working.
  Future<void> stopCode(String id) async {
    await account.call('DELETE', 'share-plays/$id/code');
  }

  Future<void> end(String id) async {
    await account.call('DELETE', 'share-plays/$id');
  }

  /// Watches a friend's share play: a seat, and its media server room while it is "sfu".
  Future<SharePlayStart> join(String id) async =>
      SharePlayStart.fromJson(await account.call('POST', 'share-plays/$id/join'));

  /// Stops watching.
  Future<void> leave(String id) async {
    await account.call('POST', 'share-plays/$id/leave');
  }

  Future<void> invite(String id, List<String> userIds) async {
    await account.call('POST', 'share-plays/$id/invites', {'userIds': userIds});
  }

  /// Hands a viewer pad 2, 3 or 4, or takes it back (null).
  Future<SharePlay> setPad(String id, String userId, int? slot) async =>
      SharePlay.fromJson(await account.call('PUT', 'share-plays/$id/viewers/$userId/slot', {'slot': slot}));

  Future<void> remove(String id, String userId) async {
    await account.call('DELETE', 'share-plays/$id/viewers/$userId');
  }

  Future<SharePlayStart> iceServers(String id) async {
    final json = await account.call('GET', 'share-plays/$id/ice-servers');
    return SharePlayStart(
      const SharePlay(id: '', hostDevice: '', titleId: '', open: false, maxViewers: 0, viewers: []),
      [
        for (final server in json['iceServers'] as List? ?? const [])
          if (server is Map<String, dynamic>) server,
      ],
      json['expiresAt'] is String ? DateTime.tryParse(json['expiresAt'] as String) : null,
    );
  }
}

/// The host's bookkeeping as the share play changes: whom to call, whom to hang up on, who holds
/// which pad, and the video settings for the viewers' answers.
abstract final class ShareRoster {
  /// Pads a viewer can be handed: player 1 is the host.
  static const pads = [2, 3, 4];

  /// The host uploads a stream per viewer: at most four on the mesh. More watch through the
  /// media server, up to what it takes ([ShareMedia.viewerChoices]).
  static const maxViewers = 4;

  /// Viewers to call (new, or on another device than before) and to hang up on (gone, or moved
  /// to another device: the old connection goes first).
  static ({List<ShareViewer> call, List<String> hangUp}) plan(List<ShareViewer> before, List<ShareViewer> after) {
    final old = {for (final viewer in before) viewer.user.id: viewer.device};
    final now = {for (final viewer in after) viewer.user.id: viewer.device};
    return (
      call: [
        for (final viewer in after)
          if (old[viewer.user.id] != viewer.device) viewer,
      ],
      hangUp: [
        for (final MapEntry(:key, :value) in old.entries)
          if (now[key] != value) key,
      ],
    );
  }

  /// Who holds which pad, by user ID.
  static Map<String, int> padsOf(List<ShareViewer> viewers) => {
    for (final viewer in viewers)
      if (viewer.slot != null) viewer.user.id: viewer.slot!,
  };

  /// The lowest pad nobody holds, for Let Them Play; null when all are taken.
  static int? freePad(List<ShareViewer> viewers) {
    final taken = {for (final viewer in viewers) ?viewer.slot};
    for (final pad in pads) {
      if (!taken.contains(pad)) return pad;
    }
    return null;
  }

  /// What each viewer's stream may take: 720p60 up to 10 Mbit/s for one or two viewers; from
  /// three on, 540p30 up to 5 Mbit/s apiece.
  static ({int maxBitrate, int maxFramerate, double scaleDown, int startKbps}) encoding(int viewers) => viewers >= 3
      ? (maxBitrate: 5000000, maxFramerate: 30, scaleDown: 4 / 3, startKbps: 1500)
      : (maxBitrate: 10000000, maxFramerate: 60, scaleDown: 1.0, startKbps: 2500);

  /// The viewer's answer with WebRTC's own bit rate hints on each H.264 format, as the Mac puts
  /// them in: start high enough that the first picture is sharp, never above [maxKbps].
  static String tuneVideo(String sdp, {required int startKbps, required int maxKbps}) {
    final payloads = RegExp(
      r'a=rtpmap:(\d+) H264/90000',
      caseSensitive: false,
    ).allMatches(sdp).map((match) => match.group(1)!);
    final lines = sdp.split('\r\n');
    final hints = 'x-google-start-bitrate=$startKbps;x-google-max-bitrate=$maxKbps;x-google-min-bitrate=600';
    for (final payload in payloads) {
      final prefix = 'a=fmtp:$payload ';
      final index = lines.indexWhere((line) => line.startsWith(prefix));
      if (index >= 0) {
        if (!lines[index].contains('x-google-start-bitrate')) lines[index] = '${lines[index]};$hints';
      } else {
        final rtpmap = lines.indexWhere((line) => line.startsWith('a=rtpmap:$payload '));
        if (rtpmap >= 0) lines.insert(rtpmap + 1, '$prefix$hints');
      }
    }
    return lines.join('\r\n');
  }
}

/// The game's pad bridges as share play uses them: one held per viewer with a pad.
abstract interface class SharePadBridges {
  int? reservePadBridge();
  void releasePadBridge(int bridge);
  void sendPad(Uint8List data, int bridge);
}

/// Viewers' pad packets to the game: only from a viewer the host handed a pad, each through a
/// bridge of their own, carrying the pad the host gave (byte 13) so the engine seats them as that
/// player and never as the host's player 1. A pad taken back lets go of every button before its
/// bridge is freed. The macOS launcher's SharePadRouter.
class SharePadRouter {
  SharePadRouter(this.bridges);

  final SharePadBridges bridges;
  final _held = <String, int>{};
  final _last = <String, Uint8List>{};
  var _pads = <String, int>{};

  /// The viewers with a pad who help player 1 rather than play their own (assist): their packets
  /// say so instead of their pad.
  final assist = <String>{};

  /// The pads as the share play has them now (user ID → pad 2-4).
  void update(Map<String, int> pads) {
    _pads = Map.of(pads);
    for (final userId in _held.keys.where((userId) => !pads.containsKey(userId)).toList()) {
      final bridge = _held.remove(userId)!;
      final last = _last.remove(userId);
      if (last != null) bridges.sendPad(letGo(last), bridge);
      bridges.releasePadBridge(bridge);
    }
    final wanted = pads.keys.where((userId) => !_held.containsKey(userId)).toList()
      ..sort((a, b) => pads[a]!.compareTo(pads[b]!));
    for (final userId in wanted) {
      final bridge = bridges.reservePadBridge();
      if (bridge == null) break;
      _held[userId] = bridge;
    }
  }

  /// A packet from a viewer's pad channel: forwarded when it is a well-formed pad packet from a
  /// viewer who holds a pad; true when it went on.
  bool receive(Uint8List data, String userId) {
    final session = RemotePacket.inputSession(data);
    final bridge = _held[userId];
    final pad = _pads[userId];
    if (session == null || session == 0 || bridge == null || pad == null) return false;
    final packet = Uint8List.fromList(data)
      ..[RemotePacket.seatByte] = assist.contains(userId) ? RemotePacket.assistSeat : pad;
    _last[userId] = packet;
    bridges.sendPad(packet, bridge);
    return true;
  }

  int? bridgeOf(String userId) => _held[userId];

  /// Whose pad a bridge carries, for the game's answers on it.
  String? viewerOn(int bridge) => _held.entries.where((entry) => entry.value == bridge).firstOrNull?.key;

  /// Every bridge given back (share play over).
  void releaseAll() => update(const {});

  /// The packet after [packet] with nothing pressed: no buttons, sticks centred, triggers up, no
  /// touch, same session.
  static Uint8List letGo(Uint8List packet) {
    final out = Uint8List.fromList(packet);
    final data = ByteData.sublistView(out);
    data.setUint32(8, (data.getUint32(8, Endian.little) + 1) & 0xFFFFFFFF, Endian.little);
    out.fillRange(32, 36, 0);
    out.fillRange(36, 40, 128);
    out[40] = 0;
    out[41] = 0;
    out.fillRange(44, 56, 0);
    return out;
  }
}

/// Who watches through the media server and who keeps the direct connection to the host, and
/// how many the host may let watch. The Mac's SharePlayMedia.
abstract final class ShareMedia {
  /// The host's "how many may watch" choices: up to the server's limit with a media server, the
  /// mesh's 1-4 without one (or when the server did not say); never below who watches now nor
  /// below the share play's own limit.
  static ({int min, int max}) viewerChoices(MediaLimits? limits, {int watching = 0, int current = 1}) {
    final server = limits != null && limits.sfu ? limits.maxShareViewers : 0;
    final top = [ShareRoster.maxViewers, server, current].reduce((a, b) => a > b ? a : b);
    final bottom = watching < 1 ? 1 : watching;
    return (min: bottom < top ? bottom : top, max: top);
  }

  /// The saved choice within what the server takes now.
  static int clampViewers(int count, MediaLimits? limits) {
    final top = viewerChoices(limits).max;
    return count < 1 ? 1 : (count > top ? top : count);
  }

  /// The viewers the host keeps a direct (mesh) connection with: everyone on the mesh; through
  /// the media server, those holding a pad, and older viewer apps without a pad that asked for
  /// one ([asked]) and were served.
  static List<ShareViewer> meshViewers(SharePlay share, Set<String> asked) {
    if (share.media != MediaRoute.sfu) return share.viewers;
    return [
      for (final viewer in share.viewers)
        if (viewer.slot != null || asked.contains(viewer.user.id)) viewer,
    ];
  }

  /// Whether the host answers a viewer's ask for an offer with a mesh connection: always on the
  /// mesh; through the media server, for a pad holder, or (best effort, for viewer apps from
  /// before the media server) while the host has fewer than four direct connections.
  static bool servesAsk(SharePlay share, String userId, {required int meshPeers}) {
    if (share.media != MediaRoute.sfu) return true;
    final viewer = share.viewers.where((viewer) => viewer.user.id == userId).firstOrNull;
    if (viewer == null) return false;
    return viewer.slot != null || meshPeers < ShareRoster.maxViewers;
  }
}
