import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/app_update.dart';
import '../core/audio/tones.dart';
import '../core/gamepad/feel.dart' show HapticCue;
import '../core/host.dart';
import '../core/package_install.dart';
import '../core/toolkit_download.dart';
import '../core/update_channel.dart';
import '../core/update_notice.dart';
import '../core/together/account.dart';
import 'app_model.dart';
import 'components.dart';
import 'strings.dart';
import 'together_model.dart' show launcherVersion;

/// New versions of AnyPS5 Desktop itself: looked for at the start, every six hours while the
/// launcher stays open and when it comes back to the front after half an hour (while Settings ›
/// Behaviour › Check for updates is on); a newer one is
/// downloaded quietly and checked against the release's signature, then a quiet notice on the
/// home screen offers Restart Now and Later (the next launch). Settings › About shows where it
/// stands. A copy a package manager installed (Scoop, pacman) is that package manager's to
/// update: a newer release is said, with how to get it, and nothing is downloaded.
class LauncherUpdateModel {
  LauncherUpdateModel(this.app);

  final AppModel app;

  static const every = Duration(hours: 6);
  static const afterAway = Duration(minutes: 30);

  /// What GitHub said last, and when it last answered.
  UpstreamRelease? latest;
  DateTime? lastCheck;
  bool checking = false;
  String? checkError;

  /// The download in progress: bytes so far of [total].
  int? received;
  int total = 0;
  DownloadCancel? _cancel;

  /// The checked download, once there, and the version it is.
  String? downloaded;
  String? downloadedVersion;

  /// Why the last download failed.
  String? error;

  /// Later on the home screen's notice, by version.
  final UpdateNotice notice = UpdateNotice();

  /// Restart Now with a game running: the restart waits for the game to close.
  bool restartAfterGame = false;

  Timer? _timer;

  GitHubReleases? get _source => app.services.launcherReleases;

  /// The version this launcher is.
  String get current => launcherVersion;

  bool get available => latest != null && LauncherUpdates.isNewer(latest!, current);

  String? get _appImagePath {
    final path = (app.services.environment ?? Platform.environment)['APPIMAGE'];
    return path == null || path.isEmpty ? null : path;
  }

  bool get _appImage => _appImagePath != null;

  /// The package manager that installed this copy, looked for once.
  late final PackageManager? managedBy =
      (app.services.packageManager ??
      () => PackageInstall.detect(app.system, environment: app.services.environment ?? Platform.environment))();

  /// The newest release's file for this system; none for a package manager's copy.
  ReleaseAsset? get asset =>
      latest == null || managedBy != null ? null : LauncherUpdates.assetFor(latest!, app.system, appImage: _appImage);

  /// What the toast says of [version] for a package manager's copy: the command, or the package
  /// manager.
  String _managedNews(String version) => switch (managedBy?.command) {
    final command? => T.format('desktopUpdateWithCommand', [version, command]),
    null => T.format('desktopUpdateWithPackageManager', [version]),
  };

  /// About's row for a package manager's copy: how it updates, and the command copied on select.
  PanelRow _managedRow(String id, String version) {
    final command = managedBy?.command;
    return PanelRow(
      id: id,
      title: T.format('desktopUpdateOut', [version]),
      detail: command == null ? T.text('desktopUpdatePackageDetail') : T.format('desktopUpdateScoopDetail', [command]),
      kind: command == null
          ? const InfoRow('')
          : ActionRow(() {
              app.services.copyText?.call(command);
              app.show(T.text('padCopied'));
            }),
    );
  }

  /// Where downloads are kept.
  String get folder => p.join(app.paths.cache, 'Updates');

  /// The update ready: downloaded for the newest version.
  String? get _ready =>
      downloaded != null && available && downloadedVersion == latest!.version ? downloadedVersion : null;

  LauncherUpdateState get state => LauncherUpdateState.of(
    checking: checking,
    newer: available ? latest!.version : null,
    progress: received == null ? null : (total <= 0 ? 0 : received! / total),
    ready: _ready,
    lastCheck: lastCheck,
    failed: checkError != null,
  );

  /// How the ready download goes in: the installer, the AppImage swapped, or by the user.
  SelfApply get apply =>
      SelfApply.of(windows: app.system == HostSystem.windows, appImage: _appImage, file: downloaded ?? '');

