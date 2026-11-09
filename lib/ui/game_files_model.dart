import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/audio/tones.dart' show Cue;
import '../core/game_archives.dart';
import '../core/game_library.dart';
import '../core/game_updates.dart';
import 'app_model.dart';
import 'components.dart' show byteText;
import 'strings.dart';

/// What the files panel ([Layer.gameFiles]) is about: a zip in a games folder to unpack, or an
/// update folder to put beside a game.
sealed class FilesAsk {
  const FilesAsk();
}

/// A game dropped into the games folder as a zip: unpacked into [into] (the folder beside it, or
/// the update folder of the game in the library it is an update for).
class UnpackAsk extends FilesAsk {
  const UnpackAsk(this.archive, this.plan, {required this.into, this.updateOf});

  final GameArchive archive;
  final ArchivePlan plan;
  final String into;

  /// The game in the library it is an update for, null for a game of its own.
  final Game? updateOf;
}

/// Game Settings › Add Update: a dump of the game's update, checked, to be put beside it.
class UpdateAsk extends FilesAsk {
  const UpdateAsk(this.update, this.game, {required this.size});

  final UpdateCandidate update;
  final Game game;
  final int size;
}

/// Zips dropped into the games folders (offered for unpacking, then read as any dump) and
/// updates added from a folder (Game Settings › Add Update). One job at a time, its progress in
/// the panel; Back hides the panel and the job goes on.
class GameFilesModel {
  GameFilesModel(this.app);

  final AppModel app;

  /// What the panel asks about or works on.
  FilesAsk? asked;

  /// The job running, with its bytes done and the whole.
  FilesAsk? working;
  int done = 0;
  int total = 0;
  UnpackCancel? _cancel;

  /// The zips looked into, by path: their size then (a zip still being copied grows), when, and
  /// the plan (null for one that could not be read as a zip yet).
  final Map<String, (int, DateTime, ArchivePlan?)> _plans = {};

  /// How soon a zip that could not be read is looked into again: a copy that set the file's
  /// whole size first (Explorer does) writes the zip's list of files last.
  static const retryUnread = Duration(seconds: 10);

  /// Zips answered Not Now, until the launcher starts again.
  final Set<String> _later = {};

  /// The zips with a game in them, waiting to be offered.
  final List<UnpackAsk> waiting = [];
  bool _looking = false;
  List<String>? _again;
  Timer? _retry;

  /// After a scan of the games folders: new zips are looked into (away from the interface), and
  /// one with a game in it is offered when nothing else is on the screen.
  void scanned(List<String> roots) {
    if (_looking) {
      _again = roots;
      return;
    }
    final found = GameArchives.find(roots);
    final paths = {for (final archive in found) archive.path};
    _plans.removeWhere((path, _) => !paths.contains(path));
    waiting.removeWhere((ask) => !paths.contains(ask.archive.path));
    unawaited(_look(found, roots));
  }

  Future<void> _look(List<GameArchive> found, List<String> roots) async {
    _looking = true;
    var unread = false;
    try {
      for (final archive in found) {
        final known = _plans[archive.path];
        if (known != null && known.$1 == archive.size) {
          if (known.$3 != null) continue;
          if (DateTime.now().difference(known.$2) < retryUnread) {
            unread = true;
            continue;
          }
        }
        ArchivePlan? plan;
        try {
          plan = await _planOf(archive.path);
        } on Object catch (error) {
          debugPrint('[anyps5-launcher] ${archive.name} cannot be read as a zip yet: $error');
        }
        // No list of files: still being copied, or not a zip. Looked into again in a while.
        // A .ffpfsc that says why it will not unpack has its answer already.
        if (plan != null && plan.files == 0 && plan.problem == null) plan = null;
        unread |= plan == null;
        _plans[archive.path] = (archive.size, DateTime.now(), plan);
      }
    } finally {
      _looking = false;
    }
    if (_disposed) return;
    waiting
      ..clear()
      ..addAll([
        for (final archive in found)
          if (_plans[archive.path]?.$3 case final ArchivePlan plan when plan.looksLikeGame || plan.problem != null)
            if (_ask(archive, plan) case final UnpackAsk ask) ask,
      ]);
    offerNext();
    final again = _again;
    _again = null;
    if (again != null) return scanned(again);
    if (unread && !(_retry?.isActive ?? false)) {
      _retry = Timer(retryUnread, () {
        if (app.preferences.gamesFolders.isNotEmpty) scanned(app.preferences.gamesFolders);
      });
    }
  }

