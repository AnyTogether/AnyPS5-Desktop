part of 'app_model.dart';

/// A PS1 or PS2 game playing in the launcher's window through the emulator host: the game, its
/// controllers and its in-game menu.
class RetroPlay {
  RetroPlay({
    required this.game,
    required this.host,
    required this.controls,
    required this.menu,
    required this.started,
    required this.program,
    required this.core,
    required this.unchecked,
    required this.states,
  });

  final Game game;
  final RetroHostGame host;

  /// The host executable the game runs in, so its host is kept only for games of the same one.
  final String program;

  /// The core library the game was started with: SwanStation, or LRPS2 for a PS2 game.
  final String core;

  /// Whether the game is a PS2 one, started with `start.console` `ps2`.
  bool get ps2 => game.retro?.platform == RetroPlatform.ps2;

  /// The host was started without the checks a signed release's gets (a debug or test build's
  /// `ANYPS5_RETRO_HOST`): the game is marked as such while it runs (`RetroUncheckedMark`).
  final bool unchecked;
  final RetroHostControls controls;
  final RetroGameMenu menu;
  final DateTime started;

  /// The game's save states, in its menu's Save state and Load state where its host saves states
  /// ([RetroSaveStates.available]).
  final RetroSaveStates states;

  /// The player chose Close Game: the end that follows is not an error to show.
  bool closing = false;

  /// When the game stopped being played: it ended on its own, or Close Game began. Play time is
  /// counted to here, not to when an error screen was left.
  DateTime? endedAt;

  /// The game is over (ended, closing or closed), even while its error screen still shows.
  bool get over => endedAt != null;

  /// Its play time went to the family rules ([RetroHostPlaying._countRetroPlay]); once only.
  bool counted = false;

  /// The player was told this game's memory card cannot be read, so its saves are not written
  /// ([RetroStatus.cardUnreadable]); once per game.
  bool cardWarned = false;

  /// The player was told the memory card may be back at a state's moment after a load that ended
  /// the game ([RetroHostPlaying._warnRetroCardAfterLoad]); once per game.
  bool loadCardWarned = false;

  /// The section of the menu shown, or null for the menu's first page.
  RetroOptionSection? menuSection;

  /// The Auto Optimizer of the game's internal resolution, while it is on Auto: a PS1 game whose
  /// player kept no resolution, on a host that measures how it runs.
  RetroAutoController? auto;

  /// The host's last `resolutionError` the log was given, so each one is logged once.
  String resolutionErrorLogged = '';

  /// The menu's Save state or Load state page shown, or null.
  RetroStatePage? statePage;

  /// The slot Overwrite slot N? asks about ([Layer.retroOverwriteState]).
  int? overwriting;

  /// How many times the menu was opened: a save or load goes back to the game only from the visit
  /// it was asked in, not from the menu opened again while it waited.
  int menuVisits = 0;

  /// The ids of the menu's first page as last built: the rows it gains or loses as the status
  /// changes leave the focus on the row it was on ([RetroHostPlaying._keepRetroMenuRow]).
  List<String> firstPageRows = const [];

  /// The phase and the problem the launcher last acted on ([RetroHostPlaying._retroChanged]).
  (RetroHostGamePhase, String?)? _seen;

  bool _released = false;

  /// Lets go of the controllers, the menu and the host, once, whoever asks first: Close Game, or
  /// the launcher going away while Close Game still waits on the host.
  void release(VoidCallback listener) {
    if (_released) return;
    _released = true;
    auto?.dispose();
    host.removeListener(listener);
    states.removeListener(listener);
    controls.dispose();
    menu.dispose();
    states.dispose();
    host.dispose();
  }

  /// The game is starting or loading: the loading screen shows.
  bool get loading => host.phase == RetroHostGamePhase.starting || host.phase == RetroHostGamePhase.loading;

  /// Why the game stopped, as the key of the words to show the player; null while it plays, and
  /// for a game that ended without an error or that the player closed.
  String? get problem => closing ? null : retroHostProblem(host, ps2: ps2);
}

/// The pages of the game's menu that list its save state slots.
enum RetroStatePage { save, load }

/// The words for a save or load of a state that did not work, by its key: a load the host refused
/// for a state of another emulator build, of another game or damaged says so; anything else says
/// only that it did not work.
String retroStateProblem(RetroStateOutcome outcome, {required bool saving}) => switch (outcome) {
  RetroStateOutcome.otherCore when !saving => 'retroStateOtherCore',
  RetroStateOutcome.otherGame when !saving => 'retroStateOtherGame',
  RetroStateOutcome.badState when !saving => 'retroStateBad',
  _ => saving ? 'retroStateSaveFailed' : 'retroStateLoadFailed',
};

/// "2026-11-18 14:03": when a slot's state was saved, as the cloud saves show theirs.
String retroStateTime(DateTime date) {
  final local = date.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
}

/// Why [host]'s game stopped, as the key of the words to show the player; null while it plays or
/// after a clean end. A host that speaks another protocol version "needs updating" (protocol.md
/// "Host failure"), and one that never greeted the launcher could not be started. A game that
/// could not be followed (a refused `status` or `pause`) keeps its last status, which says no
/// error: its [RetroHostGame.failure] makes it one without a known cause. A [ps2] game a host
/// without `ps2` was never given ([RetroHostGame.consoleRefused]) needs a newer host.
String? retroHostProblem(RetroHostGame host, {bool ps2 = false}) {
  if (host.phase != RetroHostGamePhase.ended) return null;
  if (host.hostEnd == RetroHostEnd.unsupported) return 'retroHostOutdatedDetail';
  if (host.consoleRefused) return retroHostNoPs2Problem;
  final status = host.endStatus;
  if (status == null) return host.failure == null ? null : 'retroHostNotStartedDetail';
  return retroHostErrorKey(status.errorCode, ps2: ps2) ?? (host.failure == null ? null : 'retroHostOtherDetail');
}

/// The problem of a PS1 game that found no BIOS it can use: its error screen offers the BIOS folder.
const retroHostBiosProblem = 'retroHostBiosDetail';

/// The problem of a PS2 game that found no BIOS it can use: its error screen offers the PS2 BIOS
/// folder, where LRPS2 looks.
const retroHostPs2BiosProblem = 'retroHostPs2BiosDetail';

/// The problem of a PS2 game whose host cannot play PS2 games: it does not list `ps2`, or its
/// signed release ships no LRPS2.
const retroHostNoPs2Problem = 'retroHostNoPs2Detail';

