import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';

/// A release the fake GitHub serves: its files by name.
class FakeRelease {
  FakeRelease(this.tag, this.files, {this.digests = true, this.prerelease = false, this.draft = false});

  final String tag;
  final Map<String, List<int>> files;

  /// Whether the API lists a sha256 digest for each file (GitHub does for newer uploads).
  bool digests;
  final bool prerelease;
  final bool draft;

  /// Digests the API reports instead of the real ones, by file name.
  final Map<String, String> wrongDigests = {};

  /// When each file was uploaded (updated_at), by file name; the others at the release's time.
  final Map<String, String> uploaded = {};
}

/// GitHub's releases API and download servers on loopback, as the launcher uses them:
///
/// - `GET /api/repos/<repo>/releases/latest`, `/api/repos/<repo>/releases` and
///   `/api/repos/<repo>/releases/tags/<tag>`
/// - `GET /download/<tag>/<name>`, a redirect to `/blob/<tag>/<name>` (GitHub sends release
///   downloads on to another host), which honours `Range: bytes=N-`.
class FakeGitHub {
  FakeGitHub._(this._server, this.repository) {
    _server.listen(_handle);
  }

  static Future<FakeGitHub> start({String repository = 'boykopovar/AnyPS5'}) async =>
      FakeGitHub._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0), repository);

  final HttpServer _server;
  final String repository;
  final List<FakeRelease> releases = [];

  /// Every request: its path and its Range header.
  final List<(String, String?)> requests = [];

  /// The next download of a file sends only this many bytes, then the connection drops.
  final Map<String, int> dropAfter = {};

  /// Downloads stop after this many bytes and wait until [release] is called.
  final Map<String, int> holdAfter = {};
  final List<void Function()> _held = [];

  /// Answers every download with the whole file, ignoring Range.
  bool ignoreRange = false;

  /// The API answers with this status instead of the releases.
  int? apiStatus;

  Uri get api => Uri.parse('http://127.0.0.1:${_server.port}/api');
  Uri get base => Uri.parse('http://127.0.0.1:${_server.port}');

  /// Lets downloads waiting in [holdAfter] carry on.
  void release() {
    holdAfter.clear();
    for (final resume in List.of(_held)) {
      resume();
    }
    _held.clear();
  }

  Future<void> close() => _server.close(force: true);

  List<String> get downloads =>
      requests.where((request) => request.$1.startsWith('/blob/')).map((request) => request.$1).toList();

  Map<String, Object?> _json(FakeRelease release) => {
    'tag_name': release.tag,
    'name': release.tag,
    'draft': release.draft,
    'prerelease': release.prerelease,
    'published_at': '2026-10-20T09:31:13Z',
    'assets': [
      for (final entry in release.files.entries)
        {
          'name': entry.key,
          'size': entry.value.length,
          'browser_download_url': '$base/download/${release.tag}/${entry.key}',
          'content_type': 'application/octet-stream',
          'updated_at': release.uploaded[entry.key] ?? '2026-10-20T09:31:13Z',
          if (release.digests)
            'digest': 'sha256:${release.wrongDigests[entry.key] ?? sha256.convert(entry.value).toString()}',
        },
    ],
  };

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    requests.add((path, request.headers.value(HttpHeaders.rangeHeader)));
    final response = request.response;
    final apiPrefix = '/api/repos/$repository/releases';
    if (path.startsWith(apiPrefix)) {
      if (apiStatus case final int status) {
        response.statusCode = status;
        response.write('{"message":"API rate limit exceeded"}');
        return response.close();
      }
      response.headers.contentType = ContentType.json;
      if (path == '$apiPrefix/latest') {
        final latest = releases.where((release) => !release.prerelease && !release.draft).firstOrNull;
        if (latest == null) {
          response.statusCode = HttpStatus.notFound;
          return response.close();
        }
        response.write(jsonEncode(_json(latest)));
      } else if (path.startsWith('$apiPrefix/tags/')) {
        final tag = path.substring('$apiPrefix/tags/'.length);
        final found = releases.where((release) => release.tag == tag && !release.draft).firstOrNull;
        if (found == null) {
          response.statusCode = HttpStatus.notFound;
          return response.close();
        }
        response.write(jsonEncode(_json(found)));
      } else {
        response.write(jsonEncode([for (final release in releases) _json(release)]));
      }
      return response.close();
    }
    final parts = path.split('/');
    if (parts.length == 4 && parts[1] == 'download') {
      response
        ..statusCode = HttpStatus.found
        ..headers.set(HttpHeaders.locationHeader, '$base/blob/${parts[2]}/${parts[3]}');
      return response.close();
    }
    if (parts.length == 4 && parts[1] == 'blob') {
      final release = releases.where((release) => release.tag == parts[2]).firstOrNull;
      final bytes = release?.files[parts[3]];
      if (bytes == null) {
        response.statusCode = HttpStatus.notFound;
        return response.close();
      }
      final name = parts[3];
      var start = 0;
      final range = RegExp(r'^bytes=(\d+)-$').firstMatch(request.headers.value(HttpHeaders.rangeHeader) ?? '');
      if (range != null && !ignoreRange) {
        start = int.parse(range.group(1)!);
        if (start >= bytes.length) {
          response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          return response.close();
        }
      }
      final body = Uint8List.fromList(bytes.sublist(start));
      final status = start > 0 ? '206 Partial Content' : '200 OK';
      final head = StringBuffer('HTTP/1.1 $status\r\n')
        ..write('Content-Type: application/octet-stream\r\n')
        ..write('Content-Length: ${body.length}\r\n')
        ..write('Accept-Ranges: bytes\r\n');
      if (start > 0) head.write('Content-Range: bytes $start-${bytes.length - 1}/${bytes.length}\r\n');
      head.write('Connection: close\r\n\r\n');
      final socket = await response.detachSocket(writeHeaders: false);
      socket.add(utf8.encode(head.toString()));
      final drop = dropAfter.remove(name);
      final hold = holdAfter[name];
      if (drop != null) {
        socket.add(body.sublist(0, (drop - start).clamp(0, body.length)));
        await socket.flush();
        socket.destroy();
        return;
      }
      if (hold != null && hold - start < body.length) {
        final first = (hold - start).clamp(0, body.length);
        socket.add(body.sublist(0, first));
        await socket.flush();
        _held.add(() async {
          try {
            socket.add(body.sublist(first));
            await socket.flush();
            await socket.close();
          } on Object {
            // The client went away.
          }
        });
        return;
      }
      socket.add(body);
      await socket.flush();
      await socket.close();
      return;
    }
    response.statusCode = HttpStatus.notFound;
    await response.close();
  }
}

