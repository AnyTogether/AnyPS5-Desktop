import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'binary.dart';
import 'family/family_rules.dart' show AgeLevels;
import 'game_addons.dart';
import 'ps3_disc.dart';
import 'self_unwrap.dart';

/// What a dump's eboot.bin is.
enum ExecutableKind {
  /// A plain ELF (an unwrapped dump).
  elf,

  /// A SELF container, or a re-signed one with its ELF kept as eboot.bin.esbak.
  container,

  /// Neither: an encrypted or unknown file.
  unreadable,

  disc,
}

enum RetroPlatform {
  ps1('DuckStation'),
  ps2('PCSX2'),
  ps3('RPCS3');

  const RetroPlatform(this.emulator);
  final String emulator;
}

typedef RetroDisc = ({RetroPlatform platform, String path});

/// A PS5 game dump found in the games folder: a folder with sce_sys/param.json and an eboot.bin.
class Game {
  Game({
    required this.folder,
    required this.titleId,
    required this.name,
    required this.names,
    required this.defaultLanguage,
    required this.version,
    required this.executable,
    this.icon,
    this.background,
    this.music,
    this.retro,
    this.ageLevels,
    this.update,
    this.addons = const [],
    this.libraryId,
  });

  /// The dump's folder, as the scan found it.
  final String folder;
  final String titleId;

  /// The name in the dump's default language.
  final String name;

  /// Every language's name, by locale tag (en-US, tr-TR...).
  final Map<String, String> names;
  final String defaultLanguage;
  final String version;
  final ExecutableKind executable;

  /// sce_sys/icon0.png, pic0.png and snd0.at9 when the dump has them.
  final String? icon;
  final String? background;
  final String? music;
  final RetroDisc? retro;

  /// param.json's age ratings (`ageLevel`): "default" or a region such as "US", to an age; null
  /// when the dump has none.
  final Map<String, int>? ageLevels;

  /// The update dumped beside the game ([GameAddons]), null when there is none.
  final GameUpdate? update;

  /// The add-ons dumped beside the game ([GameAddons]).
  final List<GameAddon> addons;

  /// What the engine needs to see them (ANYPS5_UPDATE_DIR, ANYPS5_ADDCONT_DIRS).
  Map<String, String> get addonEnvironment => GameAddons.environment(update: update, addons: addons);

  final String? libraryId;
  String get id => libraryId ?? folder;

  /// The name in the first of [languages] the dump has (a tag such as tr-TR, or just tr),
  /// else the default name.
  String nameFor(List<String> languages) {
    for (final language in languages) {
      final exact = names[language];
      if (exact != null && exact.isNotEmpty) return exact;
      final prefix = language.split('-').first.toLowerCase();
      for (final entry in names.entries) {
        if (entry.key.split('-').first.toLowerCase() == prefix && entry.value.isNotEmpty) {
          return entry.value;
        }
      }
    }
    return name;
  }

  /// The title ID as a file name and identifier part: letters and digits only, lower case.
  String get slug => titleId.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  @override
  bool operator ==(Object other) => other is Game && other.folder == folder;

  @override
  int get hashCode => folder.hashCode;

  @override
  String toString() => 'Game($titleId, $name, $folder)';
}

/// What a look through the games folder found: the games, and the folders that look like a dump
/// still being copied (a sce_sys folder or an eboot.bin, but no whole game yet).
class LibrarySurvey {
  const LibrarySurvey(this.games, this.incomplete, {this.folders = const {}, this.roots = const {}});

  final List<Game> games;
  final List<String> incomplete;

  /// From [GameLibrary.surveyAll]: each games folder in order, with the games found in it; null
  /// for a folder that is not there (its drive unplugged).
  final Map<String, int?> folders;

  /// From [GameLibrary.surveyAll]: the games folder each game was found in, by [Game.id].
  final Map<String, String> roots;
}

abstract final class GameLibrary {
  /// Where the launcher keeps what it makes inside the games folder.
  static const storeName = '.AnyPS5';
  static const _skipped = {storeName, 'sce_sys', 'sce_module', 'sce_modules', 'prx', 'out', 'rel'};