  bool _disposed = false;

  // Static, so the isolate's closure holds the path alone and not this model.
  static Future<ArchivePlan> _planOf(String path) => Isolate.run(() => GameArchives.plan(path));
  static Future<int> _sizeOf(String folder) => Isolate.run(() => GameLibrary.size(folder));

  void dispose() {
    _disposed = true;
    _retry?.cancel();
  }

  /// Where [archive] unpacks: the update folder of a game in the library when it is a newer
  /// version of it, else [folder] (the one beside it when not given). Null when that folder is
  /// there already.
  UnpackAsk? _ask(GameArchive archive, ArchivePlan plan, {String? folder}) {
    final titleId = plan.titleId;
    final version = plan.version;
    if (titleId != null && version != null) {
      for (final game in app.games) {
        if (game.titleId.toUpperCase() != titleId.toUpperCase()) continue;
        final problem = GameUpdates.problemWith(game, titleId: titleId, version: version);
        // The update the game has already, or one as new: nothing to offer.
        if (problem == UpdateProblem.haveNewer) return null;
        if (problem == null) return UnpackAsk(archive, plan, into: GameUpdates.target(game), updateOf: game);
      }
    }
    final target = folder ?? archive.folder;
    if (FileSystemEntity.typeSync(target) != FileSystemEntityType.notFound) return null;
    return UnpackAsk(archive, plan, into: target);
  }

  /// The first zip waiting, offered when the home screen shows nothing else.
  void offerNext() {
    if (working != null || !app.preferences.onboarded) return;
    // A question another screen took the place of is dropped.
    if (asked != null && app.overlay == Layer.gameFiles) return;
    asked = null;
    if (app.overlay != null || app.running != null || app.starting != null) return;
    final next = waiting.where((ask) => !_later.contains(ask.archive.path)).firstOrNull;
    if (next == null) return;
    asked = next;
    app.open(Layer.gameFiles);
  }

  /// Settings › Game library › Add game file: one .ffpfsc chosen and unpacked into a normal game
  /// folder, in the first games folder unless it already sits in a games folder.
  Future<void> addGameFile() async {
    if (working != null) return app.show(T.text('filesBusy'));
    if (app.preferences.gamesFolders.isEmpty) return app.show(T.text('addGameFileNoFolder'));
    final file = await app.services.pickFile?.call(T.text('addGameFileChoose'), const ['ffpfsc']);
    if (file == null) return;
    await addGameFilePicked(file);
  }

  /// The file at [file] looked into away from the interface, then offered or said to be no game.
  Future<void> addGameFilePicked(String file) async {
    final folders = app.preferences.gamesFolders;
    int size;
    try {
      size = File(file).lengthSync();
    } on FileSystemException {
      size = 0;
    }
    final archive = GameArchive(path: file, size: size);
    final parent = p.dirname(file);
    final inLibrary = folders.any((root) => p.equals(root, parent) || p.equals(root, p.dirname(parent)));
    final target = inLibrary ? archive.folder : p.join(folders.first, p.basenameWithoutExtension(file));
    ArchivePlan? plan;
    try {
      plan = await _planOf(file);
    } on Object catch (error) {
      debugPrint('[anyps5-launcher] ${archive.name} cannot be read: $error');
    }
    if (_disposed) return;
    if (plan == null) return app.show(T.text('ffpfscDamaged'));
    if (plan.problem == null && !plan.looksLikeGame && plan.refused.isEmpty) {
      return app.show(T.text('addGameFileNoGame'));
    }
    final UnpackAsk ask;
    if (plan.problem != null) {
      ask = UnpackAsk(archive, plan, into: target);
    } else if (_ask(archive, plan, folder: target) case final UnpackAsk found) {
      ask = found;
    } else if (FileSystemEntity.typeSync(target) != FileSystemEntityType.notFound) {
      return app.show(T.format('addGameFileThere', [p.basename(target)]));
    } else {
      return app.show(T.text('addGameFileHaveNewer'));
    }
    asked = ask;
    app.open(Layer.gameFiles);
  }

