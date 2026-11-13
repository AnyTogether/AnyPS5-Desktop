import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../core/audio/tones.dart' show Cue;
import '../core/crash_report.dart';
import '../core/deep_link.dart';
import '../core/game_library.dart';
import '../core/game_log.dart';
import '../core/game_settings.dart';
import '../core/host.dart';
import '../core/online/online_play.dart' show OnlineHost;
import 'app_model.dart';
import 'engine_model.dart';
import 'strings.dart';
import 'together_model.dart' show launcherVersion;

/// What the launcher was started with: `--trace` gives every start of this run detailed logging.
class LaunchOptions {
  const LaunchOptions({this.trace = false, this.steam = false, this.fullscreen = false, this.play, this.link});

  factory LaunchOptions.parse(List<String> arguments) {
    final at = arguments.indexOf('--play');
    final play = at >= 0 && at + 1 < arguments.length ? arguments[at + 1] : null;
    return LaunchOptions(
      trace: arguments.contains('--trace'),
      steam: arguments.contains('--steam'),
      fullscreen: arguments.contains('--fullscreen'),
      play: play == null || play.startsWith('--') ? null : play,
      link: DeepLink.inArguments(arguments),
    );
  }

  final bool trace;

  /// Started by one of AnyPS5's Steam shortcuts.
  final bool steam;

  /// The window full screen from the start (the runners read it before Flutter does).
  final bool fullscreen;

  /// The title ID of a game to start at once (a game's Steam shortcut).
  final String? play;

  /// The anyps5:// link the system started the launcher for.
  final DeepLink? link;
}

/// What the launcher knows about a game's last start beyond its log.
class LastSession {
  LastSession({required this.started, required this.traced});

  final DateTime started;
  final bool traced;
  DateTime? ended;
  int? exitCode;
  bool stoppedByUser = false;

  /// Why it stopped, read from the end of its log as it ended.
  Diagnosis? diagnosis;
}

/// The report of one game's last start, as the crash panel shows it.
class CrashReportState {
  CrashReportState(this.game, {required this.afterCrash});

  final Game game;

  /// Opened because the game stopped, not from its options.
  final bool afterCrash;

  /// Read away from the interface; null until then.
  SessionReport? report;
  IssueDraft? engineIssue;
  IssueDraft? launcherIssue;

  /// The end of the log the panel shows, cleaned like the report.
  List<String> tail = const [];

  /// The step that shows what the issue carries before it opens.
  bool sharing = false;
}

/// The crash report of a game's last start and detailed logging, as on the Mac: offered when a
/// game stops on an error (not when the user closed it), and in the game's options for the last
/// start. It saves crash_log.txt where the user picks, copies the report, and opens a pre-filled
/// issue on the engine's repository (upstream's or AnyPS5-ARM's) or the launcher's.
class CrashModel {
  CrashModel(this.app);

  final AppModel app;

  /// Each game's last start in this run, by title ID.
  final Map<String, LastSession> lastSessions = {};

  /// The panel's report while it is open.
  CrashReportState? current;

  /// `--trace` on the launcher's command line: every start of this run logs in detail.
  bool traceAll = false;

  /// The report being read, or the file being saved, for tests to wait on.
  Future<void>? pending;

  Future<SystemInfo>? _system;

  /// Whether a start of [game] logs in detail: the setting, `--trace`, or [once].
  bool traced(GameSettings settings, {bool once = false}) => once || traceAll || settings.trace == true;

  /// A start of [game] begins.
  void started(Game game, {required bool traced}) {
    lastSessions[game.titleId] = LastSession(started: DateTime.now(), traced: traced);
    if (traced) app.show(T.text('traceOnNotice'));
  }

  /// [game] ended with [code]; [stopped] when the user closed it. A stop on an error offers the
  /// report.
  void ended(Game game, int code, {required bool stopped}) {
    final last = lastSessions[game.titleId] ??= LastSession(started: DateTime.now(), traced: false);
    last
      ..ended = DateTime.now()
      ..exitCode = code
      ..stoppedByUser = stopped;
    if (code == 0 || stopped) return;
    final session = GameLog.lastSession(GameLog.tail(app.paths.logFile(game.titleId), 256 * 1024));
    last.diagnosis = Diagnosis.read(session, exitCode: code);
    offer(game);
  }