/// The words of the BIOS folder a [problem] sends the player to, on its error screen's options
/// key: the PS1 or the PS2 BIOS folder for a missing BIOS; null for any other problem.
String? retroBiosFolderOf(String? problem) => switch (problem) {
  retroHostBiosProblem => 'retroHostBiosFolder',
  retroHostPs2BiosProblem => 'retroHostPs2BiosFolder',
  _ => null,
};

/// The loading screen's line: the host's own words for what it loads (`status.progressLabel`)
/// where the launcher speaks English, as the host's are English; the launcher's otherwise.
String retroLoadingText(RetroStatus? status) =>
    (T.language.code == Language.english.code ? status?.progressLabel : null) ?? T.text('retroHostLoading');

/// The words for a status's `errorCode` (protocol.md "status", its `errorCode` table, and "Host
/// failure"): null for `""`, a game stopped without an error. A code this launcher does not know
/// is "a game that ended with an error" (protocol.md "Compatibility"). A [ps2] game's `bios` (LRPS2
/// found no BIOS in `pcsx2/bios`) sends the player to the PS2 BIOS folder.
String? retroHostErrorKey(String errorCode, {bool ps2 = false}) => switch (errorCode) {
  RetroErrorCode.none => null,
  RetroErrorCode.bios => ps2 ? retroHostPs2BiosProblem : retroHostBiosProblem,
  RetroErrorCode.disc => 'retroHostDiscDetail',
  RetroErrorCode.core => 'retroHostCoreDetail',
  RetroErrorCode.stalled => 'retroHostStalledDetail',
  RetroErrorCode.didNotStart => 'retroHostDidNotStartDetail',
  RetroErrorCode.frameTooLarge => 'retroHostFrameTooLargeDetail',
  RetroErrorCode.hostExited => 'retroHostExitedDetail',
  RetroErrorCode.hostHung => 'retroHostHungDetail',
  _ => 'retroHostOtherDetail',
};

/// The words of an internal resolution value: Native, 2x, 3x, 4x, or the host's own label for a
/// value the launcher does not offer.
String retroResolutionLabel(RetroResolutionValue value) => switch (value.scale) {
  null => value.label,
  1 => T.text('retroResolutionNative'),
  final scale => T.format('retroResolutionScale', ['$scale']),
};

/// The words under the internal resolution row ([RetroGraphicsNote]). A refusal is said in the
/// launcher's words, naming the value the game uses; the host's English `resolutionError` goes to
/// the log.
String retroResolutionDetail(RetroResolutionChoice choice) => choice.note == RetroGraphicsNote.refused
    ? T.format('retroResolutionRefusedDetail', [retroResolutionLabel(choice.active)])
    : retroGraphicsNoteDetail(choice.note, about: 'retroResolutionDetail');

/// Starts one emulator host for PS1 and PS2 games, with the player's volume: [checked] is the check of a
/// signed release's host ([RetroHostInstall.checked]), whose files the host holds until it exits.
typedef RetroHostOpener = RetroHostSession Function(
  RetroHostInstall install, {
  RetroHostChecked? checked,
  required double volume,
  required bool muted,
});

/// The menu's sections, in the order its first page lists them, each with the words of its row
/// and heading and of the row's detail. Graphics lists not its options but the internal
/// resolution and the settings that set them ([RetroGameMenu.graphics]).
const retroMenuSections = {
  RetroOptionSection.audio: ('retroMenuAudio', 'retroMenuAudioDetail'),
  RetroOptionSection.graphics: ('retroMenuGraphics', 'retroMenuGraphicsDetail'),
  RetroOptionSection.controller: ('retroMenuController', 'retroMenuControllerDetail'),
  RetroOptionSection.console: ('retroMenuConsole', 'retroMenuConsoleDetail'),
  RetroOptionSection.advanced: ('retroMenuAdvanced', 'retroMenuAdvancedDetail'),
};

/// Settings › Emulators › Run PS1 (or PS2) games in the separate host: those discs played in the
/// launcher's window through the emulator host, with the launcher's controllers and keyboard, and
/// the game's menu on PS.
extension RetroHostPlaying on AppModel {
  /// The host this build runs: in a debug or test build ([RetroHostBuild]) the one
  /// `ANYPS5_RETRO_HOST` names, unchecked; otherwise the signed host downloaded in Settings ›
  /// Emulators, checked before each start. Null when neither is there. Neither is looked for here
  /// ([retroHostUnchecked], [RetroHostDownloadModel.installed]).
  RetroHostInstall? get retroHostInstall => retroHostUnchecked ?? retroHostDownload.installed;

  /// What this launcher was compiled as: a debug build, a test build, or a release, as
  /// `RetroHostBuild.of(debug: kDebugMode)` says. A constant of the compiled program.
  static const retroHostBuild = kDebugMode
      ? RetroHostBuild.debug
      : RetroHostBuild.testDefined
      ? RetroHostBuild.test
      : RetroHostBuild.release;

  /// Whether this launcher looks for, runs and marks (`RetroUncheckedMark`) an unchecked host: a
  /// debug or test build. A constant, so a release is compiled without the lookup
  /// ([AppModel.retroHostUnchecked]) and without the mark, as without the host.
  static const runsUnchecked = retroHostBuild != RetroHostBuild.release;

  /// Whether [platform]'s discs play in the emulator host: PS1 with its setting on and a host found,
  /// PS2 with its own setting on and a host that has LRPS2 beside it. Otherwise they go to the
  /// emulator chosen in Settings › Emulators, as before.
  bool playsInHost(RetroPlatform platform) => switch (platform) {
    RetroPlatform.ps1 => preferences.retroHostPs1 && retroHostInstall != null,
    RetroPlatform.ps2 => preferences.retroHostPs2 && retroHostInstall?.ps2Core != null,
    RetroPlatform.ps3 => false,
  };

  /// Whether [platform]'s discs can be played now: in the host, or in the emulator chosen.
  bool retroPlayable(RetroPlatform platform) => playsInHost(platform) || standaloneEmulator(platform) != null;

  /// Whether the game's own screen is in front: a game in the host and no layer over it.
  bool get retroInGame => retroPlay != null && overlay == null;

  /// Whether the game's menu is shown, or the question one of its rows asks (Overwrite slot N?).
  bool get retroMenuShown => overlay == Layer.retroMenu || overlay == Layer.retroOverwriteState;

  /// Shuts down the host kept for the next game and waits until it has exited, so its files are
  /// no longer held: before the host is replaced by a download.
  Future<void> stopKeptRetroHost() => retroHostKeeper.shutdown();