  /// Game Settings › Add Update: a folder is chosen and checked against [game].
  Future<void> addUpdate(Game game) async {
    if (working != null) return app.show(T.text('filesBusy'));
    final folder = await app.services.pickFolder?.call(T.text('addUpdateChoose'));
    if (folder == null) return;
    final (:update, :problem) = GameUpdates.check(folder, game);
    if (update == null) {
      return app.show(switch (problem) {
        UpdateProblem.otherGame => T.format('addUpdateOtherGame', [game.name]),
        UpdateProblem.notNewer => T.format('addUpdateNotNewer', [game.version]),
        UpdateProblem.haveNewer => T.format('addUpdateHaveNewer', [game.update?.shortVersion ?? '']),
        UpdateProblem.haveOlder => T.format('addUpdateHaveOlder', [p.basename(GameUpdates.target(game))]),
        _ => T.text('addUpdateNotADump'),
      });
    }
    final size = await _sizeOf(folder);
    if (_disposed) return;
    asked = UpdateAsk(update, game, size: size);
    app.open(Layer.gameFiles);
  }

  String get title => switch (working ?? asked) {
    UnpackAsk(updateOf: final Game game) => T.format('unpackUpdateTitle', [game.name]),
    UnpackAsk(:final archive) => T.text(archive.isFfpfsc ? 'unpackFileTitle' : 'unpackTitle'),
    UpdateAsk(:final game) => T.format('addUpdateTitle', [game.name]),
    null => '',
  };

  List<PanelRow> rows() {
    final job = working;
    if (job != null) {
      final percent = total == 0 ? 0 : (done * 100 ~/ total).clamp(0, 100);
      return [
        PanelRow(
          id: 'files-progress',
          title: T.format(job is UpdateAsk ? 'filesCopying' : 'filesUnpacking', [T.percent(percent)]),
          kind: InfoRow(
            '${T.format('filesProgress', [byteText(done), byteText(total)])}\n${T.text('filesKeepsGoing')}',
          ),
        ),
        PanelRow(id: 'files-stop', title: T.text('filesStop'), kind: ActionRow(stop, destructive: true)),
      ];
    }
    switch (asked) {
      case UnpackAsk(:final archive, :final plan, :final into, :final updateOf):
        final beside = p.equals(into, archive.folder);
        final about = updateOf != null
            ? T.format('unpackUpdateAbout', [_short(plan.version ?? ''), p.basename(into)])
            : T.format(beside ? 'unpackAbout' : 'unpackAboutFolder', [p.basename(into)]);
        if (plan.problem case final problem?) {
          return [
            PanelRow(
              id: 'files-about',
              title: archive.name,
              kind: InfoRow(T.text(problem == ArchiveProblem.compressed ? 'ffpfscCompressed' : 'ffpfscUnsupported')),
            ),
            PanelRow(id: 'files-later', title: T.text('close'), kind: ActionRow(later)),
          ];
        }
        if (plan.refused.isNotEmpty) {
          return [
            PanelRow(
              id: 'files-about',
              title: archive.name,
              kind: InfoRow(T.text(archive.isFfpfsc ? 'unpackFileUnsafe' : 'unpackUnsafe')),
            ),
            PanelRow(id: 'files-later', title: T.text('close'), kind: ActionRow(later)),
          ];
        }
        final free = app.freeSpace(p.dirname(into));
        final short = free != null && free < plan.size + GameArchives.spaceMargin;
        return [
          PanelRow(
            id: 'files-about',
            title: _head(archive, plan),
            picture: plan.icon,
            kind: InfoRow(
              short
                  ? '$about ${T.format('filesNoSpace', [byteText(plan.size), byteText(free)])}'
                  : '$about ${T.format('filesSpace', [byteText(plan.size)])}',
            ),
          ),
          if (!short) PanelRow(id: 'files-go', title: T.text('unpackGo'), kind: ActionRow(start)),
          PanelRow(id: 'files-later', title: T.text(short ? 'close' : 'filesLater'), kind: ActionRow(later)),
        ];
      case UpdateAsk(:final update, :final game, :final size):
        return [
          PanelRow(
            id: 'files-about',
            title: T.format('addUpdateVersion', [update.shortVersion]),
            kind: InfoRow(T.format('addUpdateAbout', [p.basename(GameUpdates.target(game)), byteText(size)])),
          ),
          PanelRow(id: 'files-go', title: T.text('addUpdateGo'), kind: ActionRow(start)),
          PanelRow(id: 'files-later', title: T.text('cancel'), kind: ActionRow(later)),
        ];
      case null:
        return const [];
    }
  }

