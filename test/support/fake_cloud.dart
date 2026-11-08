import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// A pretend AnyTogether cloud for saves on a local port: slots keeping three versions, uploads
/// in parts, the conflict hint, a quota and ranged downloads, as AnyTogether's
/// docs/cloud-storage.md describes them (the macOS launcher's FakeCloud). Any bearer token
/// passes.
class FakeCloud {
  FakeCloud._(this._server);

  static Future<FakeCloud> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final cloud = FakeCloud._(server);
    server.listen(cloud._handle);
    return cloud;
  }

  final HttpServer _server;

  /// The photos, clips and voice notes GET /me/storage lists (Cloud Storage's media rows).
  final List<Map<String, dynamic>> media = [];
  Uri get base => Uri.parse('http://127.0.0.1:${_server.port}');

  bool enabled = true;
  int quota = 100 * 1048576;
  int partSize = 1024;
  final slots = <FakeSlot>[];
  final uploads = <String, FakeUpload>{};
  final partsSent = <int>[];
  final dropOnce = <int>{};
  final beginBodies = <Map<String, dynamic>>[];
  final completeBodies = <Map<String, dynamic>>[];
  final ranges = <String>[];

  /// Runs just before an upload completes (another computer uploading meanwhile, say).
  void Function()? beforeComplete;
  var _ids = 0;

  String _id() => 'id${++_ids}';

  static String sha(List<int> data) => sha256.convert(data).toString();

  int get used {
    final seen = <String, int>{};
    for (final version in slots.expand((slot) => slot.versions)) {
      seen[version.sha] = version.data.length;
    }
    return seen.values.fold(0, (a, b) => a + b);
  }

  Map<String, Object?> get usage => {'used': used, 'limit': quota, 'saves': used, 'media': 0};

  Map<String, Object?> versionJson(FakeVersion version) => {
    'id': version.id,
    'version': version.number,
    'size': version.data.length,
    'sha256': version.sha,
    'device': version.device,
    'launcherVersion': null,
    'createdAt': version.created.toUtc().toIso8601String(),
    'download': '$base/api/v1/files/save/${version.id}/x.zip',
  };

  Map<String, Object?> slotJson(FakeSlot slot) => {
    'id': slot.id,
    'titleId': slot.titleId,
    'game': 'Orbit Runner',
    'slot': slot.slot,
    'updatedAt': DateTime.now().toUtc().toIso8601String(),
    'versions': [for (final version in slot.versions) versionJson(version)],
  };

  /// Another device's upload, straight in.
  FakeVersion put(
    List<int> data, {
    String titleId = 'PPSA01001',
    String slot = 'AnyPS5 saves',
    String device = 'Other PC',
  }) {
    var found = slots.where((each) => each.titleId == titleId && each.slot == slot).firstOrNull;
    if (found == null) {
      found = FakeSlot(_id(), titleId, slot);
      slots.add(found);
    }
    found.last++;
    final version = FakeVersion(_id(), found.last, Uint8List.fromList(data), device, DateTime.now());
    found.versions.insert(0, version);
    if (found.versions.length > 3) found.versions.removeRange(3, found.versions.length);
    return version;
  }

  (bool fits, bool byReplacing) _room(int size, FakeSlot? slot, String sha) {
    final versions = slot?.versions ?? const <FakeVersion>[];
    bool fits(List<FakeVersion> drop) {
      final keep = slots.expand((each) => each.versions).where((v) => !drop.any((d) => d.id == v.id)).toList();
      final kept = <String, int>{for (final v in keep) v.sha: v.data.length};
      final after = kept.values.fold(0, (a, b) => a + b);
      return after + (kept.containsKey(sha) ? 0 : size) <= quota;
    }

    var dropped = versions.skip(2).toList();
    if (fits(dropped)) return (true, false);
    if (versions.length > 1) dropped = versions.skip(1).toList();
    if (fits(dropped)) return (true, false);
    return (false, versions.isNotEmpty && fits([...dropped, versions.first]));
  }

  Future<void> _handle(HttpRequest request) async {
    final body = await request
        .fold<BytesBuilder>(BytesBuilder(), (builder, chunk) => builder..add(chunk))
        .then((b) => b.takeBytes());
    (int, Object?) problem(int status, String code, [Map<String, Object?> extra = const {}]) =>
        (status, {'type': 'x', 'title': code, 'status': status, 'code': code, ...extra});
    Map<String, dynamic> input() {
      try {
        final json = jsonDecode(utf8.decode(body));
        return json is Map<String, dynamic> ? json : {};
      } on Object {
        return {};
      }
    }

    final path = request.uri.path.replaceFirst('/api/v1/', '');
    final parts = path.split('/');
    final method = request.method;
    List<String>? route(String verb, String pattern) {
      final want = pattern.split('/');
      if (verb != method || want.length != parts.length) return null;
      final found = <String>[];
      for (var index = 0; index < want.length; index++) {
        if (want[index] == '*') {
          found.add(parts[index]);
        } else if (want[index] != parts[index]) {
          return null;
        }
      }
      return found;
    }

    (int, Object?) answer;
    if (route('GET', 'storage') != null) {
      answer = (
        200,
        enabled ? {'enabled': true, 'quota': quota, 'partSize': partSize, 'saveMax': 52428800} : {'enabled': false},
      );
    } else if (!enabled) {
      answer = problem(503, 'storage_disabled');
    } else if (route('GET', 'me/storage') != null) {
      answer = (
        200,
        {
          'enabled': true,
          'usage': usage,
          'saves': [for (final slot in slots) slotJson(slot)],
          'media': media,
        },
      );
    } else if (route('GET', 'me/saves') != null) {
      final title = request.uri.queryParameters['titleId'];
      answer = (
        200,
        {
          'usage': usage,
          'slots': [
            for (final slot in slots)
              if (title == null || slot.titleId == title) slotJson(slot),
          ],
        },
      );
    } else if (route('POST', 'me/saves/uploads') != null) {
      final json = input();
      beginBodies.add(json);
      final titleId = json['titleId'] as String;
      final name = json['slot'] as String;
      final slot = slots.where((each) => each.titleId == titleId && each.slot == name).firstOrNull;
      final base = json['baseVersion'] as int?;
      if (base != null && (slot?.versions.firstOrNull?.number ?? 0) != base) {
        answer = problem(409, 'save_conflict', {
          'latest': slot?.versions.firstOrNull == null ? null : versionJson(slot!.versions.first),
        });
      } else {
        final size = json['size'] as int;
        final sha = json['sha256'] as String;
        final replace = json['replaceLatest'] == true;
        final room = _room(size, slot, sha);
        if (!room.$1 && !(room.$2 && replace)) {
          answer = problem(413, 'quota_exceeded', {
            'used': used,
            'limit': quota,
            'needed': size,
            'canReplace': room.$2,
            'latest': room.$2 && slot != null ? versionJson(slot.versions.first) : null,
          });
        } else {
          final id = _id();
          final count = (size + partSize - 1) ~/ partSize;
          uploads[id] = FakeUpload(titleId, name, size, sha, count, json['device'] as String?);
          answer = (
            201,
            {'uploadId': id, 'size': size, 'sha256': sha, 'partSize': partSize, 'parts': count, 'received': []},
          );
        }
      }
    } else if (route('GET', 'me/saves/uploads/*') case [final id]) {
      final upload = uploads[id];
      answer = upload == null
          ? problem(404, 'not_found')
          : (
              200,
              {
                'uploadId': id,
                'size': upload.size,
                'sha256': upload.sha,
                'partSize': partSize,
                'parts': upload.parts,
                'received': upload.received.keys.toList()..sort(),
              },
            );
    } else if (route('PUT', 'me/saves/uploads/*/parts/*') case [final id, final number]) {
      final upload = uploads[id];
      final n = int.tryParse(number);
      if (upload == null || n == null) {
        answer = problem(404, 'not_found');
      } else {
        partsSent.add(n);
        if (dropOnce.remove(n)) {
          answer = problem(500, 'internal');
        } else {
          upload.received[n] = body;
          answer = (200, {'part': n, 'sha256': sha(body), 'received': upload.received.keys.toList()..sort()});
        }
      }
    } else if (route('DELETE', 'me/saves/uploads/*') case [final id]) {
      uploads.remove(id);
      answer = (204, null);
    } else if (route('POST', 'me/saves/uploads/*/complete') case [final id]) {
      final json = input();
      completeBodies.add(json);
      beforeComplete?.call();
      beforeComplete = null;
      final upload = uploads[id];
      if (upload == null) {
        answer = problem(404, 'not_found');
      } else {
        final missing = [
          for (var n = 1; n <= upload.parts; n++)
            if (!upload.received.containsKey(n)) n,
        ];
        final slot = slots.where((each) => each.titleId == upload.titleId && each.slot == upload.slot).firstOrNull;
        final base = json['baseVersion'] as int?;
        if (missing.isNotEmpty) {
          answer = problem(409, 'conflict', {'missing': missing});
        } else if (base != null && (slot?.versions.firstOrNull?.number ?? 0) != base) {
          answer = problem(409, 'save_conflict', {'latest': versionJson(slot!.versions.first)});
        } else {
          final data = [for (var n = 1; n <= upload.parts; n++) ...upload.received[n]!];
          if (sha(data) != upload.sha) {
            uploads.remove(id);
            answer = problem(400, 'checksum_mismatch');
          } else {
            if (json['replaceLatest'] == true && slot != null && slot.versions.isNotEmpty) slot.versions.removeAt(0);
            final version = put(data, titleId: upload.titleId, slot: upload.slot, device: upload.device ?? '');
            uploads.remove(id);
            final kept = slots.firstWhere((each) => each.titleId == upload.titleId && each.slot == upload.slot);
            answer = (201, {'save': slotJson(kept), 'version': versionJson(version), 'dropped': [], 'usage': usage});
          }
        }
      }
    } else if (route('GET', 'me/saves/versions/*/download') case [final id]) {
      final version = slots.expand((slot) => slot.versions).where((v) => v.id == id).firstOrNull;
      if (version == null) {
        answer = problem(404, 'not_found');
      } else {
        final range = request.headers.value(HttpHeaders.rangeHeader);
        if (range != null) ranges.add(range);
        final from = range == null ? 0 : int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
        request.response
          ..statusCode = range == null ? 200 : 206
          ..headers.contentType = ContentType.binary
          ..add(version.data.sublist(from));
        await request.response.close();
        return;
      }
    } else if (route('POST', 'me/saves/versions/*/restore') case [final id]) {
      final slot = slots.where((each) => each.versions.any((v) => v.id == id)).firstOrNull;
      if (slot == null) {
        answer = problem(404, 'not_found');
      } else {
        final old = slot.versions.firstWhere((v) => v.id == id);
        final version = put(old.data, titleId: slot.titleId, slot: slot.slot, device: old.device ?? '');
        answer = (200, {'save': slotJson(slot), 'version': versionJson(version), 'dropped': [], 'usage': usage});
      }
    } else if (route('DELETE', 'me/saves/versions/*') case [final id]) {
      for (final slot in slots) {
        slot.versions.removeWhere((v) => v.id == id);
      }
      slots.removeWhere((slot) => slot.versions.isEmpty);
      answer = (200, {'usage': usage});
    } else if (route('DELETE', 'me/media/*') case [final id]) {
      media.removeWhere((item) => item['id'] == id);
      answer = (200, {'usage': usage});
    } else if (route('DELETE', 'me/saves/slots/*') case [final id]) {
      slots.removeWhere((slot) => slot.id == id);
      answer = (200, {'usage': usage});
    } else {
      answer = problem(404, 'not_found');
    }
    request.response.statusCode = answer.$1;
    if (answer.$2 != null) {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(answer.$2));
    }
    await request.response.close();
  }

  Future<void> close() => _server.close(force: true);
}

class FakeSlot {
  FakeSlot(this.id, this.titleId, this.slot);
  final String id;
  final String titleId;
  final String slot;
  final versions = <FakeVersion>[];
  int last = 0;
}

class FakeVersion {
  FakeVersion(this.id, this.number, this.data, this.device, this.created);
  final String id;
  final int number;
  final Uint8List data;
  final String? device;
  final DateTime created;
  String get sha => FakeCloud.sha(data);
}

class FakeUpload {
  FakeUpload(this.titleId, this.slot, this.size, this.sha, this.parts, this.device);
  final String titleId;
  final String slot;
  final int size;
  final String sha;
  final int parts;
  final String? device;
  final received = <int, Uint8List>{};
}
