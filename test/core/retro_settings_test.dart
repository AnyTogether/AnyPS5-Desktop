import 'dart:io';

import 'package:anyps5_desktop/core/retro_settings.dart';
import 'package:test/test.dart';

void main() {
  test('editing one repeated binding preserves comments and other bindings', () {
    final root = Directory.systemTemp.createTempSync('retro-ini');
    addTearDown(() => root.deleteSync(recursive: true));
    final file = File('${root.path}/settings.ini')
      ..writeAsStringSync('; keep\r\n[Pad1]\r\nCross = Keyboard/K\r\nCross = SDL-0/FaceSouth\r\n');
    final settings = RetroSettings.read(file);
    expect(settings.options.map((entry) => entry.value), ['Keyboard/K', 'SDL-0/FaceSouth']);
    settings.replace(settings.options.first, 'Keyboard/X');
    expect(file.readAsStringSync(), '; keep\r\n[Pad1]\r\nCross = Keyboard/X\r\nCross = SDL-0/FaceSouth\r\n');
    expect(() => settings.replace(settings.options.last, 'SDL-1/FaceSouth'), throwsStateError);
    expect(() => RetroSettings.read(file).add('Pad1', 'Cross', 'SDL-1/FaceSouth\n[UI]'), throwsFormatException);
    RetroSettings.read(file).add('UI', 'StartFullscreen', 'true');
    expect(RetroSettings.read(file).options.last.value, 'true');
  });
}
