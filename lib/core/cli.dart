import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'controllers/pad_check.dart';
import 'controllers/troubleshooter.dart';
import 'game_library.dart';
import 'glibc.dart';
import 'game_process.dart';
import 'game_presets.dart';
import 'game_settings.dart';
import 'profiles/profiles.dart';
import 'host.dart';
import 'installer.dart';
import 'remote/mdns.dart';
import 'remote/paired_devices.dart';
import 'remote/remote_protocol.dart';
import 'remote/remote_server.dart';
import 'self_unwrap.dart';
import 'steam/steam_install.dart';
import 'steam/steam_shortcuts.dart';
import 'toolkit.dart';
import 'toolkit_download.dart';

const usage = '''usage: anyps5_tool <command>
  unwrap <self> <elf>                      a decrypted SELF container as a clean ELF
  scan <games folder>...                   the dumps found, one per line (a title in several
                                           folders once, from the first)
  engine [<version>] [--folder <dir>]      download upstream's toolkit for this system (the latest
                                           release unless a version is given) into the launcher's
                                           toolkits folder, or <dir>; prints the toolkit's folder
  install <game folder> <games folder>     unwrap, relink and lay out (ANYPS5_TOOLKIT names the toolkit)
  play <game folder> <games folder> [--trace]
                                           start an installed game with its saved settings;
                                           --trace turns on the engine's detailed logging
  remote [--allow-all] [--hidden] [--port <port>] [--devices <file>] [--games <folder>]...
                                           the phone server until stopped
  steam status                             the Steam folders and accounts found, AnyPS5's shortcuts
  steam add --program <launcher> [--games <folder>]... [--fullscreen] [--user <id>] [--close-steam]
                                           AnyPS5 (and with --games each unlocked game) as non-Steam
                                           games, without artwork (Settings > Steam draws it)
  steam remove [--user <id>] [--close-steam]
                                           takes AnyPS5's shortcuts and pictures out of Steam
  pads [--sdl <library>] [--seconds <n>]   the controllers as the launcher reads them (SDL2) for n
                                           seconds (3), then what the troubleshooter finds''';

