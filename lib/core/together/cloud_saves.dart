import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../save_backup.dart';
import '../save_sync.dart';
import 'account.dart';

int _int(Object? value) => switch (value) {
  final num number => number.toInt(),
  final String text => int.tryParse(text) ?? 0,
  _ => 0,
};

/// Whether the server keeps files (GET /storage, no sign-in needed).
class StorageInfo {
  const StorageInfo({
    required this.enabled,
    this.quota = 0,
    this.saveMax = 0,
    this.partSize = 0,
    this.media = const MediaLimits(),
    this.galleryMax = 12,
  });

  static const disabled = StorageInfo(enabled: false);

  factory StorageInfo.fromJson(Map<String, dynamic> json) => StorageInfo(
    enabled: json['enabled'] == true,
    quota: _int(json['quota']),
    saveMax: _int(json['saveMax']),
    partSize: _int(json['partSize']),
    media: json['media'] is Map<String, dynamic>
        ? MediaLimits.fromJson(json['media'] as Map<String, dynamic>)
        : const MediaLimits(),
    galleryMax: json.containsKey('galleryMax') ? _int(json['galleryMax']) : 12,
  );

  final bool enabled;
  final int quota;
  final int saveMax;
  final int partSize;

  /// What a picture, a clip and a clip's poster may be; the server's defaults when it does not say.
  final MediaLimits media;

  /// How many photos and clips a profile's gallery holds.
  final int galleryMax;
}

/// The media limits GET /storage gives (`mediaLimits` on the server).
class MediaLimits {
  const MediaLimits({
    this.image = 10 * 1024 * 1024,
    this.clip = 25 * 1024 * 1024,
    this.poster = 2 * 1024 * 1024,
    this.pixels = 40000000,
  });

  factory MediaLimits.fromJson(Map<String, dynamic> json) {
    int read(String key, int otherwise) => json.containsKey(key) && _int(json[key]) > 0 ? _int(json[key]) : otherwise;
    const standard = MediaLimits();
    return MediaLimits(
      image: read('image', standard.image),
      clip: read('clip', standard.clip),
      poster: read('poster', standard.poster),
      pixels: read('pixels', standard.pixels),
    );
  }

  final int image;
  final int clip;
  final int poster;
  final int pixels;
}

/// Bytes used, in all and by what; [limit] is the account's quota.
class StorageUsage {
  const StorageUsage({required this.used, required this.limit, required this.saves, required this.media});

  factory StorageUsage.fromJson(Map<String, dynamic> json) => StorageUsage(
    used: _int(json['used']),
    limit: _int(json['limit']),
    saves: _int(json['saves']),
    media: _int(json['media']),
  );

  final int used;
  final int limit;
  final int saves;
  final int media;

  double get fraction => limit > 0 ? math.min(1, used / limit) : 0;
  int get free => math.max(0, limit - used);
}

/// One kept archive of a save slot.
class SaveVersion {
  const SaveVersion({
    required this.id,
    required this.version,
    required this.size,
    required this.sha256,
    this.device,
    this.createdAt,
    this.download,
  });

  factory SaveVersion.fromJson(Map<String, dynamic> json) => SaveVersion(
    id: json['id'] as String,
    version: _int(json['version']),
    size: _int(json['size']),
    sha256: (json['sha256'] as String? ?? '').toLowerCase(),
    device: json['device'] as String?,
    createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
    download: json['download'] as String?,
  );

  static SaveVersion? maybe(Object? json) => json is Map<String, dynamic> ? SaveVersion.fromJson(json) : null;

  final String id;
  final int version;
  final int size;
  final String sha256;

  /// The computer (or Mac, or device) that uploaded it.
  final String? device;
  final DateTime? createdAt;

  /// A signed link to the archive that needs no token, good for an hour or two.
  final String? download;
}

/// A game's save slot in the cloud, its versions newest first (at most three).
class SaveSlot {
  const SaveSlot({required this.id, required this.titleId, required this.slot, required this.versions, this.game});

  factory SaveSlot.fromJson(Map<String, dynamic> json) => SaveSlot(
    id: json['id'] as String,
    titleId: json['titleId'] as String,
    game: json['game'] as String?,
    slot: json['slot'] as String? ?? '',
    versions: [
      for (final version in json['versions'] as List<dynamic>? ?? const [])
        if (version is Map<String, dynamic>) SaveVersion.fromJson(version),
    ],
  );

  final String id;
  final String titleId;

