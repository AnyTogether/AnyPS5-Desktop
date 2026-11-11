import 'dart:async';

import 'package:path/path.dart' as p;

import '../core/audio/tones.dart';
import '../core/engine_checkout.dart';
import '../core/game_library.dart';
import 'app_model.dart';
import 'strings.dart';

/// Settings › AnyPS5 Engine › Update from Git: an engine folder that is a git checkout of the
/// engine's source, pulled and built in place (git pull --ff-only, the submodules, cmake --build
/// for the relinker and the libraries). A checkout without a build folder gets one set up first,
/// as its build guide does it. The build changes the folder's fingerprint, so installed games
/// then offer Update and Play. Every command runs as its own process, never on the interface's
/// thread.
class EngineGitModel {
  EngineGitModel(this.app);

  final AppModel app;

  /// The build guide of the checkout in use: upstream's for upstream's tree, AnyPS5-ARM's for its
  /// own. It says what to install when a tool is missing.
  Uri get guide => checkout?.guide ?? EngineCheckout.armGuide;

  CommandRunner get _runner => app.services.commands ?? const SystemCommands();

  EngineCheckout? _checkout;
  Object? _checkoutKey;

  /// The chosen engine folder when it is a git checkout of the engine, null otherwise. Read again
  /// when the folder or the toolkit (read again after a build, or the launcher back in front)
  /// changes.
  EngineCheckout? get checkout {
    final folder = app.preferences.toolkitFolder;
    final key = (folder, identityHashCode(app.toolkit));
    if (key != _checkoutKey) {
      _checkoutKey = key;
      final found = folder == null ? null : EngineCheckout.at(folder, system: app.system);
      _checkout = found != null && found.isGit ? found : null;
    }
    return _checkout;
  }

  /// The step running now, null when idle.
  GitStep? step;

  /// The last lines the running command printed.
  final lines = <String>[];

  /// Looking at the remote before a game starts.
  bool checking = false;

  /// Why the last update stopped, null after one that went through.
  GitUpdateFailure? failure;

  /// What the last update printed, for Copy.
  List<String> _output = const [];

  /// The last update went through: Relink All is offered for the games made before it.
  bool updated = false;

  CommandCancel? _cancel;
  Timer? _refresh;

  bool get running => step != null;

  /// What installs the tools the last update found missing, each to copy and, where it installs
  /// for the user only, to run here.
  List<InstallCommand> fixes = const [];

  /// The install command running now, null when none is.
  InstallCommand? installing;

  /// Looking for the tools again (Check again, or after an install).
  bool rechecking = false;

  /// Tests: what /etc/os-release says, in place of the computer's own (which package manager a
  /// Linux system installs with).
  static String? Function()? osReleaseOverride;

  EngineGit _gitFor(EngineCheckout checkout) =>
      EngineGit(checkout, runner: _runner, environment: app.services.environment, osRelease: osReleaseOverride);

  /// The game whose Play asked for the check and the build (Update from Git Before Playing).
  String? forGame;

  /// What the engine is doing now, for the games waiting on it and Home's indicator; null when
  /// idle.
  EngineJob? get job {
    if (!running && !checking) return null;
    return EngineJob(step: step, lines: List.unmodifiable(lines), forGame: forGame);
  }

  /// Pulls and builds the checkout; true when it went through. [quiet] says nothing at the end
  /// (before a game starts, the caller does).
  Future<bool> update({bool quiet = false}) async {
    final checkout = this.checkout;
    if (checkout == null || running || installing != null || rechecking) return false;
    // A game being unlocked uses the relinker and the libraries the build would rewrite.
    if (app.unlocking) {
      if (!quiet) app.show(T.text('engineGitWaitUnlock'));
      return false;
    }
    final git = _gitFor(checkout);
    final cancel = CommandCancel();
    _cancel = cancel;
    failure = null;
    fixes = const [];
    updated = false;
    lines.clear();
    step = GitStep.checking;
    app.refresh();
    try {
      final result = await git.update(
        cancel: cancel,
        onStep: (next) {
          step = next;
          lines.clear();
          app.refresh();
        },
        onLine: (line) {
          if (line.trim().isEmpty) return;
          lines.add(line);
          if (lines.length > 3) lines.removeAt(0);
          // A build prints a line per file: the screen follows a few times a second.
          _refresh ??= Timer(const Duration(milliseconds: 250), () {
            _refresh = null;
            app.refresh();
          });
        },
      );
      _output = List.of(git.output);
      app.preferences.engineGitBuilt[checkout.root] = result.after;
      app.savePreferences();
      // The build changed the relinker and the libraries: their fingerprint is read again, and
      // the games made with the build before offer Update and Play.
      app.reloadDiskFacts();
      updated = true;
      if (!quiet) {
        app.sounds.play(Cue.unlocked);
        final commit = _short(result.after);
        app.show(
          app.engine.withGames(
            result.pulled ? T.format('engineGitDone', [commit]) : T.format('engineGitBuiltAt', [commit]),
          ),
        );
      }
      return true;
    } on GitUpdateFailure catch (stopped) {
      _output = List.of(git.output);
      failure = stopped.kind == GitFailureKind.cancelled ? null : stopped;
      // Tools to install: the commands that do it on this system, beside what is missing.
      if (stopped.missing.isNotEmpty) {
        try {
          fixes = await git.fixes(stopped.missing);
        } on Object {
          fixes = const [];
        }
      }
      // A build stopped half way may have changed some libraries.
      if (!stopped.untouched || stopped.kind == GitFailureKind.cancelled) app.reloadDiskFacts();
      if (!quiet) {
        if (stopped.kind == GitFailureKind.cancelled) {
          app.show(T.text('engineGitStopped'));
        } else {
          app.sounds.play(Cue.back);
          app.show(T.format('engineGitFailed', [reasonOf(stopped)]));
        }
      }
      return false;
    } finally {
      _refresh?.cancel();
      _refresh = null;
      step = null;
      _cancel = null;
      // The unlocks asked for meanwhile wait for the build: they go on now.
      app.engineJobEnded();
    }
  }