  /// The game stopped on an error: the report opens at once over the home screen (or the log),
  /// or a toast says why when something else is open.
  void offer(Game game) {
    final reason = switch (lastSessions[game.titleId]?.diagnosis) {
      final Diagnosis diagnosis => diagnosisText(diagnosis),
      null => T.text('gameEnded'),
    };
    if (app.overlay != null && app.overlay != Layer.log) {
      app.show('${game.name}: $reason');
      return;
    }
    unawaited(app.raiseLauncher());
    unawaited(open(game, afterCrash: true));
  }

  /// Opens the panel on [game]'s last start and reads its report away from the interface: the
  /// log of the start, the last unlock's output and this computer.
  Future<void> open(Game game, {required bool afterCrash}) {
    final state = CrashReportState(game, afterCrash: afterCrash);
    current = state;
    app.open(Layer.crashReport);
    final future = _read(state);
    pending = future;
    return future;
  }

  Future<void> _read(CrashReportState state) async {
    final game = state.game;
    final last = lastSessions[game.titleId];
    final input = _ReportInput(
      logFile: app.paths.logFile(game.titleId),
      unlockFile: GameLog.unlockFile(app.paths.logs, game.titleId),
      gameName: game.name,
      titleId: game.titleId,
      gameVersion: game.version,
      settings: app.launchSettings(game),
      system: await systemInfo(),
      platform: app.system == HostSystem.windows ? 'Windows' : 'Linux',
      privacy: privacy(),
      unlockedWith: app.records[game.id]?.toolkit,
      engineNow: app.toolkitVersion,
      relinkerFlags: app.records[game.id]?.relinkerFlags ?? const [],
      customRelinkerOptions: app.records[game.id]?.customRelinkerOptions ?? const [],
      exitCode: last?.exitCode,
      stoppedByUser: last?.stoppedByUser ?? false,
      traced: last?.traced,
      started: last?.started,
      ended: last?.ended,
      controllers: app.controllers.reportLines,
      onlineLog: OnlineHost.logFile(game.titleId, app.paths.onlineLogs),
    );
    final built = await _buildAway(input);
    if (!identical(current, state)) return;
    state
      ..report = built.report
      ..engineIssue = built.engine
      ..launcherIssue = built.launcher
      ..tail = built.tail;
    app.refresh();
  }

  /// This computer, read once (away from the interface where it costs).
  Future<SystemInfo> systemInfo() => _system ??=
      app.services.systemInfo?.call() ?? SystemInfo.current(app.system, environment: app.services.environment);

  /// What a report takes out: the home folder, the names of the user, the computer, the
  /// AnyTogether account and the profile, and the account's tokens.
  ReportPrivacy privacy() {
    final user = app.together.user;
    final profile = app.preferences.profileName.trim();
    return ReportPrivacy.current(
      system: app.system,
      environment: app.services.environment,
      names: [
        app.services.computerName ?? Platform.localHostname,
        ?user?.handle,
        ?user?.displayName,
        // The default name is a word the report needs, not someone's name.
        if (profile.isNotEmpty && profile != 'Player' && profile != T.text('profileDefaultName')) profile,
      ],
      secrets: app.together.account.secrets,
    );
  }

  /// Shows [report] for [game] without reading anything (previews and tests).
  @visibleForTesting
  void show(Game game, SessionReport report, {required bool afterCrash, bool sharing = false}) {
    final state = CrashReportState(game, afterCrash: afterCrash)
      ..report = report
      ..engineIssue = IssueDraft.engine(report)
      ..launcherIssue = IssueDraft.launcher(report)
      ..tail = report.logTail(48)
      ..sharing = sharing;
    current = state;
    app.open(Layer.crashReport);
  }

  /// The game's reason in the launcher's language.
  String reasonText(CrashReportState state) {
    final report = state.report;
    if (report == null) return T.text('reportReading');
    if (report.diagnosis case final Diagnosis diagnosis) return diagnosisText(diagnosis);
    return T.text(report.stoppedByUser ? 'reportClosedByUser' : 'reportNormal');
  }

  static String diagnosisText(Diagnosis diagnosis) => switch (diagnosis) {
    MissingModule(:final name) => T.format('diagnosisMissingModule', [name]),
    Unsupported(:final function) => T.format('diagnosisUnsupported', [function]),
    GpuLost() => T.text('diagnosisGpuLost'),
    OutOfMemory() => T.text('diagnosisOutOfMemory'),
    EngineError(:final message) => T.format('diagnosisEngineError', [message]),
    Crashed(:final exception) => T.format('diagnosisCrashed', [exception]),
    Aborted() => T.text('diagnosisAborted'),
    Exited(:final code) => T.format('diagnosisExited', [code]),
  };

