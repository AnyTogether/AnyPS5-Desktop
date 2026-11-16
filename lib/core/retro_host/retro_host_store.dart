import 'dart:io';

import 'package:path/path.dart' as p;

import '../release_signing.dart';
import '../toolkit_download.dart';
import 'retro_host_install.dart';
import 'retro_host_release.dart';

/// The emulator host the launcher downloaded from the host repository's signed GitHub releases,
/// beside its toolkits and its ffmpeg:
///
/// ```text
/// RetroHost/
///     host/          the unpacked zip, with SHA256SUMS, SHA256SUMS.sig and the .files beside it
///     host.new/      a host being unpacked (RetroHostRelease.install)
///     host.old/      the host it replaces, until it can be removed
///     .downloads/    files on their way, kept to carry on after a stop
/// ```
///
/// It is the launcher's own storage, which only the user can write (protocol.md "Finding and
/// checking the host"). Nothing is downloaded unasked: [fetch] runs when the player asks for it.
class RetroHostStore {
  RetroHostStore(this.root, {this.keys, RetroHostSystem? system}) : system = system ?? RetroHostSystem.current;

  /// Where the host releases are published.
  static const repository = 'AnyTogether/anyps5-retro-host';

  final String root;

  /// The keys a release must be signed with; the launcher's built-in keys when null.
  final List<ReleaseKey>? keys;

  /// The system whose files are used; null where no host is released.
  final RetroHostSystem? system;

  Directory get folder => Directory(p.join(root, 'host'));
  String get _downloads => p.join(root, '.downloads');

  /// The host to start, when its files are there; it is checked before each start ([check]).
  RetroHostInstall? installed() {
    final target = system;
    if (target == null || version == null) return null;
    final host = p.join(folder.path, target.executable);
    final core = p.join(folder.path, target.core);
    if (!File(host).existsSync() || !File(core).existsSync()) return null;
    return RetroHostInstall(host: host, core: core, checked: true);
  }

  /// The installed host's version as its SHA256SUMS names it, for showing; not checked.
  RetroHostVersion? get version => system == null ? null : RetroHostRelease.installedVersion(folder, system: system);

  /// The checks before a start ([RetroHostRelease.checkBeforeStart]); the files stay held in the
  /// result until the host it starts has exited.
  Future<RetroHostChecked> check() => RetroHostRelease.checkBeforeStart(folder, keys: keys, system: system);

  /// The release to install from [releases] (newest first, as [GitHubReleases.all] gives them):
  /// the newest that is neither a draft nor a pre-release, is tagged `v<version>` at or above the
  /// launcher's minimum, and has SHA256SUMS and SHA256SUMS.sig; null when there is none.
  static UpstreamRelease? newest(Iterable<UpstreamRelease> releases) {
    for (final release in releases) {
      if (release.prerelease || release.signatureFiles == null || !release.tag.startsWith('v')) continue;
      final version = RetroHostVersion.tryParse(release.version);
      if (version != null && version.compareTo(RetroHostRelease.minimumVersion) >= 0) return release;
    }
    return null;
  }

  /// Downloads [release] into `.downloads/<tag>` and gives that folder, once its signature is
  /// checked and its files match the signed sums; [putInPlace] then installs it.
  ///
  /// The signature comes first: SHA256SUMS and SHA256SUMS.sig are fetched and checked before
  /// anything else, and this system's zip and `.files` are fetched against the digests the signed
  /// sums give them. A release without a signature, or without files for this system, is not
  /// available; there is no way to take it unsigned. Files fetched before a stop are kept, so the
  /// next try carries on.
  Future<Directory> fetch(
    UpstreamRelease? release, {
    void Function(ToolkitProgress)? onProgress,
    DownloadCancel? cancel,
    HttpClient Function()? client,
  }) async {
    final target = system;
    if (target == null) {
      throw ToolkitFailure(ToolkitFailureKind.notAvailable, 'no emulator host is released for this system');
    }
    final signatureFiles = release?.signatureFiles;
    if (release == null || signatureFiles == null) {
      throw ToolkitFailure(ToolkitFailureKind.notAvailable, 'no signed emulator host has been published yet');
    }
    final download = Directory(p.join(_downloads, release.tag));
    download.createSync(recursive: true);
    final (sumsAsset, signatureAsset) = signatureFiles;
    for (final asset in [sumsAsset, signatureAsset]) {
      if (asset.size > ReleaseSigning.largestFile) {
        throw ToolkitFailure(ToolkitFailureKind.signature, '${asset.name} of ${release.tag} is too large');
      }
      await AssetDownload.fetch(
        asset.url,
        p.join(download.path, asset.name),
        size: asset.size,
        sha256: asset.sha256,
        cancel: cancel,
        client: client,
      );
    }
    final RetroHostSignedRelease signed;
    try {
      signed = RetroHostRelease.signed(
        File(p.join(download.path, ReleaseSigning.sumsName)).readAsBytesSync(),
        File(p.join(download.path, ReleaseSigning.signatureName)).readAsBytesSync(),
        keys: keys,
        system: target,
      );
    } on RetroHostNotReleased catch (failure) {
      _forget(download);
      throw ToolkitFailure(ToolkitFailureKind.notAvailable, '${release.tag}: ${failure.message}');
    } on RetroHostReleaseFailure catch (failure) {
      _forget(download);
      throw ToolkitFailure(ToolkitFailureKind.signature, '${release.tag}: ${failure.message}');
    }
    final assets = [
      for (final name in [signed.filesName, signed.zipName])
        release.named(name) ?? (throw ToolkitFailure(ToolkitFailureKind.notAvailable, '${release.tag} has no $name')),
    ];
    final total = assets.fold<int>(0, (sum, asset) => sum + asset.size);
    var before = 0;
    for (final asset in assets) {
      final start = before;
      await AssetDownload.fetch(
        asset.url,
        p.join(download.path, asset.name),
        size: asset.size,
        sha256: signed.sums.digestFor(asset.name),
        cancel: cancel,
        client: client,
        onProgress: (received) => onProgress?.call(ToolkitProgress(ToolkitPhase.download, start + received, total)),
      );
      before += asset.size;
    }
    if (cancel?.cancelled ?? false) throw ToolkitFailure(ToolkitFailureKind.cancelled, 'the download was stopped');
    return download;
  }

  /// Installs what [fetch] downloaded in place of the installed host, through
  /// [RetroHostRelease.install], which checks it all again from the files on disk before it
  /// unpacks; gives its version. Stop the host first: on Windows its files are held while it
  /// runs, and the install then fails with the installed host left whole.
  Future<RetroHostVersion> putInPlace(Directory download) async {
    final RetroHostVersion version;
    try {
      version = await RetroHostRelease.install(download, folder, keys: keys, system: system);
    } on RetroHostReleaseFailure catch (failure) {
      throw ToolkitFailure(ToolkitFailureKind.badLayout, failure.message);
    } on FileSystemException catch (failure) {
      throw ToolkitFailure(
        ToolkitFailureKind.badLayout,
        'the host could not be written: ${failure.osError?.message ?? failure.message}',
      );
    }
    _forget(Directory(_downloads));
    return version;
  }

  void _forget(Directory folder) {
    try {
      if (folder.existsSync()) folder.deleteSync(recursive: true);
    } on FileSystemException {
      // Left for the next download.
    }
  }
}
