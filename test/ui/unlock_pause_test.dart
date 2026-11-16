import 'dart:io';

import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/installer.dart';
import 'package:anyps5_desktop/ui/app_model.dart' hide Command, GameState;
import 'package:anyps5_desktop/ui/app_model.dart' as launcher show Command;
import 'package:anyps5_desktop/ui/game_action.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_toolkit.dart';
import '../support/phone/fake_phone.dart';
import '../support/phone/messages.dart';
import '../support/self_builder.dart';
import '../support/ui_support.dart';

/// Pause, Resume and Cancel on an unlock the user asked for: the next game starting while one is
/// paused, a resumed one waiting its turn, the cancel on a running, a paused and a waiting
/// unlock, the question when the launcher closes, the focus when the small Cancel goes away, and
/// what the phone is told. The fake relinker sleeps (mode slow), so an unlock stays under way.
void main() {
  late Fixture fixture;
  late AppModel model;
  late List<int> quits;

  const skipWindows = 'the fake relinker is a shell script';

  Future<void> untilTrue(bool Function() condition) async {
    for (var tries = 0; tries < 500 && !condition(); tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(condition(), isTrue);
  }

  setUp(() {
    quits = [];
    fixture = makeFixture(quit: quits.add);
    model = fixture.model;
    makeFakeToolkit(fixture.toolkit, mode: 'slow');
  });

  tearDown(() async {
    // Nothing is left sleeping: every unlock is given up before the folders go.
    for (final game in model.games) {
      if (model.stateOf(game) is Queued) model.cancelUnlock(game);
    }
    for (final game in model.games) {
      if (model.stateOf(game) case Installing(cancelling: false)) model.cancelUnlock(game);
    }
    await untilTrue(() => !model.unlocking);
    T.language = Language.english;
    model.dispose();
    fixture.dispose();
  });

  Game named(String titleId) => model.games.firstWhere((game) => game.titleId == titleId);

  /// A game the fake relinker can unlock.
  Game lockable(String titleId) {
    final game = named(titleId);
    File(p.join(game.folder, 'eboot.bin')).writeAsBytesSync(typicalSelf());
    return game;
  }

  Installing installing(Game game) => model.stateOf(game) as Installing;

  /// The relinker is running: only then is there a process to freeze.
  Future<void> relinking(Game game) => untilTrue(() => model.progress[game.id]?.$1 == InstallStep.relink);

  /// Two unlocks: [first] runs, [second] waits in line.
  Future<(Game, Game)> twoUnlocks() async {
    final first = lockable('PPSA02002');
    final second = lockable('PPSA03003');
    model.unlock(first);
    model.unlock(second);
    expect(model.stateOf(first), isA<Installing>());
    expect(model.stateOf(second), isA<Queued>());
    await relinking(first);
    return (first, second);
  }

  group('pause and resume', () {
    test('Pause freezes the unlock, the button says Resume, and the next game starts', () async {
      final (first, second) = await twoUnlocks();
      expect(GameAction.of(model.stateOf(first)).title, 'Pause');
      model.pauseUnlock(first);
      expect(installing(first).paused, isTrue);
      expect(GameAction.of(model.stateOf(first)).title, 'Resume');
      await untilTrue(() => model.stateOf(second) is Installing);
      expect(installing(second).paused, isFalse);
      expect(installing(first).paused, isTrue, reason: 'the first one stays where it stopped');
      expect(model.unlocking, isTrue);
    }, skip: Platform.isWindows ? skipWindows : false);

    test('Resume with nothing else running goes on at once', () async {
      final first = lockable('PPSA02002');
      model.unlock(first);
      await relinking(first);
      model.pauseUnlock(first);
      expect(installing(first).paused, isTrue);
      model.resumeUnlock(first);
      expect(installing(first).paused, isFalse);
      expect(installing(first).waiting, isFalse);
      expect(GameAction.of(model.stateOf(first)).title, 'Pause');
    }, skip: Platform.isWindows ? skipWindows : false);

    test('Resume while another unlock runs: it waits its turn, with Pause as its button', () async {
      final (first, second) = await twoUnlocks();
      model.pauseUnlock(first);
      await untilTrue(() => model.stateOf(second) is Installing);
      model.resumeUnlock(first);
      final waiting = installing(first);
      expect(waiting.waiting, isTrue);
      expect(waiting.paused, isFalse);
      expect(GameAction.of(waiting).title, 'Pause');
      expect(installing(second).paused, isFalse, reason: 'only one unlock works at a time');
      // Pause puts it back to paused.
      model.pauseUnlock(first);
      expect(installing(first).waiting, isFalse);
      expect(installing(first).paused, isTrue);
    }, skip: Platform.isWindows ? skipWindows : false);

    test('a waiting unlock goes on when the one that runs has ended', () async {
      final (first, second) = await twoUnlocks();
      model.pauseUnlock(first);
      await untilTrue(() => model.stateOf(second) is Installing);
      await relinking(second);
      model.resumeUnlock(first);
      expect(installing(first).waiting, isTrue);
      model.cancelUnlock(second);
      await untilTrue(() => model.stateOf(second) is Locked);
      await untilTrue(() => model.stateOf(first) is Installing && !installing(first).waiting);
      expect(installing(first).paused, isFalse);
    }, skip: Platform.isWindows ? skipWindows : false);
  });

  group('cancel', () {
    test('on a running unlock: Cancelling… until its work has ended, no failure', () async {
      final first = lockable('PPSA02002');
      model.unlock(first);
      await relinking(first);
      model.cancelUnlock(first);
      expect(installing(first).cancelling, isTrue);
      expect(GameAction.of(model.stateOf(first)).title, 'Cancelling…');
      await untilTrue(() => model.stateOf(first) is Locked);
      expect(model.failures, isEmpty, reason: 'a cancel is not a failure');
    }, skip: Platform.isWindows ? skipWindows : false);

    test('on a paused unlock: it is given up for good', () async {
      final first = lockable('PPSA02002');
      model.unlock(first);
      await relinking(first);
      model.pauseUnlock(first);
      model.cancelUnlock(first);
      expect(installing(first).cancelling, isTrue);
      await untilTrue(() => model.stateOf(first) is Locked);
      await untilTrue(() => !model.unlocking);
      expect(model.failures, isEmpty);
    }, skip: Platform.isWindows ? skipWindows : false);

    test('on a waiting unlock: it goes, the one that runs is not touched', () async {
      final (first, second) = await twoUnlocks();
      model.pauseUnlock(first);
      await untilTrue(() => model.stateOf(second) is Installing);
      model.resumeUnlock(first);
      expect(installing(first).waiting, isTrue);
      model.cancelUnlock(first);
      await untilTrue(() => model.stateOf(first) is Locked);
      expect(model.stateOf(second), isA<Installing>().having((state) => state.cancelling, 'cancelling', isFalse));
      expect(installing(second).paused, isFalse);
    }, skip: Platform.isWindows ? skipWindows : false);

    test('the small Cancel asks first; Keep going leaves the unlock, Cancel unlock drops it', () async {
      final first = lockable('PPSA02002');
      model.unlock(first);
      await relinking(first);
      model.select(model.games.indexOf(first));
      expect(model.cancelShown, isTrue);
      model.askCancelUnlock(first);
      expect(model.overlay, Layer.confirmCancelUnlock);
      expect(model.panelCategories().single.rows.map((row) => row.id), ['keep', 'cancel']);
      (model.panelCategories().single.rows.first.kind as ActionRow).run();
      expect(model.overlay, isNull);
      expect(installing(first).cancelling, isFalse);
      model.askCancelUnlock(first);
      (model.panelCategories().single.rows.last.kind as ActionRow).run();
      expect(model.overlay, isNull);
      await untilTrue(() => model.stateOf(first) is Locked);
    }, skip: Platform.isWindows ? skipWindows : false);

    test('an unlock the game starts after has no Pause and no small Cancel', () async {
      final first = lockable('PPSA02002');
      model.unlock(first);
      await relinking(first);
      expect(model.canCancelUnlock(const Installing(InstallStep.relink, 0.5, playsAfter: true)), isFalse);
      expect(model.canCancelUnlock(const Installing(InstallStep.relink, 0.5, updating: true)), isFalse);
      expect(model.canCancelUnlock(const Installing(InstallStep.relink, 0.5, preparing: true)), isFalse);
      expect(model.canCancelUnlock(installing(first)), isTrue);
    }, skip: Platform.isWindows ? skipWindows : false);
  });

  group('the focus when the small Cancel goes away', () {
    test('a focus on it goes to the main button; one after it keeps its button', () async {
      final first = lockable('PPSA02002');
      model.unlock(first);
      await relinking(first);
      model.select(model.games.indexOf(first));
      expect(model.actionCount, 3, reason: 'the main button, the small Cancel and the settings');
      model.focus = HomeFocus.actions(model.settingsAction);
      expect(model.settingsAction, 2);
      model.cancelUnlock(first);
      await untilTrue(() => !model.cancelShown);
      expect(model.focus, HomeFocus.actions(model.settingsAction), reason: 'still on the settings button');
      expect(model.settingsAction, 1);
      expect(model.focus, const HomeFocus.actions(1));
    }, skip: Platform.isWindows ? skipWindows : false);

    test('on the small Cancel itself it goes back to the main button', () async {
      final first = lockable('PPSA02002');
      model.unlock(first);
      await relinking(first);
      model.select(model.games.indexOf(first));
      model.focus = HomeFocus.actions(model.cancelAction);
      model.cancelUnlock(first);
      await untilTrue(() => !model.cancelShown);
      expect(model.focus, const HomeFocus.actions(0));
    }, skip: Platform.isWindows ? skipWindows : false);
  });

  group('closing the launcher', () {
    test('with no unlock under way nothing is asked', () {
      expect(model.hasManualUnlock, isFalse);
      expect(model.allowExit(), isTrue);
      model.requestQuit();
      expect(quits, [0]);
      expect(model.overlay, isNull);
    });

    test('with an unlock under way the window close and Quit ask first', () async {
      final first = lockable('PPSA02002');
      model.unlock(first);
      await relinking(first);
      expect(model.allowExit(), isFalse);
      expect(model.overlay, Layer.confirmQuitUnlocks);
      expect(quits, isEmpty);
      expect(model.panelCategories().single.title, T.text('quitUnlocksTitle'));
      model.closeOverlay();
      model.requestQuit();
      expect(model.overlay, Layer.confirmQuitUnlocks);
      expect(quits, isEmpty);
      // Go back keeps the launcher and the unlock.
      (model.panelCategories().single.rows.first.kind as ActionRow).run();
      expect(model.overlay, isNull);
      expect(model.stateOf(first), isA<Installing>());
      expect(quits, isEmpty);
    }, skip: Platform.isWindows ? skipWindows : false);

    test('a paused or waiting unlock asks too', () async {
      final (first, second) = await twoUnlocks();
      model.pauseUnlock(first);
      await untilTrue(() => model.stateOf(second) is Installing);
      model.cancelUnlock(second);
      await untilTrue(() => model.stateOf(second) is Locked);
      expect(model.stateOf(first), isA<Installing>().having((state) => state.paused, 'paused', isTrue));
      expect(model.hasManualUnlock, isTrue);
      expect(model.allowExit(), isFalse);
      expect(model.overlay, Layer.confirmQuitUnlocks);
    }, skip: Platform.isWindows ? skipWindows : false);

    test('Cancel and quit drops every unlock, the paused ones too, then quits', () async {
      final (first, second) = await twoUnlocks();
      model.pauseUnlock(first);
      await untilTrue(() => model.stateOf(second) is Installing);
      model.requestQuit();
      (model.panelCategories().single.rows.last.kind as ActionRow).run();
      await untilTrue(() => quits.isNotEmpty);
      expect(quits, [0]);
      expect(model.unlocking, isFalse, reason: 'no frozen relinker outlives the launcher');
      expect(model.queue, isEmpty);
      expect(model.stateOf(first), isA<Locked>());
      expect(model.stateOf(second), isA<Locked>());
      // The close the launcher started itself goes through the exit request.
      expect(model.allowExit(), isTrue);
    }, skip: Platform.isWindows ? skipWindows : false);

    test('a quit nobody is asked about (a Steam game ended, Install now) cancels the unlocks first', () async {
      final first = lockable('PPSA02002');
      model.unlock(first);
      await relinking(first);
      model.exitWithoutAsking(0);
      expect(quits, [0]);
      expect(model.overlay, isNull, reason: 'the question does not open');
      expect(model.allowExit(), isTrue, reason: 'and the exit request lets the close through');
      await untilTrue(() => model.stateOf(first) is Locked);
      expect(model.unlocking, isFalse);
    }, skip: Platform.isWindows ? skipWindows : false);
  });

  group('the phone', () {
    setUp(() async {
      await model.startPhoneServer();
    });

    tearDown(() async {
      await model.stopPhoneServer();
    });

    Future<FakePhone> pairedPhone() async {
      final phone = await FakePhone.connect(model.remote!.port!);
      phone.hello('phone-1', 'Pixel');
      await phone.next<Pairing>();
      await untilTrue(() => model.pairing != null);
      model.handle(launcher.Command.select);
      await phone.next<Welcome>();
      await phone.next<Library>();
      return phone;
    }

    GameState stateOfGame(Library library, Game game) => library.games.firstWhere((entry) => entry.id == game.id).state;

    test('a paused unlock reads as locked and a waiting one as installing', () async {
      final phone = await pairedPhone();
      final (first, second) = await twoUnlocks();
      model.pauseUnlock(first);
      await phone.nextWhere<Library>((library) => stateOfGame(library, first) == GameState.locked);
      await untilTrue(() => model.stateOf(second) is Installing);
      model.resumeUnlock(first);
      expect(installing(first).waiting, isTrue);
      await phone.nextWhere<Library>((library) => stateOfGame(library, first) == GameState.installing);
      await phone.close();
    }, skip: Platform.isWindows ? skipWindows : false);

    test('the activity skips a paused and a waiting unlock: it shows the one that runs', () async {
      final phone = await pairedPhone();
      final (first, second) = await twoUnlocks();
      await phone.nextWhere<ActivityUpdate>((update) => update.activity?.id == first.id);
      model.pauseUnlock(first);
      await phone.nextWhere<ActivityUpdate>((update) => update.activity?.id == second.id);
      model.resumeUnlock(first);
      expect(installing(first).waiting, isTrue);
      // Still the one that runs, not the one that waits (a later activity may only repeat it).
      expect(model.stateOf(second), isA<Installing>().having((state) => state.paused, 'paused', isFalse));
      await phone.close();
    }, skip: Platform.isWindows ? skipWindows : false);

    test('the phone\'s Unlock on a paused game resumes it', () async {
      final phone = await pairedPhone();
      final first = lockable('PPSA02002');
      model.unlock(first);
      await relinking(first);
      model.pauseUnlock(first);
      expect(installing(first).paused, isTrue);
      await phone.nextWhere<Library>((library) => stateOfGame(library, first) == GameState.locked);
      model.primaryAction(first);
      expect(installing(first).paused, isFalse);
      await phone.nextWhere<Library>((library) => stateOfGame(library, first) == GameState.installing);
      await phone.close();
    }, skip: Platform.isWindows ? skipWindows : false);
  });
}
