import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui show Image;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color, IconData, Icons;
import 'package:flutter/services.dart' show LogicalKeyboardKey, PlatformException;
import 'package:path/path.dart' as p;

import '../core/audio/atrac9.dart';
import '../core/capture/game_sound.dart';
import '../core/capture/screen_cast_portal.dart';
import '../core/capture/video_encoders.dart';
import '../core/capture/wayland_capture.dart';
import '../core/audio/audio_out.dart';
import '../core/audio/interface_sounds.dart';
import '../core/audio/theme_music.dart';
import '../core/app_update.dart';
import '../core/audio/tones.dart';
import '../core/controllers/pad_info.dart';
import '../core/controllers/troubleshooter.dart';
import '../core/controls.dart';
import '../core/custom_options.dart';
import '../core/crash_report.dart' show Diagnosis, IssueDraft, SystemInfo;
import '../core/launcher_health.dart';
import '../core/desktop_notice.dart';
import '../core/desktop/desktop.dart';
import '../core/desktop/launcher_window.dart';
import '../core/discord_presence.dart' show DiscordPresence;
import '../core/now_playing.dart' show NowPlayingSource;
import '../core/desktop/window_backdrop.dart';
import '../core/font_download.dart';
import '../core/free_space.dart';
import '../core/family/family_rules.dart' show TitleVerdict;
import '../core/ffmpeg_download.dart' show FfmpegBuild;
import '../core/gamepad/feel.dart';
import '../core/gamepad/guide_switch.dart';
import '../core/gamepad/pad_gate.dart';
import '../core/gamepad/pad_navigation.dart';
import '../core/gamepad/shortcuts.dart';
import '../core/game_deletion.dart' show Trash;
import '../core/game_library.dart';
import '../core/game_log.dart';
import '../core/game_process.dart';
import '../core/game_presets.dart';
import '../core/game_settings.dart';
import '../core/launch_resolution.dart';
import '../core/gyro_aiming.dart';
import '../core/host.dart';
import '../core/installer.dart';
import '../core/library_watch.dart';
import '../core/package_install.dart';
import '../core/power.dart';
import '../core/prepare_queue.dart';
import '../core/relinker_flags.dart';
import '../core/remote/adb_tunnel.dart';
import '../core/remote/assist.dart';
import '../core/remote/mdns.dart';
import '../core/remote/paired_devices.dart';
import '../core/remote/phone_pad_events.dart';
import '../core/remote/remote_protocol.dart';
import '../core/remote/remote_server.dart';
import '../core/remote/usb_tunnel.dart';
import '../core/replay_buffer.dart';
import '../core/save_backup.dart';
import '../core/steam/steam_launch.dart';
import '../core/screenshots.dart';
import '../core/deep_link.dart';
import '../core/engine_checkout.dart';
import '../core/toolkit.dart';
import '../core/toolkit_download.dart';
import '../core/profiles/profile_saves.dart';
import '../core/profiles/profiles.dart';
import '../core/together/account.dart' show ClientTooOld, TogetherAccount, TogetherProblem;
import '../core/together/e2ee_keys.dart';
import '../core/together/join_advice.dart' show StaleCopy;
import '../core/together/levels.dart';
import '../core/together/media.dart' show SfuRoom;
import '../core/together/talk_key.dart';
import '../core/together/token_store.dart';
import '../core/online/online_peer_mesh.dart';
import '../core/together/voice_mesh.dart';
import '../core/themes/theme_design.dart';
import '../core/themes/theme_library.dart';
import '../core/trophies.dart';
import '../core/unlock_space.dart';
import '../core/update_channel.dart';
import '../core/unreal/unreal_controls.dart';
import 'browser_play.dart';
import 'clip_player.dart';
import 'voice_note_player.dart';
import 'components.dart';
import 'controllers_model.dart';
import 'crash_model.dart';
import 'discord_model.dart';
import 'now_playing_model.dart';
import 'engine_model.dart';
import 'ffmpeg_model.dart';
import 'fonts_model.dart';
import 'media_model.dart';
import 'share_play_model.dart';
import 'game_delete_model.dart';
import 'game_files_model.dart';
import 'steam_model.dart';
import 'glass.dart';
import 'phone_art.dart';
import 'power_model.dart';
import 'profile_picture.dart';
import 'save_sync_model.dart';
import 'sharing_model.dart';
import 'strings.dart';
import 'theme.dart';
import 'theme_hub_model.dart';
import 'together_model.dart';
import 'update_model.dart';
import 'trophy_card.dart';

part 'profiles_model.dart';
part 'retro_home_folders.dart';
part 'standalone_emulators.dart';
part 'settings_search.dart';
part 'themes_model.dart';

/// The launcher's own choices, kept as JSON in the config folder.
class Preferences {
  Preferences();

  factory Preferences.fromJson(Map<String, dynamic> json) => Preferences()
    ..language = json['language'] as String? ?? 'en'
    // A look this launcher does not know (or garbage) is Cosmic; the rest of the file still counts.
    ..theme = switch (json['theme']) {
      final num index => LookStyle.fromIndex(index.toInt()).index,
      _ => LookStyle.cosmic.index,
    }
    ..accent = json['accent'] as String?
    ..customTheme = json['customTheme'] as String?
    ..backdrop = switch (json['backdrop']) {
      final String kind when Preferences.backdrops.contains(kind) => kind,
      _ => 'theme',
    }
    ..backdropFile = json['backdropFile'] as String?
    ..menuMusicFile = json['menuMusicFile'] as String?
    ..profileName = json['profileName'] as String? ?? ''
    ..gamesFolders = _folders(json['gamesFolders'], json['gamesFolder'])
    ..retroLibrary = json['retroLibrary'] == true
    ..retroEmulators = {
      if (json['retroEmulators'] case final Map<dynamic, dynamic> entries)
        for (final platform in RetroPlatform.values)
          if (entries[platform.name] case final String path) platform.name: path,
    }
    ..showRetroFolders = json['showRetroFolders'] == true
    ..toolkitFolder = json['toolkitFolder'] as String?
    ..onboarded = json['onboarded'] as bool? ?? false
    ..gameArtwork = json['gameArtwork'] as bool? ?? true
    ..reducedMotion = json['reducedMotion'] as bool? ?? false
    ..reduceTransparency = json['reduceTransparency'] == true
    ..glassTooSlow = json['glassTooSlow'] == true
    ..glassTransparency = switch (json['glassTransparency']) {
      final num percent => percent.toInt().clamp(0, 100),
      _ => null,
    }
    ..glassArtwork = json['glassArtwork'] == true
    ..phoneServer = json['phoneServer'] as bool? ?? true
    ..browserPlay = json['browserPlay'] as bool? ?? true
    ..browserPlayAlways = json['browserPlayAlways'] == true
    ..togetherServer = json['togetherServer'] as String?
    ..friendsJoin = json['friendsJoin'] as bool? ?? true
    ..discordPresence = json['discordPresence'] as bool? ?? true
    ..discordJoin = json['discordJoin'] as bool? ?? true
    ..nowPlayingCard = json['nowPlayingCard'] as bool? ?? true
    ..nowPlayingShare = json['nowPlayingShare'] as bool? ?? false
    ..onlinePlay = json['onlinePlay'] == true
    ..onlinePlatformGroups = json['onlinePlatformGroups'] as bool? ?? true
    ..pushToTalk = json['pushToTalk'] as bool? ?? false
    ..noiseSuppression = json['noiseSuppression'] as bool? ?? true
    ..talkKey = (json['talkKey'] as num?)?.toInt()
    ..sounds = json['sounds'] as bool? ?? true
    ..soundVolume = (json['soundVolume'] as num?)?.toInt()
    ..musicVolume = (json['musicVolume'] as num?)?.toInt()
    ..launcherVolume = (json['launcherVolume'] as num?)?.toInt()
    ..engineSource = json['engineSource'] as String? ?? 'upstream'
    ..updateChannel = json['updateChannel'] as String?
    ..engineGitBeforePlay = json['engineGitBeforePlay'] == true
    ..engineGitBuilt = {
      for (final entry in (json['engineGitBuilt'] as Map<String, dynamic>? ?? const {}).entries)
        if (entry.value is String) entry.key: entry.value as String,
    }
    ..fontsFolder = json['fontsFolder'] as String?
    ..saveSync = json['saveSync'] as bool?
    ..syncFolder = json['syncFolder'] as String?
    ..syncThrough = json['syncThrough'] as String?
    ..powerProfiles = json['powerProfiles'] is Map<String, dynamic>
        ? json['powerProfiles'] as Map<String, dynamic>
        : null
    ..heatReader = json['heatReader'] == true
    ..screenshotsFolder = json['screenshotsFolder'] as String?
    ..showHiddenTrophies = json['showHiddenTrophies'] as bool? ?? false
    ..controllerVibration = json['controllerVibration'] as bool? ?? true
    ..steamUser = json['steamUser'] as String?
    ..steamGames = json['steamGames'] == true
    ..steamFullscreen = json['steamFullscreen'] as bool? ?? true
    ..controllerLight = json['controllerLight'] as String?
    ..confirmCircle = json['confirmCircle'] == true
    ..assistPlayerOne = json['assistPlayerOne'] as String?
    ..stickDeadzone = switch (json['stickDeadzone']) {
      final num percent => percent.toInt().clamp(0, StickDeadzone.maximum),
      _ => 0,
    }
    ..cjkGames = {
      for (final id in json['cjkGames'] as List<dynamic>? ?? const <dynamic>[])
        if (id is String) id,
    }
    ..prepareNewGames = json['prepareNewGames'] as bool? ?? true
    ..displayDefaults = DisplayDefaults.fromJson(json['displayDefaults'])
    ..launcherFullscreen = json['launcherFullscreen'] as bool?
    ..windowButtons = json['windowButtons'] as bool? ?? true
    ..pauseOnMenu = json['pauseOnMenu'] as bool? ?? true
    ..hideWhilePlaying = json['hideWhilePlaying'] == true
    ..checkUpdates = json['checkUpdates'] as bool? ?? true
    ..replayBuffer = json['replayBuffer'] == true
    ..waylandRestoreToken = json['waylandRestoreToken'] as String? ?? ''
    ..replaySeconds = switch (json['replaySeconds']) {
      final num seconds when ReplayBuffer.lengths.contains(seconds.toInt()) => seconds.toInt(),
      _ => ReplayBuffer.defaultLength,
    }
    ..shortcuts = ShortcutMap.fromJson(json['shortcuts'])
    ..compatNever = json['compatNever'] == true
    ..compatAsked = {
      for (final entry in (json['compatAsked'] as Map<String, dynamic>? ?? const {}).entries)
        if (entry.value is String) entry.key: entry.value as String,
    }
    ..lastPlayed = {
      for (final entry in (json['lastPlayed'] as Map<String, dynamic>? ?? const {}).entries)
        entry.key: entry.value as String,
    };

  String language = 'en';
  int theme = 0;
  String? accent;

  /// The id of the theme in use made in the Theme Studio or installed from a file (its folder
  /// in the config folder's Themes); null for the built-in look [theme] and its [accent].
  String? customTheme;

  /// Settings › Appearance › Background: the theme's animation ('theme'), the user's own picture
  /// ('image') or video ('video') in [backdropFile]. The macOS launcher's keys and values.
  String backdrop = 'theme';
  String? backdropFile;
  static const backdrops = ['theme', 'image', 'video'];

  /// Settings › Appearance › Menu Music: a song of the user's own that plays when the selected
  /// game has none (a custom theme's own music comes first); null for none.
  String? menuMusicFile;

  /// Empty until the first profile is made: it is then the profile's name (the language's word
  /// for a player when none was typed).
  String profileName = '';

  /// The games folders in order (a library over several drives); the first holds the store, where
  /// games are unlocked. A folder whose drive is unplugged stays in the list.
  List<String> gamesFolders = [];

  /// Settings › Game Library › Emulator games: the games folders' PS1, PS2 and PS3 discs are
  /// listed too, for the emulators in Settings › Emulators. Off until turned on, so a PS5-only
  /// library is scanned as before.
  bool retroLibrary = false;

  /// The emulator chosen for each console ([RetroPlatform.name]), by its executable's path.
  Map<String, String> retroEmulators = {};

  /// Settings › Emulators › Show as folders: a console's games in one tile on the home screen.
  bool showRetroFolders = false;
  String? toolkitFolder;
  bool onboarded = false;
  bool gameArtwork = true;
  bool reducedMotion = false;

  /// Glass draws its surfaces solid, without the blur behind them.
  bool reduceTransparency = false;

  /// The graphics card fell behind drawing Glass's transparency once: it starts solid from then
  /// on, until Glass is picked again in Settings › Appearance.
  bool glassTooSlow = false;

  /// Glass's see-through window: how much of the desktop shows, in percent (null for
  /// GlassWindow.defaultTransparency), and whether the selected game's picture is laid over it.
  int? glassTransparency;
  bool glassArtwork = false;
  bool phoneServer = true;

  /// Play from a browser (browser_play.dart), and whether its server stays up all the time.
  bool browserPlay = true;
  bool browserPlayAlways = false;

  /// Another AnyTogether server than AnyTogether's own; null for that one.
  String? togetherServer;

  /// While a game runs, friends see it and can join (an AnyTogether game session).
  bool friendsJoin = true;

  /// Settings › Behaviour: the running game and the party on the user's Discord profile, and a
  /// Join button there with the party's code (discord_model.dart).
  bool discordPresence = true;
  bool discordJoin = true;

  /// Settings › Behaviour: the quick menu's Now playing card (what a media player on this
  /// computer plays), and whether AnyTogether friends see it; the second is the user's to turn
  /// on (now_playing_model.dart).
  bool nowPlayingCard = true;
  bool nowPlayingShare = false;

  /// Settings › AnyTogether › Online play (experimental): games are started with the launcher's
  /// online bridge (signed in as the AnyTogether user, friends, Player Sessions, game packets to
  /// the other players). Off by default.
  bool onlinePlay = false;

  /// With online play on, the platform's web API groups the launcher knows (userProfile,
  /// communicationRestrictionStatus, sessionManager) are answered; off answers them all "not
  /// offered", for a clean observation run. Not in the interface.
  bool onlinePlatformGroups = true;

  /// In party voice: the talk key held to talk (else it turns the microphone on and off), and
  /// which key it is (a USB HID usage; null for the default).
  bool pushToTalk = false;

  /// WebRTC's noise suppression on the microphone in calls; on unless turned off.
  bool noiseSuppression = true;
  int? talkKey;

  /// Interface sounds, and their volume and the selected game's theme song's in percent; null
  /// keeps the default.
  bool sounds = true;
  int? soundVolume;
  int? musicVolume;

  /// Everything the launcher plays (its sounds and music) in percent, over the two above; 0 is
  /// silent, null is 100. Games keep their own volume.
  int? launcherVolume;
  Map<String, String> lastPlayed = {};

  /// Which engine the settings offer: 'upstream' (boykopovar/AnyPS5) or 'arm' (AnyPS5-ARM's,
  /// with the phone controller, full screen and window size). A first start chooses 'arm'
  /// ([load]); choices saved without it (launchers from before there was a choice) read 'upstream'.
  String engineSource = 'upstream';

  /// Settings › About › Update Channel: null for Stable, 'nightly' for Nightly (UpdateChannel).
  String? updateChannel;

  /// Settings › AnyPS5 Engine › Update from Git Before Playing, for an engine folder that is a
  /// git checkout: pulled and built before a game starts when the remote has new commits.
  bool engineGitBeforePlay = false;

  /// The commit each engine checkout was last built at by the launcher, by its folder.
  Map<String, String> engineGitBuilt = {};

  /// A folder of the user's own fonts (the console's, say) games get first; null for none.
  String? fontsFolder;

  /// Settings › Behaviour › Save Sync: each game's saves kept in step before it starts and after
  /// it ends (null is off), through [syncFolder] (null for iCloud Drive where it is set up) or,
  /// with [syncThrough] "together", the AnyTogether cloud. The Mac's keys.
  bool? saveSync;
  String? syncFolder;
  String? syncThrough;

  /// Settings › Battery & Heat: the two profiles as PowerProfiles writes them (the Mac's
  /// "powerProfiles"); null for the defaults.
  Map<String, dynamic>? powerProfiles;

  /// Settings › Battery & Heat › Read the processor's temperature (Windows): the reader with
  /// administrator rights starts with the launcher. Off again when Windows' prompt is turned down.
  bool heatReader = false;

  /// Settings › Captures › Screenshots Folder: where F12 screenshots, trophy pictures and clips
  /// go; null for Pictures/AnyPS5 (AppPaths.pictures).
  String? screenshotsFolder;

  /// Hidden trophies show their name, description and icon before they are earned.
  bool showHiddenTrophies = false;

  /// Soft pulses in the controller for select, back, errors, trophies, invitations and the end
  /// of a row.
  bool controllerVibration = true;

  /// Settings › Steam: the account the shortcuts go to (`<Steam folder>|<account ID>`; null for
  /// the one signed in last), each unlocked game its own shortcut too, the launcher full screen
  /// when Steam starts it.
  String? steamUser;
  bool steamGames = false;
  bool steamFullscreen = true;

  /// Settings › Controllers: the light bar's colour (PadLight's name; null for the theme's
  /// accent), Circle confirming instead of Cross, and the sticks' dead zone in percent.
  String? controllerLight;
  bool confirmCircle = false;
  int stickDeadzone = 0;

  /// Settings › Controllers › Assist Player 1 (AssistTarget): null off, "controllers", or the
  /// device ID of the phone or browser pad that helps.
  String? assistPlayerOne;

  /// The title IDs of games seen asking for Japanese, Chinese or Korean fonts: their next start
  /// waits for those to download.
  Set<String> cjkGames = {};

  /// Settings › Game Library: new games unlocked in the background like a console installing them.
  bool prepareNewGames = true;

  /// Settings › Default Display: how the games without display choices of their own start.
  /// The same for every profile, as the game settings are.
  DisplayDefaults displayDefaults = const DisplayDefaults();

  /// Settings › Appearance › Full Screen: null until the user chooses (the launcher starts full
  /// screen then), the choice after.
  bool? launcherFullscreen;

  /// Settings › Appearance: full screen, the pointer at the top edge brings down Minimize, Leave
  /// Full Screen and Quit.
  bool windowButtons = true;

  /// Settings › Behaviour: before the quick menu covers a game, its Options is pressed so it
  /// pauses.
  bool pauseOnMenu = true;

  /// Settings › Behaviour: the launcher's window minimized once a game starts, back when it
  /// closes, as on the Mac.
  bool hideWhilePlaying = false;

  /// Settings › Behaviour › Check for updates: off, the launcher and the engine look for new
  /// versions only when asked (Settings › About), as on the Mac.
  bool checkUpdates = true;

  /// Settings › Captures: the last [replaySeconds] of play kept while a game runs, for Share.
  bool replayBuffer = false;
  int replaySeconds = ReplayBuffer.defaultLength;

  /// Under Wayland: brings back the window shared last time without the desktop's dialog.
  String waylandRestoreToken = '';

  /// Settings › Shortcuts.
  ShortcutMap shortcuts = ShortcutMap();

  /// "How did it run?" after a game (AnyTogether's compatibility list): never asked, and the
  /// launcher version each game (by title ID) was last asked about.
  bool compatNever = false;
  Map<String, String> compatAsked = {};

  Map<String, Object?> toJson() => {
    'language': language,
    'theme': theme,
    'accent': accent,
    'customTheme': customTheme,
    'backdrop': backdrop,
    'backdropFile': backdropFile,
    'menuMusicFile': menuMusicFile,
    'profileName': profileName,
    'gamesFolders': gamesFolders,
    if (retroLibrary) 'retroLibrary': true,
    if (retroEmulators.isNotEmpty) 'retroEmulators': retroEmulators,
    if (showRetroFolders) 'showRetroFolders': true,
    // The first one under the old name too, for an older launcher started again.
    'gamesFolder': gamesFolders.firstOrNull,
    'toolkitFolder': toolkitFolder,
    'onboarded': onboarded,
    'gameArtwork': gameArtwork,
    'reducedMotion': reducedMotion,
    'reduceTransparency': reduceTransparency,
    if (glassTooSlow) 'glassTooSlow': true,
    'glassTransparency': glassTransparency,
    'glassArtwork': glassArtwork,
    'phoneServer': phoneServer,
    'browserPlay': browserPlay,
    'browserPlayAlways': browserPlayAlways,
    'togetherServer': togetherServer,
    'friendsJoin': friendsJoin,
    'discordPresence': discordPresence,
    'discordJoin': discordJoin,
    'nowPlayingCard': nowPlayingCard,
    'nowPlayingShare': nowPlayingShare,
    'onlinePlay': onlinePlay,
    if (!onlinePlatformGroups) 'onlinePlatformGroups': false,
    'pushToTalk': pushToTalk,
    if (!noiseSuppression) 'noiseSuppression': false,
    'talkKey': talkKey,
    'sounds': sounds,
    'soundVolume': soundVolume,
    'musicVolume': musicVolume,
    if (launcherVolume != null) 'launcherVolume': launcherVolume,
    'lastPlayed': lastPlayed,
    'engineSource': engineSource,
    if (updateChannel != null) 'updateChannel': updateChannel,
    'engineGitBeforePlay': engineGitBeforePlay,
    'engineGitBuilt': engineGitBuilt,
    'fontsFolder': fontsFolder,
    'saveSync': saveSync,
    'syncFolder': syncFolder,
    'syncThrough': syncThrough,
    'powerProfiles': powerProfiles,
    if (heatReader) 'heatReader': true,
    'screenshotsFolder': screenshotsFolder,
    'showHiddenTrophies': showHiddenTrophies,
    'controllerVibration': controllerVibration,
    'steamUser': steamUser,
    'steamGames': steamGames,
    'steamFullscreen': steamFullscreen,
    'controllerLight': controllerLight,
    'confirmCircle': confirmCircle,
    'stickDeadzone': stickDeadzone,
    'assistPlayerOne': assistPlayerOne,
    'cjkGames': cjkGames.toList()..sort(),
    'prepareNewGames': prepareNewGames,
    if (!displayDefaults.isBuiltIn) 'displayDefaults': displayDefaults.toJson(),
    'launcherFullscreen': launcherFullscreen,
    'windowButtons': windowButtons,
    'pauseOnMenu': pauseOnMenu,
    if (hideWhilePlaying) 'hideWhilePlaying': true,
    if (!checkUpdates) 'checkUpdates': false,
    'replayBuffer': replayBuffer,
    if (waylandRestoreToken.isNotEmpty) 'waylandRestoreToken': waylandRestoreToken,
    'replaySeconds': replaySeconds,
    if (!shortcuts.isDefault) 'shortcuts': shortcuts.toJson(),
    if (compatNever) 'compatNever': true,
    if (compatAsked.isNotEmpty) 'compatAsked': compatAsked,
  };

  /// The saved list of games folders, or a file from before with one (`gamesFolder`) as a list of
  /// one; what is not a path, and a folder listed twice, is left out.
  static List<String> _folders(Object? list, Object? single) {
    final folders = <String>[];
    for (final folder in list is List<dynamic> ? list : [single]) {
      if (folder is String && folder.isNotEmpty && !folders.any((known) => p.equals(known, folder))) {
        folders.add(folder);
      }
    }
    return folders;
  }

  /// The launcher's choices in [file]. Without the file (the first start) the launcher's language
  /// is the first of the computer's languages it has a file for: [systemLocales], else the ones
  /// the system gives, as Settings lists them.
  static Preferences load(String file, {List<String>? systemLocales}) {
    if (!File(file).existsSync()) {
      // A first start gets AnyPS5-ARM's engine (the phone controller, full screen, window size).
      // A launcher that saved its choices before keeps the engine it had: never switched silently.
      return Preferences()
        ..language = Language.forSystem(systemLocales ?? Preferences.systemLocales()).code
        ..engineSource = 'arm';
    }
    try {
      final json = jsonDecode(File(file).readAsStringSync());
      return json is Map<String, dynamic> ? Preferences.fromJson(json) : Preferences();
    } on Object {
      return Preferences();
    }
  }

  /// The computer's languages, the one it is set to first: Windows' list of display languages
  /// and Linux's LANGUAGE and LANG as Flutter reads them, then Dart's locale name.
  static List<String> systemLocales() => [
    for (final locale in PlatformDispatcher.instance.locales) locale.toLanguageTag(),
    Platform.localeName,
  ];

  void save(String file) {
    try {
      File(file).parent.createSync(recursive: true);
      File(file).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(toJson()));
    } on FileSystemException {
      // Kept in memory for this run.
    }
  }
}

/// What the launcher shows about a game: one state at a time, worked out by [AppModel.stateOf]
/// from what the launcher is doing with it. Everything about the game on the screen (its main
/// button's words, colour and icon, its tile's badge, the line under its name, its settings)
/// follows from it, and the main button's press does what the state says ([AppModel.primaryAction]):
///
///   Locked → (Queued) → Installing (unlocking) → Installed (ready)
///   Installed → Installed(outdated) (needs an update) → Installing(updating) → Installed
///   Installed → Starting (launching) → Running(pid) → Stopping(pid) → Installed
///   Installed → WaitingForEngine (the engine is being built in place) → Installed
///   any unlock → Failed(message) → (Retry) Queued
///
/// The engine's own build (Update from Git) is a job of its own ([EngineJob]) the games wait on.
sealed class GameState {
  const GameState();
}

class Locked extends GameState {
  const Locked({this.waitingToPrepare = false});

  /// In line to be prepared in the background once the game playing closes.
  final bool waitingToPrepare;
}

class Unreadable extends GameState {
  const Unreadable();
}

class Queued extends GameState {
  const Queued({this.updating = false, this.waitingForEngine = false});

  /// An installed game in line to be unlocked again (an update), not a first unlock.
  final bool updating;

  /// In line behind the engine's build (Update from Git): it starts once the build is done.
  final bool waitingForEngine;
}

class Installing extends GameState {
  const Installing(
    this.step,
    this.fraction, {
    this.preparing = false,
    this.paused = false,
    this.updating = false,
    this.playsAfter = false,
  });
  final InstallStep step;
  final double fraction;

  /// Prepared in the background (a new game), not asked for by the user.
  final bool preparing;

  /// Stopped where it is while a game plays.
  final bool paused;

  /// Unlocked again over an install it had (Update and Play, Relink All, Reinstall).
  final bool updating;

  /// The game starts once it is done (Play, Update and Play).
  final bool playsAfter;

  /// The share of the whole install done, for one bar.
  double get overall => InstallSpan.overall(step, fraction);
}

class Failed extends GameState {
  const Failed(this.message);
  final String message;
}

class NeedsEmulator extends GameState {
  const NeedsEmulator();
}

class Installed extends GameState {
  const Installed({this.outdated = false});

  /// Made with another toolkit than the current one.
  final bool outdated;
}

/// An installed game that cannot start now: the engine it plays with is being checked or built
/// in place (Update from Git). [forThisGame]: its own Play asked for the build, and it starts
/// after it.
class WaitingForEngine extends GameState {
  const WaitingForEngine(this.job, {this.forThisGame = false});
  final EngineJob job;
  final bool forThisGame;
}

/// Being started: the launcher prepares its fonts and settings and starts its process.
class Starting extends GameState {
  const Starting();
}

/// Its process, started by this launcher, runs.
class Running extends GameState {
  const Running(this.pid);
  final int pid;
}

/// Asked to close (Stop): it has a moment to close as its window would, then it is ended.
class Stopping extends GameState {
  const Stopping(this.pid);
  final int pid;
}

/// The engine's own work, which every game waits on: the checkout's remote looked at before a
/// game starts ([step] null), or a pull and build ([step] the one running, [lines] the last ones
/// it printed). [forGame]: the game whose Play asked for it.
class EngineJob {
  const EngineJob({this.step, this.lines = const [], this.forGame});
  final GitStep? step;
  final List<String> lines;
  final String? forGame;

  /// Only looking at the remote: nothing on disk changes, games can still start.
  bool get checking => step == null;
}

/// A parent's family settings keep the game from the child: too old a rating, or none known.
class FamilyLocked extends GameState {
  const FamilyLocked(this.verdict);
  final TitleVerdict verdict;
}

/// Each install step's share of the whole, for one overall bar.
abstract final class InstallSpan {
  static (double, double) of(InstallStep step) => switch (step) {
    InstallStep.unwrap => (0, 0.12),
    InstallStep.relink => (0.12, 0.5),
    InstallStep.copy => (0.62, 0.26),
    InstallStep.layout => (0.88, 0.08),
    InstallStep.finish => (0.96, 0.04),
  };

  static double overall(InstallStep step, double fraction) {
    final (start, length) = of(step);
    return start + length * fraction;
  }

  static String title(InstallStep step) => T.text(switch (step) {
    InstallStep.unwrap => 'stepUnwrap',
    InstallStep.relink => 'stepRelink',
    InstallStep.copy => 'stepCopy',
    InstallStep.layout => 'stepBundle',
    InstallStep.finish => 'stepFinish',
  });
}

/// A move on the launcher's screen, from the keyboard or the phone.
enum Command {
  left,
  right,
  up,
  down,
  select,
  back,
  options,
  previousGame,
  nextGame,
  home;

  /// Left for right and right for left, the rest as it is: on mirrored screens (Arabic, Urdu)
  /// → moves to what is drawn on the right, as on the Mac.
  Command get mirrored => switch (this) {
    Command.left => Command.right,
    Command.right => Command.left,
    _ => this,
  };
}

/// Where the home screen's focus is: the tiles, a top-bar button, a button under the title, or
/// one of the update notice's (0 Restart Now, 1 Later), left of the top bar's.
class HomeFocus {
  const HomeFocus._(this.area, this.index);
  static const tiles = HomeFocus._('tiles', 0);
  const HomeFocus.top(int index) : this._('top', index);
  const HomeFocus.actions(int index) : this._('actions', index);
  const HomeFocus.notice(int index) : this._('notice', index);

  /// The profile picture at the end of the top bar (0) and, under it, the list's entries from 1:
  /// the other profiles, then Add profile.
  const HomeFocus.switcher(int index) : this._('switcher', index);

  final String area;
  final int index;

  bool get isTiles => area == 'tiles';
  bool get isTop => area == 'top';
  bool get isActions => area == 'actions';
  bool get isNotice => area == 'notice';
  bool get isSwitcher => area == 'switcher';

  @override
  bool operator ==(Object other) => other is HomeFocus && other.area == area && other.index == index;

  @override
  int get hashCode => Object.hash(area, index);
}

/// Where a screen was left: the layer, and on a panel its section and row, by their ids, so a
/// list that changed meanwhile still lands on the same row. Back from a screen opened over it
/// (a profile, the feed, a leaderboard) comes here.
typedef PanelSpot = ({Layer layer, String? category, String? row});

enum Layer {
  library,
  settings,
  gameSettings,
  controls,

  /// A game's Advanced page: its sticks, the mouse as the camera, the keyboard's ramps, the
  /// shader cache and its settings file, as on the Mac.
  advanced,
  confirmUninstall,

  /// Game Settings › Delete game: the game's own files off the disk, asked first (ConfirmCard).
  confirmDeleteGame,
  updateChoice,

  /// AnyTogether no longer answers this launcher's version (client_too_old): update.
  updateRequired,

  /// A join held back by a different game version or engine build (together.joinBlock): what
  /// differs, both builds whole, and what gets past it.
  joinBlocked,

  /// Play on a game someone the user knows already plays (together.joinChoice): join theirs, or
  /// start one's own.
  joinOrHost,
  log,
  trophies,

  /// The selected game's pictures: F12 screenshots and the ones taken when trophies were earned.
  gallery,

  /// AnyTogether: friends and requests, what can be done with one friend, the messages, the
  /// party and its voice.
  friends,
  friendOptions,
  messages,
  party,
  profile,

  /// Comparing trophies with someone: the games either has trophies in, then one game's trophies
  /// side by side.
  compare,

  /// AnyTogether's social screens (together_social.dart): friends' activity, a leaderboard, the
  /// notifications behind the bell, and "How did it run?" after a game.
  feed,

  /// Captures (together_captures.dart): the screenshots and clips posted, liked and commented on.
  captures,
  leaderboard,
  notifications,
  compat,

  /// A challenge on a game's leaderboard (together_challenges.dart): its standings, Join and Leave.
  challenge,

  /// Find Players (together_find.dart): the looking-for-group board, the user's posts, public
  /// parties and people to meet; the post form; one game's hub.
  findPlayers,
  lfgPost,
  gameHub,

  /// Family limits: today's play time, asking a parent for more.
  family,

  /// A game's last start: why it stopped, crash_log.txt to save, the issue to open.
  crashReport,

  /// Before an unlock that would copy the game's files: how much and why, the two ways to link
  /// instead (the games folder on the dump's drive, Windows' Developer Mode), copying anyway.
  copyWarning,

  /// A phone or a browser pad connected while the engine in use cannot read it (upstream's): why,
  /// and Switch to the AnyPS5-ARM Engine in one press.
  phoneEngine,

  /// Settings › Controllers › Test Buttons and Sticks.
  controllerTest,

  /// Settings › Phones › Play from a browser: the QR code a phone scans (browser_play.dart).
  browserPlay,

  /// PS in a game: the game paused under Resume, Game Settings and Close Game.
  quickMenu,

  /// A friend's share play watched full screen (share_play_model.dart): the controller is the
  /// game's, PS leaves.
  shareWatch,

  /// PS held in a game: Close Game?
  closeGame,

  /// PS held in the launcher: Switch Profile, Quit AnyPS5.
  homeMenu,

  /// Escape on the home screen: Quit AnyPS5? (Cancel first).
  confirmQuit,

  /// A zip in a games folder to unpack, or an update to put beside a game, and the job's
  /// progress (game_files_model.dart).
  gameFiles,

  /// "Who's playing?": the profiles' tiles and Add Profile (profiles_model.dart).
  profilePicker,

  /// A picture chosen for the profile, placed and zoomed in a circle before it is kept
  /// (picture_crop_view.dart).
  cropPicture,

  /// A new profile: its name, then offline or online.
  addProfile,

  /// Signing in to AnyTogether for a profile (a new one, one going online or signing in again).
  signIn,

  /// Options (or a right click) on Home: the game's settings, Switch Profile, online or offline.
  profileMenu,

  /// At start, after the launcher itself crashed or stopped responding: Send Report, Not Now.
  launcherReport,

  /// Save Sync through the cloud asks: both sides changed, or the quota is full.
  cloudQuestion,

  /// Settings › Behaviour › Cloud Storage: the usage and every game's cloud saves.
  cloudStorage,

  /// Settings › Appearance › Themes: the built-in looks, the custom themes, the Studio and
  /// Install from a File (themes_model.dart).
  themes,

  /// The Theme Studio: the theme in use changed live, the launcher behind it showing each change.
  themeStudio,

  /// The user's own profile: Edit showcase (up to six trophies and games pinned) and Profile
  /// theme (a Theme Hub theme to wear), as panels over it (together_profile.dart).
  showcaseEdit,
  profileTheme,

  /// Settings › AnyTogether › Country: the countries by name, with a search (countries.dart).
  countryPicker,
}

/// A settings row the panels draw and the keyboard moves through.
/// The signs a row can carry before its title.
enum PanelIcon { flag, trophy, android, iphone, browser, phone }

/// How a paired phone or browser pad shows: the sign for its kind, and its name for people.
/// A browser pad's stored name is "Android · Web" (BrowserPadAccess.deviceName, the same on the
/// Mac); it is shown as "Android browser", in the launcher's language.
class PhoneLabel {
  static const _web = ' · Web';

  static bool isBrowser(String name) => name.endsWith(_web);

  /// The device behind [name]: "Android" of "Android · Web", the name itself otherwise.
  static String device(String name) => isBrowser(name) ? name.substring(0, name.length - _web.length) : name;

  /// The sign for the device's kind: Android, an iPhone or iPad, a browser on a system it did not
  /// name, or a phone the name says nothing about.
  static PanelIcon icon(String name) {
    final device = PhoneLabel.device(name);
    if (RegExp('iPhone|iPad|iPod', caseSensitive: false).hasMatch(device)) return PanelIcon.iphone;
    if (device.toLowerCase().contains('android')) return PanelIcon.android;
    return isBrowser(name) ? PanelIcon.browser : PanelIcon.phone;
  }

  /// The name as people read it: a phone app's own name as it is, a browser pad's by its system.
  static String title(String name) {
    if (!isBrowser(name)) return name;
    final device = PhoneLabel.device(name);
    return device.isEmpty || device == 'Phone' ? T.text('phoneBrowserGeneric') : T.format('phoneBrowserName', [device]);
  }
}

class PanelRow {
  const PanelRow({
    required this.id,
    required this.title,
    required this.kind,
    this.detail,
    this.glyph,
    this.person,
    this.level,
    this.icon,
    this.picture,
    this.meter,
    this.wraps = false,
  });

