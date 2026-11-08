part of 'app_model.dart';

class _RetroRestartTrials {
  _RetroRestartTrials(this.app);

  final AppModel app;
  Game? _game;
  EmbeddedRetroGame? _baselineSession;
  EmbeddedRetroGame? _trialSession;
  RetroTuningSample? _baseline;
  RetroTuningSample? _candidate;
  RestartTuningChoice? _choice;
  Map<String, String> _baselineValues = const {};
  Map<String, String> _savedValues = const {};
  String? _priorOverride;
  bool _applied = false;
  bool _busy = false;
  int _restartGeneration = 0;

  void cancelPendingRestart() => _restartGeneration++;
  String _status = 'Record the current settings while playing a repeatable segment.';

  bool isTrial(EmbeddedRetroGame session) => identical(_trialSession, session);

  PanelCategory page(Game game, EmbeddedRetroGame session) {
    final choices = restartTuningChoices(game.retro!.platform, _activeOptions(session));
    final sameGame = _game?.id == game.id;
    final trial = sameGame && isTrial(session);
    final baseline = sameGame && identical(_baselineSession, session) ? _baseline : null;
    final applied = sameGame && _applied;
    final selected = choices.indexWhere((choice) => choice == _choice);
    final current = choices.isEmpty ? null : choices[selected < 0 ? 0 : selected];
    return PanelCategory(
      id: 'emulator-restart-tuning',
      title: 'Tune This Game › Restart Trials',
      rows: [
        const PanelRow(
          id: 'restart-instructions',
          title: 'Save in the game before restarting',
          kind: InfoRow('Restarting loses unsaved progress. Load the same save and repeat the same gameplay segment.'),
        ),
        PanelRow(
          id: 'restart-status',
          title: 'Comparison',
          kind: InfoRow(!sameGame && !_busy ? 'Record a baseline with your current settings.' : _status),
        ),
        if (game.retro!.platform == RetroPlatform.ps3)
          const PanelRow(
            id: 'restart-renderer',
            title: 'PS3 renderer',
            kind: InfoRow('Vulkan is the renderer supported by this AnyPS5 host.'),
          ),
        if (baseline != null || (trial && _baseline != null))
          PanelRow(id: 'restart-baseline', title: 'Baseline', kind: InfoRow((baseline ?? _baseline!).summary)),
        if (!_busy && !trial && !applied && choices.isNotEmpty)
          PanelRow(
            id: 'restart-record-baseline',
            title: 'Record baseline',
            detail: 'Play the same segment for about 12 seconds.',
            kind: ActionRow(() => unawaited(_record(game, session, trial: false))),
          ),
        if (!_busy && baseline != null && current != null && !applied) ...[
          PanelRow(
            id: 'restart-choice',
            title: 'Setting to test',
            kind: ChoiceRow(
              [for (final choice in choices) '${choice.group} · ${choice.label}'],
              selected < 0 ? 0 : selected,
              (index) {
                _choice = choices[index];
                if (!app._disposed) app._changed();
              },
            ),
          ),
          PanelRow(
            id: 'restart-start',
            title: 'Restart with temporary setting',
            detail: 'Save first. CPU and disc timing changes can affect game compatibility.',
            kind: ActionRow(() => unawaited(_startTrial(game, session, current))),
          ),
        ],
        if (trial && _choice != null)
          PanelRow(
            id: 'restart-candidate',
            title: _choice!.label,
            kind: InfoRow(applied ? 'Saved for this game' : 'Temporary'),
          ),
        if (_candidate case final result? when trial)
          PanelRow(id: 'restart-result', title: 'Candidate', kind: InfoRow(result.summary)),
        if (!_busy && trial && !applied)
          PanelRow(
            id: 'restart-record-candidate',
            title: 'Record candidate',
            detail: 'After loading the same save, repeat the baseline segment.',
            kind: ActionRow(() => unawaited(_record(game, session, trial: true))),
          ),
        if (!_busy && trial && !applied && _passesComparison)
          PanelRow(id: 'restart-apply', title: 'Apply to this game', kind: ActionRow(() => _apply(game, session))),
        if (!_busy && trial && !applied)
          PanelRow(
            id: 'restart-restore',
            title: 'Restart with saved settings',
            detail: 'Save in the game before restarting.',
            kind: ActionRow(() => unawaited(_restore(game, session))),
          ),
        if (!_busy && applied) ...[
          PanelRow(
            id: 'restart-undo',
            title: 'Undo and restart',
            detail: 'Save in the game before restarting.',
            kind: ActionRow(() => unawaited(_undo(game, session))),
          ),
          PanelRow(
            id: 'restart-finish',
            title: 'Finish and restart',
            detail: 'Keep the tested setting and close this comparison. Save in the game first.',
            kind: ActionRow(() {
              _applied = false;
              unawaited(_restore(game, session));
            }),
          ),
        ],
        if (!trial && choices.isEmpty)
          const PanelRow(
            id: 'restart-unavailable',
            title: 'No supported restart candidates',
            kind: InfoRow('This core has not reported an eligible alternative for this game.'),
          ),
      ],
    );
  }

