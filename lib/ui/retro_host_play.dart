part of 'app_model.dart';

/// A PS1 game playing in the launcher's window through the emulator host: the game, its
/// controllers and its in-game menu.
class RetroPlay {
  RetroPlay({
    required this.game,
    required this.host,
    required this.controls,
    required this.menu,
    required this.started,
    required this.program,
  });

  final Game game;
  final RetroHostGame host;

  /// The host executable the game runs in, so its host is kept only for games of the same one.
  final String program;
  final RetroHostControls controls;
  final RetroGameMenu menu;
  final DateTime started;

  /// The player chose Close Game: the end that follows is not an error to show.
  bool closing = false;

  /// When the game stopped being played: it ended on its own, or Close Game began. Play time is
  /// counted to here, not to when an error screen was left.
  DateTime? endedAt;

  /// The game is over (ended, closing or closed), even while its error screen still shows.
  bool get over => endedAt != null;

  /// Its play time went to the family rules ([RetroHostPlaying._countRetroPlay]); once only.
  bool counted = false;

  /// The section of the menu shown, or null for the menu's first page.
  RetroOptionSection? menuSection;

  bool _released = false;

  /// Lets go of the controllers, the menu and the host, once, whoever asks first: Close Game, or
  /// the launcher going away while Close Game still waits on the host.
  void release(VoidCallback listener) {
    if (_released) return;
    _released = true;
    host.removeListener(listener);
    controls.dispose();
    menu.dispose();
    host.dispose();
  }

  /// The game is starting or loading: the loading screen shows.
  bool get loading => host.phase == RetroHostGamePhase.starting || host.phase == RetroHostGamePhase.loading;

  /// Why the game stopped, as the key of the words to show the player; null while it plays, and
  /// for a game that ended without an error or that the player closed.
  String? get problem => closing ? null : retroHostProblem(host);
}

/// Why [host]'s game stopped, as the key of the words to show the player; null while it plays or
/// after a clean end. A host that speaks another protocol version "needs updating" (protocol.md
/// "Host failure"), and one that never greeted the launcher could not be started. A game that
/// could not be followed (a refused `status` or `pause`) keeps its last status, which says no
/// error: its [RetroHostGame.failure] makes it one without a known cause.
String? retroHostProblem(RetroHostGame host) {
  if (host.phase != RetroHostGamePhase.ended) return null;
  if (host.hostEnd == RetroHostEnd.unsupported) return 'retroHostOutdatedDetail';
  final status = host.endStatus;
  if (status == null) return host.failure == null ? null : 'retroHostNotStartedDetail';
  return retroHostErrorKey(status.errorCode) ?? (host.failure == null ? null : 'retroHostOtherDetail');
}

/// The words for a status's `errorCode` (protocol.md "status", its `errorCode` table, and "Host
/// failure"): null for `""`, a game stopped without an error. A code this launcher does not know
/// is "a game that ended with an error" (protocol.md "Compatibility").
String? retroHostErrorKey(String errorCode) => switch (errorCode) {
  RetroErrorCode.none => null,
  RetroErrorCode.bios => 'retroHostBiosDetail',
  RetroErrorCode.disc => 'retroHostDiscDetail',
  RetroErrorCode.core => 'retroHostCoreDetail',
  RetroErrorCode.stalled => 'retroHostStalledDetail',
  RetroErrorCode.didNotStart => 'retroHostDidNotStartDetail',
  RetroErrorCode.frameTooLarge => 'retroHostFrameTooLargeDetail',
  RetroErrorCode.hostExited => 'retroHostExitedDetail',
  RetroErrorCode.hostHung => 'retroHostHungDetail',
  _ => 'retroHostOtherDetail',
};

/// Starts one emulator host for PS1 games, with the player's volume.
typedef RetroHostOpener = RetroHostSession Function(
  RetroHostInstall install, {
  required double volume,
  required bool muted,
});

/// The menu's sections, in the order its first page lists them, each with the words of its row
/// and heading and of the row's detail. Graphics is not among them: its options are left for a
/// Graphics page of their own ([RetroOptionSection.graphics]).
const retroMenuSections = {
  RetroOptionSection.audio: ('retroMenuAudio', 'retroMenuAudioDetail'),
  RetroOptionSection.controller: ('retroMenuController', 'retroMenuControllerDetail'),
  RetroOptionSection.console: ('retroMenuConsole', 'retroMenuConsoleDetail'),
  RetroOptionSection.advanced: ('retroMenuAdvanced', 'retroMenuAdvancedDetail'),
};

