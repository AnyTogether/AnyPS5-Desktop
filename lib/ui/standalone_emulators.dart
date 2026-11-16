part of 'app_model.dart';

/// PS1, PS2 and PS3 discs in the games folders, played in an emulator installed on the computer
/// (DuckStation, PCSX2, RPCS3): the library's switch, the emulators' settings and the start.
extension StandaloneEmulators on AppModel {
  /// The emulator chosen for [platform], while its executable is still there.
  String? standaloneEmulator(RetroPlatform platform) {
    final program = preferences.retroEmulators[platform.name];
    return program != null && p.isAbsolute(program) && File(program).existsSync() ? program : null;
  }

  /// Asks for [platform]'s emulator executable and keeps it.
  Future<void> chooseStandaloneEmulator(RetroPlatform platform) async {
    final String? selected;
    try {
      selected = await services.pickFile?.call(
        T.format('retroSelectExecutable', [platform.emulator]),
        system == HostSystem.windows ? const ['exe'] : const [],
      );
    } on PlatformException {
      if (!_disposed) show(T.text('retroEmulatorPickerFailed'));
      return;
    }
    if (selected == null || _disposed) return;
    if (!p.isAbsolute(selected) || !File(selected).existsSync()) {
      show(T.format('retroSelectExecutable', [platform.emulator]));
      return;
    }
    preferences.retroEmulators[platform.name] = selected;
    savePreferences();
  }

  /// Settings › Game Library › Emulator games: turns the discs' discovery on or off, and with it
  /// Settings › Emulators. The scan that follows announces none of the discs as new games.
  void setRetroLibrary(bool enabled) {
    if (preferences.retroLibrary == enabled) return;
    preferences.retroLibrary = enabled;
    if (!enabled) _homeRetroFolder = null;
    savePreferences();
    _tracker.reset();
    rescan();
  }

  PanelRow _retroLibraryRow() => PanelRow(
    id: 'retroLibrary',
    title: T.text('retroLibrary'),
    detail: T.text('retroLibraryDetail'),
    kind: ToggleRow(preferences.retroLibrary, setRetroLibrary),
  );

  /// Settings › Emulators, shown while Emulator games is on.
  PanelCategory _standaloneEmulatorSettings() => PanelCategory(
    id: 'emulators',
    title: T.text('retroEmulators'),
    rows: [
      for (final platform in RetroPlatform.values)
        PanelRow(
          id: 'retro-${platform.name}',
          title: platform.emulator,
          detail: standaloneEmulator(platform) ?? T.text('retroChooseExecutable'),
          kind: ActionRow(() => unawaited(chooseStandaloneEmulator(platform))),
        ),
      ..._retroHostSettingsRows(),
      PanelRow(
        id: 'retro-show-folders',
        title: T.text('retroShowFolders'),
        kind: ToggleRow(preferences.showRetroFolders, setShowRetroFolders),
      ),
    ],
  );

  /// Starts [game]'s disc in its emulator. Given up while the emulator starts ([cancelStart]),
  /// the start lets the slot go at once, and an emulator that starts after all is stopped.
  Future<void> _playStandalone(Game game, RetroDisc disc) async {
    if (starting != null || running != null) return;
    final allowed = together.family.beforePlay(game);
    if (!(allowed is bool ? allowed : await allowed) ||
        starting != null ||
        running != null ||
        retroPlay != null ||
        _disposed) {
      return;
    }

    final program = standaloneEmulator(disc.platform);
    if (program == null) {
      await chooseStandaloneEmulator(disc.platform);
      return;
    }
    final ps3 = disc.platform == RetroPlatform.ps3;
    final boot = ps3 ? p.join(game.folder, 'PS3_GAME', 'USRDIR', 'EBOOT.BIN') : disc.path;
    if (!File(disc.path).existsSync() || (ps3 && !File(boot).existsSync())) {
      show(T.text('retroDiscMoved'));
      return;
    }

    sounds.play(Cue.select);
    final turn = ++_startTurn;
    starting = game;
    _changed();
    final RunningGame run;
    try {
      run = await startRetroGame(
        installed: p.dirname(program),
        program: program,
        arguments: [
          if (ps3) '--no-gui' else ...['-nogui', '--'],
          boot,
        ],
        logFile: paths.logFile(game.titleId),
      );
    } on Object catch (error) {
      if (_disposed || turn != _startTurn) return;
      starting = null;
      _padLog?.call('Could not start ${disc.platform.emulator}: $error');
      show(T.format('retroEmulatorStartFailed', [disc.platform.emulator]));
      _changed();
      return;
    }

    if (_disposed || turn != _startTurn) {
      // The emulator of a start given up: asked to end, then ended after the same grace as Stop.
      final end = Timer(stopGrace, run.kill);
      if (!run.stop()) run.kill();
      await run.exitCode;
      end.cancel();
      return;
    }
    starting = null;
    running = (game, run);
    _stopped = false;
    stopping = false;
    preferences.lastPlayed[game.id] = run.started.toIso8601String();
    together.family.followGame();
    savePreferences();

    final code = await run.exitCode;
    if (_disposed) return;
    running = null;
    together.family.followGame();
    together.family.played(run.started, DateTime.now(), reported: false);
    stopping = false;
    _stopTimer?.cancel();
    _stopTimer = null;
    if (hiddenForGame) {
      hiddenForGame = false;
      unawaited(services.window?.restore());
    }
    if (overlay == Layer.quickMenu || overlay == Layer.closeGame) overlay = null;
    updates.gameEnded();
    if (!_stopped && code != 0) show(T.format('retroEmulatorExited', [disc.platform.emulator, code]));
    _changed();
    final next = _launchAfterExit;
    _launchAfterExit = null;
    if (next != null) {
      _quitAfterGame = null;
      unawaited(_startAfterExit(next, Future<void>.value()));
    }
  }
}
