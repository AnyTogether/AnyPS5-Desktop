import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse, PlatformDispatcher;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'ui/soloud_audio.dart';
import 'core/deep_link.dart';
import 'core/desktop/desktop.dart';
import 'core/desktop/file_types.dart';
import 'core/desktop/url_scheme.dart';
import 'core/link_relay.dart';
import 'core/now_playing_mpris.dart';
import 'core/desktop/linux_desktop.dart';
import 'core/desktop/window_backdrop.dart';
import 'core/desktop/windows_desktop.dart';
import 'core/controllers/pad_reader.dart';
import 'core/controllers/troubleshooter.dart';
import 'core/app_update.dart';
import 'core/child_processes.dart';
import 'core/ffmpeg_download.dart' show FfmpegBuild;
import 'core/github_contributors.dart';
import 'core/host.dart';
import 'core/opened_files.dart';
import 'core/launcher_health.dart';
import 'core/libmpv.dart';
import 'core/release_signing.dart';
import 'core/retro_host/retro_host_store.dart';
import 'core/steam/steam_launch.dart';
import 'core/toolkit_download.dart';
import 'ui/app_model.dart';
import 'ui/clip_player.dart';
import 'ui/components.dart' show FocusRing;
import 'ui/countries.dart';
import 'ui/crash_model.dart';
import 'ui/launcher.dart';
import 'ui/launcher_window_channel.dart';
import 'ui/layer_overlay_channel.dart';
import 'ui/now_playing_channel.dart';
import 'ui/profile_picture.dart';
import 'ui/sealed_photo.dart';
import 'ui/voice_note_player.dart';
import 'ui/sharing_model.dart';
import 'ui/startup_intro.dart';
import 'ui/strings.dart';
import 'ui/together_model.dart' show launcherVersion;
import 'ui/theme.dart';
import 'ui/trash_channel.dart';

