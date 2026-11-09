import 'dart:async';

import 'package:path/path.dart' as p;

import '../core/audio/tones.dart';
import '../core/game_library.dart';
import '../core/glibc.dart';
import '../core/host.dart';
import '../core/release_signing.dart';
import '../core/toolkit.dart';
import '../core/toolkit_download.dart';
import '../core/update_channel.dart';
import 'app_model.dart';
import 'components.dart';
import 'engine_git_model.dart';
import 'strings.dart';

/// The AnyPS5 engine (upstream's relinker and system libraries) as the launcher gets it by
/// itself: which versions GitHub has, the one being downloaded, the ones on disk and which
/// one is in use.
class EngineModel {
  EngineModel(this.app) : store = ToolkitStore(app.paths.toolkits, system: app.system) {
    refresh();
  }

  final AppModel app;
  final ToolkitStore store;

  /// Update from Git, for an engine folder that is a git checkout.
  late final EngineGitModel git = EngineGitModel(app);

  /// The downloaded toolkits, newest first.
  List<Toolkit> downloaded = const [];

  /// What GitHub said last: the latest release and the recent ones.
  UpstreamRelease? latest;
  List<UpstreamRelease> releases = const [];
  bool checking = false;

  /// Why GitHub could not be asked, until the next try.
  String? checkError;

  /// The package being downloaded and how far it is.
  ToolkitPackage? downloading;
  ToolkitProgress? progress;
  DownloadCancel? _cancel;

  /// A package GitHub gave no checksum for, waiting for the user to download it anyway.
  ToolkitPackage? unverified;

  /// An unsigned package of a signing source from before signing began, waiting for the user to
  /// download it anyway.
  ToolkitPackage? unsigned;

  /// Why the last download failed.
  String? error;

  GitHubReleases? get _source => app.services.engineReleases;

  /// Whether the launcher can ask GitHub at all (not in tests without a fake).
  bool get online => _source != null;

  void refresh() => downloaded = store.installed();

  /// The latest release's files for this system.
  ToolkitPackage? get latestPackage => latest?.packageFor(app.system);

  /// The upstream version of the toolkit in use, null for a folder of the user's own.
  String? get currentVersion {
    final kit = app.toolkit;
    return kit == null ? null : ToolkitStore.upstreamVersion(kit.version);
  }

  /// A newer engine than the downloaded one in use is out and not downloaded yet: games made
  /// with the current one are offered to be unlocked again with it.
  bool get updateAvailable {
    final version = app.toolkitVersion;
    if (isUpstreamNightly(version)) {
      final newest = upstreamNightly;
      return newest != null &&
          newest.version != version &&
          !downloaded.any((kit) => p.basename(kit.root) == newest.version);
    }
    if (isArm(version)) {
      final newest = armPackage;
      return newest != null &&
          newest.version != version &&
          !armInUseIsNewer &&
          !downloaded.any((kit) => p.basename(kit.root) == newest.version);
    }
    final package = latestPackage;
    final current = currentVersion;
    if (package == null || current == null) return false;
    // The store's toolkits are already listed: no disk read for a getter the screen asks often.
    return compareVersions(package.version, current) > 0 &&
        !downloaded.any((kit) => p.basename(kit.root) == package.version);
  }

  /// A toolkit's name for people: v0.1.3 for a downloaded one, its version.txt otherwise.
  static String label(Toolkit kit) => nameOf(kit.version);

  /// An engine's name for people from its version.txt, or its folder name in the engines folder
  /// (0.1.3, arm-5ca076a87, upstream-main-bf80054e7).
  static String nameOf(String version) {
    if (isArm(version)) return 'AnyPS5-ARM ${version.substring(4)}';
    if (UpstreamNightlyPackage.commitOf(version) case final String commit) return 'Upstream main $commit';
    final upstream = ToolkitStore.upstreamVersion(version);
    if (upstream != null) return 'v$upstream';
    return RegExp(r'^\d').hasMatch(version) ? 'v$version' : version;
  }

  // The AnyPS5-ARM engine, from AnyPS5-ARM's signed releases.

  /// Whether the settings offer AnyPS5-ARM's engine rather than upstream's.
  bool get armSelected => app.preferences.engineSource == 'arm';

  /// The newest AnyPS5-ARM engine for this system GitHub lists, once asked.
  ArmToolkitPackage? armPackage;