  void setRetroHostPs1(bool enabled) {
    if (preferences.retroHostPs1 == enabled) return;
    preferences.retroHostPs1 = enabled;
    savePreferences();
    _changed();
  }

  /// Turns PS2 discs in the host on or off; the library is scanned again, as it lists PS2 cue
  /// sheets only while the host plays PS2 discs ([GameLibrary.survey]).
  void setRetroHostPs2(bool enabled) {
    if (preferences.retroHostPs2 == enabled) return;
    preferences.retroHostPs2 = enabled;
    savePreferences();
    rescan();
  }

  /// Settings › Emulators' rows for the host: its download, or the notice that this build runs an
  /// unchecked host, and where a host is found, the setting and the BIOS folder; then the same two
  /// for PS2 where that host has LRPS2 beside it.
  List<PanelRow> _retroHostSettingsRows() {
    final unchecked = retroHostUnchecked != null;
    final download = retroHostDownload.rows(uncheckedHost: unchecked);
    final install = retroHostInstall;
    if (install == null) return download;
    return [
      ...download,
      if (unchecked)
        PanelRow(
          id: 'retro-host-unchecked',
          title: T.text('retroHostUnchecked'),
          kind: InfoRow(T.text('retroHostUncheckedDetail')),
        ),
      PanelRow(
        id: 'retro-host-ps1',
        title: T.text('retroHostPs1'),
        detail: T.text('retroHostPs1Detail'),
        kind: ToggleRow(preferences.retroHostPs1, setRetroHostPs1),
      ),
      if (preferences.retroHostPs1)
        PanelRow(
          id: 'retro-host-bios',
          title: T.text('retroHostBiosFolder'),
          detail: T.text('retroHostBiosFolderDetail'),
          kind: ActionRow(openRetroBiosFolder),
        ),
      ..._retroHostPs2SettingsRows(install),
    ];
  }

  /// The PS2 rows of Settings › Emulators under the PS1 ones: where [install] has LRPS2 beside it,
  /// the setting and, once it is on, the folder LRPS2 looks for the PS2 BIOS in; where it has none
  /// (a host release that does not ship LRPS2), no rows, so its Settings stay as they are for PS1.
  List<PanelRow> _retroHostPs2SettingsRows(RetroHostInstall install) {
    if (install.ps2Core == null) return const [];
    return [
      PanelRow(
        id: 'retro-host-ps2',
        title: T.text('retroHostPs2'),
        detail: T.text('retroHostPs2Detail'),
        kind: ToggleRow(preferences.retroHostPs2, setRetroHostPs2),
      ),
      if (preferences.retroHostPs2)
        PanelRow(
          id: 'retro-host-ps2-bios',
          title: T.text('retroHostPs2BiosFolder'),
          detail: T.text('retroHostPs2BiosFolderDetail'),
          kind: ActionRow(() => openRetroBiosFolder(ps2: true)),
        ),
    ];
  }

  /// The folder the host looks for the PS1 BIOS in, or with [ps2] the one LRPS2 looks for the PS2
  /// BIOS in, made if it is not there yet, opened in the system's file manager.
  void openRetroBiosFolder({bool ps2 = false}) {
    final folder = ps2 ? paths.retroPs2Bios : paths.retroSystem;
    try {
      Directory(folder).createSync(recursive: true);
    } on FileSystemException catch (error) {
      _padLog?.call('emulator host: no BIOS folder: $error');
      return;
    }
    services.openFolder?.call(folder);
  }

  /// Starts [game]'s PS1 or PS2 disc in a new emulator host and shows it in the launcher's window.
  Future<void> _playInHost(Game game, RetroDisc disc) async {
    if (starting != null || running != null || retroPlay != null) return;
    if (retroHostDownload.installing) {
      show(T.text('retroHostUpdating'));
      return;
    }
    final install = retroHostInstall;
    if (install == null || (disc.platform == RetroPlatform.ps2 && install.ps2Core == null)) return;
    final allowed = together.family.beforePlay(game);
    if (!(allowed is bool ? allowed : await allowed) || starting != null || running != null || retroPlay != null) {
      return;
    }
    if (_disposed) return;
    if (!File(disc.path).existsSync()) {
      show(T.text('retroDiscMoved'));
      return;
    }
    try {
      Directory(paths.retroSystem).createSync(recursive: true);
    } on FileSystemException catch (error) {
      _padLog?.call('emulator host: no BIOS folder: $error');
    }

    if (!retroHostDownload.holdForStart()) {
      show(T.text('retroHostUpdating'));
      return;
    }
    try {
      await _playInHeldHost(game, disc, install);
    } finally {
      retroHostDownload.releaseStart();
    }
  }

