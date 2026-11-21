import 'package:anyps5_desktop/core/controllers/pad_info.dart';
import 'package:anyps5_desktop/core/controllers/pad_inventory.dart';
import 'package:anyps5_desktop/core/controllers/pad_reader.dart';
import 'package:anyps5_desktop/core/controllers/sdl_pads.dart';
import 'package:anyps5_desktop/core/controllers/sdl_worker.dart';
import 'package:anyps5_desktop/core/gamepad/feel.dart';
import 'package:anyps5_desktop/core/gamepad/pad_navigation.dart';
import 'package:test/test.dart';

import '../../support/fake_sdl.dart';

/// A plain joystick SDL has no mapping for.
const joystick = SdlDevice(instance: 9, index: 9, gameController: false, name: 'Some Joystick');

/// A reader that only lists what it is given (the fallback in these tests).
class ListedSource implements PadSource, PadInventory, PadRumble {
  ListedSource(this.listed);
  final List<PadInfo> listed;
  bool started = false;
  void Function()? changed;

  @override
  void start(void Function(PadEvent event) onEvent) => started = true;
  @override
  void stop() => started = false;
  @override
  String get description => 'evdev: ${listed.map((pad) => pad.name).join(', ')}';
  @override
  PadRumble? get motors => this;
  @override
  bool canRumble(String pad) => true;
  @override
  void rumble(String pad, double strong, double weak, Duration length) {}
  @override
  List<PadInfo> get pads => listed;
  @override
  set onPadsChanged(void Function()? listener) => changed = listener;
  @override
  PadState? state(String id) => null;
  @override
  bool setLight(String id, int red, int green, int blue) => false;
  @override
  void setPlayerLights(List<String> ordered) {}
  @override
  String get readerName => 'evdev';
  @override
  List<String> get refused => const [];
}