  /// The game's name when the server's catalogue knows it.
  final String? game;
  final String slot;
  final List<SaveVersion> versions;

  SaveVersion? get latest => versions.firstOrNull;

  /// Bytes its versions take (the same bytes twice are counted once by the server).
  int get size => {for (final version in versions) version.sha256: version.size}.values.fold(0, (a, b) => a + b);
}

/// The usage and every save slot (GET /me/storage).
class StorageOverview {
  const StorageOverview({required this.enabled, this.usage, this.saves = const [], this.media = const []});

  factory StorageOverview.fromJson(Map<String, dynamic> json) => StorageOverview(
    enabled: json['enabled'] as bool? ?? true,
    usage: json['usage'] is Map<String, dynamic> ? StorageUsage.fromJson(json['usage'] as Map<String, dynamic>) : null,
    saves: [
      for (final slot in json['saves'] as List<dynamic>? ?? const [])
        if (slot is Map<String, dynamic>) SaveSlot.fromJson(slot),
    ],
    media: [
      for (final item in json['media'] as List<dynamic>? ?? const [])
        if (item is Map<String, dynamic>) StoredMedia.fromJson(item),
    ],
  );

  final bool enabled;
  final StorageUsage? usage;
  final List<SaveSlot> saves;
  final List<StoredMedia> media;
}

/// A photo, clip or voice note on AnyTogether, as Cloud Storage lists them.
class StoredMedia {
  const StoredMedia({required this.id, required this.kind, this.size = 0, this.createdAt, this.gallery});

  factory StoredMedia.fromJson(Map<String, dynamic> json) => StoredMedia(
    id: json['id'] as String,
    kind: json['kind'] as String? ?? 'image',
    size: _int(json['size']),
    createdAt: json['createdAt'] is String ? DateTime.tryParse(json['createdAt'] as String) : null,
    gallery: json['gallery'] is num ? (json['gallery'] as num).toInt() : null,
  );

  final String id;

  /// "image", "clip" or "voice".
  final String kind;
  final int size;
  final DateTime? createdAt;

  /// Its place in the owner's gallery when pinned, null otherwise.
  final int? gallery;
}

/// What AnyTogether's problems say about storage.
extension StorageProblem on TogetherProblem {
  /// A 413 quota_exceeded: the cloud is full.
  bool get quotaExceeded => code == 'quota_exceeded';

  /// A 409 save_conflict: the cloud has a newer save than this computer's base (in [latest]).
  bool get saveConflict => code == 'save_conflict';

  /// The server keeps no files (503 storage_disabled).
  bool get storageDisabled => code == 'storage_disabled';
  bool get canReplace => extra['canReplace'] == true;
  SaveVersion? get latest => SaveVersion.maybe(extra['latest']);
  List<int>? get missing => (extra['missing'] as List<dynamic>?)?.map(_int).toList();
}

/// AnyTogether's storage calls (docs/cloud-storage.md in AnyTogether), on the signed-in account.
class CloudStorage {
  CloudStorage(this.account);

  final TogetherAccount account;
  final HttpClient _http = HttpClient()..connectionTimeout = const Duration(seconds: 15);

  /// Whether the server keeps files; needs no sign-in.
  Future<StorageInfo> info() async {
    final request = await _http.getUrl(_url('storage'));
    request.headers.set('AnyTogether-Client', account.clientName);
    final response = await request.close().timeout(const Duration(seconds: 20));
    final text = await utf8.decodeStream(response);
    if (response.statusCode == 503) return StorageInfo.disabled;
    if (response.statusCode != 200) throw TogetherProblem(response.statusCode, 'internal', 'storage');
    final json = jsonDecode(text);
    return json is Map<String, dynamic> ? StorageInfo.fromJson(json) : StorageInfo.disabled;
  }

  Future<StorageOverview> overview() async => StorageOverview.fromJson(await account.call('GET', 'me/storage'));

  /// Removes one photo, clip or voice note from the user's storage.
  Future<void> deleteMedia(String id) async {
    await account.call('DELETE', 'me/media/${Uri.encodeComponent(id)}');
  }

  /// The game's slots (GET /me/saves?titleId=).
  Future<List<SaveSlot>> slots(String titleId) async {
    final json = await account.call('GET', 'me/saves?titleId=${Uri.encodeQueryComponent(titleId)}');
    return [
      for (final slot in json['slots'] as List<dynamic>? ?? const [])
        if (slot is Map<String, dynamic>) SaveSlot.fromJson(slot),
    ];
  }

