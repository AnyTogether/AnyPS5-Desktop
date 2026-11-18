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