void main() {
  group('SdlWorkerLoop', () {
    test('opens every game controller, lists the rest, lets go of the ones gone', () {
      final sdl = FakeSdl()
        ..plug(dualSense(1), power: 2)
        ..plug(joystick)
        ..serials[1] = 'a0:ab:51:00:00:01';
      final loop = SdlWorkerLoop(sdl);
      sdl.hold(1, {0}, power: 2);
      final frame = loop.tick();
      expect(frame.devices.map((device) => device.instance), [1, 9]);
      expect(frame.open.keys, [1]);
      expect(frame.open[1]!.reading!.held, {0});
      expect(frame.open[1]!.serial, 'a0:ab:51:00:00:01');
      expect(frame.open[1]!.hasRumble, isTrue);
      sdl.unplug(1);
      expect(loop.tick().open, isEmpty);
      expect(sdl.calls, contains('close 1'));
    });

    test('a frame goes out when it changed, and once a second regardless', () {
      final sdl = FakeSdl()..plug(dualSense(1));
      final loop = SdlWorkerLoop(sdl);
      expect(loop.shouldSend(loop.tick(), heartbeat: 3), isTrue);
      expect(loop.shouldSend(loop.tick(), heartbeat: 3), isFalse);
      expect(loop.shouldSend(loop.tick(), heartbeat: 3), isFalse);
      expect(loop.shouldSend(loop.tick(), heartbeat: 3), isTrue, reason: 'the heartbeat');
      sdl.hold(1, {1});
      expect(loop.shouldSend(loop.tick(), heartbeat: 3), isTrue);
    });

    test('the launcher\'s commands reach SDL', () {
      final sdl = FakeSdl()..plug(dualSense(1));
      final loop = SdlWorkerLoop(sdl)..tick();
      loop
        ..command(('rumble', 1, [65535, 0, 120]))
        ..command(('led', 1, [0, 0, 255]))
        ..command(('player', 1, [0]))
        ..quit();
      expect(sdl.calls, containsAll(['rumble 1 65535 0 120', 'led 1 0 0 255', 'player 1 0', 'rumble 1 0 0 0']));
      expect(sdl.quitCalled, isTrue);
    });
  });

  group('SdlIsolateBackend', () {
    test('the reader sees the worker\'s frames as SDL itself', () {
      final backend = SdlIsolateBackend(spawn: false);
      addTearDown(backend.quit);
      final sdl = FakeSdl()..plug(dualSense(1));
      final loop = SdlWorkerLoop(sdl);
      backend
        ..receive(const SdlWorkerStarted('2.30.0'))
        ..receive(loop.tick());
      final source = SdlPadSource(backend);
      final events = <PadEvent>[];
      source.start(events.add);
      addTearDown(source.stop);
      expect(source.pads.single.name, 'PS5 Controller');
      expect(source.readerName, 'SDL 2.30.0');
      sdl.hold(1, {0});
      backend.receive(loop.tick());
      source.poll();
      expect(events.whereType<PadButtonEvent>().where((event) => event.down).single.button, PadButton.south);
    });

    test('a worker that never finishes starting is stuck', () {
      final failures = <(String, bool)>[];
      final backend = SdlIsolateBackend(spawn: false, startTicks: 3)
        ..onFailed = (why, {required stalled}) => failures.add((why, stalled));
      addTearDown(backend.quit);
      backend.watchTick();
      backend.watchTick();
      expect(failures, isEmpty);
      backend.watchTick();
      expect(failures.single.$2, isTrue);
      expect(failures.single.$1, contains('did not finish starting'));
      backend.watchTick();
      expect(failures, hasLength(1), reason: 'told once');
    });

    test('a started worker that goes quiet is stuck; one that answers is not', () {
      final failures = <String>[];
      final backend = SdlIsolateBackend(spawn: false, silentTicks: 2)..onFailed = (why, {required stalled}) => failures.add(why);
      addTearDown(backend.quit);
      backend.receive(const SdlWorkerStarted('2.30.0'));
      for (var second = 0; second < 5; second++) {
        backend
          ..receive(SdlFrame.empty)
          ..watchTick();
      }
      expect(failures, isEmpty);
      backend
        ..watchTick()
        ..watchTick();
      expect(failures.single, contains('stopped answering'));
      expect(backend.devices(), isEmpty);
    });

    test('a worker without SDL2 says why, not stuck', () {
      final failures = <(String, bool)>[];
      final backend = SdlIsolateBackend(spawn: false)..onFailed = (why, {required stalled}) => failures.add((why, stalled));
      addTearDown(backend.quit);
      backend.receive(const SdlWorkerFailed('SDL_InitSubSystem failed'));
      expect(failures, [('SDL_InitSubSystem failed', false)]);
    });
  });

  group('FallbackPadSource', () {
    test('hands over to the fallback: the pads held are let go, the listeners carried over', () {
      final sdl = FakeSdl()..plug(dualSense(1));
      final first = SdlPadSource(sdl);
      const evdevPad = PadInfo(id: 'event21', name: 'DualSense', kind: PadKind.dualSense, driver: 'evdev');
      final fallback = ListedSource([evdevPad]);
      final reader = FallbackPadSource(first, () => fallback);
      final events = <PadEvent>[];
      var changes = 0;
      reader
        ..onPadsChanged = (() => changes++)
        ..start(events.add);
      addTearDown(reader.stop);
      first.poll();
      expect(reader.pads.single.id, 'sdl1');
      expect(PadReader.current(reader), same(first));
      expect(PadReader.sdlLoaded(reader), isTrue);
      final before = changes;
      reader.fallBack('SDL2 stopped answering', stalled: true);
      expect(events.whereType<PadGone>().map((event) => event.pad), ['sdl1']);
      expect(sdl.quitCalled, isTrue);
      expect(fallback.started, isTrue);
      expect(fallback.changed, isNotNull);
      expect(changes, greaterThan(before));
      expect(reader.pads.single.id, 'event21');
      expect(PadReader.current(reader), same(fallback));
      expect(PadReader.sdlLoaded(reader), isTrue, reason: 'stuck, not missing');
      expect(reader.description, startsWith('SDL2 stopped answering; evdev'));
      expect(reader.readerName, 'evdev (SDL2 stuck)');
      reader.fallBack('again');
      expect(reader.why, 'SDL2 stopped answering', reason: 'once');
    });
  });
}