  Future<Map<String, dynamic>> beginUpload({
    required String titleId,
    required String slot,
    required int size,
    required String sha256,
    required String device,
    String? launcherVersion,
    required int baseVersion,
    bool replaceLatest = false,
  }) => account.call('POST', 'me/saves/uploads', {
    'titleId': titleId,
    'slot': slot,
    'size': size,
    'sha256': sha256,
    'device': device,
    'launcherVersion': ?launcherVersion,
    'baseVersion': baseVersion,
    if (replaceLatest) 'replaceLatest': true,
  });

  Future<Map<String, dynamic>> upload(String id) => account.call('GET', 'me/saves/uploads/$id');

  Future<void> sendPart(String id, int part, List<int> bytes) =>
      account.upload('PUT', 'me/saves/uploads/$id/parts/$part', bytes, 'application/octet-stream');

  Future<Map<String, dynamic>> complete(String id, {required int baseVersion, bool replaceLatest = false}) =>
      account.call('POST', 'me/saves/uploads/$id/complete', {
        'baseVersion': baseVersion,
        if (replaceLatest) 'replaceLatest': true,
      });

  Future<void> cancel(String id) async {
    try {
      await account.call('DELETE', 'me/saves/uploads/$id');
    } on Object {
      // It expires on its own after a day.
    }
  }

  Future<SaveVersion> restore(String versionId) async => SaveVersion.fromJson(
    (await account.call('POST', 'me/saves/versions/$versionId/restore'))['version'] as Map<String, dynamic>,
  );

  Future<void> deleteVersion(String versionId) => account.call('DELETE', 'me/saves/versions/$versionId');

  Future<void> deleteSlot(String slotId) => account.call('DELETE', 'me/saves/slots/$slotId');

  /// A version's archive into [file], going on from a part left by a broken download (Range).
  Future<void> download(String versionId, String file) async {
    Future<void> once(String token) async {
      final request = await _http.getUrl(_url('me/saves/versions/$versionId/download'));
      request.headers
        ..set('AnyTogether-Client', account.clientName)
        ..set(HttpHeaders.authorizationHeader, 'Bearer $token');
      final part = File(file);
      final have = part.existsSync() ? part.lengthSync() : 0;
      if (have > 0) request.headers.set(HttpHeaders.rangeHeader, 'bytes=$have-');
      final response = await request.close().timeout(const Duration(seconds: 60));
      if (response.statusCode == 416) {
        await response.drain<void>();
        return;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final text = await utf8.decodeStream(response);
        Object? json;
        try {
          json = jsonDecode(text);
        } on FormatException {
          json = null;
        }
        if (json is Map<String, dynamic> && json['code'] is String) {
          throw TogetherProblem(
            response.statusCode,
            json['code'] as String,
            json['title'] as String? ?? '',
            extra: json,
          );
        }
        throw TogetherProblem(response.statusCode, 'internal', 'AnyTogether answered ${response.statusCode}');
      }
      part.parent.createSync(recursive: true);
      final sink = part.openWrite(mode: response.statusCode == 206 ? FileMode.append : FileMode.write);
      try {
        await response.pipe(sink);
      } finally {
        await sink.close();
      }
    }

    try {
      await once(await account.accessToken());
    } on TogetherProblem catch (problem) {
      if (problem.status != 401) rethrow;
      await once(await account.accessToken(renew: true));
    }
  }

  Uri _url(String path) => Uri.parse('${account.base.toString().replaceAll(RegExp(r'/+$'), '')}/api/v1/$path');

  void close() => _http.close(force: true);
}

/// Both this computer and the cloud changed since they last agreed.
enum ConflictChoice { keepThisComputer, takeCloud, notNow }

/// What a cloud sync did.
sealed class CloudOutcome {
  const CloudOutcome();
}

class CloudUnchanged extends CloudOutcome {
  const CloudUnchanged();
}

class CloudUploaded extends CloudOutcome {
  const CloudUploaded(this.version);
  final int version;
}

/// The cloud's saves replaced this computer's (kept in Backups first).
class CloudDownloaded extends CloudOutcome {
  const CloudDownloaded(this.version, this.from);
  final int version;
  final String? from;
}

/// The player chose to leave it for now.
class CloudSkipped extends CloudOutcome {
  const CloudSkipped();
}

