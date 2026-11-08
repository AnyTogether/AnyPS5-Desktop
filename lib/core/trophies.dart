import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import 'game_library.dart';

part 'ps3_trophies.dart';

enum TrophyGrade {
  platinum('P', 300),
  gold('G', 90),
  silver('S', 30),
  bronze('B', 15);

  const TrophyGrade(this.letter, this.points);

  final String letter;

  /// The console's weights: the percentage counts a gold trophy as six bronze ones.
  final int points;

  static TrophyGrade? byLetter(String? letter) {
    for (final grade in values) {
      if (grade.letter == letter) return grade;
    }
    return null;
  }
}

class Trophy {
  const Trophy({
    required this.serviceLabel,
    required this.number,
    required this.grade,
    required this.hidden,
    required this.name,
    required this.detail,
    this.icon,
    this.unlocked,
    this.progress,
  });

  final int serviceLabel;
  final int number;
  final TrophyGrade grade;
  final bool hidden;
  final String name;
  final String detail;
  final Uint8List? icon;
  final DateTime? unlocked;

  /// The stat a progressive trophy counts, and its target.
  final (int, int)? progress;

  String get id => '$serviceLabel/$number';
}

/// A game's trophies: the list and texts from the trophy packages in the dump's
/// sce_sys/trophy2, and what the engine recorded in the installed game's _trophy folder.
class TrophySet {
  const TrophySet({required this.title, required this.trophies, this.icon});

  final String title;
  final Uint8List? icon;
  final List<Trophy> trophies;

  int get unlockedCount => trophies.where((trophy) => trophy.unlocked != null).length;

  (int, int) count(TrophyGrade grade) {
    final graded = trophies.where((trophy) => trophy.grade == grade);
    return (graded.where((trophy) => trophy.unlocked != null).length, graded.length);
  }

  /// Unlocked points over all points, from 0 to 100.
  int get percent {
    final total = trophies.fold(0, (sum, trophy) => sum + trophy.grade.points);
    if (total == 0) return 0;
    final unlocked = trophies.fold(0, (sum, trophy) => sum + (trophy.unlocked != null ? trophy.grade.points : 0));
    return unlocked * 100 ~/ total;
  }
}

/// The Dart form of the macOS launcher's Trophies.swift.
abstract final class Trophies {
  static const _recordSuffix = '.txt';
  static const _statsSuffix = '.stats.txt';

  /// The engine's ticks are microseconds since 1 January of year 1.
  static const unixEpochTick = 62135596800000000;

  static TrophySet? loadPs3(Game game, {String? system, List<String> languages = const []}) {
    return _Ps3Trophies.load(game, system, languages);
  }

  static String ps3ProgressStamp(Game game, String system) => _Ps3Trophies.progressStamp(game, system);

  /// The game's trophies in the first of [languages] its packages have, null when it has none.
  /// [installed] is the installed game's folder, which holds the unlocks; before the game is
  /// installed every trophy shows as locked.
  static TrophySet? load(Game game, {String? installed, List<String> languages = const []}) {
    final folder = p.join(game.folder, 'sce_sys', 'trophy2');
    final records = installed == null ? null : p.join(installed, '_trophy');
    var title = game.name;
    Uint8List? setIcon;
    final trophies = <Trophy>[];
    for (var label = 0; label < 100; label++) {
      final package = File(p.join(folder, 'trophy${label.toString().padLeft(2, '0')}.ucp'));
      Uint8List data;
      try {
        data = package.readAsBytesSync();
      } on FileSystemException {
        if (label == 0) continue;
        break;
      }
      final files = readUcp(data);
      if (files == null) continue;
      final loaded = _parse(files, label, languages, records);
      if (loaded == null) continue;
      if (label == 0 || trophies.isEmpty) {
        title = loaded.title;
        setIcon = loaded.icon;
      }
      trophies.addAll(loaded.trophies);
    }
    return trophies.isEmpty ? null : TrophySet(title: title, icon: setIcon, trophies: trophies);
  }