/// A zip of [files] (name to content); [links] adds symbolic links (name to target), marked as
/// made on Unix so that readers take them as links.
List<int> zipOf(Map<String, List<int>> files, {Map<String, String> links = const {}}) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.addFile(ArchiveFile.bytes(entry.key, entry.value));
  }
  for (final entry in links.entries) {
    final file = ArchiveFile.bytes(entry.key, utf8.encode(entry.value))..mode = 0xA1FF;
    archive.addFile(file);
  }
  final bytes = Uint8List.fromList(ZipEncoder().encode(archive));
  if (links.isNotEmpty) {
    // Version made by: Unix (3) in the central directory's high byte.
    for (var index = 0; index + 4 < bytes.length; index++) {
      if (bytes[index] == 0x50 && bytes[index + 1] == 0x4B && bytes[index + 2] == 1 && bytes[index + 3] == 2) {
        bytes[index + 5] = 3;
      }
    }
  }
  return bytes;
}

/// A .tar.gz of [files]; [links] adds symbolic links (name to target).
List<int> tarGzOf(Map<String, List<int>> files, {Map<String, String> links = const {}}) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.addFile(ArchiveFile.bytes(entry.key, entry.value)..mode = 0x1ED);
  }
  for (final entry in links.entries) {
    archive.addFile(ArchiveFile.symlink(entry.key, entry.value));
  }
  return const GZipEncoder().encodeBytes(TarEncoder().encodeBytes(archive));
}

/// Something that stands in for a library or a relinker, [size] bytes long.
/// The bytes do not repeat, so that archives of them stay about as large.
List<int> filler(String seed, [int size = 4000]) {
  var state = seed.codeUnits.fold(17, (hash, unit) => (hash * 31 + unit) & 0x7FFFFFFF);
  return List.generate(size, (_) {
    state = (state * 1103515245 + 12345) & 0x7FFFFFFF;
    return state >> 16 & 0xFF;
  });
}