  final String id;
  final String title;
  final String? detail;

  /// The words under the title are to be read whole (two engine builds, what to do about them):
  /// no line limit.
  final bool wraps;

  /// A thin bar under the words: how much of something the row's two parts take up.
  final PanelMeter? meter;

  /// A face button drawn after the title.
  final PadGlyph? glyph;
  final RowKind kind;

  /// Someone on AnyTogether the row is about, drawn as their picture before the title.
  final PanelPerson? person;

  /// Their trophy level, drawn after the title.
  final LevelBadge? level;

  /// A sign drawn before the title where no one's picture is (a challenge's notifications).
  final PanelIcon? icon;

  /// A picture (a game's icon) drawn before the title in the sign's place.
  final Uint8List? picture;

  bool get focusable => kind is! InfoRow;
}

sealed class RowKind {
  const RowKind();
}

class ChoiceRow extends RowKind {
  const ChoiceRow(this.options, this.selected, this.set);
  final List<String> options;
  final int selected;
  final void Function(int) set;
}

class ToggleRow extends RowKind {
  const ToggleRow(this.value, this.set);
  final bool value;
  final void Function(bool) set;
}

class StepperRow extends RowKind {
  const StepperRow({
    required this.value,
    required this.min,
    required this.max,
    required this.step,
    required this.format,
    required this.set,
    this.wraps = false,
    this.slider = false,
  });
  final int value;
  final int min;
  final int max;
  final int step;
  final String Function(int) format;
  final void Function(int) set;

  /// A circle (a hue in degrees): past [max] comes [min] again, and the other way.
  final bool wraps;

  /// Shown as a bar to drag or click along (a volume), with − + beside it.
  final bool slider;

  /// The value a place along the bar stands for, [fraction] 0 (the start) to 1 (the end), on a
  /// step.
  int valueAt(double fraction) {
    final steps = ((max - min) / step).round();
    return (min + (fraction.clamp(0.0, 1.0) * steps).round() * step).clamp(min, max);
  }

  /// [value] moved [steps] steps: kept between [min] and [max], or round the circle.
  int moved(int steps) {
    final next = value + steps * step;
    if (!wraps) return next.clamp(min, max);
    final span = max - min + step;
    return min + (next - min) % span;
  }

  /// How many steps one move of a hold takes after [repeats] repeats: one at first, then more,
  /// so a held arrow crosses a long range in a second or two and a press stays exact.
  static int stride(int repeats) => repeats < 8 ? 1 : (repeats < 20 ? 3 : 6);

  /// [stride] for this row: a short range (a dozen presses or so end to end) speeds up less, so
  /// a hold does not jump past what it was held for.
  int strideFor(int repeats) {
    final steps = ((max - min) / step).ceil();
    return math.min(stride(repeats), math.max(1, steps ~/ 8));
  }
}

/// How much of a whole two parts take, each from 0 to 1 (Cloud Storage's saves and media).
class PanelMeter {
  const PanelMeter(this.first, this.second);
  final double first;
  final double second;
}

class ActionRow extends RowKind {
  const ActionRow(this.run, {this.destructive = false});
  final void Function() run;
  final bool destructive;
}

class InfoRow extends RowKind {
  const InfoRow(this.text);
  final String text;
}

/// A field to type in: choosing the row puts the cursor in it; Enter sends [submit].
class TextRow extends RowKind {
  const TextRow(this.value, this.set, {this.submit, this.hint, this.obscure = false});
  final String value;
  final void Function(String) set;
  final void Function()? submit;
  final String? hint;

  /// Typed as dots, never shown (a stream key).
  final bool obscure;
}

/// How a person shows in a row: their initials or picture, a dot for what they are doing, a
/// ring while they speak in party voice.
class PanelPerson {
  const PanelPerson({required this.name, this.avatar, this.picture, this.tint, this.status, this.speaking = false});
  final String name;
  final String? avatar;

  /// A picture on this computer (a profile's own), shown before [avatar].
  final String? picture;

  /// The colour under the initials: a profile's own; a neutral grey for others.
  final Color? tint;
  final PersonStatus? status;
  final bool speaking;

  /// One or two letters for a person with no picture.
  String get initials {
    final words = name.trim().split(RegExp(r'\s+')).where((word) => word.isNotEmpty).take(2);
    final letters = words.map(T.initial).join();
    return letters.isEmpty ? '?' : letters;
  }
}

/// What a person's dot shows: playing (blue), online (green), away (yellow), idle (a yellow
/// moon), do not disturb (red, with a bar) or offline (grey).
enum PersonStatus { playing, online, away, idle, dnd, offline }

/// The quick menu's Now playing card: the track is the row's title, artist (detail) and cover
/// (picture). Choosing it plays or pauses, ← and → go to the previous and the next track, and
/// its three buttons do the same for the mouse.
class MediaRow extends RowKind {
  const MediaRow({
    required this.label,
    required this.playing,
    required this.previous,
    required this.playPause,
    required this.next,
  });

  /// "Now playing in Rhythmbox", "Paused in Rhythmbox".
  final String label;
  final bool playing;
  final void Function() previous;
  final void Function() playPause;
  final void Function() next;
}

/// A pad action's keys and mouse buttons; choosing it waits for a key.
class KeysRow extends RowKind {
  const KeysRow(this.sources, {required this.capturing, required this.capture});
  final List<String> sources;
  final bool capturing;
  final void Function() capture;
}

/// A shortcut's key and controller binding (Settings › Shortcuts); choosing it waits for a key or
/// buttons.
class ShortcutRow extends RowKind {
  const ShortcutRow({required this.key, required this.pad, required this.capturing, required this.capture});
  final String? key;
  final String? pad;
  final bool capturing;
  final void Function() capture;
}

class PanelCategory {
  const PanelCategory({required this.id, required this.title, required this.rows});
  final String id;
  final String title;
  final List<PanelRow> rows;
}

/// What the launcher needs from the system, replaceable in tests.
class LauncherServices {
  const LauncherServices({
    this.pickFolder,
    this.openFolder,
    this.computerName,
    this.advertise = true,
    this.preferredPorts = true,
    this.cable = true,
    this.openUrl,
    this.clipPlayback,
    this.voicePlayback,
    this.copyText,
    this.environment,
    this.togetherStore,
    this.togetherStoreFor,
    this.togetherServer,
    this.togetherPollEvery,
    this.voiceEngine,
    this.sfuRoom,
    this.gameLinks,
    this.talkKeys,
    this.engineReleases,
    this.launcherReleases,
    this.packageManager,
    this.hostGlibc,
    this.audio,
    this.decodeSong,
    this.armEngineReleases,
    this.ffmpegReleases,
    this.ffmpegRun,
    this.pads,
    this.systemProbe,
    this.desktop,
    this.backdrop,
    this.renderTrophyCard,
    this.renderNoticeCard,
    this.renderLiveBadge,
    this.cjkFonts,
    this.fontClient,
    this.builtInFonts,
    this.saveFile,
    this.saveFileAs,
    this.pickFile,
    this.pickFileAt,
    this.pickImage,
    this.pickPictures,
    this.systemInfo,
    this.startDetached,
    this.quit,
    this.window,
    this.replay,
    this.waylandCapture,
    this.folderSize,
    this.gameControls,
    this.commands,
    this.discord,
    this.discordGames,
    this.nowPlaying,
    this.trash,
  });

  /// The system's trash, where Delete game puts a game's files: the Recycle Bin through the
  /// runner on Windows, the desktop's own tool on Linux when not given.
  final Trash? trash;

  /// What a media player on this computer plays (Windows' media session, MPRIS on Linux), for
  /// the quick menu's card (now_playing_model.dart); none in the tests unless they give a fake.
  final NowPlayingSource Function()? nowPlaying;

  /// Discord's IPC for the "Playing …" status (discord_model.dart); the tests give a fake.
  final DiscordPresence Function()? discord;

  /// Reads Discord's list of the games it knows (an HTTPS GET), null on a failure.
  final Future<String?> Function(Uri url)? discordGames;

  /// Runs git and CMake for an engine folder that is a git checkout (Update from Git); the
  /// system's processes when not given.
  final CommandRunner? commands;

  /// A game folder's size on disk, read away from the interface (Isolate.run by default): a
  /// dump holds tens of thousands of files.
  final Future<int> Function(String folder)? folderSize;

  /// What an Unreal game's own input settings say each pad button does, read from its paks
  /// away from the interface (Isolate.run by default); null when they say nothing readable.
  final Future<Map<PadAction, List<String>>?> Function(String folder)? gameControls;

  /// The launcher's own window: full screen or not; nothing when not given.
  final LauncherWindow? window;

  /// The replay buffer for a game about to start, [seconds] long; ffmpeg found on this system by
  /// default (null: none, or a desktop it cannot record).
  final ReplayBuffer? Function(int seconds)? replay;

  /// Recording through the desktop's portal under Wayland; made for a real Wayland session by
  /// default, and null elsewhere.
  final WaylandCapture? waylandCapture;

  /// Starts a program that outlives the launcher (an update's installer, the new AppImage);
  /// Process.start detached by default.
  final Future<void> Function(String executable, List<String> arguments)? startDetached;

  /// Ends the launcher (Restart Now); exit by default.
  final void Function(int code)? quit;

  /// Asks the user for a picture (PNG or JPEG); null when they cancelled.
  final Future<String?> Function()? pickImage;

  /// Asks the user for picture files to send in a chat (SealedPhoto.extensions, several at once);
  /// null when they cancelled.
  final Future<List<String>?> Function()? pickPictures;

  /// Asks the user where to save a file, [suggestedName] first; null when they cancelled.
  final Future<String?> Function(String suggestedName)? saveFile;

  /// Asks where to save a file of [label]'s kind (one of [extensions]), [suggestedName] first;
  /// null when they cancelled.
  final Future<String?> Function(String suggestedName, String label, List<String> extensions)? saveFileAs;

  /// Asks the user for a file of [label]'s kind (one of [extensions]) to open; null when they
  /// cancelled.
  final Future<String?> Function(String label, List<String> extensions)? pickFile;

  /// The same, opened in [folder] when one is given (a game's backups).
  final Future<String?> Function(String label, List<String> extensions, String? folder)? pickFileAt;

  /// This computer for a crash report; read from the system when not given.
  final Future<SystemInfo> Function()? systemInfo;

  /// The Japanese, Chinese and Korean fonts downloaded when a game needs them (Noto Sans CJK
  /// from GitHub); none in tests without a fake, which then download nothing.
  final FontArchive? cjkFonts;

  /// The HTTP client that downloads them; dart:io's by default.
  final HttpClient Function()? fontClient;

  /// The folder of the fonts that come with the launcher; found beside the executable (its
  /// Flutter assets) when not given.
  final String? builtInFonts;

  /// Where AnyPS5-ARM's engine is read from (its signed GitHub releases); none in tests without
  /// a fake.
  final GitHubReleases? armEngineReleases;

  /// Where the launcher's own ffmpeg comes from: this repository's releases, signed; null in
  /// tests that have no GitHub, so nothing is offered.
  final GitHubReleases? ffmpegReleases;

  /// Tests: runs the downloaded ffmpeg to see that it starts; Process.run by default.
  final ProcessRunner? ffmpegRun;

  /// Where controller input comes from (XInput and winmm on Windows, evdev on Linux); none when
  /// not given.
  final PadSource Function()? pads;

  /// What the controller troubleshooter asks the system (running programs, drivers, Steam's
  /// setting, permissions); nothing asked when not given.
  final SystemProbe Function()? systemProbe;

  /// The game's window, its picture and the trophy card over it; nothing when not given.
  final DesktopWindows? desktop;

  /// The launcher window's see-through backdrop for Glass (Acrylic on Windows, an RGBA window
  /// and KWin's blur on Linux); an opaque window when not given.
  final WindowBackdrop? backdrop;

  /// Draws the trophy card for the desktop's window; TrophyCard.render by default.
  final Future<RgbaImage> Function(Trophy trophy, double scale)? renderTrophyCard;

  /// Draws a short message's card over the game; TrophyCard.renderNotice by default.
  final Future<RgbaImage> Function(String title, String? detail, IconData symbol, double scale)? renderNoticeCard;

  /// Draws the LIVE badge for the desktop's window; LiveBadge.render by default.
  final Future<RgbaImage> Function(bool live, String time, double scale)? renderLiveBadge;

  /// The sound card for the interface sounds and theme songs; none (silence) when not given.
  final AudioOut Function()? audio;

  /// Reads a game's theme song; LibAtrac9 away from the interface by default.
  final Future<PlayableSong?> Function(String path)? decodeSong;

  /// This system's glibc version, checked against what a Linux engine needs; the system's own
  /// by default (null: unknown, nothing is said).
  final String? Function()? hostGlibc;

  /// Where the AnyPS5 engine's releases are read from (GitHub); none in tests without a fake.
  final GitHubReleases? engineReleases;

  /// Where AnyPS5 Desktop's own releases are read from (GitHub, signed); none in tests without a
  /// fake.
  final GitHubReleases? launcherReleases;

  /// The package manager that installed this copy (Scoop, pacman) or null; looked for on the
  /// computer by default (PackageInstall.detect).
  final PackageManager? Function()? packageManager;

  /// Party voice's microphone and connections; flutter_webrtc by default.
  final VoiceEngine Function()? voiceEngine;

  /// Media server rooms, for share plays and party calls bigger than the mesh; LiveKit by default.
  final SfuRoom Function()? sfuRoom;

  /// Online play's peer connections to the other players; flutter_webrtc by default.
  final GameLinks Function()? gameLinks;

  /// Reads the talk key anywhere on the desktop; the system's reader by default, none in tests.
  final KeyStateReader? Function()? talkKeys;

  /// Opens a web page in the browser.
  final void Function(Uri url)? openUrl;

  /// Plays clips inside the launcher (the gallery's, Captures' and those in chats); libmpv
  /// through media_kit by default. None: a clip shows its picture, as in tests.
  final ClipPlayback Function()? clipPlayback;

  /// Plays voice notes inside the launcher; libmpv in the app, a fake in tests. Null: they go to
  /// the system's player.
  final VoicePlayback Function()? voicePlayback;

  /// Puts a text on the clipboard.
  final void Function(String text)? copyText;

  /// The environment the launcher reads (ANYTOGETHER_URL); the process's by default.
  final Map<String, String>? environment;

  /// Where the AnyTogether session is kept (the first profile's); the system's own store by
  /// default.
  final TokenStore? togetherStore;

  /// Where another launcher profile's session is kept; its own system store by default.
  final TokenStore Function(String profile)? togetherStoreFor;

  /// An AnyTogether server that wins over every choice (tests).
  final Uri? togetherServer;

  /// How often an AnyTogether sign-in asks whether it was approved (tests go faster).
  final Duration? togetherPollEvery;

  /// Whether phones on a USB cable are joined: Android through adb, iPhones through usbmuxd (off
  /// in tests).
  final bool cable;

  /// Whether the phone server is announced on the network (off in tests).
  final bool advertise;

  /// Whether the phone server tries its usual ports first (off in tests: any free port).
  final bool preferredPorts;

  /// Asks the user for a folder; null when they cancelled.
  final Future<String?> Function(String title)? pickFolder;

  /// Shows a folder in the system's file manager.
  final void Function(String folder)? openFolder;
  final String? computerName;
}

/// The launcher's state and everything the interface does with it.
class AppModel extends ChangeNotifier {
  AppModel({
    required this.paths,
    Preferences? preferences,
    this.services = const LauncherServices(),
    HostSystem? system,
    this.persist = true,
  }) : system = system ?? HostSystem.current,
       preferences = preferences ?? Preferences.load(paths.preferencesFile),
       settingsStore = GameSettingsStore(paths.gameSettingsFolder) {
    // Profiles: a launcher set up before them becomes its first profile at once.
    profiles = ProfileStore(
      p.join(paths.config, 'Profiles'),
      existing: ExistingSetup(onboarded: this.preferences.onboarded, name: this.preferences.profileName),
      persist: persist,
      defaultName: LauncherProfiles.defaultName,
    );
    T.language = Language.byCode(this.preferences.language);
    Motion.reduced = this.preferences.reducedMotion;
    together = TogetherModel(this);
    // The party and its code changing (and signing out) change what Discord shows.
    together.hub.addListener(discord.update);
    // The quick menu opening and closing, the account and the family's limits change whether
    // the media session is followed and what friends are shown of it.
    together.hub.addListener(nowPlaying.update);
    addListener(nowPlaying.update);
    _applySound();
    sounds.onCue = _cueAsked;
    // Full screen the system made or ended (Maximize, Win+Up): the launcher follows it.
    services.window?.listen(fullscreenChanged: windowChangedFullscreen);
  }

  // Feel: the controller's pulses, the end-of-row bump, the hover tick.

  /// The launcher's own clock for the feel's timings.
  final Stopwatch _clock = Stopwatch()..start();
  Duration get feelNow => _clock.elapsed;

  /// When the last cue other than the hover tick was asked for.
  Duration? _lastCue;

  late final PulsePlayer _pulses = PulsePlayer(_PadMotors(this));

  /// The pulses the controller gives: Settings › Behaviour › Controller Vibration, never while a
  /// game (or another window) is in front, only while the pad is the device in use.
  late final HapticFeedback haptics = HapticFeedback(_pulses, enabled: preferences.controllerVibration);

  final EdgeBump _edge = EdgeBump();
  final HoverGate _hover = HoverGate();

  void _cueAsked(Cue cue) {
    if (cue != Cue.hover) _lastCue = feelNow;
    final haptic = HapticCue.forSound(cue.name);
    if (haptic != null) _pulse(haptic);
  }

  /// A pulse told on its own: a trophy, an invitation, an error.
  void vibrate(HapticCue cue) => _pulse(cue);

  /// A pulse, only while the launcher is in front: asked of the desktop each time, as Flutter's
  /// own report of the window's focus is not enough on its own (see [launcherInFront]).
  void _pulse(HapticCue cue) {
    haptics.launcherInFront = launcherInFront;
    haptics.play(cue, now: feelNow);
  }

  /// The keyboard or the mouse was used: the controller on the desk stays still.
  void usedKeyboard() {
    haptics.padInUse = false;
    _usedInput(InputMode.keyboardMouse);
  }

  /// The mouse moved over the launcher: its hints and controls show again.
  void usedPointer() {
    if (inputMode == InputMode.keyboardMouse) return;
    usedKeyboard();
  }

  /// The mouse's Back button (XBUTTON1, button 8) and a Back key: Circle wherever the user is.
  /// A field typed in lets go first and a key or button waited for is given up, as Esc does.
  void mouseBack() {
    usedKeyboard();
    _forward = null;
    if (editingRow != null) return stopEditing();
    if (together.capturingTalkKey) {
      together.capturingTalkKey = false;
      return refresh();
    }
    if (shortcutCapture != null) return cancelShortcutCapture();
    final (from, game) = (overlay, selected);
    command(Command.back);
    if (from != null && overlay != from && _forwardLayers.contains(from)) _forward = (from, overlay, game);
  }

  /// The mouse's Forward button (XBUTTON2, button 9): the layer Back just closed opens again,
  /// as a browser goes forward; nothing when the user has gone elsewhere since.
  void mouseForward() {
    usedKeyboard();
    final forward = _forward;
    _forward = null;
    if (forward == null || editingRow != null || pairing != null) return;
    final (layer, landed, game) = forward;
    if (overlay != landed || selected != game) return;
    open(layer);
  }

  /// What Forward opens again: the layer, where Back left the user, and the game selected then.
  (Layer, Layer?, int)? _forward;

  /// Whether the command being handled is a held direction's repeat.
  bool _repeatingNow = false;

  /// The stepper row a held arrow is moving, which way, and how many repeats so far.
  ({String row, int delta, int repeats})? _stepHold;

  /// The layers Forward may open again: plain screens, never a question or a running step.
  static const _forwardLayers = {
    Layer.library,
    Layer.settings,
    Layer.gameSettings,
    Layer.controls,
    Layer.advanced,
    Layer.trophies,
    Layer.gallery,
    Layer.friends,
  };

  /// What a command may change where the eye is: a direction that changed none of it and asked
  /// for no sound hit the end of its row.
  Object _focusMark() => (
    overlay,
    focus.area,
    focus.index,
    selected,
    libraryIndex,
    panelRow,
    panelCategory,
    trophyIndex,
    galleryIndex,
    galleryViewing,
    capturing,
    editingRow,
    panelSections,
    settingsSearchFocused,
    editingValue,
    shortcutCapture,
  );

  /// A command from the keys or a controller: handled, and a direction that did nothing bumps
  /// (once per press, once in a hold that reaches the end).
  void command(Command command, {bool repeat = false}) {
    if (pointerFocus) {
      // The keys or the pad move the focus from here: the lists follow it again.
      pointerFocus = false;
      notifyListeners();
    }
    final mark = _focusMark();
    final asked = sounds.requests;
    _repeatingNow = repeat;
    try {
      handle(command);
    } finally {
      _repeatingNow = false;
    }
    final direction =
        command == Command.left || command == Command.right || command == Command.up || command == Command.down;
    if (_edge.handled(
      direction: direction,
      repeat: repeat,
      changed: sounds.requests != asked || _focusMark() != mark,
    )) {
      sounds.play(Cue.bump);
    }
  }

  /// The pointer arrived on a control, tile, row or card: the quiet tick, when [HoverGate] lets
  /// it.
  void hoverArrived(Object id, {required double x, required double y, required bool buttonsDown}) {
    // Not while a list is dragged or still gliding after one: rows passing under the pointer
    // are not arrivals.
    final allowed = preferences.sounds && active && preferences.onboarded && !panning;
    if (_hover.arrive(id, x: x, y: y, now: feelNow, lastCue: _lastCue, buttonsDown: buttonsDown, allowed: allowed)) {
      sounds.play(Cue.hover);
    }
  }

  void hoverLeft(Object id) => _hover.leave(id);

  /// A list is being dragged with the mouse, or still gliding after it: no hover ticks.
  bool panning = false;

  /// The focus was last moved by the pointer (a row hovered or clicked), not by the keys or a
  /// controller: the lists stay where they are ([KeepVisible] scrolls only for the keys and the
  /// pad, so a list never chases the mouse).
  bool pointerFocus = false;

  late final AudioOut _audio = services.audio?.call() ?? const SilentAudio();

  /// The sound card opened (it may still be off with the launcher's sounds): a watched share
  /// play's sound plays through it.
  Future<bool> startSound() => _audio.start();

  /// The interface's soft sounds (moving, selecting, going back, something finished).
  late final InterfaceSounds sounds = InterfaceSounds(_audio);

  /// The selected game's theme song.
  late final ThemeMusic music = ThemeMusic(_audio, decode: services.decodeSong);

  /// The themes made in the Theme Studio or installed from files (themes_model.dart).
  late final ThemeLibrary themes = ThemeLibrary(p.join(paths.config, 'Themes'));
  late List<ThemeDesign> designs = themes.all;

  /// The Theme studio's knobs as last turned, with the colours they made: read back from the
  /// colours (8 bits each) a hue can come out a degree off, so while the colours are still the
  /// ones the knobs made, the knobs are these (themes_model.dart).
  ({String id, ThemeKnobs knobs, String colours})? _studioKnobs;

  /// Whether the launcher's window is in front: the theme song plays only then.
  bool active = true;

  /// Opens the sound card and makes the interface sounds.
  Future<void> startAudio() => sounds.start();

  static const defaultMusicVolume = 50;

  int get musicVolume => preferences.musicVolume ?? defaultMusicVolume;

  /// The launcher's own volume, over its sounds and its music (Settings › Behaviour).
  int get launcherVolume => (preferences.launcherVolume ?? 100).clamp(0, 100);

  /// Every sound and song the launcher plays goes through [sounds] and [music]: the launcher's
  /// volume is on top of each one's own.
  void _applySound() {
    final master = launcherVolume / 100;
    sounds
      ..enabled = preferences.sounds && launcherVolume > 0
      ..volume = master * (preferences.soundVolume ?? 100) / 100;
    music.volume = master * musicVolume / 100;
  }

  void setActive(bool value) {
    if (active == value) return;
    active = value;
    _shownInFront = launcherInFront;
    // Behind a game (or any other window) the pad is the game's: the motors stop at once, and a
    // direction held on it lets go.
    haptics.launcherInFront = value;
    _padLog?.call('window ${value ? 'in front' : 'behind'} (Flutter)');
    if (!value) _gate?.close();
    if (value) updates.activated();
    // A game may have changed the light bars: the launcher's colour again.
    if (value) controllers.applyLights();
    // Back in front: a toolkit rebuilt meanwhile is read again.
    if (value) _forgetDiskFacts();
    // Something copied in while the launcher was away shows at once.
    // (One watcher's scan reads every games folder.)
    if (value) _libraries.values.firstOrNull?.rescanSoon();
    // A name or handle changed on the website meanwhile.
    if (value) together.refreshOwnProfile();
    notifyListeners();
  }

  /// The selected game's song while the launcher is in front and idle, silence otherwise (the
  /// first start, a game starting or playing, the volume at 0); the interface sounds are quiet
  /// while a game is in front.
  void _updateMusic() {
    final quiet =
        !preferences.onboarded ||
        !active ||
        running != null ||
        starting != null ||
        musicVolume == 0 ||
        launcherVolume == 0;
    // The theme's (or the user's own) menu music when the selected game has no song.
    music.play(quiet ? null : homePreviewGame, fallback: quiet ? null : menuMusic);
    // With the game in front, the launcher says nothing.
    sounds.muted = running != null && !active;
  }

  /// AnyTogether: the account, friends, messages, parties.
  late final TogetherModel together;

  /// "Playing …" on the user's Discord profile.
  late final DiscordModel discord = DiscordModel(this);

  /// Now playing: the quick menu's card and "Listening to …" for friends.
  late final NowPlayingModel nowPlaying = NowPlayingModel(this);

  /// An unlock the user asked for finished (the game's id, whether it worked): Play Together
  /// joins a game it unlocked first.
  void Function(String gameId, bool succeeded)? onUnlocked;

  DesktopWindows get desktop => services.desktop ?? const NoDesktop();

  PadSource? _pads;
  PadNavigator? _navigator;
  PadGate? _gate;
  DeadzoneStage? _deadzone;

  /// Settings › Controllers: the controllers, their log, lights and troubleshooter.
  late final ControllersModel controllers = ControllersModel(this);

  /// The motors of whatever controllers are read now.
  PadRumble? get padMotors => _pads?.motors;

  /// Started from Steam: Steam's virtual controller stands for the real one.
  bool get launchedFromSteam => steamLaunch.fromSteam;

  /// The accent as red, green and blue (0 to 255), for the light bars' Theme Colour.
  (int, int, int) get accentRgb {
    final color = accentChoice.color;
    return ((color.r * 255).round(), (color.g * 255).round(), (color.b * 255).round());
  }

  /// A controller connect or disconnect: the debug log (ANYPS5_PAD_LOG) and the console.
  void padLogLine(String line) {
    _padLog?.call(line);
    debugPrint('[anyps5-launcher] $line');
  }

  /// The controller settings that act at once: Circle confirming, the dead zone, the hints.
  void _applyPadPreferences() {
    _navigator
      ?..circleConfirms = preferences.confirmCircle
      ..shortcuts = preferences.shortcuts;
    _deadzone?.percent = preferences.stickDeadzone;
    Hint.circleConfirms = preferences.confirmCircle;
    applyAssist();
  }

  /// Assist as the phone server needs it.
  void applyAssist() {
    final target = AssistTarget.stored(preferences.assistPlayerOne);
    remote?.setAssist(devices: target.devices, controllers: target.controllers);
  }

  void openControllerTest() {
    unawaited(controllers.probe());
    open(Layer.controllerTest);
  }

  /// Back from the controller test to Settings › Controllers, where it was opened from.
  void closeControllerTest() {
    open(Layer.settings, cue: Cue.back);
    final categories = panelCategories();
    final index = categories.indexWhere((category) => category.id == 'controllers');
    if (index < 0) return;
    panelCategory = index;
    panelRow = categories[index].rows
        .indexWhere((row) => row.id == 'padTest')
        .clamp(0, categories[index].rows.length - 1);
    _changed();
  }

  /// Whether the launcher is in front: Flutter says its window has the focus and, where the
  /// desktop can tell (Windows, X11), the window in front is the launcher's. The controller is
  /// read whichever window is in front, so this is what keeps a game's pad out of the launcher;
  /// Flutter's focus report alone let the presses through on Windows while a game was played.
  bool get launcherInFront {
    // Steam's Game Mode (gamescope) may report no active window at all: with no game running
    // the launcher is what is on screen.
    if (steamLaunch.gameMode && running == null && starting == null) return true;
    return active && (desktop.launcherFocused() ?? true);
  }

  /// A line for the controller's debug log: ANYPS5_PAD_LOG names a file to add them to.
  late final void Function(String line)? _padLog = () {
    final path = (services.environment ?? Platform.environment)['ANYPS5_PAD_LOG'];
    if (path == null || path.isEmpty) return null;
    return (String line) {
      try {
        File(path).writeAsStringSync(
          '${DateTime.now().toIso8601String()} $line (focus ${active ? 'resumed' : 'inactive'}, '
          'desktop ${desktop.launcherFocused()})\n',
          mode: FileMode.append,
        );
      } on FileSystemException {
        // The log is a help, never a reason to stop.
      }
    };
  }();

  /// Reads the controllers: their moves become the same commands as the keys, while the
  /// launcher is in front ([PadGate]).
  void startPads() {
    if (_pads != null) return;
    final source = services.pads?.call();
    if (source == null) return;
    final navigator = _padNavigator;
    final gate = PadGate(_padEvent, inFront: () => launcherInFront, log: _padLog, passesInGame: navigator.passesInGame);
    _gate = gate;
    final deadzone = DeadzoneStage(gate.handle);
    _deadzone = deadzone;
    _applyPadPreferences();
    _pads = source..start(deadzone.handle);
    controllers.attach(source);
    if (_padLog case final log?) {
      log('pad: reading ${source.description}');
      // For the log, what the desktop says as it changes, controller or not.
      bool? said;
      _focusWatch = Timer.periodic(const Duration(milliseconds: 500), (_) {
        final now = desktop.launcherFocused();
        if (now == said) return;
        said = now;
        log('desktop: launcher ${now == null ? 'cannot tell' : (now ? 'in front' : 'behind')}');
      });
    }
  }

  Timer? _focusWatch;

  /// The navigator the controllers and the phones' pads move the launcher through.
  PadNavigator get _padNavigator {
    final made = _navigator;
    if (made != null) return made;
    final navigator = PadNavigator(
      padCommand,
      shortcuts: preferences.shortcuts,
      isPlayStation: (pad) => controllers.roster.pad(pad)?.kind.isPlayStation ?? false,
    );
    _navigator = navigator;
    _applyPadPreferences();
    return navigator;
  }

  /// The pictures sent to the phones, made small and kept.
  final PhoneArt phoneArt = PhoneArt();

  /// The phones' pads (the Remote app's, browser pads) as controller events.
  late final PhonePadEvents _phonePads = PhonePadEvents(_phonePadEvent);

  /// The phone pads whose events reached the navigator since it last let go of them.
  final Set<String> _phonePadsMoving = {};

  /// Whether a phone's pad moves the launcher now: with no game starting or playing and the
  /// launcher in front, as a controller does; otherwise its input is the game's alone.
  bool get phonePadMovesLauncher => running == null && starting == null && launcherInFront;

  void _phonePadEvent(PadEvent event) {
    final navigator = _padNavigator;
    if (event is PadGone) {
      if (_phonePadsMoving.remove(event.pad)) navigator.handle(event);
      return;
    }
    if (!phonePadMovesLauncher) {
      // A game (or another window) is in front: what the launcher held from this pad lets go.
      if (_phonePadsMoving.remove(event.pad)) navigator.handle(PadGone(event.pad));
      return;
    }
    // Options (the pad's settings button): the launcher's Settings, and out of them again.
    if (event is PadButtonEvent && event.button == PadButton.start) {
      if (event.down) _phoneOptions();
      return;
    }
    _phonePadsMoving.add(event.pad);
    navigator.handle(event);
  }

  void _phoneOptions() {
    if (pairing != null || editingRow != null || shortcutCapture != null || !preferences.onboarded) return;
    _usedInput(InputMode.pad);
    if (overlay == Layer.settings) {
      closeOverlay();
    } else {
      open(Layer.settings);
    }
  }

  /// A controller's event past the gate: to the navigator, or to Settings › Shortcuts while it
  /// waits for buttons.
  void _padEvent(PadEvent event) {
    if (shortcutCapture != null && event is PadButtonEvent) return _capturePad(event);
    _navigator?.handle(event);
  }

  /// What the user moved the launcher with last: the controller's hints or the keys'.
  InputMode inputMode = InputMode.keyboardMouse;

  void _usedInput(InputMode mode) {
    if (inputMode == mode) return;
    inputMode = mode;
    notifyListeners();
  }

  /// Whether the command being handled came from a controller (or the phone's pad), not the
  /// keys or the mouse: the settings' sections and edit mode are for it.
  bool _viaPad = false;

  /// A controller command. With the launcher behind a game (or another window) only PS/Guide
  /// and the in-game shortcuts (the quick menu, Share) count.
  void padCommand(PadCommand command) {
    final inFront = launcherInFront;
    final Command mapped;
    switch (command) {
      case PadCommand.homeHold || PadCommand.quickMenu || PadCommand.screenshot || PadCommand.saveClip:
        _pulses.pad = _navigator?.lastPad;
        // A controller's press, in the game or not: the menus it opens show its buttons.
        _usedInput(InputMode.pad);
        if (inFront) haptics.padInUse = true;
        if (overlay == Layer.controllerTest && inFront) return;
        return switch (command) {
          PadCommand.homeHold => homeHeld(),
          PadCommand.quickMenu => unawaited(openQuickMenu()),
          PadCommand.screenshot => unawaited(takeScreenshot()),
          _ => unawaited(saveClip()),
        };
      case PadCommand.fullscreen:
        if (!inFront || overlay == Layer.controllerTest) return;
        _usedInput(InputMode.pad);
        return unawaited(toggleFullscreen());
      case PadCommand.left:
        mapped = Command.left;
      case PadCommand.right:
        mapped = Command.right;
      case PadCommand.up:
        mapped = Command.up;
      case PadCommand.down:
        mapped = Command.down;
      case PadCommand.select:
        mapped = Command.select;
      case PadCommand.back:
        mapped = Command.back;
      case PadCommand.options:
        mapped = Command.options;
      case PadCommand.menu:
        // Options/Start on Home: Switch Profile, online or offline (Triangle stays the game's).
        mapped = Command.options;
        if (overlay == null && preferences.onboarded && inFront && pairing == null && starting == null) {
          haptics.padInUse = true;
          _usedInput(InputMode.pad);
          return openProfileMenu();
        }
      case PadCommand.previousGame:
        mapped = Command.previousGame;
      case PadCommand.nextGame:
        mapped = Command.nextGame;
      case PadCommand.home:
        mapped = Command.home;
    }
    if (mapped != Command.home && !inFront) return;
    haptics.padInUse = true;
    _pulses.pad = _navigator?.lastPad;
    controllers.used(_navigator?.lastPad);
    _usedInput(InputMode.pad);
    // The controller test takes the pads' buttons: only PS acts (a held Circle leaves it).
    if (overlay == Layer.controllerTest && mapped != Command.home) return;
    if (editingRow != null) {
      // Typing in Settings' search: ○ stops (the field keeps the focus), ↓ goes to what it found.
      if (editingRow == SettingsSearch.searchRow && (mapped == Command.back || mapped == Command.down)) {
        stopEditing();
        if (mapped == Command.down) _searchCommand(Command.down);
      }
      return;
    }
    if (capturing != null && mapped != Command.back) return;
    if (overlay == Layer.settings && (mapped == Command.previousGame || mapped == Command.nextGame)) {
      return moveCategory(mapped == Command.nextGame ? 1 : -1);
    }
    _viaPad = true;
    try {
      this.command(mapped, repeat: _navigator?.repeating ?? false);
    } finally {
      _viaPad = false;
    }
  }

  // Shortcuts (Settings › Shortcuts).

  /// The action waiting for a key or controller buttons in Settings › Shortcuts.
  LauncherAction? shortcutCapture;

  /// The buttons held together so far while waiting, the most at once, and whether they were
  /// held long enough to be a long press.
  final Set<PadButton> _captureHeld = {};
  final Set<PadButton> _captureChord = {};
  bool _captureLong = false;
  Timer? _captureTimer;

  void startShortcutCapture(LauncherAction action) {
    shortcutCapture = action;
    _captureHeld.clear();
    _captureChord.clear();
    _captureLong = false;
    // The press that chose the row is let go into the capture: the navigator starts afresh.
    _navigator?.reset();
    sounds.play(Cue.select);
    _changed();
  }