  /// Every trophy the engine recorded as earned in the installed game, by trophy id
  /// (`<service label>/<number>`), cheap enough to read every second.
  static Set<String> earned(String installed) {
    final records = p.join(installed, '_trophy');
    final List<String> names;
    try {
      names = Directory(records).listSync().map((entry) => p.basename(entry.path)).toList();
    } on FileSystemException {
      return const {};
    }
    final labels = <int>{};
    for (final name in names) {
      if (!name.endsWith(_recordSuffix) || name.endsWith(_statsSuffix)) continue;
      final label = int.tryParse(name.substring(0, name.length - _recordSuffix.length).split('_').last);
      if (label != null) labels.add(label);
    }
    return {
      for (final label in labels)
        for (final number in unlocked(records, label).keys) '$label/$number',
    };
  }

  /// The trophy package's files: a big-endian table of names, offsets and sizes.
  static Map<String, Uint8List>? readUcp(Uint8List bytes) {
    int? number(int offset, int size) {
      if (offset < 0 || offset + size > bytes.length) return null;
      var value = 0;
      for (var index = 0; index < size; index++) {
        value = value << 8 | bytes[offset + index];
      }
      return value;
    }

    final count = number(0x10, 4);
    final toc = number(0x14, 4);
    if (number(0, 4) != 0xB228C60A || number(4, 4) != 1 || count == null || toc == null || count > 4096) return null;
    final files = <String, Uint8List>{};
    for (var index = 0; index < count; index++) {
      final entry = toc + 0x20 + index * 0x40;
      final offset = number(entry + 0x20, 8);
      final length = number(entry + 0x28, 8);
      if (offset == null || length == null || offset < 0 || length < 0 || offset + length > bytes.length) return null;
      final field = bytes.sublist(entry, entry + 0x20);
      final end = field.indexOf(0);
      final name = utf8.decode(field.sublist(0, end < 0 ? field.length : end), allowMalformed: true);
      files[name] = Uint8List.sublistView(bytes, offset, offset + length);
    }
    return files;
  }

  static TrophySet? _parse(Map<String, Uint8List> files, int label, List<String> languages, String? records) {
    final conf = _json(files['tropconf.json']);
    final definitions = conf?['trophies'];
    if (conf == null || definitions is! List<dynamic>) return null;
    final fallback = conf['defaultLanguage'] as String? ?? 'en-US';
    final candidates = [...languages, 'en-US', 'en-GB', fallback];
    final available = files.keys
        .where((name) => name.startsWith('tropmeta_') && name.endsWith('.json'))
        .map((name) => name.substring(9, name.length - 5))
        .toSet();
    final sorted = available.toList()..sort();
    final language = candidates.firstWhere(available.contains, orElse: () => sorted.isEmpty ? '' : sorted.first);
    final metadata = _json(files['tropmeta_$language.json'])?['metadata'];
    if (metadata is! Map<String, dynamic>) return null;
    final texts = <int, (String, String)>{};
    for (final entry in metadata['trophyMetadata'] as List<dynamic>? ?? const []) {
      if (entry is! Map<String, dynamic>) continue;
      final id = _identifier(entry['id']);
      if (id == null) continue;
      texts[id] = (entry['name'] as String? ?? '', entry['detail'] as String? ?? '');
    }
    final unlocks = records == null ? const <int, DateTime>{} : unlocked(records, label);
    final stats = records == null ? const <int, int>{} : statValues(records, label);
    final trophies = <Trophy>[];
    for (final definition in definitions) {
      if (definition is! Map<String, dynamic>) continue;
      final id = _identifier(definition['id']);
      final grade = TrophyGrade.byLetter(definition['grade'] as String?);
      if (id == null || grade == null) continue;
      (int, int)? progress;
      final condition = definition['unlockCondition'];
      if (condition is Map<String, dynamic> && condition['progressive'] == true) {
        final stat = _unsigned(condition['udsStatId']);
        final target = _unsigned(condition['targetValue']);
        if (stat != null && target != null && target > 1) {
          final value = stats[stat] ?? 0;
          progress = (value < target ? value : target, target);
        }
      }
      final text = texts[id] ?? ('', '');
      trophies.add(
        Trophy(
          serviceLabel: label,
          number: id,
          grade: grade,
          hidden: definition['hidden'] == true,
          name: text.$1,
          detail: text.$2,
          icon: files['trop${id.toString().padLeft(4, '0')}.png'],
          unlocked: unlocks[id],
          progress: progress,
        ),
      );
    }
    final titleMetadata = metadata['titleMetadata'];
    final title = titleMetadata is Map<String, dynamic> ? titleMetadata['name'] as String? ?? '' : '';
    final iconName = (files.keys.where((name) => name.startsWith('icon0')).toList()..sort()).firstOrNull;
    final icon = files['icon0_$language.png'] ?? files['icon0.png'] ?? (iconName == null ? null : files[iconName]);
    return TrophySet(title: title, icon: icon, trophies: trophies);
  }

