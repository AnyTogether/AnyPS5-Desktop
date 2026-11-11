import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'engine_checkout.dart' show CommandRunner;
import 'game_addons.dart';
import 'game_archives.dart';
import 'game_library.dart';

/// Why Delete game will not touch a game's files.
enum DeletionRefusal {
  /// The game's folder is a games folder itself, or holds one: deleting it would take the
  /// library's own folder (and whatever else is in it).
  libraryFolder,

  /// The game's folder is a link, or is reached through one that leads out of its games folder:
  /// the files live somewhere the library does not own.
  linkedElsewhere,

  /// Another game of the library keeps its files inside this game's folder.
  sharedFolder,
}

/// Delete game refused, and why.
class DeletionRefused implements Exception {
  const DeletionRefused(this.reason);

  final DeletionRefusal reason;

  @override
  String toString() => 'DeletionRefused(${reason.name})';
}

/// What Delete game takes from the disk: the game's own folder first, then what belongs to it and
/// to no other game (its update, its add-ons, and the archives those folders were unpacked from).
class DeletionPlan {
  const DeletionPlan({required this.game, required this.root, required this.items});

  final Game game;

  /// The games folder the game was found in.
  final String root;

  /// The folders and files that go, the game's folder first. Never a link.
  final List<String> items;

  /// The game's own folder.
  String get folder => items.first;

  /// What goes with the game's folder.
  List<String> get extras => items.sublist(1);
}

/// How one item left the disk.
sealed class TrashResult {
  const TrashResult();
}

/// In the trash, where it can be put back from.
class Trashed extends TrashResult {
  const Trashed();
}

/// There is no trash for it where it is (another drive without one, a network share, a folder too
/// big for the Recycle Bin): nothing was touched.
class NoTrash extends TrashResult {
  const NoTrash([this.detail]);

  final String? detail;
}

/// It could not be moved (in use, no permission): nothing was touched.
class TrashFailed extends TrashResult {
  const TrashFailed(this.message);

  final String message;
}

/// The system's trash: the Recycle Bin on Windows (the runner's IFileOperation), the freedesktop
/// trash on Linux ([LinuxTrash]). Never deletes for good.
abstract class Trash {
  const Trash();

  Future<TrashResult> move(String path);
}

/// The freedesktop trash through the desktop's own tool: `gio trash` (GLib, on every GNOME, Xfce
/// and Cinnamon desktop and most others), else KDE's kioclient. A desktop with neither, or a
/// place they cannot trash from (a drive mounted without a trash folder), has no trash.
class LinuxTrash extends Trash {
  const LinuxTrash(this.commands);

  final CommandRunner commands;

  static const _tools = [
    ('gio', ['trash', '--']),
    ('kioclient6', ['--noninteractive', 'move', '--']),
    ('kioclient5', ['--noninteractive', 'move', '--']),
  ];

  @override
  Future<TrashResult> move(String path) async {
    String? said;
    for (final (tool, arguments) in _tools) {
      final lines = <String>[];
      try {
        final code = await commands.run(
          tool,
          [...arguments, path, if (tool != 'gio') 'trash:/'],
          workingDirectory: p.dirname(path),
          onLine: lines.add,
        );
        if (code == 0 && FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.notFound) {
          return const Trashed();
        }
        said ??= lines.where((line) => line.trim().isNotEmpty).lastOrNull?.trim();
      } on ProcessException {
        // Not installed: the next one.
      }
      // Still there: the next tool may know a trash this one does not.
    }
    return NoTrash(said);
  }
}

/// How a deletion ended.
sealed class DeletionOutcome {
  const DeletionOutcome();
}

/// The game's folder is gone. [left] could not follow it (the paths).
class Deleted extends DeletionOutcome {
  const Deleted({this.left = const []});

  final List<String> left;
}

/// The game's folder cannot go to the trash where it is; nothing was touched.
class NeedsPermanent extends DeletionOutcome {
  const NeedsPermanent();
}

/// The game's folder could not be removed; nothing was touched.
class DeletionFailed extends DeletionOutcome {
  const DeletionFailed(this.message);

  final String message;
}

