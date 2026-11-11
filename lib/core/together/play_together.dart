import 'account.dart';
import 'game_sessions.dart';
import 'join_advice.dart';
import 'people.dart';

/// Play Together: in a party, the host picks a game and starts it for the party; the launcher
/// opens a LAN game session (kind `lan`) and starts the game with online play on for that session.
/// The rest of the party hears "Mira started Minecraft"; Join checks they have the same game and
/// version, then starts it in the same session, so the peer mesh joins the players' virtual LAN
/// and the host's game finds the others by broadcast. It ends with its host.

/// The party's Play Together game while one runs, as the party view carries it.
class PartyTogether {
  const PartyTogether({
    required this.sessionId,
    required this.hostId,
    required this.titleId,
    required this.gameVersion,
    required this.engineBuild,
    required this.players,
    required this.capacity,
    this.versionRule = 'exact',
    this.versionOverrides = const [],
  });

  /// The game, or null when the server sent none (or an older server says nothing of it).
  static PartyTogether? fromJson(Object? json) {
    if (json is! Map<String, dynamic> || json['sessionId'] is! String) return null;
    return PartyTogether(
      sessionId: json['sessionId'] as String,
      hostId: json['hostId'] as String? ?? '',
      titleId: json['titleId'] as String? ?? '',
      gameVersion: json['gameVersion'] as String? ?? '',
      engineBuild: json['engineBuild'] as String? ?? '',
      versionRule: json['versionRule'] as String? ?? 'exact',
      players: [
        for (final id in json['players'] as List<dynamic>? ?? const [])
          if (id is String) id,
      ],
      capacity: (json['capacity'] as num? ?? 2).toInt(),
      versionOverrides: [
        for (final id in json['versionOverrides'] as List<dynamic>? ?? const [])
          if (id is String) id,
      ],
    );
  }

  final String sessionId;
  final String hostId;
  final String titleId;
  final String gameVersion;
  final String engineBuild;
  final String versionRule;

  /// Who plays, the host first, by user id.
  final List<String> players;
  final int capacity;

  /// The players who joined with a game version that did not fit, by trying anyway (none from a
  /// server before it).
  final List<String> versionOverrides;
}

/// Why the server refused a join: a different game version or engine build, the host's and this
/// copy's, whether this side is the one behind, and whether the player may try anyway (a game
/// version only: a different engine build cannot talk to the host's).
class JoinRefusal {
  const JoinRefusal({
    required this.engine,
    required this.expected,
    required this.actual,
    required this.youUpdate,
    required this.overridable,
  });

  /// From a refused join's problem; null when it was not about the versions (or an older server
  /// said no more).
  static JoinRefusal? of(TogetherProblem problem) {
    final extra = problem.extra;
    final reason = extra['reason'];
    final expected = extra['expected'];
    final actual = extra['actual'];
    if (problem.code != 'version_mismatch' || expected is! String || actual is! String) return null;
    if (reason != 'game_version' && reason != 'engine') return null;
    return JoinRefusal(
      engine: reason == 'engine',
      expected: expected,
      actual: actual,
      youUpdate: extra['update'] != 'host',
      overridable: extra['overridable'] as bool? ?? reason == 'game_version',
    );
  }

  final bool engine;
  final String expected;
  final String actual;
  final bool youUpdate;
  final bool overridable;
}

/// What a party member is offered: the host's game, its version and engine, and room left.
class PlayTogetherOffer {
  const PlayTogetherOffer({
    required this.sessionId,
    required this.hostId,
    required this.hostName,
    required this.titleId,
    required this.gameVersion,
    required this.engineBuild,
    required this.versionRule,
    required this.players,
    required this.capacity,
  });

  factory PlayTogetherOffer.fromSession(GameSession session) => PlayTogetherOffer(
    sessionId: session.id,
    hostId: session.host?.id ?? '',
    hostName: session.host?.displayName ?? '',
    titleId: session.titleId,
    gameVersion: session.gameVersion,
    engineBuild: session.engineBuild,
    versionRule: session.versionRule,
    players: session.players.length,
    capacity: session.capacity,
  );