  /// Every user's unlocks of the package: `<user>_<label>.txt` lines of `<trophy id> <tick>`.
  static Map<int, DateTime> unlocked(String records, int label) {
    final result = <int, DateTime>{};
    for (final (key, tick) in _pairs(records, label, _recordSuffix)) {
      if (tick < unixEpochTick) continue;
      final date = DateTime.fromMicrosecondsSinceEpoch(tick - unixEpochTick, isUtc: true);
      final earlier = result[key];
      result[key] = earlier == null || date.isBefore(earlier) ? date : earlier;
    }
    return result;
  }

  /// The stats the engine counted: `<user>_<label>.stats.txt` lines of `<stat id> <value>`.
  static Map<int, int> statValues(String records, int label) {
    final result = <int, int>{};
    for (final (key, value) in _pairs(records, label, _statsSuffix)) {
      final current = result[key];
      result[key] = current == null || value > current ? value : current;
    }
    return result;
  }

  static List<(int, int)> _pairs(String records, int label, String suffix) {
    final List<FileSystemEntity> entries;
    try {
      entries = Directory(records).listSync();
    } on FileSystemException {
      return const [];
    }
    final ending = '_$label$suffix';
    final result = <(int, int)>[];
    for (final entry in entries) {
      final name = p.basename(entry.path);
      if (!name.endsWith(ending) || int.tryParse(name.substring(0, name.length - ending.length)) == null) continue;
      if (suffix == _recordSuffix && name.endsWith(_statsSuffix)) continue;
      String text;
      try {
        text = File(entry.path).readAsStringSync();
      } on FileSystemException {
        continue;
      }
      for (final line in const LineSplitter().convert(text)) {
        final parts = line.trim().split(' ');
        if (parts.length != 2) continue;
        final key = int.tryParse(parts[0]);
        final value = int.tryParse(parts[1]);
        if (key != null && value != null) result.add((key, value));
      }
    }
    return result;
  }

  static Map<String, dynamic>? _json(Uint8List? data) {
    if (data == null) return null;
    final start = data.length >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF ? 3 : 0;
    try {
      final value = jsonDecode(utf8.decode(data.sublist(start), allowMalformed: true));
      return value is Map<String, dynamic> ? value : null;
    } on FormatException {
      return null;
    }
  }

  /// Ids and stat numbers come as "0007" strings or as plain numbers.
  static int? _unsigned(Object? value) {
    if (value is String) return int.tryParse(value);
    if (value is int && value >= 0) return value;
    if (value is double && value >= 0 && value == value.roundToDouble()) return value.toInt();
    return null;
  }

  static int? _identifier(Object? value) {
    final number = _unsigned(value);
    return number != null && number <= 0x7FFFFFFF ? number : null;
  }
}
