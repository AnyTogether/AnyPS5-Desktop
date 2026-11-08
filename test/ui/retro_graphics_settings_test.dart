import 'dart:io';

import 'package:anyps5_desktop/core/retro_settings.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/retro_graphics_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late File file;
  late int saves;

  setUp(() {
    final folder = Directory.systemTemp.createTempSync('retro-graphics');
    addTearDown(() => folder.deleteSync(recursive: true));
    file = File('${folder.path}/PCSX2.ini');
    saves = 0;
  });

  ChoiceRow control(String title) =>
      RetroGraphicsSettings.rows(
            settings: RetroSettings.read(file),
            save: (apply) {
              apply();
              saves++;
            },
          ).singleWhere((row) => row.title == title).kind
          as ChoiceRow;

  void choose(String title, String choice) {
    final row = control(title);
    expect(row.options, contains(choice));
    row.set(row.options.indexOf(choice));
  }

  test('friendly graphics options read and save PCSX2 graphics values', () {
    file.writeAsStringSync(
      '[EmuCore/GS]\nupscale_multiplier = 1.000000\nRenderer = -1\nfilter = 2\nMaxAnisotropy = 0\nfxaa = false\n'
      '[Other]\nfilter = unchanged\n',
    );
    final native = control('Internal Resolution');
    expect(native.options[native.selected], 'Native (1×)');
    expect(saves, 0);

    choose('Internal Resolution', '3× (~1080p)');
    choose('Renderer', 'Vulkan');
    choose('Texture Filtering', 'Bilinear (forced, except sprites)');
    choose('Anisotropic Filtering', '16×');
    choose('FXAA', 'On');

    final options = RetroSettings.read(file).options;
    expect(
      {for (final option in options.where(RetroGraphicsSettings.handles)) option.key: option.value},
      {'upscale_multiplier': '3', 'Renderer': '14', 'filter': '3', 'MaxAnisotropy': '16', 'fxaa': 'true'},
    );
    expect(options.singleWhere((option) => option.section == 'Other').value, 'unchanged');
    expect(saves, 5);
  });

  test('an existing custom multiplier is preserved until replaced, with defaults for missing entries', () {
    final ini = '[EmuCore/GS]\nupscale_multiplier = 2.5\n';
    file.writeAsStringSync(ini);
    final custom = control('Internal Resolution');
    expect(custom.options[custom.selected], 'Custom · 2.5');
    custom.set(custom.selected);
    final renderer = control('Renderer');
    expect(renderer.options[renderer.selected], 'Automatic');
    expect(file.readAsStringSync(), ini);
    expect(saves, 0);

    choose('Renderer', 'Direct3D 12');
    expect(RetroSettings.read(file).options.singleWhere((option) => option.key == 'Renderer').value, '15');
    expect(RetroSettings.read(file).options.singleWhere((option) => option.key == 'upscale_multiplier').value, '2.5');
  });
}
