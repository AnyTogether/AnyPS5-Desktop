import 'dart:async';
import 'dart:typed_data';

import 'account.dart';
import 'e2ee.dart';
import 'e2ee_keys.dart';
import 'notifier.dart';

/// Someone's devices as the server listed them, each one checked (its ID is its key's and its
/// signature holds for that user; one that fails is left out): the active ones, which messages
/// are sealed for, and the removed ones, kept to verify their old messages.
class UserDevices {
  const UserDevices(this.userId, this.active, this.removed);

  final String userId;
  final List<PublicDevice> active;
  final List<PublicDevice> removed;

  List<PublicDevice> get all => [...active, ...removed];

  List<String> get activeIds => [for (final d in active) d.id]..sort();
}

/// What a direct conversation is: end-to-end encrypted ([on]); plain because the other person
/// has no device key yet and it never was encrypted ([off]); or encrypted with nobody on the
/// other side to read it now ([noDevice]: the composer says so and sends nothing).
enum EncryptionState { on, off, noDevice }

/// Whose devices changed since this device last looked.
enum DevicesChange { mine, theirs, both }

/// A direct conversation's encryption as the thread shows it.
class ConversationLock {
  const ConversationLock({
    required this.state,
    required this.mine,
    required this.theirs,
    this.safetyNumber,
    this.compared = false,
    this.notice,
  });

  final EncryptionState state;
  final UserDevices mine;
  final UserDevices theirs;

  /// 60 digits while both people have a device.
  final String? safetyNumber;

  /// The user marked this very safety number as compared.
  final bool compared;

  /// A devices-changed notice not dismissed yet.
  final DevicesChange? notice;
}

/// A sealed message could not be sent: this device can not seal it for anyone now (the other
/// person has no device key, or this device has none).
class E2eeUnavailable implements Exception {
  const E2eeUnavailable();
}

/// End-to-end encryption for direct messages (AnyTogether's docs/e2ee.md, "What every client
/// does"): this device's keys, made once and kept on it, registered for the session; the other
/// people's devices, checked; the lock state, safety number and devices-changed notice of each
/// direct conversation; sealing, opening and sealed media. A server without the routes (404)
/// means no encryption: [available] turns false and everything works as before.
class EndToEnd with Notifier {
  EndToEnd({required this.account, required this.keys, required this.notes, required this.deviceName});

  final TogetherAccount account;

  /// The secret store and the notes of the launcher profile signed in, asked at each sign-in.
  final E2eeKeyStore Function() keys;
  final E2eeNotesStore Function() notes;
  final String Function() deviceName;

  /// null until known; false on a server without end-to-end encryption.
  bool? available;

  /// This device's secrets while it is registered.
  DeviceSecrets? device;

  String? _user;
  Future<bool>? _starting;
  Map<String, dynamic> _notes = {};
  final Map<String, UserDevices> _devices = {};
  final Map<String, ConversationLock> _locks = {};
  final Map<String, Opened?> _opened = {};

  /// How long a cached opening is kept: plenty for a thread and the list.
  static const _openedKept = 2000;

  /// The lock of a direct conversation as last checked; null before, for a group, or on a
  /// server without encryption.
  ConversationLock? lockOf(String? conversationId) => _locks[conversationId];

  UserDevices? devicesOf(String userId) => _devices[userId];

  /// A lock shown as it is given, without the server: for previews and the screens' tests.
  void showLock(String conversationId, ConversationLock lock) {
    _locks[conversationId] = lock;
    notifyListeners();
  }

  /// Makes this device's keys once (per AnyTogether user), keeps them, and registers them for
  /// the session: GET /me/e2ee/device, then PUT when it is missing or other keys. True once
  /// registered; false when the server has no such routes. Asked again after a failure.
  Future<bool> start() {
    final user = account.user?.id;
    if (user == null) return Future.value(false);
    if (user != _user) {
      clear();
      _user = user;
    }
    if (available != null) return Future.value(available);
    return _starting ??= _register(user).whenComplete(() => _starting = null);
  }