  /// The panel's rows: the report's actions, or the issue's targets while what is shared shows.
  List<PanelRow> rows() {
    final state = current;
    if (state == null) return const [];
    final game = state.game;
    final saveRow = PanelRow(
      id: 'save',
      title: T.text('reportSave'),
      detail: T.text('reportSaveDetail'),
      kind: ActionRow(() => pending = save()),
    );
    if (state.sharing) {
      final engine = state.engineIssue?.repository ?? IssueDraft.engineRepository;
      return [
        PanelRow(
          id: 'github',
          title: T.text('reportGitHub'),
          detail: T.format('reportGitHubDetail', [engine]),
          kind: ActionRow(() => openIssue(launcher: false)),
        ),
        PanelRow(
          id: 'launcher',
          title: T.text('reportLauncher'),
          detail: T.text('reportLauncherDetail'),
          kind: ActionRow(() => openIssue(launcher: true)),
        ),
        saveRow,
        PanelRow(id: 'back', title: T.text('back'), kind: ActionRow(leaveSharing)),
      ];
    }
    final installed = app.records.containsKey(game.id);
    final playGo = installed && (state.report?.playGoChunksUnknown ?? false);
    return [
      // The dump has no PlayGo chunk table: AnyPS5-ARM's engine (for a game not made with it), or
      // this start only with the chunks it does not list counted as installed.
      if (playGo && !EngineModel.isArm(app.records[game.id]?.toolkit))
        PanelRow(
          id: 'playGoArm',
          title: T.text('reportPlayGoArm'),
          detail: T.text('reportPlayGoArmDetail'),
          kind: ActionRow(() => unawaited(switchToArmAndPlay(game))),
        ),
      if (playGo)
        PanelRow(
          id: 'playGoInstalled',
          title: T.text('reportPlayGoInstalled'),
          detail: T.text('reportPlayGoInstalledDetail'),
          kind: ActionRow(() {
            app.closeOverlay();
            unawaited(app.play(game, once: playGoInstalled));
          }),
        ),
      saveRow,
      PanelRow(id: 'copy', title: T.text('reportCopy'), detail: T.text('reportCopyDetail'), kind: ActionRow(copy)),
      PanelRow(
        id: 'issue',
        title: T.text('reportOpenIssue'),
        detail: T.text('reportOpenIssueDetail'),
        kind: ActionRow(enterSharing),
      ),
      PanelRow(id: 'log', title: T.text('reportShowLog'), kind: ActionRow(() => app.open(Layer.log))),
      if (app.records.containsKey(game.id))
        PanelRow(
          id: 'playTraced',
          title: T.text('reportPlayTraced'),
          detail: T.text('reportPlayTracedDetail'),
          kind: ActionRow(() {
            app.closeOverlay();
            unawaited(app.play(game, trace: true));
          }),
        ),
      PanelRow(id: 'close', title: T.text('close'), kind: ActionRow(app.closeOverlay)),
    ];
  }

  /// What "Play again with missing chunks counted as installed" starts the game with, once.
  static const playGoInstalled = {'APS5_PLAYGO_UNLISTED_CHUNKS': 'installed'};

  /// Switch to the AnyPS5-ARM Engine and Play Again: the engine downloaded when it is not on disk
  /// and used, then the game unlocked again with it and started (Update and Play).
  Future<void> switchToArmAndPlay(Game game) async {
    app.closeOverlay();
    if (!await app.engine.switchToArm()) return;
    app.updateAndPlay(game);
  }

  /// Back steps out of the shared text first; Options closes the panel.
  void command(Command command) {
    if (command == Command.back && current?.sharing == true) return leaveSharing();
    if (command == Command.back || command == Command.options) return app.closeOverlay();
    app.panelCommand(command);
  }

  void enterSharing() {
    final state = current;
    if (state == null || state.engineIssue == null) return;
    state.sharing = true;
    app.panelRow = 0;
    app.refresh();
  }

  void leaveSharing() {
    final state = current;
    if (state == null) return;
    app.sounds.play(Cue.back);
    state.sharing = false;
    app.panelRow = math.max(0, rows().indexWhere((row) => row.id == 'issue'));
    app.refresh();
  }