  /// [name]: how a person is shown here (a friend's private name); their public name without it.
  factory PlayTogetherOffer.fromParty(
    PartyTogether together,
    List<Person> members, {
    String Function(Person person)? name,
  }) {
    final host = members.where((person) => person.id == together.hostId).firstOrNull;
    return PlayTogetherOffer(
      sessionId: together.sessionId,
      hostId: together.hostId,
      hostName: host == null ? '' : (name?.call(host) ?? host.displayName),
      titleId: together.titleId,
      gameVersion: together.gameVersion,
      engineBuild: together.engineBuild,
      versionRule: together.versionRule,
      players: together.players.length,
      capacity: together.capacity,
    );
  }

  final String sessionId;
  final String hostId;
  final String hostName;
  final String titleId;
  final String gameVersion;
  final String engineBuild;
  final String versionRule;
  final int players;
  final int capacity;

  PlayTogetherOffer copyWith({int? players, String? versionRule}) => PlayTogetherOffer(
    sessionId: sessionId,
    hostId: hostId,
    hostName: hostName,
    titleId: titleId,
    gameVersion: gameVersion,
    engineBuild: engineBuild,
    versionRule: versionRule ?? this.versionRule,
    players: players ?? this.players,
    capacity: capacity,
  );
}

/// A copy of a game in this computer's library, for the join check.
class TogetherCopy {
  const TogetherCopy({
    required this.id,
    required this.titleId,
    required this.gameVersion,
    required this.engineBuild,
    required this.unlocked,
    this.nextEngineBuild,
  });

  final String id;
  final String titleId;
  final String gameVersion;

  /// The engine build it was unlocked with (or would be, while locked).
  final String engineBuild;
  final bool unlocked;

  /// The engine build unlocking it again would give, when that differs.
  final String? nextEngineBuild;
}

/// What Join can do for an offer; each answer that is not a way in names what is missing.
sealed class PlayTogetherVerdict {
  const PlayTogetherVerdict();
}

/// Join with this copy (a game id).
final class JoinWith extends PlayTogetherVerdict {
  const JoinWith(this.gameId);
  final String gameId;
  @override
  bool operator ==(Object other) => other is JoinWith && other.gameId == gameId;
  @override
  int get hashCode => gameId.hashCode;
}

/// The copy is not unlocked yet: unlock it, then join.
final class UnlockAndPlay extends PlayTogetherVerdict {
  const UnlockAndPlay(this.gameId);
  final String gameId;
  @override
  bool operator ==(Object other) => other is UnlockAndPlay && other.gameId == gameId;
  @override
  int get hashCode => gameId.hashCode;
}

/// The copy was unlocked with an older engine and unlocking it again brings it to the host's.
final class UpdateAndPlay extends PlayTogetherVerdict {
  const UpdateAndPlay(this.gameId);
  final String gameId;
  @override
  bool operator ==(Object other) => other is UpdateAndPlay && other.gameId == gameId;
  @override
  int get hashCode => gameId.hashCode;
}

final class SignInFirst extends PlayTogetherVerdict {
  const SignInFirst();
  @override
  bool operator ==(Object other) => other is SignInFirst;
  @override
  int get hashCode => 1;
}

final class MissingGame extends PlayTogetherVerdict {
  const MissingGame(this.titleId);
  final String titleId;
  @override
  bool operator ==(Object other) => other is MissingGame && other.titleId == titleId;
  @override
  int get hashCode => titleId.hashCode;
}

/// No copy has a version that fits the host's; [youUpdate] when this side is behind.
final class OtherGameVersion extends PlayTogetherVerdict {
  const OtherGameVersion({required this.have, required this.need, required this.youUpdate});
  final String have;
  final String need;
  final bool youUpdate;
  @override
  bool operator ==(Object other) =>
      other is OtherGameVersion && other.have == have && other.need == need && other.youUpdate == youUpdate;
  @override
  int get hashCode => Object.hash(have, need, youUpdate);
}

final class OtherEngine extends PlayTogetherVerdict {
  const OtherEngine({required this.have, required this.need, required this.youUpdate});
  final String have;
  final String need;
  final bool youUpdate;
  @override
  bool operator ==(Object other) =>
      other is OtherEngine && other.have == have && other.need == need && other.youUpdate == youUpdate;
  @override
  int get hashCode => Object.hash(have, need, youUpdate);
}

