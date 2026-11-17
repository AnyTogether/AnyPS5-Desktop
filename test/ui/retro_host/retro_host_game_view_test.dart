import 'dart:ui' as ui;

import 'package:anyps5_desktop/core/controllers/pad_info.dart';
import 'package:anyps5_desktop/core/gamepad/pad_navigation.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_session.dart';
import 'package:anyps5_desktop/core/retro_host/retro_pad.dart';
import 'package:anyps5_desktop/ui/retro_host/retro_frame_view.dart';
import 'package:anyps5_desktop/ui/retro_host/retro_host_controls.dart';
import 'package:anyps5_desktop/ui/retro_host/retro_host_game.dart';
import 'package:anyps5_desktop/ui/retro_host/retro_host_game_view.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_retro_host_session.dart';

const _request = RetroHostStartRequest(core: 'c', disc: 'd.cue', system: 's', saves: 'v');

Widget _framed(Widget child) => Directionality(
  textDirection: TextDirection.ltr,
  child: Center(child: SizedBox(width: 800, height: 400, child: child)),
);

void _expectSize(Size actual, Size expected) {
  expect(actual.width, closeTo(expected.width, 1e-9));
  expect(actual.height, closeTo(expected.height, 1e-9));
}

void main() {
  testWidgets('the frame view letterboxes its picture to the aspect ratio', (tester) async {
    final image = ValueNotifier<ui.Image?>(null);
    await tester.pumpWidget(_framed(RetroFrameView(image: image, aspect: 4 / 3)));
    expect(find.byType(RawImage), findsNothing);
    _expectSize(tester.getSize(find.byType(AspectRatio)), const Size(400 * 4 / 3, 400));

    final picture = await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(const Color(0xff00ff00), BlendMode.src);
      return recorder.endRecording().toImage(4, 3);
    });
    image.value = picture;
    await tester.pump();
    expect(tester.widget<RawImage>(find.byType(RawImage)).image!.isCloneOf(picture!), isTrue);
    _expectSize(tester.getSize(find.byType(RawImage)), const Size(400 * 4 / 3, 400));

    await tester.pumpWidget(_framed(RetroFrameView(image: image, aspect: 2)));
    expect(tester.getSize(find.byType(AspectRatio)), const Size(800, 400));
    await tester.pumpWidget(const SizedBox());
    picture.dispose();
    image.dispose();
  });

  testWidgets('a view mounted while the window has no focus tells the game at once', (tester) async {
    final session = FakeRetroHostSession();
    final game = RetroHostGame(session, statusEvery: const Duration(hours: 1));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpWidget(_framed(RetroHostGameView(game: game)));
    await tester.pump();
    expect(game.focused, isFalse);
    expect(session.focusChanges, [false]);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(game.focused, isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      game.dispose();
      await pumpEventQueue();
    });
  });

  testWidgets('the game view shows the host\'s frames at the status aspect and pauses on focus loss', (tester) async {
    final session = FakeRetroHostSession();
    final game = RetroHostGame(session, statusEvery: const Duration(hours: 1));
    final slot = FakeSlot(4, 2)..fill([255, 0, 0, 255]);
    addTearDown(slot.free);

    await tester.pumpWidget(_framed(RetroHostGameView(game: game)));
    session.readyCompleter.complete();
    session.nextStatus = fakeStatus(aspect: 2);
    await tester.runAsync(() => game.start(_request));
    await tester.pump();
    expect(game.phase, RetroHostGamePhase.playing);
    expect(tester.getSize(find.byType(AspectRatio)), const Size(800, 400));
    expect(find.byType(RawImage), findsNothing);

    session.send(slot.pin());
    for (var i = 0; i < 200 && game.picture.shown == 0; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
    }
    expect(game.picture.shown, 1);
    await tester.pump();
    final shown = tester.widget<RawImage>(find.byType(RawImage)).image!;
    expect((shown.width, shown.height), (4, 2));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(game.paused, isTrue);
    expect(session.calls, [('pause', true)]);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(game.paused, isFalse);
    expect(session.calls, [('pause', true), ('pause', false)]);

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      game.dispose();
      await pumpEventQueue();
    });
    expect(session.closed, isTrue);
  });

  testWidgets('a controller held while the window loses focus reaches the game again when it comes back', (
    tester,
  ) async {
    final session = FakeRetroHostSession();
    final game = RetroHostGame(session, statusEvery: const Duration(hours: 1));
    var state = const PadState(pressed: {PadButton.south});
    final controls = RetroHostControls(
      game,
      pads: RetroPadReader(pads: () => const ['pad'], state: (_) => state),
    );
    await tester.pumpWidget(_framed(RetroHostGameView(game: game)));
    session.readyCompleter.complete();
    session.nextStatus = fakeStatus();
    await tester.runAsync(() => game.start(_request));
    await tester.pump(const Duration(milliseconds: 20));
    final cross = RetroPadInput(buttons: RetroPadButton.cross.mask);
    expect(session.inputStates, [(0, cross), (1, RetroPadInput.idle)]);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    state = const PadState(pressed: {PadButton.south, PadButton.start});
    await tester.pump(const Duration(milliseconds: 100));
    expect(session.inputStates, hasLength(2));
    expect(session.focusChanges, [false]);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 20));
    expect(session.inputStates.skip(2), [
      (0, RetroPadInput(buttons: RetroPadButton.cross.mask | RetroPadButton.start.mask)),
      (1, RetroPadInput.idle),
    ]);

    controls.dispose();
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      game.dispose();
      await pumpEventQueue();
    });
  });
}