/// The launcher's pipeline on the command line, for scripted checks on a Windows or Linux
/// machine without the interface: the same code the launcher runs.
Future<int> runCli(
  List<String> arguments, {
  StringSink? out,
  StringSink? err,
  Map<String, String>? environment,
  HostSystem? system,
  Future<void>? until,
}) async {
  final output = out ?? stdout;
  final errors = err ?? stderr;
  final env = environment ?? Platform.environment;
  final host = system ?? HostSystem.current;
  int fail(String message) {
    errors.writeln(message);
    return 2;
  }

  if (arguments.isEmpty) return fail(usage);
  switch (arguments.first) {
    case 'unwrap' when arguments.length == 3:
      try {
        final size = SelfUnwrap.unwrapFile(arguments[1], arguments[2]);
        output.writeln('wrote ${arguments[2]}, $size bytes');
        return 0;
      } on SelfRefused catch (error) {
        return fail('FAIL: ${arguments[1]}: ${error.reason}');
      } on FileSystemException catch (error) {
        return fail('FAIL: ${arguments[1]}: ${error.message}');
      }
    case 'scan' when arguments.length >= 2:
      final library = GameLibrary.surveyAll(arguments.sublist(1));
      for (final game in library.games) {
        final installed =
            game.retro != null ||
            Installer.record(Installer.installedFolder(game, library.roots[game.id]!), system: host) != null;
        output.writeln(
          [game.titleId, game.name, game.executable.name, installed ? 'installed' : 'locked', game.folder].join('\t'),
        );
      }
      return 0;
    case 'engine':
      return _engine(arguments.skip(1).toList(), output, errors, env, host);
    case 'install' when arguments.length == 3:
      final toolkit = Toolkit.locate(const [], system: host, environment: env);
      if (toolkit == null) return fail('no toolkit: set ANYPS5_TOOLKIT');
      _glibcWarning(toolkit, host, env, output);
      final game = GameLibrary.inspect(arguments[1]);
      if (game == null) return fail('not a game folder: ${arguments[1]}');
      if (game.retro != null) return fail('Disc games are configured and launched from the desktop library.');
      final plan = Installer.plan(game, arguments[2]);
      if (plan.copies) {
        output.writeln(
          'note: ${(plan.bytes / 1e9).toStringAsFixed(1)} GB will be copied: the games folder cannot link to the dump '
          '(${host == HostSystem.windows ? 'another drive, and Windows makes symbolic links only with Developer Mode on' : 'a file system without links'}). '
          'Keep the games folder on the dump\'s drive${host == HostSystem.windows ? ', or turn on Developer Mode in Settings > System > For developers' : ''}.',
        );
      } else {
        output.writeln('files: ${plan.mode.name} links to the dump');
      }
      final paths = AppPaths.forSystem(host, environment: env);
      final settings = GameSettingsStore(paths.gameSettingsFolder).load(game.slug);
      final started = DateTime.now();
      final lastShown = <InstallStep, int>{};
      final installer = Installer(
        game: game,
        toolkit: toolkit,
        root: arguments[2],
        resolution: settings.resolution,
        onProgress: (step, fraction) {
          final percent = (fraction * 100).round();
          if (lastShown[step] == percent) return;
          lastShown[step] = percent;
          if (percent % 10 == 0) output.writeln('[${step.name} ${percent.toString().padLeft(3)}%]');
        },
        onLog: output.writeln,
      );
      try {
        final installed = await installer.run();
        final seconds = DateTime.now().difference(started).inMilliseconds / 1000;
        output.writeln('installed $installed in ${seconds.toStringAsFixed(1)} s');
        return 0;
      } on Object catch (error) {
        return fail('FAIL: $error');
      }
    case 'play' when arguments.length == 3 || (arguments.length == 4 && arguments[3] == '--trace'):
      final trace = arguments.length == 4;
      final game = GameLibrary.inspect(arguments[1]);
      if (game == null) return fail('not a game folder: ${arguments[1]}');
      final installed = Installer.installedFolder(game, arguments[2]);
      if (Installer.record(installed, system: host) == null) return fail('not installed: ${game.titleId}');
      if (await Installer.brokenLink(installed) case final String missing) {
        return fail("the game's dump moved ($missing is gone): unlock it again or put the dump back");
      }
      final paths = AppPaths.forSystem(host, environment: env);
      // Settings › Default Display for the display choices the game left at Default.
      final settings = GameSettingsStore(paths.gameSettingsFolder)
          .load(game.slug)
          .withDefaults(DisplayDefaults.load(paths.preferencesFile));
      final inputFile = p.join(paths.inputFilesFolder, '${game.slug}.ini');
      settings.writeInputFile(inputFile);
      final running = await GameProcess.start(
        installed: installed,
        system: host,
        environment: {
          ...settings.environment(
            launcherLanguage: 1,
            inputFile: inputFile,
            screenshots: paths.pictures,
            shaderCacheFolder: paths.shaderCache(game.slug),
            trace: trace,
          ),
          ...game.addonEnvironment,
          ...GamePresetsStore(_gamePresetsFile(paths)).load().environment,
        },
        logFile: paths.logFile(game.titleId),
        traced: trace || settings.trace == true,
      );
      output.writeln(
        'started ${game.titleId} (pid ${running.pid})${trace || settings.trace == true ? ' with detailed logging' : ''}, '
        'log ${paths.logFile(game.titleId)}',
      );
      final code = await running.exitCode;
      output.writeln('exit $code');
      return code;
    case 'steam' when arguments.length >= 2:
      return _steam(arguments.skip(1).toList(), output, errors, env, host);
    case 'pads':
      String? option(String name) {
        final index = arguments.indexOf(name);
        return index >= 0 && index + 1 < arguments.length ? arguments[index + 1] : null;
      }
      return padCheck(
        out: output,
        system: host,
        sdlPath: option('--sdl'),
        seconds: int.tryParse(option('--seconds') ?? '') ?? 3,
        probe: HostProbe(host, environment: env),
        executable: Platform.resolvedExecutable,
      );
    case 'remote':
      return _remote(arguments.skip(1).toList(), output, errors, env, host, until);
    default:
      return fail(usage);
  }
}

/// Says when a Linux toolkit's libraries need a newer glibc than this system has (ANYPS5_HOST_GLIBC
/// stands in for the system's version).
void _glibcWarning(Toolkit toolkit, HostSystem host, Map<String, String> env, StringSink output) {
  if (host != HostSystem.linux) return;
  final missing = Glibc.shortfall(toolkit.libraryFiles, host: env['ANYPS5_HOST_GLIBC'] ?? Glibc.host());
  if (missing == null) return;
  output.writeln(
    'warning: games need glibc ${missing.needed} or newer; this system has ${missing.host} '
    '(the engine was built for a newer Linux): they will not start here',
  );
}

