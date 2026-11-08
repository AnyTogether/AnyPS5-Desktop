part of 'trophies.dart';

abstract final class _Ps3Trophies {
  static const _languageCodes = <String, int>{
    'ja': 0,
    'en': 1,
    'fr': 2,
    'es': 3,
    'de': 4,
    'it': 5,
    'nl': 6,
    'pt': 7,
    'ru': 8,
    'ko': 9,
    'zh-tw': 10,
    'zh-hk': 10,
    'zh-hant': 10,
    'zh': 11,
    'fi': 12,
    'sv': 13,
    'da': 14,
    'no': 15,
    'nb': 15,
    'nn': 15,
    'pl': 16,
    'pt-br': 17,
    'en-gb': 18,
    'tr': 19,
  };
  static final _packageId = RegExp(r'^NPWR[0-9]{5}_[0-9]{2}$');
  static final _localizedFile = RegExp(r'^TROP_[0-9]{2}\.SFM$');

  static List<Directory> _packages(Game game) {
    try {
      return Directory(p.join(game.folder, 'PS3_GAME', 'TROPDIR'))
          .listSync()
          .whereType<Directory>()
          .where((entry) => _packageId.hasMatch(p.basename(entry.path).toUpperCase()))
          .toList()
        ..sort((left, right) => p.basename(left.path).compareTo(p.basename(right.path)));
    } on FileSystemException {
      return const [];
    }
  }

  static String _statePath(String system, Directory package) {
    final packageId = p.basename(package.path).toUpperCase();
    return p.join(system, 'rpcs3', 'dev_hdd0', 'home', '00000001', 'trophy', packageId, 'TROPUSR.DAT');
  }

  static String progressStamp(Game game, String system) {
    final stamps = <String>[];
    for (final package in _packages(game)) {
      final stat = FileStat.statSync(_statePath(system, package));
      if (stat.type != FileSystemEntityType.file) continue;
      final id = p.basename(package.path);
      stamps.add('$id:${stat.modified.microsecondsSinceEpoch}:${stat.changed.microsecondsSinceEpoch}:${stat.size}');
    }
    return stamps.join('|');
  }

  static TrophySet? load(Game game, String? system, List<String> languages) {
    var title = game.name;
    Uint8List? icon;
    final trophies = <Trophy>[];
    for (final (label, package) in _packages(game).indexed) {
      final files = _readTrp(_read(p.join(package.path, 'TROPHY.TRP')));
      if (files == null) continue;
      final state = system == null ? null : _read(_statePath(system, package));
      final loaded = _parse(files, label, languages, _readUnlocks(state));
      if (loaded.trophies.isEmpty) continue;
      if (trophies.isEmpty) {
        if (loaded.title.isNotEmpty) title = loaded.title;
        icon = loaded.icon;
      }
      trophies.addAll(loaded.trophies);
    }
    return trophies.isEmpty ? null : TrophySet(title: title, icon: icon, trophies: trophies);
  }

  static Uint8List? _read(String path) {
    try {
      return File(path).readAsBytesSync();
    } on FileSystemException {
      return null;
    }
  }

  static Map<String, Uint8List>? _readTrp(Uint8List? bytes) {
    const headerSize = 0x40;
    if (bytes == null || bytes.length < headerSize) return null;
    final data = ByteData.sublistView(bytes);
    if (data.getUint32(0) != 0xDCA24D00) return null;
    final declaredSize = data.getUint64(8);
    final count = data.getUint32(0x10);
    final stride = data.getUint32(0x14);
    final tableEnd = headerSize + count * stride;
    if (stride < 0x40 || count > 4096 || tableEnd > declaredSize || declaredSize > bytes.length) return null;
    final files = <String, Uint8List>{};
    for (var index = 0; index < count; index++) {
      final entry = headerSize + index * stride;
      final offset = data.getUint64(entry + 0x20);
      final length = data.getUint64(entry + 0x28);
      if (offset < tableEnd || offset > declaredSize || length < 0 || length > declaredSize - offset) return null;
      var end = entry;
      while (end < entry + 0x20 && bytes[end] != 0) {
        end++;
      }
      final name = ascii.decode(Uint8List.sublistView(bytes, entry, end), allowInvalid: true).toUpperCase();
      files[name] = Uint8List.sublistView(bytes, offset, offset + length);
    }
    return files;
  }

