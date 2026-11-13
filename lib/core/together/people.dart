import '../now_playing.dart';
import 'levels.dart';

/// Someone on AnyTogether as the API's name cards show them.
class Person {
  const Person({
    required this.id,
    required this.handle,
    required this.displayName,
    this.avatar,
    this.privateName,
    this.privateAvatar,
  });

  factory Person.fromJson(Map<String, dynamic> json) => Person(
    id: json['userId'] as String,
    handle: json['handle'] as String,
    displayName: json['displayName'] as String,
    avatar: json['avatar'] as String?,
    privateName: json['privateName'] is String ? json['privateName'] as String : null,
    privateAvatar: json['privateAvatar'] is String ? json['privateAvatar'] as String : null,
  );

  final String id;
  final String handle;
  final String displayName;

  /// The picture's full address, or null for none.
  final String? avatar;

  /// The friends-only name and picture (docs/private-identity.md): on the cards of friends in
  /// the answers that carry them, null when not set or not for this user to see. The picture is
  /// a signed link that runs out.
  final String? privateName;
  final String? privateAvatar;

  Map<String, Object?> toJson() => {
    'userId': id,
    'handle': handle,
    'displayName': displayName,
    'avatar': avatar,
    'privateName': ?privateName,
    'privateAvatar': ?privateAvatar,
  };
}

enum PresenceState { inGame, online, away, offline }

/// What a user chose to show on AnyTogether (`status`): online, idle, do not disturb, or
/// invisible (others see them offline). Servers before it only had appear offline.
enum PresenceStatus {
  online,
  idle,
  dnd,
  invisible;

  /// The server's word for it, null for none or one this launcher does not know.
  static PresenceStatus? parse(Object? value) => switch (value) {
    'online' => online,
    'idle' => idle,
    'dnd' => dnd,
    'invisible' => invisible,
    _ => null,
  };
}

/// The party a friend is in: its size, and whether friends may walk in.
class PresenceParty {
  const PresenceParty({required this.id, required this.size, required this.max, required this.open});

  final String id;
  final int size;
  final int max;
  final bool open;
}

/// The game session a friend hosts: open to friends and not full when joinable.
class PresenceGame {
  const PresenceGame({
    required this.sessionId,
    required this.titleId,
    required this.joinable,
    required this.players,
    required this.capacity,
    this.kind,
    this.hostId,
  });

  final String sessionId;
  final String titleId;
  final bool joinable;
  final int players;
  final int capacity;

  /// online, lan (Play Together) or local; null from older servers.
  final String? kind;
  final String? hostId;

  /// Playing together (a LAN game with their party).
  bool get together => kind == 'lan';
}

/// The share play a friend hosts, in their presence.
class PresenceShare {
  const PresenceShare({
    required this.sharePlayId,
    required this.titleId,
    required this.open,
    required this.viewers,
    required this.maxViewers,
    this.title,
  });

  final String sharePlayId;
  final String titleId;
  final String? title;

  /// Open to friends and not full: a friend may walk in.
  final bool open;
  final int viewers;
  final int maxViewers;
}

/// What a friend shows: in a game (which, since when), online, away or offline, the party they
/// are in, the game session and the share play they host.
class Presence {
  const Presence({
    this.state = PresenceState.offline,
    this.status,
    this.titleId,
    this.since,
    this.party,
    this.game,
    this.share,
    this.listening,
  });

  factory Presence.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const Presence();
    final party = json['party'];
    final game = json['game'];
    final status = PresenceStatus.parse(json['status']);
    return Presence(
      // Invisible is offline to everyone else, whatever else came with it.
      state: status == PresenceStatus.invisible
          ? PresenceState.offline
          : switch (json['state']) {
              'in_game' => PresenceState.inGame,
              'online' => PresenceState.online,
              'away' => PresenceState.away,
              _ => PresenceState.offline,
            },
      status: status == PresenceStatus.invisible ? null : status,
      titleId: json['titleId'] as String?,
      since: DateTime.tryParse(json['since'] as String? ?? ''),
      party: party is Map<String, dynamic> && party['id'] is String
          ? PresenceParty(
              id: party['id'] as String,
              size: (party['size'] as num? ?? 1).toInt(),
              max: (party['max'] as num? ?? 8).toInt(),
              open: party['open'] == true,
            )
          : null,
      game: game is Map<String, dynamic> && game['sessionId'] is String
          ? PresenceGame(
              sessionId: game['sessionId'] as String,
              titleId: game['titleId'] as String? ?? '',
              joinable: game['joinable'] == true,
              players: (game['players'] as num? ?? 1).toInt(),
              capacity: (game['capacity'] as num? ?? 1).toInt(),
              kind: game['kind'] as String?,
              hostId: game['hostId'] as String?,
            )
          : null,
      share: _share(json['share']),
      listening: Listening.fromJson(json['listening']),
    );
  }

  final PresenceState state;

  /// Idle or do not disturb, as they chose it; null from older servers (and for online).
  final PresenceStatus? status;
  final String? titleId;
  final DateTime? since;
  final PresenceParty? party;
  final PresenceGame? game;
  final PresenceShare? share;

  /// What they listen to, when they chose to show it (a server before it sends none).
  final Listening? listening;

  static PresenceShare? _share(Object? share) {
    if (share is! Map<String, dynamic> || share['sharePlayId'] is! String) return null;
    return PresenceShare(
      sharePlayId: share['sharePlayId'] as String,
      titleId: share['titleId'] as String? ?? '',
      title: share['title'] as String?,
      open: share['open'] == true,
      viewers: (share['viewers'] as num? ?? 0).toInt(),
      maxViewers: (share['maxViewers'] as num? ?? 2).toInt(),
    );
  }

  bool get playing => state == PresenceState.inGame;
  bool get online => state != PresenceState.offline;
}

/// A friend, what they are doing, and their trophy level (null when they keep their trophies
/// from this user, or on a server older than levels).
class Friend {
  const Friend(this.person, this.presence, {this.level});

  final Person person;
  final Presence presence;
  final LevelBadge? level;

  Friend copyWith({Presence? presence, LevelBadge? level}) =>
      Friend(person, presence ?? this.presence, level: level ?? this.level);
}
