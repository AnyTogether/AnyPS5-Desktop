import '../update_channel.dart';
import 'game_sessions.dart';
import 'parties.dart';
import 'people.dart';
import 'play_together.dart';

/// Joining someone's game, said whole (JoinAdvice.swift on the Mac): when a copy is rebuilt
/// before it starts, what a different engine build asks of whom, what each party member plays
/// next to the user's own game, and whose game to offer when the user starts a title someone
/// they know already plays.

/// A copy of a game made by another engine than the one it starts with now.
class StaleCopy {
  /// [built]: the engine in the copy's install record (null: not unlocked). [current]: the
  /// engine the game is unlocked with now, the default or the game's own (null: none at hand).
  /// A copy made by another engine is rebuilt before it starts or joins a game.
  static bool needsRebuild({required String? built, required String? current}) =>
      built != null && current != null && built != current;
}

/// The release part of an engine build, without its fingerprint: "0.2.36-f75c475400e3" is
/// "0.2.36", "0.2.36-nightly.20261110.1-a6fff1ba742d" is "0.2.36-nightly.20261110.1".
String engineRelease(String build) {
  final parts = build.split('-');
  if (parts.length < 2 || !RegExp(r'^[0-9a-fA-F]{12}$').hasMatch(parts.last)) return build;
  return parts.sublist(0, parts.length - 1).join('-');
}

/// What gets a player past a host's different engine build.
enum EngineAdvice {
  /// The copy was made by an older engine and the engine at hand is the host's: rebuild it, then
  /// join.
  rebuild,

  /// The host's release is newer than the engine at hand: this side updates.
  updateYours,

  /// The host plays on a nightly build ahead of this release: the same update channel on both.
  hostNightly,

  /// This side is newer: the host updates and starts the game again.
  updateHost,

  /// The same release built differently (an engine of one's own, another download), or builds
  /// that say no release: the same engine on both.
  sameEngine;

  /// [yours]: the engine this copy was made with. [host]: the session's. [rebuildGives]: the
  /// engine unlocking the copy again would give, when that differs. The releases are compared as
  /// releases come out (a nightly before its release), never by a build's fingerprint.
  static EngineAdvice of({required String yours, required String host, String? rebuildGives}) {
    if (rebuildGives != null && rebuildGives == host && rebuildGives != yours) return EngineAdvice.rebuild;
    final mine = ReleaseVersion.parse(engineRelease(rebuildGives ?? yours));
    final theirs = ReleaseVersion.parse(engineRelease(host));
    if (mine == null || theirs == null || mine == theirs) return EngineAdvice.sameEngine;
    if (mine < theirs) return theirs.isNightly && !mine.isNightly ? EngineAdvice.hostNightly : EngineAdvice.updateYours;
    return EngineAdvice.updateHost;
  }

  /// Whether this side is the one behind.
  bool get youUpdate => this == EngineAdvice.updateYours || this == EngineAdvice.hostNightly;
}

/// What a party member plays, next to the user's own game.
sealed class MemberGame {
  const MemberGame();

  /// [mine]: the session the user is in, with its players. [together]: the party's Play
  /// Together game. [presence]: the member's game as a friend's presence says it; [friend]
  /// whether they are a friend at all (nothing is known of a stranger outside the party's game:
  /// null).
  static MemberGame? of(
    String userId, {
    required GameSession? mine,
    required PartyTogether? together,
    required PresenceGame? presence,
    required bool friend,
  }) {
    if (mine != null) {
      if (mine.players.any((player) => player.id == userId) || mine.host?.id == userId) return const InYourGame();
      if (together != null && together.sessionId == mine.id && together.players.contains(userId)) {
        return const InYourGame();
      }
      if (presence?.sessionId == mine.id) return const InYourGame();
    }
    if (together != null && together.players.contains(userId)) {
      return InOtherGame(
        sessionId: together.sessionId,
        titleId: together.titleId,
        hostId: together.hostId,
        joinable: together.players.length < together.capacity,
        together: true,
        sameTitle: mine?.titleId == together.titleId,
      );
    }
    if (presence != null) {
      return InOtherGame(
        sessionId: presence.sessionId,
        titleId: presence.titleId,
        hostId: presence.hostId ?? userId,
        joinable: presence.joinable && presence.players < presence.capacity,
        together: presence.together,
        sameTitle: mine?.titleId == presence.titleId,
      );
    }
    return friend ? const InNoGame() : null;
  }
}

/// In the session the user is in.
final class InYourGame extends MemberGame {
  const InYourGame();
  @override
  bool operator ==(Object other) => other is InYourGame;
  @override
  int get hashCode => 1;
}

/// In another session; [sameTitle] when it is the title the user plays in a session of their own.
final class InOtherGame extends MemberGame {
  const InOtherGame({
    required this.sessionId,
    required this.titleId,
    required this.hostId,
    required this.joinable,
    required this.together,
    required this.sameTitle,
  });
  final String sessionId;
  final String titleId;
  final String hostId;
  final bool joinable;
  final bool together;
  final bool sameTitle;
  @override
  bool operator ==(Object other) =>
      other is InOtherGame &&
      other.sessionId == sessionId &&
      other.titleId == titleId &&
      other.hostId == hostId &&
      other.joinable == joinable &&
      other.together == together &&
      other.sameTitle == sameTitle;
  @override
  int get hashCode => Object.hash(sessionId, titleId, hostId, joinable, together, sameTitle);
}

/// Known to play nothing others can join.
final class InNoGame extends MemberGame {
  const InNoGame();
  @override
  bool operator ==(Object other) => other is InNoGame;
  @override
  int get hashCode => 2;
}

/// A game someone the user knows already plays, offered when the user starts the same title:
/// join theirs, or start one of their own.
class JoinableGame {
  const JoinableGame({required this.sessionId, required this.titleId, required this.personId, required this.together});

  final String sessionId;
  final String titleId;

  /// Whose game it is to join: the host when they are known here, else the friend seen in it.
  final String personId;

  /// The party's Play Together game (joined as one), not a friend's own session.
  final bool together;

  /// The game to offer for [titleId]: the party's Play Together game first, then a party
  /// member's own session, then any friend's; only one with room that lets others in, never the
  /// session the user is in ([mine]) or hosts.
  static JoinableGame? find({
    required String titleId,
    required String me,
    required String? mine,
    required Party? party,
    required List<Friend> friends,
  }) {
    final together = party?.together;
    if (together != null &&
        together.titleId == titleId &&
        together.sessionId != mine &&
        together.hostId != me &&
        !together.players.contains(me) &&
        together.players.length < together.capacity) {
      return JoinableGame(sessionId: together.sessionId, titleId: titleId, personId: together.hostId, together: true);
    }
    final inParty = {for (final member in party?.members ?? const <Person>[]) member.id};
    final playing = [
      for (final friend in friends)
        if (friend.presence.game case final PresenceGame game
            when game.titleId == titleId &&
                game.joinable &&
                game.players < game.capacity &&
                game.sessionId != mine &&
                game.hostId != me &&
                friend.person.id != me)
          friend,
    ];
    final friend = playing.where((friend) => inParty.contains(friend.person.id)).firstOrNull ?? playing.firstOrNull;
    final game = friend?.presence.game;
    if (friend == null || game == null) return null;
    return JoinableGame(
      sessionId: game.sessionId,
      titleId: titleId,
      personId: friend.person.id,
      together: game.together,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is JoinableGame &&
      other.sessionId == sessionId &&
      other.titleId == titleId &&
      other.personId == personId &&
      other.together == together;
  @override
  int get hashCode => Object.hash(sessionId, titleId, personId, together);
}