  Future<bool> _register(String user) async {
    _notes = await notes().load(user);
    final store = keys();
    var secrets = await store.load(user);
    if (secrets == null) {
      secrets = await DeviceSecrets.generate();
      try {
        await store.save(user, secrets);
      } on Object {
        // Not kept: this run still reads and writes; the next one registers new keys.
      }
    }
    final mine = await publicDevice(secrets, user);
    Map<String, dynamic>? current;
    try {
      final json = await account.call('GET', 'me/e2ee/device');
      current = json['device'] is Map<String, dynamic> ? json['device'] as Map<String, dynamic> : json;
    } on TogetherProblem catch (problem) {
      // No device for this session yet, or no such route: the PUT tells which.
      if (problem.status != 404) rethrow;
    }
    if (_user != user) return false;
    // Registered again when the name changed too: older launchers sent the computer's own name.
    final name = deviceName();
    if (current == null || current['id'] != mine.id || current['boxKey'] != mine.boxKey || current['name'] != name) {
      try {
        await account.call('PUT', 'me/e2ee/device', mine.toRegister(name));
      } on TogetherProblem catch (problem) {
        if (problem.status == 404 || problem.status == 405 || problem.status == 501) {
          if (_user == user) {
            available = false;
            notifyListeners();
          }
          return false;
        }
        rethrow;
      }
    }
    if (_user != user) return false;
    device = secrets;
    available = true;
    notifyListeners();
    return true;
  }

  /// Signed out, or another account: nothing of the last one stays in memory.
  void clear() {
    _user = null;
    available = null;
    device = null;
    _starting = null;
    _notes = {};
    _devices.clear();
    _locks.clear();
    _opened.clear();
    notifyListeners();
  }

  /// [users]' devices, from the server when [fresh] or not fetched yet (20 at a time, as the
  /// server answers), each one checked.
  Future<void> fetch(Iterable<String> users, {bool fresh = false}) async {
    final wanted = {
      for (final user in users)
        if (fresh || !_devices.containsKey(user)) user,
    }.toList();
    for (var at = 0; at < wanted.length; at += 20) {
      final part = wanted.sublist(at, at + 20 > wanted.length ? wanted.length : at + 20);
      final json = await account.call('GET', 'e2ee/devices?users=${part.map(Uri.encodeQueryComponent).join(',')}');
      final answered = <String>{};
      for (final entry in (json['users'] as List<dynamic>? ?? const [])) {
        if (entry is! Map<String, dynamic> || entry['userId'] is! String) continue;
        final userId = entry['userId'] as String;
        answered.add(userId);
        Future<List<PublicDevice>> checked(Object? list, {required bool removed}) async => [
          for (final item in (list is List<dynamic> ? list : const []))
            if (PublicDevice.fromJson(item) case final PublicDevice d when await verifyDevice(userId, d))
              PublicDevice(id: d.id, signKey: d.signKey, boxKey: d.boxKey, sig: d.sig, name: d.name, removed: removed),
        ];
        _devices[userId] = UserDevices(
          userId,
          await checked(entry['devices'], removed: false),
          await checked(entry['removed'], removed: true),
        );
      }
      // Someone the server left out has no device this user may know of.
      for (final user in part) {
        if (!answered.contains(user)) _devices[user] = UserDevices(user, const [], const []);
      }
    }
  }

  Map<String, dynamic> _noteOf(String conversationId) =>
      ((_notes['conversations'] ??= <String, dynamic>{}) as Map<String, dynamic>).putIfAbsent(
        conversationId,
        () => <String, dynamic>{},
      ) as Map<String, dynamic>;

  Future<void> _saveNotes() async {
    final user = _user;
    if (user == null) return;
    try {
      await notes().save(user, _notes);
    } on Object {
      // Remembered for this run.
    }
  }

  /// Whether this device ever saw [conversationId] encrypted: it never sends plain text there.
  bool sawEncrypted(String conversationId) => _noteOf(conversationId)['encrypted'] == true;

  void markEncrypted(String conversationId) {
    final note = _noteOf(conversationId);
    if (note['encrypted'] == true) return;
    note['encrypted'] = true;
    unawaited(_saveNotes());
  }

