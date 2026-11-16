import 'dart:async';

import '../../core/retro_host/retro_host_session.dart';

/// Keeps the emulator host of the last game running while the player may start another, so the
/// next game starts on it instead of on a new host. protocol.md "Processes": "One host runs games
/// one after another until the launcher exits or the host fails."
///
/// It holds at most one host, with no game loaded ([RetroHostGame.detach] made sure). That host is
/// shut down after [idleLimit] without a game, when [shutdown] is asked (the player left the
/// emulator games), or when another host is kept. A host that ends while kept (it crashed, or it
/// exited after `release`, as protocol.md "release" allows) is forgotten, so the next game starts a
/// new one.
class RetroHostKeeper {
  RetroHostKeeper({this.idleLimit = const Duration(minutes: 5)});

  /// How long a host with no game is kept.
  Duration idleLimit;

  RetroHostSession? _session;
  String? _program;
  Timer? _idle;
  final _closing = <Future<void>>[];

  /// Whether a host is kept now.
  bool get holding => _session != null;

  /// Keeps [session], the host started from [program], for the next game; a host kept before is
  /// shut down.
  void keep(RetroHostSession session, {required String program}) {
    if (identical(session, _session)) return;
    _shutdownKept();
    _session = session;
    _program = program;
    _idle = Timer(idleLimit, _shutdownKept);
    unawaited(
      session.ended.then((_) {
        if (!identical(_session, session)) return;
        _forget();
        _track(session.close());
      }),
    );
  }

  /// The kept host, for a game starting now, when it was started from [program]; it is no longer
  /// kept. Null when none is, or the kept one runs another program, which is then shut down.
  RetroHostSession? take({required String program}) {
    final session = _session;
    if (session == null) return null;
    if (_program != program) {
      _shutdownKept();
      return null;
    }
    _forget();
    return session;
  }

  /// Shuts the kept host down, if one is, and waits for every host this keeper shut down to end.
  Future<void> shutdown() async {
    _shutdownKept();
    await Future.wait(List.of(_closing));
  }

  void _shutdownKept() {
    final session = _session;
    if (session == null) return;
    _forget();
    _track(_close(session));
  }

  void _track(Future<void> closing) {
    _closing.add(closing);
    unawaited(closing.whenComplete(() => _closing.remove(closing)));
  }

  static Future<void> _close(RetroHostSession session) async {
    session.shutdown();
    await session.ended;
    await session.close();
  }

  void _forget() {
    _idle?.cancel();
    _idle = null;
    _session = null;
    _program = null;
  }
}
