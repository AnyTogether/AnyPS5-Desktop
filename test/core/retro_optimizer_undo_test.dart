import 'dart:io';

import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/retro_optimizer.dart';
import 'package:anyps5_desktop/core/retro_optimizer_undo.dart';
import 'package:anyps5_desktop/core/retro_settings.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _platform = RetroPlatform.ps2;
const _section = 'EmuCore/GS';
const _key = 'upscale_multiplier';

RetroOptimizationRecommendation _scale(int scale) => RetroOptimizationRecommendation(
  section: _section,
  key: _key,
  scale: scale,
  adapter: const RetroAdapter(name: 'Test GPU', dedicatedBytes: 8 << 30),
  displayHeight: 1440,
);

void main() {
  late Directory folder;
  late Directory journals;
  late File file;
  late RetroOptimizerUndo optimizer;

  setUp(() {
    folder = Directory.systemTemp.createTempSync('retro-optimizer-undo');
    addTearDown(() => folder.deleteSync(recursive: true));
    journals = Directory(p.join(folder.path, 'journal'));
    file = File(p.join(folder.path, 'PCSX2.ini'));
    optimizer = RetroOptimizerUndo(journals);
  });

  RetroSettings read() => RetroSettings.read(file);

  void apply(int scale, {RetroSettings? settings}) =>
      optimizer.apply(platform: _platform, settings: settings ?? read(), recommendation: _scale(scale));

  test('a fresh instance restores the previous value without altering other INI options', () {
    file.writeAsStringSync('; keep\r\n[$_section]\r\n$_key = 1.500000\r\nRenderer = -1\r\n');
    apply(4);
    read().set(_section, 'Renderer', '14');

    final restarted = RetroOptimizerUndo(journals);
    expect(restarted.canUndo(platform: _platform, settings: read()), isTrue);
    restarted.undo(platform: _platform, settings: read());
    expect(file.readAsStringSync(), '; keep\r\n[$_section]\r\n$_key = 1.500000\r\nRenderer = 14\r\n');
    expect(restarted.canUndo(platform: _platform, settings: read()), isFalse);
  });

  test('Undo removes a setting that was absent before optimization', () {
    const original = '[$_section]\nRenderer = -1\n';
    file.writeAsStringSync(original);
    apply(4);
    expect(read().options.singleWhere((option) => option.key == _key).value, '4');
    optimizer.undo(platform: _platform, settings: read());
    expect(file.readAsStringSync(), original);
  });

  test('Undo refuses a changed value or a different profile, including with a cached snapshot', () {
    file.writeAsStringSync('[$_section]\n$_key = 1\n');
    apply(4);
    final applied = read();
    final other = File(p.join(folder.path, 'other.ini'))..writeAsStringSync(file.readAsStringSync());
    final otherSettings = RetroSettings.read(other);
    expect(optimizer.canUndo(platform: _platform, settings: otherSettings), isFalse);
    expect(() => optimizer.undo(platform: _platform, settings: otherSettings), throwsStateError);

    read().set(_section, _key, '4.000000');
    expect(optimizer.canUndo(platform: _platform, settings: applied), isFalse);
    expect(() => optimizer.undo(platform: _platform, settings: applied), throwsStateError);
    expect(optimizer.canUndo(platform: _platform, settings: read()), isFalse);
    expect(read().options.single.value, '4.000000');
  });

  test('stale INI writes and no-op optimization preserve the previous undo', () {
    file.writeAsStringSync('[$_section]\n$_key = 1\nRenderer = -1\n');
    apply(4);
    final stale = read();
    read().set(_section, 'Renderer', '14');
    expect(() => apply(3, settings: stale), throwsStateError);
    expect(() => optimizer.undo(platform: _platform, settings: stale), throwsStateError);

    apply(4);
    expect(optimizer.canUndo(platform: _platform, settings: read()), isTrue);
    optimizer.undo(platform: _platform, settings: read());
    expect(file.readAsStringSync(), '[$_section]\n$_key = 1\nRenderer = 14\n');
  });

  test('an equivalent numeric setting creates no undo and retains its existing spelling', () {
    const original = '[$_section]\n$_key = 4.000000\n';
    file.writeAsStringSync(original);
    apply(4);
    expect(file.readAsStringSync(), original);
    expect(optimizer.canUndo(platform: _platform, settings: read()), isFalse);
  });

  test('a failed journal rename rolls back the resolution change', () {
    const original = '[$_section]\n$_key = 1.250000\nRenderer = -1\n';
    file.writeAsStringSync(original);
    Directory(p.join(journals.path, 'ps2.json')).createSync(recursive: true);

    expect(() => apply(4), throwsA(isA<FileSystemException>()));
    expect(file.readAsStringSync(), original);
    expect(optimizer.canUndo(platform: _platform, settings: read()), isFalse);
  });
}
