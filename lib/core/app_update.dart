import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'host.dart';
import 'release_signing.dart';
import 'toolkit_download.dart';
import 'update_channel.dart';

/// New releases of AnyPS5 Desktop itself (AnyTogether/AnyPS5-Desktop on GitHub). The launcher says
/// when one is out and downloads its installer for this system, checked against the release's
/// signed SHA256SUMS; the user runs it. Every release newer than a launcher that checks
/// signatures came out after signing began, so an unsigned one is never downloaded.
abstract final class LauncherUpdates {
  static const repository = 'AnyTogether/AnyPS5-Desktop';

  /// Where the launcher's releases are read from, signed with the built-in keys.
  static GitHubReleases source({Uri? api, List<ReleaseKey>? keys, HttpClient Function()? client}) =>
      GitHubReleases(api: api, repository: repository, signingKeys: keys ?? ReleaseSigning.trustedKeys, client: client);

  /// Whether [release] is past the running version [current], in the order releases come out
  /// (a nightly before the release it leads to).
  static bool isNewer(UpstreamRelease release, String current) => ChannelReleases.isNewer(release.tag, current);

  /// The release the Nightly channel offers: the newest with a signature and a file for this
  /// system, as on the Mac, whose Nightly offers a build once it is complete. A nightly CI
  /// published is unsigned until the release Mac signs it (it could not be downloaded), and the
  /// signed build before it stays on offer meanwhile.
  static UpstreamRelease? newestNightly(List<UpstreamRelease> releases, HostSystem system, {bool appImage = false}) =>
      ChannelReleases.offered(releases, UpdateChannel.nightly)
          .where((release) => release.signatureFiles != null && assetFor(release, system, appImage: appImage) != null)
          .firstOrNull;

  /// The file of [release] for this system: the installer on Windows; on Linux the AppImage when
  /// the launcher runs from one ([appImage]), the archive otherwise.
  static ReleaseAsset? assetFor(UpstreamRelease release, HostSystem system, {bool appImage = false}) {
    bool wanted(String name) => switch (system) {
      HostSystem.windows => name.startsWith('AnyPS5-Desktop-Setup-') && name.endsWith('.exe'),
      HostSystem.linux => appImage ? name.endsWith('.AppImage') : name == 'AnyPS5-Desktop-linux-x64.tar.gz',
    };
    return release.assets.where((asset) => wanted(asset.name)).firstOrNull;
  }

  /// Downloads [asset] of [release] into [folder] once the release's signature checked out, and
  /// checks the file against the signed sums; returns where it is. An unsigned release, or one
  /// whose signature is not good, is refused before anything else is downloaded.
  static Future<String> download(
    UpstreamRelease release,
    ReleaseAsset asset,
    String folder, {
    void Function(int received)? onProgress,
    DownloadCancel? cancel,
    HttpClient Function()? client,
  }) async {
    if (release.signingKeys == null || release.signatureFiles == null) {
      throw ToolkitFailure(ToolkitFailureKind.signature, 'AnyPS5 Desktop ${release.version} is not signed');
    }
    final sums = await SignedRelease.sums(release, folder, cancel: cancel, client: client);
    final digest = SignedRelease.digestOf(sums, asset);
    final target = p.join(folder, asset.name);
    await AssetDownload.fetch(
      asset.url,
      target,
      size: asset.size,
      sha256: digest,
      onProgress: onProgress,
      cancel: cancel,
      client: client,
    );
    return target;
  }

  /// The marker of an installer downloaded, checked and left for the next launch (Later).
  static const pendingFile = 'pending.json';

  /// Later on Windows: the installer [file] of [version] runs at the next launch. Its SHA-256
  /// now (checked against the signed sums while it downloaded) goes with it, so a file changed
  /// meanwhile is never run.
  static void writePending(String folder, String version, String file) {
    final digest = sha256.convert(File(file).readAsBytesSync()).toString();
    Directory(folder).createSync(recursive: true);
    File(p.join(folder, pendingFile))
        .writeAsStringSync(jsonEncode({'version': version, 'file': file, 'sha256': digest}));
  }

  /// At launch: the installer left by Later, once (the marker goes whatever happens next), when
  /// it is for a version past [current] and the file is the one that was checked; null otherwise.
  static String? takePending(String folder, String current) {
    final marker = File(p.join(folder, pendingFile));
    if (!marker.existsSync()) return null;
    try {
      final json = jsonDecode(marker.readAsStringSync());
      marker.deleteSync();
      if (json is! Map<String, dynamic>) return null;
      final version = json['version'];
      final file = json['file'];
      final digest = json['sha256'];
      if (version is! String || file is! String || digest is! String) return null;
      if (!ChannelReleases.isNewer(version, current) || !File(file).existsSync()) return null;
      if (sha256.convert(File(file).readAsBytesSync()).toString() != digest) return null;
      return file;
    } on Object {
      if (marker.existsSync()) marker.deleteSync();
      return null;
    }
  }

  /// Puts the downloaded AppImage [file] in place of the running one ([appImage], \$APPIMAGE):
  /// copied beside it, made executable and renamed over it, so the running launcher keeps its
  /// own (already open) copy and the next start is the new one.
  static void swapAppImage(String file, String appImage) {
    final staged = '$appImage.new';
    File(file).copySync(staged);
    final chmod = Process.runSync('chmod', ['755', staged]);
    if (chmod.exitCode != 0) {
      File(staged).deleteSync();
      throw FileSystemException('chmod failed', staged);
    }
    File(staged).renameSync(appImage);
  }
}
