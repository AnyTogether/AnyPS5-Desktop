import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/audio/tones.dart';
import '../core/ffmpeg_download.dart';
import '../core/replay_buffer.dart';
import '../core/toolkit_download.dart';
import 'app_model.dart';
import 'components.dart';
import 'strings.dart';

/// Why the launcher offers its own ffmpeg.
enum FfmpegNeed {
  /// None was found beside the launcher or on the PATH.
  missing,

  /// One was found, but no H.264 encoder works with it here.
  noEncoder,
}

/// ffmpeg for everything that records or decodes: one already on this computer when there is one,
/// else the one the launcher downloads, once the user presses for it. It comes from a signed
/// pre-release of this repository and is checked as the engines are; see [FfmpegStore].
class FfmpegModel {
  FfmpegModel(this.app) : store = FfmpegStore(_folder(app), system: app.system, run: app.services.ffmpegRun) {
    _downloaded = store.installed();
  }

  /// The launcher's data folder, beside the toolkits.
  static String _folder(AppModel app) => p.join(p.dirname(app.paths.toolkits), 'FFmpeg');

  final AppModel app;
  final FfmpegStore store;

  /// ffmpeg beside the launcher, else on the PATH; found once, at the first ask.
  late final String? systemFfmpeg = ReplayBuffer.locate(
    system: app.system,
    environment: app.services.environment ?? Platform.environment,
    launcherFolder: p.dirname(Platform.resolvedExecutable),
  );

  String? _downloaded;
  bool _noEncoder = false;
  Future<bool>? _x264;

  /// The ffmpeg the features use: the system's first, unless it could not encode and the
  /// launcher's was taken instead.
  String? get path {
    final system = systemFfmpeg;
    final downloaded = _downloaded;
    if (downloaded != null && (system == null || store.preferred)) return downloaded;
    return system ?? downloaded;
  }

  /// Why a download is worth offering, null when ffmpeg is fine as it is.
  FfmpegNeed? get need {
    if (path == null) return FfmpegNeed.missing;
    return _noEncoder && path == systemFfmpeg ? FfmpegNeed.noEncoder : null;
  }

  /// Whether the launcher can offer its own ffmpeg now.
  bool get offered => need != null && app.services.ffmpegReleases != null;

  /// The last download or check found no signed release yet.
  bool notYet = false;

  /// Why the last download failed; a sentence, or null.
  String? error;

  ToolkitProgress? progress;
  DownloadCancel? _cancel;
  bool get downloading => _cancel != null;

  /// [tool] is the ffmpeg on this computer and no H.264 encoder works with it: the launcher's own
  /// has x264, which runs on the processor.
  void noteNoEncoder(String tool) {
    if (tool != systemFfmpeg || _noEncoder) return;
    _noEncoder = true;
    app.refresh();
  }

  /// Whether the ffmpeg on this computer is in use and has no x264, which clip tools need; says so
  /// to [noteNoEncoder] when it has none.
  Future<bool> systemLacksX264() async {
    final tool = systemFfmpeg;
    if (tool == null || path != tool) return false;
    final lacks = await (_x264 ??= _lacksX264(tool));
    if (lacks) noteNoEncoder(tool);
    return lacks;
  }

  Future<bool> _lacksX264(String tool) async {
    try {
      final run = app.services.ffmpegRun ?? ((executable, arguments) => Process.run(executable, arguments));
      final result = await run(tool, const ['-hide_banner', '-encoders']).timeout(const Duration(seconds: 10));
      return result.exitCode == 0 && !'${result.stdout}'.contains(' libx264 ');
    } on Object {
      return false;
    }
  }

  /// Downloads, checks and puts the launcher's ffmpeg in place. Runs only when the user pressed
  /// for it; said to the user however it ends.
  Future<void> download() async {
    if (downloading) return;
    final source = app.services.ffmpegReleases;
    if (source == null) return;
    final needed = need;
    if (needed == null) return;
    // Downloaded before, and only passed over because the system has one.
    if (needed == FfmpegNeed.noEncoder && _downloaded != null) return _useDownloaded();
    final cancel = DownloadCancel();
    _cancel = cancel;
    error = null;
    notYet = false;
    progress = ToolkitProgress(ToolkitPhase.download, 0, FfmpegBuild.approximateBytes(app.system));
    app.refresh();
    var shown = -1;
    try {
      final release = await source.byTag(FfmpegBuild.tag);
      _downloaded = await store.install(
        release,
        cancel: cancel,
        onProgress: (next) {
          progress = next;
          final step = (next.fraction * 200).floor() + next.phase.index * 1000;
          if (step != shown) {
            shown = step;
            app.refresh();
          }
        },
      );
      if (needed == FfmpegNeed.noEncoder) store.prefer();
      _noEncoder = false;
      app.sounds.play(Cue.unlocked);
      app.show(T.text('ffmpegReady'));
    } on ToolkitFailure catch (failure) {
      switch (failure.kind) {
        case ToolkitFailureKind.cancelled:
          break;
        case ToolkitFailureKind.notAvailable:
          notYet = true;
          app.show(T.text('ffmpegNotYet'));
        default:
          error = failure.message;
          app.show(T.format('ffmpegFailed', [failure.message]));
      }
    } finally {
      _cancel = null;
      progress = null;
      app.refresh();
    }
  }

  void _useDownloaded() {
    store.prefer();
    _noEncoder = false;
    app.show(T.text('ffmpegReady'));
    app.refresh();
  }

  /// Stops the download; what came is kept, to carry on next time.
  void cancel() => _cancel?.cancel();

  /// The row a feature that needs ffmpeg shows under its own: one press to download, then how it
  /// goes, what went wrong, or nothing at all when ffmpeg is fine.
  List<PanelRow> rows() {
    if (downloading) {
      return [
        PanelRow(
          id: 'ffmpeg-download',
          title: T.format('ffmpegDownloading', [((progress?.fraction ?? 0) * 100).floor()]),
          detail: T.format('ffmpegProgress', [_progressText()]),
          kind: ActionRow(cancel),
        ),
      ];
    }
    final needed = offered ? need : null;
    if (needed == null) return const [];
    return [
      PanelRow(
        id: 'ffmpeg-download',
        title: T.text('ffmpegDownload'),
        detail:
            error ??
            (notYet
                ? T.text('ffmpegNotYet')
                : T.format(needed == FfmpegNeed.missing ? 'ffmpegOffer' : 'ffmpegOfferNoEncoder', [
                    byteText(FfmpegBuild.approximateBytes(app.system)),
                  ])),
        kind: ActionRow(() => unawaited(download())),
      ),
    ];
  }

  String _progressText() {
    final now = progress;
    if (now == null) return '';
    return switch (now.phase) {
      ToolkitPhase.download => T.format('engineProgress', [byteText(now.received), byteText(now.total)]),
      ToolkitPhase.unpack => T.text('engineUnpacking'),
      ToolkitPhase.finish => T.text('ffmpegChecking'),
    };
  }
}
