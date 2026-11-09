import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'host.dart';
import 'release_signing.dart';
import 'toolkit.dart';

/// Why getting the AnyPS5 engine from upstream did not work.
enum ToolkitFailureKind {
  /// GitHub could not be reached, or answered with an error.
  network,

  /// The release has no relinker and system libraries for this system.
  noAssets,

  /// GitHub gave no checksum for a file; it is only used when the user says so.
  unverified,

  /// A downloaded file is not the one GitHub described (size or checksum).
  checksum,

  /// A release that must be signed is not, or its signature is not good: it is refused.
  signature,

  /// A release of a signing source published before signing began; it is only used when the
  /// user says so.
  unsigned,

  /// The archive names a file outside its own folder, or a link that leads out of it.
  unsafeArchive,

  /// The unpacked files are not a toolkit.
  badLayout,

  /// The user stopped the download.
  cancelled,

  /// The release is not out (or not signed) yet: nothing is wrong, it just cannot be had.
  notAvailable,
}

class ToolkitFailure implements Exception {
  ToolkitFailure(this.kind, this.message);
  final ToolkitFailureKind kind;
  final String message;

  @override
  String toString() => message;
}

/// One file of an upstream release, as GitHub's API describes it.
class ReleaseAsset {
  const ReleaseAsset({required this.name, required this.size, required this.url, this.sha256, this.updated});

  factory ReleaseAsset.fromJson(Map<String, dynamic> json) {
    final digest = json['digest'] as String?;
    return ReleaseAsset(
      name: json['name'] as String,
      size: (json['size'] as num).toInt(),
      url: Uri.parse(json['browser_download_url'] as String),
      sha256: digest != null && digest.startsWith('sha256:') && digest.length == 71
          ? digest.substring(7).toLowerCase()
          : null,
      updated: DateTime.tryParse(json['updated_at'] as String? ?? ''),
    );
  }

  final String name;
  final int size;
  final Uri url;

  /// GitHub's SHA-256 of the file in hex, null when the API gave none.
  final String? sha256;

  /// When the file was uploaded (GitHub's updated_at), null when the API gave none.
  final DateTime? updated;
}

/// A release on GitHub: upstream AnyPS5's (boykopovar/AnyPS5), or one of ours, which are signed.
class UpstreamRelease {
  const UpstreamRelease({
    required this.tag,
    required this.assets,
    this.published,
    this.prerelease = false,
    this.signingKeys,
  });

  factory UpstreamRelease.fromJson(Map<String, dynamic> json, {List<ReleaseKey>? signingKeys}) => UpstreamRelease(
    tag: json['tag_name'] as String,
    published: DateTime.tryParse(json['published_at'] as String? ?? ''),
    prerelease: json['prerelease'] as bool? ?? false,
    signingKeys: signingKeys,
    assets: [
      for (final asset in json['assets'] as List<dynamic>? ?? const [])
        if (asset is Map<String, dynamic>) ReleaseAsset.fromJson(asset),
    ],
  );

  final String tag;
  final DateTime? published;
  final bool prerelease;
  final List<ReleaseAsset> assets;

  /// The keys a release of a signing source (AnyPS5-ARM, AnyPS5 Desktop) must be signed with;
  /// null for upstream, which does not sign its releases (GitHub's checksums check those).
  final List<ReleaseKey>? signingKeys;

  /// The tag without its v: 0.1.3.
  String get version => tag.startsWith('v') ? tag.substring(1) : tag;

  ReleaseAsset? named(String name) => assets.where((asset) => asset.name == name).firstOrNull;

  /// SHA256SUMS and SHA256SUMS.sig, when the release has both.
  (ReleaseAsset, ReleaseAsset)? get signatureFiles {
    final sums = named(ReleaseSigning.sumsName);
    final signature = named(ReleaseSigning.signatureName);
    return sums == null || signature == null ? null : (sums, signature);
  }

  /// How far the release can be trusted; null for upstream's (GitHub's checksums only).
  ReleaseTrust? get trust {
    if (signingKeys == null) return null;
    return ReleaseSigning.trust(version, signed: signatureFiles != null);
  }

  /// The relinker and the system libraries for [system], null when the release has none.
  ///
  /// Windows takes `relinker-v0.1.3.exe` and `prx-windows-v0.1.3.zip`, Linux `relinker-v0.1.3`
  /// and `prx-linux-v0.1.3.tar.gz`; the other archive format of the same libraries is the
  /// fallback.
  ToolkitPackage? packageFor(HostSystem system) {
    final windows = system == HostSystem.windows;
    final relinker = named(windows ? 'relinker-v$version.exe' : 'relinker-v$version');
    final prefix = 'prx-${windows ? 'windows' : 'linux'}-v$version';
    final formats = windows ? ['.zip', '.tar.gz'] : ['.tar.gz', '.zip'];
    final libraries = formats.map((format) => named('$prefix$format')).nonNulls.firstOrNull;
    if (relinker == null || libraries == null) return null;
    return ToolkitPackage(release: this, relinker: relinker, libraries: libraries);
  }
}