  /// Every recent AnyPS5-ARM release GitHub listed, nightlies too, whatever the channel.
  List<UpstreamRelease> armReleases = const [];
  bool armChecked = false;
  bool armChecking = false;
  String? armError;

  /// AnyPS5-ARM's releases, signed with the release keys built into the launcher.
  GitHubReleases? get _armSource => app.services.armEngineReleases;

  // Upstream nightlies: upstream's main built unmodified by AnyPS5-ARM's CI, from AnyPS5-ARM's
  // signed pre-releases.

  /// The newest signed upstream nightly for this system, on the Nightly update channel only; null
  /// on Stable and until AnyPS5-ARM's releases are listed.
  UpstreamNightlyPackage? upstreamNightly;

  /// Whether a toolkit's version.txt names an upstream nightly (`upstream-main-<commit>`).
  static bool isUpstreamNightly(String? version) => UpstreamNightlyPackage.isVersion(version);

  Future<void>? _armCheck;

  /// Asks AnyPS5-ARM's releases for its newest engine; a second call while one runs waits for it.
  Future<void> checkArm({bool quiet = false}) {
    if (armChecking) return _armCheck ?? Future.value();
    return _armCheck = _checkArm(quiet);
  }

  Future<void> _checkArm(bool quiet) async {
    final source = _armSource;
    if (source == null) return;
    armChecking = true;
    armError = null;
    app.refresh();
    try {
      armReleases = await source.all();
      _offerArm();
      armChecked = true;
      if (!quiet) {
        app.show(
          armPackage == null
              ? T.text('engineArmNone')
              : (updateAvailable ? T.format('engineUpdateToast', [armPackage!.commit]) : T.text('engineArmUpToDate')),
        );
      }
    } on ToolkitFailure catch (failure) {
      armError = failure.message;
      if (!quiet) app.show(T.text('engineOffline'));
    } finally {
      armChecking = false;
      app.refresh();
    }
  }

  /// The newest engine the update channel offers: nightly engines (those of pre-releases) only on
  /// Nightly, in the order releases come out (ReleaseVersion).
  /// A nightly is published by CI first and signed on the release Mac after: until then it would
  /// only be refused, so it is not offered.
  void _offerArm() {
    final ready = [
      for (final release in armReleases)
        if (!release.prerelease || release.trust != ReleaseTrust.unsignedRefused) release,
    ];
    armPackage = ArmToolkitPackage.find(ChannelReleases.offered(ready, app.updateChannel), app.system);
    // An upstream nightly is no version the channels order (ChannelReleases leaves it out): only
    // Nightly offers it, once signed.
    upstreamNightly = app.updateChannel == UpdateChannel.nightly
        ? UpstreamNightlyPackage.newest([
            for (final release in armReleases)
              if (release.trust == ReleaseTrust.signed) release,
          ], app.system)
        : null;
  }

  /// The update channel changed: the engine it offers, from the releases already listed (and
  /// asked again when there are none yet).
  void channelChanged() {
    _offerArm();
    if ((armSelected || app.updateChannel == UpdateChannel.nightly) && !armChecked) unawaited(checkArm(quiet: true));
  }

  /// The AnyPS5-ARM engine in use came from a newer release than the one offered (a nightly, on
  /// Stable again): Stable never offers going back to an older engine.
  bool get armInUseIsNewer {
    final version = app.toolkitVersion;
    final offered = armPackage;
    if (!isArm(version) || offered == null) return false;
    final commit = version!.substring('arm-'.length);
    final from = armReleases.where(
      (release) =>
          release.assets.any((asset) => asset.name.startsWith('AnyPS5-toolkit-') && asset.name.contains('-$commit.')),
    );
    final mine = from.map((release) => ReleaseVersion.parse(release.tag)).nonNulls.firstOrNull;
    final theirs = ReleaseVersion.parse(offered.release.tag);
    return mine != null && theirs != null && mine > theirs;
  }

  /// Switches the settings between upstream's engine and AnyPS5-ARM's; a downloaded one of that
  /// kind is used at once, else the settings offer it.
  void chooseSource(bool arm) {
    app.preferences.engineSource = arm ? 'arm' : 'upstream';
    app.savePreferences();
    final kit = downloaded.where((kit) => isArm(kit.version) == arm).firstOrNull;
    final current = app.toolkit;
    if (kit != null && (current == null || isArm(current.version) != arm)) use(kit);
    if (arm && !armChecked) unawaited(checkArm(quiet: true));
    if (!arm && latest == null) unawaited(check(quiet: true));
  }