  void cancelShortcutCapture() {
    if (shortcutCapture == null) return;
    shortcutCapture = null;
    _captureTimer?.cancel();
    sounds.play(Cue.back);
    _changed();
  }

  void _capturePad(PadButtonEvent event) {
    final button = _navigator?.normalize(event.pad, event.button) ?? event.button;
    if (event.down) {
      _captureHeld.add(button);
      _captureChord.add(button);
      _captureTimer?.cancel();
      _captureLong = false;
      _captureTimer = Timer(ShortcutTiming.hold, () => _captureLong = true);
      return;
    }
    if (!_captureHeld.remove(button) || _captureHeld.isNotEmpty) return;
    _captureTimer?.cancel();
    final chord = PadChord({..._captureChord}, hold: _captureLong);
    _captureChord.clear();
    _usedInput(InputMode.pad);
    // Circle alone (Cross with Circle confirming) is the way out.
    final cancel = preferences.confirmCircle ? PadButton.south : PadButton.east;
    if (!chord.hold && chord.buttons.length == 1 && chord.buttons.first == cancel) return cancelShortcutCapture();
    // Triangle alone clears the controller's binding.
    if (!chord.hold && chord.buttons.length == 1 && chord.buttons.first == PadButton.north) {
      final action = shortcutCapture!;
      shortcutCapture = null;
      return clearShortcut(action, input: InputMode.pad);
    }
    assignPadShortcut(chord);
  }

  /// A key pressed while a shortcut waits for one.
  void captureShortcutKey(KeyCombo key) {
    if (shortcutCapture == null) return;
    _usedInput(InputMode.keyboardMouse);
    final plain = !key.control && !key.alt && !key.shift;
    if (key.key == KeyIds.escape && plain) return cancelShortcutCapture();
    final action = shortcutCapture!;
    // Backspace (or Delete) alone clears the key.
    if ((key.key == KeyIds.backspace || key.key == KeyIds.delete) && plain) {
      shortcutCapture = null;
      return clearShortcut(action, input: InputMode.keyboardMouse);
    }
    final conflict = preferences.shortcuts.keyConflict(action, key);
    _finishCapture(conflict, () => preferences.shortcuts[action].withKey(key));
  }

  void assignPadShortcut(PadChord chord) {
    final action = shortcutCapture;
    if (action == null) return;
    final conflict = preferences.shortcuts.padConflict(action, chord);
    _finishCapture(conflict, () => preferences.shortcuts[action].withPad(chord));
  }

  void _finishCapture(ShortcutConflict? conflict, ShortcutBinding Function() binding) {
    final action = shortcutCapture!;
    shortcutCapture = null;
    if (conflict != null) {
      vibrate(HapticCue.error);
      sounds.play(Cue.bump);
      show(switch (conflict) {
        TakenBy(:final action) => T.format('shortcutTaken', [shortcutTitle(action)]),
        Reserved() => T.text('shortcutReserved'),
      });
      _changed();
      return;
    }
    preferences.shortcuts = preferences.shortcuts.withBinding(action, binding());
    sounds.play(Cue.move);
    savePreferences();
  }

  /// The shortcut whose row the focus is on in Settings › Shortcuts, if any.
  LauncherAction? get focusedShortcut {
    if (overlay != Layer.settings) return null;
    final rows = _currentRows;
    final id = panelRow < rows.length ? rows[panelRow].id : '';
    return id.startsWith('shortcut-') ? LauncherAction.byName(id.substring('shortcut-'.length)) : null;
  }

  /// △ (or Delete) on a shortcut: the binding of the input in use goes.
  void clearShortcut(LauncherAction action, {InputMode? input}) {
    final binding = preferences.shortcuts[action];
    final next = (input ?? inputMode) == InputMode.pad ? binding.withPad(null) : binding.withKey(null);
    if (next == binding) return _changed();
    preferences.shortcuts = preferences.shortcuts.withBinding(action, next);
    sounds.play(Cue.back);
    savePreferences();
  }

  /// The action a key runs while the launcher has the keyboard, if any.
  LauncherAction? shortcutForKey(KeyCombo key) => preferences.shortcuts.actionForKey(key);

  /// A shortcut's key pressed in the launcher.
  void runKeyShortcut(LauncherAction action) {
    usedKeyboard();
    switch (action) {
      case LauncherAction.home:
        command(Command.home);
      case LauncherAction.quickMenu:
        unawaited(openQuickMenu());
      case LauncherAction.screenshot:
        unawaited(takeScreenshot());
      case LauncherAction.saveClip:
        unawaited(saveClip());
      case LauncherAction.toggleFullscreen:
        unawaited(toggleFullscreen());
      case LauncherAction.previousSection || LauncherAction.nextSection:
        final delta = action == LauncherAction.nextSection ? 1 : -1;
        if (overlay == Layer.settings) return moveCategory(delta);
        command(delta > 0 ? Command.nextGame : Command.previousGame);
    }
  }

  static String shortcutTitle(LauncherAction action) => T.text(switch (action) {
    LauncherAction.home => 'shortcutHome',
    LauncherAction.quickMenu => 'shortcutQuickMenu',
    LauncherAction.screenshot => 'shortcutScreenshot',
    LauncherAction.saveClip => 'shortcutSaveClip',
    LauncherAction.toggleFullscreen => 'shortcutFullscreen',
    LauncherAction.previousSection => 'shortcutPreviousSection',
    LauncherAction.nextSection => 'shortcutNextSection',
  });

  /// The AnyPS5 engine downloaded from upstream: versions, the download, the one in use.
  late final EngineModel engine = EngineModel(this);
  late final LauncherUpdateModel updates = LauncherUpdateModel(this);

  /// The system fonts games get: the folder put together for them, the CJK download.
  late final FontsModel fonts = FontsModel(this);

  /// Remote Play and broadcasting.
  late final MediaModel media = MediaModel(this);

  /// Hosting share play while a game runs.
  late final SharePlayModel sharePlay = SharePlayModel(this);
  late final BrowserPlayModel browserPlay = BrowserPlayModel(this);

  /// AnyPS5 and its games in the Steam library (Settings › Steam).
  late final SteamModel steam = SteamModel(this);

  /// Save Sync and cloud saves (save_sync_model.dart).
  late final SaveSyncModel saveSync = SaveSyncModel(this);

  /// Settings › Battery & Heat: the power read, the profiles applied to the game and launcher.
  late final PowerModel powerWatch = PowerModel(this);

  /// How this launch came from Steam (a shortcut's --steam, SteamGameId, gamescope), and the
  /// controllers Steam Input took over.
  SteamLaunch steamLaunch = const SteamLaunch();

  /// The crash report of a game's last start, and detailed logging.
  late final CrashModel crash = CrashModel(this);

  /// Zips dropped into the games folders and updates added from a folder.
  late final GameFilesModel files = GameFilesModel(this);

  /// Game Settings › Delete game: the game itself off the disk.
  late final GameDeleteModel deletion = GameDeleteModel(this);

  /// Closed: what still runs for it (a deletion) says nothing more.
  bool get disposed => _disposed;

  /// [game] out of the library at once (Delete game), before its files are gone: the selection
  /// stays where it is, on the game that takes its place.
  void hideGame(Game game) {
    final index = games.indexWhere((other) => other.id == game.id);
    if (index < 0) return;
    games = [...games]..removeAt(index);
    if (selected > index) selected--;
    selected = selected.clamp(0, games.isEmpty ? 0 : games.length - 1);
    if (libraryIndex > index) libraryIndex--;
    libraryIndex = libraryIndex.clamp(0, games.isEmpty ? 0 : games.length - 1);
    _changed();
  }

  /// What the launcher held about a game that is no longer on the disk (Delete game). Its
  /// settings stay, for the day it is added again.
  void forgetGame(Game game) {
    sizes.remove(game.id);
    failures.remove(game.id);
    trophies.remove(game.id);
    records.remove(game.id);
  }

  // The launcher's own crashes and stalls (core/launcher_health.dart).

  /// What an earlier run left to report, offered once the home screen is free.
  LauncherProblem? launcherProblem;

  /// Called once that report was sent or put aside (problem.json goes).
  void Function()? onLauncherProblemDone;

  /// The problem with what Windows or Linux kept of how that run ended (LauncherHealth.lookAgain),
  /// read when the report is sent.
  Future<LauncherProblem> Function(LauncherProblem problem)? lookAgainLauncherProblem;

  /// The first error this run's code did not catch, with its stack, for a report.
  String? firstError;

  /// A line a second of what the launcher drew and showed (LauncherShell's FrameLog), the newest
  /// last: a report's last seconds.
  final List<String> recentLines = [];

  void addRecentLine(String line) {
    recentLines.add(line);
    if (recentLines.length > LauncherHealth.keptLines) recentLines.removeAt(0);
  }

  bool _problemOffered = false;

  /// Send Report? once, when nothing else is on the home screen (after "Who's playing?").
  void offerLauncherReport() {
    if (_problemOffered || launcherProblem == null || !preferences.onboarded) return;
    if (overlay != null || running != null || starting != null || pairing != null) return;
    _problemOffered = true;
    open(Layer.launcherReport);
  }

  /// Opens the pre-filled GitHub issue; nothing is sent until the user submits it there.
  Future<void> sendLauncherReport() async {
    final unread = launcherProblem;
    if (unread == null) return;
    _launcherProblemDone();
    final problem = await lookAgainLauncherProblem?.call(unread) ?? unread;
    final system = await crash.systemInfo();
    final privacy = crash.privacy();
    final draft = IssueDraft.launcherProblem(problem, system: system, privacy: privacy);
    // The link had no room for every line: the whole report on the clipboard, to paste there.
    if (draft.linesLeftOut > 0 && services.copyText != null) {
      services.copyText!(IssueDraft.launcherProblemText(problem, system: system, privacy: privacy));
      show(T.text('launcherReportCopied'));
    }
    services.openUrl?.call(draft.url);
  }

  void _launcherProblemDone() {
    launcherProblem = null;
    onLauncherProblemDone?.call();
    closeOverlay();
  }

  List<PanelRow> _launcherReportRows() => [
    PanelRow(
      id: 'sendReport',
      title: T.text('launcherReportSend'),
      detail: T.text('launcherReportSendDetail'),
      kind: ActionRow(() => unawaited(sendLauncherReport())),
    ),
    PanelRow(
      id: 'notNow',
      title: T.text('launcherReportLater'),
      detail: T.text('launcherReportLaterDetail'),
      kind: ActionRow(_launcherProblemDone),
    ),
  ];

  /// The text row the cursor is in, by id; null while the keys move through the launcher.
  String? editingRow;

  void startEditing(String id) {
    editingRow = id;
    // A click in Settings' search field: the keys are there.
    if (id == SettingsSearch.searchRow) settingsSearchFocused = true;
    // A click in the party chat's field: the keys are in the chat.
    if (id == TogetherPartyChat.draftRow) together.partyChatKeys.focused = true;
    notifyListeners();
  }

  void stopEditing() {
    if (editingRow == null) return;
    editingRow = null;
    notifyListeners();
  }

  /// Something outside the model changed what the screen shows.
  void refresh() => _changed();

  final AppPaths paths;

  /// Replaced by another profile's when that profile plays (profiles_model.dart).
  Preferences preferences;

  /// Who plays on this computer, and the profile screens' state.
  late final ProfileStore profiles;
  final ProfileFlow profileFlow = ProfileFlow();

  /// The picture being cut square for the profile, while [Layer.cropPicture] is up; and a
  /// picture going up to AnyTogether or coming down from it.
  PictureCrop? pictureCrop;
  bool pictureBusy = false;

  /// The other profiles' sessions in tests and previews, which give the first one's in memory.
  final Map<String, MemoryTokenStore> _memoryStores = {};

  /// Their end-to-end encryption keys and notes, in memory there too.
  final Map<String, MemoryE2eeKeyStore> _memoryKeys = {};
  final Map<String, MemoryE2eeNotesStore> _memoryNotes = {};
  final LauncherServices services;
  final HostSystem system;
  final GameSettingsStore settingsStore;

  /// Whether choices are written to disk (off in previews and tests).
  final bool persist;

  /// Settings › Game Presets of the profile playing, in a file of their own in its folder
  /// ([GamePresetsStore]): every game it starts begins with them. Read again when another
  /// profile plays.
  GamePresets get gamePresets {
    final owner = _presetsOwner;
    if (_presets == null || owner != _cachedPresetsOwner) {
      _presets = persist ? GamePresetsStore(gamePresetsFile(owner)).load() : const GamePresets();
      _cachedPresetsOwner = owner;
    }
    return _presets!;
  }

  GamePresets? _presets;
  String? _cachedPresetsOwner;
  String get _presetsOwner => profiles.book.currentProfile?.id ?? LauncherProfile.legacyId;

  /// Where profile [id]'s presets are kept: beside its other files, under the profiles folder.
  String gamePresetsFile(String id) => p.join(profiles.folder, id, 'GamePresets.json');

  void setGamePresets(GamePresets presets) {
    if (presets == gamePresets) return;
    _presets = presets;
    _cachedPresetsOwner = _presetsOwner;
    if (persist) GamePresetsStore(gamePresetsFile(_presetsOwner)).save(presets);
    _changed();
  }

  List<PanelRow> _presetRows() {
    final presets = gamePresets;
    const difficultyNames = [
      'presetGameDefault',
      'presetEasiest',
      'presetEasy',
      'presetNormal',
      'presetHard',
      'presetHardest',
    ];
    const priorityNames = ['presetGameDefault', 'presetPerformance', 'presetResolution'];
    const subtitleNames = ['presetGameDefault', 'presetShow', 'presetHide'];
    const languages = ConsoleLanguage.all;
    final languageIndex = presets.audioLanguage == null
        ? 0
        : languages.indexWhere((language) => language.$1 == presets.audioLanguage) + 1;
    PanelRow toggle(String id, bool value, GamePresets Function(bool) change) =>
        PanelRow(id: id, title: T.text(id), kind: ToggleRow(value, (on) => setGamePresets(change(on))));
    return [
      PanelRow(id: 'presetsIntro', title: T.text('presetsIntroTitle'), kind: InfoRow(T.text('presetsIntro'))),
      PanelRow(
        id: 'presetDifficulty',
        title: T.text('presetDifficulty'),
        kind: ChoiceRow([for (final name in difficultyNames) T.text(name)], presets.difficulty.index, (index) {
          setGamePresets(presets.copyWith(difficulty: PresetDifficulty.values[index]));
        }),
      ),
      PanelRow(
        id: 'presetPriority',
        title: T.text('presetPriority'),
        detail: T.text('presetPriorityDetail'),
        kind: ChoiceRow([for (final name in priorityNames) T.text(name)], presets.priority.index, (index) {
          setGamePresets(presets.copyWith(priority: PresetPriority.values[index]));
        }),
      ),
      toggle(
        'presetInvertVerticalFirst',
        presets.invertVerticalFirstPerson,
        (on) => presets.copyWith(invertVerticalFirstPerson: on),
      ),
      toggle(
        'presetInvertHorizontalFirst',
        presets.invertHorizontalFirstPerson,
        (on) => presets.copyWith(invertHorizontalFirstPerson: on),
      ),
      toggle(
        'presetInvertVerticalThird',
        presets.invertVerticalThirdPerson,
        (on) => presets.copyWith(invertVerticalThirdPerson: on),
      ),
      toggle(
        'presetInvertHorizontalThird',
        presets.invertHorizontalThirdPerson,
        (on) => presets.copyWith(invertHorizontalThirdPerson: on),
      ),
      PanelRow(
        id: 'presetSubtitles',
        title: T.text('presetSubtitles'),
        kind: ChoiceRow([for (final name in subtitleNames) T.text(name)], presets.subtitles.index, (index) {
          setGamePresets(presets.copyWith(subtitles: PresetSubtitles.values[index]));
        }),
      ),
      PanelRow(
        id: 'presetAudioLanguage',
        title: T.text('presetAudioLanguage'),
        kind: ChoiceRow(
          [T.text('presetGameDefault'), for (final language in languages) language.$2],
          languageIndex < 0 ? 0 : languageIndex,
          (index) => setGamePresets(presets.copyWith(audioLanguage: () => index == 0 ? null : languages[index - 1].$1)),
        ),
      ),
      if (!presets.isEmpty)
        PanelRow(
          id: 'presetsReset',
          title: T.text('presetsReset'),
          kind: ActionRow(() => setGamePresets(const GamePresets())),
        ),
    ];
  }

  List<Game> games = [];
  int selected = 0;
  RetroPlatform? _homeRetroFolder;
  int libraryIndex = 0;
  HomeFocus focus = HomeFocus.tiles;
  Layer? overlay;
  bool scanning = false;

  /// The panel row the keyboard is on, and in the settings, the category.
  int panelRow = 0;
  int panelCategory = 0;

  /// With a controller in the settings: the focus is on the sections' column (← from a row),
  /// where ↑ and ↓ change the section and → or ✕ go back into its rows.
  bool panelSections = false;

  /// Settings' search (settings_search.dart): what is typed, whether the keys are on the field,
  /// and the section to go back to when it is emptied.
  String settingsQuery = '';
  bool settingsSearchFocused = false;
  int _categoryBeforeSearch = 0;

  /// With a controller: the choice or stepper row whose value ← and → change now (✕ on it);
  /// outside it they never change a value. Null while none is.
  String? editingValue;

  /// The pad action waiting for a key in the controls panel.
  PadAction? capturing;

  final Map<String, InstallRecord> records = {};
  final Map<String, (InstallStep, double)> progress = {};
  final List<String> queue = [];
  final Map<String, String> failures = {};
  final Map<String, int> sizes = {};

  /// Each game's own actions by pad button (UnrealControls), read the first time its controls
  /// open; empty while being read and for a game whose files name none.
  final Map<String, Map<PadAction, List<String>>> gameControls = {};

  /// The selected game's pictures while the gallery is open, newest first; the one the focus is
  /// on and whether it is shown over the whole screen.
  List<String> galleryShots = const [];
  int galleryIndex = 0;
  bool galleryViewing = false;
  Layer? _galleryFrom;

  /// The picture taken when each trophy of the selected game was earned, by trophy id.
  Map<String, String> trophyShots = const {};

  static const galleryColumns = 4;

  List<String> screenshotsOf(Game game) => Screenshots.list(picturesFolder, game);

  /// Where F12 screenshots, trophy pictures and clips go: Settings › Captures › Screenshots
  /// Folder, else Pictures/AnyPS5.
  String get picturesFolder => preferences.screenshotsFolder ?? paths.pictures;

  /// The selected game's pictures read again (another screenshots folder).
  void loadGalleryShots() => _loadShots();

  void _loadShots() {
    final game = selectedGame;
    galleryShots = game == null ? const [] : screenshotsOf(game);
    trophyShots = Screenshots.trophyShots(galleryShots);
  }

  /// Opens the gallery of the selected game, coming back to [from] (or home) after.
  void openGallery({String? shot}) {
    _galleryFrom = overlay;
    open(Layer.gallery);
    final index = shot == null ? -1 : galleryShots.indexOf(shot);
    if (index >= 0) {
      galleryIndex = index;
      galleryViewing = true;
      _changed();
    }
  }

  void _galleryCommand(Command command) {
    // The post being written, then the Share menu, have the keys over the gallery.
    if (together.captures.draft != null) return together.postDraftCommand(command);
    if (together.captures.sharing) return together.shareCommand(command);
    final count = galleryShots.length;
    void move(int delta) {
      final next = (galleryIndex + delta).clamp(0, count == 0 ? 0 : count - 1);
      if (next == galleryIndex) return;
      galleryIndex = next;
      sounds.play(Cue.move);
      _changed();
    }

    switch (command) {
      case Command.left:
        move(-1);
      case Command.right:
        move(1);
      case Command.up:
        if (!galleryViewing) move(-galleryColumns);
      case Command.down:
        if (!galleryViewing) move(galleryColumns);
      // A clip plays over the whole screen as a picture is shown, as on the Mac.
      case Command.select:
        if (count == 0) return;
        galleryViewing = !galleryViewing;
        sounds.play(galleryViewing ? Cue.select : Cue.back);
        _changed();
      // △ shares, as on the Mac: to a chat, to the AnyTogether gallery, as a post; without a
      // server that keeps files, the file's folder.
      case Command.options when count > 0:
        together.openShareMenu();
      case Command.back || Command.options:
        if (galleryViewing) {
          galleryViewing = false;
          sounds.play(Cue.back);
          _changed();
        } else if (_galleryFrom case final Layer from) {
          final trophy = trophyIndex;
          final revealed = revealedTrophies;
          open(from, cue: Cue.back);
          if (from == Layer.trophies) {
            trophyIndex = trophy;
            revealedTrophies = revealed;
          }
        } else {
          closeOverlay();
        }
      default:
        break;
    }
  }

  /// A click on a picture or clip in the gallery: shown big (a clip plays); a click on a big
  /// picture goes back.
  void tapShot(int index) {
    if (index < 0 || index >= galleryShots.length) return;
    galleryIndex = index;
    galleryViewing = true;
    sounds.play(Cue.select);
    _changed();
  }

  /// A clip from the gallery, playing over the whole screen in the launcher.
  void openClip(String path) {
    final index = galleryShots.indexOf(path);
    if (index < 0) return;
    tapShot(index);
  }

  /// A clip the launcher's player could not open ([source] a file's path or a link): in the
  /// system's video player instead.
  void playClipOutside(String source) {
    final link = Uri.tryParse(source);
    services.openUrl?.call(link != null && link.hasScheme && link.scheme.length > 1 ? link : Uri.file(source));
  }

  /// Each game's trophies, read at the scan; a game without trophy packages has none.
  final Map<String, TrophySet> trophies = {};
  int trophyIndex = 0;

  /// The hidden trophies shown in the list open now (△ on one), by id; forgotten when it closes.
  Set<String> revealedTrophies = {};

  /// Whether [trophy] is hidden from the list until it is earned, and can be shown with △.
  bool canReveal(Trophy trophy) => trophy.hidden && trophy.unlocked == null && !preferences.showHiddenTrophies;

  /// Whether the list shows [trophy] as a hidden trophy: no name, description or icon.
  bool isSecret(Trophy trophy) => canReveal(trophy) && !revealedTrophies.contains(trophy.id);

  /// The trophy the list's focus is on.
  Trophy? get focusedTrophy => trophies[selectedGame?.id]?.trophies.elementAtOrNull(trophyIndex);

  /// Shows a hidden trophy in the list, or hides it again (△, or a click on its Show).
  void toggleReveal(int index) {
    final trophy = trophies[selectedGame?.id]?.trophies.elementAtOrNull(index);
    if (trophy == null || !canReveal(trophy)) return;
    trophyIndex = index;
    final shown = !revealedTrophies.remove(trophy.id);
    if (shown) revealedTrophies = {...revealedTrophies, trophy.id};
    sounds.play(shown ? Cue.select : Cue.back);
    _changed();
  }

  Timer? _trophyWatch;
  Set<String> _earned = {};
  Installer? _installer;
  String? _playAfterInstall;

  /// What goes on once a copy made by another engine is rebuilt ([rebuildFirst]): the game's
  /// start, hosting Play Together, a friend's game joined.
  (String, void Function())? afterRebuild;

  Game? starting;
  (Game, RunningGame)? running;

  /// A short message at the bottom of the screen, with a trophy level's badge before it when
  /// it says one was reached.
  String? toast;
  LevelBadge? toastLevel;

  /// A game's icon before the words (a new game).
  String? toastIcon;

  /// What a click on the toast does (a message's: open its conversation); null for most.
  void Function()? toastTap;

  /// A notice on the desktop while the launcher is behind other windows.
  void Function(String title, String body) desktopNotify = (title, body) =>
      DesktopNotice.show(title, body, urgent: false);
  Timer? _toastTimer;

  RemoteServer? remote;
  ServiceAdvertiser? _advertiser;
  AdbTunnel? _adb;

  /// iPhones on a cable, through usbmuxd (Apple Mobile Device Support on Windows,
  /// libimobiledevice's usbmuxd on Linux), as on the Mac.
  UsbTunnel? _usb;
  PairingRequest? pairing;
  String? phoneConnecting;
  double? phoneLatency;
  String? remoteError;
  RemoteMessage? _toldLibrary;

  /// Settings › About › Update Channel.
  UpdateChannel get updateChannel => UpdateChannel.of(preferences.updateChannel);

  /// A new update channel: the engine picker and the launcher's own update ask for it at once.
  /// Stable offers a release only when it is newer than what is in use, so going back to Stable
  /// never installs an older engine or launcher.
  void setUpdateChannel(UpdateChannel channel) {
    if (channel == updateChannel) return;
    preferences.updateChannel = channel.saved;
    savePreferences();
    engine.channelChanged();
    updates.channelChanged();
  }

  /// The animated background in use: the custom theme's when one is used.
  LookStyle get look => LookStyle.fromIndex(activeDesign?.style ?? preferences.theme);

  /// Glass gave up its transparency: the GPU took too long to draw it (RasterWatch), this run or
  /// an earlier one (kept as Preferences.glassTooSlow).
  late bool glassFallback = preferences.glassTooSlow;

  /// Glass surfaces drawn solid: asked for, the GPU too slow for the blur, or Glass
  /// Transparency at 0 % on a window that could let the desktop through.
  bool get solidGlass =>
      preferences.reduceTransparency ||
      // Settings › Battery & Heat › Lighter Launcher, while a profile holds.
      powerWatch.dimmed ||
      glassFallback ||
      (backdrop.kind.seeThrough && preferences.glassTransparency == 0);

  WindowBackdrop get backdrop => services.backdrop ?? const NoBackdrop();

  /// Glass's window: see-through to the desktop where the system can, under its tint.
  GlassWindow get glassWindow => GlassWindow.make(
    glass: look == LookStyle.glass,
    solid: solidGlass,
    transparency: preferences.glassTransparency,
    kind: backdrop.kind,
  );

  bool? _backdropApplied;
  Timer? _backdropRetry;

  /// Puts the window's backdrop in step with the look: called after every change. Before the
  /// window first shows it cannot be found, so it is tried again a little later.
  void applyBackdrop() {
    final seeThrough = glassWindow.seeThrough;
    if (_backdropApplied == seeThrough || backdrop.kind == BackdropKind.none) return;
    _backdropRetry?.cancel();
    if (backdrop.apply(seeThrough: seeThrough)) {
      _backdropApplied = seeThrough;
    } else {
      _backdropRetry = Timer(const Duration(milliseconds: 250), applyBackdrop);
    }
  }

  /// The GPU fell behind drawing Glass: its surfaces turn solid, once said in a toast, and stay
  /// solid at the next starts too (picking Glass again in Settings tries once more).
  void glassTooSlow() {
    if (glassFallback || look != LookStyle.glass) return;
    glassFallback = true;
    preferences.glassTooSlow = true;
    if (persist) preferences.save(paths.preferencesFile);
    if (!preferences.reduceTransparency) show(T.text('glassFallback'));
    notifyListeners();
  }

  /// PS/Guide as a toggle between the game and the launcher (one press, one switch).
  final GuideSwitch _guide = GuideSwitch();

  /// Whether the launcher was in front at the last look ([checkFront]): the desktop's word
  /// where it has one (Windows, X11), Flutter's focus otherwise. Not in front, the launcher
  /// rests: no animation, no frame drawn, the GPU left to the game.
  bool get resting => !_shownInFront;
  bool _shownInFront = true;

  /// Looks again whether the launcher's window is in front (the shell asks a few times a
  /// second: Flutter's own focus report does not change on Windows when a game takes over).
  void checkFront() {
    final front = launcherInFront;
    // The own profile, read again every few minutes while the launcher is in front.
    if (front) together.refreshOwnProfile(age: TogetherModel.ownProfileAge);
    if (front == _shownInFront) return;
    _shownInFront = front;
    if (!front) {
      _gate?.close();
      haptics.launcherInFront = false;
    } else {
      together.refreshOwnProfile();
    }
    notifyListeners();
  }

  /// For PS/Guide, which window is in front now: the desktop's answer, which changes the moment
  /// the window does (Flutter's focus can lag behind it, or not change at all on Windows).
  bool get _frontForGuide {
    if (steamLaunch.gameMode && running == null && starting == null) return true;
    return desktop.launcherFocused() ?? active;
  }

  /// The game back in front, the launcher behind it (or minimized again, with Hide the
  /// launcher while a game runs).
  Future<void> _showGame(RunningGame run) async {
    final shown = await desktop.focusGame(run.pid);
    _padLog?.call('PS: game ${shown ? 'in front' : 'could not be brought in front'}');
    if (preferences.hideWhilePlaying && running?.$2 == run) await _hideForGame();
    checkFront();
  }

  /// Whether the launcher's window was minimized for the game playing (Settings › Behaviour ›
  /// Hide the launcher while a game runs).
  bool hiddenForGame = false;

  /// The launcher's window steps aside while a game runs, as on the Mac: minimized, so it stays
  /// in the taskbar and PS still brings it back with the quick menu.
  Future<void> _hideForGame() async {
    final window = services.window;
    if (window == null) return;
    final hidden = await window.minimize();
    // The game closed while the window went: straight back.
    if (running == null) {
      if (hidden) await window.restore();
      return;
    }
    hiddenForGame = hidden;
  }

  /// The launcher's window in front of everything (PS, a link, a crash report), back from
  /// minimized first when it stepped aside for the game.
  Future<bool> raiseLauncher() async {
    if (hiddenForGame) {
      hiddenForGame = false;
      await services.window?.restore();
    }
    return desktop.raiseLauncher();
  }

  /// The built-in accent chosen in Settings › Appearance (or the look's own).
  Accent get builtInAccent =>
      Accent.values.firstWhere((accent) => accent.name == preferences.accent, orElse: () => look.defaultAccent);

  /// The accent in use: a custom theme's own colour, else the built-in one.
  AccentChoice get accentChoice {
    final design = activeDesign;
    if (design == null) return AccentChoice(builtInAccent.color, index: builtInAccent.index);
    final rgb = design.accentRgb;
    return AccentChoice(Color.fromRGBO((rgb.r * 255).round(), (rgb.g * 255).round(), (rgb.b * 255).round(), 1));
  }

  Game? get selectedGame => games.isEmpty ? null : games[selected.clamp(0, games.length - 1)];

  /// The chosen toolkit; without one (or when it is gone), the newest downloaded engine.
  ///
  /// Finding it reads the disk (the relinker, every library, version.txt), and the screen asks
  /// for it for every game on every frame it builds: it is looked up again only when the choice,
  /// the downloaded engines or the library change.
  Toolkit? get toolkit {
    final key = (preferences.toolkitFolder, identityHashCode(engine.downloaded), _toolkitEpoch);
    if (key != _toolkitKey) {
      final folder = preferences.toolkitFolder;
      _toolkit = Toolkit.locate([?folder, for (final kit in engine.downloaded) kit.root], system: system);
      _toolkitVersion = _toolkit?.version;
      _toolkitKey = key;
    }
    return _toolkit;
  }

  Toolkit? _toolkit;
  String? _toolkitVersion;
  Object? _toolkitKey;
  int _toolkitEpoch = 0;

  /// The version.txt of [toolkit], read once with it.
  String? get toolkitVersion {
    toolkit;
    return _toolkitVersion;
  }

  /// Facts about a game the settings rows show that cost a disk read (its patch file, its
  /// backups), read when its settings open rather than on every frame.
  final Map<String, ({bool resolution, List<String> backups})> _gameFacts = {};

  /// The resolution [game] is unlocked with: the one chosen in its Game Settings, or one step
  /// below it while a Battery & Heat profile asks for a lower resolution (the title's own when
  /// none is chosen). On Windows and Linux the relinker writes it, so it lasts until the next
  /// unlock.
  String? _unlockResolution(Game game, Toolkit kit) {
    final own = currentSettings(game).resolution;
    if (!powerWatch.adjustment.lowerResolution) return own;
    final patch = kit.patchFile(game.titleId);
    if (patch == null) return own;
    final String text;
    try {
      text = File(patch).readAsStringSync();
    } on FileSystemException {
      return own;
    }
    if (!ResolutionPatch.supports(text)) return own;
    final current = own ?? ResolutionPatch.defaultOf(text);
    if (current == null) return own;
    return ResolutionPatch.lower(current, ResolutionPatch.choices) ?? own;
  }

  /// A game about to start: one step lower under a Battery & Heat profile that asks for it,
  /// the resolution it was unlocked with otherwise, written into its executable as on the Mac
  /// (LaunchResolution). A note for its log when that was done; a toolkit whose output cannot
  /// take it keeps the unlock's resolution.
  Future<String?> _setLaunchResolution(Game game, String folder) async {
    final kit = toolkitFor(game);
    final patch = kit?.patchFile(game.titleId);
    if (kit == null || patch == null) return null;
    try {
      final text = File(patch).readAsStringSync();
      final title = ResolutionPatch.defaultOf(text);
      if (!ResolutionPatch.supports(text) || title == null) return null;
      final unlocked = records[game.id]?.resolution ?? title;
      final wanted = powerWatch.adjustment.lowerResolution ? (_unlockResolution(game, kit) ?? unlocked) : unlocked;
      final result = await LaunchResolution.apply(
        executable: p.join(Installer.installedFolder(game, folder), system.executableName),
        patch: text,
        wanted: wanted,
        known: {title, unlocked, wanted, ...ResolutionPatch.choices},
      );
      return result == LaunchResolutionResult.written ? '[anyps5-launcher] resolution for this start: $wanted' : null;
    } on Object {
      return null;
    }
  }

  /// Whether the title's patch file lets Game Settings choose its resolution.
  bool supportsResolution(Game game) => _factsOf(game).resolution;

  ({bool resolution, List<String> backups}) _factsOf(Game game) => _gameFacts.putIfAbsent(game.id, () {
    final patch = toolkitFor(game)?.patchFile(game.titleId);
    var resolution = false;
    try {
      resolution = patch != null && ResolutionPatch.supports(File(patch).readAsStringSync());
    } on FileSystemException {
      resolution = false;
    }
    return (resolution: resolution, backups: SaveBackup.backups(backupFolder(game)));
  });

  /// The log shown in the log layer, read as it opens.
  String shownLog = '';

  /// Reads the toolkit and the games' facts again (after the engine was built in place).
  void reloadDiskFacts() {
    _forgetDiskFacts();
    notifyListeners();
  }

  /// Reads the disk again for what the screen keeps (the toolkit, a game's facts).
  void _forgetDiskFacts() {
    _toolkitEpoch++;
    _gameFacts.clear();
  }

  /// The first games folder.
  String? get root => preferences.gamesFolders.firstOrNull;

  /// The games folder [game] was found in: its store (.AnyPS5) holds the game unlocked, so the
  /// game's files are linked on their own drive, never copied to another, and a game and its
  /// unlock come and go together with their drive.
  String? rootOf(Game game) => _gameRoots[game.id] ?? root;

  Map<String, String> _gameRoots = {};

  /// What the last scan found in each games folder: its games, null while it is not there.
  Map<String, int?> folderCounts = {};

  void _changed() {
    if (launcherProblem != null) offerLauncherReport();
    notifyListeners();
    _publishLibrary();
    _publishActivity();
    _prepareWhenChanged();
  }

  void savePreferences() {
    if (persist) preferences.save(paths.preferencesFile);
    _applyPadPreferences();
    _changed();
  }

  // Library.

  /// Scans every games folder, reads the installed records and the sizes.
  void rescan() {
    final folders = preferences.gamesFolders;
    if (folders.isEmpty) {
      games = [];
      folderCounts = {};
      _changed();
      return;
    }
    final key = folders.join('\n');
    if (key != _scannedFolders) {
      // Other games folders: what their first scan finds is not new.
      _tracker.reset();
      _connected.clear();
      _scannedFolders = key;
    }
    final survey = GameLibrary.surveyAll(folders, includeRetro: preferences.retroLibrary);
    folderCounts = survey.folders;
    _gameRoots = survey.roots;
    _takeScan(survey.games, quiet: _newlyConnected());
    files.scanned(folders);
  }

  /// The games folders seen connected since the list last changed.
  final Set<String> _connected = {};

  /// The folders connected in the last scan that were not before (a drive plugged in that was not
  /// when the launcher started): what they hold is the library coming back, not new games.
  Set<String> _newlyConnected() {
    final fresh = {
      for (final entry in folderCounts.entries)
        if (entry.value != null && !_connected.contains(entry.key)) entry.key,
    };
    _connected.addAll(fresh);
    return fresh;
  }