  /// [_playInHost] once the installed host is held for the start, so no download replaces it
  /// between its check and the game's play being set.
  Future<void> _playInHeldHost(Game game, RetroDisc disc, RetroHostInstall install) async {
    final ps2 = disc.platform == RetroPlatform.ps2;
    final volume = preferences.retroHostVolume / 100;
    final muted = preferences.retroHostMuted;
    final recheck = install.checked && retroHostKeeper.keeps(program: install.host);
    if (recheck && !await _recheckKeptRetroHost(install)) return;
    final kept = retroHostKeeper.take(program: install.host);
    final RetroHostSession session;
    if (kept != null) {
      session = kept;
      _padLog?.call('emulator host: the kept ${install.host} plays the next game');
    } else {
      RetroHostChecked? checked;
      if (install.checked) {
        try {
          checked = await _checkRetroHost(install);
        } on RetroHostReleaseFailure {
          return;
        }
        if (_disposed || starting != null || running != null || retroPlay != null) {
          checked?.release();
          return;
        }
        if (ps2 && checked?.ps2Core == null) {
          checked?.release();
          _padLog?.call('emulator host: ${install.host} has no checked PS2 core');
          show(T.text(retroHostNoPs2Problem));
          return;
        }
      }
      try {
        session = openRetroHost(install, checked: checked, volume: volume, muted: muted);
      } on Object catch (error) {
        checked?.release();
        _padLog?.call('emulator host: ${install.host} did not start: $error');
        show(T.text('retroHostNotStartedDetail'));
        return;
      }
    }
    final core = ps2 ? install.ps2Core! : install.core;
    final host = RetroHostGame(session, statusEvery: retroStatusEvery, volume: volume, muted: muted);
    if (kept != null) unawaited(host.setVolume(level: volume, muted: muted));
    final settings = currentSettings(game);
    final keyboard = RetroKeyboard(
      settings.controls ?? const {},
      modifierScale: (settings.tuning ?? const InputTuning()).stickModifierScale / 100,
    );
    final controls =
        RetroHostControls(
            host,
            pads: RetroPadReader(pads: () => [for (final pad in controllers.pads) pad.id], state: controllers.stateOf),
            motors: _PadMotors(this),
            keyboard: () =>
                keyboard.state([for (final key in HardwareKeyboard.instance.physicalKeysPressed) key.usbHidUsage]),
          )
          ..deadzonePercent = preferences.stickDeadzone
          ..vibration = preferences.controllerVibration;
    final menu = RetroGameMenu(host, controls: controls);
    final discPath = p.normalize(disc.path);
    final states = p.normalize(paths.retroStates(game.titleId, ps2: ps2));
    final saveStates = RetroSaveStates(
      host,
      RetroStateFolder(folder: states, disc: discPath),
      log: _padLog,
    );
    final play = RetroPlay(
      game: game,
      host: host,
      controls: controls,
      menu: menu,
      started: DateTime.now(),
      program: install.host,
      core: core,
      unchecked: !install.checked,
      states: saveStates,
    );
    retroPlay = play;
    final auto = !ps2 && !preferences.retroHostOptions.containsKey(retroResolutionKeyPs1);
    if (auto) _startRetroAuto(play);
    host.addListener(_retroChanged);
    saveStates.addListener(_retroChanged);
    unawaited(saveStates.refresh());
    sounds.play(Cue.select);
    overlay = null;
    preferences.lastPlayed[game.id] = play.started.toIso8601String();
    together.family.followGame();
    savePreferences();
    _changed();
    _padLog?.call('emulator host: ${install.host} plays ${disc.path}');
    await host.start(
      RetroHostStartRequest(
        console: ps2 ? RetroConsole.ps2 : null,
        core: core,
        disc: discPath,
        system: p.normalize(paths.retroSystem),
        saves: p.normalize(ps2 ? paths.retroPs2Saves : paths.retroSaves),
        states: states,
        options: retroStartOptions(
          preferences.retroHostOptions,
          ps2: ps2,
          game: preferences.retroHostGameOptions[game.titleId] ?? const {},
        ),
      ),
      autoResolution: auto ? () => '${_retroAutoStartScale(play)}' : null,
    );
  }

  /// The scale [play] starts at on Auto ([RetroAutoResolution.startScale]), from what was learned
  /// of the game with this host's build only: what another build's cores did proves nothing. The
  /// GPU and the game's other graphics settings are known only from its statuses; the optimizer
  /// checks them there and starts its memory again when they differ.
  int _retroAutoStartScale(RetroPlay play) {
    final memory = preferences.retroHostAuto[play.game.titleId];
    return RetroAutoResolution.startScale(
      _retroAutoScales,
      need: _retroDisplayNeed,
      memory: memory != null && memory.host == play.host.hostVersion ? memory : null,
    );
  }

  /// The PS1 scales the Auto Optimizer may start a game at, before its host lists its own: those the
  /// launcher offers (`retro_resolution.dart`), which every SwanStation the host draws with lists.
  static const _retroAutoScales = [1, 2, 3, 4, 6, 8];

  /// The largest PS1 scale the view the game is shown in needs.
  int get _retroDisplayNeed => retroAutoDisplayNeed(retroDisplayHeight());

  /// Puts [play]'s internal resolution on Auto: the optimizer judges it from now while the game
  /// plays, and what it learns is kept and saved.
  void _startRetroAuto(RetroPlay play) {
    play.auto?.dispose();
    play.auto = RetroAutoController(
      menu: play.menu,
      titleId: play.game.titleId,
      memories: preferences.retroHostAuto,
      need: () => _retroDisplayNeed,
      saved: savePreferences,
      log: _padLog,
      every: retroAutoEvery,
      clock: retroAutoClock(),
    )..start();
  }

  /// The checks before a start of a signed release's host (protocol.md "Finding and checking the
  /// host"), whose files then stay held until that host has exited; null for the debug host. A
  /// host that fails them is not started: the player is told to download it again, and its row in
  /// Settings › Emulators offers it again.
  Future<RetroHostChecked?> _checkRetroHost(RetroHostInstall install) async {
    if (!install.checked) return null;
    try {
      return await retroHostDownload.store.check();
    } on RetroHostReleaseFailure catch (failure) {
      final file = failure.file == null ? '' : ' (${failure.file} failed)';
      _padLog?.call('emulator host: ${install.host} failed its check$file: ${failure.message}');
      retroHostDownload.failedCheck(failure.message);
      if (!_disposed) show(T.text('retroHostCheckFailed'));
      rethrow;
    }
  }

  /// The checks again before a kept signed host loads its next game: its files are still held from
  /// its own start on Windows, but on Linux SwanStation was checked by path and is loaded again for
  /// every game, so it is checked again (a second check, let go at once; the host's own stays held).
  /// The start holds the installed host ([RetroHostDownloadModel.holdForStart]) and the host stays
  /// in [retroHostKeeper] meanwhile; it is taken only once the check passed. One that fails is shut
  /// down through the keeper, which a download waits for. False when no game may start.
  Future<bool> _recheckKeptRetroHost(RetroHostInstall install) async {
    try {
      (await _checkRetroHost(install))?.release();
    } on RetroHostReleaseFailure {
      unawaited(retroHostKeeper.shutdown());
      return false;
    }
    return !_disposed && starting == null && running == null && retroPlay == null;
  }

  /// The game moved on: a memory card the host cannot read is said once; a game that ended
  /// without an error, and was not closed by the player, goes back to the library; one with an
  /// error stays on its error screen. The launcher's state changes only with the game's phase or
  /// problem. Anything else (a loading step, the discs, an option) is shown by the game's own
  /// screen, which follows the host itself (RetroPlayView), and by its menu while it is open.
  void _retroChanged() {
    final play = retroPlay;
    if (play == null || _disposed) return;
    final refusal = play.host.status?.resolutionError ?? '';
    if (refusal != play.resolutionErrorLogged) {
      play.resolutionErrorLogged = refusal;
      if (refusal.isNotEmpty) _padLog?.call('emulator host: $refusal');
    }
    if (!play.cardWarned && play.host.status?.cardUnreadable == true) {
      play.cardWarned = true;
      show(T.text('retroHostCardUnreadable'));
    }
    final seen = (play.host.phase, play.problem);
    if (seen == play._seen) {
      _keepRetroMenuRow(play);
      if (retroMenuShown) _redraw();
      return;
    }
    play._seen = seen;
    _keepRetroMenuRow(play);
    if (play.host.phase == RetroHostGamePhase.ended && !play.closing) {
      if (!play.over) {
        play.endedAt = DateTime.now();
        together.family.followGame();
      }
      if (play.menu.isOpen || retroMenuShown) {
        overlay = null;
        _leaveRetroPages(play);
        unawaited(play.menu.close());
      }
      _warnRetroCardAfterLoad(play);
      final problem = play.problem;
      _padLog?.call('emulator host: the game ended (${play.host.endStatus?.error ?? play.host.failure ?? 'no error'})');
      if (problem == null) {
        unawaited(closeRetroGame());
        return;
      }
    }
    _changed();
  }

