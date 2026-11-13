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
      ..._embeddedSetupRows(),
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
    if (_disposed || _embeddedSetupBusy || starting != null || running != null || _retroDiscLaunch != null) return;
    final launchPreferences = preferences;
    final managed = _embeddedReady(disc.platform) ? _managedRetro : null;
    final program = standaloneEmulator(disc.platform);
    final ps3 = disc.platform == RetroPlatform.ps3;
    final boot = ps3 ? p.join(game.folder, 'PS3_GAME', 'USRDIR', 'EBOOT.BIN') : disc.path;
    if (!File(disc.path).existsSync() || (ps3 && !File(boot).existsSync())) {
      show(T.text('retroDiscMoved'));
      return;
    }

    ({int index, String path})? initialDisc;
    if (managed != null && disc.platform == RetroPlatform.ps1 && p.extension(boot).toLowerCase() == '.m3u') {
      try {
        final playlist = GameLibrary.ps1PlaylistDiscs(boot);
        if (playlist.isEmpty) {
          show(T.text('retroDiscMoved'));
          return;
        }
        if (playlist.length > 1) {
          final chosen = await _pickRetroLaunchDisc(game, disc, playlist);
          if (chosen == null || _disposed || !identical(preferences, launchPreferences)) return;
          final index = GameLibrary.ps1PlaylistDiscs(boot).indexOf(chosen);
          if (index < 0) {
            show(T.text('retroDiscMoved'));
            return;
          }
          initialDisc = (index: index, path: chosen);
        }
      } on FileSystemException {
        show(T.text('retroDiscMoved'));
        return;
      }
    }

    final allowed = together.family.beforePlay(game);
    if (!(allowed is bool ? allowed : await allowed) ||
        starting != null ||
        running != null ||
        _retroDiscLaunch != null ||
        _embeddedSetupBusy ||
        _disposed ||
        !identical(preferences, launchPreferences)) {
      return;
    }

    if (program == null && managed == null) {
      await chooseStandaloneEmulator(disc.platform);
      return;
    }
    sounds.play(Cue.select);
    final turn = ++_startTurn;
    starting = game;
    _changed();
    final RunningGame run;
    try {
      run = managed != null
          ? await _startEmbeddedRetro(game, disc, managed, initialDisc: initialDisc)
          : await startRetroGame(
              installed: p.dirname(program!),
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
      show(
        managed == null
            ? T.format('retroEmulatorStartFailed', [disc.platform.emulator])
            : T.text('retroEmbeddedStartFailed'),
      );
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
    if (run is! EmbeddedRetroGame) starting = null;
    running = (game, run);
    _stopped = false;
    stopping = false;
    together.family.followGame();
    _changed();

    if (run is EmbeddedRetroGame) {
      var timedOut = false;
      final ready = await run.ready.timeout(
        const Duration(minutes: 3),
        onTimeout: () {
          timedOut = true;
          return false;
        },
      );
      if (_disposed) return;
      starting = null;
      if (timedOut && !stopping && turn == _startTurn) {
        show(T.text('retroEmbeddedStartupTimedOut'));
        unawaited(stopRunningGame());
      }
      if (ready && !stopping && turn == _startTurn) {
        preferences.lastPlayed[game.id] = run.started.toIso8601String();
        savePreferences();
      } else {
        _changed();
      }
    } else {
      preferences.lastPlayed[game.id] = run.started.toIso8601String();
      savePreferences();
    }

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
    if (overlay == Layer.quickMenu || overlay == Layer.closeGame || overlay == Layer.retroDiscs) overlay = null;
    updates.gameEnded();
    if (!_stopped && code != 0) {
      if (run is EmbeddedRetroGame) {
        debugPrint('Embedded emulator ended: ${run.error}');
        show(T.text('retroEmbeddedStartFailed'));
      } else {
        show(T.format('retroEmulatorExited', [disc.platform.emulator, code]));
      }
    }
    _changed();
    final next = _launchAfterExit;
    _launchAfterExit = null;
    if (next != null) {
      _quitAfterGame = null;
      unawaited(_startAfterExit(next, Future<void>.value()));
    }
  }
}