  bool get _passesComparison {
    final before = _baseline;
    final after = _candidate;
    return before != null && after != null && after.holdsBaseline(before) && after.improvesHeadroom(before);
  }

  Map<String, EmbeddedOption> _activeOptions(EmbeddedRetroGame session) => {
    for (final entry in session.options.entries)
      if (session.activeOptions[entry.key] case final String active)
        if (entry.value.values.indexOf(active) case final index when index >= 0)
          entry.key: (
            values: entry.value.values,
            labels: entry.value.labels,
            title: entry.value.title,
            restart: entry.value.restart,
            selected: index,
          ),
  };

  Map<String, String> _profile(Game game) => {
    if (game.retro!.platform == RetroPlatform.ps3) ...app.preferences.retroPs3Defaults,
    ...?_overrides(game)[_profileId(game)],
    'frontend-resolution': ?app.preferences.retroInternalResolution[game.id],
  };

  String _profileId(Game game) => game.retro!.platform == RetroPlatform.ps3 ? game.titleId : game.id;

  Map<String, Map<String, String>> _overrides(Game game) => game.retro!.platform == RetroPlatform.ps3
      ? app.preferences.retroPs3Graphics
      : app.preferences.retroEmbeddedGraphics;

  Future<void> _record(Game game, EmbeddedRetroGame session, {required bool trial}) async {
    if (_busy || app.embeddedGame != session || !session.presented || isTrial(session) != trial) return;
    if (trial && !_trialMatches(session)) {
      _setStatus('The core is no longer using the requested setting. Restart with the saved profile.');
      return;
    }
    final result = session.tuning.captureRestartSample();
    if (result == null) {
      _setStatus('Wait for the game to finish loading and any other recording to stop.');
      return;
    }
    if (_game?.id != game.id) {
      _baselineSession = null;
      _trialSession = null;
      _baseline = null;
      _candidate = null;
      _choice = null;
      _priorOverride = null;
      _applied = false;
    }
    _busy = true;
    _game = game;
    final active = Map<String, String>.of(session.activeOptions);
    final saved = _profile(game);
    _status = 'Recording gameplay…';
    app.resumeGame();
    final sample = await result;
    _busy = false;
    if (sample == null ||
        app.embeddedGame != session ||
        !mapEquals(active, session.activeOptions) ||
        !mapEquals(saved, _profile(game))) {
      if (trial) {
        _candidate = null;
      } else {
        _baseline = null;
      }
      _setStatus('The sample was interrupted or the game settings changed. Record the segment again.');
      return;
    }
    if (trial) {
      _candidate = sample;
      _setStatus(
        _passesComparison
            ? 'The candidate improved the measured result. Review it before applying.'
            : 'The candidate did not show a clear improvement. Restart with the saved settings.',
      );
    } else {
      _baselineSession = session;
      _baseline = sample;
      _candidate = null;
      _choice = null;
      _baselineValues = active;
      _savedValues = saved;
      _setStatus('Baseline recorded. Save in the game, then choose one setting to test.');
    }
  }

  bool _trialMatches(EmbeddedRetroGame session) {
    final choice = _choice;
    if (choice == null ||
        session.activeOptions[choice.key] != choice.value ||
        !restartRendererMatches(choice, hardware: session.hardwareRendering)) {
      return false;
    }
    for (final entry in _baselineValues.entries) {
      if (entry.key == choice.key) continue;
      final reported = session.activeOptions[entry.key];
      if (choice.group == 'Renderer' && reported == null && _baselineSession?.options[entry.key]?.restart == false) {
        continue;
      }
      if (reported != entry.value) return false;
    }
    return true;
  }

