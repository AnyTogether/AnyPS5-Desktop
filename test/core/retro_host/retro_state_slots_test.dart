import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/retro_host/retro_host_protocol.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_session.dart';
import 'package:anyps5_desktop/core/retro_host/retro_state_slots.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../support/save_states_host_recording.dart';

void main() {
  final recording = SaveStatesHostRecording.load();
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('retro-states-'));
  tearDown(() => temp.deleteSync(recursive: true));

  test("a disc's name is the host's: the last part after a separator, without its extension", () {
    expect(RetroStateFolder.discName(r'C:\Games\Spyro (USA).cue', windows: true), 'Spyro (USA)');
    expect(RetroStateFolder.discName('C:/Games/Final Fantasy VII.m3u', windows: true), 'Final Fantasy VII');
    expect(RetroStateFolder.discName('/games/Jak.and.Daxter.iso', windows: false), 'Jak.and.Daxter');
    expect(
      RetroStateFolder.discName('/games/.hidden', windows: false),
      '.hidden',
      reason: 'a first dot is no extension',
    );
    expect(RetroStateFolder.discName('/games/noextension', windows: false), 'noextension');
    expect(RetroStateFolder.discName(r'/games/a\b.cue', windows: false), r'a\b', reason: r'\ is a letter on Linux');
  });

  test('the recorded host named each slot it saved as the launcher reads it', () {
    // Recorded on Windows, so its paths are read as the host read them there.
    final start = recording.calls('slots', 'start').single.call['args']! as Map<String, Object?>;
    final name = RetroStateFolder.discName(start['disc']! as String, windows: true);
    final saved = {
      for (final exchange in recording.calls('slots', 'saveState'))
        if (exchange.reply['result'] is Map) (exchange.call['args']! as Map)['slot'] as int,
    };
    expect(saved, {0, 3});
    expect(recording.files('slots'), [for (final slot in saved) '$name.$slot.state']);
    expect(
      p.basename(RetroStateFolder(folder: temp.path, disc: p.join(temp.path, 'game.cue')).statePath(3)),
      'game.3.state',
    );

    final ps2 = recording.calls('ps2-slot', 'start').single.call['args']! as Map<String, Object?>;
    final ps2Name = RetroStateFolder.discName(ps2['disc']! as String, windows: true);
    expect(recording.files('ps2-slot'), ['$ps2Name.1.state']);
  });

  test("the recorded host lists saveStates and took the launcher's start with its states folder", () {
    expect(recording.welcome('welcome')['capabilities'], contains(retroCapabilitySaveStates));
    final start = recording.calls('slots', 'start').single.call['args']! as Map<String, Object?>;
    final ours = RetroHostStartRequest(
      core: start['core']! as String,
      disc: start['disc']! as String,
      system: start['system']! as String,
      saves: start['saves']! as String,
      states: start['states']! as String,
    );
    expect(ours.toArgs(), start);
    expect(ours.withoutStates().toArgs(), {...start}..remove('states'));
    final ps2 = recording.calls('ps2-slot', 'start').single.call['args']! as Map<String, Object?>;
    expect(
      RetroHostStartRequest(
        console: RetroConsole.ps2,
        core: ps2['core']! as String,
        disc: ps2['disc']! as String,
        system: ps2['system']! as String,
        saves: ps2['saves']! as String,
        states: ps2['states']! as String,
      ).toArgs(),
      ps2,
    );
  });

  test('every error code the recorded host gave has its outcome', () {
    final codes = {
      for (final exchange in recording.stateCalls())
        if (exchange.reply['error'] case final Map<String, Object?> error) error['code']! as String,
    };
    expect(codes, {
      RetroCallError.argument,
      RetroCallError.noState,
      RetroCallError.badState,
      RetroCallError.otherGame,
      RetroCallError.otherCore,
      RetroCallError.coreRefused,
      RetroCallError.fileError,
    });
    expect(
      {for (final code in codes) code: RetroStateOutcome.ofError(code)},
      {
        RetroCallError.argument: RetroStateOutcome.failed,
        RetroCallError.noState: RetroStateOutcome.noState,
        RetroCallError.badState: RetroStateOutcome.badState,
        RetroCallError.otherGame: RetroStateOutcome.otherGame,
        RetroCallError.otherCore: RetroStateOutcome.otherCore,
        RetroCallError.coreRefused: RetroStateOutcome.coreRefused,
        RetroCallError.fileError: RetroStateOutcome.fileError,
      },
    );
    expect(RetroStateOutcome.ofError('aCodeOfALaterHost'), RetroStateOutcome.failed);
  });

  test('the slots: empty without a file, saved at its time with the picture kept beside it', () async {
    final folder = RetroStateFolder(folder: temp.path, disc: p.join('games', 'Night Racer.cue'));
    expect([for (final slot in await folder.read()) slot.empty], List.filled(RetroStateFolder.slots, true));

    final at = DateTime(2026, 11, 18, 14, 3);
    File(folder.statePath(2))
      ..writeAsBytesSync([1, 2, 3])
      ..setLastModifiedSync(at);
    File(folder.statePath(5)).writeAsBytesSync([4]);
    Directory(folder.statePath(6)).createSync();
    File(p.join(temp.path, 'Other Game.1.state')).writeAsBytesSync([5]);
    final png = Uint8List.fromList([137, 80, 78, 71]);
    await folder.keepPicture(2, png);
    File(folder.picturePath(2)).setLastModifiedSync(at.add(const Duration(seconds: 1)));
    File(folder.picturePath(5)).writeAsBytesSync(Uint8List(RetroStateFolder.pictureLimit + 1));

    final slots = await folder.read();
    expect([for (final slot in slots) slot.slot], [0, 1, 2, 3, 4, 5, 6, 7]);
    expect(
      [
        for (final slot in slots)
          if (!slot.empty) slot.slot,
      ],
      [2, 5],
      reason: 'a folder is no state',
    );
    expect(slots[2].savedAt, at);
    expect(slots[2].picture, png);
    expect(slots[5].picture, isNull, reason: 'a picture far larger than one the launcher writes is left out');
    expect(p.basename(folder.statePath(2)), 'Night Racer.2.state');
    expect(p.basename(folder.picturePath(2)), 'Night Racer.2.png');
  });

  test('a picture older than its state is of a state before, and is not shown', () async {
    final folder = RetroStateFolder(folder: temp.path, disc: 'game.cue');
    File(folder.picturePath(3))
      ..writeAsBytesSync([9])
      ..setLastModifiedSync(DateTime(2026, 11, 1));
    File(folder.statePath(3))
      ..writeAsBytesSync([1])
      ..setLastModifiedSync(DateTime(2026, 11, 2));
    final slot = (await folder.read())[3];
    expect(slot.empty, isFalse);
    expect(slot.picture, isNull, reason: 'a picture a failed save could not take away stays out of sight');
  });

  test('a picture is put in place whole, and a save without one takes the old one away', () async {
    final folder = RetroStateFolder(folder: temp.path, disc: 'game.cue');
    await folder.keepPicture(0, Uint8List.fromList([1]));
    await folder.keepPicture(0, Uint8List.fromList([2, 2]));
    expect(File(folder.picturePath(0)).readAsBytesSync(), [2, 2]);
    expect(temp.listSync().map((entry) => p.basename(entry.path)), ['game.0.png'], reason: 'nothing left beside it');
    await folder.keepPicture(0, null);
    expect(File(folder.picturePath(0)).existsSync(), isFalse);
    await folder.keepPicture(1, null);
  });

  test('a picture that cannot be written leaves none behind', () async {
    final folder = RetroStateFolder(folder: p.join(temp.path, 'missing'), disc: 'game.cue');
    await expectLater(folder.keepPicture(0, Uint8List.fromList([1])), throwsA(isA<FileSystemException>()));
    expect(File(folder.picturePath(0)).existsSync(), isFalse);
  });
}