/// Settings › Emulators › Run PS1 games in the separate host: PS1 discs played in the launcher's
/// window through the emulator host, with the launcher's controllers and keyboard, and the game's
/// menu on PS.
extension RetroHostPlaying on AppModel {
  /// The host this build may run, where one is found (only debug builds, for now).
  RetroHostInstall? get retroHostInstall => RetroHostInstall.locate(
    services.environment ?? Platform.environment,
    debug: kDebugMode,
    system: HostSystem.current,
  );

  /// Whether [platform]'s discs play in the emulator host: PS1, with the setting on and a host
  /// found. Otherwise they go to the emulator chosen in Settings › Emulators, as before.
  bool playsInHost(RetroPlatform platform) =>
      platform == RetroPlatform.ps1 && preferences.retroHostPs1 && retroHostInstall != null;

  /// Whether [platform]'s discs can be played now: in the host, or in the emulator chosen.
  bool retroPlayable(RetroPlatform platform) => playsInHost(platform) || standaloneEmulator(platform) != null;

  /// Whether the game's own screen is in front: a game in the host and no layer over it.
  bool get retroInGame => retroPlay != null && overlay == null;

  void setRetroHostPs1(bool enabled) {
    if (preferences.retroHostPs1 == enabled) return;
    preferences.retroHostPs1 = enabled;
    savePreferences();
    _changed();
  }

