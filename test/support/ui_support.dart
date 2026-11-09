import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:anyps5_desktop/core/discord_presence.dart';
import 'package:anyps5_desktop/core/ffmpeg_download.dart';
import 'package:anyps5_desktop/core/engine_checkout.dart';
import 'package:anyps5_desktop/core/audio/atrac9.dart';
import 'package:anyps5_desktop/core/audio/audio_out.dart';
import 'package:anyps5_desktop/core/controls.dart';
import 'package:anyps5_desktop/core/crash_report.dart';
import 'package:anyps5_desktop/core/desktop/desktop.dart';
import 'package:anyps5_desktop/core/desktop/launcher_window.dart';
import 'package:anyps5_desktop/core/desktop/window_backdrop.dart';
import 'package:anyps5_desktop/core/font_download.dart';
import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/gamepad/pad_navigation.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/power.dart';
import 'package:anyps5_desktop/core/release_signing.dart';
import 'package:anyps5_desktop/core/capture/wayland_capture.dart';
import 'package:anyps5_desktop/core/replay_buffer.dart';
import 'package:anyps5_desktop/core/trophies.dart';
import 'package:anyps5_desktop/core/installer.dart';
import 'package:anyps5_desktop/core/toolkit_download.dart';
import 'package:anyps5_desktop/core/together/media.dart' show SfuRoom;
import 'package:anyps5_desktop/core/together/talk_key.dart';
import 'package:anyps5_desktop/core/together/token_store.dart';
import 'package:anyps5_desktop/core/together/voice_mesh.dart';
import 'package:anyps5_desktop/core/unreal/unreal_controls.dart';
import 'package:anyps5_desktop/main.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/background.dart';
import 'package:anyps5_desktop/ui/clip_player.dart';
import 'package:anyps5_desktop/ui/voice_note_player.dart';
import 'package:anyps5_desktop/ui/components.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:anyps5_desktop/ui/theme_hub_model.dart';
import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fake_toolkit.dart';
import 'fake_sfu.dart';
import 'fake_voice.dart';
import 'fixtures.dart';
import 'trophy_fixture.dart';

bool _fontsLoaded = false;

/// The app's font and the Material icons, so golden images show real text instead of boxes.
Future<void> loadFonts() async {
  if (_fontsLoaded) return;
  _fontsLoaded = true;
  final figtree = FontLoader('Figtree')..addFont(rootBundle.load('assets/fonts/Figtree.ttf'));
  final icons = FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
  await Future.wait([figtree.load(), icons.load()]);
}

/// A PNG written in Dart: [color] gives each pixel's RGBA.
Uint8List png(int width, int height, int Function(int x, int y) color) {
  final raw = BytesBuilder();
  for (var y = 0; y < height; y++) {
    raw.addByte(0);
    for (var x = 0; x < width; x++) {
      final value = color(x, y);
      raw.add([value >> 24 & 0xFF, value >> 16 & 0xFF, value >> 8 & 0xFF, value & 0xFF]);
    }
  }
  final out = BytesBuilder()..add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  void chunk(String type, List<int> data) {
    final body = [...type.codeUnits, ...data];
    out
      ..add(_u32(data.length))
      ..add(body)
      ..add(_u32(_crc(body)));
  }

  chunk('IHDR', [..._u32(width), ..._u32(height), 8, 6, 0, 0, 0]);
  chunk('IDAT', ZLibEncoder().convert(raw.toBytes()));
  chunk('IEND', const []);
  return out.toBytes();
}

List<int> _u32(int value) => [value >> 24 & 0xFF, value >> 16 & 0xFF, value >> 8 & 0xFF, value & 0xFF];

int _crc(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = crc & 1 != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return crc ^ 0xFFFFFFFF;
}

/// A made-up game icon: a diagonal gradient between two colors with a soft disc.
Uint8List iconArt(int from, int to, {int size = 96}) => png(size, size, (x, y) {
  final t = (x + y) / (2 * size);
  final disc = math.max(0.0, 1 - math.sqrt(math.pow(x - size * 0.62, 2) + math.pow(y - size * 0.4, 2)) / (size * 0.3));
  int mix(int shift) {
    final a = from >> shift & 0xFF;
    final b = to >> shift & 0xFF;
    return (a + (b - a) * t + 255 * disc * 0.35).round().clamp(0, 255);
  }

  return mix(16) << 24 | mix(8) << 16 | mix(0) << 8 | 0xFF;
});

/// A made-up wide background: dark horizon bands.
Uint8List backgroundArt(int tint) => png(160, 90, (x, y) {
  final t = y / 90;
  int channel(int shift) => ((tint >> shift & 0xFF) * (0.25 + 0.55 * (1 - (t - 0.55).abs() * 1.6).clamp(0, 1))).round();
  return channel(16) << 24 | channel(8) << 16 | channel(0) << 8 | 0xFF;
});

class Fixture {
  Fixture(this.temp, this.model, this.toolkit, this.opened, this.copied);
  final Directory temp;
  final AppModel model;
  final String toolkit;

  /// Web pages the launcher opened in the browser.
  final List<Uri> opened;

