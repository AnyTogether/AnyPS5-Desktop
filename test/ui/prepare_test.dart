import 'dart:io';

import 'package:anyps5_desktop/core/file_links.dart';
import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/installer.dart';
import 'package:anyps5_desktop/core/power.dart';
import 'package:anyps5_desktop/core/prepare_queue.dart';
import 'package:anyps5_desktop/core/unlock_space.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/launcher.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_toolkit.dart';
import '../support/fixtures.dart';
import '../support/self_builder.dart';
import '../support/ui_support.dart';

/// The free-space check before an unlock (merged with the copy panel) and new games prepared in
/// the background: the setting, the queue's states as the launcher shows them, the notices.
void main() {
  late Fixture fixture;
  late AppModel model;

  tearDown(() {
    T.language = Language.english;
    FileLinks.calls = FileLinks.system;
    model.dispose();
    fixture.dispose();
  });

  Future<void> until(bool Function() condition) async {
    for (var tries = 0; tries < 500 && !condition(); tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(condition(), isTrue);
  }

  Game named(String titleId) => model.games.firstWhere((game) => game.titleId == titleId);
  List<String> rowIds() => model.panelCategories().single.rows.map((row) => row.id).toList();
  PanelRow row(String id) => model.panelCategories().single.rows.firstWhere((row) => row.id == id);

  /// A whole dump copied into the games folder, then the scan that finds it.
  Game copyIn(String name, String titleId) {
    final folder = makeDump(model.root!, name, titleId: titleId, names: {'en-US': name});
    File(p.join(folder, 'eboot.bin')).writeAsBytesSync(typicalSelf());
    model.rescan();
    return named(titleId);
  }

  group('settings', () {
    setUp(() {
      fixture = makeFixture();
      model = fixture.model;
    });

    test('on unless turned off, and kept', () {
      expect(Preferences().prepareNewGames, isTrue);
      expect(Preferences.fromJson(const {}).prepareNewGames, isTrue, reason: 'a file from before has none');
      final off = Preferences()..prepareNewGames = false;
      expect(Preferences.fromJson(off.toJson()).prepareNewGames, isFalse);
      final file = p.join(fixture.temp.path, 'preferences.json');
      off.save(file);
      expect(Preferences.load(file).prepareNewGames, isFalse);
    });

    test('Settings › Game library has the switch', () {
      model.open(Layer.settings);
      final library = model.panelCategories().firstWhere((category) => category.id == 'library');
      final toggle = library.rows.firstWhere((row) => row.id == 'prepareNewGames');
      expect(toggle.title, 'Prepare new games automatically');
      (toggle.kind as ToggleRow).set(true);
      expect(model.preferences.prepareNewGames, isTrue);
      T.language = Language.byCode('tr');
      expect(T.text('prepareNewGames'), 'Yeni oyunları otomatik hazırla');
    });
  });

  group('free space first', () {
    test('too little room: nothing starts, the panel says how much and the way out', () async {
      var free = 1 << 20;
      fixture = makeFixture(freeSpace: (_) => free);
      model = fixture.model;
      final neon = named('PPSA02002');
      File(p.join(neon.folder, 'eboot.bin')).writeAsBytesSync(typicalSelf());
      model.unlock(neon);
      expect(model.overlay, Layer.copyWarning);
      expect(model.stateOf(neon), isA<Locked>());
      expect(model.queue, isEmpty);
      expect(model.panelCategories().single.title, 'Not enough space');
      expect(rowIds(), ['space', 'otherDrive', 'retry', 'cancel'], reason: 'linked files: no copy rows');
      expect(row('space').title, contains('1.0 MB free'));
      expect(model.copyWarning!.shortage!.free, 1 << 20);
      // Room made, Try again unlocks.
      free = 1 << 50;
      model.activateRow(rowIds().indexOf('retry'));
      expect(model.overlay, isNull);
      await until(() => model.stateOf(neon) is Installed);
    });

    test('too little room for a copy: the copy panel says both, without Copy anyway', () {
      fixture = makeFixture(freeSpace: (_) => 1 << 20);
      model = fixture.model;
      FileLinks.calls = LinkCalls(hardLink: (_, _) => false, symbolicLink: (_, _) => false);
      final neon = named('PPSA02002');
      model.sizes[neon.id] = 31400000000;
      model.unlock(neon, copy: true);
      expect(model.overlay, Layer.copyWarning, reason: 'Copy anyway does not get past a full drive');
      expect(rowIds(), ['space', 'why', 'sameDrive', 'retry', 'cancel']);
      expect((row('space').kind as InfoRow).text, contains('31.4 GB'));
      expect(model.copyWarning!.shortage!.copying, isTrue);
    });

    test('with the room, the copy panel says how much it needs and what is free', () {
      fixture = makeFixture(freeSpace: (_) => 200000000000);
      model = fixture.model;
      FileLinks.calls = LinkCalls(hardLink: (_, _) => false, symbolicLink: (_, _) => false);
      final neon = named('PPSA02002');
      model.sizes[neon.id] = 31400000000;
      model.unlock(neon);
      expect(model.panelCategories().single.title, T.text('copyWarningTitle'));
      expect(rowIds(), ['why', 'sameDrive', 'copyAnyway', 'cancel']);
      expect((row('why').kind as InfoRow).text, contains('200 GB free'));
    });

    test('Update and play is checked the same way', () {
      fixture = makeFixture(freeSpace: (_) => 1 << 20);
      model = fixture.model;
      final orbit = named('PPSA01001');
      model.updateAndPlay(orbit);
      expect(model.overlay, Layer.copyWarning);
      expect(model.stateOf(orbit), isA<Installed>());
    });
  });

  group('preparing new games', () {
    test('a new game is prepared at once and says so, then Ready to play', () async {
      fixture = makeFixture(prepareNewGames: true);
      model = fixture.model;
      final comet = copyIn('Comet', 'PPSA05005');
      expect(model.toast, 'New game: Comet · Preparing…');
      final state = model.stateOf(comet);
      expect(state, isA<Installing>().having((state) => state.preparing, 'preparing', isTrue));
      await until(() => model.stateOf(comet) is Installed);
      expect(model.toast, 'Comet · Ready to play');
      expect(model.prepare.active, isNull);
    });

    test('turned off, a new game only gets its notice', () {
      fixture = makeFixture();
      model = fixture.model;
      final comet = copyIn('Comet', 'PPSA05005');
      expect(model.toast, 'New game: Comet');
      expect(model.stateOf(comet), isA<Locked>());
    });

    test('a game playing: it waits, then goes once the game closed', () async {
      fixture = makeFixture(prepareNewGames: true);
      model = fixture.model;
      model.starting = named('PPSA01001');
      final comet = copyIn('Comet', 'PPSA05005');
      expect(model.toast, 'New game: Comet · Prepares after your game');
      expect(model.stateOf(comet), isA<Locked>().having((state) => state.waitingToPrepare, 'waiting', isTrue));
      model.starting = null;
      model.rescan();
      await until(() => model.stateOf(comet) is Installing);
      await until(() => model.stateOf(comet) is Installed);
    });

    test('a game started while preparing stops it where it is; it goes on after', () async {
      fixture = makeFixture(prepareNewGames: true);
      model = fixture.model;
      makeFakeToolkit(fixture.toolkit, mode: 'slow');
      final comet = copyIn('Comet', 'PPSA05005');
      await until(() => (model.stateOf(comet) as Installing).step == InstallStep.relink);
      model.starting = named('PPSA01001');
      model.rescan();
      await until(() => model.prepare.paused);
      expect(model.stateOf(comet), isA<Installing>().having((state) => state.paused, 'paused', isTrue));
      model.starting = null;
      model.rescan();
      await until(() => !model.prepare.paused);
      // Cancel still cancels.
      model.cancelUnlock(comet);
      await until(() => model.stateOf(comet) is Locked);
      expect(model.prepare.active, isNull);
    }, skip: Platform.isWindows ? 'the fake relinker is a shell script' : false);

    test("the user's own unlock comes first: the preparation stops for it", () async {
      fixture = makeFixture(prepareNewGames: true);
      model = fixture.model;
      makeFakeToolkit(fixture.toolkit, mode: 'slow');
      final comet = copyIn('Comet', 'PPSA05005');
      await until(() => model.stateOf(comet) is Installing);
      final neon = named('PPSA02002');
      File(p.join(neon.folder, 'eboot.bin')).writeAsBytesSync(typicalSelf());
      model.unlock(neon);
      await until(() => model.prepare.paused);
      model.cancelUnlock(neon);
      await until(() => !model.prepare.paused);
    }, skip: Platform.isWindows ? 'the fake relinker is a shell script' : false);

    test('Play on a game being prepared makes it the user\'s own; Cancel unlock gives it up', () async {
      fixture = makeFixture(prepareNewGames: true);
      model = fixture.model;
      makeFakeToolkit(fixture.toolkit, mode: 'slow');
      final comet = copyIn('Comet', 'PPSA05005');
      await until(() => model.stateOf(comet) is Installing);
      model.primaryAction(comet);
      expect(model.toast, "Comet starts as soon as it's ready");
      expect(model.prepare.promoted, isTrue);
      expect(model.stateOf(comet), isA<Installing>().having((state) => state.preparing, 'preparing', isFalse));
      // It starts when ready: a second press says so rather than giving it up.
      model.primaryAction(comet);
      expect(model.toast, T.format('gameUnlockingHint', ['Comet']));
      expect(model.stateOf(comet), isA<Installing>());
      model.select(model.games.indexOf(comet));
      model.open(Layer.gameSettings);
      // Pause is the first row now; Cancel unlock follows and asks before it gives the work up.
      final rows = model.panelCategories().single.rows;
      expect(rows.first.id, 'pauseJob');
      final cancel = rows.firstWhere((row) => row.id == 'cancelJob');
      expect(cancel.title, T.text('cancelUnlock'));
      (cancel.kind as ActionRow).run();
      expect(model.overlay, Layer.confirmCancelUnlock);
      final sure = model.panelCategories().single.rows.firstWhere((row) => row.id == 'cancel');
      (sure.kind as ActionRow).run();
      await until(() => model.stateOf(comet) is Locked);
    }, skip: Platform.isWindows ? 'the fake relinker is a shell script' : false);

    test('on a low battery it is not prepared, and says so', () {
      fixture = makeFixture(prepareNewGames: true);
      model = fixture.model;
      model.power = () => const PowerState(onBattery: true, level: 12);
      final comet = copyIn('Comet', 'PPSA05005');
      expect(model.toast, 'New game: Comet · Plug in to prepare it');
      expect(model.stateOf(comet), isA<Locked>().having((state) => state.waitingToPrepare, 'waiting', isFalse));
    });

    test('without the room it is not prepared, and says so', () {
      fixture = makeFixture(prepareNewGames: true, freeSpace: (_) => 1 << 20);
      model = fixture.model;
      final comet = copyIn('Comet', 'PPSA05005');
      expect(model.toast, 'New game: Comet · Not enough space to prepare it');
      expect(model.stateOf(comet), isA<Locked>());
      expect(Directory(p.join(model.root!, GameLibrary.storeName, 'Work')).existsSync(), isFalse);
    });

    test('the notice for several, and in Turkish', () {
      fixture = makeFixture();
      model = fixture.model;
      expect(AppModel.newGameText(['A', 'B', 'C'], preparing: true), '3 new games · Preparing…');
      expect(
        AppModel.newGameText([
          'A',
        ], skipped: const SpaceShort(SpaceShortage(needed: 2, free: 1, folder: '/g', copying: false))),
        'New game: A · Not enough space to prepare it',
      );
      T.language = Language.byCode('tr');
      expect(AppModel.newGameText(['Comet'], preparing: true), 'Yeni oyun: Comet · Hazırlanıyor…');
      expect(T.format('readyToPlay', ['Comet']), 'Comet · Oynamaya hazır');
    });
  });

  group('screens', () {
    final shell = find.byType(LauncherShell);

    testWidgets('golden: not enough space', (tester) async {
      fixture = makeFixture(freeSpace: (_) => 3100000000);
      model = fixture.model;
      final neon = named('PPSA02002');
      model.select(model.games.indexOf(neon));
      model.sizes[neon.id] = 14200000000;
      FileLinks.calls = LinkCalls(hardLink: (_, _) => false, symbolicLink: (_, _) => false);
      model.unlock(neon, copy: true);
      await pumpLauncher(tester, model);
      expect(find.text('Not enough space'), findsOneWidget);
      await expectLater(shell, matchesGoldenFile('goldens/no_space_copy_en.png'));
    });

    testWidgets('golden: not enough space, Turkish, Windows', (tester) async {
      fixture = makeFixture(freeSpace: (_) => 3100000000, language: Language.byCode('tr'), system: HostSystem.windows);
      model = fixture.model;
      final neon = named('PPSA02002');
      model.select(model.games.indexOf(neon));
      model.sizes[neon.id] = 52000000000;
      FileLinks.calls = LinkCalls(hardLink: (_, _) => false, symbolicLink: (_, _) => false);
      model.unlock(neon);
      await pumpLauncher(tester, model);
      expect(find.text('Yeterli alan yok'), findsOneWidget);
      await expectLater(shell, matchesGoldenFile('goldens/no_space_tr.png'));
    });

    testWidgets('golden: a new game being prepared', (tester) async {
      fixture = makeFixture();
      model = fixture.model;
      final neon = named('PPSA02002');
      model.select(model.games.indexOf(neon));
      model.progress[neon.id] = (InstallStep.relink, 0.42);
      model.prepare.add([neon.id]);
      model.prepare.active = neon.id;
      model.prepare.add([named('PPSA03003').id]);
      model.show(AppModel.newGameText([neon.name], preparing: true), icon: neon.icon);
      await pumpLauncher(tester, model);
      expect(find.text('Play when ready'), findsOneWidget);
      await expectLater(shell, matchesGoldenFile('goldens/prepare_home_en.png'));
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('golden: paused while a game plays, Turkish', (tester) async {
      fixture = makeFixture(language: Language.byCode('tr'));
      model = fixture.model;
      final neon = named('PPSA02002');
      model.select(model.games.indexOf(neon));
      model.progress[neon.id] = (InstallStep.relink, 0.42);
      model.prepare.active = neon.id;
      model.prepare.paused = true;
      model.show(T.format('readyToPlay', [named('PPSA03003').name]));
      await pumpLauncher(tester, model);
      expect(find.text('Oyun için durdu'), findsWidgets);
      await expectLater(shell, matchesGoldenFile('goldens/prepare_paused_tr.png'));
      await tester.pump(const Duration(seconds: 5));
    });
  });
}
