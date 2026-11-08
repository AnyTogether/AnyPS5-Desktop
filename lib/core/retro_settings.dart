import 'dart:io';

import 'package:path/path.dart' as p;

import 'game_library.dart';

typedef RetroOption = ({int line, String section, String key, String value});

class RetroSettings {
  RetroSettings._(this.file, this._original);

  factory RetroSettings.read(File file) => RetroSettings._(file, file.existsSync() ? file.readAsStringSync() : null);

  static File configFile(String program, RetroPlatform platform) {
    final folder = p.dirname(program);
    return File(switch (platform) {
      RetroPlatform.ps1 => p.join(folder, 'settings.ini'),
      RetroPlatform.ps2 => p.join(folder, 'inis', 'PCSX2.ini'),
      RetroPlatform.ps3 => throw ArgumentError('PS3 uses embedded emulator settings.'),
    });
  }

  final File file;
  final String? _original;
  String get _newline => _original?.contains('\r\n') == true ? '\r\n' : '\n';
  List<String> get _lines => (_original ?? '').split(RegExp(r'\r?\n'));

  List<RetroOption> get options {
    var section = '';
    final options = <RetroOption>[];
    final lines = _lines;
    for (var line = 0; line < lines.length; line++) {
      final text = lines[line].trim();
      if (text.startsWith('[') && text.endsWith(']')) {
        section = text.substring(1, text.length - 1);
        continue;
      }
      if (section.isEmpty || text.startsWith(';') || text.startsWith('#')) continue;
      final equals = text.indexOf('=');
      if (equals < 1) continue;
      options.add((
        line: line,
        section: section,
        key: text.substring(0, equals).trim(),
        value: text.substring(equals + 1).trim(),
      ));
    }
    return options;
  }

  void replace(RetroOption option, String value) {
    _validateValue(value);
    final lines = _lines;
    lines[option.line] = _replaceValue(lines[option.line], value);
    _save(lines);
  }

  String _replaceValue(String line, String value) {
    final equals = line.indexOf('=');
    final whitespace = RegExp(r'^\s*').stringMatch(line.substring(equals + 1))!;
    return '${line.substring(0, equals + 1)}$whitespace$value';
  }

  void remove(RetroOption option) {
    if (!options.contains(option)) throw StateError('This setting is not in the profile snapshot.');
    final lines = _lines..removeAt(option.line);
    _save(lines);
  }

  void add(String section, String key, String value) {
    _validateName(section, key);
    _validateValue(value);
    if (options.any((option) => option.section == section && option.key == key)) {
      throw const FormatException('This setting already exists. Edit it in its section.');
    }
    final lines = _lines;
    final sectionLine = lines.lastIndexWhere((line) => line.trim() == '[$section]');
    if (sectionLine < 0) {
      lines.addAll(['[$section]', '$key = $value', '']);
    } else {
      lines.insert(sectionLine + 1, '$key = $value');
    }
    _save(lines);
  }

  void _validateName(String section, String key) {
    if (section.trim().isEmpty || key.trim().isEmpty || RegExp(r'[\r\n\[\]=]').hasMatch('$section$key')) {
      throw const FormatException('Enter a section and setting name.');
    }
  }

  void set(String section, String key, String value) {
    final matches = options.where((option) => option.section == section && option.key == key).toList();
    if (matches.length > 1) throw StateError('This setting has repeated values. Edit its individual entries.');
    if (matches.isEmpty) {
      add(section, key, value);
    } else {
      replace(matches.single, value);
    }
  }

  void setMany(String section, Map<String, String> values) {
    if (values.isEmpty) return;
    final lines = _lines;
    final existing = options.where((option) => option.section == section).toList();
    final added = <String>[];
    for (final entry in values.entries) {
      _validateName(section, entry.key);
      _validateValue(entry.value);
      final matches = existing.where((option) => option.key == entry.key).toList();
      if (matches.length > 1) throw StateError('This setting has repeated values. Edit its individual entries.');
      if (matches.isEmpty) {
        added.add('${entry.key} = ${entry.value}');
      } else {
        final index = matches.single.line;
        lines[index] = _replaceValue(lines[index], entry.value);
      }
    }
    if (added.isNotEmpty) {
      final header = lines.lastIndexWhere((line) => line.trim() == '[$section]');
      if (header < 0) {
        lines.addAll(['[$section]', ...added, '']);
      } else {
        lines.insertAll(header + 1, added);
      }
    }
    _save(lines);
  }

  void _validateValue(String value) {
    if (value.contains('\r') || value.contains('\n') || value.contains('\u0000')) {
      throw const FormatException('Enter a single-line value.');
    }
  }

  void _save(List<String> lines) {
    final current = file.existsSync() ? file.readAsStringSync() : null;
    if (current != _original) throw StateError('The emulator settings changed. Reload and try again.');
    file.parent.createSync(recursive: true);
    final temp = file.parent.createTempSync('.anyps5-settings-');
    try {
      File(p.join(temp.path, 'settings.ini'))
        ..writeAsStringSync(lines.join(_newline), flush: true)
        ..renameSync(file.path);
    } finally {
      temp.deleteSync(recursive: true);
    }
  }
}