  /// One press from the phone's notice or a crash report: AnyPS5-ARM's engine is chosen, used at
  /// once when one is downloaded, else downloaded from AnyPS5-ARM's signed releases. True when it
  /// is the engine in use. Installed games then offer Update and Play (unlocked again with it).
  Future<bool> switchToArm() async {
    if (!armSelected) {
      app.preferences.engineSource = 'arm';
      app.savePreferences();
    }
    if (isArm(app.toolkitVersion)) return true;
    final kit = downloaded.where((kit) => isArm(kit.version)).firstOrNull;
    if (kit != null) {
      use(kit);
      return true;
    }
    if (downloading != null) return false;
    if (!armChecked) await checkArm(quiet: true);
    return download();
  }

  /// The newest engine of the source chosen, for the first start's download card.
  ToolkitPackage? get offered => armSelected ? armPackage : latestPackage;

  /// Whether GitHub is being asked for the source chosen.
  bool get looking => armSelected ? armChecking : checking;

  /// Why GitHub could not be asked for the source chosen.
  String? get lookError => armSelected ? armError : checkError;

  /// Asks GitHub for the source chosen, quietly.
  void lookQuietly() {
    if (armSelected) {
      if (!armChecking) unawaited(checkArm(quiet: true));
    } else if (!checking) {
      unawaited(check(quiet: true));
    }
  }

  /// A package as the download card names it: v0.1.4, or AnyPS5-ARM 5ca076a87.
  static String offeredName(ToolkitPackage package) =>
      package is ArmToolkitPackage ? 'AnyPS5-ARM ${package.commit}' : packageName(package);

  List<PanelRow> _armRows(Toolkit? current) {
    final package = armPackage;
    final pending = downloading;
    final have = package == null
        ? null
        : downloaded.where((kit) => p.basename(kit.root) == package.version).firstOrNull;
    return [
      if (current == null || !isArm(current.version))
        PanelRow(
          id: 'engineArmWhy',
          title: T.text('engineArmWhy'),
          detail: T.text('engineArmWhyDetail'),
          kind: const InfoRow(''),
        ),
      if (pending != null)
        PanelRow(
          id: 'engineDownload',
          title: T.format('engineDownloading', [packageName(pending), ((progress?.fraction ?? 0) * 100).floor()]),
          detail: '${progressText()} · ${T.text('engineStop')}',
          kind: ActionRow(cancel),
        )
      else if (unsigned case final ArmToolkitPackage waiting)
        PanelRow(
          id: 'engineDownload',
          title: T.text('engineUnsignedTitle'),
          detail: T.format('engineUnsignedDetail', [waiting.commit]),
          kind: ActionRow(() => unawaited(download(waiting, false, true)), destructive: true),
        )
      else if (unverified case final ArmToolkitPackage waiting)
        PanelRow(
          id: 'engineDownload',
          title: T.text('engineUnverifiedTitle'),
          detail: T.format('engineUnverifiedDetail', [waiting.commit]),
          kind: ActionRow(() => unawaited(download(waiting, true)), destructive: true),
        )
      else if (package != null && have == null && !armInUseIsNewer)
        PanelRow(
          id: 'engineDownload',
          title: T.format('engineArmDownload', [package.commit]),
          detail: '${byteText(package.size)} · ${package.release.tag}',
          kind: ActionRow(() => unawaited(download(package))),
        )
      else if (have != null && (current == null || !p.equals(have.root, current.root)))
        PanelRow(
          id: 'engineDownload',
          title: T.format('engineArmUse', [package!.commit]),
          detail: T.text('engineDownloaded'),
          kind: ActionRow(() => use(have)),
        ),
      PanelRow(
        id: 'engineCheck',
        title: T.text('engineCheck'),
        detail: armChecking
            ? T.text('checkingUpdates')
            : armError != null
            ? T.text('engineOffline')
            : armChecked && package == null
            ? T.text('engineArmNone')
            : package == null
            ? T.text('engineArmSource')
            : T.format('engineNewest', ['${package.commit} · ${package.release.tag}']),
        kind: ActionRow(() => unawaited(checkArm())),
      ),
    ];
  }