  static TrophySet _parse(Map<String, Uint8List> files, int label, List<String> languages, Map<int, DateTime> unlocks) {
    final available = files.keys.where(_localizedFile.hasMatch).toList()..sort();
    final preferred = <String>{
      for (final language in languages)
        for (final code in _codes(language)) 'TROP_${code.toString().padLeft(2, '0')}.SFM',
      'TROP_01.SFM',
      'TROP.SFM',
      ...available,
      'TROPCONF.SFM',
    };
    final translations = [
      for (final name in preferred)
        if (_xml(files[name]) case final XmlElement xml) xml,
    ];
    final definitions = _xml(files['TROPCONF.SFM'])?.findElements('trophy').toList();
    final rows = definitions != null && definitions.isNotEmpty
        ? definitions
        : translations.firstOrNull?.findElements('trophy') ?? const <XmlElement>[];
    final texts = <int, (String, String)>{};
    var title = '';
    for (final translation in translations) {
      if (title.isEmpty) title = _text(translation, 'title-name');
      for (final row in translation.findElements('trophy')) {
        final id = int.tryParse(row.getAttribute('id') ?? '');
        if (id == null) continue;
        final (name, detail) = texts[id] ?? ('', '');
        texts[id] = (name.isEmpty ? _text(row, 'name') : name, detail.isEmpty ? _text(row, 'detail') : detail);
      }
    }
    final trophies = <Trophy>[];
    for (final row in rows) {
      final id = int.tryParse(row.getAttribute('id') ?? '');
      final grade = TrophyGrade.byLetter(row.getAttribute('ttype'));
      if (id == null || id < 0 || grade == null) continue;
      final (name, detail) = texts[id] ?? ('', '');
      trophies.add(
        Trophy(
          serviceLabel: label,
          number: id,
          grade: grade,
          hidden: row.getAttribute('hidden') == 'yes',
          name: name,
          detail: detail,
          icon: files['TROP${id.toString().padLeft(3, '0')}.PNG'],
          unlocked: unlocks[id],
        ),
      );
    }
    return TrophySet(title: title, icon: files['ICON0.PNG'], trophies: trophies);
  }

  static Iterable<int> _codes(String language) sync* {
    final normalized = language.toLowerCase().replaceAll('_', '-');
    final parts = normalized.split('-');
    final base = parts.first;
    if (_languageCodes[normalized] case final int exact) yield exact;
    if (parts.length > 2) {
      if (_languageCodes['$base-${parts[1]}'] case final int script) yield script;
    }
    if (base != normalized) {
      if (_languageCodes[base] case final int fallback) yield fallback;
    }
  }

  static XmlElement? _xml(Uint8List? bytes) {
    if (bytes == null) return null;
    try {
      final root = XmlDocument.parse(utf8.decode(bytes)).rootElement;
      return root.name.local == 'trophyconf' ? root : root.getElement('trophyconf');
    } on FormatException {
      return null;
    } on XmlException {
      return null;
    }
  }

  static String _text(XmlElement element, String name) => element.getElement(name)?.innerText.trim() ?? '';

  static Map<int, DateTime> _readUnlocks(Uint8List? bytes) {
    const headerSize = 0x30;
    const tableSize = 0x20;
    const entrySize = 0x70;
    if (bytes == null || bytes.length < headerSize) return const {};
    final data = ByteData.sublistView(bytes);
    if (data.getUint32(0) != 0x818F54AD) return const {};
    final tableCount = data.getUint32(8);
    final tableEnd = headerSize + tableCount * tableSize;
    if (tableEnd > bytes.length) return const {};
    for (var index = 0; index < tableCount; index++) {
      final table = headerSize + index * tableSize;
      if (data.getUint32(table) != 6) continue;
      final count = data.getUint32(table + 0xC);
      final offset = data.getUint64(table + 0x10);
      if (data.getUint32(table + 4) != entrySize - 0x10 ||
          offset < tableEnd ||
          offset > bytes.length ||
          count > (bytes.length - offset) ~/ entrySize) {
        return const {};
      }
      final unlocked = <int, DateTime>{};
      for (var item = 0; item < count; item++) {
        final entry = offset + item * entrySize;
        if (data.getUint32(entry) != 6 || data.getUint32(entry + 0x14) != 1) continue;
        final date = _date(data.getUint64(entry + 0x28)) ?? _date(data.getUint64(entry + 0x20));
        if (date != null) unlocked[data.getUint32(entry + 0x10)] = date;
      }
      return unlocked;
    }
    return const {};
  }

  static DateTime? _date(int tick) {
    if (tick <= 0) return null;
    final microseconds = tick - Trophies.unixEpochTick;
    if (microseconds > 8640000000000000000) return null;
    return DateTime.fromMicrosecondsSinceEpoch(microseconds, isUtc: true);
  }
}