  /// Settings › Emulators' rows for the host, shown where a host is found.
  List<PanelRow> _retroHostSettingsRows() {
    if (retroHostInstall == null) return const [];
    return [
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
          kind: ActionRow(() {
            Directory(paths.retroSystem).createSync(recursive: true);
            services.openFolder?.call(paths.retroSystem);
          }),
        ),
    ];
  }

  /// Starts [game]'s PS1 disc in a new emulator host and shows it in the launcher's window.
  Future<void> _playInHost(Game game, RetroDisc disc) async {
    if (starting != null || running != null || retroPlay != null) return;
    final install = retroHostInstall;
    if (install == null) return;
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

    final volume = preferences.retroHostVolume / 100;
    final muted = preferences.retroHostMuted;
    final kept = retroHostKeeper.take(program: install.host);
    final RetroHostSession session;
    if (kept != null) {
      session = kept;
      _padLog?.call('emulator host: the kept ${install.host} plays the next game');
    } else {
      try {
        session = openRetroHost(install, volume: volume, muted: muted);
      } on Object catch (error) {
        _padLog?.call('emulator host: ${install.host} did not start: $error');
        show(T.text('retroHostNotStartedDetail'));
        return;
      }
    }
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
    final play = RetroPlay(
      game: game,
      host: host,
      controls: controls,
      menu: menu,
      started: DateTime.now(),
      program: install.host,
    );
    retroPlay = play;
    host.addListener(_retroChanged);
    sounds.play(Cue.select);
    overlay = null;
    preferences.lastPlayed[game.id] = play.started.toIso8601String();
    together.family.followGame();
    savePreferences();
    _changed();
    _padLog?.call('emulator host: ${install.host} plays ${disc.path}');
    await host.start(
      RetroHostStartRequest(
        core: install.core,
        disc: p.normalize(disc.path),
        system: p.normalize(paths.retroSystem),
        saves: p.normalize(paths.retroSaves),
        options: {
          for (final MapEntry(:key, :value) in preferences.retroHostOptions.entries)
            if (retroOptionShown(key)) key: value,
        },
      ),
    );
  }

  /// The game moved on: a game that ended without an error, and was not closed by the player,
  /// goes back to the library; one with an error stays on its error screen.
  void _retroChanged() {
    final play = retroPlay;
    if (play == null || _disposed) return;
    if (play.host.phase == RetroHostGamePhase.ended && !play.closing) {
      if (!play.over) {
        play.endedAt = DateTime.now();
        together.family.followGame();
      }
      if (play.menu.isOpen || overlay == Layer.retroMenu) {
        overlay = null;
        play.menuSection = null;
        unawaited(play.menu.close());
      }
      final problem = play.problem;
      _padLog?.call('emulator host: the game ended (${play.host.endStatus?.error ?? play.host.failure ?? 'no error'})');
      if (problem == null) {
        unawaited(closeRetroGame());
        return;
      }
    }
    _changed();
  }

  /// PS in the game: its menu, the game paused and the controllers kept out of it.
  void openRetroMenu() {
    final play = retroPlay;
    if (play == null || play.closing || !play.host.loaded || overlay == Layer.retroMenu) return;
    play.menuSection = null;
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
    play.menuSection = null;
    if (overlay == Layer.retroMenu) {
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
    play.menuSection = null;
    _countRetroPlay(play);
    if (overlay == Layer.retroMenu) overlay = null;
    _changed();
    try {
      if (await play.host.detach()) {
        retroHostKeeper.keep(play.host.session, program: play.program);
        if (_disposed) await retroHostKeeper.shutdown();
        _padLog?.call('emulator host: kept for the next game');
      }
    } finally {
      play.release(_retroChanged);
      if (identical(retroPlay, play)) retroPlay = null;
      if (overlay == Layer.retroMenu) overlay = null;
      if (!_disposed) _changed();
    }
  }

  /// What a command does while a game plays in the host; false when it is not the game's to take.
  /// On the game's own screen the controller is the game's: only PS acts (its menu), and Back from
  /// the mouse opens the menu too. Its error screen goes back to the library.
  bool _retroCommand(Command command) {
    final play = retroPlay;
    if (play == null) return false;
    if (overlay == Layer.retroMenu) {
      if (command == Command.back && play.menuSection != null) {
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
    if (play.problem != null) {
      if (command == Command.select || command == Command.back || command == Command.home) {
        sounds.play(Cue.back);
        unawaited(closeRetroGame());
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

  /// The game's menu. Its first page: Resume, the discs of a multi-disc game, a row for each
  /// section ([retroMenuSections]) that has rows, and Close Game. A section's page: its options
  /// in the order the host lists them, with Volume and Mute first in Audio. Back on a section's
  /// page goes back to the first page.
  List<PanelCategory> _retroMenuCategories() {
    final play = retroPlay;
    if (play == null) return const [];
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
    final menu = play.menu;
    return [
      PanelCategory(
        id: 'retroMenu',
        title: play.game.name,
        rows: [
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
          for (final MapEntry(key: section, value: (title, detail)) in retroMenuSections.entries)
            if (_retroSectionRows(play, section).isNotEmpty)
              PanelRow(
                id: 'section-${section.name}',
                title: T.text(title),
                detail: T.text(detail),
                kind: ActionRow(() => _openRetroMenuSection(play, section)),
              ),
          PanelRow(
            id: 'closeGame',
            title: T.text('quickCloseGame'),
            kind: ActionRow(() => unawaited(closeRetroGame()), destructive: true),
          ),
        ],
      ),
    ];
  }

  /// The rows of one section's page: Volume and Mute first in Audio, then the section's options.
  /// An option that takes effect only when the game starts again says so; a chosen value not yet
  /// in effect says when it will be.
  List<PanelRow> _retroSectionRows(RetroPlay play, RetroOptionSection section) {
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

  /// Back from a section's page to the first page, on the section's row.
  void _leaveRetroMenuSection(RetroPlay play) {
    final section = play.menuSection;
    play.menuSection = null;
    final rows = _retroMenuCategories().single.rows;
    final index = rows.indexWhere((row) => row.id == 'section-${section?.name}');
    panelRow = index < 0 ? 0 : index;
    sounds.play(Cue.back);
    _changed();
  }

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

  /// The kept host is shut down once the player has left the PS1 games: the game selected is not a
  /// PS1 disc that plays in the host, or another game starts or runs.
  void _letUnwantedRetroHostGo() {
    if (!retroHostKeeper.holding || retroPlay != null) return;
    final wanted =
        running == null &&
        starting == null &&
        selectedGame?.retro?.platform == RetroPlatform.ps1 &&
        playsInHost(RetroPlatform.ps1);
    if (!wanted) unawaited(retroHostKeeper.shutdown());
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