  Future<void> _startTrial(Game game, EmbeddedRetroGame session, RestartTuningChoice choice) async {
    if (_busy || app.embeddedGame != session || _baselineSession != session || _baseline == null) return;
    if (!mapEquals(_baselineValues, session.activeOptions) || !mapEquals(_savedValues, _profile(game))) {
      _baseline = null;
      _setStatus('Settings changed after the baseline. Record it again.');
      return;
    }
    _busy = true;
    _choice = choice;
    _candidate = null;
    _setStatus('Restarting with the temporary setting…');
    final generation = _restartGeneration;
    try {
      final trial = await _restart(game, session, {choice.key: choice.value});
      if (generation != _restartGeneration || app._disposed) return;
      if (trial != null && _trialMatches(trial)) {
        _trialSession = trial;
        _setStatus('Temporary setting is active. Load the same save and record the candidate from Tune This Game.');
        app.show('Restart trial ready. Load the same save, then open Tune This Game.');
      } else {
        if (trial != null && app.embeddedGame == trial && app.starting == null && !app.stopping) {
          await _restart(game, trial, const {});
        }
        _baseline = null;
        _setStatus('The trial could not use the requested setting. The saved settings are unchanged.');
        if (!app._disposed) app.show(_status);
      }
    } on TimeoutException catch (failure) {
      _setStatus(failure.message ?? 'The restart did not complete. The saved settings are unchanged.');
      if (!app._disposed) app.show(_status);
    } on StateError catch (failure) {
      _setStatus(failure.message);
      if (!app._disposed) app.show(_status);
    } finally {
      _busy = false;
      if (!app._disposed) app._changed();
    }
  }

  Future<EmbeddedRetroGame?> _restart(Game game, EmbeddedRetroGame previous, Map<String, String> trialOptions) async {
    final generation = _restartGeneration;
    bool current() => generation == _restartGeneration && !app._disposed && !app._quitting;

    final settled = app._retroSettled;
    if (app.embeddedGame != previous || settled == null) return null;
    unawaited(app.stopRunningGame());
    await settled.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () => throw TimeoutException('The previous game session did not close in time.'),
    );
    if (!current() || app.running != null || app.starting != null) return null;
    if (previous.error.isNotEmpty) throw StateError(previous.error);

    final booted = Completer<EmbeddedRetroGame?>();
    unawaited(
      app._playRetro(game, game.retro!, trialOptions: trialOptions, booted: booted, canBoot: current).whenComplete(() {
        if (!booted.isCompleted) booted.complete(null);
      }),
    );
    final result = await booted.future;
    return current() ? result : null;
  }

  void _apply(Game game, EmbeddedRetroGame session) {
    final choice = _choice;
    if (_busy || choice == null || !_passesComparison || !_trialMatches(session)) return;
    if (!mapEquals(_savedValues, _profile(game))) {
      _setStatus('The saved profile changed. Restart with the saved settings and record a new baseline.');
      return;
    }
    _priorOverride = _overrides(game)[_profileId(game)]?[choice.key];
    if (_save(game, choice.key, choice.value)) {
      _applied = true;
      _setStatus('Applied to this game. Undo is available until AnyPS5 closes.');
    }
  }

  Future<void> _restore(Game game, EmbeddedRetroGame session) async {
    if (_busy || app.embeddedGame != session) return;
    _busy = true;
    _setStatus('Restarting with the saved settings…');
    final generation = _restartGeneration;
    try {
      final restored = await _restart(game, session, const {});
      if (generation != _restartGeneration || app._disposed) return;
      if (restored != null) {
        _trialSession = null;
        _baseline = null;
        _candidate = null;
        _setStatus('The game is back on its saved profile.');
      } else {
        _setStatus('The saved profile is unchanged. Start the game again to load it.');
      }
    } on TimeoutException catch (failure) {
      _setStatus(failure.message ?? 'The restart did not complete.');
      if (!app._disposed) app.show(_status);
    } on StateError catch (failure) {
      _setStatus(failure.message);
      if (!app._disposed) app.show(_status);
    } finally {
      _busy = false;
      if (!app._disposed) app._changed();
    }
  }

  Future<void> _undo(Game game, EmbeddedRetroGame session) async {
    final choice = _choice;
    if (_busy || !_applied || choice == null || app.embeddedGame != session) return;
    if (_overrides(game)[_profileId(game)]?[choice.key] != choice.value) {
      _setStatus('The tested setting has since changed. Undo would overwrite that change.');
      return;
    }
    if (_save(game, choice.key, _priorOverride)) {
      _applied = false;
      await _restore(game, session);
    }
  }

  bool _save(Game game, String key, String? value) {
    final profiles = _overrides(game);
    final id = _profileId(game);
    final original = profiles[id];
    final options = {...?original};
    if (value == null) {
      options.remove(key);
    } else {
      options[key] = value;
    }
    if (options.isEmpty) {
      profiles.remove(id);
    } else {
      profiles[id] = options;
    }
    try {
      if (app.persist) app.preferences._saveTuning(app.paths.preferencesFile);
    } on FileSystemException {
      if (original == null) {
        profiles.remove(id);
      } else {
        profiles[id] = original;
      }
      _setStatus('AnyPS5 could not save the change. The saved profile is unchanged.');
      return false;
    }
    return true;
  }

  void _setStatus(String value) {
    _status = value;
    if (!app._disposed) app._changed();
  }
}
