import 'dart:io';

import 'package:path/path.dart' as p;

/// The system a game is relinked for and started on.
enum HostSystem {
  linux,
  windows;

  /// The system this process runs on; macOS (only for tests) counts as Linux, both POSIX.
  static HostSystem get current => Platform.isWindows ? HostSystem.windows : HostSystem.linux;

  /// The relinked executable's name in an installed game.
  String get executableName => this == HostSystem.windows ? 'app.exe' : 'app.elf';

  /// The relinker's own file name in the toolkit.
  String get relinkerName => this == HostSystem.windows ? 'relinker.exe' : 'relinker';

  /// The relinker options that select this system's output. Windows games are GUI subsystem
  /// executables, so starting one opens no console window; with its output handles given by
  /// the launcher it still writes its log to them.
  List<String> get relinkerOptions => this == HostSystem.windows ? const ['--windows', '--windows-gui'] : const [];

  /// The script that starts an installed game outside the launcher.
  String get launchScriptName => this == HostSystem.windows ? 'launch.cmd' : 'launch.sh';
}

/// Where the launcher keeps its own files, per system: settings, logs, caches, screenshots.
class AppPaths {
  AppPaths({
    required this.config,
    required this.logs,
    required this.cache,
    required this.pictures,
    required this.toolkits,
    String? onlineLogs,
  }) : onlineLogs = onlineLogs ?? p.join(logs, 'Online');

  /// The usual folders for [system], read from [environment] (Platform.environment by default).
  factory AppPaths.forSystem(HostSystem system, {Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    if (system == HostSystem.windows) {
      final profile = env['USERPROFILE'] ?? r'C:\Users\Public';
      final roaming = env['APPDATA'] ?? p.windows.join(profile, 'AppData', 'Roaming');
      final local = env['LOCALAPPDATA'] ?? p.windows.join(profile, 'AppData', 'Local');
      return AppPaths(
        config: p.windows.join(roaming, 'AnyPS5'),
        logs: p.windows.join(local, 'AnyPS5', 'Logs'),
        cache: p.windows.join(local, 'AnyPS5', 'Cache'),
        pictures: p.windows.join(profile, 'Pictures', 'AnyPS5'),
        toolkits: p.windows.join(local, 'AnyPS5', 'Toolkits'),
        onlineLogs: p.windows.join(local, 'AnyPS5', 'Logs', 'Online'),
      );
    }
    final home = env['HOME'] ?? '/tmp';
    String xdg(String name, String fallback) {
      final value = env[name];
      return value != null && value.isNotEmpty && p.posix.isAbsolute(value) ? value : p.posix.join(home, fallback);
    }

    return AppPaths(
      config: p.posix.join(xdg('XDG_CONFIG_HOME', '.config'), 'AnyPS5'),
      logs: p.posix.join(xdg('XDG_STATE_HOME', '.local/state'), 'AnyPS5', 'logs'),
      cache: p.posix.join(xdg('XDG_CACHE_HOME', '.cache'), 'AnyPS5'),
      pictures: p.posix.join(home, 'Pictures', 'AnyPS5'),
      toolkits: p.posix.join(xdg('XDG_DATA_HOME', '.local/share'), 'AnyPS5', 'Toolkits'),
      onlineLogs: p.posix.join(xdg('XDG_STATE_HOME', '.local/state'), 'AnyPS5', 'online'),
    );
  }

  /// Settings, paired phones, per-game choices.
  final String config;
  final String logs;

  /// Online play's observation logs, one per game (`<TitleID>.jsonl`, the engine writes them).
  final String onlineLogs;

  /// Shader caches, one folder per game.
  final String cache;

  /// F12 screenshots.
  final String pictures;

  /// The AnyPS5 engine toolkits the launcher downloaded, one folder per upstream version.
  final String toolkits;

  String get preferencesFile => p.join(config, 'preferences.json');
  String get gameSettingsFolder => p.join(config, 'games');

  /// The launcher profiles' book and each profile's own files ([ProfileStore]).
  String get profilesFolder => p.join(config, 'Profiles');
  String get inputFilesFolder => p.join(config, 'input');
  String get pairedDevicesFile => p.join(config, 'RemoteDevices.json');

  /// A fonts folder of the user's own at a fixed place (the first Desktop releases' only one);
  /// used as theirs when it exists and they chose no other.
  String get fontsFolder => p.join(config, 'fonts');

  /// The launcher's own fonts beside its toolkits (local, not roaming, on Windows): the
  /// downloaded Japanese, Chinese and Korean ones, and the folder games are given, put together
  /// from those, the built-in ones and the user's.
  String get downloadedFonts => p.join(p.dirname(toolkits), 'Fonts', 'Downloaded');
  String get gameFonts => p.join(p.dirname(toolkits), 'Fonts', 'Games');
  String get backupsFolder => p.join(config, 'Backups');

  /// The emulator host's PS1 BIOS folder (the core's system directory) and memory cards, where
  /// protocol.md's `start` example keeps them.
  String get retroSystem => p.join(config, 'retro', 'system');
  String get retroSaves => p.join(config, 'retro', 'saves', 'ps1');

  String logFile(String titleId) => p.join(logs, '$titleId.log');
  String shaderCache(String slug) => p.join(cache, slug, 'shader_cache');
}