  void cancel() => _cancel?.cancel();

  static String _short(String commit) => commit.length > 7 ? commit.substring(0, 7) : commit;

  /// Why an update stopped, for people.
  static String reason(GitFailureKind kind) => T.text(switch (kind) {
    GitFailureKind.noGit => 'engineGitNoGit',
    GitFailureKind.noCmake => 'engineGitNoCmake',
    GitFailureKind.noNinja => 'engineGitNoNinja',
    GitFailureKind.noCompiler => 'engineGitNoCompiler',
    // Said with what is missing ([reasonOf]); alone, as a tool not found.
    GitFailureKind.prerequisites => 'engineGitNoBuildReason',
    GitFailureKind.configure => 'engineGitConfigureFailed',
    GitFailureKind.notGit => 'engineGitNotGit',
    GitFailureKind.dirty => 'engineGitDirty',
    GitFailureKind.noBuild => 'engineGitNoBuildReason',
    GitFailureKind.pull => 'engineGitPullFailed',
    GitFailureKind.submodules => 'engineGitSubmodulesFailed',
    GitFailureKind.build => 'engineGitBuildFailed',
    GitFailureKind.cancelled => 'engineGitStopped',
  });

  /// Why [stopped] stopped: for tools not installed, every one of them by name.
  static String reasonOf(GitUpdateFailure stopped) => stopped.missing.isEmpty
      ? reason(stopped.kind)
      : T.format('engineGitMissing', [stopped.missing.map(needName).join(', ')]);

  /// A missing tool as the failure names it.
  static String needName(MissingNeed missing) => switch (missing.need) {
    BuildNeed.git => 'Git',
    BuildNeed.cmake => 'CMake',
    BuildNeed.ninja => 'Ninja',
    BuildNeed.compiler => T.text('engineToolCompiler'),
    BuildNeed.newerCompiler => T.format('engineToolCompilerOld', [missing.found ?? '']),
    BuildNeed.x11 => T.text('engineToolX11'),
  };

  /// What a command installs, in a few words: "Git", "GCC, CMake, Ninja".
  static String fixNames(InstallCommand command) => <String>{
    for (final need in command.needs)
      switch (need) {
        BuildNeed.git => 'Git',
        BuildNeed.cmake => 'CMake',
        BuildNeed.ninja => 'Ninja',
        BuildNeed.compiler || BuildNeed.newerCompiler => 'GCC',
        BuildNeed.x11 => T.text('engineToolX11'),
      },
  }.join(', ');

  void copyFix(InstallCommand command) {
    app.services.copyText?.call(command.line);
    app.show(T.text('engineGitFixCopied'));
  }

  /// Looks for the tools again, PATH read anew (no restart after an install): the failure goes
  /// when all are there, or lists what is still missing. [quiet] says nothing when all are there.
  Future<bool> recheck({bool quiet = false}) async {
    final checkout = this.checkout;
    if (checkout == null || running || installing != null || rechecking) return false;
    final git = _gitFor(checkout);
    rechecking = true;
    app.refresh();
    try {
      final missing = await git.missingNeeds();
      if (missing.isEmpty) {
        failure = null;
        fixes = const [];
        if (!quiet) app.show(T.text('engineGitToolsReady'));
        return true;
      }
      failure = GitUpdateFailure(GitFailureKind.prerequisites, const [], missing);
      try {
        fixes = await git.fixes(missing);
      } on Object {
        fixes = const [];
      }
      app.show(T.format('engineGitStillMissing', [missing.map(needName).join(', ')]));
      return false;
    } on GitUpdateFailure {
      return false;
    } finally {
      rechecking = false;
      app.refresh();
    }
  }

