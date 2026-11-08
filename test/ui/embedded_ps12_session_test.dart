import 'dart:io';

import 'package:anyps5_desktop/core/controllers/pad_info.dart';
import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/gamepad/pad_navigation.dart';
import 'package:anyps5_desktop/core/managed_retro.dart';
import 'package:anyps5_desktop/ui/embedded_retro_game.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  const channel = MethodChannel('anyps5/retro_core');

  for (final (host, platform, library, discName, scale) in [
    (
      EmbeddedCoreHost.linuxX64,
      RetroPlatform.ps1,
      'swanstation_libretro.so',
      'game.cue',
      'swanstation_GPU_ResolutionScale',
    ),
    (EmbeddedCoreHost.windowsX64, RetroPlatform.ps2, 'pcsx2_libretro.dll', 'game.iso', 'pcsx2_upscale_multiplier'),
  ]) {
    testWidgets('${platform.name} uses a native texture, sends input and remembers accepted settings', (tester) async {
      final root = Directory.systemTemp.createTempSync('anyps5-embedded-');
      addTearDown(() => root.deleteSync(recursive: true));
      final managed = ManagedRetro(root.path, host);
      final path = p.join(root.path, library);
      File(path).createSync();
      final disc = (platform: platform, path: p.join(root.path, discName));
      final calls = <MethodCall>[];
      var ended = false;
      var active = '2';
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        switch (call.method) {
          case 'start':
            expect(call.arguments, containsPair('core', path));
            expect(call.arguments, containsPair('disc', disc.path));
            expect(call.arguments, containsPair('internalResolution', '2'));
            return 19;
          case 'status':
            return {
              'ended': ended,
              'presented': true,
              'options': {
                scale: {
                  'values': ['1', '2', '3'],
                  'activeValue': active,
                  'selected': int.parse(active) - 1,
                },
              },
            };
          case 'option':
            expect(call.arguments, {'key': scale, 'value': '3'});
            active = '3';
            return true;
          case 'stop':
            ended = true;
            return null;
          default:
            return null;
        }
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      String? saved;
      final game = await EmbeddedRetroGame.start(
        managed,
        disc,
        internalResolution: '2',
        graphics: {scale: '2'},
        onResolutionSelected: (value) => saved = value,
        onGraphicsSelected: (_, _) {},
        readPad: () => PadState.idle,
        changed: () {},
      );
      expect(game.textureId, 19);
      await tester.pump(const Duration(milliseconds: 130));
      expect(await game.ready, isTrue);
      await game.setOption(scale, '3');
      expect(saved, '3');

      game.key(PadButton.south, true);
      await tester.pump(const Duration(milliseconds: 17));
      expect(calls.lastWhere((call) => call.method == 'input').arguments, [1, 0, 0, 0, 0]);
      game.playback(playing: true, focused: false);
      await tester.pump();
      expect(calls.lastWhere((call) => call.method == 'input').arguments, [0, 0, 0, 0, 0]);
      expect(calls.where((call) => call.method == 'pause'), isEmpty);

      game.playback(playing: false, focused: true);
      game.playback(playing: true, focused: true);
      await tester.pump();
      expect(calls.where((call) => call.method == 'pause').map((call) => call.arguments), [true, false]);
      expect(calls.where((call) => call.method == 'start'), hasLength(1));
      await game.close();
      await tester.pump(const Duration(milliseconds: 130));
      expect(await game.exitCode, 0);
      expect(calls.last.method, 'release');
    });
  }

  test('a rejected core archive or BIOS replacement preserves the installed file', () async {
    final root = Directory.systemTemp.createTempSync('anyps5-core-validation-');
    addTearDown(() => root.deleteSync(recursive: true));
    final managed = ManagedRetro(root.path, EmbeddedCoreHost.linuxX64);
    const platform = RetroPlatform.ps1;
    final installed = File(managed.libraryPath(platform))..writeAsBytesSync([3, 5, 8]);
    final invalid = File(p.join(root.path, 'invalid.zip'))..writeAsBytesSync([1, 2]);
    await expectLater(managed.install(platform, invalid.path), throwsFormatException);
    expect(installed.readAsBytesSync(), [3, 5, 8]);
    expect(await managed.verifiesInstalled(platform), isFalse);

    final bios = File(p.join(root.path, 'bios.bin'))..writeAsBytesSync(List.filled(512 * 1024, 0)..[0] = 1);
    await managed.importBios(platform, bios.path);
    await expectLater(managed.importBios(platform, invalid.path), throwsFormatException);
    expect(File(managed.biosPath(platform)!).lengthSync(), 512 * 1024);
    expect(File(managed.biosPath(platform)!).readAsBytesSync().first, 1);
  });
}