  /// The home screen's quiet notice: an update ready, or a restart waiting for the game.
  bool get showsNotice => restartAfterGame || notice.shows(state);

  /// Asks GitHub for the newest release; without [quiet], says what came of it.
  Future<void> check({bool quiet = false}) async {
    final source = _source;
    if (source == null || checking) return;
    checking = true;
    checkError = null;
    app.refresh();
    try {
      // Stable: the release GitHub calls latest. Nightly: the newest signed one for this system
      // of the recent ones, pre-releases too, in the order releases come out.
      // A package manager's copy follows Stable, the releases the package manager gets.
      latest = app.updateChannel == UpdateChannel.nightly && managedBy == null
          ? LauncherUpdates.newestNightly(await source.all(), app.system, appImage: _appImage)
          : await source.latest();
      lastCheck = DateTime.now();
      if (!quiet) {
        app.show(switch (available) {
          true when managedBy != null => _managedNews(latest!.version),
          true => T.format('desktopUpdateAvailable', [latest!.version]),
          false when ChannelReleases.stays(app.updateChannel, current) => T.format('updateChannelStays', [current]),
          false => T.format('desktopUpToDate', [current]),
        });
      }
    } on ToolkitFailure catch (failure) {
      checkError = failure.message;
      if (!quiet) app.show(T.text('updateCheckFailed'));
    } finally {
      checking = false;
      app.refresh();
    }
  }

  /// The update channel changed: what the other channel found no longer counts (a download
  /// ready for it is no longer offered, since [latest] names another release), and the new
  /// channel is asked at once.
  void channelChanged() {
    latest = null;
    unawaited(check());
  }

  /// At start: a quiet look, then the same every six hours while the launcher stays open.
  Future<void> startupCheck() async {
    if (_source == null) return;
    _timer ??= Timer.periodic(every, (_) => unawaited(periodicCheck()));
    await periodicCheck(first: true);
  }

  /// A quiet look; a newer release with a file for this system is downloaded at once (its
  /// notice comes once it is ready), one without (or any, for a package manager's copy) is said
  /// once.
  Future<void> periodicCheck({bool first = false}) async {
    // Settings › Behaviour › Check for updates off: only Check for Updates Now asks.
    if (!app.preferences.checkUpdates) return;
    final before = latest?.version;
    await check(quiet: true);
    if (!available) return;
    if (asset == null) {
      if (first || before != latest!.version) {
        app.show(
          managedBy != null ? _managedNews(latest!.version) : T.format('desktopUpdateAvailable', [latest!.version]),
        );
      }
      return;
    }
    if (_ready == null && received == null) await download(quiet: true);
  }

  /// The launcher came back to the front: asked again after half an hour away.
  void activated() {
    if (_source == null || checking || received != null || !app.preferences.checkUpdates) return;
    final last = lastCheck;
    if (last != null && DateTime.now().difference(last) < afterAway) return;
    unawaited(periodicCheck());
  }

  /// Downloads the newest release's file once its signature checked out.
  Future<void> download({bool quiet = false}) async {
    final release = latest;
    final file = asset;
    if (release == null || file == null || received != null) return;
    final cancel = DownloadCancel();
    _cancel = cancel;
    received = 0;
    total = file.size;
    error = null;
    app.refresh();
    var shown = -1;
    try {
      downloaded = await LauncherUpdates.download(
        release,
        file,
        folder,
        cancel: cancel,
        onProgress: (bytes) {
          received = bytes;
          final step = total <= 0 ? 0 : bytes * 100 ~/ total;
          if (step != shown) {
            shown = step;
            app.refresh();
          }
        },
      );
      downloadedVersion = release.version;
    } on ToolkitFailure catch (failure) {
      if (failure.kind != ToolkitFailureKind.cancelled) {
        error = failure.message;
        // The periodic check says nothing over a game or a screen; About shows it.
        if (!quiet) app.show(T.format('desktopUpdateFailed', [failure.message]));
      }
    } finally {
      received = null;
      _cancel = null;
      app.refresh();
    }
  }

  void cancel() => _cancel?.cancel();