/// What is downloaded for one system: the relinker and the archive of system libraries.
class ToolkitPackage {
  const ToolkitPackage({required this.release, required this.relinker, required this.libraries});

  final UpstreamRelease release;
  final ReleaseAsset relinker;
  final ReleaseAsset libraries;

  String get version => release.version;

  /// Bytes to download.
  int get size => relinker.size + libraries.size;

  /// Whether GitHub gave a checksum for both files.
  bool get verified => relinker.sha256 != null && libraries.sha256 != null;

  /// How far the release can be trusted; null for upstream's (GitHub's checksums only).
  ReleaseTrust? get trust => release.trust;

  /// The version.txt a toolkit made from this package has: upstream-v0.1.3.
  String get toolkitVersion => ToolkitStore.versionText(version);
}

/// The AnyPS5-ARM engine for one system, as AnyPS5-ARM's releases carry it: one archive,
/// `AnyPS5-toolkit-<windows|linux>-<commit>.zip` (or .tar.gz), holding the whole toolkit (the
/// relinker, libs/, version.txt). Built from AnyPS5-ARM's tree, it reads what upstream's engine
/// does not: the phone controller, ANYPS5_FULLSCREEN and ANYPS5_WINDOW_SIZE. Its toolkit folder
/// and version.txt are `arm-<commit>`.
class ArmToolkitPackage extends ToolkitPackage {
  ArmToolkitPackage({required super.release, required this.archive, required this.commit})
    : super(relinker: archive, libraries: archive);

  static const repository = 'AnyTogether/AnyPS5-ARM';
  static final _name = RegExp(r'^AnyPS5-toolkit-(windows|linux)-([0-9a-f]{7,40})\.(zip|tar\.gz)$');

  final ReleaseAsset archive;
  final String commit;

  @override
  String get version => 'arm-$commit';

  @override
  int get size => archive.size;

  @override
  bool get verified => archive.sha256 != null;

  @override
  String get toolkitVersion => version;

  /// The newest of [releases] (newest first) that carries the engine for [system].
  static ArmToolkitPackage? find(List<UpstreamRelease> releases, HostSystem system) {
    final wanted = system == HostSystem.windows ? 'windows' : 'linux';
    for (final release in releases) {
      final matches = [
        for (final asset in release.assets)
          if (_name.firstMatch(asset.name) case final match? when match.group(1) == wanted) (asset, match.group(2)!),
      ];
      if (matches.isEmpty) continue;
      // The newest upload first: a release keeps an older engine beside a newer one for the
      // launchers that already have it, and GitHub lists files by name, not by age. Then the
      // zip first on Windows, the .tar.gz first on Linux.
      final epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
      final newest = matches.map((match) => match.$1.updated ?? epoch).reduce((a, b) => a.isAfter(b) ? a : b);
      final commit = matches.firstWhere((match) => (match.$1.updated ?? epoch) == newest).$2;
      matches.retainWhere((match) => match.$2 == commit);
      matches.sort((a, b) {
        int rank(ReleaseAsset asset) => asset.name.endsWith(system == HostSystem.windows ? '.zip' : '.tar.gz') ? 0 : 1;
        return rank(a.$1).compareTo(rank(b.$1));
      });
      return ArmToolkitPackage(release: release, archive: matches.first.$1, commit: matches.first.$2);
    }
    return null;
  }
}

/// Upstream AnyPS5's main as it was on one day, built unmodified by AnyPS5-ARM's CI (its Engine
/// nightly workflow) and published as an AnyPS5-ARM pre-release tagged
/// `upstream-nightly.<YYYYMMDD>.<commit>`, signed as AnyPS5-ARM's nightlies are. Its files are
/// upstream's own release files, named after upstream's git describe instead of a release:
/// `relinker-v0.1.4-1523-gbf80054e7.exe` and `prx-windows-v0.1.4-1523-gbf80054e7.zip` on Windows,
/// `relinker-v0.1.4-1523-gbf80054e7` and `prx-linux-v0.1.4-1523-gbf80054e7.tar.gz` on Linux. They
/// are laid out as upstream's releases are; the toolkit folder and version.txt are
/// `upstream-main-<commit>`. It has none of AnyPS5-ARM's changes, and nobody tried it with a game:
/// only the Nightly update channel offers it.
class UpstreamNightlyPackage extends ToolkitPackage {
  const UpstreamNightlyPackage({
    required super.release,
    required super.relinker,
    required super.libraries,
    required this.commit,
    required this.day,
    required this.describe,
  });

  static final _tag = RegExp(r'^upstream-nightly\.(\d{4})(\d{2})(\d{2})\.([0-9a-f]{7,40})$');