/// A game's saves and trophies kept in step through the user's AnyTogether cloud: the same zip
/// SaveBackup makes, as one save slot per game. Each computer remembers the cloud version it last
/// had and a digest of the saves then. A side that alone changed since is taken; where both did,
/// the player chooses. Uploads go in parts and pick up where they stopped; downloads too. The
/// macOS launcher's TogetherCloudSave, step for step, on the same slot.
class TogetherCloudSave {
  TogetherCloudSave({
    required this.storage,
    required this.game,
    required this.titleId,
    required this.backups,
    required this.workspace,
    required this.device,
    required this.conflict,
    required this.replaceLatest,
    this.launcherVersion,
  });

  /// The slot every game's saves go in: the whole of _sd, _sd_mem and _trophy.
  static const slot = 'AnyPS5 saves';

  final CloudStorage storage;

  /// The installed game folder (_sd, _sd_mem, _trophy).
  final String game;
  final String titleId;

  /// Where this computer's saves go before a download replaces them.
  final String backups;

  /// Where this computer keeps its record and the zips going up or down, per account.
  final String workspace;
  final String device;
  final String? launcherVersion;

  /// Asks the player: the cloud has [latest] from another device, and this computer its own
  /// changes.
  final Future<ConflictChoice> Function(SaveVersion? latest) conflict;

  /// Asks whether the slot's newest version may make way, when only that makes room.
  final Future<bool> Function(SaveVersion? latest) replaceLatest;

  /// This account's records: `<folder>/<user ID>`.
  static String workspaceFor(String folder, String userId) => p.join(folder, userId.replaceAll(RegExp(r'[/\\]'), '-'));

  String get stateFile => p.join(workspace, '$titleId.json');
  String get outgoing => p.join(workspace, '$titleId.zip');
  String incoming(int version) => p.join(workspace, '$titleId-v$version.zip.part');

  Future<CloudOutcome> sync({DateTime? date}) async {
    final when = date ?? DateTime.now();
    final local = SaveSync.digest(game);
    final state = loadState();
    final latest = await _latest();
    if (local == null && latest == null) return const CloudUnchanged();
    if (latest == null) return _upload(state, 0, when);
    if (local == null) return _download(latest, state, when);
    final localChanged = local != state.digest;
    final cloudChanged = latest.version != state.version;
    if (!localChanged && !cloudChanged) return const CloudUnchanged();
    if (localChanged && !cloudChanged) return _upload(state, latest.version, when);
    if (!localChanged && cloudChanged) return _download(latest, state, when);
    return _choose(latest, state, when);
  }

  /// Takes the cloud's newest saves now, whatever this computer has (backed up first): after the
  /// player restored an older version, say.
  Future<CloudOutcome> takeCloud({DateTime? date}) async {
    final latest = await _latest();
    if (latest == null) return const CloudUnchanged();
    return _download(latest, loadState(), date ?? DateTime.now());
  }

  Future<SaveVersion?> _latest() async =>
      (await storage.slots(titleId)).where((each) => each.slot == slot).firstOrNull?.latest;

  Future<CloudOutcome> _choose(SaveVersion? latest, CloudState state, DateTime date) async {
    switch (await conflict(latest)) {
      case ConflictChoice.keepThisComputer:
        return _upload(state, latest?.version ?? 0, date);
      case ConflictChoice.takeCloud:
        if (latest == null) return _upload(state, 0, date);
        return _download(latest, state, date);
      case ConflictChoice.notNow:
        return const CloudSkipped();
    }
  }

  // Upload.