  /// Finds every game folder under [root], down to three levels, sorted by name.
  static List<Game> scan(String root, {bool includeRetro = false}) => survey(root, includeRetro: includeRetro).games;

  /// The games under [root] and the dumps not whole yet. Cheap: a listing per level and each
  /// game's param.json.
  static LibrarySurvey survey(String root, {bool includeRetro = false}) {
    final found = <Game>[];
    final incomplete = <String>[];
    _visit(root, 0, found, incomplete, includeRetro);
    // A game's update and add-ons are not games of their own, nor dumps still being copied.
    final claimed = GameAddons.claimed(found.map((game) => (update: game.update, addons: game.addons)));
    if (claimed.isNotEmpty) {
      found.removeWhere((game) => GameAddons.isClaimed(game.folder, claimed));
      incomplete.removeWhere((folder) => GameAddons.isClaimed(folder, claimed));
    }
    found.sort(_byName);
    return LibrarySurvey(found, incomplete);
  }

  /// The library of several games folders ([roots], in order): every folder's games, sorted as
  /// [survey] sorts them. A title found in more than one folder shows once, from the folder that
  /// comes first; two dumps of one title in the same folder both show, as they do in one folder.
  /// A folder that is not there is skipped and counted as null.
  static LibrarySurvey surveyAll(List<String> roots, {bool includeRetro = false}) {
    final games = <Game>[];
    final incomplete = <String>[];
    final folders = <String, int?>{};
    final titles = <String>{};
    final found = <String, String>{};
    for (final root in roots) {
      if (!Directory(root).existsSync()) {
        folders[root] = null;
        continue;
      }
      final here = survey(root, includeRetro: includeRetro);
      folders[root] = here.games.length;
      final earlier = {...titles};
      for (final game in here.games) {
        titles.add(game.titleId);
        if (earlier.contains(game.titleId) || found.containsKey(game.id)) continue;
        games.add(game);
        found[game.id] = root;
      }
      incomplete.addAll(here.incomplete.where((folder) => !incomplete.contains(folder)));
    }
    games.sort(_byName);
    return LibrarySurvey(games, incomplete, folders: folders, roots: found);
  }

  static int _byName(Game a, Game b) {
    final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    return byName != 0 ? byName : a.folder.compareTo(b.folder);
  }