/// The engine download the first start and Settings make, on the command line.
Future<int> _engine(
  List<String> options,
  StringSink output,
  StringSink errors,
  Map<String, String> env,
  HostSystem host,
) async {
  final at = options.indexOf('--folder');
  final folder = at >= 0 && at + 1 < options.length
      ? options[at + 1]
      : AppPaths.forSystem(host, environment: env).toolkits;
  final rest = [
    for (var i = 0; i < options.length; i++)
      if (i != at && i != at + 1) options[i],
  ];
  if (rest.length > 1) {
    errors.writeln(usage);
    return 2;
  }
  try {
    final github = GitHubReleases();
    final wanted = rest.isEmpty ? null : (rest.first.startsWith('v') ? rest.first.substring(1) : rest.first);
    final release = wanted == null
        ? await github.latest()
        : (await github.all()).where((release) => release.version == wanted).firstOrNull;
    if (release == null) {
      errors.writeln('no upstream release $wanted');
      return 2;
    }
    final package = release.packageFor(host);
    if (package == null) {
      errors.writeln('upstream ${release.tag} has nothing for ${host.name}');
      return 2;
    }
    output.writeln(
      'upstream ${release.tag}: ${package.relinker.name} + ${package.libraries.name}, '
      '${(package.size / 1048576).toStringAsFixed(1)} MB, ${package.verified ? 'sha256 from GitHub' : 'no checksum'}',
    );
    var shown = -1;
    final started = DateTime.now();
    final toolkit = await ToolkitStore(folder, system: host).install(
      package,
      onProgress: (progress) {
        final percent = (progress.fraction * 100).floor();
        if (progress.phase == ToolkitPhase.download && percent ~/ 10 != shown ~/ 10) {
          shown = percent;
          output.writeln('[download ${percent.toString().padLeft(3)}%]');
        } else if (progress.phase != ToolkitPhase.download) {
          output.writeln('[${progress.phase.name}]');
        }
      },
    );
    final seconds = DateTime.now().difference(started).inMilliseconds / 1000;
    output.writeln(
      'toolkit ${toolkit.version}: ${toolkit.libraryFiles.length} libraries in ${seconds.toStringAsFixed(1)} s',
    );
    _glibcWarning(toolkit, host, env, output);
    output.writeln(toolkit.root);
    return 0;
  } on ToolkitFailure catch (error) {
    errors.writeln('FAIL: ${error.message}');
    return 2;
  } on IOException catch (error) {
    errors.writeln('FAIL: $error');
    return 2;
  }
}

Future<int> _remote(
  List<String> options,
  StringSink output,
  StringSink errors,
  Map<String, String> env,
  HostSystem host,
  Future<void>? until,
) async {
  String? value(String name) {
    final at = options.indexOf(name);
    return at >= 0 && at + 1 < options.length ? options[at + 1] : null;
  }

  final allowAll = options.contains('--allow-all');
  final hidden = options.contains('--hidden');
  final port = int.tryParse(value('--port') ?? '') ?? RemoteServer.preferredPort;
  final devices = PairedDevices(value('--devices') ?? AppPaths.forSystem(host, environment: env).pairedDevicesFile);
  final games = GameLibrary.surveyAll(_values(options, '--games')).games;
  late final RemoteServer server;
  void publishLibrary() => server.publish(
    RemoteLibrary(
      games: [
        for (final game in games)
          RemoteGame(id: game.id, name: game.name, state: RemoteGameState.installed, art: game.titleId),
      ],
      selected: games.isEmpty ? null : games.first.id,
      language: 'en',
    ),
  );
  server = RemoteServer(
    name: Platform.localHostname,
    devices: devices,
    controlPort: port,
    events: RemoteEvents(
      pairing: (request) {
        output.writeln('pairing ${request.deviceName} code ${request.code}');
        if (allowAll) server.respond(request.id, allow: true);
      },
      connected: (name) {
        output.writeln('connected $name');
        publishLibrary();
      },
      disconnected: () => output.writeln('disconnected'),
      request: (message, device) => output.writeln('from $device: ${message.text}'),
      players: () => output.writeln('players ${server.phonePlayers}'),
    ),
  );
  try {
    await server.start();
  } on SocketException catch (error) {
    errors.writeln('the phone server did not start: ${error.message}');
    return 2;
  }
  ServiceAdvertiser? advertiser;
  if (!hidden) {
    advertiser = MdnsResponder(
      instance: Platform.localHostname,
      serviceType: RemoteServer.serviceType,
      port: server.port!,
    );
    try {
      await advertiser.start();
    } on Object catch (error) {
      errors.writeln('not advertised: $error');
      advertiser = null;
    }
  }
  output.writeln('listening on ${server.port}, pad on udp ${server.udpPort}, bridges ${server.bridgeEnvironment}');
  await (until ?? ProcessSignal.sigint.watch().first);
  await advertiser?.stop();
  await server.stop();
  return 0;
}

