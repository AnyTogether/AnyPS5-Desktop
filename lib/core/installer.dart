import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'package:crypto/crypto.dart';

import 'binary.dart';
import 'file_links.dart';
import 'free_space.dart';
import 'game_library.dart';
import 'game_settings.dart';
import 'host.dart';
import 'process_control.dart';
import 'profiles/profile_saves.dart';
import 'relinker_flags.dart';
import 'save_backup.dart';
import 'self_unwrap.dart';
import 'toolkit.dart';
import 'unlock_space.dart';

/// What an installed game records about itself (anyps5-install.json beside its executable).
class InstallRecord {
  InstallRecord({
    required this.source,
    required this.titleId,
    required this.toolkit,
    required this.system,
    required this.date,
    this.resolution,
    this.update,
    this.relinkerFlags = const [],
    this.customRelinkerOptions = const [],
  });

  factory InstallRecord.fromJson(Map<String, dynamic> json) => InstallRecord(
    source: json['source'] as String,
    titleId: json['titleID'] as String,
    toolkit: json['toolkit'] as String,
    system: json['system'] as String? ?? 'linux',
    date: DateTime.parse(json['date'] as String),
    resolution: json['resolution'] as String?,
    update: json['update'] as String?,
    relinkerFlags: json['relinkerFlags'] is List<dynamic>
        ? (json['relinkerFlags'] as List<dynamic>).whereType<String>().toList()
        : const [],
    customRelinkerOptions: json['customRelinkerOptions'] is List<dynamic>
        ? (json['customRelinkerOptions'] as List<dynamic>).whereType<String>().toList()
        : const [],
  );

  final String source;
  final String titleId;
  final String toolkit;
  final String system;
  final DateTime date;

  /// The resolution written into the executable by the title's patch file, if any.
  final String? resolution;

  /// The version of the update the game was unlocked with ([GameUpdate]), null without one.
  final String? update;

  /// The relinker options the game was unlocked with ([RelinkerFlag]).
  final List<String> relinkerFlags;

  /// The Custom relinker options the game was unlocked with, word by word.
  final List<String> customRelinkerOptions;

  Map<String, Object> toJson() => {
    'resolution': ?resolution,
    'update': ?update,
    if (relinkerFlags.isNotEmpty) 'relinkerFlags': relinkerFlags,
    if (customRelinkerOptions.isNotEmpty) 'customRelinkerOptions': customRelinkerOptions,
    'date': date.toUtc().toIso8601String(),
    'source': source,
    'system': system,
    'titleID': titleId,
    'toolkit': toolkit,
  };
}

class InstallError implements Exception {
  InstallError(this.message);
  final String message;

  @override
  String toString() => message;
}

/// A tool that ended with an error: its exit code and the end of what it printed. The relinker
/// ends a failed conversion with `FAIL: <reason>` and, when one file caused it, `Input: <path>`.
class ToolFailed extends InstallError {
  /// With [workingDirectory], an `Input:` path inside it is said relative to it, as the dump has
  /// the file (the work folder it names is gone once the unlock stops).
  ToolFailed(String tool, this.code, this.lines, {String? workingDirectory})
    : super(_message(tool, code, lines, workingDirectory));

  final int code;

  /// Everything the tool printed (its last 400 lines).
  final List<String> lines;

  /// The lines that say what went wrong: from the last `FAIL:` line on, else the last line.
  static List<String> tailOf(List<String> lines) {
    final fail = lines.lastIndexWhere((line) => line.startsWith('FAIL:'));
    if (fail >= 0) return lines.sublist(fail);
    return lines.isEmpty ? const [] : [lines.last];
  }

  static String _message(String tool, int code, List<String> lines, String? workingDirectory) {
    final tail = [
      for (final line in tailOf(lines))
        if (workingDirectory != null && line.startsWith('Input:'))
          'Input: ${_inside(line.substring(6).trim(), workingDirectory)}'
        else
          line,
    ];
    return '$tool failed ($code)${tail.isEmpty ? '' : ': ${tail.join('\n')}'}';
  }

  /// [path] relative to [folder] with / separators when it is inside it (or inside it with its
  /// links resolved), else as it is.
  static String _inside(String path, String folder) {
    final bases = {p.normalize(folder)};
    try {
      bases.add(Directory(folder).resolveSymbolicLinksSync());
    } on FileSystemException {
      // Gone: its name as given.
    }
    for (final base in bases) {
      if (p.isWithin(base, path)) return p.split(p.relative(path, from: base)).join('/');
    }
    return path;
  }

  /// The reason after `FAIL:`, null when the tool printed none.
  String? get reason {
    final fail = lines.lastIndexWhere((line) => line.startsWith('FAIL:'));
    return fail < 0 ? null : lines[fail].substring(5).trim();
  }

  /// The file the relinker names after its `FAIL:` line, null when it names none.
  String? get input {
    final fail = lines.lastIndexWhere((line) => line.startsWith('FAIL:'));
    if (fail < 0) return null;
    for (final line in lines.skip(fail + 1)) {
      if (line.startsWith('Input:')) return line.substring(6).trim();
    }
    return null;
  }
}

/// Why a module of the dump was left out of the relink.
enum LeftOutReason {
  /// Neither an ELF nor a SELF container that can be unwrapped: still encrypted in the dump.
  encrypted,

  /// The relinker could not convert it.
  notRelinked,
}

/// A module of the dump the unlock left out. The engine starts a game without a module it imports
/// nothing from, answers the game's own load of it with an error, and uses its own library of
/// that name where it has one (libSceNpCppWebApi); one the executable imports from and the engine
/// lacks stops the game at its start.
class LeftOutModule {
  const LeftOutModule(this.path, this.reason, [this.detail]);

  factory LeftOutModule.fromJson(Map<String, dynamic> json) => LeftOutModule(
    json['path'] as String,
    LeftOutReason.values.byName(json['reason'] as String),
    json['detail'] as String?,
  );

  /// Relative to the dump, with / separators.
  final String path;
  final LeftOutReason reason;

  /// The relinker's reason, or the unwrap's.
  final String? detail;

  Map<String, Object> toJson() => {'path': path, 'reason': reason.name, 'detail': ?detail};

  @override
  bool operator ==(Object other) =>
      other is LeftOutModule && other.path == path && other.reason == reason && other.detail == detail;

  @override
  int get hashCode => Object.hash(path, reason, detail);

  @override
  String toString() => '$path (${reason.name}${detail == null ? '' : ': $detail'})';
}

class InstallCancelled implements Exception {
  @override
  String toString() => 'cancelled';
}

/// The steps of an install, in order.
enum InstallStep { unwrap, relink, copy, layout, finish }

/// What unlocking a game will do with its files, known before it starts: link them to the dump
/// or copy [bytes] of them.
class InstallPlan {
  const InstallPlan(this.mode, this.bytes, {this.space});

  final LinkMode mode;

  /// The size of the game's files, which a copy duplicates.
  final int bytes;

  /// What the unlock writes on the games folder's drive, when the toolkit was known.
  final UnlockSpace? space;