  /// A watcher's scans (of [folder], one of the games folders): nothing is read again when the
  /// library is the same. Gives the dumps still being copied in [folder].
  List<String> _watchedScan(String folder) {
    final folders = preferences.gamesFolders;
    if (_disposed || !folders.contains(folder)) return const [];
    final survey = GameLibrary.surveyAll(folders, includeRetro: preferences.retroLibrary);
    final key = folders.join('\n');
    final counted = !mapEquals(folderCounts, survey.folders);
    folderCounts = survey.folders;
    if (key != _scannedFolders || !GameLibrary.sameListing(games, deletion.visible(survey.games))) {
      if (key != _scannedFolders) {
        _tracker.reset();
        _connected.clear();
        _scannedFolders = key;
      }
      _gameRoots = survey.roots;
      _takeScan(survey.games, quiet: _newlyConnected());
    } else if (counted) {
      _newlyConnected();
      notifyListeners();
    }
    // A zip dropped in (or one copied in further) is looked into.
    files.scanned(folders);
    return [
      for (final path in survey.incomplete)
        if (p.equals(path, folder) || p.isWithin(folder, path)) path,
    ];
  }

  /// A scan's games: the records and trophies read again, the selection kept on the game it
  /// was on, and the games not seen before announced (but those in the [quiet] folders). An
  /// unlock going on is left as it is: its record is written only when it is done.
  void _takeScan(List<Game> found, {Set<String> quiet = const {}}) {
    final previous = selectedGame?.id;
    final focusedInLibrary = libraryIndex >= 0 && libraryIndex < games.length ? games[libraryIndex].id : null;
    _forgetDiskFacts();
    // A game being deleted stays out of the library until its files are gone or came back.
    games = deletion.visible(found);
    records.clear();
    trophies.clear();
    for (final game in games) {
      if (game.retro != null) continue;
      final installed = Installer.installedFolder(game, rootOf(game)!);
      // Being uninstalled: not installed, whatever is left of it on the disk.
      final record = _removals.containsKey(game.id) ? null : Installer.record(installed, system: system);
      if (record != null) records[game.id] = record;
      _loadTrophies(game);
    }
    final index = games.indexWhere((game) => game.id == previous);
    selected = index >= 0 ? index : selected.clamp(0, games.isEmpty ? 0 : games.length - 1);
    final libraryAt = games.indexWhere((game) => game.id == focusedInLibrary);
    libraryIndex = libraryAt >= 0 ? libraryAt : libraryIndex.clamp(0, games.isEmpty ? 0 : games.length - 1);
    final added = [
      for (final game in _tracker.update(found))
        if (!quiet.any((folder) => p.isWithin(folder, game.folder))) game,
    ];
    if (added.isNotEmpty) _announceNewGames(added);
    _changed();
  }

  /// "New game: [name]" (or "3 new games") with the select sound; the game is selected when the
  /// home screen shows, and the desktop says it too while the launcher is behind other windows.
  void _announceNewGames(List<Game> added) {
    if (!preferences.onboarded) return;
    final name = added.first.nameFor([T.language.code]);
    final prepared = _prepareNewGames(added);
    final text = newGameText(
      added.length == 1 ? [name] : [for (final game in added) game.name],
      preparing: prepared.preparing,
      waiting: prepared.waiting,
      skipped: prepared.skipped,
    );
    if (overlay == null && running == null && starting == null) {
      final index = games.indexOf(added.first);
      if (index >= 0) {
        selected = index;
        focus = HomeFocus.tiles;
        measureSelected();
      }
    }
    show(text, icon: added.length == 1 ? added.first.icon : null);
    sounds.play(Cue.select);
    if (!active) {
      final names = added.take(3).map((game) => game.nameFor([T.language.code])).join(', ');
      desktopNotify(text, added.length == 1 ? T.text('newGameDetail') : (added.length > 3 ? '$names…' : names));
    }
  }

  void _loadTrophies(Game game) {
    final folder = rootOf(game);
    if (folder == null) return;
    final installed = Installer.installedFolder(game, folder);
    final language = ConsoleLanguage.tag(T.language.consoleLanguage);
    final set = Trophies.load(game, installed: installed, languages: [?language]);
    if (set == null) {
      trophies.remove(game.id);
    } else {
      trophies[game.id] = set;
      together.recordTrophies(game, set);
    }
  }

  /// A watcher for each games folder, by folder.
  final Map<String, LibraryWatcher> _libraries = {};
  final LibraryTracker _tracker = LibraryTracker();
  String? _scannedFolders;

  /// Watches every games folder and everything in it (library_watch.dart): a dump copied in, in a
  /// subfolder too, shows up on its own a moment after its copy is far enough along, and one
  /// removed goes. A folder that is not there (its drive unplugged) is looked for until it is
  /// back, and its games come with it. An unlock going on does not hold the scans back.
  void watchGamesFolders() {
    final folders = preferences.gamesFolders;
    for (final gone in _libraries.keys.where((folder) => !folders.contains(folder)).toList()) {
      _libraries.remove(gone)?.stop();
    }
    for (final folder in folders) {
      _libraries[folder] ??= LibraryWatcher(folder, onScan: () => _watchedScan(folder))..start();
    }
  }

  /// The size of the selected game, measured once.
  /// The selected game's size, read away from the interface: walking a dump's tens of thousands
  /// of files here stalled the launcher for seconds at each game a held direction passed. One
  /// walk at a time; when it ends, the game the selection rests on by then is the next.
  void measureSelected() {
    final game = selectedGame;
    if (game == null || sizes.containsKey(game.id) || _measuring) return;
    _measuring = true;
    unawaited(
      _measure(
        game,
        services.folderSize,
      ).then((bytes) => sizes[game.id] = bytes, onError: (Object _) => sizes[game.id] = 0).whenComplete(() {
        _measuring = false;
        if (_disposed) return;
        notifyListeners();
        measureSelected();
      }),
    );
  }

  bool _measuring = false;

  /// What [game] takes on the disk: its folder, or its own files when it shares the folder
  /// ([Game.files]). Static, so the closure sent to the other isolate holds only the paths.
  static Future<int> _measure(Game game, Future<int> Function(String path)? measure) {
    final files = game.files;
    if (files == null) {
      final folder = game.folder;
      return measure != null ? measure(folder) : Isolate.run(() => GameLibrary.size(folder));
    }
    if (measure == null) return Isolate.run(() => GameLibrary.filesSize(files));
    return _measureEach(files, measure);
  }

  /// [files] measured one after the other with [measure].
  static Future<int> _measureEach(List<String> files, Future<int> Function(String path) measure) async {
    var total = 0;
    for (final file in files) {
      total += await measure(file);
    }
    return total;
  }

  /// A game's own controls read on another isolate. Static, so the closure sent there holds
  /// only the folder and not the model.
  static Future<Map<PadAction, List<String>>?> _readGameControls(String folder) =>
      Isolate.run(() => UnrealControls.read(folder));

  /// Reads what the game's own files say each pad button does, once per game.
  void _readControls(Game game) {
    if (gameControls.containsKey(game.id)) return;
    gameControls[game.id] = const {};
    final read = services.gameControls ?? _readGameControls;
    unawaited(
      read(game.folder).then((controls) {
        if (_disposed || controls == null || controls.isEmpty) return;
        gameControls[game.id] = controls;
        notifyListeners();
      }, onError: (Object _) {}),
    );
  }

  GameState stateOf(Game game) {
    if (running case (final Game playing, final RunningGame run) when playing.id == game.id) {
      return stopping ? Stopping(run.pid) : Running(run.pid);
    }
    if (starting?.id == game.id) return const Starting();
    if (together.family.ageLock(game) case final FamilyLocked lock) return lock;
    if (game.retro case final RetroDisc disc) {
      return standaloneEmulator(disc.platform) == null ? const NeedsEmulator() : const Installed();
    }
    final installed = records.containsKey(game.id);
    final current = progress[game.id];
    if (current != null) {
      return Installing(
        current.$1,
        current.$2,
        preparing: isPreparing(game),
        paused: isPreparing(game) && prepare.paused,
        updating: installed,
        playsAfter: _playAfterInstall == game.id,
      );
    }
    final job = engine.git.job;
    if (queue.contains(game.id)) return Queued(updating: installed, waitingForEngine: job != null && !job.checking);
    final failure = failures[game.id];
    if (failure != null) return Failed(failure);
    final record = records[game.id];
    // The engine is checked for this game's Play, or built in place: no game starts on a build
    // half done.
    if (job != null && record != null && (job.forGame == game.id || !job.checking)) {
      return WaitingForEngine(job, forThisGame: job.forGame == game.id);
    }
    // An update dumped (or removed) since the unlock needs its executable relinked: unlocking
    // again applies it.
    if (record != null && record.update == game.update?.version) {
      // A game with an engine of its own follows that one, whatever the default is.
      if (currentSettings(game).engine != null) {
        final own = toolkitFor(game)?.version;
        return Installed(outdated: own != null && own != record.toolkit);
      }
      final version = toolkitVersion;
      return Installed(outdated: (version != null && version != record.toolkit) || engine.updateAvailable);
    }
    if (game.executable == ExecutableKind.unreadable) return const Unreadable();
    return Locked(waitingToPrepare: prepare.pending.contains(game.id));
  }

  /// An unlock runs now (asked for, or a new game prepared in the background).
  bool get unlocking => _installer != null || _preparer != null;

  GameSettings settingsFor(Game game) => settingsStore.load(game.slug);

  /// The engine that unlocks [game]: the one chosen for it in its Game Settings (null while that
  /// one is not on this computer: [missingEngine]), else the default [toolkit].
  Toolkit? toolkitFor(Game game) {
    final pin = currentSettings(game).engine;
    if (pin == null) return toolkit;
    return engine.downloaded.where((kit) => p.basename(kit.root) == pin).firstOrNull;
  }

  /// The version of the engine [game] is unlocked with now: its own when it has one, else the
  /// default's.
  String? engineVersionFor(Game game) =>
      currentSettings(game).engine != null ? toolkitFor(game)?.version : toolkitVersion;

  /// Whether [game]'s copy was made by another engine than the one it is unlocked with now (the
  /// engine was updated or changed since). A newer engine to download is not this: that one is
  /// offered ([Layer.updateChoice]).
  bool needsRebuild(Game game) =>
      stateOf(game) is Installed &&
      StaleCopy.needsRebuild(built: records[game.id]?.toolkit, current: engineVersionFor(game));

  /// A copy made by another engine than the one it starts with now is rebuilt first, with the
  /// unlock's usual progress, and [then] runs once it is ready; a copy that is current goes on at
  /// once. Nothing goes on after a rebuild that failed or was cancelled.
  void rebuildFirst(Game game, void Function() then) {
    if (!needsRebuild(game)) return then();
    afterRebuild = (game.id, then);
    show(T.format('gameRebuildingFirst', [game.name]));
    unlock(game);
    // The unlock did not begin (no engine at hand): nothing waits on it. A question about
    // copying the game's files asked first keeps it.
    if (afterRebuild?.$1 == game.id &&
        !queue.contains(game.id) &&
        !progress.containsKey(game.id) &&
        copyWarning?.game.id != game.id) {
      afterRebuild = null;
    }
  }

  /// An unlock ended: what waited on the copy's rebuild goes on, or is dropped when it failed.
  void _rebuildDone(String id, bool succeeded) {
    final waiting = afterRebuild;
    if (waiting == null || waiting.$1 != id) return;
    afterRebuild = null;
    if (succeeded) waiting.$2();
  }

  /// The engine [game] is pinned to when that one is not on this computer, null otherwise.
  String? missingEngine(Game game) {
    final pin = currentSettings(game).engine;
    return pin != null && !engine.downloaded.any((kit) => p.basename(kit.root) == pin) ? pin : null;
  }

  /// A game pinned to an engine that is not downloaded: says so, and the game's settings offer
  /// the download (Game Settings › Engine).
  void _tellEngineMissing(Game game, String pin) {
    show(T.format('engineGameMissing', [EngineModel.nameOf(pin)]));
    if (selectedGame == game && overlay == null) open(Layer.gameSettings);
  }

  void saveSettings(Game game, GameSettings settings) {
    if (persist) settingsStore.save(game.slug, settings);
    _cachedSettings[game.slug] = settings;
    // A game's own engine brings its own patch file.
    _gameFacts.remove(game.id);
    _changed();
  }

  final Map<String, GameSettings> _cachedSettings = {};

  GameSettings currentSettings(Game game) => _cachedSettings.putIfAbsent(game.slug, () => settingsFor(game));

  /// The settings [game] starts with: its own, and Settings › Default Display for the display
  /// choices it left at Default.
  GameSettings launchSettings(Game game) => currentSettings(game).withDefaults(preferences.displayDefaults);

  /// Onboarding: the first games folder, picked (or picked again: it changes).
  Future<void> chooseGamesFolder() async {
    final folder = await services.pickFolder?.call(T.text('chooseFolder'));
    if (folder == null) return;
    final others = preferences.gamesFolders.skip(1).where((known) => !p.equals(known, folder));
    _setGamesFolders([folder, ...others]);
  }

  /// Settings › Game Library › Add Folder and Select on the empty shelf: another games folder,
  /// after the others (one already in the list is said, not added again).
  Future<void> addGamesFolder() async {
    final folder = await services.pickFolder?.call(T.text('chooseFolder'));
    if (folder == null) return;
    if (preferences.gamesFolders.any((known) => p.equals(known, folder))) {
      show(T.text('folderAlreadyAdded'));
      return;
    }
    _setGamesFolders([...preferences.gamesFolders, folder]);
  }

  /// The copy warning's folder fixes: the picked folder becomes the first (the one unlocked games
  /// go to), the others stay in the library after it.
  Future<void> chooseFirstGamesFolder() async {
    final folder = await services.pickFolder?.call(T.text('chooseFolder'));
    if (folder == null) return;
    _setGamesFolders([folder, ...preferences.gamesFolders.where((known) => !p.equals(known, folder))]);
  }

  /// Settings › Game Library: [folder] out of the library; nothing on its drive is touched. With
  /// the last one gone the library is empty.
  void removeGamesFolder(String folder) {
    _setGamesFolders([...preferences.gamesFolders.where((known) => known != folder)]);
    show(T.text('folderRemoved'));
  }

  void _setGamesFolders(List<String> folders) {
    preferences.gamesFolders = folders;
    savePreferences();
    rescan();
    watchGamesFolders();
  }

  /// Settings › Game Library: a row for each games folder, its path and how many games it holds (or
  /// that its drive is not connected); choosing it takes the folder out of the library.
  List<PanelRow> folderRows() {
    final folders = preferences.gamesFolders;
    return [
      for (final (index, folder) in folders.indexed)
        PanelRow(
          id: 'folder-$index',
          title: folder,
          detail: [
            switch (folderCounts[folder]) {
              null => T.text('folderNotConnected'),
              1 => T.text('folderOneGame'),
              final int count => T.format('folderGames', [count]),
            },
            T.text('folderRemove'),
          ].join(' · '),
          kind: ActionRow(() => removeGamesFolder(folder), destructive: true),
        ),
    ];
  }

  Future<void> chooseToolkit() async {
    final folder = await services.pickFolder?.call(T.text('toolkitChoose'));
    if (folder == null) return;
    useOwnFolder(folder);
  }

  /// Settings › AnyPS5 Engine › Use My Own Folder: [folder] as it is, and what that means for the
  /// games unlocked with another engine.
  void useOwnFolder(String folder) {
    preferences.toolkitFolder = folder;
    savePreferences();
    if (!preferences.onboarded) return;
    show(engine.withGames(T.text(engine.git.checkout != null ? 'engineOwnCheckoutChosen' : 'engineOwnChosen')));
  }

  // Installing.

  void primaryAction(Game game) {
    switch (stateOf(game)) {
      case NeedsEmulator():
        unawaited(chooseStandaloneEmulator(game.retro!.platform));
      case Installed() when game.retro != null:
        unawaited(play(game));
      case Installed(:final outdated):
        // A copy made by another engine than the one at hand is rebuilt on the way (play); a
        // newer engine to download is offered; a game someone the user knows already plays asks
        // first whether to join theirs.
        void go() => outdated && !needsRebuild(game) ? open(Layer.updateChoice) : together.playOrJoin(game);
        // Settings › AnyPS5 Engine › Update from Git Before Playing: the checkout's remote first.
        engine.git.updatesBeforePlay ? unawaited(engine.git.beforePlay(game, go)) : go();
      case WaitingForEngine(:final forThisGame):
        // The engine is being built in place: its relinker and libraries are not whole yet.
        show(forThisGame ? T.format('gameStartsAfterEngine', [game.name]) : T.text('gameWaitsForEngine'));
      // The rebuild of a copy that is still there failed: try again, or play it as it is.
      case Failed() when records[game.id] != null:
        open(Layer.updateChoice);
      case Locked() || Failed():
        unlock(game);
      case Installing(preparing: true):
        _promotePreparation(game);
      // An update (or one the game starts after) is not given up by a second press on its button:
      // Game Settings › Cancel Update does it.
      case Installing(updating: true) || Queued(updating: true):
        show(T.format('gameUpdatingHint', [game.name]));
      case Installing(playsAfter: true):
        show(T.format('gameUnlockingHint', [game.name]));
      case Installing() || Queued():
        cancelUnlock(game);
      case Unreadable():
        show(T.text('unreadableDump'));
      // The game back in front, as on the Mac; Stop is in the game's menu and the quick menu.
      case Running():
        if (running?.$2 case final RunningGame run) unawaited(_showGame(run));
      case Starting() || Stopping():
        break;
      case FamilyLocked():
        unawaited(together.family.askToPlay(game));
    }
  }

  /// The game an unlock waits for an answer about, the size of its files that would be copied,
  /// and the room it lacks on the games folder's drive (see [Layer.copyWarning]); [free] is what
  /// the drive has, null when it does not say.
  ({Game game, int bytes, SpaceShortage? shortage, int? needed, int? free})? copyWarning;

  /// The free bytes where a folder is (FreeSpace.of); replaceable in tests.
  int? Function(String folder) freeSpace = FreeSpace.of;

  /// The power now (Power.current); replaceable in tests.
  PowerState Function() power = Power.current;

  /// Copies smaller than this go ahead without asking (homebrew, demos).
  static const copyWarningFrom = 100000000;

  /// Queues [game]'s unlock; when its files would be copied (the games folder cannot link to the
  /// dump) and [copy] does not say so already, asks first.
  void unlock(Game game, {bool copy = false}) {
    if (game.retro != null) return;
    final folder = rootOf(game);
    if (folder == null) return;
    final kit = toolkitFor(game);
    if (kit == null) {
      if (missingEngine(game) case final String pin) return _tellEngineMissing(game, pin);
      return show(T.text('noToolkit'));
    }
    // Asked for while it is being prepared: it becomes the user's own.
    if (prepare.active == game.id) return _promotePreparation(game);
    prepare.cancel(game.id);
    final waiting = queue.contains(game.id) || progress.containsKey(game.id);
    if (!waiting) {
      InstallPlan? plan;
      try {
        plan = Installer.plan(
          game,
          folder,
          knownSize: sizes[game.id],
          toolkit: kit,
          resolution: _unlockResolution(game, kit),
          relinkerFlags: currentSettings(game).chosenRelinkerFlags,
          customRelinkerOptions: currentSettings(game).customRelinkerWords,
        );
      } on FileSystemException {
        plan = null; // The install says what is wrong.
      }
      // The room first: a drive that is short says so before anything is written, copy or not.
      final free = plan == null ? null : freeSpace(folder);
      final shortage = plan?.space?.shortage(free: free, folder: folder);
      if (plan != null && (shortage != null || (!copy && plan.copies && plan.bytes >= copyWarningFrom))) {
        if (shortage != null && _playAfterInstall == game.id) _playAfterInstall = null;
        if (shortage != null && afterRebuild?.$1 == game.id) afterRebuild = null;
        copyWarning = (game: game, bytes: plan.bytes, shortage: shortage, needed: plan.space?.needed, free: free);
        open(Layer.copyWarning, cue: shortage == null ? Cue.select : Cue.back);
        return;
      }
    }
    // Unlocked all the same (another glibc may be at hand), but said first.
    if (engine.glibcWarning(kit) case final String warning) show(warning);
    failures.remove(game.id);
    if (!queue.contains(game.id) && !progress.containsKey(game.id)) {
      queue.add(game.id);
      sounds.play(Cue.select);
    }
    _changed();
    _startNext();
    _stepPrepare();
  }

  /// Unlocks the game again and plays it; with a newer engine out, downloads that first.
  void updateAndPlay(Game game) {
    _playAfterInstall = game.id;
    // A game with its own engine is unlocked with that one: the default's update is not its.
    if (currentSettings(game).engine == null && engine.updateAvailable) {
      unawaited(
        engine.download().then((done) {
          if (done) {
            unlock(game);
          } else if (_playAfterInstall == game.id) {
            _playAfterInstall = null;
          }
        }),
      );
      return;
    }
    unlock(game);
  }

  void cancelUnlock(Game game) {
    if (_playAfterInstall == game.id) _playAfterInstall = null;
    if (afterRebuild?.$1 == game.id) afterRebuild = null;
    if (prepare.contains(game.id)) {
      if (prepare.cancel(game.id)) _preparer?.cancel();
      sounds.play(Cue.back);
      return _changed();
    }
    if (queue.remove(game.id)) {
      _changed();
      _stepPrepare();
      return;
    }
    if (progress.containsKey(game.id)) _installer?.cancel();
    sounds.play(Cue.back);
  }

  void _startNext() {
    // While the engine is built in place the unlocks wait for it (engineJobEnded goes on).
    if (engine.git.running) return;
    if (_installer != null || queue.isEmpty || root == null) return;
    final next = games.where((game) => game.id == queue.first).firstOrNull;
    final kit = next == null ? toolkit : toolkitFor(next);
    if (next != null && kit == null && missingEngine(next) == null) return; // No engine yet: it waits.
    final id = queue.removeAt(0);
    final game = next;
    if (game == null) return _startNext();
    // Its engine was deleted while it waited: said, and the next game goes on.
    if (kit == null) {
      if (_playAfterInstall == id) _playAfterInstall = null;
      if (afterRebuild?.$1 == id) afterRebuild = null;
      _tellEngineMissing(game, missingEngine(game)!);
      return _startNext();
    }
    final folder = rootOf(game)!;
    _installer = _runUnlock(
      game,
      kit,
      folder,
      background: false,
      done: (error) {
        _installer = null;
        switch (error) {
          case null:
            sounds.play(Cue.unlocked);
            show('${game.name} · ${T.text('ready')}');
            if (_playAfterInstall == id) {
              _playAfterInstall = null;
              unawaited(play(game));
            }
            onUnlocked?.call(id, true);
            _rebuildDone(id, true);
          case InstallCancelled():
            onUnlocked?.call(id, false);
            _rebuildDone(id, false);
          case final SpaceShortage shortage:
            _tellShortage(game, shortage);
          default:
            failures[id] = error.toString();
            onUnlocked?.call(id, false);
            _rebuildDone(id, false);
            show('${T.text('unlockFailed')}: ${game.name}');
        }
      },
    );
    _changed();
  }

  /// Starts unlocking [game]: its progress and its log. [done] runs after the log and the record
  /// are written, with the error when it failed (null when it worked); the queues go on after it.
  Installer _runUnlock(
    Game game,
    Toolkit kit,
    String folder, {
    required bool background,
    required void Function(Object? error) done,
  }) {
    final id = game.id;
    progress[id] = (InstallStep.unwrap, 0);
    final unlockLines = <String>[];
    final unlockLog = GameLog.unlockFile(paths.logs, game.titleId);
    final installer = Installer(
      game: game,
      toolkit: kit,
      root: folder,
      resolution: _unlockResolution(game, kit),
      relinkerFlags: currentSettings(game).chosenRelinkerFlags,
      customRelinkerOptions: currentSettings(game).customRelinkerWords,
      freeSpace: freeSpace,
      onProgress: (step, fraction) {
        progress[id] = (step, fraction);
        notifyListeners();
        _publishActivity();
      },
      onLog: (line) {
        unlockLines.add(line);
        _appendLog(game, line);
      },
    )..background = background;
    unawaited(() async {
      Object? failure;
      try {
        // Uninstalled a moment ago: its old files go first (one that could not be renamed aside
        // is still being removed where the new one goes).
        await _removals[id];
        final installed = await installer.run();
        GameLog.writeUnlockLog(unlockLog, unlockLines);
        final record = Installer.record(installed, system: system);
        if (record != null) records[id] = record;
      } on InstallCancelled catch (error) {
        failure = error;
      } on SpaceShortage catch (error) {
        failure = error;
      } on Object catch (error) {
        GameLog.writeUnlockLog(unlockLog, unlockLines, failure: error.toString());
        failure = error;
      }
      progress.remove(id);
      if (_disposed) return;
      done(failure);
      if (failure == null && installer.leftOut.isNotEmpty) show(leftOutText(game, installer.leftOut), icon: game.icon);
      _changed();
      _publishActivity();
      _startNext();
      _stepPrepare();
    }());
    return installer;
  }

  /// What an unlock that left modules of the dump out says once the game is ready: one short
  /// sentence, encrypted files first since dumping again fixes those. The files themselves are in
  /// the unlock's log; a list of them here was too long to read before the notice went.
  static String leftOutText(Game game, List<LeftOutModule> leftOut) {
    final encrypted = leftOut.any((module) => module.reason == LeftOutReason.encrypted);
    return T.format(encrypted ? 'unlockLeftOutEncrypted' : 'unlockLeftOutNotRelinked', [game.name]);
  }

  /// The whole error of [game]'s failed unlock to the clipboard: the message, then the unlock's
  /// log with all the relinker printed.
  void copyFailure(Game game) {
    final failure = failures[game.id];
    if (failure == null) return;
    final log = GameLog.read(GameLog.unlockFile(paths.logs, game.titleId))?.trimRight();
    services.copyText?.call([failure, if (log != null && log.isNotEmpty && log != failure) log].join('\n\n'));
    show(T.text('unlockErrorCopied'));
  }

  /// The unlock of [game] did not start for want of room: the copy panel says how much is needed
  /// and free, and what to do.
  void _tellShortage(Game game, SpaceShortage shortage) {
    if (_playAfterInstall == game.id) _playAfterInstall = null;
    if (afterRebuild?.$1 == game.id) afterRebuild = null;
    copyWarning = (game: game, bytes: 0, shortage: shortage, needed: shortage.needed, free: shortage.free);
    open(Layer.copyWarning, cue: Cue.back);
  }

  // Preparing new games.

  /// New games prepared in the background (PrepareQueue) and the unlock doing it.
  final PrepareQueue prepare = PrepareQueue();
  Installer? _preparer;
  Timer? _prepareTimer;
  (bool, bool, bool)? _prepareSignature;

  /// The game being prepared in the background, not yet asked for by the user.
  bool isPreparing(Game game) => prepare.active == game.id && !prepare.promoted;

  PrepareConditions get _prepareConditions => PrepareConditions(
    enabled: preferences.prepareNewGames && preferences.onboarded,
    playing: running != null || starting != null,
    // The engine built in place holds the background unlocks back as the user's own do.
    unlocking: _installer != null || queue.isNotEmpty || engine.git.running,
    power: power(),
  );

  /// The engine's build (Update from Git) ended: the unlocks waiting for it go on.
  void engineJobEnded() {
    _startNext();
    _stepPrepare();
    _changed();
  }

  /// After any change: when a game started or ended, an unlock began or finished, or the setting
  /// changed, the queue takes its steps (soon, not in the middle of the change).
  void _prepareWhenChanged() {
    if (prepare.active == null && prepare.pending.isEmpty) {
      _prepareSignature = null;
      return;
    }
    final signature = (
      preferences.prepareNewGames,
      running != null || starting != null,
      _installer != null || queue.isNotEmpty,
    );
    if (signature == _prepareSignature) return;
    _prepareSignature = signature;
    scheduleMicrotask(() {
      if (!_disposed) _stepPrepare();
    });
  }

  /// Takes the queue's steps until it has nothing more to do now; the skips are told unless
  /// [quiet] (the caller tells them), and returned.
  List<(String, PrepareSkip)> _stepPrepare({bool quiet = false}) {
    final kit = toolkit;
    final skipped = <(String, PrepareSkip)>[];
    if (root == null || kit == null || _disposed) return skipped;
    final conditions = _prepareConditions;
    while (true) {
      final action = prepare.step(
        conditions,
        shortage: (id) {
          final game = games.where((game) => game.id == id).firstOrNull;
          final folder = game == null ? null : rootOf(game);
          if (game == null || folder == null) return null;
          try {
            final plan = Installer.plan(
              game,
              folder,
              knownSize: sizes[game.id],
              toolkit: toolkitFor(game) ?? kit,
              resolution: _unlockResolution(game, toolkitFor(game) ?? kit),
              relinkerFlags: currentSettings(game).chosenRelinkerFlags,
              customRelinkerOptions: currentSettings(game).customRelinkerWords,
            );
            return plan.space?.shortage(free: freeSpace(folder), folder: folder);
          } on FileSystemException {
            return null;
          }
        },
      );
      switch (action) {
        case PrepareNone():
          _schedulePrepareCheck();
          if (!quiet) {
            for (final (id, reason) in skipped) {
              _tellSkipped(id, reason);
            }
          }
          _prepareSignature = (
            preferences.prepareNewGames,
            running != null || starting != null,
            _installer != null || queue.isNotEmpty,
          );
          return skipped;
        case PrepareStart(:final id):
          _startPreparing(id, kit);
        case PreparePause():
          _preparer?.pause();
          notifyListeners();
        case PrepareResume():
          _preparer?.resume();
          notifyListeners();
        case PrepareSkipped(:final id, :final reason):
          skipped.add((id, reason));
      }
    }
  }

  /// While games wait or one is being prepared, the power is looked at again now and then.
  void _schedulePrepareCheck() {
    final waiting = prepare.pending.isNotEmpty || prepare.active != null;
    if (!waiting) {
      _prepareTimer?.cancel();
      _prepareTimer = null;
      return;
    }
    _prepareTimer ??= Timer.periodic(const Duration(seconds: 30), (_) => _stepPrepare());
  }

  void _startPreparing(String id, Toolkit kit) {
    final game = games.where((game) => game.id == id).firstOrNull;
    if (game == null || stateOf(game) is! Locked) {
      prepare.finished(id);
      return;
    }
    _preparer = _runUnlock(
      game,
      kit,
      rootOf(game)!,
      background: true,
      done: (error) {
        final promoted = prepare.promoted;
        _preparer = null;
        prepare.finished(id);
        switch (error) {
          case null:
            sounds.play(Cue.unlocked);
            final text = T.format('readyToPlay', [game.name]);
            show(text, icon: game.icon);
            if (!active && running == null && starting == null) desktopNotify(text, T.text('readyToPlayDetail'));
            if (promoted && _playAfterInstall == id) {
              _playAfterInstall = null;
              unawaited(play(game));
            }
          case InstallCancelled():
            if (_playAfterInstall == id) _playAfterInstall = null;
          case final SpaceShortage shortage:
            // The room went while it waited.
            promoted ? _tellShortage(game, shortage) : _tellSkipped(id, SpaceShort(shortage));
          default:
            if (_playAfterInstall == id) _playAfterInstall = null;
            failures[id] = error.toString();
            show('${T.text('unlockFailed')}: ${game.name}');
        }
      },
    );
    notifyListeners();
  }

  /// Play on a game being prepared: it no longer waits for the user's other unlocks, runs at
  /// normal priority where the system lets it, and starts when it is ready.
  void _promotePreparation(Game game) {
    prepare.promote(game.id);
    _preparer?.background = false;
    _playAfterInstall = game.id;
    sounds.play(Cue.select);
    show(T.format('startsWhenReady', [game.name]), icon: game.icon);
    _stepPrepare();
    _changed();
  }

  void _tellSkipped(String id, PrepareSkip reason) {
    final game = games.where((game) => game.id == id).firstOrNull;
    if (game == null) return;
    switch (reason) {
      case BatteryLow():
        show(T.format('notPreparedBattery', [game.name]), icon: game.icon);
      case SpaceShort(:final shortage):
        show(
          T.format('notPreparedSpace', [game.name, byteText(shortage.needed), byteText(shortage.free)]),
          icon: game.icon,
        );
    }
  }

  /// New games from a scan: the locked ones go to the background queue, and what happens to the
  /// first is returned for the "New game" notice.
  ({bool preparing, bool waiting, PrepareSkip? skipped}) _prepareNewGames(List<Game> added) {
    const nothing = (preparing: false, waiting: false, skipped: null);
    if (!preferences.prepareNewGames || toolkit == null) return nothing;
    final locked = added.where((game) => stateOf(game) is Locked).toList();
    if (locked.isEmpty) return nothing;
    prepare.add(locked.map((game) => game.id));
    final skips = _stepPrepare(quiet: true);
    final first = locked.first.id;
    for (final (id, reason) in skips) {
      if (id == first) return (preparing: false, waiting: false, skipped: reason);
    }
    return (preparing: prepare.active == first, waiting: prepare.pending.contains(first), skipped: null);
  }

  /// "New game: [name]", with what happens to it when it is prepared in the background.
  static String newGameText(List<String> names, {bool preparing = false, bool waiting = false, PrepareSkip? skipped}) {
    final one = names.length == 1;
    switch (skipped) {
      case BatteryLow():
        return T.format('newGameNotPreparedBattery', [names.first]);
      case SpaceShort():
        return T.format('newGameNotPreparedSpace', [names.first]);
      case null:
        break;
    }
    if (preparing) {
      return one ? T.format('newGamePreparing', [names.first]) : T.format('newGamesPreparing', [names.length]);
    }
    if (waiting) {
      return one ? T.format('newGameWaiting', [names.first]) : T.format('newGamesWaiting', [names.length]);
    }
    return one ? T.format('newGame', [names.first]) : T.format('newGames', [names.length]);
  }

  /// The games whose files are being removed (Uninstall), by id, until they are gone.
  final Map<String, Future<void>> _removals = {};

  /// Uninstalls [game] at once: its folders are renamed aside and go after, off the screen's
  /// thread, so the launcher keeps answering while a big game goes. A second Uninstall meanwhile
  /// does nothing, and an unlock of the game waits until its old files are gone. Completes then.
  /// The saves and trophies in it are kept in the store first and come back with the next unlock
  /// (Installer.keepSaves); when they cannot be moved the installation stays as it is and the
  /// notice says so. Delete game uninstalls too, from the games folder it knew ([root]) and
  /// without the notices ([quiet]): it has its own.
  Future<void> uninstall(Game game, {String? root, bool quiet = false}) async {
    final folder = root ?? rootOf(game);
    if (folder == null || _removals.containsKey(game.id)) return;
    final Future<void> gone;
    try {
      gone = Installer.uninstall(game, folder);
    } on FileSystemException catch (error) {
      // Nothing of the player's is lost: the installation stays where it is.
      if (!quiet) show(T.format('uninstallFailed', [error.osError?.message ?? error.message]));
      return;
    }
    _removals[game.id] = gone;
    records.remove(game.id);
    if (!quiet) show(T.text('uninstallDone'));
    _changed();
    try {
      await gone;
    } finally {
      _removals.removeWhere((id, _) => id == game.id);
    }
  }

  void clearShaderCache(Game game) {
    final cache = Directory(p.dirname(paths.shaderCache(game.slug)));
    if (cache.existsSync()) cache.deleteSync(recursive: true);
    show(T.text('cacheCleared'));
  }

  String backupFolder(Game game) => SaveBackup.folderFor(paths.backupsFolder, game.name, game.titleId);

  String? _lastBackupText(Game game) {
    final latest = _factsOf(game).backups.firstOrNull;
    if (latest == null) return null;
    return T.format('lastBackup', [p.basenameWithoutExtension(latest)]);
  }

  void backUpSaves(Game game) {
    final folder = rootOf(game);
    if (folder == null) return;
    try {
      SaveBackup.backUp(Installer.installedFolder(game, folder), backupFolder(game), DateTime.now());
      _gameFacts.remove(game.id);
      show(T.text('savesBackedUp'));
    } on Object catch (error) {
      show('${T.text('backupFailed')}: $error');
    }
    _changed();
  }

  void restoreLatestSaves(Game game) {
    final folder = rootOf(game);
    final latest = SaveBackup.backups(backupFolder(game)).firstOrNull;
    if (folder == null || latest == null) return;
    if (running?.$1 == game) return show(T.text('closeGameFirst'));
    try {
      SaveBackup.restore(latest, Installer.installedFolder(game, folder), backupFolder(game), DateTime.now());
      _gameFacts.remove(game.id);
      _loadTrophies(game);
      show(T.text('savesRestored'));
    } on Object catch (error) {
      show('${T.text('backupFailed')}: $error');
    }
    _changed();
  }