final class CloseFirst extends PlayTogetherVerdict {
  const CloseFirst(this.running);
  final String running;
  @override
  bool operator ==(Object other) => other is CloseFirst && other.running == running;
  @override
  int get hashCode => running.hashCode;
}

final class SessionFull extends PlayTogetherVerdict {
  const SessionFull();
  @override
  bool operator ==(Object other) => other is SessionFull;
  @override
  int get hashCode => 2;
}

/// Versions compared by their numbers: 01.010 > 01.9, 0.2.21-4194 > 0.2.20-5000.
int compareVersions(String a, String b) {
  List<int> parts(String text) => RegExp(r'\d+').allMatches(text).map((m) => int.parse(m.group(0)!)).toList();
  final left = parts(a);
  final right = parts(b);
  for (var i = 0; i < (left.length > right.length ? left.length : right.length); i++) {
    final x = i < left.length ? left[i] : 0;
    final y = i < right.length ? right[i] : 0;
    if (x != y) return x < y ? -1 : 1;
  }
  return 0;
}

/// Whether a joiner's game version fits the host's under the host's rule: the same (exact), the
/// same first dot-separated part (major) or any.
bool versionFits(String rule, String host, String joiner) => switch (rule) {
  'any' => true,
  'major' => int.tryParse(host.split('.').first) == int.tryParse(joiner.split('.').first),
  _ => host == joiner,
};

class PlayTogetherCheck {
  /// Signed in, owned, version, engine, not busy, room, unlocked: the first that does not hold.
  /// [overrideVersion] (Try anyway) takes any copy's game version; the engine is still checked.
  static PlayTogetherVerdict verdict(
    PlayTogetherOffer offer, {
    required bool signedIn,
    required List<TogetherCopy> copies,
    String? running,
    bool overrideVersion = false,
  }) {
    if (!signedIn) return const SignInFirst();
    final owned = copies.where((copy) => copy.titleId == offer.titleId).toList();
    if (owned.isEmpty) return MissingGame(offer.titleId);
    final fitting = overrideVersion
        ? owned
        : owned.where((copy) => versionFits(offer.versionRule, offer.gameVersion, copy.gameVersion)).toList();
    if (fitting.isEmpty) {
      final have = owned.first.gameVersion;
      return OtherGameVersion(
        have: have,
        need: offer.gameVersion,
        youUpdate: compareVersions(have, offer.gameVersion) < 0,
      );
    }
    // The copy whose engine is the host's, else one that unlocking again brings there.
    final copy =
        fitting.where((copy) => copy.engineBuild == offer.engineBuild).firstOrNull ??
        fitting.where((copy) => copy.unlocked && copy.nextEngineBuild == offer.engineBuild).firstOrNull;
    if (copy == null) {
      // Who is behind is read from the releases (a nightly before its release), never from a
      // build's fingerprint.
      final have = fitting.first.engineBuild;
      return OtherEngine(
        have: have,
        need: offer.engineBuild,
        youUpdate: EngineAdvice.of(
          yours: have,
          host: offer.engineBuild,
          rebuildGives: fitting.first.nextEngineBuild,
        ).youUpdate,
      );
    }
    if (running != null) return CloseFirst(running);
    if (offer.players >= offer.capacity) return const SessionFull();
    if (!copy.unlocked) return UnlockAndPlay(copy.id);
    if (copy.engineBuild != offer.engineBuild) return UpdateAndPlay(copy.id);
    return JoinWith(copy.id);
  }

  /// Try anyway: when only the game version keeps this computer out, the way in that skipping the
  /// version check gives (join, or unlock or update first); null when the version fits or
  /// something else (the engine, a running game, no room) is in the way.
  static PlayTogetherVerdict? tryAnyway(
    PlayTogetherOffer offer, {
    required bool signedIn,
    required List<TogetherCopy> copies,
    String? running,
  }) {
    if (verdict(offer, signedIn: signedIn, copies: copies, running: running) is! OtherGameVersion) return null;
    final anyway = verdict(offer, signedIn: signedIn, copies: copies, running: running, overrideVersion: true);
    return anyway is JoinWith || anyway is UnlockAndPlay || anyway is UpdateAndPlay ? anyway : null;
  }
}
