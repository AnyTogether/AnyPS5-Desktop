import 'dart:io';

import 'package:path/path.dart' as p;

import '../release_signing.dart';
import '../toolkit_download.dart';
import 'retro_host_install.dart';
import 'retro_host_release.dart';

/// A release [RetroHostStore.fetch] downloaded: the [folder] its files are in, and the [tag] it
/// was published under, which its signed version must match on install too.
typedef RetroHostDownload = ({Directory folder, String tag});

/// The emulator host the launcher downloaded from the host repository's signed GitHub releases,
/// beside its toolkits and its ffmpeg:
///
/// ```text
/// RetroHost/
///     host/          the unpacked host package, with SHA256SUMS, SHA256SUMS.sig, its .files and
///                    .release-tag (the tag it was published under) beside it, and each core
///                    package the player added (the PS2 emulator, LRPS2) unpacked beside it
///                    with its own .files
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

  /// The host to start, when its files are there; it is checked before each start ([check]). A
  /// host left in `host.old` by a launcher stopped in the middle of putting a new one in place is
  /// put back first ([RetroHostRelease.restore]). Its [RetroHostInstall.ps2Core] is the release's
  /// LRPS2 when the release's `.files` lists one (a host with `ps2`), as [check] decides it, and
  /// null otherwise, even with a stray `pcsx2_libretro` file in the folder.
  RetroHostInstall? installed() {
    final target = system;
    if (target == null) return null;
    RetroHostRelease.restore(folder);
    if (version == null) return null;
    final host = p.join(folder.path, target.executable);
    final core = p.join(folder.path, target.core);
    if (!File(host).existsSync() || !File(core).existsSync()) return null;
    final ps2Core = p.join(folder.path, target.ps2Core);
    return RetroHostInstall(
      host: host,
      core: core,
      ps2Core: RetroHostRelease.installedHasPs2Core(folder, system: target) ? ps2Core : null,
      checked: true,
    );
  }

  /// The installed host's version as its SHA256SUMS names it, for showing; not checked.
  RetroHostVersion? get version => system == null ? null : RetroHostRelease.installedVersion(folder, system: system);

  /// The core packages added beside the installed host ([RetroHostRelease.installedCores]); not
  /// checked.
  Set<RetroHostCorePackage> get installedCores =>
      system == null ? const {} : RetroHostRelease.installedCores(folder, system: system);

  /// The core packages the installed host's release has for this system, so the player can add
  /// them ([RetroHostRelease.offeredCores]); none for a release from before LRPS2 shipped, such as
  /// 1.0.0. Not checked.
  Set<RetroHostCorePackage> get offeredCores =>
      system == null ? const {} : RetroHostRelease.offeredCores(folder, system: system);

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

  /// Downloads [release] into `.downloads/<tag>` and gives that folder with the tag, once its
  /// signature is checked and its files match the signed sums; [putInPlace] then installs it.
  ///
  /// The signature comes first: SHA256SUMS and SHA256SUMS.sig are fetched and checked before
  /// anything else, with the version they sign held to the release's tag, and this system's host
  /// package (its zip and `.files`) is fetched against the digests the signed sums give them, with
  /// the package of each of [cores] the release has, so the core packages the player added move
  /// with the host. A release without a signature, or without files for this system, is not
  /// available; there is no way to take it unsigned. Files fetched before a stop are kept, so the
  /// next try carries on.
  Future<RetroHostDownload> fetch(
    UpstreamRelease? release, {
    Set<RetroHostCorePackage> cores = const {},
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
        tag: release.tag,
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
    await _fetchAssets(
      release,
      [
        signed.filesName,
        signed.zipName,
        for (final core in cores.intersection(signed.cores)) ...[
          core.filesName(signed.version, target),
          core.zipName(signed.version, target),
        ],
      ],
      download,
      signed.sums,
      onProgress: onProgress,
      cancel: cancel,
      client: client,
    );
    return (folder: download, tag: release.tag);
  }

  /// Fetches [names] of [release] into [download], each against its digest in [sums], with one
  /// progress for them all.
  Future<void> _fetchAssets(
    UpstreamRelease release,
    List<String> names,
    Directory download,
    SignedSums sums, {
    void Function(ToolkitProgress)? onProgress,
    DownloadCancel? cancel,
    HttpClient Function()? client,
  }) async {
    final assets = [
      for (final name in names)
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
        sha256: sums.digestFor(asset.name),
        cancel: cancel,
        client: client,
        onProgress: (received) => onProgress?.call(ToolkitProgress(ToolkitPhase.download, start + received, total)),
      );
      before += asset.size;
    }
    if (cancel?.cancelled ?? false) throw ToolkitFailure(ToolkitFailureKind.cancelled, 'the download was stopped');
  }

  /// The tag the installed host was published under, as kept beside it; null without one.
  String? get installedTag {
    try {
      return File(p.join(folder.path, RetroHostRelease.tagName)).readAsStringSync();
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  /// Downloads [core]'s package from [release], which must be the installed host's own (its tag
  /// the one kept beside the host), into `.downloads/<tag>-<core>`, and gives that folder;
  /// [putCoreInPlace] then adds it. Its zip and `.files` are fetched against the digests of the
  /// installed host's SHA256SUMS, whose signature and tag are checked first, so no other
  /// release's package is taken. A release without that package is not available.
  Future<RetroHostDownload> fetchCore(
    UpstreamRelease? release,
    RetroHostCorePackage core, {
    void Function(ToolkitProgress)? onProgress,
    DownloadCancel? cancel,
    HttpClient Function()? client,
  }) async {
    final target = system;
    if (target == null) {
      throw ToolkitFailure(ToolkitFailureKind.notAvailable, 'no emulator host is released for this system');
    }
    final RetroHostSignedRelease installed;
    try {
      installed = RetroHostRelease.installedRelease(folder, keys: keys, system: target);
    } on RetroHostReleaseFailure catch (failure) {
      throw ToolkitFailure(ToolkitFailureKind.signature, 'the installed host: ${failure.message}');
    }
    if (release == null || release.tag != 'v${installed.version}') {
      throw ToolkitFailure(ToolkitFailureKind.notAvailable, 'the release of host ${installed.version} was not found');
    }
    if (!installed.cores.contains(core)) {
      throw ToolkitFailure(ToolkitFailureKind.notAvailable, '${release.tag} has no ${core.name} package');
    }
    final download = Directory(p.join(_downloads, '${release.tag}-${core.name}'));
    download.createSync(recursive: true);
    await _fetchAssets(
      release,
      [core.filesName(installed.version, target), core.zipName(installed.version, target)],
      download,
      installed.sums,
      onProgress: onProgress,
      cancel: cancel,
      client: client,
    );
    return (folder: download, tag: release.tag);
  }

  /// Adds what [fetchCore] downloaded beside the installed host, through
  /// [RetroHostRelease.addCore], which checks it all again from the files on disk. Stop the host
  /// first.
  Future<void> putCoreInPlace(RetroHostDownload download, RetroHostCorePackage core) async {
    try {
      await RetroHostRelease.addCore(download.folder, folder, core, keys: keys, system: system);
    } on RetroHostReleaseFailure catch (failure) {
      throw ToolkitFailure(ToolkitFailureKind.badLayout, failure.message);
    } on FileSystemException catch (failure) {
      throw ToolkitFailure(
        ToolkitFailureKind.badLayout,
        '${core.name} could not be written: ${failure.osError?.message ?? failure.message}',
      );
    }
    _forget(download.folder);
  }

  /// Removes [core]'s package from beside the installed host ([RetroHostRelease.removeCore]).
  /// Stop the host first: on Windows its files are held while it runs.
  void removeCore(RetroHostCorePackage core) {
    final target = system;
    if (target == null) return;
    try {
      RetroHostRelease.removeCore(folder, core, keys: keys, system: target);
    } on RetroHostReleaseFailure catch (failure) {
      throw ToolkitFailure(ToolkitFailureKind.badLayout, failure.message);
    } on FileSystemException catch (failure) {
      throw ToolkitFailure(
        ToolkitFailureKind.badLayout,
        '${core.name} could not be removed: ${failure.osError?.message ?? failure.message}',
      );
    }
  }

  /// Installs what [fetch] downloaded in place of the installed host, through
  /// [RetroHostRelease.install], which checks it all again from the files on disk before it
  /// unpacks, its signed version against the tag included; gives its version. Each of [cores] the
  /// new release has is put in place in the same step; one it lacks is gone afterwards. Stop the
  /// host first: on Windows its files are held while it runs, and the install then fails with the
  /// installed host left whole.
  Future<RetroHostVersion> putInPlace(RetroHostDownload download, {Set<RetroHostCorePackage> cores = const {}}) async {
    final RetroHostVersion version;
    try {
      version = await RetroHostRelease.install(
        download.folder,
        folder,
        tag: download.tag,
        keys: keys,
        system: system,
        cores: cores,
      );
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
