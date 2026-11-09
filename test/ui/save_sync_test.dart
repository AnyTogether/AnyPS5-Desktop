import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/installer.dart';
import 'package:anyps5_desktop/core/profiles/profiles.dart';
import 'package:anyps5_desktop/core/save_backup.dart';
import 'package:anyps5_desktop/core/save_sync.dart';
import 'package:anyps5_desktop/core/together/token_store.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/save_sync_model.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_cloud.dart';
import '../support/fake_process.dart';
import '../support/ui_support.dart';

/// Settings › Behaviour › Save Sync through a folder or the AnyTogether cloud: the saves brought
/// in step before a game starts and after it ends, the question when both sides changed, the
/// profile kept while it syncs, and Settings › Cloud Storage.
void main() {
  Future<void> until(bool Function() condition, {String? reason}) async {
    for (var tries = 0; tries < 2000 && !condition(); tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(condition(), isTrue, reason: reason);
  }

  Game orbit(AppModel model) => model.games.firstWhere((game) => game.titleId == 'PPSA01001');
  String installed(AppModel model) => Installer.installedFolder(orbit(model), model.rootOf(orbit(model))!);

  void save(String folder, String text) {
    final file = File(p.join(folder, '_sd', 'savedata0', 'save.dat'));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(text);
  }

  String? read(String folder) {
    try {
      return File(p.join(folder, '_sd', 'savedata0', 'save.dat')).readAsStringSync();
    } on FileSystemException {
      return null;
    }
  }

  /// The saves zip another computer would upload, holding [text].
  List<int> zipOf(Directory temp, String text) {
    final folder = p.join(temp.path, 'zip-${text.hashCode}');
    save(folder, text);
    return File(SaveBackup.backUp(folder, p.join(folder, 'out'), DateTime(2026, 11, 1))).readAsBytesSync();
  }

  PanelRow? rowIn(AppModel model, String id) =>
      model.panelCategories().expand((category) => category.rows).where((row) => row.id == id).firstOrNull;

  void openBehaviour(AppModel model) {
    model.open(Layer.settings);
    model.panelCategory = model.panelCategories().indexWhere((category) => category.id == 'general');
  }

  group('through a folder', () {
    late Fixture fixture;
    late AppModel model;
    late String sync;
    late FakeGameStarts starts;

    setUp(() {
      fixture = makeFixture(pickFolder: (_) async => sync);
      model = fixture.model;
      sync = p.join(fixture.temp.path, 'OneDrive');
      Directory(sync).createSync();
      starts = FakeGameStarts();
      model.startGame = starts.call;
    });

    tearDown(() {
      model.dispose();
      fixture.dispose();
    });

    test('Save Sync asks for a folder first, then is on; the folder is the Mac\'s key', () async {
      openBehaviour(model);
      final row = rowIn(model, 'saveSync')!;
      expect((row.kind as ToggleRow).value, isFalse);
      expect(row.detail, T.text('saveSyncNoFolder'));
      expect(rowIn(model, 'syncFolder')!.detail, T.text('syncFolderNone'));
      expect(rowIn(model, 'syncThrough'), isNull, reason: 'signed out: no cloud to choose');
      (row.kind as ToggleRow).set(true);
      await until(() => model.preferences.saveSync == true);
      expect(model.preferences.syncFolder, sync);
      expect((rowIn(model, 'saveSync')!.kind as ToggleRow).value, isTrue);
      expect(rowIn(model, 'saveSync')!.detail, T.format('saveSyncDetail', [sync]));
      final json = model.preferences.toJson();
      expect(json['saveSync'], isTrue);
      expect(json['syncFolder'], sync);
      expect(Preferences.fromJson(json).syncFolder, sync);
    });

    test('before a game starts the other computer\'s saves come over; after it ends its own go up', () async {
      model.preferences
        ..saveSync = true
        ..syncFolder = sync;
      // A computer that has not played yet (the fixture's trophies taken away), and another that
      // put its saves in the folder.
      Directory(p.join(installed(model), '_trophy')).deleteSync(recursive: true);
      final other = p.join(fixture.temp.path, 'Other', 'game');
      save(other, 'from the laptop');
      SaveSync(
        game: other,
        cloud: SaveSync.folder(sync, 'PPSA01001'),
        backups: p.join(fixture.temp.path, 'Other', 'Backups'),
        device: 'Laptop',
      ).sync(DateTime.now());
      model.primaryAction(orbit(model));
      await until(() => model.running != null, reason: 'the game starts after the sync');
      expect(read(installed(model)), 'from the laptop');
      expect(model.toast, T.format('savesSyncedFrom', ['Laptop']));
      // Played here: the saves change, the game ends, they go up.
      save(installed(model), 'played on the desk');
      starts.last.quit();
      await until(() => model.running == null);
      await until(() => model.saveSync.syncing == null);
      final info = jsonDecode(
        File(p.join(SaveSync.folder(sync, 'PPSA01001'), 'info.json')).readAsStringSync(),
      ) as Map<String, dynamic>;
      expect(info['mac'], 'Desk');
    });

    test('while saves sync the profile does not change and the game does not start twice', () {
      model.saveSync.syncing = orbit(model).id;
      final other = model.profiles.add(name: 'Second', mode: ProfileMode.offline);
      expect(model.switchRefusal(other.id), ProfileRefusal.syncing);
      model.primaryAction(orbit(model));
      expect(model.starting, isNull);
      model.saveSync.syncing = null;
      expect(model.switchRefusal(other.id), isNot(ProfileRefusal.syncing));
    });
  });

  group('through AnyTogether', () {
    late FakeCloud cloud;
    late Fixture fixture;
    late AppModel model;

    setUp(() async {
      cloud = await FakeCloud.start();
      fixture = makeFixture(
        together: cloud.base,
        togetherStore: MemoryTokenStore(
          SavedSession(
            accessToken: 'access',
            accessExpiry: DateTime.now().add(const Duration(hours: 1)),
            refreshToken: 'refresh',
            user: const TogetherUser(id: 'u1', handle: 'utku', displayName: 'Utku'),
          ),
        ),
      );
      model = fixture.model;
      model.saveSync;
      await model.together.account.restore();
      await until(() => model.saveSync.info != null, reason: 'the server is asked whether it keeps files');
      model.preferences
        ..saveSync = true
        ..syncThrough = 'together';
    });

    tearDown(() async {
      model.dispose();
      fixture.dispose();
      await cloud.close();
    });

    test('signed in to a server with storage: Sync Through and Cloud Storage show', () {
      openBehaviour(model);
      expect((rowIn(model, 'syncThrough')!.kind as ChoiceRow).selected, 1);
      expect(rowIn(model, 'saveSync')!.detail, T.text('cloudSaveSyncTogetherDetail'));
      expect(rowIn(model, 'cloudStorage'), isNotNull);
      expect(rowIn(model, 'syncFolder'), isNull);
      (rowIn(model, 'syncThrough')!.kind as ChoiceRow).set(0);
      expect(model.preferences.syncThrough, isNull);
      expect(rowIn(model, 'syncFolder'), isNotNull);
    });

    test('a server that keeps no files: no cloud rows, and nothing syncs', () async {
      cloud.enabled = false;
      await model.saveSync.refreshInfo();
      openBehaviour(model);
      expect(rowIn(model, 'syncThrough'), isNull);
      expect(rowIn(model, 'cloudStorage'), isNull);
      await model.saveSync.sync(orbit(model));
      expect(cloud.beginBodies, isEmpty);
    });

    test('the first sync uploads; both sides changed asks, and Take the Newer One brings it down', () async {
      save(installed(model), 'desk level 1');
      await model.saveSync.sync(orbit(model));
      expect(cloud.slots.single.versions.single.device, 'Desk');
      expect(model.toast, T.text('cloudSavesUploaded'));
      // A laptop uploads, and this computer plays on too.
      cloud.put(zipOf(fixture.temp, 'laptop'), device: 'Laptop');
      save(installed(model), 'desk level 2');
      final syncing = model.saveSync.sync(orbit(model));
      await until(() => model.overlay == Layer.cloudQuestion);
      final category = model.panelCategories().single;
      expect(category.title, T.text('cloudConflictTitle'));
      expect(category.rows.first.detail, contains('Laptop'));
      expect(category.rows.skip(1).map((row) => row.title), [
        T.text('cloudConflictTakeCloud'),
        T.text('cloudConflictKeepMine'),
        T.text('cloudNotNow'),
      ]);
      expect(model.panelRow, 1, reason: 'on the first answer');
      (category.rows[1].kind as ActionRow).run();
      await syncing;
      expect(model.overlay, isNull);
      expect(model.toast, T.format('cloudSavesDownloaded', ['Laptop']));
      expect(read(installed(model)), 'laptop');
    });

    test('Back answers Not Now and leaves both as they are', () async {
      save(installed(model), 'desk level 1');
      await model.saveSync.sync(orbit(model));
      cloud.put(zipOf(fixture.temp, 'laptop'), device: 'Laptop');
      save(installed(model), 'desk level 2');
      final syncing = model.saveSync.sync(orbit(model));
      await until(() => model.overlay == Layer.cloudQuestion);
      model.command(Command.back);
      await syncing;
      expect(read(installed(model)), 'desk level 2');
      expect(cloud.slots.single.versions, hasLength(2));
    });

    test('Cloud Storage lists the media with its usage, and a press twice deletes one', () async {
      cloud.media.addAll([
        {'id': 'm1', 'kind': 'clip', 'size': 4000, 'createdAt': '2026-11-08T20:14:00Z', 'gallery': 0},
        {'id': 'm2', 'kind': 'image', 'size': 2500},
        {'id': 'm3', 'kind': 'voice', 'size': 900},
      ]);
      openBehaviour(model);
      (rowIn(model, 'cloudStorage')!.kind as ActionRow).run();
      await until(() => model.saveSync.overview != null);
      expect(rowIn(model, 'cloud-media')!.title, T.text('cloudStorageMediaTitle'));
      expect(rowIn(model, 'cloud-nomedia'), isNull);
      expect(rowIn(model, 'media-m1')!.title, 'Clip');
      expect(rowIn(model, 'media-m1')!.detail, contains('In your gallery'));
      expect(rowIn(model, 'media-m2')!.title, 'Photo');
      expect(rowIn(model, 'media-m3')!.title, 'Voice note');
      final usage = rowIn(model, 'cloud-usage')!;
      expect(
        usage.detail,
        'Saves ${SaveSyncModel.size(cloud.usage['saves'] as int)}, media ${SaveSyncModel.size(cloud.usage['media'] as int)}, free ${SaveSyncModel.size((cloud.usage['limit'] as int) - (cloud.usage['used'] as int))}',
      );
      expect(usage.meter, isNotNull);
      (rowIn(model, 'media-m2')!.kind as ActionRow).run();
      expect(rowIn(model, 'media-m2')!.detail, T.text('cloudStoragePressAgain'));
      expect(cloud.media, hasLength(3), reason: 'asked first');
      (rowIn(model, 'media-m2')!.kind as ActionRow).run();
      await until(() => cloud.media.length == 2);
      await until(() => rowIn(model, 'media-m2') == null, reason: 'the list is read again');
      expect(model.toast, T.text('cloudStorageDeleted'));
    });

    test('Cloud Storage without media says so', () async {
      openBehaviour(model);
      (rowIn(model, 'cloudStorage')!.kind as ActionRow).run();
      await until(() => model.saveSync.overview != null);
      expect(rowIn(model, 'cloud-nomedia')!.title, T.text('cloudStorageNoMedia'));
    });

    test('Cloud Storage lists the saves; Restore brings an older one down; Delete asks twice', () async {
      save(installed(model), 'level 1');
      await model.saveSync.sync(orbit(model));
      save(installed(model), 'level 2');
      await model.saveSync.sync(orbit(model));
      openBehaviour(model);
      (rowIn(model, 'cloudStorage')!.kind as ActionRow).run();
      expect(model.overlay, Layer.cloudStorage);
      await until(() => model.saveSync.overview != null);
      final versions = model.panelCategories().single.rows.where((row) => row.id.startsWith('version-')).toList();
      expect(versions.map((row) => row.title), ['Version 2, the newest', 'Version 1']);
      expect(rowIn(model, 'slot-${cloud.slots.single.id}')!.title, 'Orbit Runner');
      expect(rowIn(model, 'cloud-usage')!.title, contains('of'));
      (versions[1].kind as ActionRow).run();
      final older = cloud.slots.single.versions.last;
      (rowIn(model, 'restore-${older.id}')!.kind as ActionRow).run();
      await until(() => read(installed(model)) == 'level 1');
      expect(model.toast, T.format('cloudStorageRestoredHere', [1]));
      final newest = cloud.slots.single.versions.first;
      await until(() => rowIn(model, 'version-${newest.id}') != null, reason: 'the list is read again');
      (rowIn(model, 'version-${newest.id}')!.kind as ActionRow).run();
      (rowIn(model, 'delete-${newest.id}')!.kind as ActionRow).run();
      expect(rowIn(model, 'delete-${newest.id}')!.detail, T.text('cloudStoragePressAgain'));
      expect(cloud.slots.single.versions, hasLength(3));
      (rowIn(model, 'delete-${newest.id}')!.kind as ActionRow).run();
      await until(() => cloud.slots.single.versions.length == 2);
      model.command(Command.back);
      expect(model.overlay, Layer.settings);
      expect(model.panelCategories()[model.panelCategory].rows[model.panelRow].id, 'cloudStorage');
    });
  });
}