  /// Runs [command] here, its lines shown as the update's are; then looks for the tools again.
  /// Only a command that installs for the user: one that needs administrator rights is copied.
  Future<void> installFix(InstallCommand command) async {
    final checkout = this.checkout;
    if (checkout == null || running || installing != null || rechecking) return;
    if (!command.runnable || command.admin) return copyFix(command);
    final git = _gitFor(checkout);
    final cancel = CommandCancel();
    _cancel = cancel;
    installing = command;
    lines.clear();
    app.refresh();
    var installed = false;
    try {
      installed = await git.install(
        command,
        cancel: cancel,
        onLine: (line) {
          if (line.trim().isEmpty) return;
          lines.add(line);
          if (lines.length > 3) lines.removeAt(0);
          _refresh ??= Timer(const Duration(milliseconds: 250), () {
            _refresh = null;
            app.refresh();
          });
        },
      );
      _output = List.of(git.output);
    } finally {
      _refresh?.cancel();
      _refresh = null;
      installing = null;
      _cancel = null;
      lines.clear();
      app.refresh();
    }
    if (cancel.cancelled) return;
    if (!installed) {
      app.sounds.play(Cue.back);
      app.show(T.format('engineGitFixFailed', [fixNames(command)]));
      return;
    }
    await recheck();
  }

  static String stepName(GitStep step) => T.text(switch (step) {
    GitStep.checking => 'engineGitStepChecking',
    GitStep.pulling => 'engineGitStepPulling',
    GitStep.submodules => 'engineGitStepSubmodules',
    GitStep.configuring => 'engineGitStepConfiguring',
    GitStep.building => 'engineGitStepBuilding',
  });

  /// The output of the last update that stopped, the end that says why.
  String get failureText {
    final stopped = failure;
    if (stopped == null) return '';
    return [
      T.format('engineGitFailed', [reasonOf(stopped)]),
      ..._output,
      ...stopped.tail.where((line) => !_output.contains(line)),
    ].join('\n');
  }

  void copyFailure() {
    app.services.copyText?.call(failureText);
    app.show(T.text('engineGitCopied'));
  }

  /// The installed games made with another engine build than the one in use.
  List<Game> outdatedGames() => [
    for (final game in app.games)
      if (app.stateOf(game) case Installed(outdated: true)) game,
  ];

  /// Unlocks again every installed game made with the build before.
  void relinkAll() {
    final games = outdatedGames();
    if (games.isEmpty) return;
    for (final game in games) {
      app.unlock(game, copy: true);
    }
    app.show(T.format('engineGitRelinking', [games.length]));
  }

  /// Whether Play first looks at the remote: the setting is on and the engine is a checkout.
  bool get updatesBeforePlay => app.preferences.engineGitBeforePlay && checkout != null;

  /// Play with Update from Git Before Playing on: the remote is asked for new commits (offline,
  /// nothing is said and the game starts); with new ones the checkout is pulled and built, then
  /// the game is unlocked again and started. [play] starts the game as Play would have.
  Future<void> beforePlay(Game game, void Function() play) async {
    if (running || checking) {
      app.show(progressText());
      return;
    }
    final checkout = this.checkout;
    if (checkout == null) return play();
    // Another game is being unlocked with the build as it is: no build now, the game plays.
    if (app.unlocking) return play();
    checking = true;
    forGame = game.id;
    app.refresh();
    bool? needed;
    try {
      needed = await _gitFor(checkout).needsUpdate(built: app.preferences.engineGitBuilt[checkout.root]);
    } finally {
      checking = false;
      // Nothing to build (or the remote did not answer): the game no longer waits on the engine.
      if (needed != true) forGame = null;
      app.refresh();
    }
    if (needed != true) return play();
    // An unlock began while the remote was asked: the build would rewrite what it uses.
    if (app.unlocking) {
      forGame = null;
      return play();
    }
    app.show(T.text('engineGitBeforePlayStart'));
    final bool done;
    try {
      done = await update(quiet: true);
    } finally {
      forGame = null;
    }
    if (!done) {
      final stopped = failure;
      // Stopped by the player: nothing starts.
      if (stopped == null) return app.show(T.text('engineGitStopped'));
      // Nothing changed (a tree with changes, offline, no CMake): the current build plays.
      if (stopped.untouched) {
        app.show(T.format('engineGitPlayAnyway', [reasonOf(stopped)]));
        return play();
      }
      app.sounds.play(Cue.back);
      return app.show(T.format('engineGitFailed', [reasonOf(stopped)]));
    }
    if (app.stateOf(game) case Installed(outdated: true)) return app.updateAndPlay(game);
    play();
  }

