import 'dart:io';

import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/retro_settings.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/retro_controller_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final platform in RetroPlatform.ps1AndPs2) {
    test('${platform.name} controller choices save standard bindings and preserve custom and repeated bindings', () {
      final root = Directory.systemTemp.createTempSync('retro-controls');
      addTearDown(() => root.deleteSync(recursive: true));
      final file = File('${root.path}/settings.ini')
        ..writeAsStringSync(
          '[Pad1]\nType = ${platform == RetroPlatform.ps1 ? 'AnalogController' : 'DualShock2'}\n'
          'Cross = SDL-0/${platform == RetroPlatform.ps1 ? 'A' : 'FaceSouth'}\nCross = Keyboard/K\n'
          'Circle = SDL-7/Button99\nDeadzone = 0.15\n',
        );
      var saved = 0;
      List<PanelRow> rows() => RetroControllerSettings.rows(
        settings: RetroSettings.read(file),
        platform: platform,
        section: 'Pad1',
        save: (apply) {
          apply();
          saved++;
        },
      );

      final crossRows = rows().where((row) => row.title == 'Cross').toList();
      expect(crossRows, hasLength(2));
      final cross = crossRows.first.kind as ChoiceRow;
      expect(cross.options[cross.selected], 'Controller 1 · Cross');
      cross.set(cross.options.indexOf('Keyboard · X'));
      expect(RetroSettings.read(file).options.where((option) => option.key == 'Cross').map((option) => option.value), [
        'Keyboard/X',
        'Keyboard/K',
      ]);
      expect(saved, 1);

      final custom = rows().singleWhere((row) => row.title == 'Circle').kind as ChoiceRow;
      expect(custom.options[custom.selected], 'Custom · SDL-7/Button99');
      custom.set(custom.selected);
      expect(RetroSettings.read(file).options.singleWhere((option) => option.key == 'Circle').value, 'SDL-7/Button99');
      expect(RetroSettings.read(file).options.singleWhere((option) => option.key == 'Deadzone').value, '0.15');

      final unbind = rows().firstWhere((row) => row.title == 'Cross').kind as ChoiceRow;
      unbind.set(unbind.options.indexOf('Unbound'));
      expect(RetroSettings.read(file).options.where((option) => option.key == 'Cross').map((option) => option.value), [
        '',
        'Keyboard/K',
      ]);

      final trigger = rows().singleWhere((row) => row.title == 'L2').kind as ChoiceRow;
      trigger.set(trigger.options.indexOf('Controller 2 · L2'));
      expect(RetroSettings.read(file).options.singleWhere((option) => option.key == 'L2').value, 'SDL-1/+LeftTrigger');

      final up = rows().singleWhere((row) => row.title == 'D-pad up').kind as ChoiceRow;
      up.set(up.options.indexOf('Keyboard · Up arrow'));
      expect(
        RetroSettings.read(file).options.singleWhere((option) => option.key == 'Up').value,
        platform == RetroPlatform.ps1 ? 'Keyboard/UpArrow' : 'Keyboard/Up',
      );
      final start = rows().singleWhere((row) => row.title == 'Start').kind as ChoiceRow;
      start.set(start.options.indexOf('Keyboard · Enter'));
      expect(
        RetroSettings.read(file).options.singleWhere((option) => option.key == 'Start').value,
        platform == RetroPlatform.ps1 ? 'Keyboard/Enter' : 'Keyboard/Return',
      );

      final faceButtons = platform == RetroPlatform.ps1
          ? {'Cross': 'A', 'Circle': 'B', 'Square': 'X', 'Triangle': 'Y'}
          : {'Cross': 'FaceSouth', 'Circle': 'FaceEast', 'Square': 'FaceWest', 'Triangle': 'FaceNorth'};
      for (final entry in faceButtons.entries) {
        final binding = rows().firstWhere((row) => row.title == entry.key).kind as ChoiceRow;
        binding.set(binding.options.indexOf('Controller 1 · ${entry.key}'));
        expect(
          RetroSettings.read(file).options.firstWhere((option) => option.key == entry.key).value,
          'SDL-0/${entry.value}',
        );
      }
    });
  }

  test('controller type and vibration choices retain custom devices without keyboard motor bindings', () {
    final root = Directory.systemTemp.createTempSync('retro-controls');
    addTearDown(() => root.deleteSync(recursive: true));
    final file = File('${root.path}/settings.ini')
      ..writeAsStringSync('[Pad2]\nType = GunCon\nLargeMotor = SDL-0/LargeMotor\n');
    final rows = RetroControllerSettings.rows(
      settings: RetroSettings.read(file),
      platform: RetroPlatform.ps1,
      section: 'Pad2',
      save: (apply) => apply(),
    );
    final type = rows.singleWhere((row) => row.title == 'Port 2 controller').kind as ChoiceRow;
    expect(type.options[type.selected], 'Custom · GunCon');
    final motor = rows.singleWhere((row) => row.title == 'Strong vibration').kind as ChoiceRow;
    expect(motor.options, isNot(contains(startsWith('Keyboard'))));
    expect(motor.options[motor.selected], 'Controller 1 · Strong vibration');
  });
}
