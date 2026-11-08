part of 'app_model.dart';

extension StandaloneEmulators on AppModel {
  String? standaloneEmulator(RetroPlatform platform) {
    final program = preferences.retroEmulators[platform.name];
    return program != null && p.isAbsolute(program) && File(program).existsSync() ? program : null;
  }

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

  Future<void> _playRetro(Game game, RetroDisc disc) async {
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
      if (_disposed) return;
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

    if (_disposed) {
      run.stop();
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
      if (timedOut && !stopping) {
        show(T.text('retroEmbeddedStartupTimedOut'));
        unawaited(stopRunningGame());
      }
      if (ready && !stopping) {
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
  }
}