  /// Whether two scans show the same library: the same folders, names, art and states.
  static bool sameListing(List<Game> left, List<Game> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      final a = left[index], b = right[index];
      if (a.folder != b.folder ||
          a.titleId != b.titleId ||
          a.name != b.name ||
          a.version != b.version ||
          a.executable != b.executable ||
          a.retro != b.retro ||
          a.icon != b.icon ||
          a.background != b.background ||
          a.music != b.music ||
          a.update != b.update ||
          !_sameAddons(a.addons, b.addons) ||
          !_sameNames(a.names, b.names)) {
        return false;
      }
    }
    return true;
  }

  static bool _sameAddons(List<GameAddon> a, List<GameAddon> b) =>
      a.length == b.length &&
      [for (var index = 0; index < a.length; index++) a[index] == b[index]].every((same) => same);

  static bool _sameNames(Map<String, String> a, Map<String, String> b) =>
      a.length == b.length && a.entries.every((entry) => b[entry.key] == entry.value);

  static void _visit(String folder, int depth, List<Game> found, List<String> incomplete, bool includeRetro) {
    final game = inspect(folder, includeRetro: includeRetro);
    if (game != null) {
      found.add(game);
      return;
    }
    if (Directory(p.join(folder, 'sce_sys')).existsSync() || File(p.join(folder, 'eboot.bin')).existsSync()) {
      incomplete.add(folder);
    }
    if (!includeRetro && depth >= 3) return;
    List<FileSystemEntity> entries;
    try {
      entries = Directory(folder).listSync(followLinks: true);
    } on FileSystemException {
      return;
    }
    entries.sort((a, b) => a.path.compareTo(b.path));
    if (includeRetro &&
        !File(p.join(folder, 'retro.json')).existsSync() &&
        !File(p.join(folder, 'eboot.bin')).existsSync() &&
        !Directory(p.join(folder, 'sce_sys')).existsSync()) {
      found.addAll(_scanRetroFiles(folder, entries.whereType<File>()));
    }
    if (depth >= 3) return;
    for (final entry in entries) {
      final name = p.basename(entry.path);
      if (name.startsWith('.') || _skipped.contains(name)) continue;
      if (entry is Directory) _visit(entry.path, depth + 1, found, incomplete, includeRetro);
    }
  }

  static List<Game> _scanRetroFiles(String folder, Iterable<File> files) {
    final discs = <String, RetroPlatform>{};
    final playlists = <File>[];
    final ps1Folder = p.split(folder).any((part) => {'ps1', 'psx', 'playstation'}.contains(part.toLowerCase()));
    final ps2Folder = p.split(folder).any((part) => {'ps2', 'playstation 2'}.contains(part.toLowerCase()));
    for (final file in files) {
      try {
        switch (p.extension(file.path).toLowerCase()) {
          case '.m3u':
            playlists.add(file);
          case '.cue' when !ps2Folder && _cueTracks(file).isNotEmpty:
            discs[file.path] = RetroPlatform.ps1;
          case '.pbp' when _fileMagic(file, [0, 80, 66, 80]):
            discs[file.path] = RetroPlatform.ps1;
          case '.chd' when ps1Folder != ps2Folder && _fileMagic(file, ascii.encode('MComprHD')):
            discs[file.path] = ps1Folder ? RetroPlatform.ps1 : RetroPlatform.ps2;
          case '.iso' when _ps2Iso(file):
            discs[file.path] = RetroPlatform.ps2;
        }
      } on FileSystemException {
        continue;
      }
    }
    final claimed = <String>{};
    for (final playlist in playlists) {
      try {
        final tracks = ps1PlaylistDiscs(playlist.path);
        if (tracks.isNotEmpty && tracks.every((track) => discs[track] == RetroPlatform.ps1)) {
          discs[playlist.path] = RetroPlatform.ps1;
          claimed.addAll(tracks);
        }
      } on FileSystemException {
        continue;
      }
    }
    return [
      for (final entry in discs.entries)
        if (!claimed.contains(entry.key)) _discoveredRetro(folder, entry.key, entry.value),
    ];
  }

  /// Paths in core order. Reject the whole playlist if a disc is missing.
  static List<String> ps1PlaylistDiscs(String path) {
    final file = File(path);
    if (file.lengthSync() > 64 * 1024) return const [];
    final folder = p.dirname(path);
    final tracks = <String>[];
    for (final line in const LineSplitter().convert(_text(file.readAsBytesSync()))) {
      final name = line.trim();
      if (name.isEmpty || name.startsWith('#')) continue;
      final track = _localDiscFile(folder, name);
      if (track == null || tracks.length == 128) return const [];
      tracks.add(track);
    }
    return tracks;
  }

  static String? _localDiscFile(String folder, String name) {
    if (p.isAbsolute(name) || p.windows.isAbsolute(name) || name.contains(':')) return null;
    final path = p.normalize(p.join(folder, name.replaceAll(r'\', p.separator)));
    return p.isWithin(folder, path) && File(path).existsSync() ? path : null;
  }

  static List<String> _cueTracks(File file) {
    if (file.lengthSync() > 64 * 1024) return [];
    final contents = _text(file.readAsBytesSync());
    if (!RegExp(r'^\s*TRACK\s+\d+\s+MODE[12]/\d+', multiLine: true, caseSensitive: false).hasMatch(contents)) {
      return [];
    }
    final names = RegExp(
      r'^\s*FILE\s+(?:"([^"]+)"|(\S+))\s+\w+',
      multiLine: true,
      caseSensitive: false,
    ).allMatches(contents).map((match) => _localDiscFile(file.parent.path, match[1] ?? match[2]!)).toList();
    return names.any((path) => path == null) ? [] : names.nonNulls.toList();
  }

  static bool _fileMagic(File file, List<int> magic) {
    final source = file.openSync();
    try {
      final header = source.readSync(magic.length);
      return header.length == magic.length && List.generate(magic.length, (i) => header[i] == magic[i]).every((v) => v);
    } finally {
      source.closeSync();
    }
  }

  static bool _ps2Iso(File file) {
    final source = file.openSync();
    try {
      const sectorSize = 2048;
      source.setPositionSync(16 * sectorSize);
      final descriptor = source.readSync(sectorSize);
      if (descriptor.length < 190 ||
          descriptor[0] != 1 ||
          ascii.decode(descriptor.sublist(1, 6), allowInvalid: true) != 'CD001') {
        return false;
      }
      final header = ByteData.sublistView(descriptor);
      final rootOffset = header.getUint32(158, Endian.little) * sectorSize;
      final rootLength = header.getUint32(166, Endian.little);
      if (rootLength == 0 || rootLength > 1024 * 1024 || rootOffset + rootLength > source.lengthSync()) return false;
      source.setPositionSync(rootOffset);
      final records = source.readSync(rootLength);
      final data = ByteData.sublistView(records);
      for (var pos = 0; pos + 34 <= records.length;) {
        final length = records[pos];
        if (length == 0) {
          pos = (pos ~/ sectorSize + 1) * sectorSize;
          continue;
        }
        if (length < 34 || pos + length > records.length || 33 + records[pos + 32] > length) return false;
        final name = ascii.decode(records.sublist(pos + 33, pos + 33 + records[pos + 32]), allowInvalid: true);
        if (name == 'SYSTEM.CNF;1' || name == 'SYSTEM.CNF') {
          final start = data.getUint32(pos + 2, Endian.little) * sectorSize;
          final size = data.getUint32(pos + 10, Endian.little);
          if (size == 0 || size > 64 * 1024 || start + size > source.lengthSync()) return false;
          source.setPositionSync(start);
          return RegExp(r'^\s*BOOT2\s*=', multiLine: true, caseSensitive: false).hasMatch(_text(source.readSync(size)));
        }
        pos += length;
      }
      return false;
    } finally {
      source.closeSync();
    }
  }

  static Game _discoveredRetro(String folder, String disc, RetroPlatform platform) {
    final name = p.basenameWithoutExtension(disc);
    final id = p.normalize(p.absolute(disc));
    final digest = sha256.convert(utf8.encode(id)).toString().substring(0, 16).toUpperCase();
    return Game(
      folder: folder,
      libraryId: id,
      titleId: '${platform.name.toUpperCase()}-$digest',
      name: name,
      names: {'en-US': name},
      defaultLanguage: 'en-US',
      version: '',
      executable: ExecutableKind.disc,
      retro: (platform: platform, path: disc),
    );
  }

  /// The game in [folder], or null when it is not a dump.
  static Game? inspect(String folder, {bool includeRetro = false}) {
    final system = p.join(folder, 'sce_sys');
    final eboot = p.join(folder, 'eboot.bin');
    if (!File(eboot).existsSync()) return includeRetro ? _inspectRetro(folder) ?? _inspectPs3(folder) : null;
    final Map<String, dynamic> parameters;
    try {
      final decoded = jsonDecode(_text(File(p.join(system, 'param.json')).readAsBytesSync()));
      if (decoded is! Map<String, dynamic>) return null;
      parameters = decoded;
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
    final titleId = _string(parameters['titleId']) ?? p.basename(folder);
    final localized = parameters['localizedParameters'] is Map<String, dynamic>
        ? parameters['localizedParameters'] as Map<String, dynamic>
        : <String, dynamic>{};
    final language = _string(localized['defaultLanguage']) ?? _string(parameters['defaultLanguage']) ?? 'en-US';
    final names = <String, String>{};
    for (final entry in localized.entries) {
      final value = entry.value;
      if (value is Map<String, dynamic>) {
        final title = _string(value['titleName']);
        if (title != null) names[entry.key] = title;
      }
    }
    final name = names[language] ?? names['en-US'] ?? titleId;
    final version = _string(parameters['contentVersion']) ?? '1.0';
    String? existing(String name) {
      final path = p.join(system, name);
      return File(path).existsSync() ? path : null;
    }

    final ExecutableKind executable;
    if (Binary.isElf(eboot)) {
      executable = ExecutableKind.elf;
    } else if (SelfUnwrap.isContainer(eboot) || Binary.isElf('$eboot.esbak')) {
      executable = ExecutableKind.container;
    } else {
      executable = ExecutableKind.unreadable;
    }
    final beside = GameAddons.look(folder, titleId);
    return Game(
      folder: folder,
      titleId: titleId,
      name: name,
      names: names,
      defaultLanguage: language,
      version: version,
      executable: executable,
      icon: existing('icon0.png'),
      background: existing('pic0.png'),
      music: existing('snd0.at9'),
      ageLevels: AgeLevels.parse(parameters['ageLevel']),
      update: beside.update,
      addons: beside.addons,
    );
  }

  static Game? _inspectPs3(String folder) {
    final metadata = Ps3Disc.metadata(folder);
    final titleId = metadata?['TITLE_ID'];
    if (titleId == null || !RegExp(r'^[A-Z]{4}[0-9]{5}$').hasMatch(titleId)) return null;
    final name = metadata?['TITLE'] ?? p.basename(folder);
    String? image(String name) {
      final path = p.join(folder, name);
      return File(path).existsSync() ? path : null;
    }

    return Game(
      folder: folder,
      titleId: 'PS3-$titleId',
      name: name,
      names: {'en-US': name},
      defaultLanguage: 'en-US',
      version: metadata?['APP_VER'] ?? '',
      executable: ExecutableKind.disc,
      icon: image('cover.webp') ?? image('cover.png') ?? image('cover.jpg') ?? image(p.join('PS3_GAME', 'ICON0.PNG')),
      background: image(p.join('PS3_GAME', 'PIC1.PNG')),
      retro: (platform: RetroPlatform.ps3, path: p.join(folder, 'PS3_DISC.SFB')),
    );
  }

  static Game? _inspectRetro(String folder) {
    try {
      final manifest = File(p.join(folder, 'retro.json'));
      if (!manifest.existsSync()) return null;
      final json = jsonDecode(_text(manifest.readAsBytesSync()));
      if (json is! Map<String, dynamic>) return null;
      final platform = switch (json['platform']) {
        'ps1' => RetroPlatform.ps1,
        'ps2' => RetroPlatform.ps2,
        _ => null,
      };
      final titleId = _string(json['titleId']);
      final name = _string(json['name']);
      if (platform == null || titleId == null || name == null || !RegExp(r'^[A-Z0-9-]+$').hasMatch(titleId)) {
        return null;
      }

      String? localFile(String field, Set<String> extensions) {
        final name = _string(json[field]);
        if (name == null || RegExp(r'[/\\:]').hasMatch(name) || !extensions.contains(p.extension(name).toLowerCase())) {
          return null;
        }
        final path = p.join(folder, name);
        return FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.file ? path : null;
      }

      final disc = localFile('disc', switch (platform) {
        RetroPlatform.ps1 => {'.cue', '.chd', '.m3u', '.pbp'},
        RetroPlatform.ps2 => {'.iso', '.chd'},
        RetroPlatform.ps3 => {'.sfb'},
      });
      if (disc == null) return null;
      return Game(
        folder: folder,
        titleId: '${platform.name.toUpperCase()}-$titleId',
        name: name,
        names: {'en-US': name},
        defaultLanguage: 'en-US',
        version: '',
        executable: ExecutableKind.disc,
        icon: localFile('icon', {'.png', '.jpg', '.jpeg', '.webp'}),
        background: localFile('background', {'.png', '.jpg', '.jpeg', '.webp'}),
        music: localFile('music', {'.wav', '.mp3', '.m4a'}),
        ageLevels: AgeLevels.parse(json['ageLevel']),
        retro: (platform: platform, path: disc),
      );
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  /// The total size of the files in a folder, in bytes.
  static int size(String folder) {
    var total = 0;
    try {
      for (final entity in Directory(folder).listSync(recursive: true, followLinks: false)) {
        if (entity is File) total += entity.lengthSync();
      }
    } on FileSystemException {
      // What could be read counts.
    }
    return total;
  }

  static String? _string(Object? value) => value is String && value.isNotEmpty ? value : null;

  /// UTF-8 text without a byte order mark.
  static String _text(List<int> bytes) {
    final start = bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF ? 3 : 0;
    return utf8.decode(bytes.sublist(start), allowMalformed: true);
  }
}