  /// A PS1 game that ended with `errorCode` `other` after a load the host answered `false`: the
  /// core may have finished that load after the reply, and the host writes the card when the game
  /// ends, so protocol.md "The memory card" asks the launcher to say the card may now be the
  /// state's. Also when the player closed the game while that load ran, as Close game waits for its
  /// reply and its stop then reports that ending.
  void _warnRetroCardAfterLoad(RetroPlay play) {
    final status = play.host.status;
    if (play.ps2 || play.loadCardWarned || !play.states.loadAnsweredFalse) return;
    if (status == null || !status.ended || status.errorCode != RetroErrorCode.other) return;
    play.loadCardWarned = true;
    show(T.text('retroStateCardAfterEnd'));
  }

  /// PS in the game: its menu, the game paused and the controllers kept out of it.
  void openRetroMenu() {
    final play = retroPlay;
    if (play == null || play.closing || !play.host.loaded || retroMenuShown) return;
    _leaveRetroPages(play);
    play.menuVisits++;
    open(Layer.retroMenu);
    unawaited(play.menu.open());
  }

  /// Any layer over the game (its menu, a family notice) pauses it and keeps the controllers and
  /// keys out of it, as its menu does, since that layer takes them; the game's own screen back in
  /// front gives both back, so the game is never left paused unseen.
  void _syncRetroMenu() {
    final play = retroPlay;
    if (play == null || play.closing) return;
    if (overlay != null && !play.menu.isOpen && play.host.loaded) unawaited(play.menu.open());
    if (overlay == null && play.menu.isOpen) unawaited(play.menu.close());
  }

  /// Back to the game from its menu.
  void resumeRetroGame() {
    final play = retroPlay;
    if (play == null) return;
    _leaveRetroPages(play);
    if (retroMenuShown) {
      overlay = null;
      sounds.play(Cue.back);
    }
    unawaited(play.menu.close());
    _changed();
  }

  /// Closes the game: it is stopped (its memory cards written) and forgotten in the host, and the
  /// library comes back. The host is kept for the next game ([RetroHostKeeper]) when it is left
  /// with no game loaded; otherwise, or when the launcher went away meanwhile, it is shut down.
  Future<void> closeRetroGame() async {
    final play = retroPlay;
    if (play == null || play.closing) return;
    play.closing = true;
    _leaveRetroPages(play);
    _countRetroPlay(play);
    if (retroMenuShown) overlay = null;
    _changed();
    try {
      if (await play.host.detach()) {
        retroHostKeeper.keep(play.host.session, program: play.program);
        if (_disposed) await retroHostKeeper.shutdown();
        _padLog?.call('emulator host: kept for the next game');
      }
    } finally {
      if (!_disposed) _warnRetroCardAfterLoad(play);
      play.release(_retroChanged);
      if (identical(retroPlay, play)) retroPlay = null;
      if (retroMenuShown) overlay = null;
      if (!_disposed) _changed();
    }
  }

  /// What a command does while a game plays in the host; false when it is not the game's to take.
  /// On the game's own screen the controller is the game's: only PS acts (its menu), and Back from
  /// the mouse opens the menu too. Its error screen goes back to the library.
  bool _retroCommand(Command command) {
    final play = retroPlay;
    if (play == null) return false;
    if (overlay == Layer.retroOverwriteState) {
      if (command == Command.home || command == Command.back || command == Command.options) {
        _cancelRetroOverwrite(play);
        return true;
      }
      // Its two answers take the arrows and Enter, as on any yes or no.
      return command == Command.previousGame || command == Command.nextGame;
    }
    if (overlay == Layer.retroMenu) {
      if (command == Command.back && (play.menuSection != null || play.statePage != null)) {
        _leaveRetroMenuSection(play);
        return true;
      }
      if (command == Command.home || command == Command.back || command == Command.options) {
        resumeRetroGame();
        return true;
      }
      return command == Command.previousGame || command == Command.nextGame;
    }
    if (overlay != null) return false;
    if (play.problem case final problem?) {
      if (command == Command.select || command == Command.back || command == Command.home) {
        sounds.play(Cue.back);
        unawaited(closeRetroGame());
      } else if (command == Command.options && retroBiosFolderOf(problem) != null) {
        sounds.play(Cue.select);
        openRetroBiosFolder(ps2: problem == retroHostPs2BiosProblem);
      }
      return true;
    }
    if (play.loading && (command == Command.home || (command == Command.back && !_viaPad))) {
      sounds.play(Cue.back);
      unawaited(closeRetroGame());
      return true;
    }
    if (command == Command.home || (command == Command.back && !_viaPad)) openRetroMenu();
    return true;
  }

  /// The game's menu. Its first page: Resume, the discs of a multi-disc game, Save state and Load
  /// state where its host saves states, a row for each section ([retroMenuSections]) that has rows,
  /// and Close Game. A section's page: its options in the order the host lists them, with Volume
  /// and Mute first in Audio; Graphics' page its own rows ([_retroGraphicsRows]). Save state's and
  /// Load state's pages: the game's slots. Back on a page goes back to the first page.
  List<PanelCategory> _retroMenuCategories() {
    final play = retroPlay;
    if (play == null) return const [];
    if (play.statePage case final page?) {
      return [
        PanelCategory(
          id: 'retroMenu-${page.name}',
          title: T.text(page == RetroStatePage.save ? 'retroMenuSaveState' : 'retroMenuLoadState'),
          rows: _retroStateRows(play, page),
        ),
      ];
    }
    final section = play.menuSection;
    if (section != null) {
      return [
        PanelCategory(
          id: 'retroMenu-${section.name}',
          title: T.text(retroMenuSections[section]!.$1),
          rows: _retroSectionRows(play, section),
        ),
      ];
    }
    final rows = _retroFirstPageRows(play);
    play.firstPageRows = [for (final row in rows) row.id];
    return [PanelCategory(id: 'retroMenu', title: play.game.name, rows: rows)];
  }