  /// Texts the launcher put on the clipboard.
  final List<String> copied;

  /// Folders the launcher showed in the file manager.
  final List<String> folders = [];

  void dispose() => temp.deleteSync(recursive: true);
}

/// A launcher on a games folder of four made-up dumps: one installed with pictures, one locked,
/// one being installed and one that cannot be read; a fake toolkit; nothing written to the
/// user's folders.
Fixture makeFixture({
  bool onboarded = true,
  int theme = 0,
  Language language = Language.english,
  bool withToolkit = true,
  Uri? together,
  TokenStore? togetherStore,
  TokenStore Function(String profile)? togetherStoreFor,
  VoiceEngine Function()? voice,
  SfuRoom Function()? sfuRoom,
  KeyStateReader? keys,
  Uri? engine,
  Uri? armEngine,
  List<ReleaseKey>? armKeys,
  Uri? ffmpegApi,
  List<ReleaseKey>? ffmpegKeys,
  ProcessRunner? ffmpegRun,
  DesktopWindows? desktop,
  WindowBackdrop? backdrop,
  PadSource Function()? pads,
  Future<RgbaImage> Function(Trophy trophy, double scale)? renderTrophyCard,
  Future<RgbaImage> Function(bool live, String time, double scale)? renderLiveBadge,
  String? glibc,
  AudioOut? audio,
  Future<PlayableSong?> Function(String path)? decodeSong,
  FontArchive? cjkFonts,
  String? builtInFonts,
  Future<String?> Function(String suggestedName)? saveFile,
  Future<String?> Function(String suggestedName, String label, List<String> extensions)? saveFileAs,
  Future<String?> Function(String label, List<String> extensions)? pickFile,
  HostSystem system = HostSystem.linux,
  GitHubReleases? launcherReleases,
  Future<void> Function(String executable, List<String> arguments)? startDetached,
  void Function(int code)? quit,
  Map<String, String> environment = const {},
  bool prepareNewGames = false,
  int? Function(String folder)? freeSpace,
  LauncherWindow? window,
  ReplayBuffer? Function(int seconds)? replay,
  WaylandCapture? waylandCapture,
  Future<int> Function(String folder)? folderSize,
  Future<Map<PadAction, List<String>>?> Function(String folder)? gameControls,
  Future<String?> Function(String title)? pickFolder,
  Future<String?> Function()? pickImage,
  Future<List<String>?> Function()? pickPictures,
  CommandRunner? commands,
  DiscordPresence Function()? discord,
  ClipPlayback Function()? clipPlayback,
  VoicePlayback Function()? voicePlayback,
}) {
  final opened = <Uri>[];
  final copied = <String>[];
  void Function(String folder)? shown;
  final temp = temporaryFolder('ui');
  final root = p.join(temp.path, 'Games');
  final toolkit = makeFakeToolkit(p.join(temp.path, 'toolkit'));
  void pictures(String folder, int from, int to) {
    File(p.join(folder, 'sce_sys', 'icon0.png')).writeAsBytesSync(iconArt(from, to));
    File(p.join(folder, 'sce_sys', 'pic0.png')).writeAsBytesSync(backgroundArt(to));
  }

  final astro = makeDump(
    root,
    'astro',
    titleId: 'PPSA01001',
    names: {'en-US': 'Orbit Runner', 'tr-TR': 'Yörünge Koşucusu'},
  );
  pictures(astro, 0x3A6BFF, 0x0B1E5C);
  final stray = makeDump(root, 'stray', titleId: 'PPSA02002', names: {'en-US': 'Neon Alley'}, eboot: selfHead);
  pictures(stray, 0xFF8A3D, 0x5C1B0B);
  final forest = makeDump(root, 'forest', titleId: 'PPSA03003', names: {'en-US': 'Quiet Forest'}, eboot: selfHead);
  pictures(forest, 0x42D392, 0x0B3D2A);
  makeDump(root, 'broken', titleId: 'PPSA04004', names: {'en-US': 'Sealed Archive'}, eboot: const [1, 2, 3, 4]);
  final preferences = Preferences()
    ..onboarded = onboarded
    ..gamesFolders = [root]
    ..theme = theme
    ..language = language.code
    ..profileName = 'Utku'
    ..toolkitFolder = withToolkit ? toolkit : null
    // Off unless a test is about it: a game copied in would otherwise start unlocking.
    ..prepareNewGames = prepareNewGames;
  // The Theme Hub reads no server in the tests unless one asks for it: an empty Hub.
  ThemeHubModel.basesInstead = const [];
  final model = AppModel(
    paths: AppPaths.forSystem(HostSystem.linux, environment: {'HOME': p.join(temp.path, 'home')}),
    preferences: preferences,
    system: system,
    persist: false,
    services: LauncherServices(
      computerName: 'Desk',
      pickFolder: pickFolder ?? (_) async => root,
      pickImage: pickImage,
      pickPictures: pickPictures,
      advertise: false,
      preferredPorts: false,
      cable: false,
      openUrl: opened.add,
      clipPlayback: clipPlayback,
      voicePlayback: voicePlayback,
      copyText: copied.add,
      openFolder: (folder) => shown?.call(folder),
      environment: environment,
      togetherStore: togetherStore ?? MemoryTokenStore(),
      togetherStoreFor: togetherStoreFor,
      togetherServer: together,
      togetherPollEvery: const Duration(milliseconds: 10),
      voiceEngine: voice ?? FakeVoiceEngine.new,
      sfuRoom: sfuRoom ?? FakeSfuRoom.new,
      talkKeys: () => keys,
      engineReleases: engine == null ? null : GitHubReleases(api: engine),
      armEngineReleases: armEngine == null
          ? null
          : GitHubReleases(api: armEngine, repository: ArmToolkitPackage.repository, signingKeys: armKeys),
      ffmpegReleases: ffmpegApi == null
          ? null
          : GitHubReleases(api: ffmpegApi, repository: FfmpegBuild.repository, signingKeys: ffmpegKeys),
      ffmpegRun: ffmpegRun,
      desktop: desktop,
      backdrop: backdrop,
      pads: pads,
      renderTrophyCard: renderTrophyCard,
      renderLiveBadge: renderLiveBadge,
      hostGlibc: () => glibc,
      audio: audio == null ? null : () => audio,
      decodeSong: decodeSong,
      cjkFonts: cjkFonts,
      builtInFonts: builtInFonts,
      saveFile: saveFile,
      saveFileAs: saveFileAs,
      pickFile: pickFile,
      launcherReleases: launcherReleases,
      startDetached: startDetached,
      quit: quit,
      window: window,
      replay: replay,
      waylandCapture: waylandCapture,
      // The size at once, as a finished measurement: the screens and goldens show it.
      folderSize: folderSize ?? (folder) => SynchronousFuture(GameLibrary.size(folder)),
      // An Unreal game's own controls at once, read from its paks.
      gameControls: gameControls ?? (folder) => SynchronousFuture(UnrealControls.read(folder)),
      commands: commands,
      discord: discord,
      discordGames: (_) async => null,
      systemInfo: () async =>
          const SystemInfo(os: 'Ubuntu 24.04.1 LTS, kernel 6.8.0-45-generic', cpu: 'AMD Ryzen 7 5800X', memoryGB: 32),
    ),
  );
  // Room enough for any made-up size, and on mains power, unless a test says otherwise.
  model
    ..freeSpace = freeSpace ?? ((_) => 1 << 50)
    ..power = () => PowerState.mains;
  model.rescan();
  // The first game is installed: a record beside a stand-in executable.
  final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
  final installed = Installer.installedFolder(orbit, root);
  Directory(installed).createSync(recursive: true);
  File(p.join(installed, 'app.elf')).writeAsStringSync('#!/bin/sh\n');
  File(p.join(installed, Installer.recordName)).writeAsStringSync(
    '{"date":"2026-10-24T12:00:00Z","source":${jsonEncode(orbit.folder)},"system":"linux","titleID":"PPSA01001","toolkit":"toolkit-1"}',
  );
  writeTrophies(orbit.folder, installed: installed, earned: [1, 2]);
  model.rescan();
  model.sizes[orbit.id] = 48200000000;
  final fixture = Fixture(temp, model, toolkit, opened, copied);
  shown = fixture.folders.add;
  return fixture;
}