  /// "Updating from git · Building the relinker and libraries", or the check before a game.
  String progressText() {
    final now = step;
    if (now == null) return T.text('engineGitChecking');
    return T.format('engineGitRunning', [stepName(now)]);
  }

  /// The rows after Use My Own Folder when it is a git checkout.
  List<PanelRow> rows() {
    final checkout = this.checkout;
    if (checkout == null) return const [];
    final build = checkout.buildFolder;
    final now = step;
    final stopped = failure;
    final outdated = updated && now == null ? outdatedGames().length : 0;
    return [
      if (now != null)
        PanelRow(
          id: 'engineGitUpdate',
          title: T.format('engineGitRunning', [stepName(now)]),
          detail: [...lines.map((line) => line.trim()), T.text('engineStop')].join(' · '),
          kind: ActionRow(cancel),
        )
      else if (build == null)
        PanelRow(
          id: 'engineGitUpdate',
          title: T.text('engineGitUpdate'),
          detail: T.text('engineGitSetUpDetail'),
          kind: ActionRow(() => unawaited(update())),
        )
      else
        PanelRow(
          id: 'engineGitUpdate',
          title: T.text('engineGitUpdate'),
          detail: T.format('engineGitUpdateDetail', [p.relative(build, from: checkout.root)]),
          kind: ActionRow(() => unawaited(update())),
        ),
      if (now == null && stopped != null)
        PanelRow(
          id: 'engineGitFailed',
          title: T.format('engineGitFailed', [reasonOf(stopped)]),
          detail: [
            ...(stopped.tail.isEmpty ? _output : stopped.tail).reversed
                .take(2)
                .toList()
                .reversed
                .map((line) => line.trim()),
            T.text('engineGitCopy'),
          ].join(' · '),
          kind: ActionRow(copyFailure),
        ),
      // Tools to install: each command to copy, the ones that install for the user also to run
      // here, and Check again once they are in (PATH is read anew, no restart).
      if (now == null && installing == null && stopped != null && stopped.missing.isNotEmpty) ...[
        for (final (index, fix) in fixes.indexed) ...[
          PanelRow(
            id: 'engineGitFixCopy$index',
            title: T.format(fix.admin ? 'engineGitFixCopyAdmin' : 'engineGitFixCopy', [fixNames(fix)]),
            detail: fix.line,
            wraps: true,
            kind: ActionRow(() => copyFix(fix)),
          ),
          if (fix.runnable)
            PanelRow(
              id: 'engineGitFixRun$index',
              title: T.format('engineGitFixRun', [fixNames(fix)]),
              detail: T.text('engineGitFixRunDetail'),
              kind: ActionRow(() => unawaited(installFix(fix))),
            ),
        ],
        PanelRow(
          id: 'engineGitRecheck',
          title: T.text('engineGitRecheck'),
          detail: T.text('engineGitRecheckDetail'),
          kind: ActionRow(() => unawaited(recheck())),
        ),
      ],
      if (installing case final InstallCommand fix)
        PanelRow(
          id: 'engineGitFixRunning',
          title: T.format('engineGitFixRunning', [fixNames(fix)]),
          detail: [...lines.map((line) => line.trim()), T.text('engineStop')].join(' · '),
          kind: ActionRow(cancel),
        ),
      // A tool to install, or CMake's setup: the guide of this tree says how.
      if (now == null && stopped != null && stopped.guideHelps)
        PanelRow(
          id: 'engineGitGuide',
          title: T.text(checkout.isArm ? 'engineGitGuideArm' : 'engineGitGuideUpstream'),
          detail: '${guide.host}${guide.path}',
          kind: ActionRow(() => app.services.openUrl?.call(guide)),
        ),
      if (outdated > 0)
        PanelRow(
          id: 'engineGitRelinkAll',
          title: T.text('engineGitRelinkAll'),
          detail: T.format('engineGitRelinkAllDetail', [outdated]),
          kind: ActionRow(relinkAll),
        ),
      PanelRow(
        id: 'engineGitBeforePlay',
        title: T.text('engineGitBeforePlay'),
        detail: T.text('engineGitBeforePlayDetail'),
        kind: ToggleRow(app.preferences.engineGitBeforePlay, (value) {
          app.preferences.engineGitBeforePlay = value;
          app.savePreferences();
          app.refresh();
        }),
      ),
    ];
  }
}