  /// Restart Now: the update goes in and the launcher opens again on it; with a game running,
  /// the restart waits for the game to close. A download only the user can put in place is shown.
  Future<void> restartNow() async {
    final file = downloaded;
    if (_ready == null || file == null) return;
    if (apply == SelfApply.manual) {
      app.services.openFolder?.call(p.dirname(file));
      return;
    }
    switch (UpdateRestart.decide(gameRunning: app.running != null || app.starting != null)) {
      case UpdateRestart.afterGame:
        restartAfterGame = true;
        app.refresh();
      case UpdateRestart.now:
        restartAfterGame = false;
        app.sounds.play(Cue.select);
        try {
          if (apply == SelfApply.installer) {
            await (app.services.startDetached ?? _startDetached)(file, SelfApply.installerArguments);
          } else {
            final appImage = _appImagePath!;
            LauncherUpdates.swapAppImage(file, appImage);
            await (app.services.startDetached ?? _startDetached)(appImage, const []);
          }
          (app.services.quit ?? exit)(0);
        } on Object catch (failure) {
          app.vibrate(HapticCue.error);
          app.show(T.format('desktopUpdateApplyFailed', ['$failure']));
        }
    }
  }

  static Future<void> _startDetached(String executable, List<String> arguments) =>
      Process.start(executable, arguments, mode: ProcessStartMode.detached);

  void cancelRestart() {
    restartAfterGame = false;
    app.refresh();
  }

  /// Later: the update goes in at the next launch (the installer then runs first, an AppImage is
  /// swapped now, the running copy keeps going), and the notice does not come back for it.
  void later() {
    final file = downloaded;
    final version = _ready;
    notice.later(state);
    restartAfterGame = false;
    app.sounds.play(Cue.back);
    if (file != null && version != null) {
      try {
        switch (apply) {
          case SelfApply.installer:
            LauncherUpdates.writePending(folder, version, file);
          case SelfApply.appImage:
            LauncherUpdates.swapAppImage(file, _appImagePath!);
          case SelfApply.manual:
            break;
        }
      } on Object catch (failure) {
        app.show(T.format('desktopUpdateApplyFailed', ['$failure']));
      }
    }
    app.refresh();
  }

  /// A game closed while a restart waited for it: a moment for its saves, then the restart.
  void gameEnded() {
    if (!restartAfterGame) return;
    Timer(const Duration(seconds: 5), () {
      if (restartAfterGame && app.running == null && app.starting == null) unawaited(restartNow());
    });
  }

  /// At launch, before the window: an installer left by Later runs now (silently, opening the
  /// launcher again after it) and this launcher quits. True when it did. Never for a package
  /// manager's copy, which would get a second copy beside it.
  Future<bool> applyPendingAtLaunch() async {
    if (app.system != HostSystem.windows || managedBy != null) return false;
    final installer = LauncherUpdates.takePending(folder, current);
    if (installer == null) return false;
    try {
      await (app.services.startDetached ?? _startDetached)(installer, SelfApply.installerArguments);
      return true;
    } on Object {
      return false;
    }
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _cancel?.cancel();
  }

  /// The page of [release] on GitHub, where its notes are.
  static Uri _page(UpstreamRelease release) =>
      Uri.https('github.com', '${LauncherUpdates.repository}/releases/tag/${release.tag}');

