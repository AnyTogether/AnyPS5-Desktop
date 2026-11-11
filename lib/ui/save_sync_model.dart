import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../core/game_library.dart';
import '../core/host.dart';
import '../core/installer.dart';
import '../core/profiles/profiles.dart';
import '../core/save_sync.dart';
import '../core/together/account.dart';
import '../core/together/cloud_saves.dart';
import 'app_model.dart';
import 'strings.dart';
import 'together_model.dart' show launcherVersion;

/// A question the cloud asks the player (both sides changed, the quota is full): a title, a
/// line under it and the answers; Back gives the last one.
class CloudQuestion<A> {
  CloudQuestion({required this.title, required this.detail, required this.answers});

  final String title;
  final String detail;
  final List<(String, A)> answers;
  final Completer<A> _answer = Completer<A>();

  Future<A> get answer => _answer.future;

  void choose(int index) {
    if (!_answer.isCompleted) _answer.complete(answers[index.clamp(0, answers.length - 1)].$2);
  }
}

/// Save Sync and cloud saves, the launcher's side: each game's saves and trophies brought in step
/// before it starts and after it ends, through a folder other computers see (SaveSync) or the
/// player's AnyTogether cloud (TogetherCloudSave); the questions the cloud asks; Settings ›
/// Behaviour's rows and Settings › Cloud Storage (every game's saves, restore, delete). The
/// macOS launcher's CloudStorage.swift and its Save Sync, with its settings keys.
class SaveSyncModel {
  SaveSyncModel(this.app) {
    app.together.account.addListener(_accountChanged);
  }

  final AppModel app;

  static const syncThroughTogether = 'together';

  /// The game whose saves are being synced, so it does not start twice meanwhile and the
  /// profile does not change under it.
  String? syncing;

  /// What the server said of storage; null until asked (or unreachable): the cloud rows hide.
  StorageInfo? info;

  /// Settings › Cloud Storage: what the server has, whether reading it failed, the version whose
  /// Restore and Delete show, a delete row pressed once (the next press deletes), and something
  /// going up or down.
  StorageOverview? overview;
  bool failed = false;
  String? expanded;
  String? armed;
  bool working = false;

  /// The question asked now (Layer.cloudQuestion), and the layer it came over.
  CloudQuestion<Object?>? question;
  Layer? _questionFrom;

  late final CloudStorage storage = CloudStorage(app.together.account);
  String? _signedInAs;

  Preferences get _preferences => app.preferences;

  bool get on => _preferences.saveSync == true;

  /// Signed in to a server that keeps files.
  bool get cloudAvailable => app.together.signedIn && info?.enabled == true;

  /// Save Sync goes through the AnyTogether cloud (and it can now).
  bool get throughCloud => on && _preferences.syncThrough == syncThroughTogether && cloudAvailable;

  /// The sync folder: the one chosen, else iCloud Drive where iCloud for Windows set it up.
  String? get syncRoot =>
      _preferences.syncFolder ??
      SaveSync.iCloudDrive(app.services.environment ?? Platform.environment, windows: app.system == HostSystem.windows);

  /// Save Sync's folder of a profile after the first.
  String? get profileFolder {
    final book = app.profiles.book;
    final id = book.currentProfile?.id;
    if (id == null || id == (book.legacyOwner ?? LauncherProfile.legacyId)) return null;
    return id;
  }

  String get device => app.services.computerName ?? Platform.localHostname;

  void _accountChanged() {
    final id = app.together.user?.id;
    if (id == _signedInAs) return;
    _signedInAs = id;
    overview = null;
    if (id != null) unawaited(refreshInfo());
  }

  /// Asks the server whether it keeps files: at sign-in and at start.
  Future<void> refreshInfo() async {
    try {
      info = await storage.info();
      app.refresh();
    } on Object {
      // Unreachable now: what was known stays.
    }
  }

  // Syncing.

  SaveSync? _folderSync(Game game) {
    final root = syncRoot;
    final folder = app.rootOf(game);
    if (!on || root == null || folder == null) return null;
    final profile = profileFolder;
    return SaveSync(
      game: Installer.installedFolder(game, folder),
      cloud: SaveSync.folder(root, game.titleId, profile: profile),
      backups: app.backupFolder(game),
      device: device,
      profile: profile,
    );
  }