  /// What its version.txt (and toolkit folder) starts with.
  static const prefix = 'upstream-main-';

  /// Upstream's commit, as the tag gives it (9 digits).
  final String commit;

  /// The day (UTC) it was built.
  final DateTime day;

  /// Upstream's git describe the files are named after: v0.1.4-1523-gbf80054e7.
  final String describe;

  @override
  String get version => '$prefix$commit';

  @override
  String get toolkitVersion => version;

  /// The day it was built, 2026-11-06.
  String get date =>
      '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';

  /// Whether a toolkit's version.txt names an upstream nightly.
  static bool isVersion(String? toolkitVersion) => toolkitVersion != null && toolkitVersion.startsWith(prefix);

  /// The upstream commit in an upstream nightly's version.txt, null for any other toolkit.
  static String? commitOf(String? toolkitVersion) =>
      isVersion(toolkitVersion) ? toolkitVersion!.substring(prefix.length) : null;

  /// [release]'s files for [system] when it is an upstream nightly that has them, else null.
  static UpstreamNightlyPackage? of(UpstreamRelease release, HostSystem system) {
    final tag = _tag.firstMatch(release.tag);
    if (tag == null) return null;
    final (year, month, date) = (int.parse(tag.group(1)!), int.parse(tag.group(2)!), int.parse(tag.group(3)!));
    final day = DateTime.utc(year, month, date);
    if (day.year != year || day.month != month || day.day != date) return null;
    final windows = system == HostSystem.windows;
    final libraries = RegExp('^prx-${windows ? 'windows' : 'linux'}-(v[0-9A-Za-z][0-9A-Za-z._-]*)\\.(zip|tar\\.gz)\$');
    // The zip first on Windows, the .tar.gz first on Linux, as for upstream's releases.
    for (final format in windows ? ['zip', 'tar.gz'] : ['tar.gz', 'zip']) {
      for (final asset in release.assets) {
        final match = libraries.firstMatch(asset.name);
        if (match == null || match.group(2) != format) continue;
        final describe = match.group(1)!;
        final relinker = release.named(windows ? 'relinker-$describe.exe' : 'relinker-$describe');
        if (relinker == null) continue;
        return UpstreamNightlyPackage(
          release: release,
          relinker: relinker,
          libraries: asset,
          commit: tag.group(4)!,
          day: day,
          describe: describe,
        );
      }
    }
    return null;
  }

  /// The newest upstream nightly in [releases] that has the files for [system]: the latest day,
  /// then the one published last.
  static UpstreamNightlyPackage? newest(Iterable<UpstreamRelease> releases, HostSystem system) {
    final epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    UpstreamNightlyPackage? best;
    for (final release in releases) {
      final package = of(release, system);
      if (package == null) continue;
      final order = best == null
          ? 1
          : package.day != best.day
          ? package.day.compareTo(best.day)
          : (release.published ?? epoch).compareTo(best.release.published ?? epoch);
      if (order > 0) best = package;
    }
    return best;
  }
}

/// Orders upstream versions: 0.1.10 after 0.1.9, a release after its own pre-release.
int compareVersions(String a, String b) {
  List<int> numbers(String version) {
    final core = (version.startsWith('v') ? version.substring(1) : version).split(RegExp('[-+]')).first;
    return core.split('.').map((part) => int.tryParse(part) ?? 0).toList();
  }

  final left = numbers(a);
  final right = numbers(b);
  for (var index = 0; index < left.length || index < right.length; index++) {
    final x = index < left.length ? left[index] : 0;
    final y = index < right.length ? right[index] : 0;
    if (x != y) return x.compareTo(y);
  }
  String bare(String version) => version.startsWith('v') ? version.substring(1) : version;
  final leftPre = a.contains('-');
  final rightPre = b.contains('-');
  if (leftPre != rightPre) return leftPre ? -1 : 1;
  return bare(a).compareTo(bare(b));
}

/// Stops a download or an install in progress.
class DownloadCancel {
  bool _cancelled = false;
  final List<void Function()> _listeners = [];

  bool get cancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final listener in List.of(_listeners)) {
      listener();
    }
  }

  void _check() {
    if (_cancelled) throw ToolkitFailure(ToolkitFailureKind.cancelled, 'the download was stopped');
  }
}

/// Reads a repository's releases from GitHub's API: upstream's by default. [signingKeys] makes
/// it a signing source (one of ours), whose releases must be signed with those keys.
class GitHubReleases {
  GitHubReleases({Uri? api, this.repository = defaultRepository, this.signingKeys, HttpClient Function()? client})
    : api = api ?? Uri.parse('https://api.github.com'),
      _client = client ?? HttpClient.new;

  static const defaultRepository = 'boykopovar/AnyPS5';

  final Uri api;
  final String repository;
  final List<ReleaseKey>? signingKeys;
  final HttpClient Function() _client;