/// Delete game: the game's own files off the disk, into the system's trash. What it may take is
/// decided here, away from the interface, so it can be tested without one.
abstract final class GameDeletion {
  /// What deleting [game] takes, or [DeletionRefused]. [root] is the games folder it was found in,
  /// [roots] all the games folders and [games] the library.
  ///
  /// Only the game's own root ever goes: the folder that holds its eboot.bin and sce_sys. Never
  /// a games folder (a dump kept loose in one shares it with the store and with other games),
  /// never a link or a folder reached through a link that leads out of the games folder, never a
  /// folder another game lives in. Its update and add-ons go with it unless another game uses
  /// them too, and so does the archive a folder was unpacked from: left behind, the update would
  /// show as a game of its own and the archive would be offered for unpacking again.
  static DeletionPlan plan(Game game, {required String root, required List<String> roots, required List<Game> games}) {
    final folder = game.folder;
    if (_isLink(folder)) throw const DeletionRefused(DeletionRefusal.linkedElsewhere);
    for (final other in {root, ...roots}) {
      if (p.equals(other, folder) || p.isWithin(folder, other)) {
        throw const DeletionRefused(DeletionRefusal.libraryFolder);
      }
    }
    final realRoot = _real(root), realFolder = _real(folder);
    if (realRoot == null || realFolder == null) throw const DeletionRefused(DeletionRefusal.linkedElsewhere);
    if (p.equals(realRoot, realFolder)) throw const DeletionRefused(DeletionRefusal.libraryFolder);
    if (!p.isWithin(realRoot, realFolder)) throw const DeletionRefused(DeletionRefusal.linkedElsewhere);
    for (final other in roots) {
      final real = _real(other);
      if (real != null && (p.equals(real, realFolder) || p.isWithin(realFolder, real))) {
        throw const DeletionRefused(DeletionRefusal.libraryFolder);
      }
    }
    final others = [
      for (final other in games)
        if (other.id != game.id) other,
    ];
    // What the other games own: their folders, updates and add-ons.
    final taken = [
      for (final other in others) ...[
        other.folder,
        ?other.update?.folder,
        for (final addon in other.addons) addon.folder,
      ],
    ];
    if (taken.any((path) => p.isWithin(folder, path) || p.equals(folder, path))) {
      throw const DeletionRefused(DeletionRefusal.sharedFolder);
    }
    final items = <String>[folder];
    void add(String path) {
      if (items.any((item) => p.equals(item, path) || p.isWithin(item, path))) return;
      if (FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.directory) return;
      final real = _real(path);
      if (real == null || !p.isWithin(realRoot, real)) return;
      if ({root, ...roots}.any((other) => p.equals(other, path) || p.isWithin(path, other))) return;
      // Another game's too (two dumps of one title share an update): it stays.
      if (taken.any((other) => p.equals(other, path) || p.isWithin(path, other) || p.isWithin(other, path))) return;
      items.add(path);
    }

    if (game.update case final GameUpdate update) add(update.folder);
    for (final addon in game.addons) {
      // "<game>-DLC" holds nothing but this game's add-ons: the whole folder goes.
      final parent = p.dirname(addon.folder);
      final own = GameAddons.addonSuffixes.any((suffix) => p.basename(parent).toLowerCase().endsWith(suffix));
      add(own && !p.equals(parent, p.dirname(folder)) ? parent : addon.folder);
    }
    // The archive a folder was unpacked from, beside it under the same name.
    for (final item in [...items]) {
      for (final extension in GameArchives.extensions) {
        final archive = '$item$extension';
        if (FileSystemEntity.typeSync(archive, followLinks: false) == FileSystemEntityType.file) items.add(archive);
      }
    }
    return DeletionPlan(game: game, root: root, items: items);
  }

  /// Moves the plan's items to [trash], or with [permanent] deletes them for good ([remove]).
  /// The game's folder goes first: when it cannot go, nothing else is touched. Runs on the
  /// system's file threads and the trash's own process, never on the interface's.
  static Future<DeletionOutcome> run(
    DeletionPlan plan, {
    required Trash? trash,
    bool permanent = false,
    Future<void> Function(String path)? remove,
  }) async {
    final left = <String>[];
    for (final (index, item) in plan.items.indexed) {
      final first = index == 0;
      final type = FileSystemEntity.typeSync(item, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        if (first) return const DeletionFailed('the folder is not there');
        continue;
      }
      // Changed into a link since it was planned: never followed.
      if (type == FileSystemEntityType.link) {
        if (first) return const DeletionFailed('the folder became a link');
        left.add(item);
        continue;
      }
      TrashResult result;
      try {
        if (permanent) {
          await (remove ?? removeForGood)(item);
          result = const Trashed();
        } else {
          result = trash == null ? const NoTrash() : await trash.move(item);
        }
      } on FileSystemException catch (error) {
        result = TrashFailed(error.osError?.message ?? error.message);
      }
      switch (result) {
        case Trashed():
          break;
        case NoTrash():
          if (first) return const NeedsPermanent();
          left.add(item);
        case TrashFailed(:final message):
          if (first) return DeletionFailed(message);
          left.add(item);
      }
    }
    return Deleted(left: left);
  }

  /// Deletes [path] for good, links in it never followed.
  static Future<void> removeForGood(String path) async {
    switch (FileSystemEntity.typeSync(path, followLinks: false)) {
      case FileSystemEntityType.directory:
        await Directory(path).delete(recursive: true);
      case FileSystemEntityType.file:
        await File(path).delete();
      default:
        break;
    }
  }

  /// The bytes the plan's items take, files and folders alike.
  static int size(List<String> items) {
    var total = 0;
    for (final item in items) {
      try {
        total += switch (FileSystemEntity.typeSync(item, followLinks: false)) {
          FileSystemEntityType.directory => GameLibrary.size(item),
          FileSystemEntityType.file => File(item).lengthSync(),
          _ => 0,
        };
      } on FileSystemException {
        // What could be read counts.
      }
    }
    return total;
  }

  static bool _isLink(String path) => FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.link;

  /// [path] with every link in it followed, null when it cannot be read.
  static String? _real(String path) {
    try {
      return Directory(path).resolveSymbolicLinksSync();
    } on FileSystemException {
      return null;
    }
  }
}