  bool get copies => mode == LinkMode.copy;
}

/// Unlocks a game for Windows or Linux: unwraps its executable and modules, relinks them with the
/// upstream relinker for the host, and lays the game out as upstream's runtime layout says:
///
/// ```text
/// <root>/.AnyPS5/Games/<TITLE>-<hash>/
///     app.elf | app.exe       the relinked executable
///     libs/*.prx              the toolkit's system libraries
///     app0/                   the game's files (linked to the dump) and its relinked modules
///     anyps5-install.json     the record
///     launch.sh | launch.cmd  starts the game without the launcher
/// ```
///
/// The game runs with that folder as its working directory, so what it writes (saves in _sd,
/// trophies in _trophy, data/) lands there and is carried over when the game is installed again.
class Installer {
  Installer({
    required this.game,
    required this.toolkit,
    required this.root,
    this.onProgress,
    this.onLog,
    this.linkMode,
    this.resolution,
    this.relinkerFlags = const [],
    this.customRelinkerOptions = const [],
    DateTime Function()? clock,
    int? Function(String folder)? freeSpace,
  }) : _clock = clock ?? DateTime.now,
       freeSpace = freeSpace ?? FreeSpace.of;

  final Game game;
  final Toolkit toolkit;

  /// The games folder, which holds the store.
  final String root;
  final void Function(InstallStep step, double fraction)? onProgress;
  final void Function(String line)? onLog;

  /// How the game's files reach app0; probed on the first file when null.
  final LinkMode? linkMode;

  /// The WIDTHxHEIGHT to write through the title's resolution patch, null for the title's own.
  final String? resolution;

  /// The relinker options asked for this game: the ones this toolkit lacks or its relinker
  /// refuses are left out, and the record says which were used.
  final List<RelinkerFlag> relinkerFlags;

  /// The game's Custom relinker options, checked (GameSettings.customRelinkerWords): passed after
  /// the launcher's own options, before the executable's paths. A relinker that stops with them
  /// runs again without them, and the record says which were used.
  final List<String> customRelinkerOptions;
  final DateTime Function() _clock;

  /// The free bytes where the games folder is (FreeSpace.of); replaceable in tests.
  final int? Function(String folder) freeSpace;

  /// The dump's modules the last [run] left out (encrypted, or the relinker could not convert
  /// them); the game was unlocked without them.
  final List<LeftOutModule> leftOut = [];

  bool _cancelled = false;
  Process? _running;
  bool _background = false;
  bool _paused = false;
  Completer<void>? _resumed;

  /// A background unlock (a new game prepared on its own): the relinker runs at the lowest
  /// priority, so a game or anything the user does comes first. Set to false while it runs (the
  /// user asked to play it), it goes back to normal where the system lets it.
  bool get background => _background;
  set background(bool value) {
    _background = value;
    final pid = _running?.pid;
    if (pid != null) value ? ProcessControl.lower(pid) : ProcessControl.normal(pid);
  }

  bool get paused => _paused;

  /// Stops the unlock where it is (a game started): the relinker is suspended, the launcher's
  /// own steps wait at their next file.
  void pause() {
    if (_paused) return;
    _paused = true;
    _resumed = Completer<void>();
    final pid = _running?.pid;
    if (pid != null) ProcessControl.suspend(pid);
  }

  void resume() {
    if (!_paused) return;
    _paused = false;
    final pid = _running?.pid;
    if (pid != null) ProcessControl.resume(pid);
    _resumed?.complete();
    _resumed = null;
  }

  /// Waits while paused; throws when cancelled.
  Future<void> _gate() async {
    while (_paused && !_cancelled) {
      await (_resumed?.future ?? Future<void>.value());
    }
    _checkCancelled();
  }

  static const recordName = 'anyps5-install.json';

  /// The installed folder of a game, inside the games folder's store. The name keeps the title
  /// ID and a hash of the dump's path, so two dumps of one title do not collide.
  static String installedFolder(Game game, String root) {
    var hash = 0xCBF29CE484222325;
    for (final byte in utf8.encode(p.normalize(p.absolute(game.folder)))) {
      hash ^= byte;
      hash *= 0x100000001B3;
    }
    final name = '${game.titleId.replaceAll(RegExp(r'[^A-Za-z0-9]'), '')}-${(hash & 0xFFFFFF).toRadixString(16)}';
    return p.join(root, GameLibrary.storeName, 'Games', name);
  }

  /// The record of an installed game, null when it is not (completely) installed.
  static InstallRecord? record(String installed, {HostSystem? system}) {
    final host = system ?? HostSystem.current;
    if (!File(p.join(installed, host.executableName)).existsSync()) return null;
    try {
      final json = jsonDecode(File(p.join(installed, recordName)).readAsStringSync());
      return json is Map<String, dynamic> ? InstallRecord.fromJson(json) : null;
    } on Object {
      return null;
    }
  }

  /// The work folders and half-made games an interrupted install left in the store. A half-made
  /// game may hold the player's saves (the launcher closed while the new one took the old one's
  /// place): they go back into the game when it is still there, else wait in [keptSaves].
  static void removeLeftovers(String root) {
    final store = p.join(root, GameLibrary.storeName);
    _delete(p.join(store, 'Work'));
    final games = Directory(p.join(store, 'Games'));
    if (!games.existsSync()) return;
    for (final entry in games.listSync(followLinks: false)) {
      if (!entry.path.endsWith('.partial')) continue;
      // "<game>.partial", or the old one set aside as "<game>.old-<date>.partial".
      final installed = p.join(games.path, p.basename(entry.path).split('.').first);
      try {
        _rescueSaves(entry.path, installed);
      } on FileSystemException {
        // They cannot be moved out: the folder stays until they can.
        continue;
      }
      _delete(entry.path);
    }
  }

  /// Removes an installed game and what the launcher made for it; links to the dump go, never
  /// what they point to. The player's own ([savedParts]: saves, trophies, download data) is kept
  /// first ([keepSaves]) and comes back with the next unlock; when it cannot be kept this throws
  /// FileSystemException and the game stays installed. The relinker's kept output goes too. Both
  /// are moved into the store's Removing folder at once, so the game is no longer installed when
  /// this returns, and removed from there by [removeAside]: a game of tens of thousands of files
  /// deleted on the screen's thread kept the launcher from answering until it was gone. What an
  /// uninstall left there (the launcher closed before it was done) goes too. A folder that cannot
  /// be moved is removed where it is. The future completes when everything is gone.
  static Future<void> uninstall(Game game, String root) {
    keepSaves(game, root);
    final removing = Directory(removingFolder(root));
    final left = <String>{
      if (removing.existsSync())
        for (final entry in removing.listSync(followLinks: false)) entry.path,
    };
    final going = [
      _setAside(installedFolder(game, root), root, 'game'),
      _setAside(keptRelink(game, root), root, 'relinked'),
    ];
    return Future.wait([
      for (final path in {...going.nonNulls, ...left}) removeAside(path),
    ]);
  }

