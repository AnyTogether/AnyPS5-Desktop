import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/retro_host/retro_host_protocol.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_session.dart';
import 'package:anyps5_desktop/core/retro_host/retro_state_slots.dart';
import 'package:anyps5_desktop/ui/retro_host/retro_host_game.dart';
import 'package:anyps5_desktop/ui/retro_host/retro_save_states.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/save_states_host_recording.dart';
import 'fake_retro_host_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final recording = SaveStatesHostRecording.load();

  late Directory temp;
  late FakeRetroHostSession session;
  late RetroHostGame game;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('retro-save-states-');
    session = FakeRetroHostSession()..canSaveStates = true;
    game = RetroHostGame(session, statusEvery: const Duration(hours: 1));
  });

  tearDown(() {
    game.dispose();
    temp.deleteSync(recursive: true);
  });

  RetroHostStartRequest request() => RetroHostStartRequest(
    core: 'swanstation_libretro.so',
    disc: p.join(temp.path, 'games', 'Night Racer.cue'),
    system: p.join(temp.path, 'system'),
    saves: p.join(temp.path, 'saves'),
    states: p.join(temp.path, 'states'),
  );

  Future<void> started() async {
    session.readyCompleter.complete();
    session.nextStatus = fakeStatus();
    await game.start(request());
  }

  test('a game started with a states folder on a host that lists saveStates sends it and saves states', () async {
    await started();
    expect(session.startArgs?['states'], p.join(temp.path, 'states'));
    expect(game.savesStates, isTrue);
  });

  test('on a host without saveStates the folder is left out and the game has no save states', () async {
    session.canSaveStates = false;
    await started();
    expect(session.startArgs, isNot(contains('states')));
    expect(game.savesStates, isFalse);
    expect(await game.saveState(0), RetroStateOutcome.notNow);
    expect(session.calls.where((call) => call.$1 == 'saveState'), isEmpty);
  });

  test('every saveState and loadState reply the recorded host sent is the outcome the menu acts on', () async {
    await started();
    final seen = <RetroStateOutcome>{};
    for (final exchange in recording.stateCalls()) {
      final method = exchange.call['method']! as String;
      final args = exchange.call['args']! as Map<String, Object?>;
      if (!args.containsKey('slot')) continue;
      session.callResults.clear();
      session.callErrors.clear();
      final expected = switch (exchange.reply) {
        {'error': final Map<String, Object?> error} => () {
          session.callErrors[method] = RetroCallError(error['code']! as String, error['message']! as String);
          return RetroStateOutcome.ofError(error['code']! as String);
        }(),
        {'result': final Object? result} => () {
          session.callResults[method] = result;
          return result is Map ? RetroStateOutcome.done : RetroStateOutcome.notNow;
        }(),
        _ => throw StateError('a reply without result or error'),
      };
      final slot = args['slot']! as int;
      final outcome = method == 'saveState' ? await game.saveState(slot) : await game.loadState(slot);
      expect(outcome, expected, reason: '${exchange.scenario}: $method $args');
      expect(session.calls.last.$1, method);
      expect(session.calls.last.$2, {'slot': slot});
      seen.add(outcome);
    }
    expect(seen, RetroStateOutcome.values.toSet(), reason: 'the recording has every outcome');
    expect(() => game.saveState(8), throwsRangeError);
  });

  test('no other call is sent after a saveState or loadState until its reply (protocol.md)', () async {
    await started();
    session.callResults['saveState'] = recording.calls('slots', 'saveState').first.reply['result'];
    session.callResults['option'] = true;
    final gate = session.callGate = Completer<void>();
    final saving = game.saveState(1);
    await pumpEventQueue();
    session.callGate = null;
    var refreshed = false;
    final waiting = [
      game.pause(true),
      game.refresh().then((_) => refreshed = true),
      game.setOption('k', 'v'),
      game.setVolume(level: 0),
    ];
    final loading = game.loadState(1);
    await pumpEventQueue();
    expect(session.calls.last.$1, 'saveState', reason: 'everything else waits for its reply');
    expect(refreshed, isFalse, reason: 'status waits too');
    gate.complete();
    expect(await saving, RetroStateOutcome.done);
    await Future.wait(waiting);
    await loading;
    final after = [for (final call in session.calls.skipWhile((call) => call.$1 != 'saveState').skip(1)) call.$1];
    expect(after, containsAll(['pause', 'option', 'volume', 'loadState']));
    expect(refreshed, isTrue);
  });

  test('a call asked behind a second saveState or loadState waits for that one too', () async {
    await started();
    session.callResults['saveState'] = recording.calls('slots', 'saveState').first.reply['result'];
    session.callResults['loadState'] = recording.calls('slots', 'loadState')[1].reply['result'];
    session.callResults['option'] = true;
    final first = session.callGate = Completer<void>();
    final saving = game.saveState(1);
    await pumpEventQueue();
    final loading = game.loadState(2);
    final option = game.setOption('k', 'v');
    final second = Completer<void>();
    session.onCall = (method, _) {
      if (method == 'loadState') session.callGate = second;
    };
    first.complete();
    expect(await saving, RetroStateOutcome.done);
    await pumpEventQueue();
    expect(session.calls.last.$1, 'loadState', reason: 'the option waits for the load it was asked behind');
    second.complete();
    expect(await loading, RetroStateOutcome.done);
    expect(await option, isTrue);
    expect(
      [for (final call in session.calls.skip(session.calls.length - 3)) call.$1],
      ['saveState', 'loadState', 'option'],
    );
  });

  test('a load answered false counts until a status asked after its reply says the game plays on', () async {
    await started();
    final states = RetroSaveStates(game, RetroStateFolder(folder: p.join(temp.path, 'states'), disc: request().disc));
    addTearDown(states.dispose);
    session.callResults['loadState'] = false;
    expect(await states.load(1), RetroStateOutcome.notNow);
    expect(states.loadAnsweredFalse, isTrue, reason: 'the status before the load says nothing of it');
    await game.refresh();
    expect(states.loadAnsweredFalse, isFalse, reason: 'a status asked after the reply says the game plays on');

    final gate = session.callGate = Completer<void>();
    final loading = states.load(1);
    await pumpEventQueue();
    session.callGate = null;
    final polled = game.refresh();
    gate.complete();
    expect(await loading, RetroStateOutcome.notNow);
    await polled;
    expect(states.loadAnsweredFalse, isFalse, reason: 'a status held behind the load is asked after its reply');

    expect(await states.load(1), RetroStateOutcome.notNow);
    expect(states.loadAnsweredFalse, isTrue, reason: 'a later load answered false counts again');
    session.nextStatus = fakeStatus(ended: true, errorCode: RetroErrorCode.other);
    await game.refresh();
    expect(game.phase, RetroHostGamePhase.ended);
    expect(states.loadAnsweredFalse, isTrue, reason: 'the load ended the game');
  });

  test('no game loaded is notNow, without a call', () async {
    expect(await game.saveState(0), RetroStateOutcome.notNow);
    expect(session.calls, isEmpty);
  });

  test('a save keeps the picture it is given beside the state, and the slots are read again', () async {
    await started();
    final states = RetroSaveStates(
      game,
      RetroStateFolder(folder: p.join(temp.path, 'states'), disc: request().disc),
      picture: (image, aspect) async => Uint8List.fromList([7, 7, 7]),
    );
    addTearDown(states.dispose);
    expect(states.available, isTrue);
    expect(states.anySaved, isFalse);
    session.callResults['saveState'] = recording.calls('slots', 'saveState').first.reply['result'];
    session.onCall = (method, args) {
      if (method != 'saveState') return;
      File(states.folder.statePath((args! as Map)['slot'] as int))
        ..createSync(recursive: true)
        ..writeAsBytesSync([1]);
    };
    expect(await states.save(4), RetroStateOutcome.done);
    expect(states.slot(4).empty, isFalse);
    expect(states.slot(4).picture, isNull, reason: 'no frame was shown, so no picture was kept');
    expect(File(states.folder.picturePath(4)).existsSync(), isFalse);
    expect(states.anySaved, isTrue);
  });

  test('a save that did not work takes the picture away, unless the core refused it', () async {
    await started();
    final states = RetroSaveStates(game, RetroStateFolder(folder: p.join(temp.path, 'states'), disc: request().disc));
    addTearDown(states.dispose);
    File(states.folder.statePath(2))
      ..createSync(recursive: true)
      ..writeAsBytesSync([1]);
    final picture = File(states.folder.picturePath(2))..writeAsBytesSync([9]);
    RetroCallError recorded(String code) {
      final error = recording
          .stateCalls()
          .map((exchange) => exchange.reply['error'])
          .whereType<Map<String, Object?>>()
          .firstWhere((error) => error['code'] == code);
      return RetroCallError(code, error['message']! as String);
    }

    session.callErrors['saveState'] = recorded(RetroCallError.coreRefused);
    expect(await states.save(2), RetroStateOutcome.coreRefused);
    expect(picture.readAsBytesSync(), [9], reason: 'the core gave no state: the slot is as it was');

    session.callErrors['saveState'] = recorded(RetroCallError.fileError);
    expect(await states.save(2), RetroStateOutcome.fileError);
    expect(picture.existsSync(), isFalse, reason: 'a late write may still put the new state in the slot');
    expect(states.slot(2).empty, isFalse);

    picture.writeAsBytesSync([9]);
    session.callErrors.clear();
    session.callResults['saveState'] = false;
    session.onCall = (method, args) => File(states.folder.statePath(2)).writeAsBytesSync([2]);
    expect(await states.save(2), RetroStateOutcome.notNow);
    expect(
      picture.existsSync(),
      isFalse,
      reason: 'a host that wrote the state and went away answers false, as the client reports a host failure',
    );
  });

  test('a game closed while its picture is made writes no picture', () async {
    await started();
    final drawing = Completer<Uint8List?>();
    final states = RetroSaveStates(
      game,
      RetroStateFolder(folder: p.join(temp.path, 'states'), disc: request().disc),
      picture: (image, aspect) => drawing.future,
    );
    session.callResults['saveState'] = recording.calls('slots', 'saveState').first.reply['result'];
    session.onCall = (method, args) => File(states.folder.statePath(0))
      ..createSync(recursive: true)
      ..writeAsBytesSync([1]);
    final frame = FakeSlot(4, 4)..fill([10, 20, 30, 255]);
    addTearDown(frame.free);
    session.send(frame.pin());
    for (var turn = 0; turn < 50 && game.picture.value == null; turn++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(game.picture.value, isNotNull);
    final saving = states.save(0);
    for (var turn = 0; turn < 50 && !File(states.folder.statePath(0)).existsSync(); turn++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await pumpEventQueue();
    states.dispose();
    drawing.complete(Uint8List.fromList([7]));
    expect(await saving, RetroStateOutcome.done);
    expect(File(states.folder.picturePath(0)).existsSync(), isFalse);
  });

  test('one save or load at a time; a slot found empty is read again', () async {
    await started();
    final states = RetroSaveStates(game, RetroStateFolder(folder: p.join(temp.path, 'states'), disc: request().disc));
    addTearDown(states.dispose);
    File(states.folder.statePath(1))
      ..createSync(recursive: true)
      ..writeAsBytesSync([1]);
    await states.refresh();
    expect(states.slot(1).empty, isFalse);

    final gate = Completer<void>();
    session.callGate = gate;
    session.callResults['loadState'] = recording.calls('slots', 'loadState')[1].reply['result'];
    final first = states.load(1);
    expect(states.busy, isTrue);
    expect(await states.save(2), RetroStateOutcome.notNow, reason: 'one at a time');
    gate.complete();
    expect(await first, RetroStateOutcome.done);
    expect(states.busy, isFalse);

    session.callGate = null;
    File(states.folder.statePath(1)).deleteSync();
    final noState = recording.calls('slots', 'loadState').last.reply['error']! as Map<String, Object?>;
    session.callErrors['loadState'] = RetroCallError(noState['code']! as String, noState['message']! as String);
    expect(await states.load(1), RetroStateOutcome.noState);
    expect(states.slot(1).empty, isTrue);
  });
}
