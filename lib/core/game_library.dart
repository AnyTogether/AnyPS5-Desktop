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

  /// No eboot.bin: a PS1, PS2 or PS3 disc that an installed emulator plays ([Game.retro]).
  disc,
}

/// The consoles whose discs the library can list for an emulator installed on the computer.
enum RetroPlatform {
  ps1('DuckStation'),
  ps2('PCSX2'),
  ps3('RPCS3');

  const RetroPlatform(this.emulator);

  /// The emulator the launcher starts the console's discs with.
  final String emulator;
}

/// A disc an emulator plays: its console, and the file handed to the emulator (a cue sheet,
/// playlist, image or PS3_DISC.SFB).
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
    this.files,
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

  /// The disc an emulator plays, for a game that is not a PS5 dump; null for a dump.
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

  /// The game's own identifier when its folder is not one ([retro] discs): the disc's path
  /// inside its games folder, so it stays the same when the drive's letter or mount point changes.
  final String? libraryId;

  /// What the launcher keeps per game under ([Preferences.lastPlayed], sizes, records): the folder
  /// for a dump, [libraryId] for a disc.
  String get id => libraryId ?? folder;

  /// The game's own files when it shares its folder with other games (disc images side by side):
  /// what its size counts. Null when the whole folder is the game's.
  final List<String>? files;

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
  bool operator ==(Object other) => other is Game && other.id == id;

  @override
  int get hashCode => id.hashCode;

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

  /// What the launcher's scans have read from disc files ([RetroScanCache]).
  static final retroCache = RetroScanCache();

  /// Finds every game folder under [root], down to three levels, sorted by name. With
  /// [includeRetro], the PS1, PS2 and PS3 discs in them too.
  static List<Game> scan(String root, {bool includeRetro = false, RetroScanCache? cache}) =>
      survey(root, includeRetro: includeRetro, cache: cache).games;

  /// The games under [root] and the dumps not whole yet. Cheap: a listing per level and each
  /// game's param.json. With [includeRetro], also the discs: what was read from a disc file is
  /// kept in [cache] (the shared [retroCache] by default) until the file changes.
  static LibrarySurvey survey(String root, {bool includeRetro = false, RetroScanCache? cache}) {
    final found = <Game>[];
    final incomplete = <String>[];
    _visit(root, 0, found, incomplete, includeRetro ? (root: root, cache: cache ?? retroCache) : null);
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
  ///
  /// With [includeRetro], the discs too; what [cache] holds of files no longer in any folder is
  /// let go.
  static LibrarySurvey surveyAll(List<String> roots, {bool includeRetro = false, RetroScanCache? cache}) {
    final retro = cache ?? retroCache;
    if (includeRetro) retro.begin();
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
      final here = survey(root, includeRetro: includeRetro, cache: retro);
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
    if (includeRetro) retro.end();
    return LibrarySurvey(games, incomplete, folders: folders, roots: found);
  }

  static int _byName(Game a, Game b) {
    final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    if (byName != 0) return byName;
    final byFolder = a.folder.compareTo(b.folder);
    return byFolder != 0 ? byFolder : a.id.compareTo(b.id);
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
          a.id != b.id ||
          a.retro != b.retro ||
          !_sameFiles(a.files, b.files) ||
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

  static bool _sameFiles(List<String>? a, List<String>? b) =>
      a == null || b == null ? a == b : a.length == b.length && [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((same) => same);

  static void _visit(String folder, int depth, List<Game> found, List<String> incomplete, _RetroScan? retro) {
    final game = inspect(folder, includeRetro: retro != null, root: retro?.root, cache: retro?.cache);
    if (game != null) {
      found.add(game);
      return;
    }
    if (Directory(p.join(folder, 'sce_sys')).existsSync() || File(p.join(folder, 'eboot.bin')).existsSync()) {
      incomplete.add(folder);
    }
    if (retro == null && depth >= 3) return;
    List<FileSystemEntity> entries;
    try {
      entries = Directory(folder).listSync(followLinks: true);
    } on FileSystemException {
      return;
    }
    entries.sort((a, b) => a.path.compareTo(b.path));
    // Disc images side by side, in a folder that is no game of its own: each one a game.
    if (retro != null &&
        !File(p.join(folder, 'retro.json')).existsSync() &&
        !File(p.join(folder, 'eboot.bin')).existsSync() &&
        !Directory(p.join(folder, 'sce_sys')).existsSync()) {
      found.addAll(_scanRetroFiles(folder, entries.whereType<File>(), retro));
    }
    if (depth >= 3) return;
    for (final entry in entries) {
      final name = p.basename(entry.path);
      if (name.startsWith('.') || _skipped.contains(name)) continue;
      if (entry is Directory) _visit(entry.path, depth + 1, found, incomplete, retro);
    }
  }

  /// The discs among [files], all in [folder]: cue sheets whose tracks are all there, PBP files,
  /// PS2 ISOs, CHDs under a folder named for one console, and the playlists that gather a game's
  /// discs (the discs they list are not games of their own then). What is read from each file
  /// comes from [_RetroScan.cache] while the file is unchanged.
  static List<Game> _scanRetroFiles(String folder, Iterable<File> files, _RetroScan retro) {
    final cache = retro.cache;
    final discs = <String, RetroPlatform>{};
    final tracks = <String, List<String>>{};
    final playlists = <File>[];
    final ps1Folder = p.split(folder).any((part) => {'ps1', 'psx', 'playstation'}.contains(part.toLowerCase()));
    final ps2Folder = p.split(folder).any((part) => {'ps2', 'playstation 2'}.contains(part.toLowerCase()));
    for (final file in files) {
      try {
        switch (p.extension(file.path).toLowerCase()) {
          case '.m3u':
            playlists.add(file);
          case '.cue' when !ps2Folder:
            final local = cache.read(file, () => _cueFiles(file))?.map((name) => _localDiscFile(folder, name)).toList();
            if (local != null && local.isNotEmpty && local.every((path) => path != null)) {
              discs[file.path] = RetroPlatform.ps1;
              tracks[file.path] = local.nonNulls.toList();
            }
          case '.pbp' when cache.read(file, () => _fileMagic(file, [0, 80, 66, 80])):
            discs[file.path] = RetroPlatform.ps1;
          case '.chd' when ps1Folder != ps2Folder && cache.read(file, () => _fileMagic(file, ascii.encode('MComprHD'))):
            discs[file.path] = ps1Folder ? RetroPlatform.ps1 : RetroPlatform.ps2;
          case '.iso' when cache.read(file, () => _ps2Iso(file)):
            discs[file.path] = RetroPlatform.ps2;
        }
      } on FileSystemException {
        continue;
      }
    }
    final claimed = <String>{};
    final gathered = <String, List<String>>{};
    for (final playlist in playlists) {
      try {
        final entries = cache.read(playlist, () => _playlistEntries(playlist)).map((name) => _localDiscFile(folder, name))
            .toList();
        if (entries.isNotEmpty && entries.every((entry) => entry != null && discs[entry] == RetroPlatform.ps1)) {
          discs[playlist.path] = RetroPlatform.ps1;
          claimed.addAll(entries.nonNulls);
          gathered[playlist.path] = [
            playlist.path,
            for (final entry in entries.nonNulls) ...[entry, ...?tracks[entry]],
          ];
        }
      } on FileSystemException {
        continue;
      }
    }
    return [
      for (final MapEntry(key: disc, value: platform) in discs.entries)
        if (!claimed.contains(disc))
          _discoveredRetro(folder, disc, platform, retro.root, gathered[disc] ?? [disc, ...?tracks[disc]]),
    ];
  }

  static String? _localDiscFile(String folder, String name) {
    if (p.isAbsolute(name) || p.windows.isAbsolute(name) || name.contains(':')) return null;
    final path = p.normalize(p.join(folder, name.replaceAll(r'\', p.separator)));
    return p.isWithin(folder, path) && File(path).existsSync() ? path : null;
  }

  /// The files a cue sheet names, as written in it; null when it is not a data disc's sheet.
  static List<String>? _cueFiles(File file) {
    if (file.lengthSync() > 64 * 1024) return null;
    final contents = _text(file.readAsBytesSync());
    if (!RegExp(r'^\s*TRACK\s+\d+\s+MODE[12]/\d+', multiLine: true, caseSensitive: false).hasMatch(contents)) {
      return null;
    }
    return [
      for (final match in RegExp(
        r'^\s*FILE\s+(?:"([^"]+)"|(\S+))\s+\w+',
        multiLine: true,
        caseSensitive: false,
      ).allMatches(contents))
        match[1] ?? match[2]!,
    ];
  }

  /// The entries of an M3U playlist, as written in it.
  static List<String> _playlistEntries(File file) {
    if (file.lengthSync() > 64 * 1024) return const [];
    return [
      for (final line in const LineSplitter().convert(_text(file.readAsBytesSync())))
        if (line.trim() case final entry when entry.isNotEmpty && !entry.startsWith('#')) entry,
    ];
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

  /// A disc's [Game.libraryId]: its console, [key] and its path inside the games folder [root],
  /// with / between folders on every system, so that the same games folder on another drive
  /// letter or mount point keeps its games' identifiers. [key] tells apart two games at the same
  /// path in two games folders: the title ID a disc names, or the size of a loose disc's files.
  /// Outside a games folder, the whole path.
  static String retroId(RetroPlatform platform, String key, String disc, String? root) {
    final path = root != null && p.isWithin(root, disc) ? p.relative(disc, from: root) : p.normalize(p.absolute(disc));
    return 'retro:${platform.name}:$key:${p.split(path).join('/')}';
  }

  static Game _discoveredRetro(String folder, String disc, RetroPlatform platform, String root, List<String> files) {
    final name = p.basenameWithoutExtension(disc);
    final id = retroId(platform, '${filesSize(files)}', disc, root);
    final digest = sha256.convert(utf8.encode(id)).toString().substring(0, 16).toUpperCase();
    return Game(
      folder: folder,
      libraryId: id,
      files: files,
      titleId: '${platform.name.toUpperCase()}-$digest',
      name: name,
      names: {'en-US': name},
      defaultLanguage: 'en-US',
      version: '',
      executable: ExecutableKind.disc,
      retro: (platform: platform, path: disc),
    );
  }

  /// The game in [folder], or null when it is not a dump. With [includeRetro], a folder with a
  /// retro.json or an extracted PS3 disc too, identified inside the games folder [root].
  static Game? inspect(String folder, {bool includeRetro = false, String? root, RetroScanCache? cache}) {
    final system = p.join(folder, 'sce_sys');
    final eboot = p.join(folder, 'eboot.bin');
    if (!File(eboot).existsSync()) {
      return includeRetro ? _inspectRetro(folder, root) ?? _inspectPs3(folder, root, cache ?? retroCache) : null;
    }
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

  /// An extracted PS3 disc in [folder] (PS3_DISC.SFB, PS3_GAME/PARAM.SFO and the game's
  /// EBOOT.BIN), named from its PARAM.SFO.
  static Game? _inspectPs3(String folder, String? root, RetroScanCache cache) {
    if (!Ps3Disc.isDisc(folder)) return null;
    final Map<String, String>? metadata;
    try {
      metadata = cache.read(File(Ps3Disc.paramsFile(folder)), () => Ps3Disc.metadata(folder));
    } on FileSystemException {
      return null;
    }
    final titleId = metadata?['TITLE_ID'];
    if (titleId == null || !RegExp(r'^[A-Z]{4}[0-9]{5}$').hasMatch(titleId)) return null;
    final name = metadata?['TITLE'] ?? p.basename(folder);
    String? image(String name) {
      final path = p.join(folder, name);
      return File(path).existsSync() ? path : null;
    }

    final disc = p.join(folder, 'PS3_DISC.SFB');
    return Game(
      folder: folder,
      libraryId: retroId(RetroPlatform.ps3, titleId, disc, root),
      titleId: 'PS3-$titleId',
      name: name,
      names: {'en-US': name},
      defaultLanguage: 'en-US',
      version: metadata?['APP_VER'] ?? '',
      executable: ExecutableKind.disc,
      icon: image('cover.webp') ?? image('cover.png') ?? image('cover.jpg') ?? image(p.join('PS3_GAME', 'ICON0.PNG')),
      background: image(p.join('PS3_GAME', 'PIC1.PNG')),
      retro: (platform: RetroPlatform.ps3, path: disc),
    );
  }

  /// A PS1 or PS2 game folder its retro.json describes: the console, name, title ID and disc, and
  /// the art and music beside it.
  static Game? _inspectRetro(String folder, String? root) {
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
        libraryId: retroId(platform, titleId, disc, root),
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

  /// The total size of the files in a folder, in bytes; a file's own size when [folder] is one.
  static int size(String folder) {
    var total = 0;
    try {
      if (FileSystemEntity.isFileSync(folder)) return File(folder).lengthSync();
      for (final entity in Directory(folder).listSync(recursive: true, followLinks: false)) {
        if (entity is File) total += entity.lengthSync();
      }
    } on FileSystemException {
      // What could be read counts.
    }
    return total;
  }

  /// The total size of [files], in bytes; one that is not there counts nothing.
  static int filesSize(List<String> files) {
    var total = 0;
    for (final file in files) {
      try {
        total += File(file).lengthSync();
      } on FileSystemException {
        // What could be read counts.
      }
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

/// Where a scan looks for discs: the games folder it started in, and what it keeps of the files.
typedef _RetroScan = ({String root, RetroScanCache cache});

/// What a scan read from the disc files (a cue sheet's tracks, whether an ISO boots a PS2, a
/// playlist's entries, a PS3 disc's PARAM.SFO), by path, kept while the file's size and
/// modification time stay the same: a rescan, or a watched folder's change, reads again only
/// the files that changed, and a library without discs reads none.
class RetroScanCache {
  final Map<String, ({int size, DateTime modified, Object? value})> _entries = {};
  Set<String>? _seen;

  /// How many files it holds what was read from.
  int get length => _entries.length;

  /// What [read] gives for [file], read again only when the file changed since the last time.
  /// Throws a [FileSystemException] when [file] is not a file.
  T read<T>(File file, T Function() read) {
    final stat = file.statSync();
    if (stat.type != FileSystemEntityType.file) throw FileSystemException('Not a file', file.path);
    _seen?.add(file.path);
    final known = _entries[file.path];
    if (known != null && known.size == stat.size && known.modified == stat.modified && known.value is T) {
      return known.value as T;
    }
    final value = read();
    _entries[file.path] = (size: stat.size, modified: stat.modified, value: value);
    return value;
  }

  /// A whole library's scan starts: the files it does not look at are let go at [end].
  void begin() => _seen = {};

  /// The whole library's scan is done.
  void end() {
    final seen = _seen;
    _seen = null;
    if (seen != null) _entries.removeWhere((path, _) => !seen.contains(path));
  }
}