  /// A backup the user picks takes the saves' place (the current ones backed up first), as on
  /// the Mac; the game must not be running.
  Future<void> restoreChosenSaves(Game game) async {
    if (running?.$1 == game || starting == game) return show(T.text('closeGameFirst'));
    final folder = rootOf(game);
    if (folder == null) return;
    final backups = backupFolder(game);
    final title = T.text('restoreSaves');
    final picked = services.pickFileAt != null
        ? await services.pickFileAt!(title, const ['zip'], Directory(backups).existsSync() ? backups : null)
        : await services.pickFile?.call(title, const ['zip']);
    if (picked == null) return;
    if (running?.$1 == game || starting == game) return show(T.text('closeGameFirst'));
    try {
      SaveBackup.restore(picked, Installer.installedFolder(game, folder), backups, DateTime.now());
      _gameFacts.remove(game.id);
      _loadTrophies(game);
      show(T.text('savesRestored'));
    } on Object catch (error) {
      show('${T.text('backupFailed')}: $error');
    }
    _changed();
  }

  void _appendLog(Game game, String line) {
    try {
      final file = File(paths.logFile(game.titleId));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('$line\n', mode: FileMode.append);
    } on FileSystemException {
      // The log is a help, not a need.
    }
  }

  String logText(Game game) {
    try {
      final text = File(paths.logFile(game.titleId)).readAsStringSync();
      return text.length > 60000 ? text.substring(text.length - 60000) : text;
    } on FileSystemException {
      return '';
    }
  }

  // Playing.

  /// Plays [game]; [trace] turns detailed logging on for this start only, and [once] adds to the
  /// engine's environment for this start only (the crash report's PlayGo answer).
  ///
  /// A copy made by another engine than the one it starts with now is rebuilt first, so two
  /// launchers on the same release always play the same build; [asItIs] starts the copy as it is
  /// (it was just rebuilt, it joins a host on that very engine, or the user chose to).
  Future<void> play(Game game, {bool trace = false, Map<String, String> once = const {}, bool asItIs = false}) async {
    if (game.retro case final RetroDisc disc) return _playStandalone(game, disc);
    final folder = rootOf(game);
    if (folder == null || starting != null || running != null || saveSync.syncing != null) return;
    if (!asItIs && needsRebuild(game)) {
      return rebuildFirst(game, () => unawaited(play(game, trace: trace, once: once, asItIs: true)));
    }
    // The profile's own saves and trophies in the game's folder before anything reads them.
    activateProfileSaves(game);
    final allowed = together.family.beforePlay(game);
    if (!(allowed is bool ? allowed : await allowed) || starting != null || running != null) return;
    // Settings › Behaviour › Save Sync: the saves from the other computers (or the cloud) first.
    // Off, the game starts at once, as it always did.
    if (saveSync.on) {
      await saveSync.sync(game);
      if (starting != null || running != null) return;
    }
    var settings = launchSettings(game);
    // Settings › Controllers › Stick Dead Zone, for a game that set none of its own.
    if (preferences.stickDeadzone > 0) {
      settings = settings.copyWith(tuning: StickDeadzone.tuning(settings.tuning, preferences.stickDeadzone));
    }
    final inputFile = p.join(paths.inputFilesFolder, '${game.slug}.ini');
    var written = true;
    try {
      settings.writeInputFile(inputFile);
    } on FileSystemException {
      written = false;
    }
    try {
      Directory(picturesFolder).createSync(recursive: true);
    } on FileSystemException {
      // Screenshots go nowhere then.
    }
    sounds.play(Cue.select);
    starting = game;
    final turn = ++_startTurn;
    _phoneToldFor = null;
    // A game linked to its dump cannot start once the dump moved: said instead of a crash.
    final broken = await Installer.brokenLink(Installer.installedFolder(game, folder));
    if (turn != _startTurn) return;
    if (broken != null) {
      starting = null;
      sounds.play(Cue.back);
      show(T.text('dumpMoved'));
      return;
    }
    preferences.lastPlayed[game.id] = DateTime.now().toIso8601String();
    savePreferences();
    final logFile = paths.logFile(game.titleId);
    final traced = crash.traced(settings, once: trace);
    // A log grown too big is set aside before the font watch reads where it ends.
    GameLog.rollForStart(logFile);
    try {
      // A game in Japanese, Korean or Chinese waits for those fonts; every game gets the folder
      // the fonts are put together in.
      final systemFonts = await fonts.prepare(game, settings.language ?? T.language.consoleLanguage);
      // Settings › AnyTogether › Online play: the loopback bridge the engine connects to
      // (ANYPS5_ONLINE, ANYPS5_ONLINE_SECRET) and the title's observation log; nothing when off.
      final online = await together.onlineEnvironment(game);
      if (turn != _startTurn) {
        if (starting == null) unawaited(together.onlineGameEnded());
        return;
      }
      final launcherEnvironment = {
        ...settings.environment(
          launcherLanguage: T.language.consoleLanguage,
          inputFile: written ? inputFile : null,
          screenshots: picturesFolder,
          fonts: systemFonts,
          shaderCacheFolder: paths.shaderCache(game.slug),
          trace: traced,
        ),
        ...?remote?.bridgeEnvironment,
        // The update and add-ons dumped beside the game.
        ...game.addonEnvironment,
        // Settings › Game Presets, for the games that ask the console for them.
        ...gamePresets.environment,
        // The engine's online bridge reads the AnyTogether game session there.
        if (together.signedIn) 'ANYPS5_TOGETHER_SESSION': together.hub.games.bridgeFile,
        // Settings › Battery & Heat: the frame cap now, and the file it changes in while it runs.
        ...powerWatch.environment(),
        ...online,
        ...once,
      };
      // Advanced › Launch › Launch options: the player's variables under the launcher's (its own
      // value wins), and the arguments for the game.
      final launch = settings.launch;
      final (environment, overridden) = launch?.over(launcherEnvironment) ?? (launcherEnvironment, const <String>[]);
      fonts.watch(game, logFile);
      final resolutionNote = await _setLaunchResolution(game, folder);
      final run = await startGame(
        installed: Installer.installedFolder(game, folder),
        environment: environment,
        arguments: launch?.arguments ?? const [],
        logFile: logFile,
        system: system,
        traced: traced,
        // The controllers at the start, in the log a crash report reads.
        notes: [
          for (final line in controllers.reportLines) '[anyps5-launcher] controllers: $line',
          if (phonesConnected) '[anyps5-launcher] phones: ${_phoneReachNote(game)}',
          ?resolutionNote,
          for (final MapEntry(:key, :value) in once.entries) '[anyps5-launcher] this start only: $key=$value',
          ...?launch?.notes(overridden),
        ],
      );
      // Closed while it was starting: the process goes again.
      if (turn != _startTurn) {
        run.stop();
        fonts.ended();
        if (starting == null) unawaited(together.onlineGameEnded());
        return;
      }
      starting = null;
      running = (game, run);
      _gameBegan = DateTime.now();
      _stopped = false;
      stopping = false;
      _checkPhoneReach(game);
      unawaited(_startReplay());
      unawaited(media.updateRemotePlay());
      crash.started(game, traced: traced);
      final began = DateTime.now();
      // Upstream's engine does not read ANYPS5_FULLSCREEN or ANYPS5_WINDOW_SIZE: the launcher
      // sizes its window or presses its F11 once the window is open.
      if (!engine.readsDisplaySettingsOf(game)) {
        unawaited(desktop.applyDisplay(run.pid, fullscreen: settings.fullscreen, windowSize: settings.windowSize));
      }
      // Settings › Behaviour › Hide the launcher while a game runs.
      if (preferences.hideWhilePlaying) unawaited(_hideForGame());
      _watchTrophies(game);
      together.gameChanged();
      discord.update();
      _changed();
      final code = await run.exitCode;
      _phoneAnswerTimer?.cancel();
      unawaited(together.onlineGameEnded());
      fonts.ended();
      together.recordPlay(game, began, DateTime.now(), exit: _stopped ? 'killed' : (code == 0 ? 'normal' : 'crashed'));
      _trophyWatch?.cancel();
      _loadTrophies(game);
      if (running?.$1 == game) running = null;
      stopping = false;
      _stopTimer?.cancel();
      _stopTimer = null;
      unawaited(_stopReplay());
      media.gameEnded();
      unawaited(waylandCapture?.end());
      sharePlay.gameEnded();
      // Minimized for the game: back in front now it has closed, as on the Mac.
      if (hiddenForGame) {
        hiddenForGame = false;
        unawaited(services.window?.restore());
      }
      // The quick menu and the question go with the game.
      if (overlay == Layer.quickMenu || overlay == Layer.closeGame) overlay = null;
      updates.gameEnded();
      together.gameChanged();
      discord.update();
      crash.ended(game, code, stopped: _stopped);
      // The phone could not reach the game on upstream's engine: the switch, once back over Home.
      if (_phoneEngineAfterGame) {
        _phoneEngineAfterGame = false;
        askPhoneEngine(again: true);
      }
      // The saves it made go to the other computers (or the cloud).
      final saves = saveSync.sync(game);
      // "How did it run?", once the launcher is back over the home screen.
      together.askHowItRan(game, DateTime.now().difference(began));
      _changed();
      // The phone asked for another game while this one played: it starts now this one has gone
      // (and its saves have synced, which a start waits for), as on the Mac.
      final next = _launchAfterExit;
      _launchAfterExit = null;
      if (next != null) {
        _quitAfterGame = null;
        unawaited(_startAfterExit(next, saves));
        return;
      }
      // Started from a Steam shortcut of the game: the launcher goes with it, so Steam sees
      // the game end. A crash keeps it open on its report.
      if (_quitAfterGame == game.id) {
        _quitAfterGame = null;
        if (code == 0 || _stopped) (services.quit ?? exit)(0);
      }
    } on Object catch (error) {
      // A start given up meanwhile has nothing more to say.
      if (turn != _startTurn) return;
      starting = null;
      fonts.ended();
      unawaited(together.onlineGameEnded());
      vibrate(HapticCue.error);
      show('${T.text('startFailed')}: $error');
      _changed();
    }
  }

  /// Counts the starts: a start given up ([cancelStart]) sees it has changed after each wait.
  int _startTurn = 0;

  /// The game the phone asked for while another played; it starts when that one has gone.
  String? _launchAfterExit;

  /// Gives up the game starting (Close on the phone while it starts), as on the Mac.
  void cancelStart() {
    if (starting == null) return;
    _startTurn++;
    sounds.play(Cue.back);
    starting = null;
    _changed();
  }

  /// The game the phone asked for, once the one before it has gone and its saves have synced.
  Future<void> _startAfterExit(String id, Future<void> saves) async {
    try {
      await saves;
    } on Object {
      // The sync said why; the game the phone asked for still starts.
    }
    if (_disposed || running != null || starting != null) return;
    final game = games.where((game) => game.id == id).firstOrNull;
    if (game == null) return;
    select(games.indexOf(game));
    primaryAction(game);
  }

  /// Starts a standalone emulator. On Linux it gets the launcher's environment without what the
  /// launcher's AppImage set ([GameProcess.withoutAppImage]).
  @visibleForTesting
  late Future<RunningGame> Function({
    required String installed,
    required String program,
    required List<String> arguments,
    required String logFile,
  })
  startRetroGame = ({required installed, required program, required arguments, required logFile}) => GameProcess.start(
    installed: installed,
    program: program,
    arguments: arguments,
    logFile: logFile,
    environment: system == HostSystem.linux
        ? GameProcess.withoutAppImage(services.environment ?? Platform.environment)
        : const {},
    inheritEnvironment: system != HostSystem.linux,
  );

  /// While a game runs, a trophy it earns shows and goes to the phones.
  void _watchTrophies(Game game) {
    final folder = rootOf(game);
    if (folder == null) return;
    final installed = Installer.installedFolder(game, folder);
    _earned = Trophies.earned(installed);
    _trophyWatch?.cancel();
    _trophyWatch = Timer.periodic(const Duration(seconds: 2), (_) {
      final now = Trophies.earned(installed);
      final fresh = now.difference(_earned);
      _earned = now;
      if (fresh.isEmpty) return;
      _loadTrophies(game);
      // Heard over the game too; felt only with the launcher in front.
      sounds.play(Cue.unlocked, overGame: true);
      vibrate(HapticCue.trophy);
      for (final id in fresh) {
        final trophy = trophies[game.id]?.trophies.where((trophy) => trophy.id == id).firstOrNull;
        if (trophy == null) continue;
        show('${T.text('trophyEarned')} · ${trophy.name}');
        if (running case (final Game playing, final RunningGame run) when playing == game) {
          unawaited(celebrate(game, trophy, run.pid));
        }
        unawaited(_tellTrophy(trophy));
      }
      _changed();
    });
  }

  /// A trophy earned, to the phones: its icon at most [PhoneArt.trophySide] a side, as on the Mac.
  Future<void> _tellTrophy(Trophy trophy) async {
    final icon = trophy.icon;
    final small = icon == null ? null : await PhoneArt.smaller(icon, PhoneArt.trophySide);
    if (_disposed) return;
    remote?.publish(
      RemoteTrophy(
        name: trophy.name,
        detail: trophy.detail,
        grade: trophy.grade.name,
        icon: small == null ? null : base64.encode(small),
      ),
    );
  }

  Future<void> _cards = Future.value();

  /// A trophy earned while the game is in front: a picture of the game at that moment (taken
  /// before the card covers any of it) into its pictures folder, then the card over the game,
  /// one after another when several come at once; a notification where no card can be shown.
  Future<void> celebrate(Game game, Trophy trophy, int pid) async {
    final shot = await _trophyShot(game, trophy, pid);
    if (shot != null) {
      trophyShots = {...trophyShots, trophy.id: shot};
      if (overlay == Layer.trophies || overlay == Layer.gallery) _loadShots();
      notifyListeners();
    }
    await _cardTurn(() async {
      try {
        final scale = desktop.cardScale(pid);
        final render =
            services.renderTrophyCard ??
            (trophy, scale) => TrophyCard.render(trophy, scale: scale, glass: look == LookStyle.glass);
        final card = await render(trophy, scale);
        if (!await desktop.showCard(card, pid: pid)) {
          await desktop.notify(
            T.text('trophyEarned'),
            trophy.name.isEmpty ? T.text('trophyHidden') : trophy.name,
            icon: shot,
          );
        }
      } on Object {
        // The toast in the launcher and the phone still say it.
      }
    });
  }

  /// A card over the game takes its turn: one window at a time, one after another as on the Mac.
  Future<R> _cardTurn<R>(Future<R> Function() body) async {
    final previous = _cards;
    final done = Completer<void>();
    _cards = done.future;
    await previous;
    try {
      return await body();
    } finally {
      done.complete();
    }
  }

  /// A short message as the card over the game the Mac shows (its TrophyBanner notices), with
  /// the game playing and a desktop that can draw one. False when it could not be: the desktop
  /// notice instead.
  Future<bool> _noticeCard(String title, String? detail, IconData symbol, {bool sound = true}) {
    final pid = running?.$2.pid;
    if (pid == null || !desktop.canShowCard) return Future.value(false);
    return _cardTurn(() async {
      try {
        final scale = desktop.cardScale(pid);
        final render =
            services.renderNoticeCard ??
            (title, detail, symbol, scale) => TrophyCard.renderNotice(
              title,
              detail: detail,
              symbol: symbol,
              scale: scale,
              glass: look == LookStyle.glass,
            );
        final card = await render(title, detail, symbol, scale);
        if (sound) sounds.play(Cue.unlocked, overGame: true);
        return await desktop.showCard(card, pid: pid);
      } on Object {
        return false;
      }
    });
  }

  /// Saves the game's window as it is now as the picture of [trophy]; its path, or null. With
  /// the family's media setting off no picture is taken, as on the Mac.
  Future<String?> _trophyShot(Game game, Trophy trophy, int pid) async {
    if (!together.family.mediaAllowed) return null;
    try {
      final frame = await desktop.captureGame(pid);
      if (frame == null) return null;
      final path = Screenshots.trophyPath(picturesFolder, game, trophy.id, DateTime.now());
      await Isolate.run(() {
        File(path)
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync(PngEncoder.rgba(frame.width, frame.height, frame.pixels));
      });
      return path;
    } on Object {
      return null;
    }
  }

  /// Whether the user (or the phone) closed the game playing.
  bool _stopped = false;

  /// Starts an installed game's process (GameProcess.start); replaceable in tests.
  Future<RunningGame> Function({
    required String installed,
    required Map<String, String> environment,
    List<String> arguments,
    required String logFile,
    HostSystem? system,
    bool traced,
    List<String> notes,
  })
  startGame = GameProcess.start;

  /// Stop asked the game playing to close: it is given [stopGrace], then ended.
  bool stopping = false;
  Timer? _stopTimer;

  /// How long a game asked to close has before it is ended.
  Duration stopGrace = const Duration(seconds: 8);

  void stopGame() {
    if (running != null) _stopped = true;
    running?.$2.stop();
  }

  /// Stop (the game's main button while it runs, Close Game in the quick menu): the game is
  /// asked to close as closing its window would, so it can save, and ended if it is still there
  /// after [stopGrace]. Its tile reads Stopping meanwhile and Ready once it is gone.
  Future<void> stopRunningGame() async {
    final playing = running;
    if (playing == null || stopping) return;
    final run = playing.$2;
    _stopped = true;
    stopping = true;
    sounds.play(Cue.back);
    _changed();
    _stopTimer?.cancel();
    _stopTimer = Timer(stopGrace, () {
      _stopTimer = null;
      if (running?.$2 == run) run.kill();
    });
    try {
      await run.close();
    } on Object {
      // The kill after the grace still ends it.
    }
  }

  /// Asks the game playing to close as its window would (a family limit): the launcher closed
  /// it, so no crash report follows.
  Future<void> closeGame() async {
    if (running == null) return;
    _stopped = true;
    await running!.$2.close();
  }

  /// Ends the game playing at once (a family limit after its grace).
  void killGame() {
    if (running != null) _stopped = true;
    running?.$2.kill();
  }

  // Messages.

  void show(String message, {LevelBadge? level, String? icon, void Function()? onTap}) {
    toast = message;
    toastLevel = level;
    toastIcon = icon;
    toastTap = onTap;
    _toastTimer?.cancel();
    _backdropRetry?.cancel();
    _toastTimer = Timer(Duration(seconds: level == null ? 4 : 5), () {
      toast = null;
      toastLevel = null;
      toastIcon = null;
      toastTap = null;
      notifyListeners();
    });
    notifyListeners();
  }

  // Navigation.

  /// Opens a layer with the select sound, or [cue] (going back to the panel before).
  void open(Layer next, {Cue cue = Cue.select}) {
    sounds.play(cue);
    if (overlay != next) together.askingRow = null;
    overlay = next;
    panelRow = 0;
    // Settings open with every section; a search is over.
    if (next == Layer.settings) {
      settingsQuery = '';
      settingsSearchFocused = false;
    }
    panelCategory = 0;
    panelSections = false;
    editingValue = null;
    if (shortcutCapture != null) {
      shortcutCapture = null;
      _captureTimer?.cancel();
    }
    capturing = null;
    if (next == Layer.library) libraryIndex = selected;
    if (next == Layer.gameSettings) _gameFacts.clear();
    if (next == Layer.log) shownLog = selectedGame == null ? '' : logText(selectedGame!);
    if (next == Layer.trophies) {
      trophyIndex = 0;
      revealedTrophies = {};
    }
    if (next == Layer.trophies || next == Layer.gallery) _loadShots();
    if (next == Layer.controls && selectedGame != null) _readControls(selectedGame!);
    // The screens that show the own name and handle read them again first.
    if (next == Layer.friends || next == Layer.profile || next == Layer.settings || next == Layer.profilePicker) {
      together.refreshOwnProfile();
    }
    // Friends' private picture links run out (6 to 12 hours): the list is read again.
    if ((next == Layer.friends || next == Layer.party || next == Layer.profile) &&
        together.signedIn &&
        together.hub.friends.identities.learnedAt != null &&
        together.hub.friends.identities.stale()) {
      unawaited(together.hub.friends.refresh().catchError((Object _) {}));
    }
    if (next == Layer.gallery) {
      galleryIndex = 0;
      galleryViewing = false;
    }
    // The party's chat: its newest messages, read while it shows.
    if (next == Layer.party) together.partyScreenOpened();
    _skipToFocusable();
    _changed();
  }

  /// Where the user is now, for [returnTo]; null on Home.
  PanelSpot? get spot {
    final layer = overlay;
    if (layer == null) return null;
    final categories = panelCategories();
    final category = categories.isEmpty ? null : categories[panelCategory.clamp(0, categories.length - 1)];
    final rows = category?.rows ?? const <PanelRow>[];
    return (layer: layer, category: category?.id, row: panelRow < rows.length ? rows[panelRow].id : null);
  }

  /// Back where [spot] was taken: its layer, section and row, with the back sound. Home when
  /// there is no spot. A section or row gone since falls back to the first.
  void returnTo(PanelSpot? spot) {
    if (spot == null) return closeOverlay();
    open(spot.layer, cue: Cue.back);
    final categories = panelCategories();
    final index = categories.indexWhere((category) => category.id == spot.category);
    if (index < 0) return;
    panelCategory = index;
    final row = categories[index].rows.indexWhere((row) => row.id == spot.row);
    panelRow = row < 0 ? 0 : row;
    _skipToFocusable();
    _changed();
  }

  /// Settings, on the section [id].
  void openSettingsCategory(String id) {
    open(Layer.settings);
    final index = panelCategories().indexWhere((category) => category.id == id);
    if (index < 0) return;
    panelCategory = index;
    panelRow = 0;
    _skipToFocusable();
    _changed();
  }

  /// Settings › AnyPS5 Engine, from Home's engine line.
  void openEngineSettings() {
    open(Layer.settings);
    final index = panelCategories().indexWhere((category) => category.id == 'engine');
    if (index < 0) return;
    panelCategory = index;
    panelRow = 0;
    _skipToFocusable();
    _changed();
  }

  /// AnyTogether answered client_too_old: Update Required over Home (a toast over a game or
  /// another screen), and a quiet look for the release that replaces this one.
  void showUpdateRequired(ClientTooOld old) {
    unawaited(updates.check(quiet: true));
    if (overlay == null && running == null && starting == null) {
      open(Layer.updateRequired);
      panelRow = 1;
      _changed();
    } else {
      show(T.format('requiredToast', [old.minimum]));
    }
  }

  void closeOverlay() {
    overlay = null;
    deletion.ask = null;
    // A crop closed some other way (PS) keeps nothing.
    pictureCrop?.image.dispose();
    pictureCrop = null;
    panelSections = false;
    settingsQuery = '';
    settingsSearchFocused = false;
    editingValue = null;
    shortcutCapture = null;
    together.askingRow = null;
    capturing = null;
    revealedTrophies = {};
    sounds.play(Cue.back);
    _changed();
  }

  /// The game of a Steam shortcut (--play <title ID>), started once the library is read. With
  /// [quitAfter] (Steam started the launcher) it closes when the game ends normally.
  Future<void> playAtLaunch(String titleId, {bool quitAfter = false}) async {
    final wanted = titleId.toUpperCase();
    final index = games.indexWhere((game) => game.titleId.toUpperCase() == wanted);
    if (index < 0) return show(T.format('steamPlayMissing', [titleId]));
    final game = games[index];
    select(index);
    if (!records.containsKey(game.id)) return show(T.format('steamPlayLocked', [game.name]));
    if (quitAfter) _quitAfterGame = game.id;
    await play(game);
    if (running?.$1 != game && _quitAfterGame == game.id) _quitAfterGame = null;
  }

  String? _quitAfterGame;

  void select(int index) {
    if (index < 0 || index >= games.length) return;
    selected = index;
    _homeRetroFolder = preferences.showRetroFolders ? games[index].retro?.platform : null;
    focus = HomeFocus.tiles;
    measureSelected();
    _changed();
  }

  /// Play, the trophies when the game has any, and the settings.
  int get actionCount => selectedGame != null && trophies.containsKey(selectedGame!.id) ? 3 : 2;

  /// Which of the buttons under the title opens the settings.
  int get settingsAction => actionCount - 1;

  void moveSelection(int delta) {
    final next = (selected + delta).clamp(0, games.isEmpty ? 0 : games.length - 1);
    if (next == selected) return;
    selected = next;
    sounds.play(Cue.move);
    if (focus.isActions && focus.index >= actionCount) focus = HomeFocus.actions(actionCount - 1);
    if (overlay == Layer.trophies) {
      trophyIndex = 0;
      revealedTrophies = {};
      if (!trophies.containsKey(selectedGame?.id)) overlay = null;
    }
    measureSelected();
    _changed();
  }

  /// Home screen, library and panels: what a command does where the user is.
  void handle(Command command) {
    // Mirrored screens (Arabic, Urdu): → moves to what is drawn on the right, as on the Mac.
    // Watching a share play the controller is the game's, so it stays as it is there.
    if (T.language.isRightToLeft && overlay != Layer.shareWatch) command = command.mirrored;
    if (pairing != null) {
      if (command == Command.select) answerPairing(true);
      if (command == Command.back) answerPairing(false);
      return;
    }
    // A friend calling: Enter answers, Back declines, as on the Mac.
    if (together.ringing != null && command != Command.home) {
      if (command == Command.select) unawaited(together.acceptRinging());
      if (command == Command.back) together.declineRinging();
      return;
    }
    if (!preferences.onboarded) return _onboardingCommand(command);
    // Watching a share play: the controller is the game's.
    if (overlay == Layer.shareWatch) return sharePlay.watchCommand(command);
    // At start a profile is picked first: PS waits.
    if (overlay == Layer.profilePicker && profileFlow.atLaunch && command == Command.home) return sounds.play(Cue.bump);
    if (command == Command.home) {
      // PS/Guide: from the game to the launcher and back; behind another window, to the front.
      final run = running?.$2;
      switch (_guide.press(
        now: feelNow,
        gameRunning: run != null,
        launcherInFront: _frontForGuide,
        layerOpen: overlay != null,
      )) {
        case GuideAction.showGame:
          // The quick menu (or Close Game?) goes with the launcher.
          if (overlay == Layer.quickMenu || overlay == Layer.closeGame) {
            overlay = null;
            _changed();
          }
          unawaited(_showGame(run!));
        case GuideAction.showLauncher:
          // From the game: the launcher with the quick menu over it, the game paused first.
          unawaited(run != null ? openQuickMenu() : raiseLauncher());
        case GuideAction.closeLayer:
          closeOverlay();
        case GuideAction.none:
          break;
      }
      return;
    }
    if (command == Command.previousGame || command == Command.nextGame) {
      if (capturing == null &&
          (overlay == null ||
              overlay == Layer.gameSettings ||
              overlay == Layer.controls ||
              overlay == Layer.advanced ||
              overlay == Layer.trophies)) {
        moveSelection(command == Command.nextGame ? 1 : -1);
      }
      return;
    }
    switch (overlay) {
      case Layer.library:
        final columns = libraryColumns;
        switch (command) {
          case Command.left:
            _moveLibrary(-1);
          case Command.right:
            _moveLibrary(1);
          case Command.up:
            _moveLibrary(-columns);
          case Command.down:
            _moveLibrary(columns);
          case Command.select:
            select(libraryIndex);
            closeOverlay();
          case Command.back || Command.options:
            closeOverlay();
          default:
            break;
        }
        return;
      case Layer.log:
        if (command == Command.back || command == Command.select) closeOverlay();
        return;
      case Layer.crashReport:
        crash.command(command);
        return;
      case Layer.browserPlay:
        browserPlay.command(command);
        return;
      case Layer.cropPicture:
        cropCommand(command);
        return;
      case Layer.controllerTest:
        // Only the keyboard and the mouse get here (the pads' buttons are being tried).
        if (command == Command.back) closeControllerTest();
        return;
      case Layer.gallery:
        _galleryCommand(command);
        return;
      case Layer.trophies:
        final count = trophies[selectedGame?.id]?.trophies.length ?? 0;
        switch (command) {
          case Command.up || Command.down:
            final next = (trophyIndex + (command == Command.down ? 1 : -1)).clamp(0, count == 0 ? 0 : count - 1);
            if (next == trophyIndex) return;
            sounds.play(Cue.move);
            trophyIndex = next;
            _changed();
          case Command.select:
            final trophy = trophies[selectedGame?.id]?.trophies.elementAtOrNull(trophyIndex);
            // The moment the focused trophy was earned, without one the game's leaderboard.
            if (trophyShots[trophy?.id] case final String shot) {
              openGallery(shot: shot);
            } else if (together.signedIn) {
              together.openLeaderboard(selectedGame);
            }
          // △ (Triangle, Y, O) on a hidden trophy shows it, and hides it again.
          case Command.options when focusedTrophy != null && canReveal(focusedTrophy!):
            toggleReveal(trophyIndex);
          case Command.back || Command.options:
            closeOverlay();
          default:
            break;
        }
        return;
      case Layer.controls:
        if (capturing != null) {
          if (command == Command.back) {
            capturing = null;
            sounds.play(Cue.back);
            _changed();
          }
          return;
        }
        if (command == Command.back || command == Command.options) {
          open(Layer.gameSettings, cue: Cue.back);
          return;
        }
        _panelCommand(command);
        return;
      case Layer.advanced:
        // Back to the game's settings, on the row that opened the page.
        if (command == Command.back || command == Command.options) {
          open(Layer.gameSettings, cue: Cue.back);
          final row = panelCategories().firstOrNull?.rows.indexWhere((row) => row.id == 'advanced') ?? -1;
          if (row >= 0) panelRow = row;
          _changed();
          return;
        }
        _panelCommand(command);
        return;
      case Layer.messages:
        together.messagesCommand(command);
        return;
      // The party's chat beside its rows: → into it, everything while the keys are there.
      case Layer.party when together.partyChatCommand(command):
        return;
      case Layer.profile:
        together.profileCommand(command);
        return;
      case Layer.compare:
        together.compareCommand(command);
        return;
      case Layer.feed:
        together.feedCommand(command);
        return;
      case Layer.captures:
        together.capturesCommand(command);
        return;
      case Layer.leaderboard:
        together.leaderboardCommand(command);
        return;
      case Layer.challenge:
        together.challengeCommand(command);
        return;
      case Layer.shareWatch:
        // Taken above; here only for the switch's sake.
        return sharePlay.watchCommand(command);
      case Layer.quickMenu || Layer.closeGame when command == Command.back || command == Command.options:
        // A share play question asked in place (together_ask.dart) is answered Cancel first.
        if (!together.cancelAsk()) resumeGame();
        return;
      case Layer.profilePicker:
        pickerCommand(command);
        return;
      case Layer.addProfile:
        modeChoiceCommand(command);
        return;
      case Layer.signIn:
        _signInCommand(command);
        return;
      case Layer.gameFiles when command == Command.back || command == Command.options:
        files.back();
        return;
      case Layer.cloudQuestion when command == Command.back || command == Command.options:
        saveSync.answerBack();
        return;
      case Layer.cloudStorage when command == Command.back || command == Command.options:
        saveSync.backFromStorage();
        return;
      case Layer.lfgPost || Layer.gameHub when command == Command.back || command == Command.options:
        together.backFromFind();
        return;
      case Layer.findPlayers when command == Command.back || command == Command.options:
        _panelCommand(command);
        // Closed: the board's topics are no longer listened to.
        if (overlay != Layer.findPlayers) together.findClosed();
        return;
      case Layer.showcaseEdit || Layer.profileTheme when command == Command.back || command == Command.options:
        together.backToProfile();
        return;
      case Layer.countryPicker when command == Command.back || command == Command.options:
        together.backFromCountry();
        return;
      case Layer.friendOptions when command == Command.back || command == Command.options:
        // A question asked in place (together_ask.dart) is answered Cancel first.
        if (!together.cancelAsk()) open(Layer.friends, cue: Cue.back);
        return;
      case Layer.settings ||
          Layer.gameSettings ||
          Layer.confirmUninstall ||
          Layer.confirmDeleteGame ||
          Layer.copyWarning ||
          Layer.gameFiles ||
          Layer.updateChoice ||
          Layer.updateRequired ||
          Layer.joinBlocked ||
          Layer.joinOrHost ||
          Layer.phoneEngine ||
          Layer.friends ||
          Layer.friendOptions ||
          Layer.party ||
          Layer.family ||
          Layer.quickMenu ||
          Layer.closeGame ||
          Layer.homeMenu ||
          Layer.confirmQuit ||
          Layer.launcherReport ||
          Layer.cloudQuestion ||
          Layer.cloudStorage ||
          Layer.profileMenu ||
          Layer.themes ||
          Layer.themeStudio ||
          Layer.showcaseEdit ||
          Layer.profileTheme ||
          Layer.countryPicker ||
          Layer.notifications ||
          Layer.compat ||
          Layer.findPlayers ||
          Layer.lfgPost ||
          Layer.gameHub:
        _panelCommand(command);
        return;
      case null:
        break;
    }
    final game = selectedGame;
    // With no games the top bar still works: Up reaches it, and Select on the empty shelf adds a
    // games folder.
    if (game == null && (focus.area == 'tiles' || focus.area == 'actions')) {
      if (command == Command.select) unawaited(addGamesFolder());
      if (command == Command.up) _moveFocus(const HomeFocus.top(1));
      return;
    }
    // The notice went (Later, or the update went in): its focus goes to the top bar.
    if (focus.isNotice && !updates.showsNotice) focus = const HomeFocus.top(0);
    if (focus == const HomeFocus.notice(1) && updates.restartAfterGame) focus = const HomeFocus.notice(0);
    // The profile list the pointer opened: Back closes it, whatever has the focus.
    if (profileFlow.listShown && command == Command.back) return closeProfileList();
    switch ((focus.area, command)) {
      // The profile picture, past the last button: its list opens under it.
      case ('top', Command.right) when focus.index >= topButtons - 1:
        _moveFocus(const HomeFocus.switcher(0));
      case ('switcher', Command.left) when focus.index == 0:
        _moveFocus(HomeFocus.top(topButtons - 1));
      case ('switcher', Command.down) || ('switcher', Command.select) when focus.index == 0:
        _moveFocus(const HomeFocus.switcher(1));
      case ('switcher', Command.down):
        focus.index < switcherCount ? _moveFocus(HomeFocus.switcher(focus.index + 1)) : sounds.play(Cue.bump);
      case ('switcher', Command.up):
        if (focus.index > 0) _moveFocus(HomeFocus.switcher(focus.index - 1));
      case ('switcher', Command.select):
        chooseFromProfileList(focus.index - 1);
      case ('switcher', Command.back):
        closeProfileList();
      case ('tiles', Command.left):
        moveHomeSelection(-1);
      case ('tiles', Command.right):
        moveHomeSelection(1);
      case ('tiles', Command.down):
        if (!openSelectedHomeFolder()) _moveFocus(const HomeFocus.actions(0));
      case ('tiles', Command.back):
        closeHomeFolder();
      case ('tiles', Command.up):
        if (!closeHomeFolder()) _moveFocus(const HomeFocus.top(1));
      case ('tiles', Command.select):
        if (!openSelectedHomeFolder()) primaryAction(game!);
      case ('top', Command.left) when focus.index == 0 && updates.showsNotice:
        _moveFocus(HomeFocus.notice(updates.restartAfterGame ? 0 : 1));
      case ('top', Command.left):
        _moveFocus(HomeFocus.top((focus.index - 1).clamp(0, topButtons - 1)));
      case ('notice', Command.left):
        _moveFocus(HomeFocus.notice(focus.index > 0 ? focus.index - 1 : 0));
      case ('notice', Command.right):
        _moveFocus(focus.index == 1 || updates.restartAfterGame ? const HomeFocus.top(0) : const HomeFocus.notice(1));
      case ('notice', Command.down) || ('notice', Command.back):
        _moveFocus(HomeFocus.tiles);
      case ('notice', Command.select) when focus.index == 0:
        updates.restartAfterGame ? updates.cancelRestart() : unawaited(updates.restartNow());
      case ('notice', Command.select):
        updates.later();
        _moveFocus(const HomeFocus.top(0));
      case ('top', Command.right):
        _moveFocus(HomeFocus.top((focus.index + 1).clamp(0, topButtons - 1)));
      case ('top', Command.down) || ('top', Command.back):
        _moveFocus(HomeFocus.tiles);
      case ('top', Command.select):
        final layer = topLayers[focus.index.clamp(0, topButtons - 1)];
        switch (layer) {
          case Layer.messages:
            unawaited(together.openMessages());
          case Layer.notifications:
            together.openNotifications();
          default:
            open(layer);
        }
      case ('actions', Command.left):
        _moveFocus(HomeFocus.actions((focus.index - 1).clamp(0, actionCount - 1)));
      case ('actions', Command.right):
        _moveFocus(HomeFocus.actions((focus.index + 1).clamp(0, actionCount - 1)));
      case ('actions', Command.up) || ('actions', Command.back):
        _moveFocus(HomeFocus.tiles);
      case ('actions', Command.select):
        if (focus.index == 0) {
          primaryAction(game!);
        } else if (focus.index == 1 && actionCount == 3) {
          open(Layer.trophies);
        } else {
          open(Layer.gameSettings);
        }
      case (_, Command.options):
        if (selectedHomeFolder == null) open(Layer.gameSettings);
      default:
        break;
    }
  }