  /// The game's download data, /download0 to /download2 as the game sees them: what it fetched
  /// or made for the player and keeps between its runs.
  static const downloadData = ['download0', 'download1', 'download2'];

  /// What of an installed game is the player's own: the saves, the save memory and the trophies
  /// in place, every other profile's parked ones, the mark that says whose are in place, and the
  /// game's download data.
  static const savedParts = [...SaveBackup.parts, ProfileSaves.parkName, ProfileSaves.markName, ...downloadData];

  /// Where the saves and trophies of a game that is no longer installed wait (Remove
  /// installation, Delete game), in the store of the games folder: the next unlock of a game in
  /// the same folder takes them back ([placeInstalled]).
  static String keptSaves(String installed) => p.join(p.dirname(p.dirname(installed)), 'Saves', p.basename(installed));

  /// The saves a half-made game holds go back into the installed one, or wait in [keptSaves]
  /// when there is none: the half-made one is removed after.
  static void _rescueSaves(String partial, String installed) =>
      moveSaves(partial, Directory(installed).existsSync() ? installed : keptSaves(installed));

  /// Before an installed game goes: its saves and trophies ([savedParts]) move out of the
  /// installed folder into [keptSaves], so the uninstall takes none of them ([moveSaves]).
  static void keepSaves(Game game, String root) {
    final installed = installedFolder(game, root);
    moveSaves(installed, keptSaves(installed));
  }

  /// The player's own ([savedParts]) moves out of [from] into [to]. Renames on one drive, quick
  /// however big they are. A link and an empty folder hold nothing of the player's and stay.
  /// Something there already under the same name stays, the newer one beside it under its date.
  /// Throws FileSystemException when one cannot be moved: the ones moved before it go back, so
  /// [from] is left as it was.
  static void moveSaves(String from, String to) {
    final moved = <(String, String)>[];
    void rename(String source, String target) => FileSystemEntity.isDirectorySync(source)
        ? Directory(source).renameSync(target)
        : File(source).renameSync(target);
    try {
      for (final part in savedParts) {
        final source = p.join(from, part);
        final type = FileSystemEntity.typeSync(source, followLinks: false);
        if (type == FileSystemEntityType.notFound || type == FileSystemEntityType.link) continue;
        if (type == FileSystemEntityType.directory && Directory(source).listSync().isEmpty) continue;
        Directory(to).createSync(recursive: true);
        var target = p.join(to, part);
        if (FileSystemEntity.typeSync(target, followLinks: false) != FileSystemEntityType.notFound) {
          target = '$target.${DateTime.now().microsecondsSinceEpoch}';
        }
        rename(source, target);
        moved.add((source, target));
      }
    } on FileSystemException {
      for (final (source, target) in moved.reversed) {
        try {
          rename(target, source);
        } on FileSystemException {
          // It waits where it got to.
        }
      }
      rethrow;
    }
  }

  /// Where [uninstall] puts what it removes until it is gone, in the store of the games folder
  /// [root].
  static String removingFolder(String root) => p.join(root, GameLibrary.storeName, 'Removing');

  /// How [uninstall] removes what it set aside: on the system's file threads, off the screen's
  /// thread. Replaceable in tests (a removal that takes its time).
  static Future<void> Function(String path) removeAside = _deleteAway;

  /// [path] moved into the Removing folder, null when there is nothing there; [path] itself when
  /// it cannot be moved (a file in it held open).
  static String? _setAside(String path, String root, String label) {
    switch (FileSystemEntity.typeSync(path, followLinks: false)) {
      case FileSystemEntityType.notFound:
        return null;
      case FileSystemEntityType.directory:
        break;
      default:
        return path;
    }
    final aside = p.join(removingFolder(root), '${p.basename(path)}-$label-${DateTime.now().microsecondsSinceEpoch}');
    try {
      Directory(p.dirname(aside)).createSync(recursive: true);
      Directory(path).renameSync(aside);
      return aside;
    } on FileSystemException {
      return path;
    }
  }

  /// How [game]'s files will reach app0 in the games folder [root], tried the way the install
  /// tries it, and their size when they will be copied. With [toolkit], also what the whole
  /// unlock writes on the drive ([InstallPlan.space]).
  static InstallPlan plan(
    Game game,
    String root, {
    int? knownSize,
    Toolkit? toolkit,
    String? resolution,
    List<RelinkerFlag> relinkerFlags = const [],
    List<String> customRelinkerOptions = const [],
  }) {
    final games = p.join(root, GameLibrary.storeName, 'Games');
    final mode = FileLinks.probe(p.join(game.folder, 'eboot.bin'), games);
    final bytes = mode == LinkMode.copy ? knownSize ?? payloadSize(game.folder) : 0;
    if (toolkit == null) return InstallPlan(mode, bytes);
    return InstallPlan(
      mode,
      bytes,
      space: space(
        game,
        root,
        toolkit,
        copied: bytes,
        resolution: resolution,
        relinkerFlags: relinkerFlags,
        customRelinkerOptions: customRelinkerOptions,
      ),
    );
  }

  /// What unlocking [game] with [toolkit] writes on the drive of the games folder [root] (see
  /// UnlockSpace); [copied] is the size of the game's files when they are copied.
  static UnlockSpace space(
    Game game,
    String root,
    Toolkit toolkit, {
    int copied = 0,
    String? resolution,
    List<RelinkerFlag> relinkerFlags = const [],
    List<String> customRelinkerOptions = const [],
  }) {
    int size(String path) {
      try {
        return File(path).lengthSync();
      } on FileSystemException {
        return 0;
      }
    }

    final found = modulesOf(game, toolkit.system);
    final executables = ['eboot.bin', ...found].fold(0, (sum, relative) => sum + size(source(game, relative)));
    final games = p.join(root, GameLibrary.storeName, 'Games');
    final libraryFiles = toolkit.libraryFiles;
    var libraries = 0;
    if (libraryFiles.isNotEmpty && FileLinks.probe(libraryFiles.first, games) != LinkMode.hard) {
      libraries = libraryFiles.fold(0, (sum, file) => sum + size(file));
    }
    final links = keepsOutput(root);
    int? kept;
    if (links) {
      final key = relinkKey(
        game,
        toolkit,
        found,
        _patchText(toolkit, game, resolution).$1,
        flags: relinkerFlags.where(toolkit.supports).toList(),
        custom: customRelinkerOptions,
      );
      final reusable = reusableRelink(game, root, key);
      if (reusable != null) kept = GameLibrary.size(reusable);
    }
    return UnlockSpace(
      executables: executables,
      libraries: libraries,
      copied: copied,
      linksOutput: links,
      keptRelink: kept,
    );
  }

  /// Where the relinker's output of a game is kept for the next unlock, in the store.
  static String keptRelink(Game game, String root) =>
      p.join(root, GameLibrary.storeName, 'Relinked', p.basename(installedFolder(game, root)));