  List<PanelRow> _retroFirstPageRows(RetroPlay play) {
    final menu = play.menu;
    return [
      PanelRow(id: 'resume', title: T.text('quickResume'), kind: ActionRow(resumeRetroGame)),
      for (final disc in menu.rows.whereType<RetroDiscRow>())
        PanelRow(
          id: 'disc-${disc.index}',
          title: disc.label,
          detail: disc.inserted
              ? T.text(menu.discChangeFailed ? 'retroMenuDiscFailedDetail' : 'retroMenuDiscInsertedDetail')
              : (disc.enabled ? null : T.text('retroMenuDiscChangingDetail')),
          kind: ActionRow(() => unawaited(menu.chooseDisc(disc))),
        ),
      ..._retroStateMenuRows(play),
      for (final MapEntry(key: section, value: (title, detail)) in retroMenuSections.entries)
        if (_retroSectionRows(play, section).isNotEmpty)
          PanelRow(
            id: 'section-${section.name}',
            title: T.text(title),
            detail: section == RetroOptionSection.graphics ? _retroGraphicsSectionDetail(play) : T.text(detail),
            kind: ActionRow(() => _openRetroMenuSection(play, section)),
          ),
      PanelRow(
        id: 'closeGame',
        title: T.text('quickCloseGame'),
        kind: ActionRow(() => unawaited(closeRetroGame()), destructive: true),
      ),
    ];
  }

  /// What the first page's Graphics row says: what the page holds, or the internal resolution's
  /// refusal, so a saved value the emulator cannot show is said before the page is opened.
  String _retroGraphicsSectionDetail(RetroPlay play) {
    final resolution = play.menu.resolution;
    return resolution?.note == RetroGraphicsNote.refused
        ? retroResolutionDetail(resolution!)
        : T.text(retroMenuSections[RetroOptionSection.graphics]!.$2);
  }

  /// The Graphics page's rows: the internal resolution, then the console's other graphics
  /// settings, each where the host lists it.
  List<PanelRow> _retroGraphicsRows(RetroPlay play) => [
    ?_retroResolutionRow(play),
    for (final choice in play.menu.graphics) _retroGraphicsRow(choice),
  ];

  /// The Internal resolution row: the values the launcher offers that the host lists
  /// ([RetroResolutionChoice.of]), or null when the menu offers none. A PS1 game on a host that
  /// measures how it runs also offers Auto first, which names the scale the Auto Optimizer chose.
  PanelRow? _retroResolutionRow(RetroPlay play) {
    final choice = play.menu.resolution;
    if (choice == null) return null;
    final offersAuto = !play.ps2 && play.host.reportsPerformance;
    final auto = offersAuto && play.auto != null;
    return PanelRow(
      id: 'resolution',
      title: T.text('retroResolution'),
      detail: retroResolutionDetail(choice),
      kind: ChoiceRow(
        [
          if (offersAuto) T.format('retroResolutionAuto', [retroResolutionLabel(choice.active)]),
          for (final value in choice.values) retroResolutionLabel(value),
        ],
        auto ? 0 : choice.selected + (offersAuto ? 1 : 0),
        (index) => unawaited(
          offersAuto && index == 0
              ? _chooseRetroAuto(play)
              : _chooseRetroResolution(play, choice.values[index - (offersAuto ? 1 : 0)].value),
        ),
      ),
    );
  }

  /// Auto chosen for a PS1 game's internal resolution: the resolution kept for every game is let
  /// go, so each game starts at what the Auto Optimizer learned of it, and this one is judged from
  /// now at the scale it draws at.
  Future<void> _chooseRetroAuto(RetroPlay play) async {
    if (play.auto != null || play.over) return;
    preferences.retroHostOptions.remove(retroResolutionKeyPs1);
    _startRetroAuto(play);
    savePreferences();
    _changed();
  }

  /// A Graphics setting's row ([RetroGraphicsChoice]): its values in the setting's order, with what
  /// it does or when the value chosen takes effect under it.
  PanelRow _retroGraphicsRow(RetroGraphicsChoice choice) => PanelRow(
    id: choice.setting.kind.name,
    title: retroGraphicsTitle(choice.setting),
    detail: retroGraphicsDetail(choice),
    kind: ChoiceRow(
      [for (final value in choice.values) retroGraphicsLabel(value)],
      choice.selected,
      (index) => unawaited(_chooseRetroGraphics(choice.setting, index)),
    ),
  );

  /// A Graphics value chosen in the menu: the options it sets sent to the game, and kept once the
  /// host took them all, for every later game of its console, or for this game only when the
  /// setting is kept per game ([RetroGraphicsSetting.perGame]). Each takes effect as its option
  /// does: in a moment, or at the game's next start.
  Future<void> _chooseRetroGraphics(RetroGraphicsSetting setting, int index) async {
    final play = retroPlay;
    if (play == null) return;
    final taken = await play.menu.chooseGraphics(setting, index);
    if (taken == null || _disposed) return;
    if (setting.perGame) {
      (preferences.retroHostGameOptions[play.game.titleId] ??= {}).addAll(taken);
    } else {
      preferences.retroHostOptions.addAll(taken);
    }
    savePreferences();
    _changed();
  }

  /// An internal resolution chosen in the menu: sent to the game, and kept for every later game of
  /// its console once the host took it. A PS1 game draws at it in a moment, a PS2 game from its
  /// next start.
  /// A value chosen while on Auto turns Auto off, once a change Auto already asked for is
  /// answered, so the value chosen is the last one sent; the value the game then draws at is kept
  /// without being sent again. When the host refuses the value, Auto goes on.
  Future<void> _chooseRetroResolution(RetroPlay play, String value) async {
    final auto = play.auto;
    play.auto = null;
    await auto?.stop();
    final choice = play.menu.resolution;
    if (choice == null || _disposed) return;
    final already = auto != null && choice.values[choice.selected].value == value;
    if (!already && !await play.menu.chooseResolution(value)) {
      if (auto != null && !_disposed && !play.over && play.auto == null) _startRetroAuto(play);
      return;
    }
    if (_disposed) return;
    preferences.retroHostOptions[choice.key] = value;
    savePreferences();
    _changed();
  }