  Future<CloudOutcome> _upload(CloudState state, int base, DateTime date) async {
    final digest = SaveSync.digest(game);
    if (digest == null) return const CloudUnchanged();
    var replace = false;
    Map<String, dynamic>? upload;
    // An upload of these very saves that stopped part way goes on.
    final pending = state.pending;
    if (pending != null && pending.digest == digest && File(outgoing).existsSync()) {
      try {
        final resumed = await storage.upload(pending.uploadId);
        if ((resumed['sha256'] as String? ?? '').toLowerCase() == pending.sha256) {
          upload = resumed;
          base = math.max(base, pending.baseVersion);
          replace = pending.replaceLatest;
        }
      } on Object {
        upload = null;
      }
    }
    if (upload == null) {
      if (state.pending case final CloudPending stale) {
        await storage.cancel(stale.uploadId);
        state = state.withPending(null);
        saveState(state);
      }
      _makeZip(date);
      final sha = await _sha256(outgoing);
      final size = File(outgoing).lengthSync();
      while (true) {
        try {
          upload = await storage.beginUpload(
            titleId: titleId,
            slot: slot,
            size: size,
            sha256: sha,
            device: device,
            launcherVersion: launcherVersion,
            baseVersion: base,
            replaceLatest: replace,
          );
          break;
        } on TogetherProblem catch (problem) {
          if (problem.saveConflict) {
            switch (await conflict(problem.latest)) {
              case ConflictChoice.keepThisComputer:
                base = problem.latest?.version ?? 0;
              case ConflictChoice.takeCloud:
                final latest = problem.latest;
                if (latest == null) {
                  base = 0;
                  continue;
                }
                return _download(latest, state, date);
              case ConflictChoice.notNow:
                return const CloudSkipped();
            }
          } else if (problem.quotaExceeded && problem.canReplace && !replace) {
            if (!await replaceLatest(problem.latest)) rethrow;
            replace = true;
          } else {
            rethrow;
          }
        }
      }
      state = state.withPending(
        CloudPending(
          uploadId: upload['uploadId'] as String,
          sha256: sha,
          size: size,
          digest: digest,
          baseVersion: base,
          replaceLatest: replace,
        ),
      );
      saveState(state);
    }
    final uploadId = upload['uploadId'] as String;
    await _sendParts(upload, null);
    while (true) {
      try {
        final done = await storage.complete(uploadId, baseVersion: base, replaceLatest: replace);
        final version = _int((done['version'] as Map<String, dynamic>?)?['version']);
        saveState(CloudState(version: version, digest: digest));
        _delete(outgoing);
        return done['unchanged'] == true ? const CloudUnchanged() : CloudUploaded(version);
      } on TogetherProblem catch (problem) {
        if (problem.code == 'conflict' && (problem.missing?.isNotEmpty ?? false)) {
          await _sendParts(upload, problem.missing);
        } else if (problem.saveConflict) {
          switch (await conflict(problem.latest)) {
            case ConflictChoice.keepThisComputer:
              // Completing again over the newer one keeps this upload; nothing goes twice.
              base = problem.latest?.version ?? 0;
              state = state.withPending(state.pending?.withBase(base));
              saveState(state);
            case ConflictChoice.takeCloud:
              await storage.cancel(uploadId);
              state = state.withPending(null);
              saveState(state);
              _delete(outgoing);
              final latest = problem.latest;
              if (latest == null) return const CloudSkipped();
              return _download(latest, state, date);
            case ConflictChoice.notNow:
              return const CloudSkipped();
          }
        } else if (problem.quotaExceeded && problem.canReplace && !replace) {
          if (!await replaceLatest(problem.latest)) rethrow;
          replace = true;
          state = state.withPending(state.pending?.withReplace());
          saveState(state);
        } else if (problem.code == 'checksum_mismatch' || problem.status == 404) {
          // The server dropped the upload: it starts again next time.
          state = state.withPending(null);
          saveState(state);
          rethrow;
        } else {
          rethrow;
        }
      }
    }
  }

  /// Sends the parts the server does not have ([missing], or all it has not received).
  Future<void> _sendParts(Map<String, dynamic> upload, List<int>? missing) async {
    final id = upload['uploadId'] as String;
    final partSize = math.max(1, _int(upload['partSize']));
    final parts = math.max(1, _int(upload['parts']));
    final received = {for (final part in upload['received'] as List<dynamic>? ?? const []) _int(part)};
    final wanted =
        missing ??
        [
          for (var part = 1; part <= parts; part++)
            if (!received.contains(part)) part,
        ];
    if (wanted.isEmpty) return;
    final file = await File(outgoing).open();
    try {
      for (final part in wanted) {
        await file.setPosition((part - 1) * partSize);
        final bytes = await file.read(partSize);
        for (var tries = 1; ; tries++) {
          try {
            await storage.sendPart(id, part, bytes);
            break;
          } on TogetherProblem catch (problem) {
            if (problem.code != 'checksum_mismatch' || tries >= 3) rethrow;
          } on IOException {
            if (tries >= 3) rethrow;
            await Future<void>.delayed(Duration(milliseconds: 300 * tries));
          }
        }
      }
    } finally {
      await file.close();
    }
  }