  /// The release GitHub calls the latest.
  Future<UpstreamRelease> latest() async {
    final json = await _get('repos/$repository/releases/latest');
    if (json is! Map<String, dynamic>) throw ToolkitFailure(ToolkitFailureKind.network, 'GitHub sent no release');
    return UpstreamRelease.fromJson(json, signingKeys: signingKeys);
  }

  /// The release with [tag], null when GitHub has none by that name.
  Future<UpstreamRelease?> byTag(String tag) async {
    final json = await _get('repos/$repository/releases/tags/$tag', absentIsNull: true);
    if (json == null) return null;
    if (json is! Map<String, dynamic>) throw ToolkitFailure(ToolkitFailureKind.network, 'GitHub sent no release');
    return UpstreamRelease.fromJson(json, signingKeys: signingKeys);
  }

  /// Every recent release, newest first, without drafts. As many as GitHub gives at once (100):
  /// AnyPS5-ARM publishes nightlies and upstream nightlies beside its releases, and the newest
  /// release has to stay in the list.
  Future<List<UpstreamRelease>> all() async {
    final json = await _get('repos/$repository/releases?per_page=100');
    if (json is! List<dynamic>) throw ToolkitFailure(ToolkitFailureKind.network, 'GitHub sent no releases');
    final releases = [
      for (final entry in json)
        if (entry is Map<String, dynamic> && entry['draft'] != true)
          UpstreamRelease.fromJson(entry, signingKeys: signingKeys),
    ]..sort((a, b) => compareVersions(b.version, a.version));
    return releases;
  }

  Future<Object?> _get(String path, {bool absentIsNull = false}) async {
    final client = _client()..connectionTimeout = const Duration(seconds: 20);
    try {
      final base = api.toString().endsWith('/') ? api : Uri.parse('$api/');
      final request = await client.getUrl(base.resolve(path));
      request.headers
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
        ..set(HttpHeaders.userAgentHeader, 'AnyPS5-Desktop')
        ..set('X-GitHub-Api-Version', '2022-11-28');
      final response = await request.close().timeout(const Duration(seconds: 30));
      final body = await response.transform(utf8.decoder).join();
      if (absentIsNull && response.statusCode == HttpStatus.notFound) return null;
      if (response.statusCode != HttpStatus.ok) {
        throw ToolkitFailure(ToolkitFailureKind.network, 'GitHub answered ${response.statusCode}');
      }
      return jsonDecode(body);
    } on ToolkitFailure {
      rethrow;
    } on Object catch (error) {
      throw ToolkitFailure(ToolkitFailureKind.network, 'GitHub could not be reached: $error');
    } finally {
      client.close(force: true);
    }
  }
}

/// Downloads one file into place: into [target].part first, carried on from where an earlier
/// try stopped, then checked against [size] and [sha256] and renamed to [target].
abstract final class AssetDownload {
  static Future<void> fetch(
    Uri url,
    String target, {
    required int size,
    String? sha256,
    void Function(int received)? onProgress,
    DownloadCancel? cancel,
    HttpClient Function()? client,
  }) async {
    // A file finished by an earlier try that stopped later is kept when it still checks out.
    final done = File(target);
    if (done.existsSync() &&
        done.lengthSync() == size &&
        (sha256 == null || await sha256Of(target) == sha256.toLowerCase())) {
      onProgress?.call(size);
      return;
    }
    final part = File('$target.part');
    part.parent.createSync(recursive: true);
    var have = part.existsSync() ? part.lengthSync() : 0;
    if (have > size) {
      part.deleteSync();
      have = 0;
    }
    if (have < size) await _receive(url, part, have, size, onProgress, cancel, client ?? HttpClient.new);
    onProgress?.call(size);
    cancel?._check();
    final length = part.lengthSync();
    if (length != size) {
      part.deleteSync();
      throw ToolkitFailure(ToolkitFailureKind.checksum, '${p.basename(target)}: $length bytes, expected $size');
    }
    if (sha256 != null) {
      final digest = (await sha256Of(part.path)).toLowerCase();
      if (digest != sha256.toLowerCase()) {
        part.deleteSync();
        throw ToolkitFailure(ToolkitFailureKind.checksum, '${p.basename(target)}: checksum does not match');
      }
    }
    if (File(target).existsSync()) File(target).deleteSync();
    part.renameSync(target);
  }

  static Future<String> sha256Of(String file) async => (await sha256.bind(File(file).openRead()).first).toString();