  /// Works out a direct conversation's lock with [other] (fetching the devices first when
  /// [fresh] or not known), remembers the devices it saw and raises the devices-changed notice
  /// when they differ from the last time (the first time it only remembers). Null on a server
  /// without encryption, unless this device saw the conversation encrypted: then it throws, so
  /// nothing goes out in plain text.
  Future<ConversationLock?> check({
    required String conversationId,
    required String other,
    bool encrypted = false,
    bool fresh = false,
  }) async {
    final ready = await start();
    final me = _user;
    if (encrypted && me != null) markEncrypted(conversationId);
    if (!ready || me == null) {
      if (available == false && !sawEncrypted(conversationId)) {
        _locks.remove(conversationId);
        return null;
      }
      throw const E2eeUnavailable();
    }
    await fetch([me, other], fresh: fresh);
    final mine = _devices[me] ?? UserDevices(me, const [], const []);
    final theirs = _devices[other] ?? UserDevices(other, const [], const []);
    final note = _noteOf(conversationId);
    final both = mine.active.isNotEmpty && theirs.active.isNotEmpty;
    final state = both
        ? EncryptionState.on
        : sawEncrypted(conversationId)
        ? EncryptionState.noDevice
        : EncryptionState.off;
    String? number;
    if (both) {
      markEncrypted(conversationId);
      number = await safetyNumber(
        me,
        [for (final d in mine.active) d.signKey],
        other,
        [for (final d in theirs.active) d.signKey],
      );
      final seenMine = (note['mine'] as List<dynamic>?)?.cast<String>();
      final seenTheirs = (note['theirs'] as List<dynamic>?)?.cast<String>();
      if (seenMine != null && seenTheirs != null) {
        final mineChanged = !_same(seenMine, mine.activeIds);
        final theirsChanged = !_same(seenTheirs, theirs.activeIds);
        if (mineChanged || theirsChanged) {
          final before = DevicesChange.values.asNameMap()[note['notice']];
          final mineNow = mineChanged || before == DevicesChange.mine || before == DevicesChange.both;
          final theirsNow = theirsChanged || before == DevicesChange.theirs || before == DevicesChange.both;
          note['notice'] =
              (mineNow && theirsNow
                      ? DevicesChange.both
                      : mineNow
                      ? DevicesChange.mine
                      : DevicesChange.theirs)
                  .name;
        }
      }
      note['mine'] = mine.activeIds;
      note['theirs'] = theirs.activeIds;
      unawaited(_saveNotes());
    }
    final lock = ConversationLock(
      state: state,
      mine: mine,
      theirs: theirs,
      safetyNumber: number,
      compared: number != null && note['compared'] == number,
      notice: both ? DevicesChange.values.asNameMap()[note['notice']] : null,
    );
    _locks[conversationId] = lock;
    notifyListeners();
    return lock;
  }

  static bool _same(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    final sorted = [...a]..sort();
    for (var i = 0; i < sorted.length; i++) {
      if (sorted[i] != b[i]) return false;
    }
    return true;
  }

  /// "We compared them": this safety number is marked, and a devices-changed notice goes with it.
  void markCompared(String conversationId) {
    final lock = _locks[conversationId];
    if (lock?.safetyNumber == null) return;
    final note = _noteOf(conversationId)
      ..['compared'] = lock!.safetyNumber
      ..remove('notice');
    _locks[conversationId] = ConversationLock(
      state: lock.state,
      mine: lock.mine,
      theirs: lock.theirs,
      safetyNumber: lock.safetyNumber,
      compared: note['compared'] == lock.safetyNumber,
    );
    unawaited(_saveNotes());
    notifyListeners();
  }

  /// The devices-changed notice dismissed (OK).
  void dismissNotice(String conversationId) {
    final lock = _locks[conversationId];
    _noteOf(conversationId).remove('notice');
    if (lock != null) {
      _locks[conversationId] = ConversationLock(
        state: lock.state,
        mine: lock.mine,
        theirs: lock.theirs,
        safetyNumber: lock.safetyNumber,
        compared: lock.compared,
      );
    }
    unawaited(_saveNotes());
    notifyListeners();
  }

  /// Someone's devices changed (the gateway's e2ee.devices): fetched again when they are known.
  Future<void> devicesChanged(String userId) async {
    if (available != true) return;
    if (_devices.containsKey(userId) || userId == _user) await fetch([userId], fresh: true);
  }

  /// Seals [payload] as message [messageId] for every active device of the user and [other].
  Future<Sealed> sealFor({
    required String conversationId,
    required String messageId,
    required String other,
    required E2eePayload payload,
  }) async {
    final me = _user;
    final secrets = device;
    final mine = me == null ? null : _devices[me];
    final theirs = _devices[other];
    if (me == null || secrets == null || mine == null || theirs == null || theirs.active.isEmpty) {
      throw const E2eeUnavailable();
    }
    final sealed = await seal(
      conversationId: conversationId,
      messageId: messageId,
      senderUserId: me,
      sender: secrets,
      recipients: [...mine.active, ...theirs.active],
      payload: payload,
    );
    _keep('$messageId:${sealed.sealed.sig}', Opened(payload, sealed.contentKey));
    return sealed;
  }