/// Renders the launcher at 1600x900 with the background and clock held still.
/// [wrap] puts something around the app (a mock desktop behind Glass's see-through window).
Future<void> pumpLauncher(
  WidgetTester tester,
  AppModel model, {
  Size size = const Size(1600, 900),
  Widget Function(Widget app)? wrap,
}) async {
  ArtworkImage.readSynchronously = true;
  await tester.runAsync(() async {
    await loadFonts();
    await ThemeBackground.preload();
  });
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final app = AnyPS5App(model: model, time: 120, now: DateTime(2026, 10, 24, 21, 30));
  await tester.pumpWidget(wrap == null ? app : wrap(app));
  await settle(tester);
}

/// Lets images decode (real file reads) and animations finish.
Future<void> settle(WidgetTester tester) async {
  await tester.runAsync(() async {
    for (final element in find.byType(Image).evaluate()) {
      final image = element.widget as Image;
      await precacheImage(image.image, element);
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });
  for (var frame = 0; frame < 8; frame++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

/// Presses a key as the keyboard would.
Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await settle(tester);
}

/// An upstream release as GitHub's API describes it, with both systems' files and checksums,
/// for screens that show a version and a size without downloading anything.
UpstreamRelease sampleRelease(String version, {int librariesSize = 96653447, bool prerelease = false}) {
  ReleaseAsset asset(String name, int size) =>
      ReleaseAsset(name: name, size: size, url: Uri.parse('https://example.invalid/$name'), sha256: 'a' * 64);
  return UpstreamRelease(
    tag: 'v$version',
    prerelease: prerelease,
    assets: [
      asset('relinker-v$version', 4529672),
      asset('relinker-v$version.exe', 5424392),
      asset('prx-linux-v$version.tar.gz', librariesSize + 5000000),
      asset('prx-windows-v$version.zip', librariesSize),
    ],
  );
}