  /// The rows of one section's page: Volume and Mute first in Audio, then the section's options.
  /// An option that takes effect only when the game starts again says so; a chosen value not yet
  /// in effect says when it will be.
  List<PanelRow> _retroSectionRows(RetroPlay play, RetroOptionSection section) {
    if (section == RetroOptionSection.graphics) return _retroGraphicsRows(play);
    final menu = play.menu;
    return [
      if (section == RetroOptionSection.audio) ...[
        PanelRow(
          id: 'volume',
          title: T.text('retroMenuVolume'),
          kind: StepperRow(
            value: (play.host.volume * 100).round(),
            min: 0,
            max: 100,
            step: 10,
            slider: true,
            format: AppModel._percent,
            set: (value) => unawaited(_setRetroVolume(value)),
          ),
        ),
        PanelRow(
          id: 'mute',
          title: T.text('retroMenuMute'),
          kind: ToggleRow(play.host.muted, (muted) => unawaited(_setRetroMuted(muted))),
        ),
      ],
      for (final option in menu.optionsIn(section))
        PanelRow(
          id: 'option-${option.key}',
          title: option.title,
          detail: option.pending
              ? T.text(option.restartNeeded ? 'retroMenuOptionRestartDetail' : 'retroMenuOptionPendingDetail')
              : (option.restartNeeded ? T.text('retroMenuOptionRestartOnlyDetail') : null),
          kind: ChoiceRow(
            option.option.labels,
            option.option.selected,
            (index) => unawaited(_chooseRetroOption(option.option, index)),
          ),
        ),
    ];
  }

  void _openRetroMenuSection(RetroPlay play, RetroOptionSection section) {
    if (!identical(retroPlay, play) || overlay != Layer.retroMenu) return;
    play.menuSection = section;
    panelRow = 0;
    sounds.play(Cue.select);
    _changed();
  }

  /// Back from a section's or a state page to the first page, on the row that opened it.
  void _leaveRetroMenuSection(RetroPlay play) {
    final id = switch ((play.menuSection, play.statePage)) {
      (final section?, _) => 'section-${section.name}',
      (_, RetroStatePage.save) => 'saveState',
      (_, RetroStatePage.load) => 'loadState',
      _ => null,
    };
    _leaveRetroPages(play);
    final rows = _retroMenuCategories().single.rows;
    final index = rows.indexWhere((row) => row.id == id);
    panelRow = index < 0 ? 0 : index;
    sounds.play(Cue.back);
    _changed();
  }

  /// The menu opens, or is left, on its first page.
  void _leaveRetroPages(RetroPlay play) {
    play.menuSection = null;
    play.statePage = null;
    play.overwriting = null;
  }

  /// The menu's first page gained or lost rows as the game's status changed (Save state and Load
  /// state once the first frame is up, the discs and sections once the status lists them): the
  /// focus stays on the row it was on, wherever that row now is.
  void _keepRetroMenuRow(RetroPlay play) {
    if (overlay != Layer.retroMenu || play.menuSection != null || play.statePage != null) return;
    final before = play.firstPageRows;
    if (panelRow < 0 || panelRow >= before.length) return;
    final focused = before[panelRow];
    final now = play.firstPageRows = [for (final row in _retroFirstPageRows(play)) row.id];
    final index = now.indexOf(focused);
    if (index >= 0) panelRow = index;
  }

  /// Save state and Load state on the menu's first page, where the game's host saves states and
  /// once the game has shown its first frame (`status.ready`), before which the host saves and
  /// loads nothing. Load state says what a load takes back with it (a PS1 game's memory card), or
  /// that nothing is saved yet, when it cannot be chosen.
  List<PanelRow> _retroStateMenuRows(RetroPlay play) {
    final states = play.states;
    if (!states.available || play.host.phase != RetroHostGamePhase.playing) return const [];
    return [
      PanelRow(
        id: 'saveState',
        title: T.text('retroMenuSaveState'),
        detail: T.text('retroMenuSaveStateDetail'),
        kind: ActionRow(() => _openRetroStatePage(play, RetroStatePage.save)),
      ),
      PanelRow(
        id: 'loadState',
        title: T.text('retroMenuLoadState'),
        detail: T.text(
          !states.anySaved
              ? 'retroMenuNoStatesDetail'
              : (play.ps2 ? 'retroMenuLoadStateDetail' : 'retroMenuLoadStatePs1Detail'),
        ),
        kind: states.anySaved ? ActionRow(() => _openRetroStatePage(play, RetroStatePage.load)) : const InfoRow(''),
      ),
    ];
  }

  /// A state page's rows: every slot, from 1, with when its state was saved and its picture, or
  /// Saving… or Loading… while that is under way. On Save state each slot can be chosen; on Load
  /// state only a slot that holds a state.
  List<PanelRow> _retroStateRows(RetroPlay play, RetroStatePage page) {
    final running = play.states.running;
    return [
      for (final slot in play.states.slots)
        PanelRow(
          id: 'state-${slot.slot}',
          title: T.format('retroStateSlot', ['${slot.slot + 1}']),
          detail: switch (slot.savedAt) {
            _ when running?.slot == slot.slot => T.text(running!.saving ? 'retroStateSaving' : 'retroStateLoading'),
            final savedAt? => retroStateTime(savedAt),
            null => T.text('retroStateEmpty'),
          },
          picture: slot.picture,
          pictureAspect: play.host.aspect,
          kind: page == RetroStatePage.load && slot.empty
              ? const InfoRow('')
              : ActionRow(
                  () => unawaited(
                    page == RetroStatePage.save ? _chooseRetroSaveSlot(play, slot) : _loadRetroState(play, slot.slot),
                  ),
                ),
        ),
    ];
  }

  void _openRetroStatePage(RetroPlay play, RetroStatePage page) {
    if (!identical(retroPlay, play) || overlay != Layer.retroMenu) return;
    play.statePage = page;
    final rows = _retroStateRows(play, page);
    panelRow = math.max(0, rows.indexWhere((row) => row.focusable));
    sounds.play(Cue.select);
    _changed();
  }

  /// A slot chosen on Save state: an empty one is saved into at once; one that holds a state asks
  /// Overwrite slot N? first.
  Future<void> _chooseRetroSaveSlot(RetroPlay play, RetroStateSlot slot) async {
    if (play.states.busy || !identical(retroPlay, play)) return;
    if (slot.empty) return _saveRetroState(play, slot.slot);
    play.overwriting = slot.slot;
    open(Layer.retroOverwriteState);
    _changed();
  }

  /// Overwrite slot N?: Cancel first, where the focus starts, then Overwrite, which says when the
  /// state it replaces was saved.
  List<PanelCategory> _retroOverwriteCategories() {
    final play = retroPlay;
    final slot = play?.overwriting;
    if (play == null || slot == null) return const [];
    final savedAt = play.states.slot(slot).savedAt;
    return [
      PanelCategory(
        id: 'retroOverwriteState',
        title: T.format('retroStateOverwriteTitle', ['${slot + 1}']),
        rows: [
          PanelRow(id: 'cancel', title: T.text('cancel'), kind: ActionRow(() => _cancelRetroOverwrite(play))),
          PanelRow(
            id: 'overwrite',
            title: T.text('retroStateOverwrite'),
            detail: savedAt == null ? null : T.format('retroStateOverwriteDetail', [retroStateTime(savedAt)]),
            kind: ActionRow(() => unawaited(_confirmRetroOverwrite(play)), destructive: true),
          ),
        ],
      ),
    ];
  }