  /// Whether a toolkit's version.txt names an AnyPS5-ARM engine (`arm-<commit>`).
  static bool isArm(String? version) => version != null && version.startsWith('arm-');

  /// Whether an engine (a toolkit's version.txt) reads the phones the launcher relays
  /// (ANYPS5_REMOTE_PAD): true for AnyPS5-ARM's, false for upstream's release builds, which have
  /// no phone input at all, null for a folder of the user's own, which the launcher cannot tell.
  static bool? readsPhone(String? version) {
    if (version == null) return null;
    if (isArm(version)) return true;
    if (ToolkitStore.upstreamVersion(version) != null || isUpstreamNightly(version)) return false;
    return null;
  }

  /// Whether the engine in use reads ANYPS5_FULLSCREEN and ANYPS5_WINDOW_SIZE itself (AnyPS5-ARM's
  /// does; upstream's opens a window at 60% of the screen and goes full screen on F11).
  bool get readsDisplaySettings => isArm(app.toolkitVersion);

  /// The same for [game]: its own engine when it has one, else the default's.
  bool readsDisplaySettingsOf(Game game) {
    if (app.currentSettings(game).engine == null) return readsDisplaySettings;
    return isArm(app.toolkitFor(game)?.version ?? app.records[game.id]?.toolkit);
  }

  /// The folders of the downloaded engines chosen for a game of their own.
  Set<String> get pinnedKeys => {for (final game in app.games) ?app.currentSettings(game).engine};

  /// Whether a game has [kit] chosen for itself (it stays, whatever else is deleted).
  bool isPinned(Toolkit kit) => pinnedKeys.contains(p.basename(kit.root));

  /// Whether [kit] is the default or chosen by a game: the Mac's "engines in use".
  bool inUse(Toolkit kit) {
    final current = app.toolkit;
    return (current != null && p.equals(kit.root, current.root)) || isPinned(kit);
  }

  bool isDownloaded(Toolkit kit) => p.equals(p.dirname(kit.root), store.root);

  /// This system's glibc, read once.
  late final String? hostGlibc = app.system == HostSystem.linux ? (app.services.hostGlibc ?? Glibc.host)() : null;

  /// What a Linux engine's libraries need of glibc and this system lacks, null when it has
  /// enough (or on Windows, or when either is unknown).
  ({String needed, String host})? glibcShortfall(Toolkit kit) {
    if (app.system != HostSystem.linux) return null;
    return Glibc.shortfall(kit.libraryFiles, host: hostGlibc, key: '${kit.root}\u0000${kit.version}');
  }

  /// "Games need glibc 2.38 or newer; this system has 2.35", null when nothing is missing.
  String? glibcWarning(Toolkit kit) {
    final missing = glibcShortfall(kit);
    return missing == null ? null : T.format('engineGlibc', [missing.needed, missing.host]);
  }

  /// Asks GitHub for the latest release and the recent ones. Without [quiet], says what came
  /// of it.
  Future<void> check({bool quiet = false}) async {
    final source = _source;
    if (source == null || checking) return;
    // On Nightly the upstream nightlies come from AnyPS5-ARM's releases.
    if (app.updateChannel == UpdateChannel.nightly) unawaited(checkArm(quiet: true));
    checking = true;
    checkError = null;
    app.refresh();
    try {
      final newest = await source.latest();
      latest = newest;
      try {
        releases = await source.all();
      } on ToolkitFailure {
        releases = [newest];
      }
      if (!quiet) {
        app.show(
          updateAvailable
              ? T.format('engineUpdateToast', ['v${newest.version}'])
              : T.format('engineUpToDate', ['v${newest.version}']),
        );
      }
    } on ToolkitFailure catch (failure) {
      checkError = failure.message;
      if (!quiet) app.show(T.text('engineOffline'));
    } finally {
      checking = false;
      app.refresh();
    }
  }

