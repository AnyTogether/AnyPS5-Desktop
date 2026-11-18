import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_protocol.dart';
import 'package:anyps5_desktop/core/retro_host/retro_state_slots.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/retro_host/retro_host_game.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/ps1_launcher.dart';
import '../support/save_states_host_recording.dart';
import 'retro_host/fake_retro_host_session.dart';

/// Save state and Load state in the menu of a game in the emulator host, which a host that lists
/// `saveStates` (the save-states branch, recorded) answers.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final recording = SaveStatesHostRecording.load();
  final saved = recording.calls('slots', 'saveState').first.reply['result'];
  final loaded = recording.calls('slots', 'loadState')[1].reply['result'];
  RetroCallError refusal(String scenario, String code) {
    final error = recording
        .calls(scenario, 'loadState')
        .map((exchange) => exchange.reply['error'])
        .whereType<Map<String, Object?>>()
        .firstWhere((error) => error['code'] == code);
    return RetroCallError(code, error['message']! as String);
  }

  late Ps1Launcher launcher;
  tearDown(() => launcher.dispose());

  List<String> rowIds(AppModel model) => [for (final row in model.panelCategories().single.rows) row.id];

  /// The game's states folder, as the launcher keeps it.
  String statesOf(Game game, {bool ps2 = false}) =>
      p.normalize(launcher.model.paths.retroStates(game.titleId, ps2: ps2));
  RetroStateFolder folder({bool ps2 = false}) => RetroStateFolder(
    folder: statesOf(ps2 ? launcher.ps2Game : launcher.game, ps2: ps2),
    disc: ps2 ? launcher.ps2Disc! : launcher.disc,
  );

  /// The host writes a state's file as it saves it, as the recorded host did.
  void hostWritesStates() => launcher.session.onCall = (method, args) {
    if (method != 'saveState') return;
    File(folder().statePath((args! as Map)['slot'] as int))
      ..createSync(recursive: true)
      ..writeAsBytesSync([1, 2, 3]);
  };

  Future<void> settleFiles() async {
    for (var turn = 0; turn < 5; turn++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<AppModel> playing({bool ps2 = false}) async {
    launcher = Ps1Launcher(ps2: ps2);
    launcher.session.canSaveStates = true;
    final model = launcher.model
      ..setRetroHostPs1(true)
      ..setRetroHostPs2(ps2);
    await launcher.start(ps2: ps2);
    await settleFiles();
    return model;
  }

  test('a game starts with its own states folder, and its menu has Save state and Load state', () async {
    final model = await playing();
    expect(launcher.session.startArgs?['states'], statesOf(launcher.game));
    expect(p.basename(statesOf(launcher.game)), 'PS1-SLUS00001', reason: "named by the game's title ID");
    expect(T.text('retroMenuSaveState'), 'Save state', reason: 'sentence case, as every row');
    expect(T.text('retroMenuLoadState'), 'Load state');
    model.openRetroMenu();
    await settleFiles();
    expect(rowIds(model), [
      'resume',
      'saveState',
      'loadState',
      'section-audio',
      'closeGame',
    ], reason: 'after the discs (none here), before the sections');
    expect(launcher.row('saveState').detail, T.text('retroMenuSaveStateDetail'));
    expect(launcher.row('loadState').kind, isA<InfoRow>(), reason: 'nothing to load yet');
    expect(launcher.row('loadState').detail, T.text('retroMenuNoStatesDetail'));
  });

  test("a PS2 game's states are kept apart from PS1 games'", () async {
    await playing(ps2: true);
    expect(launcher.session.startArgs?['states'], statesOf(launcher.ps2Game, ps2: true));
    expect(p.dirname(statesOf(launcher.ps2Game, ps2: true)), isNot(p.dirname(statesOf(launcher.game))));
  });

  test('two games whose discs have the same name keep their states apart', () async {
    launcher = Ps1Launcher();
    final other = Directory(p.join(launcher.model.root!, 'Day Racer'))..createSync();
    File(p.join(other.path, 'game.cue')).createSync();
    File(p.join(other.path, 'retro.json')).writeAsStringSync(
      jsonEncode({'platform': 'ps1', 'titleId': 'SLUS0-0001', 'name': 'Day Racer', 'disc': 'game.cue'}),
    );
    launcher.model.rescan();
    await settleFiles();
    final day = launcher.model.games.singleWhere((game) => game.name == 'Day Racer');
    final night = launcher.model.games.singleWhere((game) => game.name == 'Night Racer');
    expect(day.slug, night.slug, reason: 'title IDs that differ only by a hyphen');
    final dayStates = RetroStateFolder(folder: statesOf(day), disc: day.retro!.path);
    final nightStates = RetroStateFolder(folder: statesOf(night), disc: night.retro!.path);
    expect(
      p.basename(dayStates.statePath(0)),
      p.basename(nightStates.statePath(0)),
      reason: 'the host names both alike',
    );
    expect(dayStates.statePath(0), isNot(nightStates.statePath(0)));
  });

  test('a host without saveStates is sent no states folder, and the menu has no Save state', () async {
    launcher = Ps1Launcher();
    final model = launcher.model..setRetroHostPs1(true);
    await launcher.start();
    expect(launcher.session.startArgs, isNot(contains('states')));
    model.openRetroMenu();
    expect(rowIds(model), isNot(contains('saveState')));
    expect(rowIds(model), isNot(contains('loadState')));
  });

  test('Save state: an empty slot saves at once and the game goes on; a used one asks first', () async {
    final model = await playing();
    hostWritesStates();
    launcher.session.callResults['saveState'] = saved;
    model.openRetroMenu();
    (launcher.row('saveState').kind as ActionRow).run();
    expect(model.panelCategories().single.title, T.text('retroMenuSaveState'));
    expect(rowIds(model), [for (var slot = 0; slot < RetroStateFolder.slots; slot++) 'state-$slot']);
    expect(launcher.row('state-0').title, 'Slot 1');
    expect(launcher.row('state-0').detail, T.text('retroStateEmpty'));
    expect(model.panelRow, 0);

    (launcher.row('state-0').kind as ActionRow).run();
    await settleFiles();
    expect(launcher.session.calls.where((call) => call.$1 == 'saveState').map((call) => call.$2), [
      {'slot': 0},
    ]);
    expect(model.overlay, isNull, reason: 'back to the game once it is saved');
    expect(launcher.session.calls.last, ('pause', false));
    expect(model.toast, 'Saved in slot 1');

    model.openRetroMenu();
    await settleFiles();
    expect(launcher.row('loadState').kind, isA<ActionRow>());
    expect(launcher.row('loadState').detail, T.text('retroMenuLoadStatePs1Detail'), reason: 'a PS1 card goes back too');
    (launcher.row('saveState').kind as ActionRow).run();
    final when = launcher.row('state-0').detail!;
    expect(when, matches(RegExp(r'^\d{4}-\d\d-\d\d \d\d:\d\d$')));
    model.panelRow = 0;
    (launcher.row('state-0').kind as ActionRow).run();
    expect(model.overlay, Layer.retroOverwriteState);
    expect(model.panelCategories().single.title, 'Overwrite slot 1?');
    expect(rowIds(model), ['cancel', 'overwrite'], reason: 'Cancel first, where the focus starts');
    expect(launcher.row('overwrite').detail, T.format('retroStateOverwriteDetail', [when]));
    expect(model.panelRow, 0);

    model.handle(Command.back);
    expect(model.overlay, Layer.retroMenu, reason: 'Back goes back to Save state');
    expect(model.panelCategories().single.id, 'retroMenu-save');
    expect(launcher.session.calls.where((call) => call.$1 == 'saveState'), hasLength(1));
    expect(launcher.play.menu.isOpen, isTrue, reason: 'the game stays paused');

    (launcher.row('state-0').kind as ActionRow).run();
    (launcher.row('overwrite').kind as ActionRow).run();
    await settleFiles();
    expect(launcher.session.calls.where((call) => call.$1 == 'saveState'), hasLength(2));
    expect(model.overlay, isNull);

    model.openRetroMenu();
    (launcher.row('saveState').kind as ActionRow).run();
    model.handle(Command.back);
    expect(model.panelCategories().single.id, 'retroMenu');
    expect(model.panelRow, 1, reason: 'on the Save state row');
  });

  test('Save state and Load state show once the game has shown its first frame, keeping the focus', () async {
    launcher = Ps1Launcher();
    launcher.session.canSaveStates = true;
    final model = launcher.model..setRetroHostPs1(true);
    await launcher.start(status: fakeStatus(ready: false));
    await settleFiles();
    expect(launcher.play.host.phase, RetroHostGamePhase.loading);
    model.openRetroMenu();
    expect(rowIds(model), ['resume', 'section-audio', 'closeGame'], reason: 'the host saves nothing yet');
    model.panelRow = rowIds(model).indexOf('closeGame');
    launcher.session.nextStatus = menuStatus();
    await launcher.play.host.refresh();
    await pumpEventQueue();
    expect(launcher.play.host.phase, RetroHostGamePhase.playing);
    expect(rowIds(model), containsAllInOrder(['resume', 'disc-0', 'disc-1', 'saveState', 'loadState', 'closeGame']));
    expect(rowIds(model)[model.panelRow], 'closeGame', reason: 'the focus stays on the row it was on');
  });

  test('a slot says Saving… or Loading… while its call runs, and nothing else starts meanwhile', () async {
    final model = await playing();
    hostWritesStates();
    launcher.session
      ..callResults['saveState'] = saved
      ..callResults['loadState'] = loaded;
    model.openRetroMenu();
    (launcher.row('saveState').kind as ActionRow).run();
    final gate = launcher.session.callGate = Completer<void>();
    (launcher.row('state-2').kind as ActionRow).run();
    await pumpEventQueue();
    expect(launcher.row('state-2').detail, T.text('retroStateSaving'));
    expect(T.text('retroStateSaving'), 'Saving…');
    expect(launcher.row('state-3').detail, T.text('retroStateEmpty'));
    (launcher.row('state-3').kind as ActionRow).run();
    await pumpEventQueue();
    expect(launcher.session.calls.where((call) => call.$1 == 'saveState'), hasLength(1));
    launcher.session.callGate = null;
    gate.complete();
    await settleFiles();
    expect(model.overlay, isNull);

    model.openRetroMenu();
    (launcher.row('loadState').kind as ActionRow).run();
    final loading = launcher.session.callGate = Completer<void>();
    (launcher.row('state-2').kind as ActionRow).run();
    await pumpEventQueue();
    expect(launcher.row('state-2').detail, T.text('retroStateLoading'));
    launcher.session.callGate = null;
    loading.complete();
    await settleFiles();
    expect(model.toast, 'Slot 3 loaded');
  });

  test('a save that does not work says so and stays on Save state', () async {
    final model = await playing();
    launcher.session.callErrors['saveState'] = const RetroCallError(RetroCallError.fileError, 'not written');
    model.openRetroMenu();
    (launcher.row('saveState').kind as ActionRow).run();
    (launcher.row('state-3').kind as ActionRow).run();
    await settleFiles();
    expect(model.toast, T.text('retroStateSaveFailed'));
    expect(model.overlay, Layer.retroMenu);
    expect(model.panelCategories().single.id, 'retroMenu-save');
  });

  test('Load state: a saved slot loads and the game goes on; a refused one says why in plain words', () async {
    launcher = Ps1Launcher();
    launcher.session.canSaveStates = true;
    final states = folder();
    for (final slot in [1, 4]) {
      File(states.statePath(slot))
        ..createSync(recursive: true)
        ..writeAsBytesSync([1]);
    }
    final png = Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10]);
    File(states.picturePath(1)).writeAsBytesSync(png);
    final model = launcher.model..setRetroHostPs1(true);
    await launcher.start();
    await settleFiles();
    model.openRetroMenu();
    await settleFiles();
    (launcher.row('loadState').kind as ActionRow).run();
    expect(model.panelCategories().single.title, T.text('retroMenuLoadState'));
    expect(launcher.row('state-0').kind, isA<InfoRow>(), reason: 'an empty slot cannot be loaded');
    expect(launcher.row('state-1').kind, isA<ActionRow>());
    expect(launcher.row('state-1').picture, png);
    expect(launcher.row('state-4').picture, isNull);
    expect(launcher.row('state-4').pictureAspect, launcher.play.host.aspect, reason: 'its place is kept');
    expect(model.panelRow, 1, reason: 'on the first slot that holds a state');

    for (final (scenario, code, words) in [
      ('other-core', RetroCallError.otherCore, 'retroStateOtherCore'),
      ('other-game', RetroCallError.otherGame, 'retroStateOtherGame'),
      ('refused', RetroCallError.badState, 'retroStateBad'),
      ('refused', RetroCallError.coreRefused, 'retroStateLoadFailed'),
      ('refused', RetroCallError.fileError, 'retroStateLoadFailed'),
    ]) {
      launcher.session.callErrors['loadState'] = refusal(scenario, code);
      (launcher.row('state-1').kind as ActionRow).run();
      await settleFiles();
      expect(model.toast, T.text(words), reason: code);
      expect(model.overlay, Layer.retroMenu, reason: '$code: still on Load state');
      expect(model.panelCategories().single.id, 'retroMenu-load');
    }

    launcher.session.callErrors.clear();
    launcher.session.callResults['loadState'] = loaded;
    (launcher.row('state-4').kind as ActionRow).run();
    await settleFiles();
    expect(launcher.session.calls.where((call) => call.$1 == 'loadState').last.$2, {'slot': 4});
    expect(model.overlay, isNull, reason: 'back to the game, which goes on from the state');
    expect(model.toast, 'Slot 5 loaded');
  });

  test('a load that answers after the menu was left and opened again leaves the new visit alone', () async {
    launcher = Ps1Launcher();
    launcher.session.canSaveStates = true;
    File(folder().statePath(0))
      ..createSync(recursive: true)
      ..writeAsBytesSync([1]);
    final model = launcher.model..setRetroHostPs1(true);
    await launcher.start();
    await settleFiles();
    launcher.session.callResults['loadState'] = loaded;
    final gate = Completer<void>();
    model.openRetroMenu();
    (launcher.row('loadState').kind as ActionRow).run();
    launcher.session.callGate = gate;
    (launcher.row('state-0').kind as ActionRow).run();
    await pumpEventQueue();
    model.resumeRetroGame();
    launcher.session.callGate = null;
    model.openRetroMenu();
    (launcher.row('loadState').kind as ActionRow).run();
    gate.complete();
    await settleFiles();
    expect(model.toast, 'Slot 1 loaded');
    expect(model.overlay, Layer.retroMenu, reason: 'the menu opened again stays open');
    expect(model.panelCategories().single.id, 'retroMenu-load');
  });

  test('a slot found empty on load says it could not be loaded and shows as empty', () async {
    launcher = Ps1Launcher();
    launcher.session.canSaveStates = true;
    File(folder().statePath(2))
      ..createSync(recursive: true)
      ..writeAsBytesSync([1]);
    final model = launcher.model..setRetroHostPs1(true);
    await launcher.start();
    model.openRetroMenu();
    await settleFiles();
    (launcher.row('loadState').kind as ActionRow).run();
    File(folder().statePath(2)).deleteSync();
    launcher.session.callErrors['loadState'] = refusal('slots', RetroCallError.noState);
    (launcher.row('state-2').kind as ActionRow).run();
    await settleFiles();
    expect(model.toast, T.text('retroStateLoadFailed'));
    expect(launcher.row('state-2').kind, isA<InfoRow>());
  });

  test('PS on Overwrite slot N? goes back to Save state, and the game ending closes both', () async {
    launcher = Ps1Launcher();
    launcher.session.canSaveStates = true;
    File(folder().statePath(0))
      ..createSync(recursive: true)
      ..writeAsBytesSync([1]);
    final model = launcher.model..setRetroHostPs1(true);
    await launcher.start();
    await settleFiles();
    hostWritesStates();
    launcher.session.callResults['saveState'] = saved;
    model.openRetroMenu();
    await settleFiles();
    (launcher.row('saveState').kind as ActionRow).run();
    (launcher.row('state-0').kind as ActionRow).run();
    expect(model.overlay, Layer.retroOverwriteState);
    model.handle(Command.home);
    expect(model.overlay, Layer.retroMenu);
    expect(model.panelCategories().single.id, 'retroMenu-save');
    (launcher.row('state-0').kind as ActionRow).run();
    model.handle(Command.options);
    expect(model.overlay, Layer.retroMenu, reason: 'Options goes back to Save state too');
    expect(model.panelCategories().single.id, 'retroMenu-save');
    expect(model.panelRow, 0, reason: 'on that slot');
    expect(launcher.session.calls.where((call) => call.$1 == 'saveState'), isEmpty);
    (launcher.row('state-0').kind as ActionRow).run();
    model.homeHeld();
    await pumpEventQueue();
    expect(model.overlay, isNull, reason: 'held PS goes back to the game');
    expect(launcher.play.menu.isOpen, isFalse);

    model.openRetroMenu();
    (launcher.row('saveState').kind as ActionRow).run();
    (launcher.row('state-0').kind as ActionRow).run();
    launcher.session.nextStatus = fakeStatus(ended: true, errorCode: RetroErrorCode.core);
    await launcher.play.host.refresh();
    await pumpEventQueue();
    expect(model.overlay, isNull, reason: 'the question goes with the game');
    expect(launcher.play.statePage, isNull);
  });

  test('a PS1 load answered false that ended the game with other says the card may be back at that moment', () async {
    launcher = Ps1Launcher();
    launcher.session.canSaveStates = true;
    File(folder().statePath(0))
      ..createSync(recursive: true)
      ..writeAsBytesSync([1]);
    final model = launcher.model..setRetroHostPs1(true);
    await launcher.start();
    await settleFiles();
    launcher.session.callResults['loadState'] = false;
    model.openRetroMenu();
    await settleFiles();
    (launcher.row('loadState').kind as ActionRow).run();
    (launcher.row('state-0').kind as ActionRow).run();
    await settleFiles();
    expect(model.toast, T.text('retroStateLoadFailed'));
    launcher.session.nextStatus = fakeStatus(ended: true, errorCode: RetroErrorCode.other);
    await launcher.play.host.refresh();
    await pumpEventQueue();
    expect(model.toast, T.text('retroStateCardAfterEnd'));
  });

  test('the words for a state that did not work', () {
    launcher = Ps1Launcher();
    expect(retroStateProblem(RetroStateOutcome.otherCore, saving: false), 'retroStateOtherCore');
    expect(retroStateProblem(RetroStateOutcome.otherGame, saving: false), 'retroStateOtherGame');
    expect(retroStateProblem(RetroStateOutcome.badState, saving: false), 'retroStateBad');
    for (final outcome in [RetroStateOutcome.notNow, RetroStateOutcome.fileError, RetroStateOutcome.failed]) {
      expect(retroStateProblem(outcome, saving: false), 'retroStateLoadFailed');
      expect(retroStateProblem(outcome, saving: true), 'retroStateSaveFailed');
    }
    expect(retroStateTime(DateTime(2026, 11, 8, 20, 4)), '2026-11-08 20:04');
  });
}
