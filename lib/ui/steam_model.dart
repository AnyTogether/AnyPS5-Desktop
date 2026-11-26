import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../core/game_library.dart';
import '../core/steam/steam_install.dart';
import '../core/steam/steam_launch.dart';
import '../core/steam/steam_shortcuts.dart';
import 'app_model.dart';
import 'steam_art.dart';
import 'strings.dart';

/// What adding to or removing from Steam waits for.
enum SteamTask { add, remove }

/// Settings › Steam: AnyPS5 (and, opted in, every unlocked game) as non-Steam games in the
/// Steam library with artwork, for Big Picture, Steam Input and the Steam Deck. Steam is found
/// where it installs itself, the account signed in last is used unless another is chosen, and
/// shortcuts.vdf is written only while Steam is closed.
class SteamModel {
  SteamModel(this.app);

  final AppModel app;

  // What tests replace.

  late Future<List<SteamInstall>> Function() find = () =>
      SteamLocator.find(system: app.system, environment: app.services.environment);
  late SteamControl Function(SteamInstall) control = (install) => SteamControl(install, system: app.system);

  /// The program the shortcuts start.
  late String Function() program = () => SteamPlan.program(
    resolvedExecutable: Platform.resolvedExecutable,
    environment: app.services.environment ?? Platform.environment,
  );
  late Future<Map<SteamArt, Uint8List>> Function() launcherArt = () =>
      SteamArtist.launcher(accent: app.accentChoice.color);
  late Future<Map<SteamArt, Uint8List>> Function(Game) gameArt = (game) =>
      SteamArtist.game(name: game.name, background: game.background, cover: game.icon, accent: app.accentChoice.color);

  /// The user's home folder, shown as ~ in the Steam folder's path.
  late String? Function() homeFolder = () {
    final env = app.services.environment ?? Platform.environment;
    return env['HOME'] ?? env['USERPROFILE'];
  };

  String _shown(String path) {
    final home = homeFolder();
    if (home == null || home.isEmpty || !path.startsWith(home)) return path;
    final rest = path.substring(home.length);
    return rest.isEmpty || rest.startsWith(Platform.pathSeparator) || rest.startsWith('/') ? '~$rest' : path;
  }

  // State.

  List<SteamInstall>? _installs;
  bool _looking = false;

  /// The accounts of every Steam found, the one signed in last first.
  List<(SteamInstall, SteamUser)> accounts = const [];

  /// AnyPS5's entries in the chosen account now.
  int inSteam = 0;

  /// Steam was open when asked: the rows offer to close it.
  SteamTask? waiting;

  /// What is going on now (closing Steam, drawing), null when idle.
  String? working;

  /// Steam was closed by the launcher to write: the rows offer to open it again.
  bool closedSteam = false;

  SteamLaunch get launch => app.steamLaunch;

  /// Looks for Steam again (once at first, then after each change).
  Future<void> scan() async {
    if (_looking) return;
    _looking = true;
    try {
      final installs = await find();
      _installs = installs;
      accounts = [
        for (final install in installs)
          for (final user in install.users()) (install, user),
      ];
      _count();
    } on Object {
      _installs = const [];
      accounts = const [];
    } finally {
      _looking = false;
      app.refresh();
    }
  }

  /// The account the shortcuts go to: the one chosen, else the one signed in last.
  (SteamInstall, SteamUser)? get account {
    if (accounts.isEmpty) return null;
    final chosen = app.preferences.steamUser;
    return accounts.where((entry) => '${entry.$1.root}|${entry.$2.id}' == chosen).firstOrNull ?? accounts.first;
  }

  SteamShortcuts? get _shortcuts => switch (account) {
    (final SteamInstall install, final SteamUser user) => SteamShortcuts(install, user),
    null => null,
  };

  void _count() => inSteam = _shortcuts?.ours().length ?? 0;

  /// Settings › Steam › Restore all: the account signed in last, no shortcut per game, full
  /// screen from Steam. The shortcuts already in Steam stay until Add to Steam writes them again.
  void restoreDefaults() {
    app.preferences
      ..steamUser = null
      ..steamGames = false
      ..steamFullscreen = true;
    _count();
  }

  void chooseAccount(int index) {
    if (index < 0 || index >= accounts.length) return;
    final (install, user) = accounts[index];
    app.preferences.steamUser = '${install.root}|${user.id}';
    app.savePreferences();
    _count();
    app.refresh();
  }

  /// The games with their own shortcut when games are on: the unlocked ones.
  List<Game> get _games => [
    for (final game in app.games)
      if (app.records.containsKey(game.id)) game,
  ];

  Future<void> add({bool closeSteam = false}) => _run(SteamTask.add, closeSteam: closeSteam);

  Future<void> remove({bool closeSteam = false}) => _run(SteamTask.remove, closeSteam: closeSteam);

  void cancel() {
    waiting = null;
    app.refresh();
  }