  /// At start: a quiet look for a newer engine, said once when there is one; nothing while
  /// Settings › Behaviour › Check for updates is off, as on the Mac.
  Future<void> startupCheck() async {
    if (!online || !app.preferences.onboarded || !app.preferences.checkUpdates) return;
    if (isUpstreamNightly(app.toolkitVersion)) {
      if (app.updateChannel != UpdateChannel.nightly) return;
      await checkArm(quiet: true);
      if (updateAvailable) app.show(T.format('engineUpdateToast', ['Upstream main ${upstreamNightly!.commit}']));
      return;
    }
    if (isArm(app.toolkitVersion)) {
      await checkArm(quiet: true);
      if (updateAvailable) app.show(T.format('engineUpdateToast', [armPackage!.commit]));
      return;
    }
    if (currentVersion == null) return;
    await check(quiet: true);
    if (updateAvailable) app.show(T.format('engineUpdateToast', ['v${latest!.version}']));
  }

  /// Downloads [package] (the latest when null), makes it the toolkit in use and deletes
  /// versions nothing needs any more. True when it is in place.
  Future<bool> download([ToolkitPackage? package, bool allowUnverified = false, bool allowUnsigned = false]) async {
    if (downloading != null) return false;
    // Update and Play with an upstream nightly in use: the newer upstream nightly.
    if (package == null && !armSelected && isUpstreamNightly(app.toolkitVersion)) package = upstreamNightly;
    if (package == null && (armSelected || isArm(app.toolkitVersion))) {
      if (!armChecked) await checkArm(quiet: true);
      package = armPackage;
      if (package == null) {
        app.show(T.text(armChecked ? 'engineArmNone' : 'engineOffline'));
        return false;
      }
    }
    if (package == null) {
      if (latest == null) await check(quiet: true);
      package = latestPackage;
      if (package == null) {
        app.show(T.text(latest == null ? 'engineOffline' : 'engineNoDownload'));
        return false;
      }
    }
    final cancel = DownloadCancel();
    _cancel = cancel;
    final keepDefault = _keepDefault;
    _keepDefault = false;
    downloading = package;
    progress = ToolkitProgress(ToolkitPhase.download, 0, package.size);
    error = null;
    app.refresh();
    var shown = -1;
    try {
      final kit = await store.install(
        package,
        allowUnverified: allowUnverified,
        allowUnsigned: allowUnsigned,
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
      unverified = null;
      unsigned = null;
      refresh();
      app.sounds.play(Cue.unlocked);
      if (keepDefault) {
        // For one game: what it unlocks next, the default stays as it is.
        app.show(glibcWarning(kit) ?? T.format('engineReady', [label(kit)]));
        return true;
      }
      app.preferences.toolkitFolder = kit.root;
      app.savePreferences();
      removeUnused();
      app.show(glibcWarning(kit) ?? switched(kit, 'engineReady'));
      return true;
    } on ToolkitFailure catch (failure) {
      switch (failure.kind) {
        case ToolkitFailureKind.cancelled:
          break;
        case ToolkitFailureKind.unverified:
          unverified = package;
          app.show(T.text('engineUnverified'));
        case ToolkitFailureKind.unsigned:
          unsigned = package;
          app.show(T.text('engineUnsigned'));
        default:
          error = failure.message;
          app.show(T.format('engineFailed', [failure.message]));
      }
      return false;
    } finally {
      downloading = null;
      progress = null;
      _cancel = null;
      app.refresh();
    }
  }

  /// Stops the download; what came is kept, to carry on next time.
  void cancel() => _cancel?.cancel();

  /// Makes [kit] the toolkit in use.
  void use(Toolkit kit) {
    app.preferences.toolkitFolder = kit.root;
    app.savePreferences();
    app.show(glibcWarning(kit) ?? switched(kit, 'engineSwitched'));
  }

  /// "Now using …", and when installed games were unlocked with another engine, that Play offers
  /// Update and Play for them (unlocking again with this one; saves and trophies stay).
  String switched(Toolkit kit, String key) => withGames(T.format(key, [label(kit)]));

  /// [message], and the installed games unlocked with another engine when there are any.
  String withGames(String message) {
    final games = gamesFromOtherEngines();
    return games == 0 ? message : '$message · ${T.format('engineGamesToUpdate', [games])}';
  }

  /// The installed games unlocked with another engine than the one in use now.
  int gamesFromOtherEngines() {
    final version = app.toolkitVersion;
    if (version == null) return 0;
    // A game with an engine of its own does not move with the default.
    final own = {
      for (final game in app.games)
        if (app.currentSettings(game).engine != null) game.id,
    };
    return app.records.entries.where((entry) => entry.value.toolkit != version && !own.contains(entry.key)).length;
  }

  /// Keeps the toolkit in use, the newest two, those installed games were made with and those
  /// chosen for a game of their own.
  void removeUnused() {
    final current = app.toolkit;
    final pinned = pinnedKeys;
    store.removeUnused(
      keep: {
        ?current?.version,
        ?current?.root,
        for (final record in app.records.values) record.toolkit,
        for (final kit in downloaded)
          if (pinned.contains(p.basename(kit.root))) kit.root,
      },
    );
    refresh();
  }

  /// Deletes every downloaded version but the one in use and those games use.
  void deleteOthers() {
    for (final kit in downloaded) {
      if (!inUse(kit)) store.remove(p.basename(kit.root));
    }
    store.clearDownloads();
    refresh();
    app.show(T.text('engineDeleted'));
  }

  /// Deletes one downloaded version; one still in use is refused, as on the Mac.
  void deleteVersion(Toolkit kit) {
    if (inUse(kit)) return app.show(T.text('engineInUseNoDelete'));
    store.remove(p.basename(kit.root));
    refresh();
    app.show(T.format('engineDeletedOne', [label(kit)]));
  }

  /// A row to delete each downloaded version that is not the one in use.
  List<PanelRow> _deleteRows(Toolkit? current) => [
    for (final kit in downloaded)
      if (current == null || !p.equals(kit.root, current.root))
        PanelRow(
          id: 'engineDelete-${p.basename(kit.root)}',
          title: T.format('engineDeleteOne', [label(kit)]),
          detail: inUse(kit) ? T.text('engineInUse') : T.text('engineDeleteHint'),
          kind: ActionRow(() => deleteVersion(kit), destructive: !inUse(kit)),
        ),
  ];

  /// The settings' AnyPS5 Engine rows.
  List<PanelRow> settingsRows() {
    final current = app.toolkit;
    final package = downloading;
    final source = PanelRow(
      id: 'engineSource',
      title: T.text('engineSourceTitle'),
      detail: T.text(armSelected ? 'engineArmName' : 'engineUpstreamName'),
      kind: ChoiceRow([T.text('engineUpstreamShort'), T.text('engineArmShort')], armSelected ? 1 : 0, (index) {
        chooseSource(index == 1);
      }),
    );
    if (armSelected) {
      return [
        source,
        PanelRow(
          id: 'engineCurrent',
          title: T.text('engineInUse'),
          detail: current?.root ?? T.text('toolkitDetail'),
          kind: InfoRow(current == null ? T.text('toolkitMissing') : label(current)),
        ),
        ..._armRows(current),
        ..._deleteRows(current),
        _ownRow(current),
        ...git.rows(),
      ];
    }
    final rows = <PanelRow>[
      source,
      PanelRow(
        id: 'engineCurrent',
        title: T.text('engineInUse'),
        detail: current?.root ?? T.text('toolkitDetail'),
        kind: InfoRow(current == null ? T.text('toolkitMissing') : label(current)),
      ),
      if (current != null && glibcWarning(current) != null)
        PanelRow(
          id: 'engineGlibc',
          title: glibcWarning(current)!,
          detail: T.text('engineGlibcDetail'),
          kind: const InfoRow(''),
        ),
      if (package != null)
        PanelRow(
          id: 'engineDownload',
          title: T.format('engineDownloading', [packageName(package), ((progress?.fraction ?? 0) * 100).floor()]),
          detail: '${progressText()} · ${T.text('engineStop')}',
          kind: ActionRow(cancel),
        )
      else if (unverified case final ToolkitPackage pending)
        PanelRow(
          id: 'engineDownload',
          title: T.text('engineUnverifiedTitle'),
          detail: T.format('engineUnverifiedDetail', ['v${pending.version}']),
          kind: ActionRow(() => unawaited(download(pending, true)), destructive: true),
        )
      else if (unsigned case final ToolkitPackage pending)
        PanelRow(
          id: 'engineDownload',
          title: T.text('engineUnsignedTitle'),
          detail: T.format('engineUnsignedDetail', ['v${pending.version}']),
          kind: ActionRow(() => unawaited(download(pending, false, true)), destructive: true),
        )
      else if (latestPackage case final ToolkitPackage newest
          when (updateAvailable && !isUpstreamNightly(app.toolkitVersion)) || current == null)
        PanelRow(
          id: 'engineDownload',
          title: T.format(current == null ? 'engineDownloadVersion' : 'engineUpdate', ['v${newest.version}']),
          detail: byteText(newest.size),
          kind: ActionRow(() => unawaited(download(newest))),
        ),
      PanelRow(
        id: 'engineCheck',
        title: T.text('engineCheck'),
        detail: checking
            ? T.text('checkingUpdates')
            : latest == null
            ? (checkError == null ? T.text('engineSource') : T.text('engineOffline'))
            : T.format('engineNewest', ['v${latest!.version}']),
        kind: ActionRow(() => unawaited(check())),
      ),
      // Upstream does not sign its releases; ours are checked against their signatures.
      if (_source != null && _source!.signingKeys == null)
        PanelRow(id: 'engineSigning', title: T.text('engineUpstreamUnsigned'), kind: const InfoRow('')),
      ?_upstreamNightlyRow(current),
    ];
    // Every version GitHub lists and every one on disk, newest first.
    final versions = <String>{
      for (final release in releases)
        if (release.packageFor(app.system) != null) release.version,
      // An upstream nightly has a row of its own, and only on Nightly.
      for (final kit in downloaded)
        if (!isUpstreamNightly(kit.version)) p.basename(kit.root),
    }.toList()..sort((a, b) => compareVersions(b, a));
    for (final version in versions.take(8)) {
      final kit = downloaded.where((kit) => p.basename(kit.root) == version).firstOrNull;
      final release = releases.where((release) => release.version == version).firstOrNull;
      final title = release?.prerelease ?? false ? 'v$version · ${T.text('enginePrerelease')}' : 'v$version';
      if (kit != null && current != null && p.equals(kit.root, current.root)) {
        rows.add(PanelRow(id: 'engine-$version', title: title, kind: InfoRow(T.text('engineInUse'))));
      } else if (kit != null) {
        rows.add(
          PanelRow(
            id: 'engine-$version',
            title: title,
            detail: T.text('engineDownloaded'),
            kind: ActionRow(() => use(kit)),
          ),
        );
      } else if (release?.packageFor(app.system) case final ToolkitPackage other) {
        rows.add(
          PanelRow(
            id: 'engine-$version',
            title: title,
            detail: T.format('engineSizeDetail', [byteText(other.size)]),
            kind: ActionRow(() => unawaited(download(other))),
          ),
        );
      }
    }
    rows.addAll(_deleteRows(current));
    rows.add(_ownRow(current));
    rows.addAll(git.rows());
    final others = downloaded.where((kit) => current == null || !p.equals(kit.root, current.root)).length;
    if (others > 0) {
      rows.add(
        PanelRow(
          id: 'engineDeleteOld',
          title: T.text('engineDeleteOld'),
          detail: T.format('engineDeleteOldDetail', [others]),
          kind: ActionRow(deleteOthers, destructive: true),
        ),
      );
    }
    return rows;
  }

  /// Game Settings › Engine: this game's engine (the default, or one of the downloaded ones) and
  /// what unlocked it; a chosen engine that is not on this computer says so, and offers the
  /// download.
  List<PanelRow> gameRows(Game game) {
    final settings = app.currentSettings(game);
    final current = app.toolkit;
    final kits = downloaded;
    final missing = app.missingEngine(game);
    final record = app.records[game.id];
    final names = [
      T.format('engineFollow', [current == null ? '—' : label(current)]),
      for (final kit in kits) label(kit),
      if (missing != null) nameOf(missing),
    ];
    final selected = missing != null
        ? kits.length + 1
        : settings.engine == null
        ? 0
        : kits.indexWhere((kit) => p.basename(kit.root) == settings.engine) + 1;
    final detail = missing != null
        ? T.format('engineGameMissing', [nameOf(missing)])
        : record != null
        ? T.format('engineUnlockedWith', [nameOf(record.toolkit)])
        : T.text('engineNotUnlocked');
    return [
      PanelRow(
        id: 'engine',
        title: T.text('gameEngine'),
        detail: detail,
        kind: ChoiceRow(names, selected, (index) {
          if (missing != null && index == names.length - 1) return;
          final choice = index == 0 ? null : p.basename(kits[index - 1].root);
          app.saveSettings(game, settings.copyWith(engine: choice));
        }),
      ),
      if (missing != null)
        PanelRow(
          id: 'engineGameDownload',
          title: T.format('engineDownloadVersion', [nameOf(missing)]),
          detail: downloading == null
              ? null
              : T.format('engineDownloading', [packageName(downloading!), ((progress?.fraction ?? 0) * 100).floor()]),
          kind: ActionRow(() => unawaited(downloadForGame(game))),
        ),
    ];
  }

  /// Downloads the engine a game asks for and is missing, asking GitHub first when it was not
  /// asked yet; the default engine stays what it is.
  Future<void> downloadForGame(Game game) async {
    final key = app.missingEngine(game);
    if (key == null || downloading != null) return;
    var package = _packageNamed(key);
    if (package == null) {
      await check(quiet: true);
      await checkArm(quiet: true);
      package = _packageNamed(key);
    }
    if (package == null) return app.show(T.format('engineGameNoPackage', [nameOf(key)]));
    _keepDefault = true;
    await download(package);
  }

  /// The package of the engine with folder name [key], from what GitHub listed for each source.
  ToolkitPackage? _packageNamed(String key) {
    for (final release in releases) {
      if (release.packageFor(app.system) case final ToolkitPackage package when package.version == key) return package;
    }
    if (armPackage case final ArmToolkitPackage package when package.version == key) return package;
    if (upstreamNightly case final UpstreamNightlyPackage package when package.version == key) return package;
    for (final release in armReleases) {
      if (ArmToolkitPackage.find([release], app.system) case final ArmToolkitPackage package
          when package.version == key) {
        return package;
      }
    }
    return null;
  }

  /// Set for one download that must leave the default engine alone (a game's own, missing one).
  bool _keepDefault = false;

  /// The newest upstream nightly, on Nightly: "Upstream main · bf80054e7 · 2026-11-06 (untested)",
  /// to download, to use once downloaded, or in use; null when there is none to offer.
  PanelRow? _upstreamNightlyRow(Toolkit? current) {
    final nightly = upstreamNightly;
    if (nightly == null) return null;
    final kit = downloaded.where((kit) => p.basename(kit.root) == nightly.version).firstOrNull;
    final title = T.format('engineUpstreamMain', ['${nightly.commit} · ${nightly.date}']);
    if (kit != null && current != null && p.equals(kit.root, current.root)) {
      return PanelRow(
        id: 'engineUpstreamMain',
        title: title,
        detail: T.text('engineUpstreamMainDetail'),
        kind: InfoRow(T.text('engineInUse')),
      );
    }
    if (kit != null) {
      return PanelRow(
        id: 'engineUpstreamMain',
        title: title,
        detail: T.text('engineDownloaded'),
        kind: ActionRow(() => use(kit)),
      );
    }
    return PanelRow(
      id: 'engineUpstreamMain',
      title: title,
      detail: '${byteText(nightly.size)} · ${T.text('engineUpstreamMainDetail')}',
      kind: ActionRow(() => unawaited(download(nightly))),
    );
  }

  /// A package's name in the download rows: v0.1.4, AnyPS5-ARM's commit, `Upstream main <commit>`.
  static String packageName(ToolkitPackage package) => switch (package) {
    ArmToolkitPackage(:final commit) => commit,
    UpstreamNightlyPackage(:final commit) => 'Upstream main $commit',
    _ => 'v${package.version}',
  };

  /// Use My Own Folder: what the folder in use is, a git checkout the launcher can update or a
  /// folder used as it is.
  PanelRow _ownRow(Toolkit? current) {
    final checkout = git.checkout;
    return PanelRow(
      id: 'engineOwn',
      title: T.text('engineOwn'),
      detail: checkout != null
          ? T.format('engineOwnCheckout', [checkout.root])
          : current != null && !isDownloaded(current)
          ? T.format('engineOwnInUse', [current.root])
          : T.text('engineOwnDetail'),
      kind: ActionRow(() => unawaited(app.chooseToolkit())),
    );
  }

  /// 42 MB of 97 MB, or the step after the download.
  String progressText() {
    final now = progress;
    if (now == null) return '';
    return switch (now.phase) {
      ToolkitPhase.download => T.format('engineProgress', [byteText(now.received), byteText(now.total)]),
      _ => T.text('engineUnpacking'),
    };
  }
}
