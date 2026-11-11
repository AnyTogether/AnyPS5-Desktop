import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../core/engine_checkout.dart' show SystemCommands;
import '../core/game_deletion.dart';
import '../core/game_library.dart';
import '../core/host.dart';
import 'app_model.dart';
import 'strings.dart';

/// What the Delete game card ([Layer.confirmDeleteGame]) asks about.
class DeleteAsk {
  DeleteAsk(this.plan, {this.permanent = false});

  final DeletionPlan plan;

  /// Asked a second time: the files cannot go to the trash where they are, so this deletes them
  /// for good.
  final bool permanent;

  /// What the plan's items take on the disk, null while it is measured.
  int? size;

  Game get game => plan.game;
}

/// Game Settings › Delete game: the game itself off the disk, not only what the launcher built
/// from it (Uninstall). The game's own folder, its update, its add-ons and the archive it was
/// unpacked from go to the system's trash; the installation goes as Uninstall takes it; the saves
/// and trophies in it are kept in the store for the day the game is added again. The tile leaves
/// the library when the answer is given and comes back when the files could not go.
class GameDeleteModel {
  GameDeleteModel(this.app);

  final AppModel app;

  /// What the card asks, null while it is closed.
  DeleteAsk? ask;

  /// The games being deleted, by id: out of the library whatever a scan finds meanwhile.
  final Set<String> hidden = {};

  /// The deletions running, for the tests to wait on.
  final List<Future<void>> running = [];

  /// The games of a scan without the ones being deleted.
  List<Game> visible(List<Game> games) => hidden.isEmpty
      ? games
      : [
          for (final game in games)
            if (!hidden.contains(game.id)) game,
        ];

  Trash? get _trash =>
      app.services.trash ??
      (app.system == HostSystem.windows ? null : LinuxTrash(app.services.commands ?? const SystemCommands()));

  /// The trash as this system calls it.
  String get trashName => T.text(app.system == HostSystem.windows ? 'trashWindows' : 'trashLinux');

  /// Why [game] cannot be deleted now, null when it can: playing, being unlocked, or a file job
  /// (an unpack, an update being copied in) at work.
  String? blocked(Game game) => switch (app.stateOf(game)) {
    Installing() || Queued() => T.text('gameBusyUpdating'),
    WaitingForEngine() => T.text('gameBusyEngine'),
    Starting() || Running() || Stopping() => T.text('closeGameFirst'),
    _ => app.files.working != null ? T.text('filesBusy') : null,
  };

  /// Game Settings › Delete game: the card, or why not.
  void open(Game game) {
    final busy = blocked(game);
    if (busy != null) return app.show(busy);
    final DeletionPlan plan;
    try {
      plan = _plan(game);
    } on DeletionRefused catch (refused) {
      return app.show(refusalText(refused.reason));
    }
    _ask(DeleteAsk(plan));
  }

  DeletionPlan _plan(Game game) {
    final root = app.rootOf(game);
    if (root == null) throw const DeletionRefused(DeletionRefusal.linkedElsewhere);
    return GameDeletion.plan(game, root: root, roots: app.preferences.gamesFolders, games: app.games);
  }

  static String refusalText(DeletionRefusal reason) => T.text(switch (reason) {
    DeletionRefusal.libraryFolder => 'deleteGameRefusedFolder',
    DeletionRefusal.linkedElsewhere => 'deleteGameRefusedLink',
    DeletionRefusal.sharedFolder => 'deleteGameRefusedShared',
  });

  void _ask(DeleteAsk next) {
    ask = next;
    unawaited(
      _size(next.plan.items).then((bytes) {
        next.size = bytes;
        if (ask == next) app.refresh();
      }, onError: (Object _) {}),
    );
    // Cancel is where the focus starts.
    app.open(Layer.confirmDeleteGame);
  }

  /// What [items] take on the disk, measured away from the interface: a dump holds tens of
  /// thousands of files. One after the other, as the launcher measures a game's folder.
  Future<int> _size(List<String> items) async {
    final measure = app.services.folderSize;
    if (measure == null) return _measure(items);
    var total = 0;
    for (final item in items) {
      total += FileSystemEntity.isDirectorySync(item) ? await measure(item) : GameDeletion.size([item]);
    }
    return total;
  }

  /// Static, so the closure sent to the other isolate holds only the paths and not the model.
  static Future<int> _measure(List<String> items) => Isolate.run(() => GameDeletion.size(items));

  /// The names of what goes with the game's folder, as the card lists them.
  List<String> get extraNames => [for (final item in ask?.plan.extras ?? const <String>[]) p.basename(item)];

  /// Cancel, Back, or the card closed some other way.
  void cancel() {
    ask = null;
    app.closeOverlay();
  }

  /// The card's destructive answer. The game leaves the library at once; its files go after, off
  /// the interface's thread.
  void confirm() {
    final asked = ask;
    if (asked == null) return;
    ask = null;
    app.closeOverlay();
    final game = asked.game;
    // Started, or began unlocking, while the card was up.
    final busy = blocked(game);
    if (busy != null) return app.show(busy);
    // The library changed under the card (another games folder, a game copied into this one):
    // what may go is decided again.
    final DeletionPlan plan;
    try {
      plan = _plan(game);
    } on DeletionRefused catch (refused) {
      return app.show(refusalText(refused.reason));
    }
    hidden.add(game.id);
    app.hideGame(game);
    late final Future<void> job;
    job = _delete(plan, permanent: asked.permanent).whenComplete(() => running.remove(job));
    running.add(job);
  }

  Future<void> _delete(DeletionPlan plan, {required bool permanent}) async {
    final game = plan.game;
    DeletionOutcome outcome;
    try {
      outcome = await GameDeletion.run(plan, trash: _trash, permanent: permanent);
    } on Object catch (error) {
      outcome = DeletionFailed('$error');
    }
    if (app.disposed) return;
    switch (outcome) {
      case Deleted(:final left):
        // The installation goes as Uninstall takes it: the saves and trophies stay in the store,
        // and saves that cannot be moved keep the whole installation in place.
        unawaited(app.uninstall(game, root: plan.root, quiet: true));
        app.forgetGame(game);
        hidden.remove(game.id);
        app.rescan();
        app.show(
          left.isNotEmpty
              ? T.format('deleteGamePartly', [game.name, left.map(p.basename).join(', ')])
              : permanent
              ? T.format('deleteGameDoneForever', [game.name])
              : T.format('deleteGameDone', [game.name, trashName]),
        );
      case NeedsPermanent():
        _comeBack(game);
        // Asked again, Cancel first: this time nothing can be put back.
        final DeletionPlan again;
        try {
          again = _plan(game);
        } on DeletionRefused catch (refused) {
          return app.show(refusalText(refused.reason));
        }
        if (app.overlay == null) {
          _ask(DeleteAsk(again, permanent: true));
        } else {
          app.show(
            T.format('deleteGameFailed', [
              game.name,
              T.format('deleteGameNoTrash', [trashName]),
            ]),
          );
        }
      case DeletionFailed(:final message):
        _comeBack(game);
        app.show(T.format('deleteGameFailed', [game.name, message]));
    }
  }

  /// The files are still there: the tile comes back, selected as it was.
  void _comeBack(Game game) {
    hidden.remove(game.id);
    app.rescan();
    final index = app.games.indexWhere((other) => other.id == game.id);
    if (index >= 0 && app.overlay == null) app.select(index);
  }
}