  /// Whether the store keeps the relinker's output: where hard links work in it, so the installed
  /// game links to the kept files instead of holding a second copy.
  static bool keepsOutput(String root) {
    final store = p.join(root, GameLibrary.storeName);
    try {
      Directory(store).createSync(recursive: true);
      final sample = File(p.join(store, '.anyps5-link-sample-$pid'))..writeAsStringSync('');
      try {
        return FileLinks.probe(sample.path, store) == LinkMode.hard;
      } finally {
        _delete(sample.path);
      }
    } on FileSystemException {
      return false;
    }
  }

  /// What the relinker's output depends on: the toolkit, the system, the patches (with the
  /// resolution in them), the module folders, the Custom relinker options ([custom]), and the
  /// dump's executable and modules (path, size and modification time of each). Unlocking again
  /// with the same key reuses the kept output.
  static String relinkKey(
    Game game,
    Toolkit toolkit,
    List<String> found,
    String? patches, {
    List<RelinkerFlag> flags = const [],
    List<String> custom = const [],
  }) {
    final lines = <String>[
      'toolkit ${toolkit.version}',
      'relinker ${toolkit.relinker}',
      'system ${toolkit.system.name} ${[...toolkit.system.relinkerOptions, ...flags.map((flag) => flag.option)].join(' ')}',
      'modules ${moduleDirectories(found).join(' ')}',
      'patches ${patches == null ? '-' : sha256.convert(utf8.encode(patches))}',
      // Word by word, so a word with a space in it is not two.
      if (custom.isNotEmpty) 'custom ${jsonEncode(custom)}',
    ];
    for (final relative in ['eboot.bin', ...found]) {
      final path = source(game, relative);
      for (final file in [path, '$path.esbak']) {
        final stat = File(file).statSync();
        if (stat.type == FileSystemEntityType.notFound) {
          if (file == path) return '';
          continue;
        }
        lines.add('${p.relative(file, from: game.folder)} ${stat.size} ${stat.modified.microsecondsSinceEpoch}');
      }
    }
    final update = game.update;
    if (update != null) lines.add('update ${update.folder} ${update.version}');
    return lines.join('\n');
  }

  /// Where the file at [relative] (with / separators) in [game] comes from: the update's copy
  /// when the game has an update that has it, else the game's.
  static String source(Game game, String relative) {
    final update = game.update;
    if (update != null) {
      final updated = p.join(update.folder, p.joinAll(relative.split('/')));
      if (File(updated).existsSync()) return updated;
    }
    return p.join(game.folder, p.joinAll(relative.split('/')));
  }

  /// The game's modules and its update's, each once and sorted: the relinker converts the
  /// update's copy of one both have ([source]), and the engine loads the relinked ones from app0.
  /// A module the dump holds in several folders is in it once ([duplicateModules]), as the
  /// relinker for [system] tells them apart.
  static List<String> modulesOf(Game game, HostSystem system) {
    final all = allModulesOf(game);
    final duplicates = duplicateModules(all, foldCase: system == HostSystem.windows);
    return [
      for (final module in all)
        if (!duplicates.containsKey(module)) module,
    ];
  }

  /// Every module of the game and its update, the copies of one in several folders among them.
  static List<String> allModulesOf(Game game) {
    final update = game.update;
    if (update == null) return modules(game.folder);
    return {...modules(game.folder), ...modules(update.folder)}.toList()..sort();
  }

  /// The folders next to eboot.bin the relinker reads by itself, in the order a copy is taken.
  static const standardModuleFolders = ['sce_module', 'sce_modules', 'prx'];

  /// The copies of a module the relink leaves out, each with the copy used in its place.
  ///
  /// The relinker names a converted module after its file alone (libc.prx becomes
  /// libc.prx.guest.prx) and stops when two of its inputs share that name, whatever their
  /// folders ("Conflicting guest output filename"), without regard to case for Windows
  /// ([foldCase]). A dump can hold a module twice: a dumper's folder of decrypted copies
  /// (decrypted/sce_module) beside sce_module, or a module next to eboot.bin and again in
  /// sce_module. One copy goes in, by the first of these that has it:
  ///
  /// 1. a standard folder ([standardModuleFolders]): a module the executable needs starts with
  ///    the game from there. From any other folder the Windows relinker has it wait until the
  ///    game loads it from that folder, and a libc.prx taken from decrypted/sce_module never
  ///    started (Lost in Play);
  /// 2. next to eboot.bin;
  /// 3. the folder nearest to eboot.bin, the first by name among equals.
  ///
  /// Only the folders the relinker reads count ([moduleDirectories]): a module in one place
  /// alone is never here, wherever it is.
  static Map<String, String> duplicateModules(List<String> modules, {required bool foldCase}) {
    final read = moduleDirectories(modules);
    final ranked = <(int, String)>[];
    for (final module in modules) {
      final slash = module.lastIndexOf('/');
      final directory = slash < 0 ? '.' : module.substring(0, slash);
      final standard = standardModuleFolders.indexOf(directory.toLowerCase());
      if (standard >= 0) {
        ranked.add((standard, module));
      } else if (read.contains(directory)) {
        ranked.add((standardModuleFolders.length + (slash < 0 ? 0 : directory.split('/').length), module));
      }
    }
    ranked.sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
    final used = <String, String>{};
    final duplicates = <String, String>{};
    for (final (_, module) in ranked) {
      final name = module.substring(module.lastIndexOf('/') + 1);
      final first = used.putIfAbsent(foldCase ? name.toLowerCase() : name, () => module);
      if (first != module) duplicates[module] = first;
    }
    return duplicates;
  }

  /// The kept relinker output of [game] when its key is [key], null when there is none or it was
  /// made from something else.
  static String? reusableRelink(Game game, String root, String key) {
    if (key.isEmpty) return null;
    final kept = keptRelink(game, root);
    try {
      if (File(p.join(kept, 'key.txt')).readAsStringSync() != key) return null;
    } on FileSystemException {
      return null;
    }
    return Directory(p.join(kept, 'out')).existsSync() ? p.join(kept, 'out') : null;
  }

  /// The title's patch file as the relinker gets it (the chosen resolution written in), and the
  /// resolution applied; nulls when the toolkit has no patches for it.
  static (String?, String?) _patchText(Toolkit toolkit, Game game, String? resolution) {
    final patches = toolkit.patchFile(game.titleId);
    if (patches == null) return (null, null);
    final text = File(patches).readAsStringSync();
    if (resolution != null && ResolutionPatch.supports(text) && ResolutionPatch.parse(resolution) != null) {
      return (ResolutionPatch.apply(text, resolution), resolution);
    }
    return (text, null);
  }

  /// The size of the files an install lays into app0 from [source] (the store left out).
  static int payloadSize(String source) {
    var total = 0;
    try {
      final base = p.normalize(p.absolute(source));
      for (final entry in Directory(base).listSync(recursive: true, followLinks: true)) {
        if (entry is! File) continue;
        if (p.split(p.relative(entry.path, from: base)).first == GameLibrary.storeName) continue;
        if (isRelinkerOutput(entry.path)) continue;
        total += entry.lengthSync();
      }
    } on FileSystemException {
      // What could be read counts.
    }
    return total;
  }

