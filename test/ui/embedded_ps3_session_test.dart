import 'dart:io';

import 'package:anyps5_desktop/core/controllers/pad_info.dart';
import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/gamepad/pad_navigation.dart';
import 'package:anyps5_desktop/core/gamepad/shortcuts.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/managed_retro.dart';
import 'package:anyps5_desktop/core/toolkit_download.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/embedded_retro_game.dart';
import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/ui_support.dart';
import 'desktop_features_test.dart' show FakePads;

void main() {
  test('PS3 settings categories work with the controller and section shortcuts', () {
    final pads = FakePads();
    final host = EmbeddedCoreHost.current!;
    final fixture = makeFixture(
      system: host == EmbeddedCoreHost.windowsX64 ? HostSystem.windows : HostSystem.linux,
      pads: () => pads,
    );
    final model = fixture.model..startPads();
    addTearDown(() {
      model.dispose();
      fixture.dispose();
    });
    final core = ManagedRetro(p.join(p.dirname(model.paths.toolkits), 'Emulators'), host);
    File(core.libraryPath(RetroPlatform.ps3)).createSync(recursive: true);
    model
      ..games = [
        Game(
          folder: fixture.temp.path,
          titleId: 'PS3-TEST00001',
          name: 'PS3 game',
          names: const {},
          defaultLanguage: 'en',
          version: '',
          executable: ExecutableKind.disc,
          retro: (platform: RetroPlatform.ps3, path: p.join(fixture.temp.path, 'PS3_DISC.SFB')),
        ),
      ]
      ..selected = 0
      ..open(Layer.gameSettings);
    expect(model.hasSettingsSections, isTrue);
    pads.press(PadButton.dpadLeft);
    expect(model.panelSections, isTrue);
    pads.press(PadButton.dpadUp);
    expect(model.settingsSearchFocused, isFalse);
    expect(model.panelCategory, 0);
    pads.press(PadButton.dpadDown);
    expect(model.panelCategory, 1);
    pads.press(PadButton.dpadRight);
    expect(model.panelSections, isFalse);
    model.runKeyShortcut(LauncherAction.nextSection);
    expect(model.panelCategory, 2);
  }, skip: EmbeddedCoreHost.current == null);

  test('PS3 stages a local PUP without replacing it after a rejected import', () async {
    final root = Directory.systemTemp.createTempSync('anyps5-ps3-firmware-');
    addTearDown(() => root.deleteSync(recursive: true));
    final managed = ManagedRetro(p.join(root.path, 'managed'), EmbeddedCoreHost.windowsX64);
    final header = Uint8List(144)..setAll(0, 'SCEUF'.codeUnits);
    ByteData.sublistView(header)
      ..setUint64(24, 1)
      ..setUint64(32, 112)
      ..setUint64(40, 32);
    final valid = File(p.join(root.path, 'PS3UPDAT.PUP'))..writeAsBytesSync(header);
    await managed.importPs3Firmware(valid.path);
    expect(managed.hasPs3FirmwarePackage, isTrue);
    expect(managed.hasPs3Firmware, isFalse);
    final flash = p.join(managed.systemPath, 'rpcs3', 'dev_flash');
    File(p.join(flash, 'vsh', 'module', 'vsh.self')).createSync(recursive: true);
    expect(managed.hasPs3Firmware, isFalse);
    File(p.join(flash, 'sys', 'external', 'liblv2.sprx')).createSync(recursive: true);
    expect(managed.hasPs3Firmware, isTrue);
    final invalid = File(p.join(root.path, 'truncated.pup'))..writeAsBytesSync(header.sublist(0, 48));
    await expectLater(managed.importPs3Firmware(invalid.path), throwsFormatException);
    expect(File(managed.ps3FirmwarePackage).readAsBytesSync(), header);
    expect(EmbeddedCoreHost.linuxX64.libraryName(RetroPlatform.ps3), 'rpcs3_libretro.so');
  });

  test('Linux installs the pinned SO from a verified ZIP and rejects tampering', () async {
    final root = Directory.systemTemp.createTempSync('anyps5-ps3-linux-');
    addTearDown(() => root.deleteSync(recursive: true));
    const platform = RetroPlatform.ps3;
    const name = 'rpcs3_libretro.so';
    final library = File(p.join(root.path, name))..writeAsBytesSync([0x7f, 0x45, 0x4c, 0x46]);
    final archive = Archive()..addFile(ArchiveFile.bytes(name, library.readAsBytesSync()));
    final package = File(p.join(root.path, 'core.zip'))..writeAsBytesSync(ZipEncoder().encode(archive));
    final archiveDigest = await AssetDownload.sha256Of(package.path);
    final libraryDigest = await AssetDownload.sha256Of(library.path);
    final managed = ManagedRetro(
      p.join(root.path, 'managed'),
      EmbeddedCoreHost.linuxX64,
      ps3CoreDigests: '$archiveDigest:$libraryDigest',
    );

    await managed.install(platform, package.path);
    expect(await managed.verifiesInstalled(platform), isTrue);
    package.writeAsBytesSync([1, 2, 3]);
    await expectLater(managed.install(platform, package.path), throwsFormatException);
    expect(await managed.verifiesInstalled(platform), isTrue);
    File(managed.libraryPath(platform)).writeAsBytesSync([1, 2, 3]);
    expect(await managed.verifiesInstalled(platform), isFalse);
  });

  testWidgets('RPCS3 forwards real progress values and remembers an accepted live setting', (tester) async {
    final root = Directory.systemTemp.createTempSync('anyps5-ps3-session-');
    addTearDown(() => root.deleteSync(recursive: true));
    final managed = ManagedRetro(root.path, EmbeddedCoreHost.windowsX64);
    const platform = RetroPlatform.ps3;
    const scale = 'rpcs3_resolution_scale';
    final core = File(managed.libraryPath(platform))..createSync();
    final disc = (platform: platform, path: p.join(root.path, 'PS3_DISC.SFB'));
    const channel = MethodChannel('anyps5/retro_core');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var ended = false;
    var compiling = true;
    var accepted = false;
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'start':
          expect(call.arguments, containsPair('core', core.path));
          expect(call.arguments, containsPair('disc', disc.path));
          expect(call.arguments, containsPair('graphics', {scale: '100'}));
          return 21;
        case 'status':
          return {
            'ended': ended,
            'presented': !compiling,
            if (compiling) ...{'progressLabel': 'Compiling PPU Modules…', 'progressPercent': 67},
            'options': {
              scale: {
                'values': ['100', '150'],
                'selected': 0,
              },
            },
          };
        case 'option':
          expect(call.arguments, {'key': scale, 'value': '150'});
          return accepted;
        case 'stop':
          ended = true;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final saved = <String, String>{};
    final game = await EmbeddedRetroGame.start(
      managed,
      disc,
      internalResolution: null,
      graphics: {scale: '100'},
      onResolutionSelected: (_) {},
      onGraphicsSelected: (key, value) => saved[key] = value,
      readPad: () => PadState.idle,
      changed: () {},
    );
    await tester.pump(const Duration(milliseconds: 130));
    expect(game.progress?.percent, 67);
    expect(game.presented, isFalse);

    compiling = false;
    await tester.pump(const Duration(milliseconds: 130));
    expect(game.progress, isNull);
    expect(await game.waitForPs3Startup(), isTrue);
    await game.setOption(scale, '150');
    expect(saved, isEmpty);
    accepted = true;
    await game.setOption(scale, '150');
    expect(saved, {scale: '150'});
    expect(calls.where((call) => call == 'start'), hasLength(1));
    await game.close();
    await tester.pump(const Duration(milliseconds: 130));
    expect(await game.exitCode, 0);
    expect(calls.last, 'release');
  });
}