/// An upstream release as boykopovar/AnyPS5 publishes it: relinkers for both systems and the
/// libraries for each as zip and .tar.gz. [flat] puts the libraries at the archive's top, as
/// 0.1.0 did; later releases put them in libs/.
FakeRelease upstreamRelease(String version, {bool flat = false, int librarySize = 4000}) {
  final prefix = flat ? '' : 'libs/';
  final linux = {
    '${prefix}libkernel.prx': filler('kernel$version', librarySize),
    '${prefix}libSceVideoOut.prx': filler('video$version', librarySize),
  };
  final windows = {
    ...linux,
    '${prefix}libwinpthread-1.dll': filler('pthread$version'),
    '${prefix}libstdc++-6.dll': filler('stdc$version'),
  };
  return FakeRelease('v$version', {
    'relinker-v$version': utf8.encode('#!/bin/sh\necho relinker $version\n'),
    'relinker-v$version.exe': [0x4D, 0x5A, ...filler('exe$version', 500)],
    'prx-linux-v$version.tar.gz': tarGzOf(linux),
    'prx-linux-v$version.zip': zipOf(linux),
    'prx-windows-v$version.tar.gz': tarGzOf(windows),
    'prx-windows-v$version.zip': zipOf(windows),
    'INPUT_MAPPING.md': utf8.encode('# Input\n'),
  });
}

/// An AnyPS5-ARM release with the Windows and Linux engines as their CI uploads them:
/// `AnyPS5-toolkit-<system>-<commit>.zip` holding relinker[.exe], libs/ and version.txt.
FakeRelease armRelease(String tag, String commit, {bool windows = true, bool linux = true}) {
  final libs = {'libs/libkernel.prx': filler('kernel$commit'), 'libs/libSceVideoOut.prx': filler('video$commit')};
  return FakeRelease(tag, {
    'AnyPS5-macOS.zip': filler('mac$tag'),
    if (windows)
      'AnyPS5-toolkit-windows-$commit.zip': zipOf({
        'relinker.exe': [0x4D, 0x5A, ...filler('exe$commit', 300)],
        'version.txt': utf8.encode('arm-$commit\n'),
        ...libs,
        'libs/libwinpthread-1.dll': filler('pthread'),
      }),
    if (linux)
      'AnyPS5-toolkit-linux-$commit.tar.gz': tarGzOf({
        'AnyPS5-toolkit/relinker': utf8.encode('#!/bin/sh\necho arm\n'),
        for (final entry in libs.entries) 'AnyPS5-toolkit/${entry.key}': entry.value,
      }),
  });
}

/// An upstream nightly as AnyPS5-ARM's Engine nightly workflow publishes it: upstream's main built
/// unmodified, tagged `upstream-nightly.<YYYYMMDD>.<commit>`, with upstream's own release files
/// named after its git describe ([describe]); [unpatched] adds the unpatched libraries upstream's
/// packaging also makes.
FakeRelease upstreamNightlyRelease(
  String tag,
  String describe, {
  bool windows = true,
  bool linux = true,
  bool unpatched = false,
}) {
  final libs = {'libs/libkernel.prx': filler('kernel$describe'), 'libs/libSceVideoOut.prx': filler('video$describe')};
  return FakeRelease(tag, {
    if (windows) ...{
      'relinker-$describe.exe': [0x4D, 0x5A, ...filler('exe$describe', 500)],
      'prx-windows-$describe.zip': zipOf({...libs, 'libs/libwinpthread-1.dll': filler('pthread$describe')}),
      if (unpatched) 'prx-windows-unpatched-$describe.zip': zipOf({'libs/libkernel.prx': filler('raw$describe')}),
    },
    if (linux) ...{
      'relinker-$describe': utf8.encode('#!/bin/sh\necho relinker $describe\n'),
      'prx-linux-$describe.tar.gz': tarGzOf(libs),
      if (unpatched) 'prx-linux-unpatched-$describe.tar.gz': tarGzOf({'libs/libkernel.prx': filler('raw$describe')}),
    },
  }, prerelease: true);
}