  /// [payloadSize], read on the system's file threads (a dump holds tens of thousands of files).
  static Future<int> measurePayload(String source) async {
    var total = 0;
    try {
      final base = p.normalize(p.absolute(source));
      await for (final entry in Directory(base).list(recursive: true, followLinks: true)) {
        if (entry is! File) continue;
        if (p.split(p.relative(entry.path, from: base)).first == GameLibrary.storeName) continue;
        if (isRelinkerOutput(entry.path)) continue;
        try {
          total += await entry.length();
        } on FileSystemException {
          // What could be read counts.
        }
      }
    } on FileSystemException {
      // What could be read counts.
    }
    return total;
  }

  /// The first file of an installed game's app0 that links to a dump file no longer there,
  /// relative to app0; null when every link holds (or the game was hard linked or copied).
  static Future<String?> brokenLink(String installed) async {
    final app0 = p.join(installed, 'app0');
    final eboot = p.join(app0, 'eboot.bin');
    // A game linked to its dump has its eboot.bin linked like every other file.
    if (FileSystemEntity.typeSync(eboot, followLinks: false) != FileSystemEntityType.link) return null;
    if (FileLinks.isBroken(eboot)) return 'eboot.bin';
    try {
      await for (final entry in Directory(app0).list(recursive: true, followLinks: false)) {
        if (entry is Link && FileLinks.isBroken(entry.path)) return p.relative(entry.path, from: app0);
      }
    } on FileSystemException {
      return null;
    }
    return null;
  }

  void cancel() {
    _cancelled = true;
    final running = _running;
    running?.kill();
    // A suspended relinker only gets the termination when it goes on.
    if (running != null && _paused) ProcessControl.resume(running.pid);
    _resumed?.complete();
    _resumed = null;
  }

  void _checkCancelled() {
    if (_cancelled) throw InstallCancelled();
  }

  void _log(String line) => onLog?.call(line);
  void _progress(InstallStep step, double fraction) => onProgress?.call(step, fraction.clamp(0, 1));