  void _keep(String key, Opened? opened) {
    if (_opened.length >= _openedKept) _opened.remove(_opened.keys.first);
    _opened[key] = opened;
  }

  /// A sealed message opened on this device: what it says and its content key. Throws no_key
  /// when it was sent before this device was added, bad_message for anything else wrong.
  Future<Opened> openMessage({
    required SealedMessage sealed,
    required String conversationId,
    required String messageId,
    required String authorId,
  }) async {
    final cacheKey = '$messageId:${sealed.sig}';
    if (_opened.containsKey(cacheKey)) {
      final known = _opened[cacheKey];
      if (known == null) throw const E2eeError('bad_message');
      return known;
    }
    if (!await start()) throw const E2eeError('bad_message');
    final me = device!;
    // A key for this device first: none means it was sent before the device was added.
    if (!sealed.keys.containsKey(me.deviceId)) throw const E2eeError('no_key');
    await fetch([authorId]);
    // A device the list does not have yet: the list again, once.
    if (!(_devices[authorId]?.all.any((d) => d.id == sealed.device) ?? false)) {
      await fetch([authorId], fresh: true);
    }
    try {
      final opened = await open(
        sealed,
        conversationId: conversationId,
        messageId: messageId,
        authorId: authorId,
        me: me,
        authorDevices: _devices[authorId]?.all ?? const [],
      );
      _keep(cacheKey, opened);
      return opened;
    } on E2eeError {
      _keep(cacheKey, null);
      throw const E2eeError('bad_message');
    }
  }

  /// The content key of a message this device opened, for a report.
  Uint8List? contentKeyOf(String messageId, SealedMessage sealed) => _opened['$messageId:${sealed.sig}']?.contentKey;

  // Sealed media.

  /// Encrypts a file (a photo already re-encoded, a clip, a voice note) and uploads it with
  /// POST /me/media/sealed, a clip's poster sealed the same way with PUT /me/media/:id/poster:
  /// what the payload carries to open and show it.
  Future<SealedAttachment> uploadSealed({
    required Uint8List file,
    required String kind,
    required String type,
    int? width,
    int? height,
    int? durationMs,
    Uint8List? poster,
    String posterType = 'image/png',
  }) async {
    if (!SealedAttachment.kinds.contains(kind)) throw ArgumentError.value(kind, 'kind');
    final sealedFile = await sealFile(file, FilePart.file);
    final media = await account.upload(
      'POST',
      'me/media/sealed?kind=$kind',
      sealedFile.ciphertext,
      'application/octet-stream',
    );
    // {media: MediaView, usage}, as the server answers an upload.
    final view = media['media'] is Map<String, dynamic> ? media['media'] as Map<String, dynamic> : media;
    final id = view['id'];
    if (id is! String) throw const TogetherProblem(500, 'internal', 'No media ID came back');
    SealedPoster? still;
    if (poster != null) {
      final sealedPoster = await sealFile(poster, FilePart.poster);
      await account.upload('PUT', 'me/media/$id/poster', sealedPoster.ciphertext, 'application/octet-stream');
      still = SealedPoster(key: sealedPoster.key, nonce: sealedPoster.nonce, type: posterType);
    }
    return SealedAttachment(
      mediaId: id,
      kind: kind,
      type: type,
      size: file.length,
      key: sealedFile.key,
      nonce: sealedFile.nonce,
      width: width,
      height: height,
      durationMs: durationMs,
      poster: still,
    );
  }

  /// The most a sealed file may be, by kind (the server's limits plus the 16-byte tag).
  static int limitOf(String kind, {bool poster = false}) =>
      (poster
              ? 2
              : switch (kind) {
                  'image' => 10,
                  'clip' => 25,
                  _ => 1,
                }) *
          1024 *
          1024 +
      16;

  /// A sealed attachment (or its poster) downloaded from its signed [link] and opened in memory.
  Future<Uint8List> download(String link, SealedAttachment attachment, {bool poster = false}) async {
    final still = attachment.poster;
    if (poster && still == null) throw const E2eeError('bad_message');
    final bytes = await account.fetchBytes(link, limit: limitOf(attachment.kind, poster: poster));
    return poster
        ? openFile(bytes, FilePart.poster, still!.key, still.nonce)
        : openFile(bytes, FilePart.file, attachment.key, attachment.nonce);
  }
}
