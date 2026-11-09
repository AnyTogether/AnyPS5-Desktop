import 'dart:async';

import 'account.dart';
import 'levels.dart';
import 'notifier.dart';
import 'people.dart';
import 'private_identity.dart';
import 'socket.dart';

/// The friends list: who they are and what they are doing, requests both ways, and adding
/// someone by handle. Presence and requests change live from the gateway; [onEvent] hears the
/// ones worth a message on screen.
class Friends with Notifier {
  Friends({required this.account, required this.socket}) {
    _events = socket.events.listen(_event);
  }

  final TogetherAccount account;
  final TogetherSocket socket;
  late final StreamSubscription<TogetherEvent> _events;

  /// A request came in (their card), or someone accepted ours.
  void Function(Person asked)? onRequest;
  void Function(Person accepted)? onAccepted;

  /// A friend went up a trophy level (the list has it already).
  void Function(Friend friend, LevelBadge level)? onLevelUp;

  List<Friend> friends = const [];
  List<Person> incoming = const [];
  List<Person> outgoing = const [];
  bool loaded = false;

  /// The friends' private names and pictures as this list last said, for the cards of other
  /// answers and of realtime events, which carry none.
  final IdentityBook identities = IdentityBook();

  int get online => friends.where((friend) => friend.presence.online).length;

  Future<void> refresh() async {
    final list = await account.call('GET', 'me/friends');
    final requests = await account.call('GET', 'me/friends/requests');
    friends = _sorted([
      for (final json in (list['friends'] as List<dynamic>? ?? const []))
        Friend(
          Person.fromJson(json as Map<String, dynamic>),
          Presence.fromJson(json['presence'] as Map<String, dynamic>?),
          level: LevelBadge.fromJson(json['level']),
        ),
    ]);
    identities.learn(friends);
    incoming = _people(requests['incoming']);
    outgoing = _people(requests['outgoing']);
    loaded = true;
    notifyListeners();
  }

  /// Asks someone by handle; true when it made friends at once (they had asked first).
  Future<bool> add(String handle) async {
    final answer = await account.call('POST', 'me/friends/requests', {'handle': clean(handle)});
    await refresh();
    return answer['state'] == 'accepted';
  }

  /// A handle as typed, without the @ and spaces.
  static String clean(String handle) => handle.trim().replaceFirst(RegExp('^@'), '');

  Future<void> answer(String userId, {required bool accept}) async {
    await account.call('POST', 'me/friends/requests/$userId/${accept ? 'accept' : 'decline'}');
    incoming = incoming.where((person) => person.id != userId).toList();
    notifyListeners();
    if (accept) await refresh();
  }

  Future<void> remove(String userId) async {
    await account.call('DELETE', 'me/friends/$userId');
    friends = friends.where((friend) => friend.person.id != userId).toList();
    identities.learn(friends);
    notifyListeners();
  }

  /// Takes back a request the user sent and they have not answered (the website's Cancel
  /// request): the same call as removing a friend.
  Future<void> withdraw(String userId) async {
    await account.call('DELETE', 'me/friends/$userId');
    outgoing = outgoing.where((person) => person.id != userId).toList();
    notifyListeners();
  }

  /// The friend with this id, if they are one.
  Friend? byId(String userId) => friends.where((friend) => friend.person.id == userId).firstOrNull;

  /// Signed out: nothing kept.
  void clear() {
    friends = const [];
    identities.learn(const []);
    incoming = const [];
    outgoing = const [];
    loaded = false;
    notifyListeners();
  }

  void _event(TogetherEvent event) {
    switch (event.type) {
      case 'live.ready':
        unawaited(refresh().catchError((Object _) {}));
      case 'friend.request':
        if (event.json['userId'] is String) onRequest?.call(Person.fromJson(event.json));
        unawaited(refresh().catchError((Object _) {}));
      case 'friend.accepted':
        if (event.json['userId'] is String) onAccepted?.call(Person.fromJson(event.json));
        unawaited(refresh().catchError((Object _) {}));
      case 'friend.removed':
        final gone = event.json['userId'];
        friends = friends.where((friend) => friend.person.id != gone).toList();
        identities.learn(friends);
        notifyListeners();
      case 'presence.updated':
        final userId = event.json['userId'];
        final known = friends.indexWhere((friend) => friend.person.id == userId);
        if (known < 0) return;
        final next = [...friends];
        next[known] = next[known].copyWith(presence: Presence.fromJson(event.json));
        friends = _sorted(next);
        notifyListeners();
      case 'level.up':
        // A friend went up a level (mine is the profile's).
        final known = friends.indexWhere((friend) => friend.person.id == event.json['userId']);
        final level = LevelBadge.fromJson(event.json);
        if (known < 0 || level == null) return;
        friends = [...friends]..[known] = friends[known].copyWith(level: level);
        notifyListeners();
        onLevelUp?.call(friends[known], level);
    }
  }

  static List<Person> _people(Object? list) => [
    for (final json in (list as List<dynamic>? ?? const [])) Person.fromJson(json as Map<String, dynamic>),
  ];

  /// Playing first, then online, away, offline; each by name, as the API sorts them.
  static List<Friend> _sorted(List<Friend> list) => list
    ..sort((a, b) {
      final state = a.presence.state.index.compareTo(b.presence.state.index);
      return state != 0 ? state : a.person.displayName.toLowerCase().compareTo(b.person.displayName.toLowerCase());
    });

  void dispose() => unawaited(_events.cancel());
}
