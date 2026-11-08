import 'dart:io';

import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/retro_optimizer.dart';
import 'package:anyps5_desktop/core/retro_settings.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/ui_support.dart';

void main() {
  for (final platform in RetroPlatform.ps1AndPs2) {
    test('${platform.name} previews, applies and restores the resolution from the dashboard', () async {
      final fixture = makeFixture();
      final exe = File(p.join(fixture.temp.path, 'emulator.exe'))..createSync();
      final config = RetroSettings.configFile(exe.path, platform);
      config.parent.createSync(recursive: true);
      final (section, key) = switch (platform) {
        RetroPlatform.ps1 => ('GPU', 'ResolutionScale'),
        RetroPlatform.ps2 => ('EmuCore/GS', 'upscale_multiplier'),
        RetroPlatform.ps3 => throw StateError('The standalone optimizer supports PS1 and PS2.'),
      };
      config.writeAsStringSync('[$section]\n$key = 1\nUntouched = yes\n');
      var displayHeight = 1440;
      final app = AppModel(
        paths: fixture.model.paths,
        persist: false,
        preferences: Preferences()..retroEmulators[platform.name] = exe.path,
        services: LauncherServices(
          retroHardware: () async => RetroHardware(
            displayHeight: displayHeight,
            adapters: const [RetroAdapter(name: 'Test GPU', dedicatedBytes: 16 << 30)],
          ),
        ),
      );
      addTearDown(() {
        app.dispose();
        fixture.model.dispose();
        fixture.dispose();
      });

      PanelCategory optimize() => app.retroSettings
          .categories(platform)
          .singleWhere((category) => category.id == 'retro-${platform.name}-optimize');
      ActionRow action(String suffix) =>
          optimize().rows.singleWhere((row) => row.id.endsWith(suffix)).kind as ActionRow;

      action('-preview').run();
      await pumpEventQueue();
      final summary = optimize().rows.singleWhere((row) => row.id.endsWith('-summary'));
      expect(summary.title, contains('1× → 4×'));
      expect(summary.detail, contains('Test GPU'));
      expect(config.readAsStringSync(), contains('$key = 1'));

      action('-apply').run();
      await pumpEventQueue();
      expect(config.readAsStringSync(), contains('$key = 4'));
      expect(config.readAsStringSync(), contains('Untouched = yes'));

      action('-undo').run();
      expect(config.readAsStringSync(), contains('$key = 1'));
      expect(config.readAsStringSync(), contains('Untouched = yes'));

      displayHeight = 720;
      action('-apply').run();
      await pumpEventQueue();
      expect(config.readAsStringSync(), contains('$key = 1'), reason: 'a preview from another display must be refreshed');
      expect(optimize().rows.singleWhere((row) => row.id.endsWith('-summary')).detail, contains('720p'));

      config.writeAsStringSync(
        '[$section]\n$key = 1\n'
        'Renderer = ${platform == RetroPlatform.ps1 ? 'Software' : '13'}\n'
        'Renderer = ${platform == RetroPlatform.ps1 ? 'Automatic' : '-1'}\n',
      );
      expect(optimize().rows.any((row) => row.id.endsWith('-apply')), isFalse);
    });
  }
}