  /// Back from Overwrite slot N? to Save state, on that slot.
  void _cancelRetroOverwrite(RetroPlay play) {
    final slot = play.overwriting;
    play.overwriting = null;
    if (overlay != Layer.retroOverwriteState) return;
    overlay = Layer.retroMenu;
    panelRow = slot ?? 0;
    sounds.play(Cue.back);
    _changed();
  }

  Future<void> _confirmRetroOverwrite(RetroPlay play) async {
    final slot = play.overwriting;
    if (slot == null || overlay != Layer.retroOverwriteState) return;
    play.overwriting = null;
    overlay = Layer.retroMenu;
    panelRow = slot;
    _changed();
    await _saveRetroState(play, slot);
  }

  /// Saves the game into [slot]: back to the game once it is saved, the slot said; still on Save
  /// State when it did not work, which is said.
  Future<void> _saveRetroState(RetroPlay play, int slot) async {
    final visit = play.menuVisits;
    final outcome = await play.states.save(slot);
    if (_disposed || !identical(retroPlay, play)) return;
    _padLog?.call('emulator host: save state slot $slot: ${outcome.name}');
    if (outcome != RetroStateOutcome.done) {
      show(T.text(retroStateProblem(outcome, saving: true)));
      _changed();
      return;
    }
    show(T.format('retroStateSaved', ['${slot + 1}']));
    if (_onRetroStatePage(play, RetroStatePage.save, visit)) resumeRetroGame();
  }

  /// Loads the state in [slot]: back to the game, which goes on from it; still on Load state when
  /// the host refused it (a state of another emulator build or game, or a damaged file), which is
  /// said.
  Future<void> _loadRetroState(RetroPlay play, int slot) async {
    if (play.states.busy) return;
    final visit = play.menuVisits;
    final outcome = await play.states.load(slot);
    if (_disposed || !identical(retroPlay, play)) return;
    _padLog?.call('emulator host: load state slot $slot: ${outcome.name}');
    if (outcome != RetroStateOutcome.done) {
      show(T.text(retroStateProblem(outcome, saving: false)));
      _changed();
      return;
    }
    show(T.format('retroStateLoaded', ['${slot + 1}']));
    if (_onRetroStatePage(play, RetroStatePage.load, visit)) resumeRetroGame();
  }

  /// Whether the menu still shows [page] of the visit [visit] a save or load was asked in.
  bool _onRetroStatePage(RetroPlay play, RetroStatePage page, int visit) =>
      overlay == Layer.retroMenu && play.statePage == page && play.menuVisits == visit;

  /// A core option chosen in the menu: sent to the game, and kept for every later one once the
  /// host took it.
  Future<void> _chooseRetroOption(RetroOption option, int index) async {
    final play = retroPlay;
    if (play == null || index == option.selected) return;
    final taken = await play.menu.stepOption(option.key, index - option.selected);
    if (!taken || _disposed) return;
    preferences.retroHostOptions[option.key] = option.values[index];
    savePreferences();
    _changed();
  }

  Future<void> _setRetroVolume(int percent) async {
    final play = retroPlay;
    if (play == null) return;
    final steps = ((percent - play.host.volume * 100) / 10).round();
    if (steps == 0) return;
    await play.menu.stepVolume(steps);
    _keepRetroVolume(play);
  }

  Future<void> _setRetroMuted(bool muted) async {
    final play = retroPlay;
    if (play == null || play.host.muted == muted) return;
    await play.menu.toggleMute();
    _keepRetroVolume(play);
  }

  void _keepRetroVolume(RetroPlay play) {
    if (_disposed) return;
    preferences
      ..retroHostVolume = (play.host.volume * 100).round()
      ..retroHostMuted = play.host.muted;
    savePreferences();
    _changed();
  }

  /// The kept host is shut down once the player has left the host's games: the game selected is not
  /// a disc that plays in the host, or another game starts or runs.
  void _letUnwantedRetroHostGo() {
    if (!retroHostKeeper.holding || retroPlay != null) return;
    final platform = selectedGame?.retro?.platform;
    final wanted = running == null && starting == null && platform != null && playsInHost(platform);
    if (!wanted) unawaited(retroHostKeeper.shutdown());
  }

  /// How long quitting the launcher waits for the emulator hosts to save and exit: well under
  /// LauncherShutdown.defaultUnansweredAfter, which ends the process anyway.
  static const quitLimit = Duration(seconds: 3);

  /// The launcher is quitting (the exit request in lib/main.dart, which every close goes
  /// through): every emulator host is shut down, the game's and the kept one, and waited for up
  /// to [limit]. A host told to shut down stops its game as `stop` does, its memory cards written
  /// (protocol.md "shutdown"). Without this a Windows host would go with the launcher's job object
  /// unsaved. On Linux a host still there when the launcher has gone gets SIGTERM
  /// (PR_SET_PDEATHSIG), which it handles like `shutdown`. A host download stops first, so one
  /// waiting for the kept host to exit does not put a new host in place as the launcher goes.
  Future<void> shutDownRetroHosts({Duration limit = quitLimit}) async {
    retroHostDownload.close();
    final hosts = Future.wait([if (retroPlay case final play?) play.host.shutdown(), retroHostKeeper.shutdown()]);
    try {
      await hosts.timeout(limit);
    } on TimeoutException {
      _padLog?.call('emulator host: not exited ${limit.inMilliseconds} ms after shutdown; the launcher quits');
    }
  }

  /// The launcher goes: the game's controllers and menu let go, and its host is shut down.
  void _disposeRetroPlay() {
    final play = retroPlay;
    if (play == null) return;
    _countRetroPlay(play);
    retroPlay = null;
    play.release(_retroChanged);
  }

  /// The game is over: the family play-time watcher lets it go, and its time from start to
  /// [RetroPlay.endedAt] is counted, once, before anything waits on the host, so the launcher
  /// going away mid-close loses none of it.
  void _countRetroPlay(RetroPlay play) {
    play.endedAt ??= DateTime.now();
    if (play.counted) return;
    play.counted = true;
    together.family.followGame();
    together.family.played(play.started, play.endedAt!, reported: false);
  }
}
