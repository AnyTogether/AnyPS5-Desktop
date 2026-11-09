import 'dart:async';

import 'package:dbus/dbus.dart';

import 'wayland_capture.dart';

/// The desktop's ScreenCast portal over the session bus.
class DbusScreenCastPortal implements ScreenCastPortal {
  DbusScreenCastPortal({DBusClient Function()? client}) : _newClient = client ?? DBusClient.session;

  static const _bus = 'org.freedesktop.portal.Desktop';
  static const _interface = 'org.freedesktop.portal.ScreenCast';
  static final _path = DBusObjectPath('/org/freedesktop/portal/desktop');

  /// AvailableSourceTypes' bit for single windows.
  static const windowSource = 2;

  /// persist_mode: until the user takes it back.
  static const persistUntilRevoked = 2;

  /// The first portal version with restore tokens.
  static const restoreVersion = 4;

  final DBusClient Function() _newClient;
  DBusClient? _client;
  DBusObjectPath? _session;
  Completer<void>? _cancelled;
  int _tokens = 0;

  @override
  Future<PortalInfo?> probe() async {
    final DBusClient client;
    try {
      client = _newClient();
    } on Object {
      // No session bus to talk to.
      return null;
    }
    try {
      final object = DBusRemoteObject(client, name: _bus, path: _path);
      final version = await object.getProperty(_interface, 'version');
      final sources = await object.getProperty(_interface, 'AvailableSourceTypes');
      return PortalInfo(version: version.asUint32(), sharesWindows: sources.asUint32() & windowSource != 0);
    } on Object {
      return null;
    } finally {
      await client.close();
    }
  }

  @override
  Future<PortalGrant?> shareWindow({String? restoreToken}) async {
    await close();
    final info = await probe();
    if (info == null) return null;
    final cancelled = _cancelled = Completer<void>();
    final client = _client = _newClient();
    // Connects, and gives the unique name the request paths are made from.
    await client.ping();
    final object = DBusRemoteObject(client, name: _bus, path: _path);

    final created = await _request(client, cancelled, (handle) async {
      await object.callMethod(_interface, 'CreateSession', [
        DBusDict.stringVariant({
          'handle_token': DBusString(handle),
          'session_handle_token': DBusString('anyps5_session_${_nextToken()}'),
        }),
      ], replySignature: DBusSignature('o'));
    });
    if (created == null) return null;
    final session = _session = DBusObjectPath(created['session_handle']!.asString());

    final selected = await _request(client, cancelled, (handle) async {
      await object.callMethod(_interface, 'SelectSources', [
        session,
        DBusDict.stringVariant({
          'handle_token': DBusString(handle),
          'types': const DBusUint32(windowSource),
          'multiple': const DBusBoolean(false),
          if (info.version >= restoreVersion) 'persist_mode': const DBusUint32(persistUntilRevoked),
          if (info.version >= restoreVersion && restoreToken != null) 'restore_token': DBusString(restoreToken),
        }),
      ], replySignature: DBusSignature('o'));
    });
    if (selected == null) return null;

    final started = await _request(client, cancelled, (handle) async {
      await object.callMethod(_interface, 'Start', [
        session,
        const DBusString(''),
        DBusDict.stringVariant({'handle_token': DBusString(handle)}),
      ], replySignature: DBusSignature('o'));
    });
    if (started == null) return null;
    return grantFrom(started);
  }

  /// The grant in Start's results; null when no stream came.
  static PortalGrant? grantFrom(Map<String, DBusValue> results) {
    final streams = results['streams']?.asArray();
    if (streams == null || streams.isEmpty) return null;
    final stream = streams.first.asStruct();
    final properties = stream[1].asStringVariantDict();
    final size = properties['size']?.asStruct();
    return PortalGrant(
      node: stream[0].asUint32(),
      width: size?[0].asInt32(),
      height: size?[1].asInt32(),
      restoreToken: results['restore_token']?.asString(),
    );
  }

  /// One portal request: listens on its Request object first (the path is known ahead, so the
  /// answer cannot be missed), makes the call, and returns the results; null for anything but
  /// success, or when [close] came first.
  Future<Map<String, DBusValue>?> _request(
    DBusClient client,
    Completer<void> cancelled,
    Future<void> Function(String handle) call,
  ) async {
    final handle = 'anyps5_request_${_nextToken()}';
    final sender = client.uniqueName.substring(1).replaceAll('.', '_');
    final path = DBusObjectPath('/org/freedesktop/portal/desktop/request/$sender/$handle');
    final answer = Completer<Map<String, DBusValue>?>();
    final signals = DBusSignalStream(client, interface: 'org.freedesktop.portal.Request', name: 'Response', path: path);
    final listening = signals.listen((signal) {
      if (answer.isCompleted || signal.values.length < 2) return;
      answer.complete(signal.values[0].asUint32() == 0 ? signal.values[1].asStringVariantDict() : null);
    });
    try {
      await call(handle);
      return await Future.any([answer.future, cancelled.future.then((_) => null)]);
    } finally {
      await listening.cancel();
    }
  }

  int _nextToken() => ++_tokens;

  @override
  Future<void> close() async {
    final cancelled = _cancelled;
    _cancelled = null;
    if (cancelled != null && !cancelled.isCompleted) cancelled.complete();
    final client = _client;
    final session = _session;
    _client = null;
    _session = null;
    if (client == null) return;
    try {
      if (session != null) {
        await DBusRemoteObject(
          client,
          name: _bus,
          path: session,
        ).callMethod('org.freedesktop.portal.Session', 'Close', const [], replySignature: DBusSignature(''));
      }
    } on Object {
      // Already closed on its side.
    }
    try {
      await client.close();
    } on Object {
      // The connection went with the desktop.
    }
  }
}
