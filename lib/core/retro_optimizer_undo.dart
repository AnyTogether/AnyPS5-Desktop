import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'game_library.dart';
import 'retro_optimizer.dart';
import 'retro_settings.dart';

typedef _UndoEntry = ({String section, String key, String? previous, String applied});

class RetroOptimizerUndo {
  const RetroOptimizerUndo(this.directory);

  final Directory directory;

  void apply({
    required RetroPlatform platform,
    required RetroSettings settings,
    required RetroOptimizationRecommendation recommendation,
  }) {
    final section = recommendation.section;
    final key = recommendation.key;
    final previous = _option(settings, section, key)?.value;
    final scale = recommendation.scale;
    if (previous != null && double.tryParse(previous) == scale) {
      final current = _option(RetroSettings.read(settings.file), section, key)?.value;
      if (current != null && double.tryParse(current) == scale) return;
    }
    final applied = scale.toString();
    final journal = _journal(platform);
    directory.createSync(recursive: true);
    final temp = directory.createTempSync('pending-');
    try {
      final staged = File(p.join(temp.path, 'undo.json'))
        ..writeAsStringSync(
          jsonEncode({
            'path': settings.file.absolute.path,
            'section': section,
            'key': key,
            'previous': previous,
            'applied': applied,
          }),
          flush: true,
        );
      settings.set(section, key, applied);
      try {
        staged.renameSync(journal.path);
      } on FileSystemException {
        _restoreIfCurrent(settings.file, section, key, applied, previous);
        rethrow;
      }
    } finally {
      temp.deleteSync(recursive: true);
    }
  }

  bool canUndo({required RetroPlatform platform, required RetroSettings settings}) =>
      _currentEntry(platform, settings) != null;

  void undo({required RetroPlatform platform, required RetroSettings settings}) {
    final entry = _currentEntry(platform, settings);
    if (entry == null) throw StateError('The optimized resolution or emulator profile changed.');
    _writeValue(settings, entry.section, entry.key, entry.previous);
    try {
      _journal(platform).deleteSync();
    } on FileSystemException {
      _restoreIfCurrent(settings.file, entry.section, entry.key, entry.previous, entry.applied);
      rethrow;
    }
  }

  File _journal(RetroPlatform platform) => File(p.join(directory.path, '${platform.name}.json'));

  _UndoEntry? _currentEntry(RetroPlatform platform, RetroSettings settings) {
    try {
      final decoded = jsonDecode(_journal(platform).readAsStringSync());
      if (decoded case {
        'path': final String path,
        'section': final String section,
        'key': final String key,
        'previous': final String? previous,
        'applied': final String applied,
      }) {
        if (path != settings.file.absolute.path || _option(settings, section, key)?.value != applied) return null;
        if (_option(RetroSettings.read(settings.file), section, key)?.value != applied) return null;
        return (section: section, key: key, previous: previous, applied: applied);
      }
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    } on StateError {
      return null;
    }
    return null;
  }

  static RetroOption? _option(RetroSettings settings, String section, String key) {
    final matches = settings.options.where((option) => option.section == section && option.key == key).take(2).toList();
    if (matches.length > 1) throw StateError('The resolution setting has repeated values.');
    return matches.firstOrNull;
  }

  static void _writeValue(RetroSettings settings, String section, String key, String? value) {
    if (value != null) {
      settings.set(section, key, value);
    } else if (_option(settings, section, key) case final RetroOption option) {
      settings.remove(option);
    }
  }

  static void _restoreIfCurrent(File file, String section, String key, String? expected, String? value) {
    final settings = RetroSettings.read(file);
    if (_option(settings, section, key)?.value == expected) _writeValue(settings, section, key, value);
  }
}