  /// Installs the game; returns its installed folder.
  Future<String> run() async {
    leftOut.clear();
    final problem = toolkit.problem;
    if (problem != null) {
      throw InstallError(switch (problem) {
        ToolkitProblem.noRelinker => 'the toolkit has no relinker at ${toolkit.relinker}',
        ToolkitProblem.noLibraries => 'the toolkit has no system libraries in ${toolkit.libraries}',
      });
    }
    final system = toolkit.system;
    final installed = installedFolder(game, root);
    final store = p.join(root, GameLibrary.storeName);
    final work = p.join(store, 'Work', '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 32)}');
    final partial = '$installed.partial';
    // A half-made one the launcher was closed over may hold the saves: they come out before it
    // is made again.
    _rescueSaves(partial, installed);
    // 0. The room it takes, before anything is written.
    await _gate();
    final mode = linkMode ?? FileLinks.probe(p.join(game.folder, 'eboot.bin'), p.join(store, 'Games'));
    final copied = mode == LinkMode.copy ? await measurePayload(game.folder) : 0;
    final needs = space(
      game,
      root,
      toolkit,
      copied: copied,
      resolution: resolution,
      relinkerFlags: relinkerFlags,
      customRelinkerOptions: customRelinkerOptions,
    );
    final shortage = needs.shortage(free: freeSpace(root), folder: root);
    if (shortage != null) throw shortage;
    try {
      final found = modulesOf(game, system);
      final (patchText, appliedResolution) = _patchText(toolkit, game, resolution);
      // An option this engine lacks is left out; one it refuses is dropped below.
      var flags = relinkerFlags.where(toolkit.supports).toList();
      for (final flag in relinkerFlags) {
        if (!flags.contains(flag)) {
          _log('${game.titleId}: this engine does not support ${flag.option}, the game is rebuilt without it');
        }
      }
      var custom = customRelinkerOptions;
      var key = relinkKey(game, toolkit, found, patchText, flags: flags, custom: custom);
      final keeps = needs.linksOutput;
      String relinked;
      final reusable = keeps ? reusableRelink(game, root, key) : null;
      if (reusable != null) {
        // Nothing the relinker depends on changed since the last unlock: its output is reused.
        _log('${game.titleId}: the executable, modules and patches are unchanged, the relinked ones are reused');
        relinked = reusable;
        leftOut.addAll(_keptLeftOut(reusable));
        _progress(InstallStep.unwrap, 1);
        _progress(InstallStep.relink, 1);
      } else {
        // 1. The executable and every guest module as plain ELF files, in the dump's layout.
        _progress(InstallStep.unwrap, 0);
        final source = p.join(work, 'source');
        Directory(source).createSync(recursive: true);
        // Only what the dump holds goes in: a fresh folder each time, the output beside it.
        final duplicates = duplicateModules(allModulesOf(game), foldCase: system == HostSystem.windows);
        for (final MapEntry(key: copy, value: used) in duplicates.entries) {
          _log('$copy: the dump has this module as $used too, the game is unlocked with that one');
        }
        final inputs = ['eboot.bin', ...found];
        final placed = <String>[];
        for (var index = 0; index < inputs.length; index++) {
          await _gate();
          final relative = inputs[index];
          final target = p.join(source, p.joinAll(relative.split('/')));
          Directory(p.dirname(target)).createSync(recursive: true);
          if (await _unwrap(relative, Installer.source(game, relative), target) && index > 0) placed.add(relative);
          _progress(InstallStep.unwrap, (index + 1) / inputs.length);
          await _yield();
        }

        // 2. The relinker turns them into the host's executable and guest modules.
        _progress(InstallStep.relink, 0);
        final output = p.join(work, 'out');
        Directory(output).createSync(recursive: true);
        final executable = p.join(output, system.executableName);
        final estimate = RelinkProgress();
        final patchOptions = <String>[];
        if (patchText != null) {
          final copy = p.join(work, 'relinker-patches.toml');
          File(copy).writeAsStringSync(patchText);
          patchOptions.addAll(['--patches', copy]);
          _log(
            '${game.titleId}: patches from ${game.titleId}.toml'
            '${appliedResolution == null ? '' : ', resolution $appliedResolution'}',
          );
        }
        // A module the relinker cannot convert is left out and the relink runs again: the game
        // starts without it, as without an encrypted one. A failure in the executable stops.
        while (true) {
          try {
            await _runTool(
              toolkit.relinker,
              [
                ...system.relinkerOptions,
                for (final flag in flags) flag.option,
                ...patchOptions,
                for (final directory in moduleDirectories(found)) ...['--module-dir', directory],
                ...custom,
                'eboot.bin',
                executable,
              ],
              workingDirectory: source,
              status: (segment) {
                final fraction = estimate.read(segment);
                if (fraction != null) _progress(InstallStep.relink, fraction);
              },
            );
            break;
          } on ToolFailed catch (failure) {
            final module = failedModule(failure, source, placed);
            if (module != null) {
              placed.remove(module);
              _delete(p.join(source, p.joinAll(module.split('/'))));
              _delete(output);
              Directory(output).createSync(recursive: true);
              leftOut.add(LeftOutModule(module, LeftOutReason.notRelinked, failure.reason));
              _log(
                '$module: the relinker could not convert it (${failure.reason}); '
                'it is left out and the relink runs again without it',
              );
              continue;
            }
            if (flags.isEmpty && custom.isEmpty) rethrow;
            // A saved option never costs the game its unlock: it runs again without them, and
            // the kept output is filed under what it was really made with.
            _log(
              '${game.titleId}: the relinker stopped with ${[...flags.map((flag) => flag.option), ...custom].join(' ')} '
              '(${failure.reason}); the game is rebuilt without it',
            );
            flags = [];
            custom = const [];
            key = relinkKey(game, toolkit, found, patchText);
            _delete(output);
            Directory(output).createSync(recursive: true);
          }
        }
        if (!File(executable).existsSync()) throw InstallError('relinker wrote no executable');
        relinked = keeps ? _keep(output, key) : output;
        _progress(InstallStep.relink, 1);
      }
      final executable = p.join(relinked, system.executableName);
      if (!File(executable).existsSync()) throw InstallError('relinker wrote no executable');
      // Kept output is hard linked in (nothing writes to it); output in the work folder is copied.
      final outputMode = relinked == reusable || (keeps && p.isWithin(store, relinked) && !p.isWithin(work, relinked))
          ? LinkMode.hard
          : LinkMode.copy;

      // 3. The game's files, linked (or copied where no link works), with the relinked modules
      // over them.
      await _gate();
      await _deleteAway(partial);
      final app0 = p.join(partial, 'app0');
      Directory(app0).createSync(recursive: true);
      await _linkTree(game.folder, app0, mode, (fraction) => _progress(InstallStep.copy, fraction));
      final guestModules = p.join(relinked, 'app0');
      if (Directory(guestModules).existsSync()) {
        await copyTree(guestModules, app0, outputMode, isCancelled: () => _cancelled, gate: _gate);
      }

      // 4. The executable, the libraries, the launch script and the record.
      await _gate();
      _progress(InstallStep.layout, 0);
      final placed = p.join(partial, system.executableName);
      FileLinks.place(executable, placed, outputMode);
      await _makeExecutable(placed);
      final libraries = p.join(partial, 'libs');
      Directory(libraries).createSync(recursive: true);
      final libraryFiles = toolkit.libraryFiles;
      final libraryMode = libraryFiles.isEmpty ? LinkMode.copy : FileLinks.probe(libraryFiles.first, libraries);
      for (final library in libraryFiles) {
        FileLinks.place(
          library,
          p.join(libraries, p.basename(library)),
          libraryMode == LinkMode.hard ? LinkMode.hard : LinkMode.copy,
        );
      }
      _progress(InstallStep.layout, 0.6);
      final script = p.join(partial, system.launchScriptName);
      File(script).writeAsStringSync(launchScript(system, game));
      await _makeExecutable(script);
      final record = InstallRecord(
        source: game.folder,
        titleId: game.titleId,
        toolkit: toolkit.version,
        system: system.name,
        date: _clock(),
        resolution: appliedResolution,
        update: game.update?.version,
        relinkerFlags: [for (final flag in flags) flag.option],
        customRelinkerOptions: custom,
      );
      File(p.join(partial, recordName)).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(record.toJson()));
      _progress(InstallStep.layout, 1);

      // 5. It takes the old one's place, with what the game wrote there.
      _progress(InstallStep.finish, 0);
      await placeInstalled(partial, installed);
      _progress(InstallStep.finish, 1);
      return installed;
    } finally {
      _running = null;
      await _deleteAway(work);
      await _deleteAway(partial);
    }
  }

  /// Puts a finished game in place. What the game wrote beside app0 in the old one (saves in _sd,
  /// trophies in _trophy, its data and download folders) moves into the new one. The old one is
  /// renamed aside at once and removed after, on the system's file threads: a game of tens of
  /// thousands of files took the screen with it while it went.
  static Future<void> placeInstalled(String partial, String installed) async {
    try {
      final exists = Directory(installed).existsSync();
      if (exists) carryOver(installed, partial);
      // The saves an uninstalled or deleted game left ([keepSaves]) come back, unless the game
      // has its own.
      final kept = keptSaves(installed);
      if (Directory(kept).existsSync()) {
        carryOver(kept, partial);
        try {
          if (Directory(kept).listSync().isEmpty) Directory(kept).deleteSync();
        } on FileSystemException {
          // It stays for the next unlock.
        }
      }
      if (exists) {
        final old = '$installed.old-${DateTime.now().microsecondsSinceEpoch}.partial';
        try {
          Directory(installed).renameSync(old);
        } on FileSystemException {
          await _deleteAway(installed);
        }
        Directory(p.dirname(installed)).createSync(recursive: true);
        Directory(partial).renameSync(installed);
        await _deleteAway(old);
        return;
      }
      Directory(p.dirname(installed)).createSync(recursive: true);
      Directory(partial).renameSync(installed);
    } on FileSystemException {
      // The new one did not take its place and is removed by the unlock that made it: the saves
      // that moved into it wait in the store for the next unlock.
      try {
        if (Directory(partial).existsSync()) moveSaves(partial, keptSaves(installed));
      } on FileSystemException {
        // Where they are.
      }
      rethrow;
    }
  }

  /// The items of [source] the new game does not have move into [target]; links stay behind.
  static void carryOver(String source, String target) {
    for (final entry in Directory(source).listSync(followLinks: false)) {
      final name = p.basename(entry.path);
      final destination = p.join(target, name);
      if (FileSystemEntity.typeSync(destination, followLinks: false) != FileSystemEntityType.notFound) continue;
      if (entry is Link) continue;
      entry.renameSync(destination);
    }
  }

  /// The suffix the relinker gives the modules it converts (libX.prx becomes libX.prx.guest.prx).
  static const guestSuffix = '.guest.prx';

  /// Whether the file [name] is a module the relinker wrote, never one of its inputs.
  static bool isRelinkerOutput(String name) => p.basename(name).toLowerCase().endsWith(guestSuffix);

  /// Every .prx and .sprx of the dump outside sce_sys, at most three levels down, relative to its
  /// folder with / separators, sorted; a relinker's output ([isRelinkerOutput]) is left out.
  static List<String> modules(String folder) {
    final found = <String>[];
    void visit(String directory, List<String> parts) {
      List<FileSystemEntity> entries;
      try {
        entries = Directory(directory).listSync(followLinks: true);
      } on FileSystemException {
        return;
      }
      for (final entry in entries) {
        final name = p.basename(entry.path);
        if (name.startsWith('.')) continue;
        final relative = [...parts, name];
        if (entry is Directory) {
          if (parts.isEmpty && name == 'sce_sys') continue;
          if (relative.length < 3) visit(entry.path, relative);
        } else if (entry is File) {
          final lower = name.toLowerCase();
          // A relinker's output left in the dump (a relink by hand writes them into app0's
          // sce_module, the dump's own folder) is no module of the game.
          if (isRelinkerOutput(name)) continue;
          if (lower.endsWith('.prx') || lower.endsWith('.sprx')) found.add(relative.join('/'));
        }
      }
    }

    visit(folder, const []);
    found.sort();
    return found;
  }

  /// The folders besides sce_module whose modules the relinker converts too (Unity's
  /// Media/Modules and Media/Plugins, prx next to eboot.bin). fakelib holds a dump tool's
  /// stand-ins for system libraries, which AnyPS5 implements itself.
  static List<String> moduleDirectories(List<String> modules) {
    final directories = ['.'];
    for (final module in modules) {
      if (!module.toLowerCase().endsWith('.prx')) continue;
      final slash = module.lastIndexOf('/');
      final directory = slash < 0 ? '.' : module.substring(0, slash);
      final first = directory.split('/').first;
      if (const ['sce_module', 'sce_modules', 'prx', 'fakelib'].contains(first.toLowerCase())) continue;
      if (directories.contains(directory)) continue;
      directories.add(directory);
    }
    return directories;
  }

  /// An ELF as it is, a re-signed one from its .esbak, a SELF container unwrapped (in an isolate
  /// of its own: an executable is read whole, and can be hundreds of megabytes). A module
  /// ([relative] other than eboot.bin) still encrypted in the dump is left out ([leftOut]) and
  /// false returned: the engine starts a game without one of its modules (the game gets an error
  /// when it loads it), while it cannot start one without its executable.
  Future<bool> _unwrap(String relative, String original, String target) async {
    final name = p.basename(original);
    final executable = relative == 'eboot.bin';
    String? refused;
    if (Binary.isElf(original)) {
      await File(original).copy(target);
      return true;
    } else if (Binary.isElf('$original.esbak')) {
      await File('$original.esbak').copy(target);
      _log('$name: from .esbak');
      return true;
    } else if (SelfUnwrap.isContainer(original)) {
      try {
        final size = await Isolate.run(() => SelfUnwrap.unwrapFile(original, target));
        _log('$name: unwrapped, $size bytes');
        return true;
      } on SelfRefused catch (error) {
        if (executable) throw InstallError('$name: ${error.reason}');
        refused = error.reason;
      }
    }
    if (executable) {
      throw InstallError(
        'eboot.bin in the dump is encrypted (neither an ELF nor a decrypted SELF container): '
        'dump the game again with a dumper that decrypts it',
      );
    }
    leftOut.add(LeftOutModule(relative, LeftOutReason.encrypted, refused));
    _log(
      '$relative in the dump is encrypted (${refused ?? 'neither an ELF nor a decrypted SELF container'}): '
      'it is left out, and the game is unlocked without it',
    );
    return false;
  }

  /// The module of the source tree [source] the relinker named in [failure], relative with /
  /// separators; null when it named none, or the executable.
  static String? failedModule(ToolFailed failure, String source, List<String> modules) {
    final input = failure.input;
    if (input == null) return null;
    final path = p.isAbsolute(input) ? input : p.join(source, input);
    // The relinker names it from its working directory as the system gives it, links resolved
    // (/var is /private/var on macOS).
    final relative = ToolFailed._inside(path, source);
    for (final module in modules) {
      if (p.equals(module, relative)) return module;
    }
    return null;
  }

  Future<void> _linkTree(String source, String target, LinkMode mode, void Function(double) progress) async {
    if (linkMode == null) {
      if (mode != LinkMode.hard) {
        _log(
          mode == LinkMode.symbolic
              ? '${game.titleId}: the store is on another volume than the dump, so the game links to it'
              : '${game.titleId}: the store cannot link to the dump (another volume without symbolic links: '
                    'on Windows turn Developer Mode on, or keep the games folder on the dump\'s drive), '
                    'so the game is copied',
        );
      }
    }
    // A relinker's output left in the dump is from another relink: only this one's goes in.
    await copyTree(
      source,
      target,
      mode,
      isCancelled: () => _cancelled,
      progress: progress,
      gate: _gate,
      skip: isRelinkerOutput,
    );
  }

  /// Beside the kept output: the modules its relink left out, said again when it is reused.
  static const leftOutName = 'left-out.json';

  static List<LeftOutModule> _keptLeftOut(String out) {
    try {
      final json = jsonDecode(File(p.join(p.dirname(out), leftOutName)).readAsStringSync());
      return [for (final entry in json as List<dynamic>) LeftOutModule.fromJson(entry as Map<String, dynamic>)];
    } on FileSystemException {
      return const [];
    } on Object {
      return const [];
    }
  }

  /// Moves the relinker's output into the store for the next unlock (a rename on the same drive)
  /// and returns where it is now; where that fails, it stays in the work folder.
  String _keep(String output, String key) {
    final kept = keptRelink(game, root);
    _delete(kept);
    try {
      Directory(kept).createSync(recursive: true);
      Directory(output).renameSync(p.join(kept, 'out'));
      if (leftOut.isNotEmpty) {
        File(p.join(kept, leftOutName)).writeAsStringSync(jsonEncode([for (final module in leftOut) module.toJson()]));
      }
      File(p.join(kept, 'key.txt')).writeAsStringSync(key);
      return p.join(kept, 'out');
    } on FileSystemException {
      final moved = p.join(kept, 'out');
      if (Directory(moved).existsSync() && !Directory(output).existsSync()) {
        try {
          Directory(moved).renameSync(output);
        } on FileSystemException {
          return moved;
        }
      }
      _delete(kept);
      return output;
    }
  }

  /// The files of [source] in [target], folder by folder, each placed as [mode] says; the store
  /// and the files [skip] names are left out. Reports the share of bytes done. The listing and
  /// the copies run on the system's file threads, so the screen goes on meanwhile (links are made
  /// in small batches).
  static Future<void> copyTree(
    String source,
    String target,
    LinkMode mode, {
    bool Function()? isCancelled,
    void Function(double)? progress,
    Future<void> Function()? gate,
    bool Function(String path)? skip,
  }) async {
    final base = p.normalize(p.absolute(source));
    final files = <(String, String, int)>[];
    var total = 0;
    await for (final entry in Directory(base).list(recursive: true, followLinks: true)) {
      final relative = p.relative(entry.path, from: base);
      final first = p.split(relative).first;
      if (first == GameLibrary.storeName) continue;
      if (entry is File && (skip?.call(entry.path) ?? false)) continue;
      if (entry is Directory) {
        await Directory(p.join(target, relative)).create(recursive: true);
      } else if (entry is File) {
        final size = await entry.length();
        files.add((entry.path, relative, size));
        total += size;
      }
    }
    var done = 0;
    for (var index = 0; index < files.length; index++) {
      if (isCancelled?.call() ?? false) throw InstallCancelled();
      final (path, relative, size) = files[index];
      final destination = p.join(target, relative);
      Directory(p.dirname(destination)).createSync(recursive: true);
      if (mode == LinkMode.copy) {
        // A copy can be gigabytes: never on the interface's isolate.
        FileLinks.remove(destination);
        await File(path).copy(destination);
      } else {
        FileLinks.place(path, destination, mode);
      }
      done += size;
      progress?.call(total == 0 ? 1 : done / total);
      if (mode == LinkMode.copy || index % 64 == 63) {
        await _yield();
        await gate?.call();
      }
    }
    progress?.call(1);
  }

  /// The script that starts the installed game from its folder without the launcher.
  static String launchScript(HostSystem system, Game game) {
    if (system == HostSystem.windows) {
      return '@echo off\r\n'
          'rem Starts ${game.name} (${game.titleId}) from its folder: AnyPS5 maps /app0 under the working directory.\r\n'
          'cd /d "%~dp0"\r\n'
          '"%~dp0app.exe" %*\r\n';
    }
    return '#!/bin/sh\n'
        '# Starts ${game.name} (${game.titleId}) from its folder: AnyPS5 maps /app0 under the working directory.\n'
        'cd "\$(dirname "\$0")" || exit 1\n'
        'exec ./app.elf "\$@"\n';
  }

  /// PATH with [folders] first (a checkout's compiler folder, whose DLLs a relinker built with
  /// MinGW loads); null to keep the launcher's environment.
  static Map<String, String>? _toolEnvironment(List<String> folders) {
    if (folders.isEmpty) return null;
    final environment = Platform.environment;
    final key = environment.keys.firstWhere((name) => name.toUpperCase() == 'PATH', orElse: () => 'PATH');
    final rest = environment[key];
    return {
      key: [...folders, if (rest != null && rest.isNotEmpty) rest].join(Platform.isWindows ? ';' : ':'),
    };
  }

  Future<void> _runTool(
    String tool,
    List<String> arguments, {
    required String workingDirectory,
    void Function(String segment)? status,
  }) async {
    _checkCancelled();
    final Process process;
    try {
      process = await Process.start(
        tool,
        arguments,
        workingDirectory: workingDirectory,
        environment: _toolEnvironment(toolkit.toolFolders),
      );
    } on ProcessException catch (error) {
      throw InstallError('${p.basename(tool)} could not start: ${error.message}');
    }
    _running = process;
    if (_cancelled) process.kill();
    if (_background) ProcessControl.lower(process.pid);
    if (_paused) ProcessControl.suspend(process.pid);
    final collector = OutputCollector(log: _log, status: status);
    final out = process.stdout.forEach(collector.add);
    final err = process.stderr.forEach(collector.add);
    final code = await process.exitCode;
    // A child the tool left behind can hold its output open; the tool's own output is in by now.
    await Future.wait([out, err])
        .timeout(const Duration(seconds: 2), onTimeout: () => const [])
        .catchError((_) => const <void>[]);
    collector.flush();
    _running = null;
    _checkCancelled();
    if (code != 0) {
      throw ToolFailed(p.basename(tool), code, List.of(collector.lines), workingDirectory: workingDirectory);
    }
  }

  static Future<void> _makeExecutable(String path) async {
    if (Platform.isWindows) return;
    await Process.run('chmod', ['755', path]);
  }

  static Future<void> _yield() => Future<void>.delayed(Duration.zero);

  static void _delete(String path) {
    try {
      FileLinks.remove(path);
    } on FileSystemException {
      // Gone or busy; a later install cleans up.
    }
  }

  /// [_delete] for a folder that may be big (a whole game), on the system's file threads. Never
  /// through a link: Directory.delete removes links, not what they point to.
  static Future<void> _deleteAway(String path) async {
    try {
      switch (FileSystemEntity.typeSync(path, followLinks: false)) {
        case FileSystemEntityType.directory:
          await Directory(path).delete(recursive: true);
        case FileSystemEntityType.notFound:
          break;
        default:
          FileLinks.remove(path);
      }
    } on FileSystemException {
      // Gone or busy; a later install cleans up.
    }
  }
}