  /// The sign-in screen: Back gives it up (a question asked in place answers Cancel first).
  void _signInCommand(Command command) {
    if (command == Command.back && editingRow == null) {
      if (!together.cancelAsk()) unawaited(cancelSignIn());
      return;
    }
    _panelCommand(command);
  }

  // PS: the quick menu, Close Game?, the home menu.

  /// The key the game's Options is on (its controls), for pausing it; null when it has none.
  String? optionsKey(Game game) {
    final sources = Controls.sources(PadAction.options, currentSettings(game).controls ?? const {});
    for (final source in sources) {
      if (source.startsWith('KEY:')) return source.substring(4);
    }
    return null;
  }

  /// The quick menu over the game playing: the game's Options pressed first (Settings ›
  /// Behaviour › Pause Game When Opening the Menu) while it is still in front, then the
  /// launcher in front with Resume, Game Settings and Close Game.
  Future<void> openQuickMenu() async {
    final playing = running;
    if (playing == null || !preferences.onboarded) return;
    final (game, run) = playing;
    final front = _frontForGuide;
    quickMenuPaused = false;
    if (!front && preferences.pauseOnMenu && game.retro == null) {
      // An engine that takes presses: Options held on player 1's pad through the remote pad
      // bridge, whoever drives it (sent three times, 40 ms apart; the menu ~210 ms after the
      // first). Otherwise the key the game's Options is on, typed into its window.
      final server = remote;
      if (server != null && server.gameTakesPresses) {
        final sent = server.pressButtons(RemotePacket.options);
        await Future<void>.delayed(const Duration(milliseconds: 210));
        quickMenuPaused = await sent;
        _padLog?.call('quick menu: ${quickMenuPaused ? 'Options pressed through the bridge' : 'no bridge took it'}');
      } else {
        final key = optionsKey(game);
        final paused = key != null && await desktop.pressKey(run.pid, key);
        quickMenuPaused = paused;
        _padLog?.call('quick menu: ${paused ? 'pressed $key in the game' : 'could not pause the game'}');
      }
    }
    if (running?.$2 != run) return;
    final index = games.indexOf(game);
    if (index >= 0) selected = index;
    open(Layer.quickMenu);
    if (!front) await raiseLauncher();
  }

  /// Whether the game under the quick menu was sent its Options (paused, as far as the launcher
  /// can tell).
  bool quickMenuPaused = false;

  /// PS held: Close Game? over a game in front; the home menu in the launcher.
  void homeHeld() {
    if (!preferences.onboarded) return;
    if (overlay == Layer.profilePicker && profileFlow.atLaunch) return;
    final front = _frontForGuide;
    if (running != null && !front) {
      open(Layer.closeGame);
      unawaited(raiseLauncher());
      return;
    }
    if (overlay == Layer.controllerTest) return;
    open(Layer.homeMenu);
    if (!front) unawaited(raiseLauncher());
  }

  /// Back to the game from the quick menu (or Close Game?): the game in front again. Its pause
  /// menu, if the Options press opened one, stays for the player.
  void resumeGame() {
    overlay = null;
    sounds.play(Cue.back);
    _changed();
    if (running?.$2 case final RunningGame run) unawaited(_showGame(run));
  }

  /// Close Game from the quick menu or the question.
  void closeRunningGame() {
    overlay = null;
    sounds.play(Cue.select);
    unawaited(stopRunningGame());
    _changed();
  }

  /// The layers that ask a plain yes or no, drawn as ConfirmCard: two answers side by side.
  static const twoChoiceLayers = {Layer.confirmQuit, Layer.closeGame, Layer.confirmDeleteGame};

  bool get twoChoice => twoChoiceLayers.contains(overlay);

  /// Escape on the home screen, the games in focus and nothing over them, asks Quit AnyPS5?
  /// (Cancel first); everywhere else Escape keeps its meaning.
  bool askQuit() {
    if (!preferences.onboarded || overlay != null || pairing != null || starting != null || !focus.isTiles) {
      return false;
    }
    // The profile list opened with the pointer: Escape closes it first.
    if (profileFlow.listShown) return false;
    open(Layer.confirmQuit);
    return true;
  }

  /// Quit AnyPS5 (the home menu): the game playing closes with it.
  void quitLauncher() {
    stopGame();
    unawaited(_stopReplay());
    unawaited(discord.close());
    unawaited(nowPlaying.close());
    (services.quit ?? exit)(0);
  }

  // Captures: Share, the replay buffer, screenshots.

  ReplayBuffer? _replay;

  /// Whether the replay buffer is recording now.
  bool get replayRecording => _replay?.running ?? false;

  /// Whether the replay buffer is recording or starting to.
  bool get replayStarted => _replay != null;

  ReplayBuffer? _defaultReplay(int seconds, {VideoEncoder? encoder, GameSound? sound}) {
    final environment = services.environment ?? Platform.environment;
    final ffmpeg = replayFfmpeg;
    final wayland = waylandCapture;
    if (ffmpeg == null || (wayland == null && !ReplayBuffer.supported(system, environment))) return null;
    return ReplayBuffer(
      ffmpeg: ffmpeg,
      folder: p.join(Directory.systemTemp.path, 'anyps5-replay-$pid'),
      seconds: seconds,
      system: system,
      environment: environment,
      encoder: encoder,
      sound: sound,
      wayland: wayland,
    );
  }

  /// Under Wayland, the desktop's portal and what it needs; null on every other desktop.
  late final WaylandCapture? waylandCapture =
      services.waylandCapture ??
      (WaylandCapture.applies(system, services.environment ?? Platform.environment)
          ? WaylandCapture(
              portal: DbusScreenCastPortal(),
              environment: services.environment ?? Platform.environment,
              readToken: () => preferences.waylandRestoreToken,
              saveToken: (token) {
                preferences.waylandRestoreToken = token;
                savePreferences();
              },
              beforeAsking: _gameWindowOpen,
              log: (line) => addRecentLine('${DateTime.now().toIso8601String()} $line'),
            )
          : null);

  DateTime? _gameBegan;

  /// How long a game gets to open its window before the desktop is asked for it anyway: a
  /// window drawn natively for Wayland cannot be seen from here.
  static const _gameWindowWait = Duration(seconds: 8);

