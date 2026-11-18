import 'dart:async';
import 'dart:io';

import '../../core/audio/tones.dart';
import '../../core/retro_host/retro_host_release.dart';
import '../../core/toolkit_download.dart';
import '../app_model.dart';
import '../strings.dart';
import 'retro_host_download_model.dart';

/// A core package as an emulator of its own: today the PS2 emulator, LRPS2, which the player adds
/// beside the installed host from the host's own release and removes again (protocol.md "Finding
/// and checking the host", "Adding a core package"). A player who never adds it never downloads
/// it. It moves with the host: a host update puts in place the same packages from the new release
/// ([RetroHostDownloadModel.download]). Offered only while the installed host's release has the
/// package, so never for a host 1.0.0.
class RetroHostCoreDownloadModel {
  RetroHostCoreDownloadModel(this.host, this.core);

  /// The host download the package is added beside.
  final RetroHostDownloadModel host;
  final RetroHostCorePackage core;

  AppModel get app => host.app;

  /// Whether the package is added beside the installed host, as the host's last look found it.
  bool get installed => host.installed != null && host.installedCores.contains(core);

  /// Whether the player can add it: a signed host is installed and its release has the package.
  bool get offered => host.offered && host.installed != null && host.offeredCores.contains(core);

  /// Why the last download failed; a sentence, or null.
  String? error;

  /// The installed host's release could not be found on GitHub, or lacks the package.
  bool notYet = false;

  ToolkitProgress? progress;
  DownloadCancel? _cancel;
  bool get downloading => _cancel != null;

  /// The checked files are being written beside the host: past the point of stopping.
  bool placing = false;

  bool _removing = false;

  /// A download or a removal is under way: the host is not downloaded meanwhile.
  bool get busy => downloading || _removing;

  /// Whether a change to the host's folder must wait: the host or this package is being changed,
  /// or the launcher is going.
  bool get _blocked => busy || host.downloading || host.installing || host.closed;

  /// Downloads the package from the installed host's release, checks it against the SHA256SUMS
  /// kept beside the host and adds it there, the host kept for the next game shut down first.
  /// The first one added turns its games on (Run PS2 games in the separate host). Runs only when
  /// the player pressed for it; said to the player however it ends.
  Future<void> add() async {
    if (_blocked) return;
    final source = app.services.retroHostReleases;
    if (source == null) return;
    if (host.hostInUse) {
      app.show(T.text('retroHostPs2CloseGame'));
      return;
    }
    final cancel = DownloadCancel();
    _cancel = cancel;
    error = null;
    notYet = false;
    progress = const ToolkitProgress(ToolkitPhase.download, 0, 0);
    app.refresh();
    var shown = -1;
    try {
      final tag = host.store.installedTag;
      final release = (await source.all()).where((release) => release.tag == tag).firstOrNull;
      final download = await host.store.fetchCore(
        release,
        core,
        cancel: cancel,
        onProgress: (next) {
          progress = next;
          final step = (next.fraction * 200).floor();
          if (step != shown) {
            shown = step;
            app.refresh();
          }
        },
      );
      if (host.closed) return;
      progress = const ToolkitProgress(ToolkitPhase.unpack, 1, 1);
      host.installing = true;
      app.refresh();
      if (host.hostInUse) throw ToolkitFailure(ToolkitFailureKind.badLayout, T.text('retroHostPs2CloseGame'));
      await app.stopKeptRetroHost();
      if (host.hostInUse) throw ToolkitFailure(ToolkitFailureKind.badLayout, T.text('retroHostPs2CloseGame'));
      if (host.closed) return;
      if (cancel.cancelled) throw ToolkitFailure(ToolkitFailureKind.cancelled, 'the download was stopped');
      placing = true;
      app.refresh();
      try {
        await host.store.putCoreInPlace(download, core);
      } on Object {
        host.lookAgain();
        rethrow;
      }
      if (!app.preferences.retroHostPs2) {
        app.preferences.retroHostPs2 = true;
        app.savePreferences();
      }
      host.lookAgain();
      app.sounds.play(Cue.unlocked);
      app.show(T.format('retroHostPs2Ready', ['${host.version}']));
    } on FileSystemException catch (failure) {
      error = failure.osError?.message ?? failure.message;
      app.show(T.format('retroHostPs2DownloadFailed', [error!]));
    } on ToolkitFailure catch (failure) {
      switch (failure.kind) {
        case ToolkitFailureKind.cancelled:
          break;
        case ToolkitFailureKind.notAvailable:
          notYet = true;
          app.show(T.text('retroHostPs2NotYet'));
        default:
          error = failure.message;
          app.show(T.format('retroHostPs2DownloadFailed', [failure.message]));
      }
    } finally {
      host.installing = false;
      placing = false;
      _cancel = null;
      progress = null;
      app.refresh();
    }
  }

  /// Removes the package from beside the host, the host kept for the next game shut down first.
  /// Its games' setting, BIOS, memory cards and save states stay.
  Future<void> remove() async {
    if (_blocked || !installed) return;
    if (host.hostInUse) {
      app.show(T.text('retroHostPs2CloseGame'));
      return;
    }
    _removing = true;
    host.installing = true;
    app.refresh();
    try {
      await app.stopKeptRetroHost();
      if (host.hostInUse) throw ToolkitFailure(ToolkitFailureKind.badLayout, T.text('retroHostPs2CloseGame'));
      host.store.removeCore(core);
      app.show(T.text('retroHostPs2Removed'));
    } on ToolkitFailure catch (failure) {
      app.show(T.format('retroHostPs2RemoveFailed', [failure.message]));
    } finally {
      _removing = false;
      host.installing = false;
      host.lookAgain();
      app.refresh();
    }
  }

  /// Stops the download; what came is kept, to carry on next time. Once the files are being
  /// written it runs to the end.
  void cancel() {
    if (!placing) _cancel?.cancel();
  }

  /// Settings › Emulators' row for the package, beside the host's own: one press to download it,
  /// then how it goes; once added, its version, which is the host's, and a press looks for a
  /// newer release of both, as the host's row does. Nothing where it is not offered, or the
  /// unchecked host `ANYPS5_RETRO_HOST` names is used.
  List<PanelRow> rows({required bool uncheckedHost}) {
    if (uncheckedHost || !offered) return const [];
    if (downloading) {
      return [
        retroDownloadProgressRow(
          id: 'retro-host-ps2-download',
          title: 'retroHostPs2Downloading',
          progress: progress,
          placing: placing,
          cancel: cancel,
        ),
      ];
    }
    if (installed) {
      return [
        PanelRow(
          id: 'retro-host-ps2-download',
          title: T.format('retroHostPs2Installed', ['${host.version}']),
          detail: T.text('retroHostPs2InstalledDetail'),
          kind: ActionRow(() => unawaited(host.download())),
        ),
      ];
    }
    return [
      PanelRow(
        id: 'retro-host-ps2-download',
        title: T.text('retroHostPs2Download'),
        detail: error ?? T.text(notYet ? 'retroHostPs2NotYet' : 'retroHostPs2DownloadDetail'),
        kind: ActionRow(() => unawaited(add())),
      ),
    ];
  }

  /// The row that removes the package, once it is added and nothing else changes the host.
  List<PanelRow> removeRows({required bool uncheckedHost}) {
    if (uncheckedHost || !installed || busy) return const [];
    return [
      PanelRow(
        id: 'retro-host-ps2-remove',
        title: T.text('retroHostPs2Remove'),
        detail: T.text('retroHostPs2RemoveDetail'),
        kind: ActionRow(() => unawaited(remove()), destructive: true),
      ),
    ];
  }
}