/// Settings › Steam on the command line.
Future<int> _steam(
  List<String> options,
  StringSink output,
  StringSink errors,
  Map<String, String> env,
  HostSystem host, {
  SteamControl Function(SteamInstall)? control,
}) async {
  String? value(String name) {
    final at = options.indexOf(name);
    return at >= 0 && at + 1 < options.length ? options[at + 1] : null;
  }

  final installs = await SteamLocator.find(system: host, environment: env);
  if (installs.isEmpty) {
    errors.writeln('Steam not found');
    return 2;
  }
  final accounts = [
    for (final install in installs)
      for (final user in install.users()) (install, user),
  ];
  if (options.first == 'status') {
    for (final install in installs) {
      final running = await (control ?? (i) => SteamControl(i, system: host))(install).running();
      output.writeln('steam ${install.root}${install.flatpak ? ' (flatpak)' : ''}${running ? ', running' : ''}');
      for (final user in install.users()) {
        final ours = SteamShortcuts(install, user).ours();
        output.writeln(
          '  user ${user.id} ${user.label}${user.mostRecent ? ' (signed in last)' : ''}: ${ours.length} AnyPS5 shortcuts',
        );
        for (final shortcut in ours) {
          output.writeln(
            '    ${ShortcutsFile.appIdOf(shortcut)} ${shortcut.string('AppName')} ${shortcut.string('Exe')} ${shortcut.string('LaunchOptions')}',
          );
        }
      }
    }
    return 0;
  }
  final wanted = value('--user');
  final account = wanted == null ? accounts.firstOrNull : accounts.where((entry) => entry.$2.id == wanted).firstOrNull;
  if (account == null) {
    errors.writeln(wanted == null ? 'no Steam account has signed in on this computer' : 'no Steam account $wanted');
    return 2;
  }
  final (install, user) = account;
  final steam = (control ?? (i) => SteamControl(i, system: host))(install);
  if (await steam.running()) {
    if (!options.contains('--close-steam')) {
      errors.writeln('Steam is running: close it first (or pass --close-steam)');
      return 3;
    }
    output.writeln('closing Steam');
    if (!await steam.shutdown()) {
      errors.writeln('Steam did not close');
      return 3;
    }
  }
  final shortcuts = SteamShortcuts(install, user);
  switch (options.first) {
    case 'add':
      final program = value('--program');
      if (program == null) {
        errors.writeln(usage);
        return 2;
      }
      final fullscreen = options.contains('--fullscreen');
      final library = GameLibrary.surveyAll(_values(options, '--games'));
      final games = [
        for (final game in library.games)
          if (Installer.record(Installer.installedFolder(game, library.roots[game.id]!), system: host) != null) game,
      ];
      final change = shortcuts.put([
        SteamEntry(SteamPlan.launcher(program, fullscreen: fullscreen, into: shortcuts)),
        for (final game in games)
          SteamEntry(
            SteamPlan.game(program, name: game.name, titleId: game.titleId, fullscreen: fullscreen, into: shortcuts),
          ),
      ]);
      output.writeln('added ${change.appIds.join(' ')} to ${change.shortcutsFile} (user ${user.id})');
      if (change.backup != null) output.writeln('backup ${change.backup}');
      return 0;
    case 'remove':
      final change = shortcuts.remove();
      output.writeln(
        change.appIds.isEmpty
            ? 'no AnyPS5 shortcuts in ${change.shortcutsFile}'
            : 'removed ${change.appIds.join(' ')} and ${change.artFiles.length} pictures',
      );
      return 0;
    default:
      errors.writeln(usage);
      return 2;
  }
}

/// The Game Presets of the profile the launcher last played as.
String _gamePresetsFile(AppPaths paths) {
  final store = ProfileStore(
    paths.profilesFolder,
    existing: const ExistingSetup(onboarded: false, name: ''),
    persist: false,
  );
  return p.join(paths.profilesFolder, store.book.currentProfile?.id ?? LauncherProfile.legacyId, 'GamePresets.json');
}

/// Every value given for the option [name] (`--games A --games B`), in order.
List<String> _values(List<String> options, String name) => [
  for (var at = 0; at + 1 < options.length; at++)
    if (options[at] == name) options[at + 1],
];