  /// The About rows: the version, the update where it stands (at most one row that acts) and
  /// the check.
  List<PanelRow> aboutRows() {
    final release = latest;
    final file = asset;
    final now = state;
    return [
      switch (now) {
        UpdateDownloading(:final version, :final percent) => PanelRow(
          id: 'desktopUpdate',
          title: T.format('desktopUpdateDownloading', [version, percent]),
          detail: T.format('engineProgress', [byteText(received ?? 0), byteText(total)]),
          kind: ActionRow(cancel),
        ),
        UpdateReady() when restartAfterGame => PanelRow(
          id: 'desktopUpdate',
          title: T.text('desktopRestartWaiting'),
          detail: T.text('desktopCancelRestart'),
          kind: ActionRow(cancelRestart),
        ),
        UpdateReady(:final version) when apply == SelfApply.manual => PanelRow(
          id: 'desktopUpdate',
          title: T.format('desktopNoticeDownloaded', [version]),
          detail: downloaded,
          kind: ActionRow(() => unawaited(restartNow())),
        ),
        UpdateReady(:final version) => PanelRow(
          id: 'desktopUpdate',
          title: '${T.format('desktopNoticeReady', [version])} · ${T.text('desktopRestartNow')}',
          detail: T.text('desktopUpdateLaterDetail'),
          kind: ActionRow(() => unawaited(restartNow())),
        ),
        UpdateAvailable(:final version) when managedBy != null => _managedRow('desktopUpdate', version),
        UpdateAvailable(:final version) when file != null => PanelRow(
          id: 'desktopUpdate',
          title: T.format('desktopUpdateTo', [version]),
          detail: error ?? T.format('desktopUpdateDetail', [file.name, byteText(file.size)]),
          kind: ActionRow(() => unawaited(download())),
        ),
        UpdateAvailable(:final version) => PanelRow(
          id: 'desktopUpdate',
          title: T.format('desktopUpdateAvailable', [version]),
          detail: T.text('desktopUpdateNoFile'),
          kind: const InfoRow(''),
        ),
        _ => null,
      },
      // What the release brings, on its page, while an update is on offer (as on the Mac).
      if (release != null && available)
        PanelRow(
          id: 'whatsNew',
          title: T.text('whatsNew'),
          detail: 'github.com/${LauncherUpdates.repository}/releases/tag/${release.tag}',
          kind: ActionRow(() => app.services.openUrl?.call(_page(release))),
        ),
      PanelRow(
        id: 'desktopUpdateCheck',
        title: T.text('checkForUpdatesNow'),
        detail: switch (now) {
          UpdateChecking() => T.text('checkingUpdates'),
          UpdateCheckFailed() => T.text('desktopUpdateNoAnswer'),
          UpdateCurrent(:final checked) => T.format('desktopUpToDateAt', [current, _time(checked)]),
          UpdateIdle() => T.format('desktopVersion', [current]),
          _ => T.format('desktopNewest', [release?.version ?? '', current]),
        },
        kind: ActionRow(() => unawaited(check())),
      ),
    ].nonNulls.toList();
  }

  /// Settings › About › Update Channel: Stable or Nightly, as on the Mac. None for a package
  /// manager's copy, which gets the stable releases.
  PanelRow? channelRow() => managedBy != null
      ? null
      : PanelRow(
          id: 'updateChannel',
          title: T.text('updateChannel'),
          detail: T.text(
            app.updateChannel == UpdateChannel.nightly ? 'updateChannelNightlyDetail' : 'updateChannelStableDetail',
          ),
          kind: ChoiceRow(
            [T.text('channelStable'), T.text('channelNightly')],
            app.updateChannel.index,
            (index) => app.setUpdateChannel(UpdateChannel.values[index]),
          ),
        );

  /// Update Required (AnyTogether's client_too_old): why, the update where it stands (the same
  /// download and restart as About) or the downloads page, and Later.
  List<PanelRow> requiredRows(ClientTooOld old) {
    final now = state;
    final file = asset;
    final step = switch (now) {
      UpdateDownloading(:final version, :final percent) => PanelRow(
        id: 'required-downloading',
        title: T.format('desktopUpdateDownloading', [version, percent]),
        kind: const InfoRow(''),
      ),
      UpdateReady(:final version) when !restartAfterGame => PanelRow(
        id: 'required-restart',
        title: '${T.format('desktopNoticeReady', [version])} · ${T.text('desktopRestartNow')}',
        detail: T.text('desktopUpdateLaterDetail'),
        kind: ActionRow(() => unawaited(restartNow())),
      ),
      UpdateAvailable(:final version) when managedBy != null => _managedRow('required-update', version),
      UpdateAvailable(:final version) when file != null => PanelRow(
        id: 'required-update',
        title: T.format('desktopUpdateTo', [version]),
        detail: T.format('desktopUpdateDetail', [file.name, byteText(file.size)]),
        kind: ActionRow(() => unawaited(download())),
      ),
      _ => null,
    };
    final page = old.downloadUrl;
    return [
      PanelRow(
        id: 'required-why',
        title: old.current == null ? T.text('requiredTooOld') : T.format('requiredTooOldVersion', [old.current!]),
        detail: T.format('requiredDetail', [old.minimum]),
        kind: const InfoRow(''),
      ),
      ?step,
      if (step == null && page != null)
        PanelRow(
          id: 'required-download',
          title: T.text('requiredDownload'),
          detail: T.text('requiredDownloadDetail'),
          kind: ActionRow(() => app.services.openUrl?.call(page)),
        ),
      PanelRow(id: 'required-later', title: T.text('requiredLater'), kind: ActionRow(app.closeOverlay)),
    ];
  }

  static String _time(DateTime time) =>
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
}