  void _makeZip(DateTime date) {
    Directory(workspace).createSync(recursive: true);
    final stage = Directory.systemTemp.createTempSync('AnyPS5-cloud-');
    try {
      final made = SaveBackup.backUp(game, stage.path, date);
      _delete(outgoing);
      try {
        File(made).renameSync(outgoing);
      } on FileSystemException {
        File(made).copySync(outgoing);
      }
    } finally {
      try {
        stage.deleteSync(recursive: true);
      } on FileSystemException {
        // The system clears it.
      }
    }
  }

  // Download.

  Future<CloudOutcome> _download(SaveVersion version, CloudState state, DateTime date) async {
    Directory(workspace).createSync(recursive: true);
    final file = incoming(version.version);
    await storage.download(version.id, file);
    if (await _sha256(file) != version.sha256.toLowerCase()) {
      _delete(file);
      throw const SaveSyncFailure('the cloud save arrived damaged; it will be fetched again');
    }
    try {
      SaveBackup.restore(file, game, backups, date);
    } finally {
      _delete(file);
    }
    if (state.pending case final CloudPending pending) await storage.cancel(pending.uploadId);
    saveState(CloudState(version: version.version, digest: SaveSync.digest(game)));
    _delete(outgoing);
    return CloudDownloaded(version.version, version.device);
  }

  // State.

  CloudState loadState() {
    try {
      final json = jsonDecode(File(stateFile).readAsStringSync());
      return json is Map<String, dynamic> ? CloudState.fromJson(json) : const CloudState();
    } on Object {
      return const CloudState();
    }
  }

  void saveState(CloudState state) {
    try {
      Directory(workspace).createSync(recursive: true);
      final temporary = File('$stateFile.tmp')..writeAsStringSync(jsonEncode(state.toJson()), flush: true);
      temporary.renameSync(stateFile);
    } on FileSystemException {
      // Asked again next time.
    }
  }

  /// The cloud version this computer last had, null when it never synced the game.
  int? get lastVersion => loadState().version;

  /// Forgets what this computer had of the game (its cloud slot was deleted).
  void forget() {
    _delete(stateFile);
    _delete(outgoing);
  }

  static void _delete(String path) {
    try {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    } on FileSystemException {
      // Left for the next time.
    }
  }

  static Future<String> _sha256(String path) async => (await sha256.bind(File(path).openRead()).first).toString();
}

/// What this computer last agreed with the cloud, and an upload under way: the Mac's record,
/// key for key.
class CloudState {
  const CloudState({this.version, this.digest, this.pending});

  factory CloudState.fromJson(Map<String, dynamic> json) => CloudState(
    version: (json['version'] as num?)?.toInt(),
    digest: json['digest'] as String?,
    pending: json['pending'] is Map<String, dynamic>
        ? CloudPending.fromJson(json['pending'] as Map<String, dynamic>)
        : null,
  );

  final int? version;
  final String? digest;
  final CloudPending? pending;

  CloudState withPending(CloudPending? next) => CloudState(version: version, digest: digest, pending: next);

  Map<String, Object?> toJson() => {
    'version': ?version,
    'digest': ?digest,
    if (pending != null) 'pending': pending!.toJson(),
  };
}

class CloudPending {
  const CloudPending({
    required this.uploadId,
    required this.sha256,
    required this.size,
    required this.digest,
    required this.baseVersion,
    required this.replaceLatest,
  });

  factory CloudPending.fromJson(Map<String, dynamic> json) => CloudPending(
    uploadId: json['uploadId'] as String,
    sha256: json['sha256'] as String,
    size: _int(json['size']),
    digest: json['digest'] as String,
    baseVersion: _int(json['baseVersion']),
    replaceLatest: json['replaceLatest'] == true,
  );

  final String uploadId;
  final String sha256;
  final int size;

  /// The saves' digest when the zip was made: a later change makes the zip stale.
  final String digest;
  final int baseVersion;
  final bool replaceLatest;

  CloudPending withBase(int base) => CloudPending(
    uploadId: uploadId,
    sha256: sha256,
    size: size,
    digest: digest,
    baseVersion: base,
    replaceLatest: replaceLatest,
  );

  CloudPending withReplace() => CloudPending(
    uploadId: uploadId,
    sha256: sha256,
    size: size,
    digest: digest,
    baseVersion: baseVersion,
    replaceLatest: true,
  );

  Map<String, Object?> toJson() => {
    'uploadId': uploadId,
    'sha256': sha256,
    'size': size,
    'digest': digest,
    'baseVersion': baseVersion,
    'replaceLatest': replaceLatest,
  };
}