  static Future<void> _receive(
    Uri url,
    File part,
    int have,
    int size,
    void Function(int)? onProgress,
    DownloadCancel? cancel,
    HttpClient Function() makeClient,
  ) async {
    final client = makeClient()
      ..connectionTimeout = const Duration(seconds: 20)
      ..idleTimeout = const Duration(seconds: 30);
    void stop() => client.close(force: true);
    cancel?._listeners.add(stop);
    try {
      cancel?._check();
      // Redirects are followed here, so that every hop is asked for the same range.
      var location = url;
      HttpClientResponse? response;
      for (var hop = 0; hop < 6; hop++) {
        final request = await client.getUrl(location);
        request
          ..followRedirects = false
          ..headers.set(HttpHeaders.userAgentHeader, 'AnyPS5-Desktop')
          ..headers.set(HttpHeaders.acceptHeader, 'application/octet-stream');
        if (have > 0) request.headers.set(HttpHeaders.rangeHeader, 'bytes=$have-');
        final answer = await request.close();
        if (answer.isRedirect) {
          final next = answer.headers.value(HttpHeaders.locationHeader);
          await answer.drain<void>();
          if (next == null) break;
          location = location.resolve(next);
          continue;
        }
        response = answer;
        break;
      }
      if (response == null) throw ToolkitFailure(ToolkitFailureKind.network, 'too many redirects for $url');
      final IOSink sink;
      switch (response.statusCode) {
        case HttpStatus.partialContent
            when have > 0 && (response.headers.value(HttpHeaders.contentRangeHeader) ?? '').startsWith('bytes $have-'):
          sink = part.openWrite(mode: FileMode.append);
        case HttpStatus.partialContent:
          await response.drain<void>();
          part.deleteSync();
          throw ToolkitFailure(ToolkitFailureKind.network, 'the server sent another part of the file; try again');
        case HttpStatus.ok:
          // The server sent the whole file: start again.
          have = 0;
          sink = part.openWrite();
        case HttpStatus.requestedRangeNotSatisfiable:
          await response.drain<void>();
          // The part is as long as the server's file, or wrong; the checks after say which.
          if (part.lengthSync() != size) part.deleteSync();
          if (!part.existsSync()) throw ToolkitFailure(ToolkitFailureKind.network, 'the download could not resume');
          return;
        default:
          await response.drain<void>();
          throw ToolkitFailure(ToolkitFailureKind.network, 'the download answered ${response.statusCode}');
      }
      var received = have;
      try {
        await for (final chunk in response.timeout(const Duration(seconds: 60))) {
          sink.add(chunk);
          received += chunk.length;
          if (received > size) throw ToolkitFailure(ToolkitFailureKind.checksum, 'the file is longer than expected');
          onProgress?.call(received);
        }
      } finally {
        await sink.flush();
        await sink.close();
      }
    } on ToolkitFailure {
      cancel?._check();
      rethrow;
    } on Object catch (error) {
      cancel?._check();
      throw ToolkitFailure(ToolkitFailureKind.network, 'the download stopped: $error');
    } finally {
      cancel?._listeners.remove(stop);
      client.close(force: true);
    }
    if (part.lengthSync() < size) {
      throw ToolkitFailure(ToolkitFailureKind.network, 'the download stopped early; try again to carry on');
    }
  }
}

/// The signed sums of a release of a signing source: SHA256SUMS and SHA256SUMS.sig are
/// downloaded into [folder] and the signature checked with the release's keys.
abstract final class SignedRelease {
  static Future<SignedSums> sums(
    UpstreamRelease release,
    String folder, {
    DownloadCancel? cancel,
    HttpClient Function()? client,
  }) async {
    final keys = release.signingKeys;
    final files = release.signatureFiles;
    if (keys == null || files == null) {
      throw ToolkitFailure(ToolkitFailureKind.signature, '${release.tag} is not signed');
    }
    final (sumsAsset, signatureAsset) = files;
    final paths = <String>[];
    for (final asset in [sumsAsset, signatureAsset]) {
      if (asset.size > ReleaseSigning.largestFile) {
        throw ToolkitFailure(ToolkitFailureKind.signature, '${asset.name} of ${release.tag} is too large');
      }
      final path = p.join(folder, '${release.tag}.${asset.name}');
      await AssetDownload.fetch(
        asset.url,
        path,
        size: asset.size,
        sha256: asset.sha256,
        cancel: cancel,
        client: client,
      );
      paths.add(path);
    }
    try {
      return ReleaseSigning.verify(File(paths[0]).readAsBytesSync(), File(paths[1]).readAsBytesSync(), keys: keys);
    } on SigningFailure catch (failure) {
      throw ToolkitFailure(ToolkitFailureKind.signature, '${release.tag}: ${failure.message}');
    } finally {
      for (final path in paths) {
        if (File(path).existsSync()) File(path).deleteSync();
      }
    }
  }

  /// The sha256 the signed [sums] give [asset]; fails when they do not list it.
  static String digestOf(SignedSums sums, ReleaseAsset asset) =>
      sums.digestFor(asset.name) ??
      (throw ToolkitFailure(ToolkitFailureKind.signature, 'the signed release does not list ${asset.name}'));
}

