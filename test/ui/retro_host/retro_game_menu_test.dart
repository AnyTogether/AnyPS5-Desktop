import 'dart:async';
import 'dart:convert';

import 'package:anyps5_desktop/core/retro_host/retro_host_protocol.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_session.dart';
import 'package:anyps5_desktop/ui/retro_host/retro_game_menu.dart';
import 'package:anyps5_desktop/ui/retro_host/retro_host_controls.dart';
import 'package:anyps5_desktop/ui/retro_host/retro_host_game.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_retro_host_session.dart';

const _request = RetroHostStartRequest(core: 'c', disc: 'd.m3u', system: 's', saves: 'v');

/// The `status` example of anyps5-retro-host docs/protocol.md "status", with the disc and option
/// fields the test changes.
RetroStatus _status({
  int? inserted = 0,
  bool busy = false,
  bool failed = false,
  int selected = 2,
  String active = '4',
}) => RetroStatus.parse(
  jsonDecode(
    '{"ready":true,"ended":false,"error":"","errorCode":"","aspect":1.3333333333333333,"hardware":true,'
    '"resolutionError":"","graphicsPending":false,"progressLabel":null,"progressPercent":null,'
    '"options":{"swanstation_GPU_ResolutionScale":{"title":"Internal Resolution","values":["1","2","4"],'
    '"labels":["1x","2x","4x"],"selected":$selected,"activeValue":"$active","restart":false}},'
    '"discs":{"labels":["Disc 1","Disc 2"],"inserted":${jsonEncode(inserted)},'
    '"insertedDiscPath":"D:\\\\Games\\\\PS1\\\\FF7\\\\FF7 (Disc 1).cue",'
    '"playedDiscPath":"D:\\\\Games\\\\PS1\\\\FF7\\\\FF7 (Disc 1).cue","busy":$busy,"failed":$failed}}',
  ) as Map<String, Object?>,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeRetroHostSession session;
  late RetroHostGame game;
  late RetroGameMenu menu;

  setUp(() {
    session = FakeRetroHostSession();
    game = RetroHostGame(session, statusEvery: const Duration(hours: 1), volume: 0.5);
    menu = RetroGameMenu(game);
  });

  tearDown(() {
    menu.dispose();
    game.dispose();
  });

  Future<void> started([RetroStatus? status]) async {
    session.readyCompleter.complete();
    session.nextStatus = status ?? _status();
    await game.start(_request);
  }

  test('the rows are the discs, the options and the volume from the protocol\'s status', () async {
    expect(menu.rows, [const RetroVolumeRow(level: 0.5, muted: false)]);
    await started();
    final rows = menu.rows;
    expect(rows.whereType<RetroDiscRow>(), [
      const RetroDiscRow(index: 0, label: 'Disc 1', inserted: true, enabled: false),
      const RetroDiscRow(index: 1, label: 'Disc 2', inserted: false, enabled: true),
    ]);
    final option = rows.whereType<RetroOptionRow>().single;
    expect(option.key, 'swanstation_GPU_ResolutionScale');
    expect(option.title, 'Internal Resolution');
    expect(option.choice, '4x');
    expect(option.pending, isFalse);
    expect(option.restartNeeded, isFalse);
    expect(rows.last, const RetroVolumeRow(level: 0.5, muted: false));
  });

  test('a single-disc game has no disc rows; an open tray or a change in progress blocks them', () {
    expect(RetroGameMenu.rowsFor(fakeStatus(), volume: 1, muted: false), [
      const RetroVolumeRow(level: 1, muted: false),
    ]);
    final open = RetroGameMenu.rowsFor(_status(inserted: null), volume: 1, muted: false).whereType<RetroDiscRow>();
    expect(open.map((row) => row.enabled), [true, true]);
    final busy = RetroGameMenu.rowsFor(_status(busy: true), volume: 1, muted: false).whereType<RetroDiscRow>();
    expect(busy.map((row) => row.enabled), [false, false]);
  });

  test('choosing a disc sends changeDisc and asks status at once', () async {
    await started();
    session.callResults['changeDisc'] = true;
    session.nextStatus = _status(busy: true);
    final disc = menu.rows.whereType<RetroDiscRow>().last;
    expect(await menu.chooseDisc(disc), isTrue);
    expect(session.calls, [('changeDisc', 1)]);
    expect(menu.rows.whereType<RetroDiscRow>().every((row) => !row.enabled), isTrue);
    expect(await menu.chooseDisc(disc), isFalse);
    expect(session.calls, hasLength(1));
  });

  test('a refused disc change and a failed one are told apart', () async {
    await started();
    session.callResults['changeDisc'] = false;
    expect(await menu.chooseDisc(menu.rows.whereType<RetroDiscRow>().last), isFalse);
    session.nextStatus = _status(failed: true);
    await game.refresh();
    expect(menu.discChangeFailed, isTrue);
  });

  test('an option steps through its values and stops at the ends', () async {
    await started();
    session.callResults['option'] = true;
    expect(await menu.stepOption('swanstation_GPU_ResolutionScale', 1), isFalse);
    session.nextStatus = _status(selected: 1);
    expect(await menu.stepOption('swanstation_GPU_ResolutionScale', -1), isTrue);
    expect(session.calls.single.$1, 'option');
    expect(session.calls.single.$2, {'key': 'swanstation_GPU_ResolutionScale', 'value': '2'});
    final option = menu.rows.whereType<RetroOptionRow>().single;
    expect(option.choice, '2x');
    expect(option.pending, isTrue);
    expect(await menu.stepOption('unknown', 1), isFalse);
  });

  test('volume steps by tenths, turning it up unmutes, and mute toggles', () async {
    await started();
    await menu.toggleMute();
    await menu.stepVolume(-6);
    expect((game.volume, game.muted), (0.0, true));
    await menu.stepVolume(3);
    expect(game.volume, 0.3, reason: 'whole tenths, not 3 × 0.1');
    expect(game.muted, isFalse);
    await menu.stepVolume(20);
    expect(game.volume, 1.0);
    expect(session.calls.map((call) => call.$2), [
      {'level': 0.5, 'muted': true},
      {'level': 0.0, 'muted': true},
      {'level': 0.3, 'muted': false},
      {'level': 1.0, 'muted': false},
    ]);
  });

  test('volume set before the host greets the launcher is sent once it does', () async {
    final pending = game.setVolume(level: 0.2);
    expect(session.calls, isEmpty);
    session.readyCompleter.complete();
    await pending;
    expect(session.calls.single.$1, 'volume');
    expect(session.calls.single.$2, {'level': 0.2, 'muted': false});
  });

  test('opening the menu pauses the game and keeps the controllers out; closing gives both back', () async {
    final controls = RetroHostControls(
      game,
      pads: RetroPadReader(pads: () => const [], state: (_) => null),
      every: const Duration(hours: 1),
    );
    addTearDown(controls.dispose);
    final withControls = RetroGameMenu(game, controls: controls);
    addTearDown(withControls.dispose);
    await withControls.open();
    expect(withControls.isOpen, isFalse);
    await started();
    await withControls.open();
    expect(withControls.isOpen, isTrue);
    expect(game.paused, isTrue);
    expect(controls.suspended, isTrue);
    await withControls.close();
    expect(game.paused, isFalse);
    expect(controls.suspended, isFalse);
    expect(session.calls, [('pause', true), ('pause', false)]);
  });

  test('opening the menu again while closing waits on the host keeps the controllers out', () async {
    final controls = RetroHostControls(
      game,
      pads: RetroPadReader(pads: () => const [], state: (_) => null),
      every: const Duration(hours: 1),
    );
    addTearDown(controls.dispose);
    final withControls = RetroGameMenu(game, controls: controls);
    addTearDown(withControls.dispose);
    await started();
    await withControls.open();
    final gate = session.callGate = Completer<void>();
    final closing = withControls.close();
    final opening = withControls.open();
    gate.complete();
    await Future.wait([closing, opening]);
    expect(withControls.isOpen, isTrue);
    expect(game.paused, isTrue);
    expect(controls.suspended, isTrue);
  });

  test('disposing an open menu gives the game back its controllers', () async {
    final controls = RetroHostControls(
      game,
      pads: RetroPadReader(pads: () => const [], state: (_) => null),
      every: const Duration(hours: 1),
    );
    addTearDown(controls.dispose);
    final withControls = RetroGameMenu(game, controls: controls);
    await started();
    await withControls.open();
    withControls.dispose();
    await pumpEventQueue();
    expect(controls.suspended, isFalse);
    expect(game.paused, isFalse);
  });
}