  /// Returns once the game's window is open, as far as can be told: the desktop's dialog lists
  /// open windows, and bringing a window back needs it there.
  Future<void> _gameWindowOpen() async {
    final deadline = (_gameBegan ?? DateTime.now()).add(_gameWindowWait);
    while (DateTime.now().isBefore(deadline)) {
      final playing = running;
      if (playing == null) return;
      final desktop = this.desktop;
      if (desktop is GameAreas && (desktop as GameAreas).gameArea(playing.$2.pid) != null) return;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }

  /// Turns the replay buffer on under Wayland: says now what is missing, and asks the desktop
  /// now when a game is open. Without a game there is no window to choose yet, so the user is
  /// told the desktop will ask when one opens.
  Future<void> _turnOnReplayUnderWayland(WaylandCapture capture) async {
    final problem = await capture.check();
    if (problem != null) return show(T.text(problem.textKey));
    if (services.replay == null && await media.encoders?.encoder == null) return show(T.text('waylandNoEncoder'));
    preferences.replayBuffer = true;
    savePreferences();
    if (running == null) {
      unawaited(notice(T.text('waylandAskTitle'), detail: T.text('waylandAskDetail')));
      return _changed();
    }
    await _startReplay();
    _changed();
  }

  /// ffmpeg found on this computer, or the one downloaded for the launcher ([FfmpegModel]).
  late final FfmpegModel ffmpegTool = FfmpegModel(this);

  /// ffmpeg for the replay buffer and everything else that records or decodes.
  String? get replayFfmpeg => ffmpegTool.path;

  /// Why the replay buffer cannot record here (no ffmpeg, no desktop to record), or null when it
  /// can. What the Wayland portal needs is checked when the buffer is turned on.
  String? get replayUnavailable {
    if (services.replay != null) return null;
    if (waylandCapture == null && !ReplayBuffer.supported(system, services.environment ?? Platform.environment)) {
      return T.text('replayNoScreen');
    }
    return replayFfmpeg == null ? T.text('replayNoFfmpeg') : null;
  }

  Future<void> _startReplay() async {
    if (!preferences.replayBuffer || _replay != null || running == null) return;
    final ReplayBuffer? buffer;
    if (services.replay case final made?) {
      buffer = made(preferences.replaySeconds);
    } else {
      // The graphics card's encoder when one works, and the game's sound with the picture.
      final encoder = await media.encoders?.encoder;
      final playing = running;
      if (playing == null || !preferences.replayBuffer || _replay != null) return;
      if (waylandCapture != null && encoder == null) return show(T.text('waylandNoEncoder'));
      buffer = _defaultReplay(preferences.replaySeconds, encoder: encoder, sound: media.soundOf(playing.$2.pid));
    }
    if (buffer == null) return;
    _replay = buffer;
    // On X11 it records the screen: the LIVE badge goes first.
    await media.badgeCheck();
    if (_replay != buffer) return;
    if (!await buffer.start()) {
      // Stopped meanwhile (the game ended during the desktop's dialog): nothing to say.
      if (_replay != buffer) return;
      _replay = null;
      final problem = waylandCapture?.problem;
      show(T.text(problem?.textKey ?? 'replayFailed'));
    }
    notifyListeners();
  }

  Future<void> _stopReplay() async {
    final buffer = _replay;
    _replay = null;
    await buffer?.stop();
  }

  // The phone in games.

  /// Whether a phone or a browser pad is connected.
  bool get phonesConnected => (remote?.connectedDevices.isNotEmpty ?? false) || browserPlay.pads.isNotEmpty;

  /// The engine in use cannot read the phones (upstream's release builds and nightlies).
  bool get phoneEngineMissing => EngineModel.readsPhone(toolkitVersion) == false;

  /// The switch was offered this run: a phone that comes again is not asked about again.
  bool _phoneEngineAsked = false;

  /// A game on upstream's engine ran with a phone connected: the switch is offered when it ends.
  bool _phoneEngineAfterGame = false;

  /// With a phone or a browser pad connected and upstream's engine in use: Switch to the
  /// AnyPS5-ARM Engine over Home, once a run ([again] from the toast, any time). Never over a game
  /// or another screen; the engine stays as it is until the press.
  void askPhoneEngine({bool again = false}) {
    if (!phoneEngineMissing || (_phoneEngineAsked && !again)) return;
    if (running != null || starting != null) return;
    if (overlay != null && overlay != Layer.phoneEngine) return;
    _phoneEngineAsked = true;
    // The download's size, once AnyPS5-ARM's releases answer.
    if (!engine.armChecked) unawaited(engine.checkArm(quiet: true));
    if (overlay != Layer.phoneEngine) open(Layer.phoneEngine);
    _changed();
  }

  /// Switch to the AnyPS5-ARM Engine: downloads it when it is not on disk and uses it. Installed
  /// games then offer Update and Play, which unlocks them again with it.
  Future<void> switchToArmForPhone() async {
    final done = await engine.switchToArm();
    if (done && overlay == Layer.phoneEngine) closeOverlay();
    _changed();
  }

  /// The rows of Switch to the AnyPS5-ARM Engine.
  List<PanelRow> phoneEngineRows() {
    final pending = engine.downloading;
    final package = engine.armPackage;
    final have = engine.downloaded.any((kit) => EngineModel.isArm(kit.version));
    return [
      PanelRow(
        id: 'phoneEngineWhy',
        title: T.text('phoneEngineWhy'),
        detail: T.text('phoneEngineWhyDetail'),
        kind: const InfoRow(''),
      ),
      if (pending != null)
        PanelRow(
          id: 'phoneEngineSwitch',
          title: T.format('engineDownloading', [
            EngineModel.packageName(pending),
            ((engine.progress?.fraction ?? 0) * 100).floor(),
          ]),
          detail: '${engine.progressText()} · ${T.text('engineStop')}',
          kind: ActionRow(engine.cancel),
        )
      else
        PanelRow(
          id: 'phoneEngineSwitch',
          title: T.text('phoneEngineSwitch'),
          detail: have
              ? T.text('phoneEngineSwitchHave')
              : package == null
              ? T.text('phoneEngineSwitchDetail')
              : T.format('phoneEngineSwitchSize', [byteText(package.size)]),
          kind: ActionRow(() => unawaited(switchToArmForPhone())),
        ),
      PanelRow(id: 'phoneEngineLater', title: T.text('phoneEngineLater'), kind: ActionRow(closeOverlay)),
    ];
  }

  /// Whether [game]'s engine reads the phones, from the engine it was unlocked with (the unlock
  /// puts that engine's libraries in the game's folder): null when the launcher cannot tell.
  bool? phoneReaches(Game game) => EngineModel.readsPhone(records[game.id]?.toolkit);

  /// How long a game may stay quiet on the phones' bridges before the launcher says the phone
  /// does not reach it. The engine says hello every second once the game's window is open.
  Duration phoneAnswerWait = const Duration(seconds: 30);

  String? _phoneToldFor;
  Timer? _phoneAnswerTimer;

  /// The game log's line on the phones at a start.
  String _phoneReachNote(Game game) {
    final engine = switch (phoneReaches(game)) {
      true => 'AnyPS5-ARM engine, reads them',
      false => "upstream's engine, which does not read them",
      null => 'engine of unknown kind',
    };
    return '${remote?.connectedDevices.length ?? 0} phone(s), ${browserPlay.pads.length} browser pad(s), $engine';
  }

  /// With a phone connected, a game whose engine cannot read it is said at once (upstream's has
  /// no phone input, so its pad went nowhere without a word). Any other game is said only when
  /// it stayed quiet on the phones' bridges for [phoneAnswerWait]. Said once a game.
  void _checkPhoneReach(Game game) {
    if (_phoneToldFor == game.id || !phonesConnected) return;
    if (phoneReaches(game) == false) return _phoneCannotReach(game, T.text('phoneUpstreamGame'));
    _phoneAnswerTimer?.cancel();
    _phoneAnswerTimer = Timer(phoneAnswerWait, () {
      if (running?.$1 != game || _phoneToldFor == game.id || !phonesConnected) return;
      if (remote?.gameHeard ?? true) return;
      _phoneCannotReach(game, T.text('phoneNoAnswer'));
    });
  }

  /// The toast, and over the game a desktop notice: the game's window hides the toast. On
  /// upstream's engine a click on the toast (or the end of the game) offers the switch.
  void _phoneCannotReach(Game game, String text) {
    _phoneToldFor = game.id;
    _phoneAnswerTimer?.cancel();
    final upstream = phoneEngineMissing;
    if (upstream) _phoneEngineAfterGame = true;
    show(text, onTap: upstream ? () => askPhoneEngine(again: true) : null);
    if (launcherInFront) return;
    unawaited(() async {
      if (await _noticeCard(text, null, Icons.smartphone_rounded)) return;
      if (!await desktop.notify('AnyPS5', text)) desktopNotify('AnyPS5', text);
    }());
  }

  /// A capture said: the toast, and over the game a desktop notice.
  Future<void> _captureSaid(String text, {required IconData symbol, bool sound = false}) async {
    show(text);
    if (launcherInFront) return;
    if (await _noticeCard(text, null, symbol, sound: sound)) return;
    if (!await desktop.notify('AnyPS5', text)) desktopNotify('AnyPS5', text);
  }

  /// Said as a capture is ([_captureSaid]), with a second line under it, and [symbol] on the card.
  Future<void> notice(String text, {String? detail, IconData symbol = Icons.notifications_rounded}) async {
    show(detail == null ? text : '$text. $detail');
    await noticeOverGame(text, detail: detail, symbol: symbol);
  }

  /// With a game in front, a word the launcher's toast cannot give: the card over the game as on
  /// the Mac, a desktop notice where a card cannot be drawn. [sound] is the card's own cue; a
  /// ring or a shutter already heard stays quiet.
  Future<void> noticeOverGame(
    String text, {
    String? detail,
    IconData symbol = Icons.notifications_rounded,
    bool sound = true,
  }) async {
    if (launcherInFront) return;
    if (await _noticeCard(text, detail, symbol, sound: sound)) return;
    if (!await desktop.notify(text, detail ?? 'AnyPS5')) desktopNotify(text, detail ?? 'AnyPS5');
  }

  /// The game's window now, into its gallery (Share held); the picture's path.
  Future<String?> takeScreenshot() async {
    final playing = running;
    if (playing == null) return null;
    final (game, run) = playing;
    final frame = await desktop.captureGame(run.pid);
    if (frame == null) {
      unawaited(_captureSaid(T.text('screenshotFailed'), symbol: Icons.error_outline_rounded, sound: true));
      return null;
    }
    final path = Screenshots.shotPath(picturesFolder, game, DateTime.now());
    try {
      await Isolate.run(() {
        File(path)
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync(PngEncoder.rgba(frame.width, frame.height, frame.pixels));
      });
    } on Object {
      unawaited(_captureSaid(T.text('screenshotFailed'), symbol: Icons.error_outline_rounded, sound: true));
      return null;
    }
    sounds.play(Cue.unlocked);
    unawaited(_captureSaid(T.text('screenshotSaved'), symbol: Icons.photo_camera_rounded));
    return path;
  }

  /// Share: the last seconds from the replay buffer as a clip in the game's gallery; with the
  /// buffer off, a screenshot.
  Future<String?> saveClip() async {
    final playing = running;
    if (playing == null) return null;
    final buffer = _replay;
    if (buffer == null || !buffer.running) return takeScreenshot();
    final saved = await buffer.save(Screenshots.clipPath(picturesFolder, playing.$1, DateTime.now()));
    if (saved != null) sounds.play(Cue.unlocked);
    unawaited(
      _captureSaid(
        saved == null ? T.text('clipFailed') : T.format('clipSaved', [replayLengthText(buffer.seconds)]),
        symbol: saved == null ? Icons.error_outline_rounded : Icons.movie_rounded,
        sound: saved == null,
      ),
    );
    return saved;
  }

  static String replayLengthText(int seconds) =>
      seconds < 60 ? T.format('replaySeconds', [seconds]) : T.format('replayMinutes', [seconds ~/ 60]);

  // The launcher's window.

  /// Whether the launcher is full screen (Settings › Appearance › Full Screen; F11).
  bool get launcherFullscreen => preferences.launcherFullscreen ?? true;

  Future<void> toggleFullscreen() => setLauncherFullscreen(!launcherFullscreen);

  /// The choice is kept only when the window made it: Settings never says full screen over a
  /// window (with no window to ask, in tests, the choice alone).
  Future<void> setLauncherFullscreen(bool on) async {
    if (services.window != null && !await _setWindowFullscreen(on)) {
      _changed();
      return;
    }
    preferences.launcherFullscreen = on;
    savePreferences();
    _changed();
  }

  /// At launch: full screen the first time, then as the user left it.
  Future<void> applyLauncherWindow() => _setWindowFullscreen(launcherFullscreen);

  Future<bool> _setWindowFullscreen(bool on) async {
    final window = services.window;
    if (window == null) return false;
    final took = Stopwatch()..start();
    final done = await window.setFullscreen(on);
    // In a report's last seconds: a window that took long to change, or would not.
    _windowLine(
      '${on ? 'full screen' : 'windowed'} asked: ${done ? 'done' : 'refused'} in ${took.elapsedMilliseconds} ms',
    );
    if (done) {
      windowFullscreen = on;
      _changed();
    }
    return done;
  }

  /// The system made the window full screen or a window (the title bar's Maximize, a double
  /// click on it, Win+Up, the window manager): the window buttons and Settings follow, and the
  /// next start keeps it.
  void windowChangedFullscreen(bool on) {
    _windowLine('${on ? 'full screen' : 'windowed'} by the system');
    windowFullscreen = on;
    if (preferences.launcherFullscreen != on) {
      preferences.launcherFullscreen = on;
      savePreferences();
    }
    _changed();
  }

  void _windowLine(String what) => addRecentLine('${DateTime.now().toIso8601String()} window $what');

  /// Whether the window is full screen now, with no title bar of the system's: set as the
  /// launcher makes it so (and by main.dart for Steam's --fullscreen).
  bool windowFullscreen = false;

  /// The launcher's own window buttons wait at the top edge: full screen, the setting on, not
  /// in Steam's Game Mode (gamescope has no windows to go back to).
  bool get showsWindowButtons => windowFullscreen && preferences.windowButtons && !steamLaunch.gameMode;

  /// The window buttons' Minimize.
  void minimizeLauncher() => unawaited(services.window?.minimize());

  static const libraryColumns = 6;

  /// The top bar's buttons, left to right.
  static const topLayers = [
    Layer.library,
    Layer.settings,
    Layer.friends,
    Layer.messages,
    Layer.party,
    Layer.notifications,
  ];

  /// The bell (the last) shows only while signed in to AnyTogether.
  int get topButtons => together.signedIn ? topLayers.length : topLayers.length - 1;

  void _moveLibrary(int delta) {
    final next = (libraryIndex + delta).clamp(0, games.isEmpty ? 0 : games.length - 1);
    if (next == libraryIndex) return;
    libraryIndex = next;
    sounds.play(Cue.move);
    _changed();
  }

  void _moveFocus(HomeFocus next) {
    if (next == focus) return;
    focus = next;
    sounds.play(Cue.move);
    _changed();
  }

  // Panels.

  List<PanelCategory> panelCategories() {
    final game = selectedGame;
    switch (overlay) {
      case Layer.settings:
        return _searchedSettings(_settingsCategories());
      case Layer.gameSettings when game != null:
        return [PanelCategory(id: 'game', title: game.name, rows: _gameRows(game))];
      case Layer.controls when game != null:
        return [PanelCategory(id: 'controls', title: game.name, rows: _controlRows(game))];
      case Layer.advanced when game != null:
        return [PanelCategory(id: 'advanced', title: game.name, rows: _advancedRows(game))];
      case Layer.confirmUninstall when game != null:
        return [
          PanelCategory(
            id: 'confirm',
            title: T.text('uninstall'),
            rows: [
              PanelRow(
                id: 'confirm',
                title: T.text('uninstall'),
                // What goes, then what stays: the saves and trophies are kept.
                detail: '${T.text('uninstallConfirm')} ${T.text('uninstallKeeps')}',
                wraps: true,
                kind: ActionRow(() {
                  unawaited(uninstall(game));
                  closeOverlay();
                }, destructive: true),
              ),
              PanelRow(id: 'cancel', title: T.text('cancel'), kind: ActionRow(closeOverlay)),
            ],
          ),
        ];
      case Layer.confirmDeleteGame:
        final ask = deletion.ask;
        if (ask == null) return const [];
        return [
          PanelCategory(
            id: 'deleteGame',
            title: T.format(ask.permanent ? 'deleteGameForeverTitle' : 'deleteGameTitle', [ask.game.name]),
            rows: [
              // Cancel first: where the focus starts.
              PanelRow(id: 'cancel', title: T.text('cancel'), kind: ActionRow(deletion.cancel)),
              PanelRow(
                id: 'delete',
                title: T.text(ask.permanent ? 'deleteGameForever' : 'deleteGame'),
                kind: ActionRow(deletion.confirm, destructive: true),
              ),
            ],
          ),
        ];
      case Layer.copyWarning:
        final warning = copyWarning;
        if (warning == null) return const [];
        return [
          PanelCategory(
            id: 'copy',
            title: warning.shortage == null ? T.text('copyWarningTitle') : T.text('noSpaceTitle'),
            rows: _copyWarningRows(warning),
          ),
        ];
      case Layer.gameFiles:
        return [PanelCategory(id: 'files', title: files.title, rows: files.rows())];
      case Layer.friends:
        return [PanelCategory(id: 'friends', title: T.text('friendsTitle'), rows: together.friendRows())];
      case Layer.party:
        return [PanelCategory(id: 'party', title: T.text('partyTitle'), rows: together.partyRows())];
      case Layer.notifications:
        return [
          PanelCategory(id: 'notifications', title: together.notificationsSubtitle, rows: together.notificationRows()),
        ];
      case Layer.compat:
        return [PanelCategory(id: 'compat', title: T.text('socialCompatSubtitle'), rows: together.compatRows())];
      case Layer.findPlayers:
        return together.findPlayersCategories();
      case Layer.gameHub:
        return together.hubCategories();
      case Layer.lfgPost:
        return [PanelCategory(id: 'post', title: together.findState.draftName, rows: together.lfgPostRows())];
      case Layer.family:
        return [PanelCategory(id: 'family', title: T.text('familyTitle'), rows: together.family.rows())];
      case Layer.crashReport:
        return [PanelCategory(id: 'report', title: T.text('reportKicker'), rows: crash.rows())];
      case Layer.themes:
        return [PanelCategory(id: 'themes', title: T.text('themes'), rows: themeRows())];
      case Layer.themeStudio:
        return [PanelCategory(id: 'studio', title: T.text('themeStudio'), rows: studioRows())];
      case Layer.showcaseEdit:
        return [
          PanelCategory(
            id: 'showcase',
            title: T.format('showcasePinned', [together.showcasePins?.count ?? 0]),
            rows: together.showcaseRows(),
          ),
        ];
      case Layer.countryPicker:
        return [PanelCategory(id: 'country', title: T.text('togetherCountryChoose'), rows: together.countryRows())];
      case Layer.profileTheme:
        // Under the heading Profile theme: where the themes come from.
        return [PanelCategory(id: 'profileTheme', title: T.text('themesHub'), rows: together.profileThemeRows())];
      case Layer.friendOptions:
        return [
          PanelCategory(
            id: 'friend',
            title: together.chosen?.person.displayName ?? T.text('friendsTitle'),
            rows: together.friendOptionRows(),
          ),
        ];
      case Layer.phoneEngine:
        return [PanelCategory(id: 'phoneEngine', title: T.text('phoneEngineTitle'), rows: phoneEngineRows())];
      case Layer.updateRequired when together.account.tooOld != null:
        return [
          PanelCategory(
            id: 'updateRequired',
            title: T.text('requiredTitle'),
            rows: updates.requiredRows(together.account.tooOld!),
          ),
        ];
      case Layer.quickMenu when running != null:
        return [
          PanelCategory(
            id: 'quickMenu',
            title: running!.$1.name,
            rows: [
              PanelRow(id: 'resume', title: T.text('quickResume'), kind: ActionRow(resumeGame)),
              // Settings › Battery & Heat: the profile that holds lifted for now.
              if (powerWatch.canUndo)
                PanelRow(
                  id: 'powerUndo',
                  title: powerWatch.undoTitle,
                  detail: T.text('powerQuickUndoDetail'),
                  kind: ActionRow(powerWatch.undo),
                ),
              PanelRow(
                id: 'gameSettings',
                title: T.text('gameSettings'),
                kind: ActionRow(() => open(Layer.gameSettings)),
              ),
              ...media.gameRows(),
              ...sharePlay.rows(),
              // The party next to the game playing: who is in it, who plays another one (Join).
              ...together.partyGameRows(),
              ...nowPlaying.quickRows(),
              PanelRow(
                id: 'closeGame',
                title: T.text('quickCloseGame'),
                // Asked first, as PS held asks.
                kind: ActionRow(() => open(Layer.closeGame), destructive: true),
              ),
            ],
          ),
        ];
      case Layer.closeGame when running != null:
        return [
          PanelCategory(
            id: 'closeGame',
            title: T.format('closeGameTitle', [running!.$1.name]),
            rows: [
              PanelRow(
                id: 'confirmClose',
                title: T.text('quickCloseGame'),
                detail: T.text('closeGameDetail'),
                kind: ActionRow(closeRunningGame, destructive: true),
              ),
              PanelRow(id: 'cancel', title: T.text('cancel'), kind: ActionRow(resumeGame)),
            ],
          ),
        ];
      case Layer.profileMenu:
        return [
          PanelCategory(
            id: 'profileMenu',
            title: currentProfile?.name ?? T.text('profileMenuTitle'),
            rows: profileMenuRows(),
          ),
        ];
      case Layer.signIn:
        return [
          PanelCategory(
            id: 'signIn',
            title: T.text(switch (profileFlow.origin) {
              ProfileOrigin.firstStart || ProfileOrigin.adding => 'profileSignInNew',
              ProfileOrigin.goingOnline => 'profileSignInOnline',
              ProfileOrigin.signingInAgain => 'profileSignInAgain',
            }),
            rows: together.signInRows(),
          ),
        ];
      case Layer.homeMenu:
        return [
          PanelCategory(
            id: 'homeMenu',
            title: 'AnyPS5',
            rows: [
              PanelRow(
                id: 'switchProfile',
                title: T.text('switchProfile'),
                detail: switch (profiles.book.profiles.length - 1) {
                  0 => T.text('profileAddSomeone'),
                  1 => T.text('profileOthersOne'),
                  final others => T.format('profileOthers', [others]),
                },
                // Not while a game plays: it is closed first.
                kind: ActionRow(() => openProfilePicker()),
              ),
              PanelRow(
                id: 'quit',
                title: T.text('quitLauncher'),
                detail: running == null ? null : T.format('quitLauncherGame', [running!.$1.name]),
                kind: ActionRow(quitLauncher, destructive: true),
              ),
            ],
          ),
        ];
      case Layer.launcherReport when launcherProblem != null:
        final problem = launcherProblem!;
        return [
          PanelCategory(
            id: 'launcherReport',
            title: switch (problem.kind) {
              LauncherProblemKind.crash when problem.whileClosing => T.text('launcherReportCrashClosing'),
              LauncherProblemKind.crash => T.text('launcherReportCrash'),
              LauncherProblemKind.hang when problem.recovered => T.format('launcherReportHang', [
                problem.stalledFor?.inSeconds ?? LauncherHealth.stall.inSeconds,
              ]),
              LauncherProblemKind.hang => T.text('launcherReportHangEnded'),
            },
            rows: _launcherReportRows(),
          ),
        ];
      case Layer.cloudQuestion:
        return [
          PanelCategory(id: 'cloudQuestion', title: saveSync.question?.title ?? '', rows: saveSync.questionRows()),
        ];
      case Layer.cloudStorage:
        return [PanelCategory(id: 'cloudStorage', title: T.text('cloudStorageSubtitle'), rows: saveSync.storageRows())];
      case Layer.confirmQuit:
        return [
          PanelCategory(
            id: 'confirmQuit',
            title: T.text('quitQuestion'),
            rows: [
              PanelRow(id: 'cancel', title: T.text('cancel'), kind: ActionRow(closeOverlay)),
              PanelRow(
                id: 'quit',
                title: T.text('quit'),
                detail: running == null ? null : T.format('quitLauncherGame', [running!.$1.name]),
                kind: ActionRow(quitLauncher, destructive: true),
              ),
            ],
          ),
        ];
      case Layer.updateChoice when game != null:
        return [
          PanelCategory(
            id: 'update',
            title: T.text('updateAvailable'),
            rows: [
              PanelRow(
                id: 'update',
                title: T.text('updateAndPlay'),
                detail: switch (engine.latestPackage) {
                  final ToolkitPackage newest when engine.updateAvailable && currentSettings(game).engine == null =>
                    T.format('engineUpdateAndPlayDetail', ['v${newest.version}', byteText(newest.size)]),
                  _ => T.text('updateAndPlayDetail'),
                },
                kind: ActionRow(() {
                  closeOverlay();
                  updateAndPlay(game);
                }),
              ),
              PanelRow(
                id: 'play',
                title: T.text('playNow'),
                detail: T.text('playNowDetail'),
                kind: ActionRow(() {
                  closeOverlay();
                  // The copy as it is, whatever engine made it (also after a rebuild that failed
                  // and left the copy in place).
                  failures.remove(game.id);
                  unawaited(play(game, asItIs: true));
                }),
              ),
            ],
          ),
        ];
      case Layer.joinBlocked:
        final block = together.joinBlock;
        if (block == null) return const [];
        return [
          PanelCategory(
            id: 'joinBlocked',
            title: T.text('togetherBlockedTitle'),
            rows: together.joinBlockedRows(block),
          ),
        ];
      case Layer.joinOrHost:
        final choice = together.joinChoice;
        if (choice == null) return const [];
        return [PanelCategory(id: 'joinOrHost', title: choice.game.name, rows: together.joinOrHostRows(choice))];
      default:
        return const [];
    }
  }

  /// The copy panel: the room the unlock lacks (when it does), why the game's files would be
  /// copied (when they would), and the ways out.
  List<PanelRow> _copyWarningRows(({Game game, int bytes, SpaceShortage? shortage, int? needed, int? free}) warning) {
    final windows = system == HostSystem.windows;
    final size = byteText(warning.bytes);
    final shortage = warning.shortage;
    final copying = warning.bytes > 0 && (shortage == null || shortage.copying);
    void dismiss() {
      closeOverlay();
      copyWarning = null;
    }

    return [
      if (shortage != null)
        PanelRow(
          id: 'space',
          title: T.format('noSpaceAmount', [byteText(shortage.needed), byteText(shortage.free)]),
          kind: InfoRow(
            '${T.text('noSpaceNothingWritten')}\n${copying ? T.format('noSpaceCopying', [size]) : T.text('noSpaceWhy')}',
          ),
        ),
      if (copying)
        PanelRow(
          id: 'why',
          title: warning.game.name,
          kind: InfoRow(
            T.format(windows ? 'copyWarningWindows' : 'copyWarningLinux', [size]) +
                (shortage == null && warning.needed != null && warning.free != null
                    ? '\n${T.format('copySpace', [byteText(warning.needed!), byteText(warning.free!)])}'
                    : ''),
          ),
        ),
      if (copying)
        PanelRow(
          id: 'sameDrive',
          title: T.text('copyFixFolder'),
          detail: T.text('copyFixFolderDetail'),
          kind: ActionRow(() {
            dismiss();
            unawaited(chooseFirstGamesFolder());
          }),
        )
      else
        PanelRow(
          id: 'otherDrive',
          title: T.text('noSpaceFolder'),
          detail: T.text('noSpaceFolderDetail'),
          kind: ActionRow(() {
            dismiss();
            unawaited(chooseFirstGamesFolder());
          }),
        ),
      if (windows && copying)
        PanelRow(
          id: 'developerMode',
          title: T.text('copyFixDeveloperMode'),
          detail: T.text('copyFixDeveloperModeDetail'),
          kind: ActionRow(() {
            services.openUrl?.call(Uri.parse('ms-settings:developers'));
            dismiss();
            show(T.text('copyFixDeveloperModeThen'));
          }),
        ),
      if (shortage == null)
        PanelRow(
          id: 'copyAnyway',
          title: T.text('copyAnyway'),
          detail: T.format('copyAnywayDetail', [size]),
          kind: ActionRow(() {
            dismiss();
            unlock(warning.game, copy: true);
          }),
        )
      else
        PanelRow(
          id: 'retry',
          title: T.text('noSpaceRetry'),
          detail: T.text('noSpaceRetryDetail'),
          kind: ActionRow(() {
            dismiss();
            unlock(warning.game, copy: true);
          }),
        ),
      PanelRow(
        id: 'cancel',
        title: T.text('cancel'),
        kind: ActionRow(() {
          dismiss();
          if (_playAfterInstall == warning.game.id) _playAfterInstall = null;
          if (afterRebuild?.$1 == warning.game.id) afterRebuild = null;
        }),
      ),
    ];
  }

  List<PanelCategory> _settingsCategories() {
    final kit = toolkit;
    return [
      PanelCategory(
        id: 'appearance',
        title: T.text('appearance'),
        rows: [
          // The theme, built-in or custom (themes_model.dart).
          ...appearanceThemeRows(),
          // Only Glass has transparency to reduce.
          if (look == LookStyle.glass)
            PanelRow(
              id: 'transparency',
              title: T.text('reduceTransparency'),
              detail: T.text('reduceTransparencyDetail'),
              kind: ToggleRow(preferences.reduceTransparency, (value) {
                preferences.reduceTransparency = value;
                savePreferences();
              }),
            ),
          // How much of the desktop shows through Glass's window, where the system can show it.
          if (look == LookStyle.glass && backdrop.kind.seeThrough && !preferences.reduceTransparency)
            PanelRow(
              id: 'glassTransparency',
              title: T.text('glassTransparency'),
              detail: T.text(backdrop.kind.blurs ? 'glassTransparencyDetail' : 'glassTransparencySharp'),
              kind: StepperRow(
                value: preferences.glassTransparency ?? GlassWindow.defaultTransparency,
                min: 0,
                max: 100,
                step: 10,
                format: _percent,
                set: (value) {
                  preferences.glassTransparency = value == GlassWindow.defaultTransparency ? null : value;
                  savePreferences();
                },
              ),
            ),
          // A custom theme brings its own accent.
          if (activeDesign == null)
            PanelRow(
              id: 'accent',
              title: T.text('accent'),
              kind: ChoiceRow([for (final accent in Accent.values) accent.title], builtInAccent.index, (index) {
                preferences.accent = Accent.values[index].name;
                savePreferences();
              }),
            ),
          // Themes and the Theme Studio.
          ...appearanceThemeLinks(),
          // Over the see-through window the picture is laid only when asked for.
          if (glassWindow.seeThrough)
            PanelRow(
              id: 'glassArtwork',
              title: T.text('glassArtwork'),
              detail: T.text('glassArtworkDetail'),
              kind: ToggleRow(preferences.glassArtwork, (value) {
                preferences.glassArtwork = value;
                savePreferences();
              }),
            )
          else
            PanelRow(
              id: 'artwork',
              title: T.text('gameArtwork'),
              kind: ToggleRow(preferences.gameArtwork, (value) {
                preferences.gameArtwork = value;
                savePreferences();
              }),
            ),
          // Background (the theme's animation, a picture or a video) and Menu Music.
          ...appearanceMediaRows(),
          PanelRow(
            id: 'fullscreen',
            title: T.text('launcherFullscreen'),
            detail: T.format('launcherFullscreenDetail', [
              keyLabel(preferences.shortcuts[LauncherAction.toggleFullscreen].key) ?? '—',
            ]),
            kind: ToggleRow(launcherFullscreen, (value) => unawaited(setLauncherFullscreen(value))),
          ),
          PanelRow(
            id: 'windowButtons',
            title: T.text('windowButtons'),
            detail: T.text('windowButtonsDetail'),
            kind: ToggleRow(preferences.windowButtons, (value) {
              preferences.windowButtons = value;
              savePreferences();
            }),
          ),
          PanelRow(
            id: 'motion',
            title: T.text('motion'),
            kind: ChoiceRow([T.text('motionFull'), T.text('motionReduced')], preferences.reducedMotion ? 1 : 0, (
              index,
            ) {
              preferences.reducedMotion = index == 1;
              Motion.reduced = preferences.reducedMotion || powerWatch.dimmed;
              savePreferences();
            }),
          ),
        ],
      ),
      PanelCategory(
        id: 'library',
        title: T.text('library'),
        rows: [
          ...folderRows(),
          PanelRow(id: 'addFolder', title: T.text('addFolder'), kind: ActionRow(() => unawaited(addGamesFolder()))),
          PanelRow(
            id: 'addGameFile',
            title: T.text('addGameFile'),
            detail: T.text('addGameFileDetail'),
            kind: ActionRow(() => unawaited(files.addGameFile())),
          ),
          PanelRow(id: 'rescan', title: T.text('rescan'), kind: ActionRow(rescan)),
          PanelRow(
            id: 'prepareNewGames',
            title: T.text('prepareNewGames'),
            detail: T.text('prepareNewGamesDetail'),
            kind: ToggleRow(preferences.prepareNewGames, (value) {
              preferences.prepareNewGames = value;
              savePreferences();
              _stepPrepare();
            }),
          ),
          _retroLibraryRow(),
        ],
      ),
      PanelCategory(id: 'engine', title: T.text('engine'), rows: engine.settingsRows()),
      PanelCategory(id: 'profiles', title: T.text('profilesCategory'), rows: profileRows()),
      PanelCategory(id: 'together', title: 'AnyTogether', rows: together.settingsRows()),
      PanelCategory(
        id: 'phone',
        title: T.text('phones'),
        rows: [
          PanelRow(
            id: 'server',
            title: T.text('phoneServer'),
            detail: T.text('phoneServerDetail'),
            kind: ToggleRow(preferences.phoneServer, (value) {
              preferences.phoneServer = value;
              savePreferences();
              unawaited(value ? startPhoneServer() : stopPhoneServer());
            }),
          ),
          // Upstream's engine has no phone input: said here before a game shows it.
          if (preferences.phoneServer && phoneEngineMissing)
            PanelRow(
              id: 'phoneUpstream',
              title: T.text('phoneUpstream'),
              detail: engine.downloading != null
                  ? T.format('engineDownloading', [
                      EngineModel.packageName(engine.downloading!),
                      ((engine.progress?.fraction ?? 0) * 100).floor(),
                    ])
                  : T.text('phoneUpstreamSwitchDetail'),
              kind: ActionRow(() => unawaited(engine.switchToArm())),
            ),
          if (preferences.phoneServer) ...browserPlay.settingsRows(),
          if (remote?.port case final int port)
            PanelRow(
              id: 'address',
              title: T.text('phoneAddress'),
              kind: InfoRow('${services.computerName ?? Platform.localHostname} · $port'),
            ),
          // The phones that are paired, which of them are connected now, as on the Mac.
          if (remote case final RemoteServer server)
            PanelRow(
              id: 'phones',
              title: T.text('phones'),
              kind: InfoRow(
                server.devices.all.isEmpty
                    ? T.text('phonesNone')
                    : server.connectedDeviceIds.isEmpty
                    ? ''
                    : T.format('phonesConnectedCount', [server.connectedDeviceIds.toSet().length]),
              ),
            ),
          for (final device in remote?.devices.all ?? const <PairedDevice>[])
            PanelRow(
              id: 'device-${device.id}',
              title: PhoneLabel.title(device.name),
              detail: T.text(
                remote?.connectedDeviceIds.contains(device.id) ?? false ? 'phoneRemoveOnline' : 'phoneRemove',
              ),
              icon: PhoneLabel.icon(device.name),
              kind: ActionRow(() {
                remote?.devices.remove(device.id);
                _changed();
              }, destructive: true),
            ),
        ],
      ),
      PanelCategory(
        id: 'general',
        title: T.text('behaviour'),
        rows: [
          PanelRow(
            id: 'language',
            title: T.text('language'),
            kind: ChoiceRow(
              [for (final language in T.languages) language.displayName],
              T.languages.indexOf(T.language),
              (index) {
                T.language = T.languages[index];
                preferences.language = T.language.code;
                savePreferences();
              },
            ),
          ),
          PanelRow(id: 'profile', title: T.text('profileName'), kind: InfoRow(preferences.profileName)),
          PanelRow(
            id: 'launcherVolume',
            title: T.text('launcherVolume'),
            detail: T.text('launcherVolumeDetail'),
            kind: StepperRow(
              value: launcherVolume,
              min: 0,
              max: 100,
              step: 5,
              format: _percent,
              slider: true,
              set: (value) {
                preferences.launcherVolume = value;
                _applySound();
                savePreferences();
              },
            ),
          ),
          PanelRow(
            id: 'sounds',
            title: T.text('sounds'),
            kind: StepperRow(
              value: preferences.sounds ? preferences.soundVolume ?? 100 : 0,
              min: 0,
              max: 100,
              step: 10,
              format: _percent,
              slider: true,
              set: (value) {
                preferences.sounds = value > 0;
                if (value > 0) preferences.soundVolume = value;
                _applySound();
                savePreferences();
              },
            ),
          ),
          PanelRow(
            id: 'music',
            title: T.text('gameMusic'),
            detail: T.text('gameMusicDetail'),
            kind: StepperRow(
              value: musicVolume,
              min: 0,
              max: 100,
              step: 10,
              format: _percent,
              slider: true,
              set: (value) {
                preferences.musicVolume = value;
                _applySound();
                savePreferences();
              },
            ),
          ),
          PanelRow(
            id: 'vibration',
            title: T.text('controllerVibration'),
            detail: T.text('controllerVibrationDetail'),
            kind: ToggleRow(preferences.controllerVibration, (value) {
              preferences.controllerVibration = value;
              haptics.enabled = value;
              savePreferences();
              // Turned on from the pad: a pulse at once says what it feels like.
              if (value) vibrate(HapticCue.select);
            }),
          ),
          PanelRow(
            id: 'hide',
            title: T.text('hideWhilePlaying'),
            kind: ToggleRow(preferences.hideWhilePlaying, (value) {
              preferences.hideWhilePlaying = value;
              savePreferences();
            }),
          ),
          PanelRow(
            id: 'pauseOnMenu',
            title: T.text('pauseOnMenu'),
            detail: T.text('pauseOnMenuDetail'),
            kind: ToggleRow(preferences.pauseOnMenu, (value) {
              preferences.pauseOnMenu = value;
              savePreferences();
            }),
          ),
          ...saveSync.settingsRows(),
          PanelRow(
            id: 'hiddenTrophies',
            title: T.text('showHiddenTrophies'),
            detail: T.text('showHiddenTrophiesDetail'),
            kind: ToggleRow(preferences.showHiddenTrophies, (value) {
              preferences.showHiddenTrophies = value;
              savePreferences();
            }),
          ),
          ...discord.settingsRows(),
          ...nowPlaying.settingsRows(),
          PanelRow(
            id: 'checkUpdates',
            title: T.text('checkUpdates'),
            detail: T.text('checkUpdatesDetail'),
            kind: ToggleRow(preferences.checkUpdates, (value) {
              preferences.checkUpdates = value;
              savePreferences();
              // On again: a quiet look at once, as on the Mac.
              if (value) unawaited(updates.periodicCheck());
            }),
          ),
        ],
      ),
      PanelCategory(id: 'steam', title: T.text('steam'), rows: steam.settingsRows()),
      PanelCategory(id: 'controllers', title: T.text('padTitle'), rows: controllers.rows()),
      PanelCategory(id: 'displayDefaults', title: T.text('displayDefaults'), rows: _displayDefaultRows()),
      PanelCategory(id: 'power', title: T.text('powerTitle'), rows: powerWatch.rows()),
      PanelCategory(id: 'presets', title: T.text('presetsTitle'), rows: _presetRows()),
      PanelCategory(id: 'captures', title: T.text('captures'), rows: _captureRows()),
      PanelCategory(id: 'broadcast', title: T.text('broadcastTitle'), rows: media.settingsRows()),
      PanelCategory(id: 'shortcuts', title: T.text('shortcuts'), rows: _shortcutRows()),
      // Fonts are rarely changed: near the end, before About.
      PanelCategory(id: 'fonts', title: T.text('fonts'), rows: fonts.settingsRows()),
      if (preferences.retroLibrary) _standaloneEmulatorSettings(),
      PanelCategory(
        id: 'about',
        title: T.text('about'),
        rows: [
          PanelRow(id: 'about', title: 'AnyPS5', kind: InfoRow(T.text('aboutText'))),
          PanelRow(id: 'aboutFfmpeg', title: 'ffmpeg', kind: InfoRow(T.format('aboutFfmpeg', [FfmpegBuild.version]))),
          PanelRow(
            id: 'toolkitVersion',
            title: T.text('toolkitVersion'),
            kind: InfoRow(kit == null ? '—' : EngineModel.label(kit)),
          ),
          ...updates.aboutRows(),
          ?updates.channelRow(),
          PanelRow(id: 'author', title: T.text('madeBy'), kind: const InfoRow('Utku Halis')),
          PanelRow(
            id: 'github',
            title: 'GitHub',
            detail: 'github.com/${LauncherUpdates.repository}',
            kind: ActionRow(() => services.openUrl?.call(Uri.https('github.com', LauncherUpdates.repository))),
          ),
          PanelRow(
            id: 'upstream',
            title: T.text('builtOn'),
            detail: 'github.com/boykopovar/AnyPS5',
            kind: ActionRow(() => services.openUrl?.call(Uri.https('github.com', 'boykopovar/AnyPS5'))),
          ),
        ],
      ),
    ];
  }

  static String _percent(int value) => value == 0 ? T.text('off') : T.percent(value);

  List<PanelRow> _captureRows() {
    final unavailable = replayUnavailable;
    final share = padLabel(preferences.shortcuts[LauncherAction.saveClip].pad) ?? '—';
    final shot = padLabel(preferences.shortcuts[LauncherAction.screenshot].pad) ?? '—';
    return [
      PanelRow(
        id: 'replayBuffer',
        title: T.text('replayBuffer'),
        detail: unavailable ?? T.text('replayBufferDetail'),
        kind: ToggleRow(preferences.replayBuffer && unavailable == null, (value) {
          if (unavailable != null) return show(unavailable);
          if (value && waylandCapture != null) return unawaited(_turnOnReplayUnderWayland(waylandCapture!));
          preferences.replayBuffer = value;
          savePreferences();
          unawaited(value ? _startReplay() : _stopReplay());
        }),
      ),
      ...ffmpegTool.rows(),
      if (preferences.replayBuffer && unavailable == null)
        PanelRow(
          id: 'replayLength',
          title: T.text('replayLength'),
          kind: ChoiceRow(
            [for (final seconds in ReplayBuffer.lengths) replayLengthText(seconds)],
            ReplayBuffer.lengths.indexOf(preferences.replaySeconds).clamp(0, ReplayBuffer.lengths.length - 1),
            (index) {
              preferences.replaySeconds = ReplayBuffer.lengths[index];
              savePreferences();
              // A new length: the buffer starts again with it.
              if (_replay != null) unawaited(_stopReplay().then((_) => _startReplay()));
            },
          ),
        ),
      PanelRow(
        id: 'screenshotsFolder',
        title: T.text('screenshotsFolder'),
        detail: picturesFolder,
        kind: ActionRow(() => unawaited(chooseScreenshotsFolder())),
      ),
      PanelRow(id: 'showScreenshots', title: T.text('showScreenshots'), kind: ActionRow(showScreenshots)),
      PanelRow(
        id: 'capturesHow',
        title: T.text('capturesHow'),
        kind: InfoRow(
          T.format(preferences.replayBuffer && unavailable == null ? 'capturesHowClip' : 'capturesHowShot', [
            share,
            shot,
          ]),
        ),
      ),
    ];
  }

  List<PanelRow> _shortcutRows() {
    final map = preferences.shortcuts;
    final conflicted = map.conflicted;
    return [
      for (final action in LauncherAction.values)
        PanelRow(
          id: 'shortcut-${action.name}',
          title: shortcutTitle(action),
          detail: conflicted.contains(action)
              ? T.text('shortcutConflict')
              : shortcutCapture == action
              ? T.text('shortcutWaiting')
              : T.text(action.inGame ? 'shortcutInGame' : 'shortcutInLauncher'),
          kind: ShortcutRow(
            key: keyLabel(map[action].key),
            pad: padLabel(map[action].pad),
            capturing: shortcutCapture == action,
            capture: () => startShortcutCapture(action),
          ),
        ),
      PanelRow(id: 'shortcutsHow', title: T.text('shortcutsHow'), kind: InfoRow(T.text('shortcutsHowDetail'))),
      PanelRow(
        id: 'gameControls',
        title: T.text('shortcutsGameButtons'),
        detail: T.text('shortcutsGameButtonsDetail'),
        kind: ActionRow(() {
          if (selectedGame != null) open(Layer.controls);
        }),
      ),
      PanelRow(
        id: 'shortcutsReset',
        title: T.text('shortcutsReset'),
        kind: ActionRow(() {
          preferences.shortcuts = ShortcutMap();
          savePreferences();
          show(T.text('shortcutsResetDone'));
        }, destructive: true),
      ),
    ];
  }

  /// A key as the launcher writes it: "Ctrl+Alt+F11"; null for none.
  static String? keyLabel(KeyCombo? key) {
    if (key == null) return null;
    final logical = LogicalKeyboardKey.findKeyByKeyId(key.key);
    var name = logical?.keyLabel ?? '';
    if (name.trim().isEmpty) name = logical?.debugName ?? '?';
    if (name.length == 1) name = name.toUpperCase();
    return [if (key.control) 'Ctrl', if (key.alt) 'Alt', if (key.shift) 'Shift', name].join('+');
  }

  /// A controller button as the launcher writes it.
  static String padButtonLabel(PadButton button) => switch (button) {
    PadButton.south => 'Cross',
    PadButton.east => 'Circle',
    PadButton.west => 'Square',
    PadButton.north => 'Triangle',
    PadButton.l1 => 'L1',
    PadButton.r1 => 'R1',
    PadButton.l2 => 'L2',
    PadButton.r2 => 'R2',
    PadButton.l3 => 'L3',
    PadButton.r3 => 'R3',
    PadButton.select => 'View',
    PadButton.start => 'Options',
    PadButton.guide => 'PS',
    PadButton.misc => 'Share',
    PadButton.touchpad => T.text('touchpad'),
    PadButton.dpadUp => '${T.text('dpad')} ↑',
    PadButton.dpadDown => '${T.text('dpad')} ↓',
    PadButton.dpadLeft => '${T.text('dpad')} ←',
    PadButton.dpadRight => '${T.text('dpad')} →',
  };

  /// A chord as the launcher writes it: "View+R1", "Share (hold)"; null for none.
  static String? padLabel(PadChord? chord) {
    if (chord == null) return null;
    final names = [
      for (final button in PadButton.values)
        if (chord.buttons.contains(button)) padButtonLabel(button),
    ].join('+');
    return chord.hold ? T.format('shortcutHeld', [names]) : names;
  }

  /// Settings › Default Display: what the games that left their display at Default start with.
  List<PanelRow> _displayDefaultRows() {
    final defaults = preferences.displayDefaults;
    void change(DisplayDefaults next) {
      preferences.displayDefaults = next;
      savePreferences();
    }

    return [
      PanelRow(
        id: 'defaultDisplay',
        title: T.text('display'),
        detail: T.text('displayDefaultsDetail'),
        kind: ChoiceRow([T.text('windowed'), T.text('fullscreen')], defaults.fullscreen ? 1 : 0, (index) {
          change(defaults.copyWith(fullscreen: index == 1));
        }),
      ),
      if (!defaults.fullscreen)
        PanelRow(
          id: 'defaultWindowSize',
          title: T.text('windowSize'),
          kind: StepperRow(
            value: defaults.windowSize,
            min: DisplayDefaults.minimumWindowSize,
            max: 100,
            step: 5,
            format: _percent,
            set: (value) => change(defaults.copyWith(windowSize: value)),
          ),
        ),
      PanelRow(
        id: 'defaultVsync',
        title: T.text('vsync'),
        kind: ToggleRow(defaults.vsync, (value) => change(defaults.copyWith(vsync: value))),
      ),
    ];
  }

  /// A game's Advanced page, as the Mac's advancedRows: the stick dead zones, the mouse as the
  /// camera, the keyboard's slow movement and ramps (all written to the engine's input file at the
  /// next start), the shader cache, its settings file and a reset.
  List<PanelRow> _advancedRows(Game game) {
    final settings = currentSettings(game);
    final tuning = settings.tuning ?? const InputTuning();
    void change(GameSettings next) => saveSettings(game, next);
    String percent(int value) => T.percent(value);
    String times(int value) => '${T.decimal(value / 10, 1)}×';
    String tenths(int value) => T.decimal(value / 10, 1);
    String milliseconds(int value) => value == 0 ? T.text('off') : '$value ms';
    PanelRow tune(
      String id,
      String title,
      String detail,
      int value,
      int min,
      int max,
      int step,
      String Function(int) format,
      InputTuning Function(InputTuning tuning, int value) set,
    ) => PanelRow(
      id: id,
      title: T.text(title),
      detail: T.text(detail),
      kind: StepperRow(
        value: value,
        min: min,
        max: max,
        step: step,
        format: format,
        set: (value) {
          final next = set(settings.tuning ?? const InputTuning(), value);
          // Back to every default: nothing of its own is kept, as the Mac keeps it.
          change(settings.copyWith(tuning: next.lines.isEmpty ? null : next));
        },
      ),
    );
    PanelRow section(String id, String title) => PanelRow(id: id, title: T.text(title), kind: const InfoRow(''));
    return [
      section('sticksSection', 'sectionSticks'),
      tune(
        'leftDeadzone',
        'leftDeadzone',
        'deadzoneDetail',
        tuning.leftDeadzone,
        0,
        90,
        2,
        percent,
        (t, v) => t.copyWith(leftDeadzone: v),
      ),
      tune(
        'rightDeadzone',
        'rightDeadzone',
        'deadzoneDetail',
        tuning.rightDeadzone,
        0,
        90,
        2,
        percent,
        (t, v) => t.copyWith(rightDeadzone: v),
      ),
      section('mouseSection', 'sectionMouse'),
      tune(
        'sensitivity',
        'mouseSensitivity',
        'mouseSensitivityDetail',
        tuning.mouseSensitivity,
        1,
        100,
        1,
        times,
        (t, v) => t.copyWith(mouseSensitivity: v),
      ),
      tune(
        'vertical',
        'mouseVertical',
        'mouseVerticalDetail',
        tuning.mouseVerticalScale,
        1,
        100,
        1,
        times,
        (t, v) => t.copyWith(mouseVerticalScale: v),
      ),
      tune(
        'curve',
        'mouseCurve',
        'mouseCurveDetail',
        tuning.mouseCurve,
        2,
        50,
        1,
        tenths,
        (t, v) => t.copyWith(mouseCurve: v),
      ),
      tune(
        'offset',
        'mouseMinimum',
        'mouseMinimumDetail',
        tuning.mouseDeadzoneOffset,
        0,
        90,
        2,
        percent,
        (t, v) => t.copyWith(mouseDeadzoneOffset: v),
      ),
      tune(
        'maxSpeed',
        'mouseMaxSpeed',
        'mouseMaxSpeedDetail',
        tuning.mouseMaxSpeed,
        1,
        100,
        1,
        times,
        (t, v) => t.copyWith(mouseMaxSpeed: v),
      ),
      tune(
        'smoothing',
        'mouseSmoothing',
        'mouseSmoothingDetail',
        tuning.mouseSmoothingMs,
        0,
        500,
        5,
        milliseconds,
        (t, v) => t.copyWith(mouseSmoothingMs: v),
      ),
      tune(
        'decay',
        'mouseDecay',
        'mouseDecayDetail',
        tuning.mouseDecayMs,
        5,
        1000,
        5,
        (value) => '$value ms',
        (t, v) => t.copyWith(mouseDecayMs: v),
      ),
      section('keyboardSection', 'sectionKeyboard'),
      tune(
        'modifier',
        'stickModifierScale',
        'stickModifierScaleDetail',
        tuning.stickModifierScale,
        5,
        100,
        5,
        percent,
        (t, v) => t.copyWith(stickModifierScale: v),
      ),
      tune(
        'keyboardRamp',
        'keyboardRamp',
        'keyboardRampDetail',
        tuning.keyboardRampMs,
        0,
        2000,
        50,
        milliseconds,
        (t, v) => t.copyWith(keyboardRampMs: v),
      ),
      tune(
        'triggerRamp',
        'triggerRamp',
        'triggerRampDetail',
        tuning.triggerRampMs,
        0,
        2000,
        50,
        milliseconds,
        (t, v) => t.copyWith(triggerRampMs: v),
      ),
      section('graphicsSection', 'sectionGraphics'),
      PanelRow(
        id: 'shaderCache',
        title: T.text('shaderCache'),
        detail: T.text('shaderCacheDetail'),
        kind: ToggleRow(
          settings.shaderCache ?? true,
          (value) => change(settings.copyWith(shaderCache: value ? null : false)),
        ),
      ),
      section('relinkerSection', 'sectionRelinker'),
      ..._relinkerRows(game, settings, change),
      _optionsRow(
        game,
        id: 'relinkerCustomOptions',
        detail: 'relinkerCustomOptionsDetail',
        saved: settings.customRelinkerOptions,
        check: (text) => checkRelinkerOptions(text).problem,
        apply: (settings, text) => settings.copyWith(customRelinkerOptions: text),
      ),
      section('launchSection', 'sectionLaunch'),
      _optionsRow(
        game,
        id: 'launchOptions',
        detail: 'launchOptionsDetail',
        saved: settings.launchOptions,
        check: (text) => GameLaunchOptions.parse(text).$2,
        apply: (settings, text) => settings.copyWith(launchOptions: text),
      ),
      section('shareSection', 'sectionShare'),
      PanelRow(
        id: 'export',
        title: T.text('exportSettings'),
        detail: T.text('exportSettingsDetail'),
        kind: ActionRow(() => unawaited(exportSettings(game))),
      ),
      PanelRow(
        id: 'import',
        title: T.text('importSettings'),
        detail: T.text('importSettingsDetail'),
        kind: ActionRow(() => unawaited(importSettings(game))),
      ),
      PanelRow(
        id: 'resetAdvanced',
        title: T.text('resetAdvanced'),
        kind: ActionRow(() {
          dropOptionDrafts(game);
          change(
            settings.copyWith(
              tuning: null,
              shaderCache: null,
              relinkerFlags: null,
              customRelinkerOptions: null,
              launchOptions: null,
            ),
          );
        }),
      ),
    ];
  }

  /// What was typed in a game's options row ([_optionsRow]) and failed its check, by game and
  /// row: kept as typed for the field, never saved.
  final Map<String, String> _optionDrafts = {};

  /// Forgets what was typed in [game]'s options rows and not saved (Reset, Import).
  void dropOptionDrafts(Game game) => _optionDrafts.removeWhere((key, _) => key.startsWith('${game.id}\n'));

  /// A field for options typed as text (Custom relinker options, Launch options): each keystroke
  /// is checked; a valid text (or none) is saved at once, one that fails is kept here unsaved and
  /// the row says why.
  PanelRow _optionsRow(
    Game game, {
    required String id,
    required String detail,
    required String? saved,
    required OptionProblem? Function(String text) check,
    required GameSettings Function(GameSettings settings, String? text) apply,
  }) {
    final key = '${game.id}\n$id';
    final draft = _optionDrafts[key];
    final problem = draft == null ? null : check(draft);
    return PanelRow(
      id: id,
      title: T.text(id),
      detail: problem == null
          ? '${T.text(detail)}\n${T.text('customOptionsWarning')}'
          : T.format('optionsNotSaved', [optionProblemText(problem)]),
      kind: TextRow(draft ?? saved ?? '', (text) {
        if (check(text) == null) {
          _optionDrafts.remove(key);
          saveSettings(game, apply(currentSettings(game), text.trim().isEmpty ? null : text));
        } else {
          _optionDrafts[key] = text;
          _changed();
        }
      }),
    );
  }

  /// What an options row says about [problem].
  static String optionProblemText(OptionProblem problem) => switch (problem.kind) {
    OptionProblemKind.openQuote => T.text('optionsQuoteOpen'),
    OptionProblemKind.launcherOption => T.format('relinkerOptionLauncher', [problem.shown]),
    OptionProblemKind.breaksGame => T.format('relinkerOptionBreaks', [problem.shown]),
    OptionProblemKind.hasSwitch => T.format('relinkerOptionSwitch', [problem.shown]),
    OptionProblemKind.unknown => T.format('relinkerOptionUnknown', [problem.shown]),
    OptionProblemKind.needsValue => T.format('relinkerOptionValue', [problem.shown]),
    OptionProblemKind.positional => T.format('relinkerOptionPositional', [problem.shown]),
  };

  /// The relinker options a player can choose for this game, used by its next rebuild. An engine
  /// that lacks one shows why instead of the switch; the rebuild leaves it out either way
  /// (Installer).
  List<PanelRow> _relinkerRows(Game game, GameSettings settings, void Function(GameSettings) change) {
    final kit = toolkitFor(game);
    return [
      for (final flag in RelinkerFlag.values)
        if (kit != null && !kit.supports(flag))
          PanelRow(
            id: 'relinker-${flag.option}',
            title: T.text(_relinkerFlagText(flag).title),
            detail: T.text('relinkerFlagUnavailableDetail'),
            kind: InfoRow(T.text('relinkerFlagUnavailable')),
          )
        else
          PanelRow(
            id: 'relinker-${flag.option}',
            title: T.text(_relinkerFlagText(flag).title),
            detail: T.text(_relinkerFlagText(flag).detail),
            kind: ToggleRow(
              settings.chosenRelinkerFlags.contains(flag),
              (value) => change(settings.withRelinkerFlag(flag, value)),
            ),
          ),
    ];
  }

  static ({String title, String detail}) _relinkerFlagText(RelinkerFlag flag) => switch (flag) {
    RelinkerFlag.traceImports => (title: 'relinkerTraceImports', detail: 'relinkerTraceImportsDetail'),
  };

  List<PanelRow> _gameRows(Game game) {
    if (game.retro case final RetroDisc disc) {
      return [
        PanelRow(
          id: 'retro-emulator',
          title: disc.platform.emulator,
          detail: standaloneEmulator(disc.platform),
          kind: ActionRow(() => unawaited(chooseStandaloneEmulator(disc.platform))),
        ),
        PanelRow(id: 'log', title: T.text('openLog'), kind: ActionRow(() => open(Layer.log))),
      ];
    }
    final settings = currentSettings(game);
    void change(GameSettings next) => saveSettings(game, next);
    final defaults = preferences.displayDefaults;
    final display = settings.withDefaults(defaults);
    String byDefault(String value) => T.format('followDefault', [value]);
    final installed = records.containsKey(game.id);
    final supportsResolution = _factsOf(game).resolution;
    final languages = ConsoleLanguage.all;
    final languageIndex = settings.language == null
        ? 0
        : languages.indexWhere((entry) => entry.$1 == settings.language) + 1;
    final state = stateOf(game);
    // What cannot change while the game is being unlocked, plays or waits for the engine says why
    // in place of its choice; the rest of the page works in every state.
    final busy = switch (state) {
      Installing() || Queued() => T.text('gameBusyUpdating'),
      WaitingForEngine() => T.text('gameBusyEngine'),
      Starting() || Running() || Stopping() => T.text('closeGameFirst'),
      _ => null,
    };
    PanelRow held(String id, String title, PanelRow Function() row) =>
        busy == null ? row() : PanelRow(id: id, title: title, kind: InfoRow(busy));
    final failure = failures[game.id];
    return [
      if (failure != null)
        PanelRow(
          id: 'unlockError',
          title: T.text('unlockError'),
          // The end of the error, as Update from Git shows its own; all of it goes to the clipboard.
          detail: [
            ...failure.split('\n').reversed.take(2).toList().reversed.map((line) => line.trim()),
            T.text('unlockErrorCopy'),
          ].join(' · '),
          kind: ActionRow(() => copyFailure(game)),
        ),
      ..._jobRows(game, state),
      PanelRow(
        id: 'display',
        title: T.text('display'),
        // AnyPS5-ARM's engine opens the game borderless full screen itself (SDL's desktop full
        // screen), and the line says what that is; upstream's ignores the choice: the launcher
        // presses F11 for it, and says so.
        detail: engine.readsDisplaySettingsOf(game) ? T.text('displayBorderless') : T.text('displayUpstream'),
        // Default (Settings › Default Display), then the game's own choices.
        kind: ChoiceRow(
          [
            byDefault(T.text(defaults.fullscreen ? 'fullscreen' : 'windowed')),
            T.text('windowed'),
            T.text('fullscreen'),
          ],
          switch (settings.ownFullscreen) {
            null => 0,
            false => 1,
            true => 2,
          },
          (index) => change(settings.copyWith(fullscreen: index == 0 ? null : index == 2)),
        ),
      ),
      if (!display.fullscreen)
        PanelRow(
          id: 'windowSize',
          title: T.text('windowSize'),
          detail: engine.readsDisplaySettingsOf(game) ? null : T.text('windowSizeUpstream'),
          kind: StepperRow(
            value: display.windowSize,
            min: DisplayDefaults.minimumWindowSize,
            max: 100,
            step: 5,
            // The default's size until the game picks one.
            format: (value) => settings.ownWindowSize == null ? byDefault(T.percent(value)) : T.percent(value),
            set: (value) => change(settings.copyWith(windowSize: value)),
          ),
        ),
      if (supportsResolution)
        // The relinker applies it: an unlock running now goes on with the one it started with.
        held(
          'resolution',
          T.text('resolution'),
          () => PanelRow(
            id: 'resolution',
            title: T.text('resolution'),
            detail: T.text('resolutionReinstall'),
            kind: ChoiceRow(
              [T.text('resolutionDefault'), ...ResolutionPatch.choices],
              settings.resolution == null ? 0 : ResolutionPatch.choices.indexOf(settings.resolution!) + 1,
              (index) => change(settings.copyWith(resolution: index == 0 ? null : ResolutionPatch.choices[index - 1])),
            ),
          ),
        ),
      // Beside Resolution: FSR 1 brings a game resolution below the window's up to the window
      // sharply, its sharpening in tenths of AMD's stops.
      PanelRow(
        id: 'upscaling',
        title: T.text('upscaling'),
        detail: engine.readsDisplaySettingsOf(game) ? T.text('upscalingDetail') : T.text('upscalingUpstream'),
        kind: ChoiceRow(
          [T.text('upscalingBilinear'), T.text('upscalingFsr1')],
          (settings.upscaler ?? Upscaler.bilinear).index,
          (index) => change(settings.copyWith(upscaler: index == 0 ? null : Upscaler.values[index])),
        ),
      ),
      if (settings.upscaler == Upscaler.fsr1)
        PanelRow(
          id: 'fsrSharpness',
          title: T.text('fsrSharpness'),
          detail: T.text('fsrSharpnessDetail'),
          kind: StepperRow(
            value: (settings.sharpness * 10).round(),
            min: 0,
            max: (GameSettings.maximumFsrSharpness * 10).round(),
            step: 1,
            format: (value) => T.decimal(value / 10, 1),
            set: (value) => change(settings.copyWith(fsrSharpness: value / 10)),
          ),
        ),
      PanelRow(
        id: 'vsync',
        title: T.text('vsync'),
        kind: ChoiceRow(
          [byDefault(T.text(defaults.vsync ? 'on' : 'off')), T.text('on'), T.text('off')],
          // Frame generation needs vertical sync: on whatever is chosen while it is on.
          switch (settings.ownVsync) {
            _ when settings.frameGeneration == true => 1,
            null => 0,
            true => 1,
            false => 2,
          },
          (index) => change(settings.copyWith(vsync: index == 0 ? null : index == 1)),
        ),
      ),
      PanelRow(
        id: 'frameGeneration',
        title: T.text('frameGeneration'),
        // Only AnyPS5-ARM's engine makes the frames: said for upstream's, as FSR 1 is.
        detail: !engine.readsDisplaySettingsOf(game)
            ? T.text('frameGenerationUpstream')
            // Settings › Battery & Heat holds it paused now.
            : settings.frameGeneration == true && powerWatch.adjustment.pauseFrameGeneration
            ? T.text('frameGenerationPaused')
            : T.text('frameGenerationDetail'),
        kind: ToggleRow(
          settings.frameGeneration == true,
          (value) => change(settings.copyWith(frameGeneration: value ? true : null)),
        ),
      ),
      if (!settings.followsDisplayDefaults)
        PanelRow(
          id: 'useDisplayDefaults',
          title: T.text('useDisplayDefaults'),
          detail: T.text('useDisplayDefaultsDetail'),
          kind: ActionRow(() => change(settings.followingDisplayDefaults())),
        ),
      PanelRow(
        id: 'overlay',
        title: T.text('overlay'),
        kind: ChoiceRow(
          [
            T.text('overlayOff'),
            T.text('overlayTopLeft'),
            T.text('overlayTopRight'),
            T.text('overlayBottomLeft'),
            T.text('overlayBottomRight'),
          ],
          settings.overlay.index,
          (index) => change(settings.copyWith(overlay: OverlayCorner.values[index])),
        ),
      ),
      if (settings.overlay != OverlayCorner.off)
        PanelRow(
          id: 'overlayStyle',
          title: T.text('overlayStyle'),
          kind: ChoiceRow(
            [T.text('overlayMinimal'), T.text('overlayDetailed')],
            settings.style.index,
            (index) => change(settings.copyWith(overlayStyle: OverlayStyle.values[index])),
          ),
        ),
      PanelRow(
        id: 'language',
        title: T.text('gameLanguage'),
        kind: ChoiceRow(
          [T.text('followLauncher'), for (final entry in languages) entry.$2],
          languageIndex,
          (index) => change(settings.copyWith(language: index == 0 ? null : languages[index - 1].$1)),
        ),
      ),
      ...engine.gameRows(game),
      PanelRow(
        id: 'controls',
        title: T.text('controls'),
        detail: T.text('controlsHint'),
        kind: ActionRow(() => open(Layer.controls)),
      ),
      PanelRow(
        id: 'gallery',
        title: T.text('screenshotsTitle'),
        detail: T.text('screenshotsDetail'),
        kind: ActionRow(openGallery),
      ),
      ...together.gameSocialRows(game),
      // Sticks, the mouse, the keyboard's ramps, the shader cache and the settings file, as on
      // the Mac.
      PanelRow(
        id: 'advanced',
        title: T.text('advanced'),
        detail: T.text('advancedDetail'),
        kind: ActionRow(() => open(Layer.advanced)),
      ),
      PanelRow(
        id: 'link',
        title: T.text('copyLink'),
        detail: ShowGameLink(game.titleId).url,
        kind: ActionRow(() => copyLink(game)),
      ),
      PanelRow(
        id: 'addUpdate',
        title: T.text('addUpdate'),
        detail: T.text('addUpdateDetail'),
        kind: ActionRow(() => unawaited(files.addUpdate(game))),
      ),
      if (installed) ...[
        held(
          'reinstall',
          T.text('reinstall'),
          () => PanelRow(
            id: 'reinstall',
            title: T.text('reinstall'),
            kind: ActionRow(() {
              closeOverlay();
              unlock(game);
            }),
          ),
        ),
        PanelRow(id: 'log', title: T.text('openLog'), kind: ActionRow(() => open(Layer.log))),
        ..._reportRows(game, settings, change),
        PanelRow(
          id: 'folder',
          title: T.text('showInFinder'),
          kind: ActionRow(() => services.openFolder?.call(Installer.installedFolder(game, rootOf(game)!))),
        ),
        PanelRow(id: 'cache', title: T.text('clearShaderCache'), kind: ActionRow(() => clearShaderCache(game))),
        PanelRow(
          id: 'backup',
          title: T.text('backUpSaves'),
          detail: _lastBackupText(game) ?? T.text('backUpSavesDetail'),
          kind: ActionRow(() => backUpSaves(game)),
        ),
        if (_factsOf(game).backups.isNotEmpty)
          held(
            'restore',
            T.text('restoreLatest'),
            () => PanelRow(
              id: 'restore',
              title: T.text('restoreLatest'),
              detail: T.text('restoreSavesDetail'),
              kind: ActionRow(() => restoreLatestSaves(game)),
            ),
          ),
        held(
          'restoreChoose',
          T.text('restoreSaves'),
          () => PanelRow(
            id: 'restoreChoose',
            title: T.text('restoreSaves'),
            detail: T.text('restoreSavesDetail'),
            kind: ActionRow(() => unawaited(restoreChosenSaves(game))),
          ),
        ),
        held(
          'uninstall',
          T.text('uninstall'),
          () => PanelRow(
            id: 'uninstall',
            title: T.text('uninstall'),
            kind: ActionRow(() => open(Layer.confirmUninstall), destructive: true),
          ),
        ),
      ] else ...[
        PanelRow(id: 'log', title: T.text('openLog'), kind: ActionRow(() => open(Layer.log))),
        ..._reportRows(game, settings, change),
      ],
      // Last, after Uninstall: the game itself off the disk, whatever its state.
      held(
        'deleteGame',
        T.text('deleteGame'),
        () => PanelRow(
          id: 'deleteGame',
          title: T.text('deleteGame'),
          detail: T.text('deleteGameDetail'),
          kind: ActionRow(() => deletion.open(game), destructive: true),
        ),
      ),
    ];
  }

  /// First on a game's settings while something happens to it: what, and the way to stop it
  /// (an update or unlock, the engine's build it waits for, the game playing).
  List<PanelRow> _jobRows(Game game, GameState state) => switch (state) {
    Installing(preparing: true) => const [],
    Installing(:final step, :final overall, :final updating) => [
      PanelRow(
        id: 'cancelJob',
        title: T.text(updating ? 'cancelUpdate' : 'cancelUnlock'),
        detail: '${InstallSpan.title(step)} · ${T.percent((overall * 100).round())}',
        kind: ActionRow(() => cancelUnlock(game), destructive: true),
      ),
    ],
    Queued(:final updating, :final waitingForEngine) => [
      PanelRow(
        id: 'cancelJob',
        title: T.text(updating ? 'cancelUpdate' : 'cancelUnlock'),
        detail: T.text(waitingForEngine ? 'waitingForEngine' : 'queued'),
        kind: ActionRow(() => cancelUnlock(game), destructive: true),
      ),
    ],
    // Looking at the remote takes a moment and changes nothing: there is nothing to stop yet.
    WaitingForEngine(job: EngineJob(checking: true)) => [
      PanelRow(id: 'engineJob', title: T.text('engineGitChecking'), kind: const InfoRow('')),
    ],
    WaitingForEngine() => [
      PanelRow(
        id: 'cancelJob',
        title: T.text('engineStopBuild'),
        detail: engine.git.progressText(),
        kind: ActionRow(engine.git.cancel, destructive: true),
      ),
    ],
    Running() => [
      PanelRow(
        id: 'stopGame',
        title: T.text('stopGame'),
        detail: T.text('stopGameDetail'),
        kind: ActionRow(() {
          closeOverlay();
          unawaited(stopRunningGame());
        }, destructive: true),
      ),
    ],
    _ => const [],
  };

  /// The last start's crash report, detailed logging, and (installed) one start with it.
  List<PanelRow> _reportRows(Game game, GameSettings settings, void Function(GameSettings) change) => [
    PanelRow(
      id: 'report',
      title: T.text('lastSessionReport'),
      detail: switch (crash.lastSessions[game.titleId]?.diagnosis) {
        final Diagnosis diagnosis => CrashModel.diagnosisText(diagnosis),
        null => T.text('lastSessionReportDetail'),
      },
      kind: ActionRow(() => unawaited(crash.open(game, afterCrash: false))),
    ),
    PanelRow(
      id: 'trace',
      title: T.text('traceTitle'),
      detail: T.text('traceDetail'),
      kind: ToggleRow(settings.trace == true, (value) => change(settings.copyWith(trace: value ? true : null))),
    ),
    if (stateOf(game) is Installed)
      PanelRow(
        id: 'playTraced',
        title: T.text('reportPlayTraced'),
        detail: T.text('reportPlayTracedDetail'),
        kind: ActionRow(() {
          closeOverlay();
          unawaited(play(game, trace: true));
        }),
      ),
  ];

  /// Controls › Gyro Aiming, first on a game's Controls page: on or off, and while on its
  /// sensitivity, when it aims, invert and its dead zone (GyroAiming).
  List<PanelRow> _gyroRows(Game game, GameSettings settings) {
    final aim = settings.gyro ?? const GyroAiming();
    void change(GyroAiming changed) =>
        saveSettings(game, settings.copyWith(gyro: changed == const GyroAiming() ? null : changed));
    return [
      PanelRow(
        id: 'gyro',
        title: T.text('gyro'),
        detail: T.text('gyroDetail'),
        kind: ToggleRow(aim.enabled, (value) => change(aim.copyWith(enabled: value))),
      ),
      if (aim.enabled) ...[
        PanelRow(
          id: 'gyroSensitivity',
          title: T.text('gyroSensitivity'),
          detail: T.text('gyroSensitivityDetail'),
          kind: StepperRow(
            value: aim.sensitivity,
            min: GyroAiming.sensitivityMin,
            max: GyroAiming.sensitivityMax,
            step: 1,
            format: (value) => T.decimal(value / 10, 1),
            set: (value) => change(aim.copyWith(sensitivity: value)),
          ),
        ),
        PanelRow(
          id: 'gyroActivation',
          title: T.text('gyroActivation'),
          detail: T.text('gyroActivationDetail'),
          kind: ChoiceRow(
            [for (final activation in GyroActivation.values) T.text('gyro_${activation.name}')],
            aim.activation.index,
            (index) => change(aim.copyWith(activation: GyroActivation.values[index])),
          ),
        ),
        PanelRow(
          id: 'gyroInvert',
          title: T.text('gyroInvert'),
          kind: ChoiceRow(
            [for (final invert in GyroInvert.values) T.text('gyroInvert_${invert.name}')],
            aim.invert.index,
            (index) => change(aim.copyWith(invert: GyroInvert.values[index])),
          ),
        ),
        PanelRow(
          id: 'gyroDeadzone',
          title: T.text('gyroDeadzone'),
          detail: T.text('gyroDeadzoneDetail'),
          kind: StepperRow(
            value: aim.deadzone,
            min: 0,
            max: GyroAiming.deadzoneMax,
            step: 1,
            format: (value) => value == 0 ? T.text('off') : '$value°/s',
            set: (value) => change(aim.copyWith(deadzone: value)),
          ),
        ),
      ],
    ];
  }

  List<PanelRow> _controlRows(Game game) {
    final settings = currentSettings(game);
    final changes = settings.controls ?? const <String, List<String>>{};
    // The game's own actions, when its files name them, under each button.
    final actions = gameControls[game.id] ?? const <PadAction, List<String>>{};
    return [
      ..._gyroRows(game, settings),
      if (actions.isNotEmpty) PanelRow(id: 'fromGame', title: T.text('controlsFromGame'), kind: const InfoRow('')),
      for (final action in PadAction.values)
        PanelRow(
          id: action.key,
          title: padActionTitle(action),
          detail: actions[action]?.join(', '),
          glyph: switch (action) {
            PadAction.cross => PadGlyph.cross,
            PadAction.circle => PadGlyph.circle,
            PadAction.square => PadGlyph.square,
            PadAction.triangle => PadGlyph.triangle,
            _ => null,
          },
          kind: KeysRow(
            Controls.sources(action, changes),
            capturing: capturing == action,
            capture: () {
              capturing = action;
              sounds.play(Cue.select);
              _changed();
            },
          ),
        ),
      PanelRow(
        id: 'reset',
        title: T.text('resetControls'),
        kind: ActionRow(() => saveSettings(game, settings.copyWith(controls: null)), destructive: true),
      ),
    ];
  }

  /// A key pressed while a pad action waits for one (a USB HID usage, see Controls.keyName).
  bool captureKey(int usage) {
    final action = capturing;
    final game = selectedGame;
    if (action == null || game == null) return false;
    final name = Controls.keyName(usage);
    if (name == null) return true;
    final settings = currentSettings(game);
    capturing = null;
    sounds.play(Cue.move);
    saveSettings(
      game,
      settings.copyWith(controls: Controls.assign('KEY:$name', action, settings.controls ?? const {})),
    );
    return true;
  }

  static String padActionTitle(PadAction action) {
    String direction(String key) => T.text(key);
    return switch (action) {
      PadAction.cross => T.text('buttonCross'),
      PadAction.circle => T.text('buttonCircle'),
      PadAction.square => T.text('buttonSquare'),
      PadAction.triangle => T.text('buttonTriangle'),
      PadAction.options => T.text('buttonOptions'),
      PadAction.touchLeft => T.text('touchpadLeft'),
      PadAction.touchRight => T.text('touchpadRight'),
      PadAction.up => '${T.text('dpad')} · ${direction('directionUp')}',
      PadAction.down => '${T.text('dpad')} · ${direction('directionDown')}',
      PadAction.left => '${T.text('dpad')} · ${direction('directionLeft')}',
      PadAction.right => '${T.text('dpad')} · ${direction('directionRight')}',
      PadAction.leftStickUp => '${T.text('leftStick')} · ${direction('directionUp')}',
      PadAction.leftStickDown => '${T.text('leftStick')} · ${direction('directionDown')}',
      PadAction.leftStickLeft => '${T.text('leftStick')} · ${direction('directionLeft')}',
      PadAction.leftStickRight => '${T.text('leftStick')} · ${direction('directionRight')}',
      PadAction.rightStickUp => '${T.text('rightStick')} · ${direction('directionUp')}',
      PadAction.rightStickDown => '${T.text('rightStick')} · ${direction('directionDown')}',
      PadAction.rightStickLeft => '${T.text('rightStick')} · ${direction('directionLeft')}',
      PadAction.rightStickRight => '${T.text('rightStick')} · ${direction('directionRight')}',
      PadAction.stickModifier => T.text('padStickModifier'),
      _ => action.key,
    };
  }

  List<PanelRow> get _currentRows {
    final categories = panelCategories();
    if (categories.isEmpty) return const [];
    return categories[panelCategory.clamp(0, categories.length - 1)].rows;
  }

  void _skipToFocusable() {
    final rows = _currentRows;
    while (panelRow < rows.length && !rows[panelRow].focusable) {
      panelRow++;
    }
    if (panelRow >= rows.length) panelRow = 0;
  }

  /// What a command does in the open panel's rows (for panels with their own Back, like the
  /// crash report).
  void panelCommand(Command command) => _panelCommand(command);

  void _panelCommand(Command command) {
    final categories = panelCategories();
    final rows = _currentRows;
    int nextFocusable(int from, int delta) {
      var index = from + delta;
      while (index >= 0 && index < rows.length && !rows[index].focusable) {
        index += delta;
      }
      return index >= 0 && index < rows.length ? index : from;
    }

    final row = panelRow < rows.length ? rows[panelRow] : null;
    if (_searchCommand(command)) return;
    // A plain yes or no (ConfirmCard): its two answers side by side, ← to the way back, → to the
    // destructive one, from the keys and the pad alike.
    if (twoChoice && (command == Command.left || command == Command.right)) {
      final target = rows.indexWhere(
        (row) => row.kind is ActionRow && (row.kind as ActionRow).destructive == (command == Command.right),
      );
      if (target >= 0 && target != panelRow) {
        panelRow = target;
        sounds.play(Cue.move);
        _changed();
      }
      return;
    }
    if (_viaPad && _padPanelCommand(command, row, categories)) return;
    if (!_viaPad) {
      // The keys and the mouse have no sections' focus and no edit mode.
      panelSections = false;
      editingValue = null;
    }
    if (row?.kind case ShortcutRow(:final capture) when command == Command.select) return capture();
    if (row?.id case final String id when command == Command.options && id.startsWith('shortcut-')) {
      final action = LauncherAction.byName(id.substring('shortcut-'.length));
      if (action != null) return clearShortcut(action);
    }
    switch (command) {
      case Command.up || Command.down:
        final next = nextFocusable(panelRow, command == Command.down ? 1 : -1);
        // ↑ on Settings' first row: onto the search field.
        if (command == Command.up && overlay == Layer.settings && nextFocusable(panelRow, -1) == panelRow) {
          return _toSearch();
        }
        if (next != panelRow) sounds.play(Cue.move);
        panelRow = next;
        _changed();
      case Command.left || Command.right:
        final delta = command == Command.right ? 1 : -1;
        switch (row?.kind) {
          // As on the Mac: the arrows stop at the first and the last option (only a select goes
          // round), so ← always goes back, even on a row of two.
          case ChoiceRow(:final options, selected: final current, :final set):
            final next = (current + delta).clamp(0, options.length - 1);
            if (next != current) {
              set(next);
              sounds.play(Cue.move);
            }
          case final StepperRow stepper:
            final StepperRow(:value, :set) = stepper;
            // A held arrow (a key, the pad or the mouse on − +) speeds up on this row.
            final id = row!.id;
            final hold = _stepHold;
            final repeats = _repeatingNow && hold != null && hold.row == id && hold.delta == delta
                ? hold.repeats + 1
                : 0;
            _stepHold = (row: id, delta: delta, repeats: repeats);
            final next = stepper.moved(delta * stepper.strideFor(repeats));
            if (next != value) {
              set(next);
              sounds.play(Cue.move);
            }
          case ToggleRow(:final value, :final set):
            set(!value);
            sounds.play(Cue.move);
          case MediaRow(:final previous, :final next):
            (delta < 0 ? previous : next)();
            sounds.play(Cue.move);
          default:
            if (overlay == Layer.settings && categories.length > 1) {
              final next = (panelCategory + delta).clamp(0, categories.length - 1);
              if (next != panelCategory) sounds.play(Cue.move);
              panelCategory = next;
              panelRow = 0;
              _skipToFocusable();
              _changed();
            }
        }
      case Command.select:
        switch (row?.kind) {
          case ChoiceRow(:final options, selected: final current, :final set):
            set((current + 1) % options.length);
            sounds.play(Cue.move);
          case ToggleRow(:final value, :final set):
            set(!value);
            sounds.play(Cue.move);
          case ActionRow(:final run):
            sounds.play(Cue.select);
            run();
          case MediaRow(:final playPause):
            sounds.play(Cue.select);
            playPause();
          case KeysRow(:final capture):
            capture();
          case TextRow():
            if (row != null) startEditing(row.id);
          default:
            break;
        }
      case Command.back || Command.options:
        // A question asked in place (together_ask.dart) is answered Cancel first.
        if (together.cancelAsk()) break;
        if (overlay == Layer.themes || overlay == Layer.themeStudio) {
          backFromThemes();
        } else {
          closeOverlay();
        }
      default:
        break;
    }
  }

  /// A controller's command in a panel: the sections' column and edit mode (the keys and the
  /// mouse keep the old ways). True when it was handled here.
  bool _padPanelCommand(Command command, PanelRow? row, List<PanelCategory> categories) {
    final sections = overlay == Layer.settings && categories.length > 1;
    if (panelSections && sections) {
      switch (command) {
        // ↑ on the first section: onto the search field.
        case Command.up when panelCategory == 0:
          _toSearch();
        case Command.up || Command.down:
          moveCategory(command == Command.down ? 1 : -1);
        case Command.right || Command.select:
          panelSections = false;
          _skipToFocusable();
          sounds.play(Cue.move);
          _changed();
        case Command.back || Command.options:
          closeOverlay();
        default:
          break;
      }
      return true;
    }
    final editable = row?.kind is ChoiceRow || row?.kind is StepperRow;
    if (editingValue != null && (row == null || row.id != editingValue || !editable)) editingValue = null;
    if (editingValue != null) {
      switch (command) {
        case Command.left || Command.right:
          // ← and → change the value: what follows is the keys' way.
          return false;
        case Command.select || Command.back:
          editingValue = null;
          sounds.play(command == Command.select ? Cue.move : Cue.back);
          _changed();
          return true;
        case Command.up || Command.down:
          // Moving on leaves edit mode.
          editingValue = null;
          return false;
        default:
          editingValue = null;
          _changed();
          return true;
      }
    }
    // Now playing's card: ← and → are the previous and the next track at once, with no edit mode.
    if (row?.kind is MediaRow && (command == Command.left || command == Command.right)) return false;
    switch (command) {
      case Command.select when editable:
        editingValue = row!.id;
        sounds.play(Cue.select);
        _changed();
        return true;
      case Command.left:
        if (sections) {
          panelSections = true;
          sounds.play(Cue.move);
          _changed();
        }
        return true;
      case Command.right:
        return true;
      default:
        return false;
    }
  }

  /// A click on a row: the focus goes there and the row does what Enter does.
  void activateRow(int index) {
    final rows = _currentRows;
    if (index < 0 || index >= rows.length || !rows[index].focusable) return;
    panelRow = index;
    pointerFocus = true;
    panelSections = false;
    settingsSearchFocused = false;
    editingValue = null;
    together.partyChatKeys.focused = false;
    handle(Command.select);
  }

  /// A click on a row's ‹ › or − + : one step back or on, the focus going to the row. Held, the
  /// arrow repeats ([repeat]) and speeds up as a held key does.
  void stepRow(int index, int delta, {bool repeat = false}) {
    final rows = _currentRows;
    if (index < 0 || index >= rows.length || !rows[index].focusable) return;
    pointerFocus = true;
    settingsSearchFocused = false;
    if (panelRow != index) {
      panelRow = index;
      _changed();
    }
    _repeatingNow = repeat;
    try {
      handle(delta < 0 ? Command.left : Command.right);
    } finally {
      _repeatingNow = false;
    }
  }

  /// A slider's bar clicked or dragged: the row takes the focus and the value, with a tick.
  void setRowValue(int index, int value) {
    final rows = _currentRows;
    if (index < 0 || index >= rows.length || !rows[index].focusable) return;
    final kind = rows[index].kind;
    if (kind is! StepperRow) return;
    pointerFocus = true;
    settingsSearchFocused = false;
    panelRow = index;
    final next = value.clamp(kind.min, kind.max);
    if (next != kind.value) {
      kind.set(next);
      sounds.play(Cue.move);
    }
    _changed();
  }

  /// The pointer moved over a row: the focus follows it, quietly, and the list stays put.
  void hoverRow(int index) {
    final rows = _currentRows;
    if ((index == panelRow && !settingsSearchFocused) || index < 0 || index >= rows.length || !rows[index].focusable) {
      return;
    }
    panelRow = index;
    pointerFocus = true;
    settingsSearchFocused = false;
    together.partyChatKeys.focused = false;
    _changed();
  }

  /// The pointer moved over a game in the library.
  void hoverLibrary(int index) {
    if (index == libraryIndex || index < 0 || index >= games.length) return;
    libraryIndex = index;
    pointerFocus = true;
    _changed();
  }

  /// The pointer moved over a trophy.
  void hoverTrophy(int index) {
    if (index == trophyIndex || index < 0) return;
    trophyIndex = index;
    pointerFocus = true;
    _changed();
  }

  void selectCategory(int index) {
    if (index != panelCategory) sounds.play(Cue.move);
    panelCategory = index;
    panelSections = false;
    settingsSearchFocused = false;
    editingValue = null;
    panelRow = 0;
    _skipToFocusable();
    _changed();
  }

  /// The onboarding's theme cards preview on a click.
  void previewTheme(int index) {
    onboardingChoice = index;
    preferences.theme = index;
    _changed();
  }

  /// The settings' category tabs move with Q and E as well.
  void moveCategory(int delta) {
    final categories = panelCategories();
    if (categories.length < 2) return;
    final next = (panelCategory + delta).clamp(0, categories.length - 1);
    if (next != panelCategory) sounds.play(Cue.move);
    panelCategory = next;
    editingValue = null;
    panelRow = 0;
    _skipToFocusable();
    _changed();
  }

  // Onboarding: language, theme, games folder, toolkit.

  static const onboardingSteps = 5;
  int onboardingStep = 0;
  final Map<int, int> _onboardingChoices = {};

  int get onboardingChoice => _onboardingChoices[onboardingStep] ?? _defaultChoice(onboardingStep);
  set onboardingChoice(int value) => _onboardingChoices[onboardingStep] = value;

  int _defaultChoice(int step) => switch (step) {
    0 => T.languages.indexOf(T.language),
    1 => look.index,
    2 => preferences.gamesFolders.isEmpty ? 0 : 1,
    3 => toolkit == null ? 0 : 2,
    _ => 0,
  };

  int get _onboardingCount => switch (onboardingStep) {
    0 => T.languages.length,
    1 => LookStyle.values.length,
    2 => preferences.gamesFolders.isEmpty ? 1 : 2,
    _ => 3,
  };

  void _onboardingCommand(Command command) {
    // The last step: the cards, or the sign-in they lead to.
    if (onboardingStep == 4) {
      overlay == Layer.signIn ? _signInCommand(command) : modeChoiceCommand(command);
      return;
    }
    switch (command) {
      case Command.left:
        if (onboardingChoice > 0) {
          onboardingChoice = onboardingChoice - 1;
          _previewChoice();
        }
      case Command.right:
        if (onboardingChoice < _onboardingCount - 1) {
          onboardingChoice = onboardingChoice + 1;
          _previewChoice();
        }
      // The languages are rows of cards: up and down move a row.
      case Command.up || Command.down when onboardingStep == 0:
        final next = onboardingChoice + (command == Command.down ? languageColumns : -languageColumns);
        if (next >= 0 && next < _onboardingCount) {
          onboardingChoice = next;
          _previewChoice();
        }
      case Command.select:
        onboardingConfirm();
      case Command.back:
        onboardingBack();
      default:
        break;
    }
    notifyListeners();
  }

  /// How many language cards the first step has in a row.
  static const languageColumns = 7;

  /// The language and theme steps show their choice at once.
  void _previewChoice() {
    if (onboardingStep == 0) {
      T.language = T.languages[onboardingChoice];
      preferences.language = T.language.code;
    }
    if (onboardingStep == 1) preferences.theme = onboardingChoice;
  }

  void onboardingConfirm() {
    switch (onboardingStep) {
      case 0 || 1:
        _previewChoice();
        onboardingStep++;
      case 2:
        if (onboardingChoice == 1 && preferences.gamesFolders.isNotEmpty) {
          onboardingStep++;
          _enterToolkitStep();
        } else {
          unawaited(
            chooseGamesFolder().then((_) {
              if (preferences.gamesFolders.isNotEmpty) onboardingChoice = 1;
              notifyListeners();
            }),
          );
        }
      case 3:
        switch (onboardingChoice) {
          case 0:
            onboardingDownload();
          case 1:
            unawaited(
              chooseToolkit().then((_) {
                if (toolkit != null && onboardingStep == 3) onboardingChoice = 2;
                notifyListeners();
              }),
            );
          default:
            profileFlow.modeChoice = 0;
            onboardingStep++;
        }
      default:
        confirmModeChoice();
    }
    notifyListeners();
  }

  /// The toolkit step asks GitHub for the newest engine as it opens: AnyPS5-ARM's on a first
  /// start (its phone controller, full screen and window size), upstream's for a launcher that
  /// had it chosen before.
  void _enterToolkitStep() {
    if (engine.offered == null) engine.lookQuietly();
  }

  /// The toolkit step's download card: downloads the newest engine (asked once more when
  /// GitHub gave no checksum), or asks GitHub again when it could not be reached.
  void onboardingDownload() {
    if (engine.downloading != null) return;
    final pending = engine.unverified;
    final package = pending ?? engine.offered;
    if (package == null) {
      engine.lookQuietly();
      return;
    }
    unawaited(
      engine.download(package, pending != null).then((done) {
        if (done && onboardingStep == 3) onboardingChoice = 2;
        notifyListeners();
      }),
    );
  }

  void onboardingBack() {
    if (onboardingStep == 0) return;
    onboardingStep--;
    notifyListeners();
  }

  void finishOnboarding() {
    preferences.onboarded = true;
    focus = HomeFocus.tiles;
    savePreferences();
    rescan();
  }

  // Phone.

  Future<void> startPhoneServer() async {
    if (remote != null || !preferences.phoneServer) return;
    final name = services.computerName ?? Platform.localHostname;
    try {
      final events = RemoteEvents(
        pairing: (request) {
          pairing = request;
          sounds.play(Cue.select);
          _changed();
          // A game in front keeps its focus: the phone asks through a notice over it instead.
          unawaited(
            noticeOverGame(
              T.text('phonePairingTitle'),
              detail: T.format('phoneOpenLauncher', [PhoneLabel.title(request.deviceName)]),
              symbol: Icons.smartphone_rounded,
            ),
          );
        },
        connecting: (device) {
          phoneConnecting = device;
          if (device == null) pairing = null;
          _changed();
        },
        connected: (device) {
          phoneConnecting = null;
          pairing = null;
          show(T.format('phoneConnected', [device]));
          // A game in front hears of it through a notice over it.
          unawaited(
            noticeOverGame(
              T.format('phoneConnected', [device]),
              detail: T.text('phoneConnectedDetail'),
              symbol: Icons.smartphone_rounded,
            ),
          );
          _toldLibrary = null;
          _changed();
          _publishLook();
          // The new phone hears what the launcher is busy with, even if it is nothing.
          _activityTold = false;
          _publishActivity();
          // Its Go Live button shows what the launcher does now.
          if (media.phase.active) remote?.publish(const RemoteBroadcast(true));
          // A phone that comes while a game runs hears at once whether that game reads it.
          if (running case (final Game playing, _)) _checkPhoneReach(playing);
          // Over Home: upstream's engine in use, the switch to AnyPS5-ARM's in one press.
          askPhoneEngine();
        },
        disconnected: _changed,
        pad: _phonePads.packet,
        padEnded: _phonePads.gone,
        latency: (milliseconds) {
          phoneLatency = milliseconds;
          notifyListeners();
        },
        request: _phoneRequest,
        streamWishes: () => unawaited(media.updateRemotePlay()),
      );
      final devices = PairedDevices(paths.pairedDevicesFile);
      final RemoteServer server;
      if (services.preferredPorts) {
        server = await RemoteServer.startPreferred(name: name, devices: devices, events: events);
      } else {
        server = RemoteServer(name: name, devices: devices, events: events);
        await server.start();
      }
      remote = server;
      applyAssist();
      server.togetherServer = together.account.base.toString();
      unawaited(browserPlay.update());
      remoteError = null;
      if (services.cable) {
        final adb = await AdbTunnel.locate();
        if (adb != null) _adb = AdbTunnel(adb: adb, targetPort: server.port!)..start();
        _usb = UsbTunnel(targetPort: server.port!)..start();
      }
      if (!services.advertise) {
        _changed();
        return;
      }
      final advertiser = await AvahiAdvertiser.available()
          ? AvahiAdvertiser(instance: name, serviceType: RemoteServer.serviceType, port: server.port!)
          : MdnsResponder(instance: name, serviceType: RemoteServer.serviceType, port: server.port!);
      try {
        await advertiser.start();
        _advertiser = advertiser;
      } on Object {
        // Without advertising the phone still connects by address.
      }
    } on Object catch (error) {
      remoteError = error.toString();
    }
    _changed();
  }

  Future<void> stopPhoneServer() async {
    await browserPlay.stop();
    await _adb?.stop();
    _adb = null;
    await _usb?.stop();
    _usb = null;
    await _advertiser?.stop();
    _advertiser = null;
    await remote?.stop();
    remote = null;
    pairing = null;
    phoneConnecting = null;
    _changed();
  }

  void answerPairing(bool allow) {
    final request = pairing;
    if (request == null) return;
    remote?.respond(request.id, allow: allow);
    sounds.play(allow ? Cue.select : Cue.back);
    pairing = null;
    _changed();
  }

  void _phoneRequest(RemoteMessage message, String deviceId) {
    switch (message) {
      case RemoteSelect(:final id):
        final index = games.indexWhere((game) => game.id == id);
        if (index < 0) return;
        if (index != selected) sounds.play(Cue.move);
        select(index);
      case RemoteLaunch(:final id):
        final game = games.where((game) => game.id == id).firstOrNull;
        if (game == null) return;
        // One game at a time: the one playing stops, and the new one starts when it has gone.
        if (running != null && running!.$1 != game) {
          _launchAfterExit = game.id;
          stopGame();
          return;
        }
        select(games.indexOf(game));
        // Launch on the game playing is no Stop: the phone has Close for that.
        if (stateOf(game) is Running || stateOf(game) is Stopping) return;
        primaryAction(game);
      case RemoteClose():
        if (starting != null) {
          cancelStart();
        } else {
          stopGame();
        }
      case RemoteHome():
        handle(Command.home);
      case RemoteKeyFrame():
        media.wantKey();
      case RemoteCommand(name: 'capture'):
        // Create on the phone's pad: a clip (or a picture) of the game, the game staying in front.
        unawaited(saveClip());
      case RemoteCommand(:final name) when name == 'broadcastStart' || name == 'broadcastStop':
        // Go Live and End Broadcast on the phone.
        media.phoneBroadcast(name == 'broadcastStart');
      case RemoteCommand(:final name):
        final command = switch (name) {
          'left' => Command.left,
          'right' => Command.right,
          'up' => Command.up,
          'down' => Command.down,
          'select' => Command.select,
          'back' => Command.back,
          'options' => Command.options,
          'l1' => Command.previousGame,
          'r1' => Command.nextGame,
          _ => null,
        };
        if (command == null) return;
        // The launcher comes forward for its D-pad, as on the Mac.
        if (!launcherInFront) unawaited(raiseLauncher());
        // The phone's pad moves the launcher as a controller does (the sections, edit mode).
        _usedInput(InputMode.pad);
        _viaPad = true;
        try {
          handle(command);
        } finally {
          _viaPad = false;
        }
      case RemoteWantArt(:final id):
        final game = games.where((game) => game.id == id).firstOrNull;
        if (game == null) return;
        unawaited(_tellArt(game, deviceId));
      case RemoteSaveLayout(:final id, :final layout):
        final game = games.where((game) => game.id == id).firstOrNull;
        if (game != null) saveSettings(game, currentSettings(game).copyWith(phoneLayout: layout));
      case RemoteTogetherHandoff() || RemoteTogetherHandoffAnswer():
        together.phoneMessage(message, deviceId);
      default:
        break;
    }
  }

  /// A game's pictures, small enough for the control channel: 256 and 1280 pixels at most on the
  /// longest side, as on the Mac.
  Future<void> _tellArt(Game game, String deviceId) async {
    final icon = await phoneArt.encoded(game.icon, PhoneArt.iconSide);
    final background = await phoneArt.encoded(game.background, PhoneArt.backgroundSide);
    if (_disposed) return;
    remote?.tell(RemoteArt(id: game.id, icon: icon, background: background), deviceId);
  }

  void _publishLibrary() {
    final server = remote;
    if (server == null || server.connectedDevices.isEmpty) return;
    final library = RemoteLibrary(
      games: [
        for (final game in games)
          RemoteGame(
            id: game.id,
            name: game.name,
            state: switch (stateOf(game)) {
              Installed(:final outdated) => outdated ? RemoteGameState.update : RemoteGameState.installed,
              Locked() || Failed() || FamilyLocked() => RemoteGameState.locked,
              // The phone has no word for the engine's build: busy with the game, as an unlock is.
              Queued() || Installing() || WaitingForEngine() => RemoteGameState.installing,
              Starting() => RemoteGameState.starting,
              Running() || Stopping() => RemoteGameState.running,
              Unreadable() || NeedsEmulator() => RemoteGameState.unavailable,
            },
            trophies: switch (trophies[game.id]) {
              final TrophySet set => '${set.unlockedCount}/${set.trophies.length}',
              null => null,
            },
            art:
                '${game.icon != null ? _stamp(game.icon!) : 0}-${game.background != null ? _stamp(game.background!) : 0}',
            layout: currentSettings(game).phoneLayout,
          ),
      ],
      selected: selectedGame?.id,
      running: (running?.$1 ?? starting)?.id,
      language: T.language.code,
    );
    if (library == _toldLibrary) return;
    _toldLibrary = library;
    server.publish(library);
  }

  RemoteActivity? _toldActivity;

  /// False before the phones heard anything, and when a new one connects.
  bool _activityTold = false;

  /// The game the launcher is busy with and since when, so the phone counts the whole of it:
  /// waiting, updating and starting.
  ({String id, DateTime since})? _activitySince;

  /// The game starting, else the one installing, else the next one waiting, as on the Mac.
  RemoteActivity? _activityForPhone() {
    final game =
        starting ??
        games.where((game) => progress[game.id] != null).firstOrNull ??
        games.where((game) => queue.contains(game.id)).firstOrNull;
    if (game == null) {
      _activitySince = null;
      return null;
    }
    if (_activitySince?.id != game.id) _activitySince = (id: game.id, since: DateTime.now());
    var phase = RemotePhase.queued;
    double? fraction;
    switch (stateOf(game)) {
      case Starting():
        phase = RemotePhase.starting;
      case final Installing state:
        phase = switch (state.step) {
          InstallStep.unwrap => RemotePhase.unwrap,
          InstallStep.relink => RemotePhase.relink,
          InstallStep.copy => RemotePhase.copy,
          InstallStep.layout => RemotePhase.bundle,
          InstallStep.finish => RemotePhase.finish,
        };
        fraction = state.overall;
      default:
        break;
    }
    return RemoteActivity(
      id: game.id,
      phase: phase,
      updating: records.containsKey(game.id),
      fraction: fraction,
      elapsed: DateTime.now().difference(_activitySince!.since).inMilliseconds / 1000,
    );
  }

  void _publishActivity() {
    final server = remote;
    if (server == null) return;
    final now = _activityForPhone();
    if (_activityTold && RemoteActivity.same(_toldActivity, now)) return;
    _activityTold = true;
    _toldActivity = now;
    server.publish(RemoteActivityUpdate(now));
  }

  void _publishLook() {
    remote?.publish(
      RemoteLook(
        deep: LookStyle.hex(palette.deep),
        middle: LookStyle.hex(palette.middle),
        accent: LookStyle.hex(accentChoice.color),
      ),
    );
  }

  static int _stamp(String file) {
    try {
      return File(file).lastModifiedSync().millisecondsSinceEpoch;
    } on FileSystemException {
      return 0;
    }
  }

  bool _disposed = false;

  /// Work that ends after the launcher closed (an install, a game, the phone server stopping)
  /// tells no one.
  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
    _updateMusic();
  }