/// Unpacks a zip or a .tar.gz into a folder without letting it write anywhere else: names that
/// are absolute, carry a drive or climb out with .. stop the unpacking, and so does a link whose
/// target leads out of the folder. Links that stay inside are made last (on POSIX; Windows
/// skips them), so no file is written through one.
abstract final class SafeUnpack {
  static Future<void> unpack(String archive, String destination) => Isolate.run(() => unpackSync(archive, destination));

  static void unpackSync(String archive, String destination) {
    Directory(destination).createSync(recursive: true);
    final root = p.normalize(p.absolute(destination));
    final links = <(String, String)>[];

    void entry(ArchiveFile file) {
      final relative = safeName(file.name);
      if (relative == null) return;
      final target = p.joinAll([root, ...relative]);
      if (file.isSymbolicLink) {
        final link = file.symbolicLink!.replaceAll(r'\', '/');
        final resolved = p.normalize(p.join(p.dirname(target), p.joinAll(link.split('/'))));
        if (p.posix.isAbsolute(link) || p.windows.isAbsolute(link) || !p.isWithin(root, resolved)) {
          throw ToolkitFailure(ToolkitFailureKind.unsafeArchive, 'the archive links ${file.name} outside itself');
        }
        links.add((target, link));
        return;
      }
      if (!file.isFile) {
        Directory(target).createSync(recursive: true);
        return;
      }
      Directory(p.dirname(target)).createSync(recursive: true);
      final output = OutputFileStream(target);
      try {
        file.writeContent(output);
      } finally {
        output.closeSync();
      }
    }

    final lower = archive.toLowerCase();
    if (lower.endsWith('.zip')) {
      final input = InputFileStream(archive);
      try {
        final decoded = ZipDecoder().decodeStream(input);
        for (final file in decoded.files) {
          entry(file);
        }
      } finally {
        input.closeSync();
      }
    } else if (lower.endsWith('.tar.gz') || lower.endsWith('.tgz')) {
      final tar = '$destination.tar';
      final source = InputFileStream(archive);
      final unzipped = OutputFileStream(tar);
      try {
        const GZipDecoder().decodeStream(source, unzipped);
      } finally {
        source.closeSync();
        unzipped.closeSync();
      }
      final input = InputFileStream(tar);
      try {
        TarDecoder().decodeStream(input, callback: entry, keepEntries: false);
      } finally {
        input.closeSync();
        File(tar).deleteSync();
      }
    } else {
      throw ToolkitFailure(ToolkitFailureKind.badLayout, 'unknown archive format: ${p.basename(archive)}');
    }
    if (!Platform.isWindows) {
      for (final (path, target) in links) {
        Directory(p.dirname(path)).createSync(recursive: true);
        if (FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.notFound) {
          Link(path).createSync(target);
        }
      }
    }
  }

  /// The parts of an archive member's name, null for the archive's own folder; throws for a
  /// name that would land outside the folder.
  static List<String>? safeName(String name) {
    final unsafe = ToolkitFailure(ToolkitFailureKind.unsafeArchive, 'the archive names a file outside itself: $name');
    final slashed = name.replaceAll(r'\', '/');
    if (slashed.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(slashed) || slashed.contains('\u0000')) {
      throw unsafe;
    }
    final parts = <String>[];
    for (final part in slashed.split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') throw unsafe;
      if (part.contains(':')) throw unsafe;
      parts.add(part);
    }
    return parts.isEmpty ? null : parts;
  }
}

/// How far an engine download has come.
class ToolkitProgress {
  const ToolkitProgress(this.phase, this.received, this.total);
  final ToolkitPhase phase;
  final int received;
  final int total;

  double get fraction => total <= 0 ? 0 : (received / total).clamp(0, 1).toDouble();
}

enum ToolkitPhase { download, unpack, finish }

/// The engine toolkits the launcher downloaded, one folder per upstream version:
///
/// ```text
/// Toolkits/
///     0.1.3/              relinker[.exe], libs/, version.txt = upstream-v0.1.3
///     0.1.2/
///     .downloads/         files on their way, kept to carry on after a restart
///     .staging-0.1.4/     a toolkit being laid out
/// ```
class ToolkitStore {
  ToolkitStore(this.root, {this.system = HostSystem.linux});

  final String root;
  final HostSystem system;

  static String versionText(String version) => 'upstream-v$version';

  /// The upstream version a toolkit was downloaded as, null for any other toolkit.
  static String? upstreamVersion(String toolkitVersion) =>
      toolkitVersion.startsWith('upstream-v') ? toolkitVersion.substring('upstream-v'.length) : null;

  String folderFor(String version) => p.join(root, version);
  String get _downloads => p.join(root, '.downloads');

  /// The usable toolkits in the store, newest first.
  List<Toolkit> installed() {
    final List<Directory> folders;
    try {
      folders = Directory(root).listSync().whereType<Directory>().toList();
    } on FileSystemException {
      return const [];
    }
    final toolkits = [
      for (final folder in folders)
        if (!p.basename(folder.path).startsWith('.')) Toolkit(folder.path, system: system),
    ].where((toolkit) => toolkit.problem == null).toList();
    toolkits.sort((a, b) => compareVersions(p.basename(b.root), p.basename(a.root)));
    return toolkits;
  }

  /// The store's toolkit for [version], null when it is not there.
  Toolkit? find(String version) {
    final toolkit = Toolkit(folderFor(version), system: system);
    return toolkit.problem == null ? toolkit : null;
  }

  /// Downloads [package], checks it and lays it out as a toolkit; returns it.
  ///
  /// A release of a signing source is checked against its signed SHA256SUMS; one published after
  /// signing began without a signature is refused, an older unsigned one needs [allowUnsigned].
  /// Upstream's releases are checked with GitHub's checksums: without [allowUnverified], a package
  /// GitHub gave no checksum for is refused. All of this happens before any download.
  Future<Toolkit> install(
    ToolkitPackage package, {
    bool allowUnverified = false,
    bool allowUnsigned = false,
    void Function(ToolkitProgress)? onProgress,
    DownloadCancel? cancel,
    HttpClient Function()? client,
  }) async {
    final version = package.version;
    if (!_plainName(version)) {
      throw ToolkitFailure(ToolkitFailureKind.unsafeArchive, 'unusable version name $version');
    }
    var relinkerSha256 = package.relinker.sha256;
    var librariesSha256 = package.libraries.sha256;
    switch (package.trust) {
      case ReleaseTrust.signed:
        final sums = await SignedRelease.sums(package.release, _downloads, cancel: cancel, client: client);
        relinkerSha256 = SignedRelease.digestOf(sums, package.relinker);
        librariesSha256 = SignedRelease.digestOf(sums, package.libraries);
      case ReleaseTrust.unsignedRefused:
        throw ToolkitFailure(
          ToolkitFailureKind.signature,
          'AnyPS5 $version is not signed, though it came out after releases began to be signed',
        );
      case ReleaseTrust.unsignedOlder when !allowUnsigned:
        throw ToolkitFailure(ToolkitFailureKind.unsigned, 'AnyPS5 $version is unsigned (an older release)');
      case ReleaseTrust.unsignedOlder || null:
        if (!package.verified && !allowUnverified) {
          throw ToolkitFailure(ToolkitFailureKind.unverified, 'GitHub gave no checksum for AnyPS5 $version');
        }
    }
    final total = package.size;
    final relinkerFile = p.join(_downloads, package.relinker.name);
    final librariesFile = p.join(_downloads, package.libraries.name);
    await AssetDownload.fetch(
      package.relinker.url,
      relinkerFile,
      size: package.relinker.size,
      sha256: relinkerSha256,
      cancel: cancel,
      client: client,
      onProgress: (received) => onProgress?.call(ToolkitProgress(ToolkitPhase.download, received, total)),
    );
    // An AnyPS5-ARM package is one archive: fetched once above.
    if (package is! ArmToolkitPackage) {
      await AssetDownload.fetch(
        package.libraries.url,
        librariesFile,
        size: package.libraries.size,
        sha256: librariesSha256,
        cancel: cancel,
        client: client,
        onProgress: (received) =>
            onProgress?.call(ToolkitProgress(ToolkitPhase.download, package.relinker.size + received, total)),
      );
    }
    cancel?._check();
    onProgress?.call(ToolkitProgress(ToolkitPhase.unpack, total, total));
    final staging = p.join(root, '.staging-$version');
    final raw = p.join(staging, '.unpacked');
    if (Directory(staging).existsSync()) Directory(staging).deleteSync(recursive: true);
    try {
      await SafeUnpack.unpack(librariesFile, raw);
      cancel?._check();
      if (package is ArmToolkitPackage) {
        layOutWhole(raw, staging, version: package.toolkitVersion);
      } else {
        layOut(raw, staging, relinker: relinkerFile, version: version, stamp: package.toolkitVersion);
      }
      final toolkit = Toolkit(staging, system: system);
      final problem = toolkit.problem;
      if (problem != null) {
        throw ToolkitFailure(ToolkitFailureKind.badLayout, 'the release is not a toolkit for this system ($problem)');
      }
      cancel?._check();
      onProgress?.call(ToolkitProgress(ToolkitPhase.finish, total, total));
      final folder = folderFor(version);
      if (Directory(folder).existsSync()) Directory(folder).deleteSync(recursive: true);
      Directory(staging).renameSync(folder);
    } finally {
      if (Directory(staging).existsSync()) Directory(staging).deleteSync(recursive: true);
    }
    for (final file in [relinkerFile, librariesFile]) {
      if (File(file).existsSync()) File(file).deleteSync();
    }
    return Toolkit(folderFor(version), system: system);
  }

  /// Turns the unpacked archive in [raw] and the downloaded [relinker] into the toolkit layout
  /// in [folder]: the folder that holds the .prx files becomes libs/ (older releases put them
  /// at the archive's top, newer ones in libs/), what sits beside a libs/ folder (patches/)
  /// is kept, the relinker gets its toolkit name and on POSIX its executable bit. version.txt says
  /// [stamp], by default `upstream-v<version>`.
  void layOut(String raw, String folder, {required String relinker, required String version, String? stamp}) {
    final prx = Directory(raw)
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .where((file) => p.extension(file.path).toLowerCase() == '.prx')
        .map((file) => p.dirname(file.path))
        .toList();
    if (prx.isEmpty) throw ToolkitFailure(ToolkitFailureKind.badLayout, 'the archive has no system libraries');
    final counts = <String, int>{};
    for (final directory in prx) {
      counts[directory] = (counts[directory] ?? 0) + 1;
    }
    final libraries = (counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;
    final libs = p.join(folder, 'libs');
    if (p.basename(libraries) == 'libs' && p.isWithin(raw, libraries)) {
      final base = p.dirname(libraries);
      for (final entity in Directory(base).listSync(followLinks: false)) {
        final name = p.basename(entity.path);
        final destination = name == 'libs' ? libs : p.join(folder, name);
        if (_reserved(name)) continue;
        entity.renameSync(destination);
      }
    } else {
      Directory(libraries).renameSync(libs);
    }
    final relinkerPath = p.join(folder, system.relinkerName);
    File(relinker).copySync(relinkerPath);
    if (!Platform.isWindows) Process.runSync('chmod', ['755', relinkerPath]);
    File(p.join(folder, 'version.txt')).writeAsStringSync('${stamp ?? versionText(version)}\n');
    if (Directory(raw).existsSync()) Directory(raw).deleteSync(recursive: true);
  }

  /// Lays out an archive that is a whole toolkit (AnyPS5-ARM's): the folder in [raw] that holds
  /// the relinker beside libs/ becomes [folder], and version.txt says [version].
  void layOutWhole(String raw, String folder, {required String version}) {
    final relinkers =
        Directory(raw)
            .listSync(recursive: true, followLinks: false)
            .whereType<File>()
            .where((file) => p.basename(file.path) == system.relinkerName)
            .where((file) => Directory(p.join(p.dirname(file.path), 'libs')).existsSync())
            .toList()
          ..sort((a, b) => a.path.length.compareTo(b.path.length));
    if (relinkers.isEmpty) {
      throw ToolkitFailure(ToolkitFailureKind.badLayout, 'the archive has no ${system.relinkerName} beside libs/');
    }
    final base = p.dirname(relinkers.first.path);
    for (final entity in Directory(base).listSync(followLinks: false)) {
      final name = p.basename(entity.path);
      if (name == '.unpacked' || name == 'version.txt') continue;
      entity.renameSync(p.join(folder, name));
    }
    if (!Platform.isWindows) Process.runSync('chmod', ['755', p.join(folder, system.relinkerName)]);
    File(p.join(folder, 'version.txt')).writeAsStringSync('$version\n');
    if (Directory(raw).existsSync()) Directory(raw).deleteSync(recursive: true);
  }

  /// A version that is one plain folder name.
  static bool _plainName(String version) {
    try {
      return !version.startsWith('.') && SafeUnpack.safeName(version)?.length == 1;
    } on ToolkitFailure {
      return false;
    }
  }

  /// Names the layout writes itself; an archive's own copies are left out.
  bool _reserved(String name) => name == 'version.txt' || name == system.relinkerName || name == '.unpacked';

  /// Deletes the toolkit for [version].
  void remove(String version) {
    if (!_plainName(version)) return;
    final folder = Directory(folderFor(version));
    if (folder.existsSync()) folder.deleteSync(recursive: true);
  }

  /// Deletes what is no longer needed: every toolkit but the [keepNewest] newest and those
  /// whose version.txt is in [keep] (the current one, the ones installed games were made
  /// with), and leftovers of installs that never finished. Returns the versions deleted.
  List<String> removeUnused({Set<String> keep = const {}, int keepNewest = 2}) {
    final removed = <String>[];
    final toolkits = installed();
    for (final (index, toolkit) in toolkits.indexed) {
      if (index < keepNewest || keep.contains(toolkit.version) || keep.contains(toolkit.root)) continue;
      final version = p.basename(toolkit.root);
      remove(version);
      removed.add(version);
    }
    try {
      for (final folder in Directory(root).listSync().whereType<Directory>()) {
        if (p.basename(folder.path).startsWith('.staging-')) folder.deleteSync(recursive: true);
      }
    } on FileSystemException {
      // Nothing there yet.
    }
    return removed;
  }

  /// Deletes half-downloaded files.
  void clearDownloads() {
    final folder = Directory(_downloads);
    if (folder.existsSync()) folder.deleteSync(recursive: true);
  }
}