  Future<void> _run(SteamTask task, {required bool closeSteam}) async {
    final target = account;
    if (target == null || working != null) return;
    final (install, user) = target;
    final steam = control(install);
    if (await steam.running()) {
      // Closing Steam from a launcher Steam started would close the launcher too; in Game
      // Mode Steam is the whole screen.
      if (launch.fromSteam || launch.gameMode) {
        waiting = null;
        app.show(T.text('steamFromSteam'));
        app.refresh();
        return;
      }
      if (!closeSteam) {
        waiting = task;
        app.refresh();
        return;
      }
      working = T.text('steamClosing');
      app.refresh();
      final closed = await steam.shutdown();
      if (!closed) {
        working = null;
        app.show(T.text('steamWouldNotClose'));
        app.refresh();
        return;
      }
      closedSteam = true;
    }
    waiting = null;
    final shortcuts = SteamShortcuts(install, user);
    try {
      if (task == SteamTask.add) {
        working = T.text('steamWorking');
        app.refresh();
        final fullscreen = app.preferences.steamFullscreen;
        final path = program();
        final games = app.preferences.steamGames ? _games : const <Game>[];
        final entries = [
          SteamEntry(
            SteamPlan.launcher(path, fullscreen: fullscreen, into: shortcuts),
            art: await launcherArt(),
          ),
          for (final game in games)
            SteamEntry(
              SteamPlan.game(path, name: game.name, titleId: game.titleId, fullscreen: fullscreen, into: shortcuts),
              art: await gameArt(game),
            ),
        ];
        shortcuts.put(entries);
        app.show(
          T.format('steamAdded', [
            games.isEmpty ? T.text('steamInSteamLauncher') : T.format('steamInSteamGames', [games.length]),
          ]),
        );
      } else {
        final change = shortcuts.remove();
        app.show(T.text(change.appIds.isEmpty ? 'steamNothing' : 'steamRemoved'));
      }
    } on Object catch (error) {
      app.show(T.format('steamFailed', [error is FileSystemException ? error.message : '$error']));
    } finally {
      working = null;
      _count();
      app.refresh();
    }
  }

  void openSteam() {
    closedSteam = false;
    app.services.openUrl?.call(Uri.parse('steam://open/games'));
    app.refresh();
  }

  // The settings.

  List<PanelRow> settingsRows() {
    if (_installs == null) {
      unawaited(scan());
      return [PanelRow(id: 'steamLooking', title: T.text('steam'), kind: InfoRow(T.text('steamLooking')))];
    }
    final chosen = account;
    if (chosen == null) {
      return [
        PanelRow(id: 'steamMissing', title: T.text('steamNotFound'), kind: InfoRow(T.text('steamNotFoundDetail'))),
      ];
    }
    final (install, _) = chosen;
    final games = app.preferences.steamGames;
    final count = inSteam;
    return [
      PanelRow(
        id: 'steamWhere',
        title: T.text('steam'),
        kind: InfoRow(install.flatpak ? T.format('steamFlatpak', [_shown(install.root)]) : _shown(install.root)),
      ),
      if (install.flatpak)
        PanelRow(id: 'steamFlatpakNote', title: 'Flatpak', kind: InfoRow(T.text('steamFlatpakNote'))),
      if (accounts.length > 1)
        PanelRow(
          id: 'steamAccount',
          title: T.text('steamAccount'),
          kind: ChoiceRow([for (final (_, user) in accounts) user.label], accounts.indexOf(chosen), chooseAccount),
        )
      else
        PanelRow(id: 'steamAccount', title: T.text('steamAccount'), kind: InfoRow(chosen.$2.label)),
      PanelRow(
        id: 'steamInSteam',
        title: T.text('steamInSteam'),
        kind: InfoRow(switch (count) {
          0 => T.text('steamNotInSteam'),
          1 => T.text('steamInSteamLauncher'),
          _ => T.format('steamInSteamGames', [count - 1]),
        }),
      ),
      PanelRow(
        id: 'steamGames',
        title: T.text('steamGames'),
        detail: T.text('steamGamesDetail'),
        kind: ToggleRow(games, (value) {
          app.preferences.steamGames = value;
          app.savePreferences();
        }),
      ),
      PanelRow(
        id: 'steamFullscreen',
        title: T.text('steamFullscreen'),
        kind: ToggleRow(app.preferences.steamFullscreen, (value) {
          app.preferences.steamFullscreen = value;
          app.savePreferences();
        }),
      ),
      if (working case final String doing)
        PanelRow(id: 'steamWorking', title: doing, kind: const InfoRow(''))
      else if (waiting case final SteamTask task) ...[
        PanelRow(id: 'steamRunning', title: T.text('steamRunning'), kind: InfoRow(T.text('steamRunningDetail'))),
        PanelRow(
          id: 'steamClose',
          title: T.text(task == SteamTask.add ? 'steamCloseAndAdd' : 'steamCloseAndRemove'),
          kind: ActionRow(
            () => unawaited(task == SteamTask.add ? add(closeSteam: true) : remove(closeSteam: true)),
            destructive: task == SteamTask.remove,
          ),
        ),
        PanelRow(id: 'steamCancel', title: T.text('cancel'), kind: ActionRow(cancel)),
      ] else ...[
        PanelRow(
          id: 'steamAdd',
          title: T.text(count > 0 ? 'steamUpdate' : 'steamAdd'),
          detail: T.text('steamAddDetail'),
          kind: ActionRow(() => unawaited(add())),
        ),
        if (closedSteam) PanelRow(id: 'steamOpen', title: T.text('steamOpen'), kind: ActionRow(openSteam)),
        if (count > 0)
          PanelRow(
            id: 'steamRemove',
            title: T.text('steamRemove'),
            detail: T.text('steamRemoveDetail'),
            kind: ActionRow(() => unawaited(remove()), destructive: true),
          ),
      ],
    ];
  }
}