  void openIssue({required bool launcher}) {
    final state = current;
    final draft = launcher ? state?.launcherIssue : state?.engineIssue;
    if (state == null || draft == null) return;
    app.services.openUrl?.call(draft.url);
    app.show(T.format('reportIssueOpened', [state.report?.fileName ?? 'crash_log.txt']));
  }

  void copy() {
    final report = current?.report;
    if (report == null) return;
    app.services.copyText?.call(report.text());
    app.show(T.text('reportCopied'));
  }

  /// Asks where to save crash_log.txt and writes the report with the whole log of the start.
  Future<void> save() async {
    final report = current?.report;
    final pick = app.services.saveFile;
    if (report == null || pick == null) return;
    final path = await pick(report.fileName);
    if (path == null) return;
    try {
      final text = await _wholeText(report);
      await File(path).writeAsString(text);
      app.show(T.format('reportSavedTo', [path.split(RegExp(r'[\\/]')).last]));
    } on Object {
      app.show(T.text('reportSaveFailed'));
    }
  }
}

/// What the report is made from, sent to the isolate that reads the log.
class _ReportInput {
  const _ReportInput({
    required this.logFile,
    required this.unlockFile,
    required this.gameName,
    required this.titleId,
    required this.gameVersion,
    required this.settings,
    required this.system,
    required this.platform,
    required this.privacy,
    required this.unlockedWith,
    required this.engineNow,
    this.relinkerFlags = const [],
    this.customRelinkerOptions = const [],
    required this.exitCode,
    required this.stoppedByUser,
    required this.traced,
    required this.started,
    required this.ended,
    this.controllers = const [],
    this.onlineLog,
  });

  final String logFile;

  /// The game's online observation log; its last lines go in when it was written this start.
  final String? onlineLog;
  final List<String> controllers;
  final String unlockFile;
  final String gameName;
  final String titleId;
  final String gameVersion;
  final GameSettings settings;
  final SystemInfo system;
  final String platform;
  final ReportPrivacy privacy;
  final String? unlockedWith;
  final String? engineNow;
  final List<String> relinkerFlags;
  final List<String> customRelinkerOptions;
  final int? exitCode;
  final bool stoppedByUser;
  final bool? traced;
  final DateTime? started;
  final DateTime? ended;
}

typedef _Built = ({SessionReport report, IssueDraft engine, IssueDraft launcher, List<String> tail});

// Top-level, so the closures sent to the isolates hold only what they are given.
Future<_Built> _buildAway(_ReportInput input) => Isolate.run(() => _build(input));

Future<String> _wholeText(SessionReport report) => Isolate.run(() => report.text(whole: true));

/// The last lines of the game's online log, when it was written during the start reported (or,
/// for a start the launcher no longer remembers, in the last day).
List<String> _onlineLines(_ReportInput input) {
  final path = input.onlineLog;
  if (path == null) return const [];
  try {
    final written = File(path).lastModifiedSync();
    final since = (input.started ?? DateTime.now().subtract(const Duration(days: 1))).subtract(
      const Duration(minutes: 1),
    );
    if (written.isBefore(since)) return const [];
  } on FileSystemException {
    return const [];
  }
  return OnlineHost.lastLines(path, SessionReport.onlineTail);
}

_Built _build(_ReportInput input) {
  final session = GameLog.lastSession(GameLog.tail(input.logFile, 32 << 20));
  // A start the launcher no longer remembers: its exit code and detailed logging from the log.
  final code =
      input.exitCode ??
      int.tryParse(RegExp(r'^--- exit (-?\d+)\s*$', multiLine: true).allMatches(session).lastOrNull?.group(1) ?? '');
  final report = SessionReport(
    gameName: input.gameName,
    titleId: input.titleId,
    gameVersion: input.gameVersion,
    settings: input.settings,
    system: input.system,
    launcherVersion: launcherVersion,
    platform: input.platform,
    session: session,
    privacy: input.privacy,
    unlockedWith: input.unlockedWith,
    engineNow: input.engineNow,
    relinkerFlags: input.relinkerFlags,
    customRelinkerOptions: input.customRelinkerOptions,
    exitCode: code,
    stoppedByUser: input.stoppedByUser,
    traced: input.traced ?? GameLog.tracedStart(session),
    started: input.started,
    ended: input.ended,
    unlockLog: GameLog.read(input.unlockFile),
    controllers: input.controllers,
    onlineLines: _onlineLines(input),
  );
  return (
    report: report,
    engine: IssueDraft.engine(report),
    launcher: IssueDraft.launcher(report),
    tail: report.logTail(48),
  );
}
