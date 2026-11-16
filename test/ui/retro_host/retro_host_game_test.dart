import 'dart:async';
import 'dart:convert';

import 'package:anyps5_desktop/core/retro_host/retro_host_client.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_protocol.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_session.dart';
import 'package:anyps5_desktop/ui/retro_host/retro_host_game.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_retro_host_session.dart';

const _request = RetroHostStartRequest(
  core: '/cores/swanstation_libretro.so',
  disc: '/games/FF7.m3u',
  system: '/retro/system',
  saves: '/retro/saves/ps1',
  options: {'swanstation_GPU_ResolutionScale': '4'},
  initialDisc: 1,
);

/// The `status` example of anyps5-retro-host docs/protocol.md "status".
const _protocolStatus =
    '{"ready":true,"ended":false,"error":"","errorCode":"","aspect":1.3333333333333333,"hardware":true,'
    '"resolutionError":"","graphicsPending":false,"progressLabel":null,"progressPercent":null,'
    '"options":{"swanstation_GPU_ResolutionScale":{"title":"Internal Resolution","values":["1","2","4"],'
    '"labels":["1x","2x","4x"],"selected":2,"activeValue":"4","restart":false}},'
    '"discs":{"labels":["Disc 1","Disc 2"],"inserted":0,"insertedDiscPath":"D:\\\\Games\\\\PS1\\\\FF7\\\\FF7 (Disc 1).cue",'
    '"playedDiscPath":"D:\\\\Games\\\\PS1\\\\FF7\\\\FF7 (Disc 1).cue","busy":false,"failed":false}}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeRetroHostSession session;
  late RetroHostGame game;

  setUp(() {
    session = FakeRetroHostSession();
    game = RetroHostGame(session, statusEvery: const Duration(hours: 1));
  });

  tearDown(() => game.dispose());

  Future<void> started({RetroStatus? status}) async {
    session.readyCompleter.complete();
    session.nextStatus = status ?? fakeStatus(ready: false);
    await game.start(_request);
  }

  test('start waits for the greeting, then sends the protocol\'s start argument', () async {
    final starting = game.start(_request);
    expect(game.phase, RetroHostGamePhase.starting);
    expect(session.startArgs, isNull);
    session.readyCompleter.complete();
    session.nextStatus = fakeStatus(ready: false);
    await starting;
    expect(session.startArgs, {
      'core': '/cores/swanstation_libretro.so',
      'disc': '/games/FF7.m3u',
      'system': '/retro/system',
      'saves': '/retro/saves/ps1',
      'options': {'swanstation_GPU_ResolutionScale': '4'},
      'initialDisc': 1,
    });
    expect(game.phase, RetroHostGamePhase.loading);
  });

  test('a request without options or a playlist entry leaves both out', () {
    const plain = RetroHostStartRequest(core: 'c', disc: 'd.cue', system: 's', saves: 'v');
    expect(plain.toArgs(), {'core': 'c', 'disc': 'd.cue', 'system': 's', 'saves': 'v'});
  });

  test('a ready status starts play and its aspect ratio is kept', () async {
    await started();
    session.nextStatus = RetroStatus.parse(jsonDecode(_protocolStatus) as Map<String, Object?>);
    await game.refresh();
    expect(game.phase, RetroHostGamePhase.playing);
    expect(game.aspect, closeTo(4 / 3, 1e-12));
    session.nextStatus = fakeStatus(aspect: 1.5);
    await game.refresh();
    expect(game.aspect, 1.5);
  });

  test('input reaches the host only while a game is loaded and the window has focus', () async {
    game.input(0, 1);
    await started(status: fakeStatus());
    game.input(0, 8);
    await game.setFocused(false);
    game.input(1, 4);
    await game.setFocused(true);
    game.input(1, 2);
    expect(session.inputs, [(0, 8), (1, 2)]);
  });

  test('losing focus pauses the game and zeroes input; getting it back resumes', () async {
    await started(status: fakeStatus());
    await game.setFocused(false);
    expect(session.focusChanges, [false]);
    expect(game.paused, isTrue);
    await game.setFocused(true);
    expect(session.focusChanges, [false, true]);
    expect(game.paused, isFalse);
    expect(session.calls, [('pause', true), ('pause', false)]);
  });

  test('a game the player paused stays paused when focus comes back', () async {
    await started(status: fakeStatus());
    await game.pause(true);
    await game.setFocused(false);
    await game.setFocused(true);
    expect(game.paused, isTrue);
    expect(session.calls, [('pause', true)]);
    await game.pause(false);
    expect(session.calls, [('pause', true), ('pause', false)]);
  });

  test('a game started without focus is paused as soon as it loads', () async {
    await game.setFocused(false);
    await started();
    expect(session.calls, [('pause', true)]);
    expect(game.paused, isTrue);
  });

  test('an ended status ends the game and keeps why', () async {
    await started(status: fakeStatus());
    session.nextStatus = fakeStatus(ended: true, errorCode: RetroErrorCode.bios);
    await game.refresh();
    expect(game.phase, RetroHostGamePhase.ended);
    expect(game.endStatus?.errorCode, RetroErrorCode.bios);
    expect(game.picture.value, isNull);
  });

  test('a refused start ends the game with the reason', () async {
    session.startError = const RetroCallError(RetroCallError.busy, 'A game is loaded.');
    session.readyCompleter.complete();
    await game.start(_request);
    expect(game.phase, RetroHostGamePhase.ended);
    expect(game.failure, contains('busy'));
  });

  test('a host that never greets ends the game', () async {
    final starting = game.start(_request);
    session.readyCompleter.completeError(const RetroHostGone(RetroHostEnd.hostFailure));
    session.endedCompleter.complete(RetroHostEnd.hostFailure);
    await starting;
    expect(game.phase, RetroHostGamePhase.ended);
    expect(session.startArgs, isNull);
  });

  test('a host failure while playing shows the client\'s failure report', () async {
    await started(status: fakeStatus());
    session.nextStatus = const RetroStatus.failed(
      error: 'The emulator closed unexpectedly.',
      errorCode: RetroErrorCode.hostExited,
    );
    session.endedCompleter.complete(RetroHostEnd.hostFailure);
    await pumpEventQueue();
    expect(game.phase, RetroHostGamePhase.ended);
    expect(game.endStatus?.errorCode, RetroErrorCode.hostExited);
  });

  test('stop while waiting for the greeting cancels the game before start is sent', () async {
    final starting = game.start(_request);
    final stopping = game.stop();
    session.readyCompleter.complete();
    await Future.wait([starting, stopping]);
    expect(session.startArgs, isNull);
    expect(session.calls, isEmpty);
    expect(game.phase, RetroHostGamePhase.ended);
  });

  test('stop while start is waiting for its reply stops the game the host then starts', () async {
    session.startGate = Completer<void>();
    session.readyCompleter.complete();
    final starting = game.start(_request);
    await pumpEventQueue();
    expect(session.startArgs, isNotNull);
    final stopping = game.stop();
    session.startGate!.complete();
    await Future.wait([starting, stopping]);
    expect(session.calls, [('stop', null), ('release', null)]);
    expect(game.phase, RetroHostGamePhase.ended);
  });

  test('frames that come after the game ended or during shutdown are not shown', () async {
    final slot = FakeSlot(1, 1)..fill([1, 2, 3, 255]);
    addTearDown(slot.free);
    await started(status: fakeStatus());
    session.nextStatus = fakeStatus(ended: true);
    await game.refresh();
    session.send(slot.pin());
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(game.picture.shown, 0);
    final closing = game.shutdown();
    session.send(slot.pin());
    await closing;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(game.picture.value, isNull);
    expect(game.picture.shown, 0);
  });

  test('disposing before a game is started leaves no unhandled error when the host is gone', () async {
    game.dispose();
    session.readyCompleter.completeError(const RetroHostGone(RetroHostEnd.hostFailure));
    await pumpEventQueue();
    game = RetroHostGame(FakeRetroHostSession());
  });

  test('focus changes after shutdown or a host failure do not reach the closed session', () async {
    await started(status: fakeStatus());
    await game.shutdown();
    await game.setFocused(false);
    expect(game.focused, isFalse);
    expect(session.focusChanges, isEmpty);

    final failed = FakeRetroHostSession();
    final other = RetroHostGame(failed, statusEvery: const Duration(hours: 1));
    addTearDown(other.dispose);
    failed.readyCompleter.complete();
    failed.nextStatus = fakeStatus();
    await other.start(_request);
    failed.nextStatus = const RetroStatus.failed(error: 'gone', errorCode: RetroErrorCode.hostExited);
    failed.endedCompleter.complete(RetroHostEnd.hostFailure);
    await pumpEventQueue();
    failed.closed = true;
    await other.setFocused(false);
    expect(failed.focusChanges, isEmpty);
  });

  test('stop stops the game, releases it and gives the status it ended with', () async {
    await started(status: fakeStatus());
    final ended = await game.stop();
    expect(ended?.ended, isTrue);
    expect(session.calls, [('stop', null), ('release', null)]);
    expect(game.phase, RetroHostGamePhase.ended);
  });

  test('shutdown asks the host to exit and frees the connection once it has', () async {
    await started(status: fakeStatus());
    final first = game.shutdown();
    final second = game.shutdown();
    await Future.wait([first, second]);
    expect(session.shutdownAsked, isTrue);
    expect(session.closed, isTrue);
    expect(game.phase, RetroHostGamePhase.closed);
    game.input(0, 1);
    expect(session.inputs, isEmpty);
  });

  test('dispose shuts the host down', () async {
    await started(status: fakeStatus());
    game.dispose();
    await pumpEventQueue();
    expect(session.shutdownAsked, isTrue);
    expect(session.closed, isTrue);
    game = RetroHostGame(FakeRetroHostSession());
  });

  test('detach stops and forgets the game and leaves the host running for the next one', () async {
    await started(status: fakeStatus());
    await game.setFocused(false);
    session.focusChanges.clear();
    final first = game.detach();
    final second = game.detach();
    expect(await first, isTrue);
    expect(await second, isTrue);
    expect(session.calls.map((call) => call.$1), containsAllInOrder(['stop', 'release']));
    expect(session.shutdownAsked, isFalse);
    expect(session.closed, isFalse);
    expect(game.phase, RetroHostGamePhase.closed);
    expect(session.focusChanges, [true], reason: 'the next game starts with focus, as a new host does');
    game.input(0, 1);
    expect(session.inputs, isEmpty, reason: 'a detached game sends nothing');
    game.dispose();
    await pumpEventQueue();
    expect(session.shutdownAsked, isFalse, reason: 'the host is no longer the game\'s');

    final next = RetroHostGame(session, statusEvery: const Duration(hours: 1));
    session.nextStatus = fakeStatus();
    await next.start(_request);
    expect(next.phase, RetroHostGamePhase.playing);
    next.dispose();
    await pumpEventQueue();
    expect(session.shutdownAsked, isTrue);
    game = RetroHostGame(FakeRetroHostSession());
  });

  test('detach releases a game that ended on its own', () async {
    await started(status: fakeStatus());
    session.nextStatus = fakeStatus(ended: true, errorCode: RetroErrorCode.stalled);
    await game.refresh();
    expect(game.phase, RetroHostGamePhase.ended);
    session.calls.clear();
    expect(await game.detach(), isTrue);
    expect(session.calls, [('release', null)]);
  });

  test('detach shuts the host down when it still holds a game after release', () async {
    await started(status: fakeStatus());
    session.stopStatus = fakeStatus();
    expect(await game.detach(), isFalse);
    expect(session.shutdownAsked, isTrue);
    expect(session.closed, isTrue);
  });

  test('detach shuts the host down when release or status fails', () async {
    await started(status: fakeStatus());
    session.statusError = const RetroCallError(RetroCallError.argument, 'refused');
    expect(await game.detach(), isFalse);
    expect(session.shutdownAsked, isTrue);
  });

  test('detach after the host ended keeps nothing', () async {
    await started(status: fakeStatus());
    session.nextStatus = const RetroStatus.failed(
      error: 'The emulator closed unexpectedly.',
      errorCode: RetroErrorCode.hostExited,
    );
    session.endedCompleter.complete(RetroHostEnd.hostFailure);
    await pumpEventQueue();
    expect(await game.detach(), isFalse);
    expect(session.closed, isTrue);
  });

  test('detach after shutdown keeps nothing', () async {
    await started(status: fakeStatus());
    await game.shutdown();
    expect(await game.detach(), isFalse);
  });
}