  TogetherCloudSave? cloudSave(Game game) {
    final user = app.together.user;
    final folder = app.rootOf(game);
    if (!throughCloud || user == null || folder == null) return null;
    return TogetherCloudSave(
      storage: storage,
      game: Installer.installedFolder(game, folder),
      titleId: game.titleId,
      backups: app.backupFolder(game),
      workspace: TogetherCloudSave.workspaceFor(p.join(app.paths.config, 'Together', 'CloudSaves'), user.id),
      device: device,
      launcherVersion: launcherVersion,
      conflict: (latest) => _askConflict(game, latest),
      replaceLatest: (latest) => _askReplace(game, latest),
    );
  }

  /// Syncs [game]'s saves (before it starts, after it ends) and says what came from elsewhere.
  /// A failure is said and never stops a game.
  Future<void> sync(Game game) async {
    if (!on || syncing != null) return;
    if (_preferences.syncThrough == syncThroughTogether) {
      // Through the cloud; signed out or a server without files, nothing syncs.
      final cloud = cloudSave(game);
      if (cloud == null) return;
      return _syncThroughCloud(cloud, game);
    }
    final folder = _folderSync(game);
    if (folder == null) return;
    syncing = game.id;
    app.refresh();
    try {
      final outcome = await Isolate.run(() => folder.sync(DateTime.now()));
      if (outcome case SyncDownloaded(:final from)) app.show(T.format('savesSyncedFrom', [from]));
    } on Object catch (error) {
      app.show('${T.text('saveSyncFailed')}: ${_message(error)}');
    } finally {
      syncing = null;
      app.refresh();
    }
  }

  Future<void> _syncThroughCloud(TogetherCloudSave cloud, Game game) async {
    syncing = game.id;
    app.refresh();
    try {
      final outcome = await cloud.sync();
      switch (outcome) {
        case CloudDownloaded(:final from):
          app.show(T.format('cloudSavesDownloaded', [from ?? T.text('cloudConflictCloudUnknown')]));
        case CloudUploaded() when app.running == null:
          app.show(T.text('cloudSavesUploaded'));
        default:
          break;
      }
      if (app.overlay == Layer.cloudStorage) unawaited(load());
    } on Object catch (error) {
      app.show('${T.text('saveSyncFailed')}: ${_message(error)}');
    } finally {
      syncing = null;
      app.refresh();
    }
  }

  /// A storage refusal in words.
  String _message(Object error) {
    if (error is SaveSyncFailure) return error.description;
    if (error is TogetherProblem) {
      switch (error.code) {
        case 'quota_exceeded':
          return T.text('cloudQuotaFull');
        case 'payload_too_large':
          return T.text('cloudTooBig');
        case 'storage_disabled':
          info = StorageInfo.disabled;
          return T.text('cloudOff');
      }
      // Any other code: the launcher's words for it, never the server's English.
      return app.together.message(error);
    }
    if (error is IOException) return T.text('togetherUnreachable');
    return '$error';
  }

  // Questions.

  Future<R> _ask<R>(CloudQuestion<R> asked) async {
    // One at a time: a second waits for the first.
    while (question != null) {
      await question!.answer;
    }
    question = asked as CloudQuestion<Object?>;
    _questionFrom = app.overlay;
    app.open(Layer.cloudQuestion);
    // On the first answer, below the line that explains.
    app.panelRow = 1;
    try {
      return await asked.answer;
    } finally {
      question = null;
      if (app.overlay == Layer.cloudQuestion) {
        final back = _questionFrom;
        back == null ? app.closeOverlay() : app.open(back);
      }
    }
  }

  /// The player's answer: a row pressed, or Back for the last one.
  void answer(int index) => question?.choose(index);
  void answerBack() => question?.choose(question!.answers.length - 1);

  String _when(SaveVersion? version) {
    final date = version?.createdAt?.toLocal();
    if (date == null) return '—';
    String two(int value) => value.toString().padLeft(2, '0');
    return '${date.year}-${two(date.month)}-${two(date.day)} ${two(date.hour)}:${two(date.minute)}';
  }

