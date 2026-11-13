import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../now_playing.dart';
import 'account.dart';
import 'notifier.dart';

/// Something AnyTogether's gateway pushed: a friend's presence, a message, a party change, a call
/// peer's signal. [type] `live.ready` is the launcher's own, after every (re)connect, for the
/// lists to catch up with what they may have missed.
class TogetherEvent {
  const TogetherEvent(this.id, this.type, this.data);

  final String id;
  final String type;
  final Object? data;

  Map<String, dynamic> get json => data is Map<String, dynamic> ? data as Map<String, dynamic> : const {};
}

enum SocketStatus { offline, connecting, ready, signedOut }

/// What friends see this launcher doing.
sealed class OwnPresence {
  const OwnPresence();

  Map<String, Object?> get json;
}

class PresenceOnline extends OwnPresence {
  const PresenceOnline();

  @override
  Map<String, Object?> get json => {'state': 'online'};
}

class PresenceInGame extends OwnPresence {
  const PresenceInGame(this.titleId, this.since);

  final String titleId;
  final DateTime since;

  @override
  Map<String, Object?> get json => {'state': 'in_game', 'titleId': titleId, 'since': since.toUtc().toIso8601String()};
}

/// The launcher's socket to AnyTogether's realtime gateway (/rt): hello with the access token, a
/// heartbeat with the presence as often as the gateway asks (and at once when it changes), the
/// events handed on, what was missed picked up after a reconnect, and the end when the session is
/// signed out elsewhere.
class TogetherSocket with Notifier {
  TogetherSocket({
    required this.account,
    this.retryBase = const Duration(seconds: 1),
    this.retryMost = const Duration(seconds: 30),
    Random? random,
  }) : _random = random ?? Random();

  final TogetherAccount account;
  final Duration retryBase;
  final Duration retryMost;
  final Random _random;

  /// Close codes the gateway uses.
  static const unauthorized = 4001;
  static const signedOut = 4003;

