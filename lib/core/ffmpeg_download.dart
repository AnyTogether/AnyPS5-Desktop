import 'dart:io';

import 'package:path/path.dart' as p;

import 'host.dart';
import 'replay_buffer.dart' show ProcessRunner;
import 'toolkit_download.dart';

/// The one ffmpeg build the launcher offers: FFmpeg's release branch as built by
/// BtbN/FFmpeg-Builds (GPL, static), repacked with its licence and a link to its source and
/// published as a pre-release of this repository by .github/workflows/ffmpeg-release.yml, which
/// also pins that build (packaging/ffmpeg/pinned.env). Like the launcher's own releases, it is
/// signed on the release Mac; until then it is not offered.
abstract final class FfmpegBuild {
  /// The pre-release that carries it: a tag no update channel reads (ReleaseVersion.parse says no).
  static const tag = 'ffmpeg-8.1.3-27-g8dca1586f4';

  /// FFmpeg's version, for people.
  static const version = '8.1.3';

  static const repository = 'AnyTogether/AnyPS5-Desktop';

  /// The archive on the release for [system]: ffmpeg and its licences at its top.
  static String assetName(HostSystem system) =>
      system == HostSystem.windows ? 'anyps5-ffmpeg-windows-x64.zip' : 'anyps5-ffmpeg-linux-x64.tar.gz';

  static String executableName(HostSystem system) => system == HostSystem.windows ? 'ffmpeg.exe' : 'ffmpeg';

  /// About what the download weighs, measured on the pinned build; said before it starts.
  static int approximateBytes(HostSystem system) => system == HostSystem.windows ? 61 * 1024 * 1024 : 65 * 1024 * 1024;
}

/// The ffmpeg the launcher downloaded, next to the toolkits:
///
/// ```text
/// FFmpeg/
///     ffmpeg-8.1.3-…/     ffmpeg[.exe], LICENSE.txt, SOURCE.txt, …
///     preferred           present: this one is used even when another ffmpeg is on the PATH
///     .downloads/         files on their way, kept to carry on after a restart
///     .staging-…/         being laid out
/// ```
class FfmpegStore {
  FfmpegStore(this.root, {required this.system, ProcessRunner? run})
    : _run = run ?? ((executable, arguments) => Process.run(executable, arguments));

  final String root;
  final HostSystem system;
  final ProcessRunner _run;

  String get _downloads => p.join(root, '.downloads');
  String get _preferred => p.join(root, 'preferred');
  String _executable(String folder) => p.join(folder, FfmpegBuild.executableName(system));

  /// The downloaded ffmpeg, the pinned build first; null when there is none.
  String? installed() {
    final pinned = _executable(p.join(root, FfmpegBuild.tag));
    if (File(pinned).existsSync()) return pinned;
    try {
      for (final folder in Directory(root).listSync().whereType<Directory>()) {
        if (p.basename(folder.path).startsWith('.')) continue;
        final executable = _executable(folder.path);
        if (File(executable).existsSync()) return executable;
      }
    } on FileSystemException {
      // Nothing downloaded yet.
    }
    return null;
  }

  /// Whether the downloaded ffmpeg goes before one found on the system.
  bool get preferred => File(_preferred).existsSync();

  /// Uses the downloaded ffmpeg even when the system has one: that one could not encode.
  void prefer() {
    Directory(root).createSync(recursive: true);
    File(_preferred).writeAsStringSync('');
  }

  /// Fetches the pinned build from [release], checks it against the release's signed sums, lays it
  /// out and checks that it runs here; the path of the executable.
  ///
  /// Nothing is downloaded from a release that is not signed: [release] null or without
  /// SHA256SUMS and SHA256SUMS.sig is reported as not available yet, a bad signature as refused.
  /// There is no way to take it unsigned.
  Future<String> install(
    UpstreamRelease? release, {
    void Function(ToolkitProgress)? onProgress,
    DownloadCancel? cancel,
    HttpClient Function()? client,
  }) async {
    void stopIfCancelled() {
      if (cancel?.cancelled ?? false) throw ToolkitFailure(ToolkitFailureKind.cancelled, 'the download was stopped');
    }

    if (release == null || release.signatureFiles == null) {
      throw ToolkitFailure(ToolkitFailureKind.notAvailable, 'the ffmpeg download has not been published yet');
    }
    final asset = release.named(FfmpegBuild.assetName(system));
    if (asset == null) {
      throw ToolkitFailure(ToolkitFailureKind.notAvailable, 'the ffmpeg release has no file for this system');
    }
    final sums = await SignedRelease.sums(release, _downloads, cancel: cancel, client: client);
    final digest = SignedRelease.digestOf(sums, asset);
    final archive = p.join(_downloads, asset.name);
    await AssetDownload.fetch(
      asset.url,
      archive,
      size: asset.size,
      sha256: digest,
      cancel: cancel,
      client: client,
      onProgress: (received) => onProgress?.call(ToolkitProgress(ToolkitPhase.download, received, asset.size)),
    );
    stopIfCancelled();
    onProgress?.call(ToolkitProgress(ToolkitPhase.unpack, asset.size, asset.size));
    final staging = p.join(root, '.staging-${release.tag}');
    final folder = p.join(root, release.tag);
    if (Directory(staging).existsSync()) Directory(staging).deleteSync(recursive: true);
    try {
      await SafeUnpack.unpack(archive, staging);
      stopIfCancelled();
      final executable = _executable(staging);
      if (!File(executable).existsSync()) {
        throw ToolkitFailure(ToolkitFailureKind.badLayout, 'the archive has no ${p.basename(executable)}');
      }
      if (!Platform.isWindows) Process.runSync('chmod', ['755', executable]);
      onProgress?.call(ToolkitProgress(ToolkitPhase.finish, asset.size, asset.size));
      await _checkRuns(executable);
      stopIfCancelled();
      if (Directory(folder).existsSync()) Directory(folder).deleteSync(recursive: true);
      Directory(staging).renameSync(folder);
    } finally {
      if (Directory(staging).existsSync()) Directory(staging).deleteSync(recursive: true);
    }
    if (File(archive).existsSync()) File(archive).deleteSync();
    _removeOthers(keep: release.tag);
    return _executable(folder);
  }

  /// `ffmpeg -version` must work: a build that cannot start here (a system too old for it, or a
  /// blocked executable) is said now and not when a feature needs it.
  Future<void> _checkRuns(String executable) async {
    final ProcessResult result;
    try {
      result = await _run(executable, const ['-hide_banner', '-version']).timeout(const Duration(seconds: 30));
    } on Object catch (error) {
      throw ToolkitFailure(
        ToolkitFailureKind.badLayout,
        'the downloaded ffmpeg does not start on this computer: $error',
      );
    }
    if (result.exitCode != 0) {
      final line = '${result.stderr}'.trim().split('\n').firstOrNull ?? '';
      throw ToolkitFailure(
        ToolkitFailureKind.badLayout,
        'the downloaded ffmpeg does not start on this computer (exit ${result.exitCode}): $line',
      );
    }
  }

  void _removeOthers({required String keep}) {
    try {
      for (final folder in Directory(root).listSync().whereType<Directory>()) {
        final name = p.basename(folder.path);
        if (name == keep) continue;
        if (name.startsWith('.staging-') || !name.startsWith('.')) folder.deleteSync(recursive: true);
      }
    } on FileSystemException {
      // Left for next time.
    }
  }
}