  Future<ConflictChoice> _askConflict(Game game, SaveVersion? latest) => _ask(
    CloudQuestion<ConflictChoice>(
      title: T.text('cloudConflictTitle'),
      detail: T.format('cloudConflictDetail', [
        game.name,
        latest?.device ?? T.text('cloudConflictCloudUnknown'),
        _when(latest),
      ]),
      answers: [
        (T.text('cloudConflictTakeCloud'), ConflictChoice.takeCloud),
        (T.text('cloudConflictKeepMine'), ConflictChoice.keepThisComputer),
        (T.text('cloudNotNow'), ConflictChoice.notNow),
      ],
    ),
  );

  Future<bool> _askReplace(Game game, SaveVersion? latest) => _ask(
    CloudQuestion<bool>(
      title: T.text('cloudQuotaTitle'),
      detail: T.format('cloudQuotaReplaceDetail', [game.name, _when(latest)]),
      answers: [(T.text('cloudReplace'), true), (T.text('cancel'), false)],
    ),
  );

  List<PanelRow> questionRows() {
    final asked = question;
    if (asked == null) return const [];
    return [
      PanelRow(id: 'cloudQuestionDetail', title: '', detail: asked.detail, kind: const InfoRow('')),
      for (final (index, (label, _)) in asked.answers.indexed)
        PanelRow(id: 'cloudAnswer$index', title: label, kind: ActionRow(() => answer(index))),
    ];
  }

  // Settings › Behaviour.

  Future<void> chooseFolder() async {
    final folder = await app.services.pickFolder?.call(T.text('syncFolder'));
    if (folder == null) return;
    _preferences
      ..syncFolder = folder
      ..saveSync = true;
    app.savePreferences();
    app.refresh();
  }

  List<PanelRow> settingsRows() {
    final through = _preferences.syncThrough == syncThroughTogether && cloudAvailable;
    final root = syncRoot;
    return [
      PanelRow(
        id: 'saveSync',
        title: T.text('saveSync'),
        detail: through
            ? T.text('cloudSaveSyncTogetherDetail')
            : root == null
            ? T.text('saveSyncNoFolder')
            : T.format('saveSyncDetail', [root]),
        kind: ToggleRow(on && (through || root != null), (value) {
          if (value && !through && root == null) {
            unawaited(chooseFolder());
            return;
          }
          _preferences.saveSync = value;
          app.savePreferences();
          app.refresh();
        }),
      ),
      if (cloudAvailable)
        PanelRow(
          id: 'syncThrough',
          title: T.text('cloudSyncThrough'),
          kind: ChoiceRow([T.text('cloudSyncThroughFolder'), T.text('cloudSyncThroughTogether')], through ? 1 : 0, (
            index,
          ) {
            _preferences.syncThrough = index == 1 ? syncThroughTogether : null;
            app.savePreferences();
            app.refresh();
          }),
        ),
      if (through)
        PanelRow(
          id: 'cloudStorage',
          title: T.text('cloudStorageTitle'),
          detail: usageText ?? T.text('cloudStorageSubtitle'),
          kind: ActionRow(openStorage),
        )
      else
        PanelRow(
          id: 'syncFolder',
          title: T.text('syncFolder'),
          detail: _preferences.syncFolder ?? (root != null ? T.text('syncFolderICloud') : T.text('syncFolderNone')),
          kind: ActionRow(() => unawaited(chooseFolder())),
        ),
    ];
  }

  // Settings › Cloud Storage.

  void openStorage() {
    if (!app.together.signedIn) return;
    armed = null;
    expanded = null;
    app.open(Layer.cloudStorage);
    unawaited(load());
  }

  Future<void> load() async {
    try {
      final read = await storage.overview();
      overview = read;
      failed = false;
      if (!read.enabled) info = StorageInfo.disabled;
    } on Object {
      failed = true;
    }
    app.refresh();
  }