  /// IDs the API gives events (UUIDv7), which a socket that comes back can resume after;
  /// presence and signals have others and are never replayed.
  static final _resumable = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[0-9a-f]{4}-[0-9a-f]{12}$',
    caseSensitive: false,
  );

  SocketStatus status = SocketStatus.offline;

  /// This device's session as the gateway and the calls name it.
  String? session;

  OwnPresence _presence = const PresenceOnline();
  OwnPresence get presence => _presence;

  final _events = StreamController<TogetherEvent>.broadcast();
  Stream<TogetherEvent> get events => _events.stream;

  WebSocket? _socket;
  Timer? _beat;
  Timer? _retry;
  bool _running = false;
  bool _renew = false;
  int _attempt = 0;
  int _generation = 0;
  String? _lastId;

  /// Where the gateway is: /rt on AnyTogether's own host.
  Uri get gateway => account.base.replace(scheme: account.base.scheme == 'http' ? 'ws' : 'wss', path: '/rt');

  void start() {
    if (_running) return;
    _running = true;
    _attempt = 0;
    unawaited(_connect());
  }

  void stop() {
    _running = false;
    _generation++;
    _retry?.cancel();
    _beat?.cancel();
    unawaited(_socket?.close(1000, 'signed out'));
    _socket = null;
    _lastId = null;
    session = null;
    _set(SocketStatus.offline);
  }

  /// What friends see: sent at once and with every heartbeat.
  set presence(OwnPresence next) {
    _presence = next;
    _heartbeat();
  }

  Listening? _listening;

  /// What friends see this user listening to (Settings › Behaviour › Show friends what I'm
  /// listening to): null while nothing plays or the setting is off.
  Listening? get listening => _listening;

  /// Sent at once when it changes, and with every heartbeat while there is one.
  set listening(Listening? next) {
    if (next == _listening) return;
    _listening = next;
    _heartbeat();
  }

  /// The heartbeat's presence: what the launcher does, and `listening` only while there is
  /// something to show (a gateway before it ignores the field).
  Map<String, Object?> get presenceFrame => {..._presence.json, 'listening': ?_listening?.json};

  /// Sends a frame while connected; false when it could not go.
  bool send(Map<String, dynamic> frame) {
    final socket = _socket;
    if (socket == null || status != SocketStatus.ready) return false;
    socket.add(jsonEncode(frame));
    return true;
  }

  void _heartbeat() => send({'op': 'heartbeat', 'presence': presenceFrame});

  List<String> _topics = const [];

  /// The public topics listened to (the looking-for-group board, the public lists).
  List<String> get watching => _topics;

  /// Listens to these public topics instead of the ones before (none stops); sent again after
  /// every reconnect. They only say "something changed": the list is read again.
  void watch(List<String> topics) {
    if (_listEquals(topics, _topics)) return;
    _topics = List.unmodifiable(topics);
    send({'op': 'watch', 'topics': _topics});
  }

  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var index = 0; index < a.length; index++) {
      if (a[index] != b[index]) return false;
    }
    return true;
  }

  void _set(SocketStatus next) {
    if (status == next) return;
    status = next;
    notifyListeners();
  }

  Future<void> _connect() async {
    if (!_running) return;
    final mine = ++_generation;
    _set(SocketStatus.connecting);
    final WebSocket socket;
    try {
      final token = await account.accessToken(renew: _renew);
      _renew = false;
      if (mine != _generation) return;
      socket = await WebSocket.connect(gateway.toString()).timeout(const Duration(seconds: 15));
      if (mine != _generation) {
        unawaited(socket.close(1000));
        return;
      }
      _socket = socket;
      socket.add(jsonEncode({'op': 'hello', 'token': token, 'client': account.clientName, 'resume': ?_lastId}));
    } on TogetherProblem catch (problem) {
      // Not signed in any more (the refresh was turned down): nothing to connect.
      if (problem.status == 401 && account.user == null) {
        _end();
        return;
      }
      _later();
      return;
    } on Object {
      _later();
      return;
    }
    socket.listen(
      (message) {
        if (message is String) _frame(message);
      },
      onDone: () => _closed(mine, socket.closeCode),
      onError: (Object _) {},
      cancelOnError: false,
    );
  }

  void _frame(String text) {
    final Object? frame;
    try {
      frame = jsonDecode(text);
    } on FormatException {
      return;
    }
    if (frame is! Map<String, dynamic>) return;
    switch (frame['op']) {
      case 'ready':
        _attempt = 0;
        session = frame['session'] as String?;
        final every = (frame['heartbeat'] as num?) ?? 25;
        _beat?.cancel();
        _beat = Timer.periodic(Duration(milliseconds: (every * 1000).round()), (_) => _heartbeat());
        _set(SocketStatus.ready);
        _heartbeat();
        if (_topics.isNotEmpty) send({'op': 'watch', 'topics': _topics});
        _events.add(const TogetherEvent('', 'live.ready', null));
      case 'event':
        final id = frame['id'] as String? ?? '';
        final type = frame['type'];
        if (type is! String) return;
        if (_resumable.hasMatch(id)) _lastId = id;
        _events.add(TogetherEvent(id, type, frame['data']));
    }
  }

  void _closed(int generation, int? code) {
    if (generation != _generation) return;
    _beat?.cancel();
    _socket = null;
    if (code == signedOut) {
      _end();
      unawaited(account.signedOutElsewhere());
      return;
    }
    // A token the gateway turned down (it ran out while asleep): a fresh one next time.
    if (code == unauthorized) _renew = true;
    _later();
  }

  void _end() {
    _running = false;
    _beat?.cancel();
    _retry?.cancel();
    session = null;
    _set(SocketStatus.signedOut);
  }

  /// 1, 2, 4 … 30 s, spread a little so a gateway restart is not met by everyone at once.
  void _later() {
    if (!_running) return;
    _set(SocketStatus.offline);
    final step = retryBase * pow(2, _attempt++).toDouble();
    final wait = (step > retryMost ? retryMost : step) * (0.8 + _random.nextDouble() * 0.4);
    _retry?.cancel();
    _retry = Timer(wait, () => unawaited(_connect()));
  }

  void dispose() {
    stop();
    unawaited(_events.close());
  }
}