/// Takes the window's close (and the other ways the launcher quits) to the launcher's health: a
/// run that closed as it should is no crash next time.
// ignore: unused_element
late final AppLifecycleListener _exit;

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  final paths = AppPaths.forSystem(HostSystem.current);
  final relayFile = LinkRelay.fileIn(paths.config);
  // A theme file opened while a launcher already runs goes to that one (as anyps5:// links do);
  // this one quits before it shows a window.
  final opened = OpenedFiles.of(arguments).where(LauncherThemes.isThemeFile).toList();
  if (opened.isNotEmpty) {
    var handed = true;
    for (final file in opened) {
      handed = await LinkRelay.send(relayFile, file) && handed;
    }
    if (handed) exit(0);
  }
  // The built-in languages, and any file a translator put in the Languages folder to try it.
  await T.load(tryOut: Directory(p.join(paths.config, 'Languages')));
  await Countries.load();
  final options = LaunchOptions.parse(arguments);
  // An anyps5:// link with a launcher already open: that one takes it, and this one quits before
  // it shows a window.
  if (options.link case final DeepLink link when await LinkRelay.send(relayFile, link.url)) exit(0);
  final padLog = Platform.environment['ANYPS5_PAD_LOG'];
  final DesktopWindows desktop = Platform.isWindows
      ? WindowsDesktop(
          log: padLog == null || padLog.isEmpty
              ? null
              : (line) {
                  try {
                    File(padLog)
                        .writeAsStringSync('${DateTime.now().toIso8601String()} $line\n', mode: FileMode.append);
                  } on FileSystemException {
                    // The log is a help, never a reason to stop.
                  }
                },
        )
      : LinuxDesktop(overlay: const ChannelLayerOverlay());
  final WindowBackdrop backdrop = switch (desktop) {
    final LinuxDesktop linux => LinuxBackdrop(linux),
    _ => Platform.isWindows ? WindowsBackdrop() : const NoBackdrop(),
  };
  // The launcher's own crashes and long stalls, offered as a report at the next start.
  final health = LauncherHealth(
    p.join(paths.logs, 'Launcher'),
    version: launcherVersion,
    platform: Platform.isWindows ? 'Windows' : 'Linux',
  );
  StallWatch? watch;
  const window = ChannelLauncherWindow();
  // Quit: the marker says closing, then the window closes as its title bar's close does.
  final shutdown = LauncherShutdown(
    health: health,
    beforeClose: () => watch?.closing(),
    closeWindow: window.close,
    exit: (code) {
      ChildProcesses.killAll();
      exit(code);
    },
  );
  void closing() {
    watch?.closing();
    health.closing();
  }

  if (SystemLibmpv.missing) debugPrint('libmpv is not installed: clips and voice notes say how to install it');
  final model = AppModel(
    paths: paths,
    services: LauncherServices(
      // Delete game: the Recycle Bin on Windows; Linux asks the desktop's own tool.
      trash: Platform.isWindows ? const ChannelTrash() : null,
      pickFolder: (title) => getDirectoryPath(confirmButtonText: title),
      openFolder: (folder) => unawaited(Process.run(Platform.isWindows ? 'explorer' : 'xdg-open', [folder])),
      openUrl: (url) => unawaited(
        Platform.isWindows
            ? Process.run('rundll32', ['url.dll,FileProtocolHandler', url.toString()])
            : Process.run('xdg-open', [url.toString()]),
      ),
      // Clips play inside the launcher (libmpv); the system's player when one cannot be opened.
      // On Linux the system's libmpv, looked for here once (SystemLibmpv.missing): without it
      // the launcher still starts, and clips and voice notes say how to install it.
      clipPlayback: MediaKitClipPlayback.new,
      voicePlayback: MediaKitVoicePlayback.new,
      copyText: (text) => unawaited(Clipboard.setData(ClipboardData(text: text))),
      pickImage: () async => (await openFile(
        acceptedTypeGroups: const [XTypeGroup(label: 'Pictures', extensions: ProfilePicture.extensions)],
      ))?.path,
      pickPictures: () async => [
        for (final file in await openFiles(
          acceptedTypeGroups: const [XTypeGroup(label: 'Pictures', extensions: SealedPhoto.extensions)],
        ))
          file.path,
      ],
      saveFile: (name) async => (await getSaveLocation(
        suggestedName: name,
        acceptedTypeGroups: const [
          XTypeGroup(label: 'Text', extensions: ['txt']),
        ],
      ))?.path,
      saveFileAs: (name, label, extensions) async => (await getSaveLocation(
        suggestedName: name,
        acceptedTypeGroups: [XTypeGroup(label: label, extensions: extensions)],
      ))?.path,
      pickFile: (label, extensions) async => (await openFile(
        acceptedTypeGroups: extensions.isEmpty ? const [] : [XTypeGroup(label: label, extensions: extensions)],
      ))?.path,
      pickFileAt: (label, extensions, folder) async => (await openFile(
        initialDirectory: folder,
        acceptedTypeGroups: [XTypeGroup(label: label, extensions: extensions)],
      ))?.path,
      engineReleases: GitHubReleases(),
      launcherReleases: LauncherUpdates.source(),
      contributors: GithubContributors(),
      audio: SoloudAudio.new,
      armEngineReleases: GitHubReleases(
        repository: ArmToolkitPackage.repository,
        signingKeys: ReleaseSigning.trustedKeys,
      ),
      ffmpegReleases: GitHubReleases(repository: FfmpegBuild.repository, signingKeys: ReleaseSigning.trustedKeys),
      retroHostReleases: GitHubReleases(repository: RetroHostStore.repository, signingKeys: ReleaseSigning.trustedKeys),
      // SDL2 (beside the launcher on Windows, the system's on Linux), else XInput and winmm or evdev.
      pads: () => PadReader.open(arguments: arguments),
      systemProbe: () => HostProbe(HostSystem.current),
      desktop: desktop,
      backdrop: backdrop,
      window: window,
      // Now playing: Windows' media session through the runner, MPRIS on the session bus on Linux.
      nowPlaying: () => Platform.isWindows ? ChannelNowPlaying() : MprisNowPlaying(),
      quit: (code) => unawaited(shutdown.quit(code)),
    ),
  );
  // An update left for this launch (Later) goes in first: its installer opens the launcher again.
  if (await model.updates.applyPendingAtLaunch()) exit(0);
  model
    ..launcherProblem = health.start()
    ..onLauncherProblemDone = health.forget
    ..lookAgainLauncherProblem = health.lookAgain;
  // The runner takes this run's marker away once the window has closed and Flutter has shut
  // down: a crash while closing still leaves it for the next start to report.
  health.runnerRemovesMarker = await window.removeAfterClose(health.markerPath);
  _exit = AppLifecycleListener(
    onExitRequested: () async {
      // Every close of the window comes through here (the title bar, Alt+F4, the taskbar, and
      // the launcher's own quit): a user's unlock under way, paused or waiting asks first. A
      // close the launcher started after the answer (LauncherShutdown.quit) goes through.
      if (!model.allowExit()) return AppExitResponse.cancel;
      closing();
      // A PS1 game in the emulator host is saved first: the host stops it and exits.
      await model.shutDownRetroHosts();
      // The game is asked to close and given time to save, then ffmpeg, the relinker and the
      // rest end with the launcher.
      await model.endChildProcesses();
      // A Quit's fallback timer starts here, not before: the game's time to save is not counted.
      shutdown.childrenEnded();
      // Only now: the question, the "Cancel and quit" seconds and the game's closing do not count
      // against the runner's five seconds for a shutdown that hangs.
      await window.armExitWatchdog();
      return AppExitResponse.exit;
    },
  );
  // Errors the launcher's code does not catch: the first is kept for a report, shown as before.
  FlutterError.onError = (details) {
    model.firstError ??= '${details.exceptionAsString()}\n${details.stack ?? ''}';
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    model.firstError ??= '$error\n$stack';
    return false;
  };
  // The watchdog, from its own isolate; not under a debugger, whose pauses would read as stalls.
  if (!kDebugMode) {
    unawaited(
      StallWatch.start(health, started: DateTime.now()).then((started) {
        watch = started;
        // The last seconds go along as each line comes (a line a second), as on the Mac: a
        // stall's report then says what the launcher did up to its last second.
        final feed = PingFeed();
        Timer.periodic(const Duration(milliseconds: 250), (_) {
          final (:lines, :error) = feed.next(
            added: model.recentLinesAdded,
            lines: model.recentLines,
            error: model.firstError,
          );
          started.ping(lines: lines, error: error);
        });
      }),
    );
  }
  model.crash.traceAll = options.trace;
  model.steamLaunch = SteamLaunch.detect(arguments, Platform.environment);
  // Full screen the first time, then as the user left it (F11, Settings › Appearance); Steam's
  // --fullscreen and Game Mode keep the whole screen whatever the choice.
  if (!options.fullscreen && !model.steamLaunch.gameMode) unawaited(model.applyLauncherWindow());
  // The runner made Steam's --fullscreen window full screen: the window buttons wait at its top.
  if (options.fullscreen) model.windowFullscreen = true;
  unawaited(model.startAudio());
  model.startPads();
  model.powerWatch.start();
  if (model.preferences.onboarded) model.rescan();
  model.watchGamesFolders();
  unawaited(model.startPhoneServer());
  // Several profiles (or Ask every time): "Who's playing?" first, the session waiting for the pick.
  model.startProfiles();
  unawaited(model.together.start());
  unawaited(model.saveSync.refreshInfo());
  unawaited(model.engine.startupCheck());
  unawaited(model.updates.startupCheck());
  // The home screen's start animation plays in the real launcher only: previews and tests
  // build the home screen without it.
  StartupIntro.enabled = true;
  // The home tiles' focus ring moves (tests leave it still).
  FocusRing.enabled = true;
  runApp(AnyPS5App(model: model));
  // .anyps5theme files open with this launcher (the zip, the AppImage and the archive install
  // nothing that would say so); not for a development build.
  if (!kDebugMode) {
    unawaited(
      ThemeFileType(
        system: HostSystem.current,
        executable: ThemeFileType.launcherProgram(Platform.environment),
        environment: Platform.environment,
      ).register(),
    );
  }
  // Theme files this launcher was opened with: installed and used.
  for (final file in opened) {
    unawaited(model.installTheme(file));
  }
  // A game's Steam shortcut: straight into the game.
  if (options.play case final String titleId when model.preferences.onboarded) {
    unawaited(model.playAtLaunch(titleId, quitAfter: model.steamLaunch.fromSteam));
  }
  // anyps5:// links: the one this launcher was started for, then the ones later launchers hand
  // over; and the system told to open them with this launcher.
  if (options.link case final DeepLink link) model.followLink(link);
  unawaited(
    LinkRelay.listen(relayFile).then(
      (relay) => relay?.links.listen((text) {
        // A theme file double-clicked while this launcher runs: installed, and the launcher shown.
        if (LauncherThemes.isThemeFile(text) && File(text).existsSync()) {
          unawaited(model.installTheme(text));
          unawaited(model.desktop.raiseLauncher());
        } else if (DeepLink.parse(text) case final DeepLink link) {
          model.followLink(link);
        }
      }),
    ),
  );
  unawaited(UrlScheme.register());
}

class AnyPS5App extends StatelessWidget {
  const AnyPS5App({super.key, required this.model, this.time, this.now});

  final AppModel model;
  final double? time;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AnyPS5',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        fontFamily: AppText.family,
        // The launcher paints its own base (LauncherShell): clear here, so Glass's see-through
        // window shows the desktop.
        scaffoldBackgroundColor: Colors.transparent,
        splashFactory: NoSplash.splashFactory,
      ),
      home: Scaffold(
        backgroundColor: Colors.transparent,
        body: LauncherShell(model: model, time: time, now: now),
      ),
    );
  }
}