/// Splits a tool's output into lines for the log as it arrives. A progress display rewrites its
/// line with carriage returns: every rewrite goes to [status], only the line's last state to the
/// log.
class OutputCollector {
  OutputCollector({this.log, this.status});

  final void Function(String line)? log;
  final void Function(String segment)? status;
  final List<int> _pending = [];
  String? _rewritten;
  final List<String> lines = [];

  void add(List<int> data) {
    _pending.addAll(data);
    final complete = <String>[];
    final segments = <String>[];
    while (true) {
      final end = _pending.indexWhere((byte) => byte == 0x0A || byte == 0x0D);
      if (end < 0) break;
      final text = utf8.decode(_pending.sublist(0, end), allowMalformed: true);
      final newline = _pending[end] == 0x0A;
      _pending.removeRange(0, end + 1);
      if (text.isNotEmpty) {
        segments.add(text);
        _rewritten = text;
      }
      if (newline) {
        if (_rewritten != null) complete.add(_rewritten!);
        _rewritten = null;
      }
    }
    lines.addAll(complete);
    if (lines.length > 400) lines.removeRange(0, lines.length - 400);
    segments.forEach(status ?? (_) {});
    complete.forEach(log ?? (_) {});
  }

  void flush() {
    final rest = _pending.isEmpty ? _rewritten : utf8.decode(_pending, allowMalformed: true);
    _pending.clear();
    _rewritten = null;
    if (rest != null && rest.isNotEmpty) {
      lines.add(rest);
      log?.call(rest);
    }
  }
}