  static String size(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1000 && unit < units.length - 1) {
      value /= 1000;
      unit++;
    }
    return unit == 0 ? '$bytes B' : '${T.decimal(value, value < 10 ? 1 : 0)} ${units[unit]}';
  }

  /// "42 MB of 100 MB used".
  String? get usageText {
    final usage = overview?.usage;
    if (usage == null) return null;
    return T.format('cloudStorageUsed', [size(usage.used), size(usage.limit)]);
  }

  String gameTitle(SaveSlot slot) =>
      app.games.where((game) => game.titleId == slot.titleId).firstOrNull?.name ?? slot.game ?? slot.titleId;

  List<PanelRow> storageRows() {
    final read = overview;
    if (read == null) {
      return [
        PanelRow(
          id: 'cloud-state',
          title: T.text(failed ? 'cloudStorageFailed' : 'cloudStorageLoading'),
          kind: const InfoRow(''),
        ),
      ];
    }
    if (!read.enabled) {
      return [PanelRow(id: 'cloud-off', title: T.text('cloudStorageOff'), kind: const InfoRow(''))];
    }
    final rows = <PanelRow>[
      if (usageText case final String used)
        PanelRow(
          id: 'cloud-usage',
          title: used,
          detail: read.usage == null
              ? null
              : T.format('cloudStorageUsageLine', [
                  size(read.usage!.saves),
                  size(read.usage!.media),
                  size(read.usage!.free),
                ]),
          meter: read.usage == null || read.usage!.limit <= 0
              ? null
              : PanelMeter(read.usage!.saves / read.usage!.limit, read.usage!.media / read.usage!.limit),
          kind: const InfoRow(''),
        ),
      PanelRow(id: 'cloud-saves', title: T.text('cloudStorageSaves'), kind: const InfoRow('')),
      if (read.saves.isEmpty)
        PanelRow(id: 'cloud-nosaves', title: T.text('cloudStorageNoSaves'), kind: const InfoRow('')),
    ];
    for (final slot in read.saves) {
      rows.add(
        PanelRow(
          id: 'slot-${slot.id}',
          title: gameTitle(slot),
          detail: T.format('cloudStorageGameLine', [slot.versions.length, size(slot.size)]),
          kind: const InfoRow(''),
        ),
      );
      for (final (index, version) in slot.versions.indexed) {
        final open = expanded == version.id;
        rows.add(
          PanelRow(
            id: 'version-${version.id}',
            title: index == 0
                ? T.format('cloudStorageVersionNewest', [version.version])
                : T.format('cloudStorageVersion', [version.version]),
            detail: T.format('cloudStorageVersionLine', [
              _when(version),
              version.device ?? T.text('cloudConflictCloudUnknown'),
              size(version.size),
            ]),
            kind: ActionRow(() {
              expanded = open ? null : version.id;
              armed = null;
              app.refresh();
            }),
          ),
        );
        if (!open) continue;
        if (index > 0) {
          rows.add(
            PanelRow(
              id: 'restore-${version.id}',
              title: T.text('cloudStorageRestore'),
              detail: T.text('cloudStorageRestoreDetail'),
              kind: ActionRow(() => unawaited(restore(version, slot))),
            ),
          );
        }
        final armedHere = armed == 'delete-${version.id}';
        rows.add(
          PanelRow(
            id: 'delete-${version.id}',
            title: T.text('cloudStorageDelete'),
            detail: armedHere ? T.text('cloudStoragePressAgain') : null,
            kind: ActionRow(() {
              if (armedHere) {
                unawaited(deleteVersion(version, slot));
              } else {
                armed = 'delete-${version.id}';
                app.refresh();
              }
            }, destructive: true),
          ),
        );
      }
      final armedSlot = armed == 'deleteslot-${slot.id}';
      rows.add(
        PanelRow(
          id: 'deleteslot-${slot.id}',
          title: T.text('cloudStorageDeleteGame'),
          detail: armedSlot ? T.text('cloudStoragePressAgain') : null,
          kind: ActionRow(() {
            if (armedSlot) {
              unawaited(deleteSlot(slot));
            } else {
              armed = 'deleteslot-${slot.id}';
              app.refresh();
            }
          }, destructive: true),
        ),
      );
    }
    rows.add(PanelRow(id: 'cloud-media', title: T.text('cloudStorageMediaTitle'), kind: const InfoRow('')));
    if (read.media.isEmpty) {
      rows.add(PanelRow(id: 'cloud-nomedia', title: T.text('cloudStorageNoMedia'), kind: const InfoRow('')));
    }
    for (final media in read.media) {
      final armedHere = armed == 'media-${media.id}';
      rows.add(
        PanelRow(
          id: 'media-${media.id}',
          title: media.kind == 'clip'
              ? T.text('messagesClip')
              : media.kind == 'voice'
              ? T.text('messagesVoice')
              : T.text('messagesPhoto'),
          detail: armedHere
              ? T.text('cloudStoragePressAgain')
              : [
                  if (media.createdAt != null) _day(media.createdAt!),
                  size(media.size),
                  if (media.gallery != null) T.text('cloudStoragePinned'),
                ].join(' · '),
          kind: ActionRow(() {
            if (armedHere) {
              unawaited(deleteMedia(media));
            } else {
              armed = 'media-${media.id}';
              app.refresh();
            }
          }, destructive: armedHere),
        ),
      );
    }
    return rows;
  }

  /// "2026-11-08 20:14", the moment as the save versions show theirs.
  String _day(DateTime date) {
    final local = date.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
  }

  /// Deletes one photo, clip or voice note; its place in storage comes back.
  Future<void> deleteMedia(StoredMedia media) async {
    try {
      await storage.deleteMedia(media.id);
      armed = null;
      app.show(T.text('cloudStorageDeleted'));
      await load();
    } on Object catch (error) {
      app.show(_message(error));
    }
  }

  /// An older version becomes the newest again and comes down to this computer when it has the
  /// game.
  Future<void> restore(SaveVersion version, SaveSlot slot) async {
    if (working) return;
    final game = app.games.where((game) => game.titleId == slot.titleId).firstOrNull;
    if (game != null && (app.running?.$1 == game || app.starting == game)) {
      return app.show(T.text('cloudStorageRunning'));
    }
    working = true;
    try {
      final made = await storage.restore(version.id);
      expanded = null;
      final cloud = game == null || slot.slot != TogetherCloudSave.slot ? null : cloudSave(game);
      if (cloud != null) {
        await cloud.takeCloud();
        app.show(T.format('cloudStorageRestoredHere', [version.version]));
      } else {
        app.show(T.format('cloudStorageRestored', [made.version]));
      }
      await load();
    } on Object catch (error) {
      app.show(_message(error));
    } finally {
      working = false;
    }
  }

  Future<void> deleteVersion(SaveVersion version, SaveSlot slot) async {
    try {
      await storage.deleteVersion(version.id);
      armed = null;
      expanded = null;
      if (slot.versions.length == 1) _forget(slot);
      app.show(T.text('cloudStorageDeleted'));
      await load();
    } on Object catch (error) {
      app.show(_message(error));
    }
  }

  Future<void> deleteSlot(SaveSlot slot) async {
    try {
      await storage.deleteSlot(slot.id);
      armed = null;
      _forget(slot);
      app.show(T.text('cloudStorageDeleted'));
      await load();
    } on Object catch (error) {
      app.show(_message(error));
    }
  }

  /// This computer forgets what it had of a slot that is gone: its saves go up afresh next time.
  void _forget(SaveSlot slot) {
    final user = app.together.user;
    if (user == null) return;
    final workspace = TogetherCloudSave.workspaceFor(p.join(app.paths.config, 'Together', 'CloudSaves'), user.id);
    try {
      final file = File(p.join(workspace, '${slot.titleId}.json'));
      if (file.existsSync()) file.deleteSync();
    } on FileSystemException {
      // Asked again next time.
    }
  }

  /// Back to Settings, on the row that opened it.
  void backFromStorage() {
    app.open(Layer.settings);
    final categories = app.panelCategories();
    for (final (index, category) in categories.indexed) {
      final row = category.rows.indexWhere((row) => row.id == 'cloudStorage');
      if (row >= 0) {
        app.panelCategory = index;
        app.panelRow = row;
        app.refresh();
        return;
      }
    }
  }

  void dispose() {
    app.together.account.removeListener(_accountChanged);
    storage.close();
  }
}