  @override
  void dispose() {
    _disposed = true;
    profileFlow.listLeave?.cancel();
    saveSync.dispose();
    powerWatch.stop();
    for (final watcher in _libraries.values) {
      watcher.stop();
    }
    _trophyWatch?.cancel();
    _toastTimer?.cancel();
    _stopTimer?.cancel();
    _phoneAnswerTimer?.cancel();
    _pulses.stop();
    _pads?.stop();
    _focusWatch?.cancel();
    _captureTimer?.cancel();
    // The replay buffer's segments go with the launcher, as do Remote Play and a broadcast.
    unawaited(_stopReplay());
    media.dispose();
    sharePlay.dispose();
    _navigator?.dispose();
    _installer?.cancel();
    _preparer?.cancel();
    _prepareTimer?.cancel();
    engine.cancel();
    fonts.dispose();
    files.dispose();
    unawaited(discord.close());
    removeListener(nowPlaying.update);
    unawaited(nowPlaying.close());
    together.dispose();
    updates.dispose();
    music.dispose();
    unawaited(stopPhoneServer());
    super.dispose();
  }
}

/// The motors of whatever controllers are being read now (none before the pads start).
class _PadMotors implements PadRumble {
  _PadMotors(this.app);
  final AppModel app;

  @override
  bool canRumble(String pad) => app._pads?.motors?.canRumble(pad) ?? false;

  @override
  void rumble(String pad, double strong, double weak, Duration length) =>
      app._pads?.motors?.rumble(pad, strong, weak, length);
}