/// Turns the relinker's progress display ("Instruction scan | eboot.bin | 42%") into one rising
/// fraction of the relink step.
class RelinkProgress {
  double _reached = 0;

  double? read(String segment) {
    final fields = segment.split('|').map((field) => field.trim()).toList();
    if (fields.length < 3) return null;
    final phase = fields[0];
    final file = fields[1];
    final value = fields[2];
    final percent = double.tryParse(value.split('%').first.trim());
    if (percent == null) return null;
    final done = (percent / 100).clamp(0.0, 1.0);
    double estimate;
    switch (phase) {
      case 'Instruction scan' when file == 'eboot.bin':
        estimate = 0.2 * done;
      case 'Instruction conversion' when file == 'eboot.bin':
        estimate = 0.2 + 0.25 * done;
      case 'Syscall scan' when file == 'eboot.bin':
        estimate = 0.45 + 0.1 * done;
      case 'PRX conversion':
        // "100% (3/7)": modules converted of all.
        final match = RegExp(r'\((\d+)/(\d+)\)').firstMatch(value);
        final converted = match == null ? null : double.parse(match.group(1)!);
        final all = match == null ? null : double.parse(match.group(2)!);
        estimate = converted != null && all != null && all > 0 ? 0.55 + 0.3 * converted / all : 0.55;
      case 'Output image':
        estimate = 0.85 + 0.1 * done;
      case 'Write output':
        estimate = 0.95 + 0.05 * done;
      default:
        return null;
    }
    if (estimate <= _reached) return null;
    _reached = estimate;
    return estimate;
  }
}