  /// The panel's title for a game file: its game's name and title ID when they read, else the
  /// file's name.
  static String _head(GameArchive archive, ArchivePlan plan) {
    final name = plan.titleName;
    if (name == null) return archive.name;
    final titleId = plan.titleId;
    return titleId == null ? name : '$name ($titleId)';
  }

  static String _short(String version) => version.endsWith('.000') ? version.substring(0, version.length - 4) : version;

  /// Not now: the panel closes; a zip is offered again at the next start.
  void later() {
    if (asked case UnpackAsk(:final archive)) _later.add(archive.path);
    asked = null;
    if (app.overlay == Layer.gameFiles) app.closeOverlay();
    offerNext();
  }

  /// Back: the question is answered Not Now; a job goes on behind the home screen.
  void back() {
    if (working != null) {
      app.closeOverlay();
      app.show(T.text('filesKeepsGoing'));
      return;
    }
    later();
  }

  void stop() => _cancel?.cancel();

  /// The job asked about, in the background: progress in the panel, a word and a new scan when
  /// it is done.
  Future<void> start() async {
    final job = asked;
    if (job == null || working != null) return;
    final folder = switch (job) {
      UnpackAsk(:final into) => p.dirname(into),
      UpdateAsk(:final game) => p.dirname(game.folder),
    };
    final needed = switch (job) {
      UnpackAsk(:final plan) => plan.size,
      UpdateAsk(:final size) => size,
    };
    final free = app.freeSpace(folder);
    // A move needs no room; a copy or an unpack does, checked when it cannot be a move.
    if (job is UnpackAsk && free != null && free < needed + GameArchives.spaceMargin) {
      return app.show(T.format('filesNoSpace', [byteText(needed), byteText(free)]));
    }
    working = job;
    done = 0;
    total = needed;
    final cancel = _cancel = UnpackCancel(
      p.join(app.paths.config, '.files-stop-${DateTime.now().microsecondsSinceEpoch}'),
    );
    app.sounds.play(Cue.select);
    app.refresh();
    void progress(int bytes, int whole) {
      done = bytes;
      total = whole;
      app.refresh();
    }

    var moved = false;
    String? failure;
    try {
      switch (job) {
        case UnpackAsk(:final archive, :final into):
          await GameArchives.unpack(archive, into: into, progress: progress, cancel: cancel);
        case UpdateAsk(:final update, :final game):
          if (free != null && free < needed + GameArchives.spaceMargin && !_sameDrive(update.folder, game.folder)) {
            throw FileSystemException(T.format('filesNoSpace', [byteText(needed), byteText(free)]));
          }
          moved = await GameUpdates.install(update, game, progress: progress, cancel: cancel);
      }
    } on UnpackCancelled {
      failure = T.text('filesStopped');
    } on Object catch (error) {
      debugPrint('[anyps5-launcher] ${job is UnpackAsk ? job.archive.name : 'the update'} failed: $error');
      failure = switch (job) {
        UnpackAsk(:final archive) => T.format('unpackFailed', [archive.name]),
        UpdateAsk() => T.text('addUpdateFailed'),
      };
      if (error is FileSystemException && error.message.isNotEmpty && error.path == null) failure = error.message;
    }
    working = null;
    _cancel = null;
    if (_disposed) return;
    if (identical(asked, job)) asked = null;
    if (job is UnpackAsk) waiting.removeWhere((ask) => ask.archive == job.archive);
    if (app.overlay == Layer.gameFiles) app.closeOverlay();
    // The game (or its update) is read first: its own notice, then this word over it.
    app.rescan();
    if (failure != null) {
      app.show(failure);
    } else {
      final text = switch (job) {
        UnpackAsk(updateOf: final Game game) => T.format('unpackUpdateDone', [game.name]),
        UnpackAsk(:final archive) => T.format(archive.isFfpfsc ? 'unpackFileDone' : 'unpackDone', [archive.name]),
        UpdateAsk(:final game) => T.format(moved ? 'addUpdateMoved' : 'addUpdateCopied', [game.name]),
      };
      app.show(text);
      if (!app.active) app.desktopNotify(text, '');
    }
    offerNext();
  }

  /// Whether two folders are on the same drive, as far as a path tells (Windows' drive letters);
  /// elsewhere a move is tried first anyway.
  static bool _sameDrive(String a, String b) =>
      !Platform.isWindows || p.rootPrefix(a).toLowerCase() == p.rootPrefix(b).toLowerCase();
}
