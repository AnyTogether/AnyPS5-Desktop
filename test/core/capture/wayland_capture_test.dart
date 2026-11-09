import 'dart:async';
import 'dart:io';

import 'package:anyps5_desktop/core/capture/game_sound.dart';
import 'package:anyps5_desktop/core/capture/remote_play.dart';
import 'package:anyps5_desktop/core/capture/screen_cast_portal.dart';
import 'package:anyps5_desktop/core/capture/video_encoders.dart';
import 'package:anyps5_desktop/core/capture/wayland_capture.dart';
import 'package:anyps5_desktop/core/desktop/desktop.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/replay_buffer.dart';
import 'package:dbus/dbus.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../replay_buffer_test.dart' show FakeProcess;

/// A portal that answers as told, and counts what it is asked.
class FakePortal implements ScreenCastPortal {
  FakePortal({this.info = const PortalInfo(version: 5, sharesWindows: true)});

  PortalInfo? info;
  PortalGrant? grant = const PortalGrant(node: 77, width: 1920, height: 1080, restoreToken: 'next');
  Completer<void>? dialog;
  final asked = <String?>[];
  int closed = 0;

  @override
  Future<PortalInfo?> probe() async => info;

  @override
  Future<PortalGrant?> shareWindow({String? restoreToken}) async {
    asked.add(restoreToken);
    await dialog?.future;
    return grant;
  }

  @override
  Future<void> close() async => closed++;
}

const _wayland = {'XDG_SESSION_TYPE': 'wayland', 'XDG_RUNTIME_DIR': '/run/user/1000'};

void main() {
  late FakePortal portal;
  late List<(String, List<String>)> ran;
  late List<(String, List<String>)> started;
  late FakeProcess gstreamer;
  late int inspectExit;
  late bool pipeWire;
  late bool toolsInstalled;
  late String? token;
  late Directory temp;

  WaylandCapture capture() => WaylandCapture(
    portal: portal,
    environment: _wayland,
    readToken: () => token,
    saveToken: (value) => token = value,
    exists: (_) => pipeWire,
    newFolder: () => Directory(p.join(temp.path, 'feed-${ran.length}'))..createSync(recursive: true),
    run: (executable, arguments) async {
      ran.add((executable, arguments));
      if (executable == 'gst-inspect-1.0' && !toolsInstalled) throw ProcessException(executable, arguments);
      return ProcessResult(1, executable == 'gst-inspect-1.0' ? inspectExit : 0, '', '');
    },
    start: (executable, arguments) async {
      started.add((executable, arguments));
      return gstreamer;
    },
  );

  setUp(() {
    portal = FakePortal();
    ran = [];
    started = [];
    gstreamer = FakeProcess();
    inspectExit = 0;
    pipeWire = true;
    toolsInstalled = true;
    token = null;
    temp = Directory.systemTemp.createTempSync('wayland-test');
  });
  tearDown(() => temp.deleteSync(recursive: true));

  test('only a Wayland session goes through the portal', () {
    expect(WaylandCapture.applies(HostSystem.linux, const {'XDG_SESSION_TYPE': 'wayland'}), isTrue);
    expect(WaylandCapture.applies(HostSystem.linux, const {'XDG_SESSION_TYPE': 'x11', 'DISPLAY': ':0'}), isFalse);
    expect(WaylandCapture.applies(HostSystem.linux, const {'DISPLAY': ':0'}), isFalse);
    expect(WaylandCapture.applies(HostSystem.windows, const {'XDG_SESSION_TYPE': 'wayland'}), isFalse);
  });

  test('X11 keeps x11grab: no feed, the same input as before', () {
    final x11 = ScreenGrab.input(system: HostSystem.linux, environment: const {'DISPLAY': ':1'}, framesPerSecond: 30);
    expect(x11, containsAllInOrder(['-f', 'x11grab']));
    expect(x11.last, ':1');
  });

  group('says what is missing, and which', () {
    test('all in place', () async {
      expect(await capture().check(), isNull);
      expect(ran.map((run) => run.$2.single), WaylandCapture.elements);
    });

    test('no portal', () async {
      portal.info = null;
      expect(await capture().check(), WaylandProblem.noPortal);
    });

    test('a portal without window sharing', () async {
      portal.info = const PortalInfo(version: 5, sharesWindows: false);
      expect(await capture().check(), WaylandProblem.noWindowShare);
    });

    test('no PipeWire socket', () async {
      pipeWire = false;
      expect(await capture().check(), WaylandProblem.noPipeWire);
    });

    test('GStreamer not installed', () async {
      toolsInstalled = false;
      expect(await capture().check(), WaylandProblem.noGstreamer);
    });

    test('GStreamer without its PipeWire plugin', () async {
      inspectExit = 1;
      expect(await capture().check(), WaylandProblem.noGstreamer);
    });

    test('nothing is asked of the user when something is missing', () async {
      pipeWire = false;
      final wayland = capture();
      expect(await wayland.share(), isNull);
      expect(portal.asked, isEmpty);
      expect(wayland.problem, WaylandProblem.noPipeWire);
    });

    test('every problem has its text in English and Turkish', () {
      for (final language in ['en', 'tr']) {
        final texts = File('assets/l10n/$language.json').readAsStringSync();
        for (final problem in WaylandProblem.values) {
          expect(texts, contains('"${problem.textKey}"'), reason: '${problem.textKey} in $language');
        }
      }
    });
  });

  group('the desktop is asked', () {
    test('once however many things record the game', () async {
      portal.dialog = Completer();
      final wayland = capture();
      final first = wayland.share();
      final second = wayland.share();
      await pumpEventQueue();
      portal.dialog!.complete();
      expect((await first)?.node, 77);
      expect((await second)?.node, 77);
      expect(await wayland.share(), isNotNull);
      expect(portal.asked, hasLength(1));
    });

    test('not again this game after the user says no', () async {
      portal.grant = null;
      final wayland = capture();
      expect(await wayland.share(), isNull);
      expect(wayland.problem, WaylandProblem.declined);
      expect(await wayland.share(), isNull);
      expect(portal.asked, hasLength(1));
      await wayland.end();
      await wayland.share();
      expect(portal.asked, hasLength(2), reason: 'the next game may ask');
    });

    test('only after the game\'s window had its chance to open', () async {
      final window = Completer<void>();
      final wayland = WaylandCapture(
        portal: portal,
        environment: _wayland,
        exists: (_) => true,
        beforeAsking: () => window.future,
        run: (_, _) async => ProcessResult(1, 0, '', ''),
      );
      final sharing = wayland.share();
      await pumpEventQueue();
      expect(portal.asked, isEmpty);
      window.complete();
      await sharing;
      expect(portal.asked, hasLength(1));
    });

    test('the token comes back, and each new one replaces it', () async {
      token = 'old';
      final wayland = capture();
      await wayland.share();
      expect(portal.asked.single, 'old');
      expect(token, 'next');
      await wayland.end();
      portal.grant = const PortalGrant(node: 78);
      await wayland.share();
      expect(portal.asked.last, 'next');
      expect(token, '', reason: 'tokens work once: none came, none is kept');
    });

    test('no token is sent when none was saved', () async {
      await capture().share();
      expect(portal.asked.single, isNull);
    });

    test('the game ending during the dialog drops the answer', () async {
      portal.dialog = Completer();
      final wayland = capture();
      final sharing = wayland.share();
      await pumpEventQueue();
      await wayland.end();
      portal.dialog!.complete();
      expect(await sharing, isNull);
      expect(wayland.area, isNull);
      expect(portal.closed, greaterThanOrEqualTo(2), reason: 'the late sharing is closed too');
    });

    test('an error from the portal is a failure, not a question repeated', () async {
      final wayland = WaylandCapture(
        portal: _ThrowingPortal(),
        environment: _wayland,
        exists: (_) => true,
        run: (_, _) async => ProcessResult(1, 0, '', ''),
      );
      expect(await wayland.share(), isNull);
      expect(wayland.problem, WaylandProblem.failed);
    });
  });

  group('the picture', () {
    test('GStreamer reads the node and writes the size ffmpeg is told', () async {
      final wayland = capture();
      final feed = await wayland.openFeed(maxWidth: 1280, maxHeight: 720, framesPerSecond: 60);
      expect(feed, isNotNull);
      final (executable, arguments) = started.single;
      expect(executable, 'gst-launch-1.0');
      expect(arguments, containsAllInOrder(['pipewiresrc', 'path=77']));
      expect(
        arguments,
        contains('video/x-raw,format=BGRx,width=1280,height=720,framerate=60/1,pixel-aspect-ratio=1/1'),
      );
      expect(arguments, contains('location=${feed!.pipe}'));
      expect(feed.input, containsAllInOrder(['-f', 'rawvideo', '-pixel_format', 'bgr0', '-video_size', '1280x720']));
      expect(feed.input, containsAllInOrder(['-framerate', '60', '-i', feed.pipe]));
      expect(ran.where((run) => run.$1 == 'mkfifo').single.$2.single, feed.pipe);
      await feed.close();
    });

    test('keeps the window\'s shape and is never larger than it', () async {
      portal.grant = const PortalGrant(node: 1, width: 1000, height: 500);
      final feed = await capture().openFeed(maxWidth: 1280, maxHeight: 720, framesPerSecond: 30);
      expect((feed!.width, feed.height), (1000, 500));
      await feed.close();
    });

    test('closing ends GStreamer and takes the pipe\'s folder', () async {
      final feed = await capture().openFeed(maxWidth: 1280, maxHeight: 720, framesPerSecond: 30);
      final folder = Directory(p.dirname(feed!.pipe));
      expect(folder.existsSync(), isTrue);
      await feed.close();
      expect(gstreamer.killed, isNotEmpty);
      expect(folder.existsSync(), isFalse);
    });

    test('no share, no picture', () async {
      portal.grant = null;
      final wayland = capture();
      expect(await wayland.openFeed(maxWidth: 1280, maxHeight: 720, framesPerSecond: 30), isNull);
      expect(started, isEmpty);
    });

    test('a pipe that cannot be made is a failure', () async {
      final wayland = WaylandCapture(
        portal: portal,
        environment: _wayland,
        exists: (_) => true,
        newFolder: () => Directory(p.join(temp.path, 'nofifo'))..createSync(),
        run: (executable, _) async => ProcessResult(1, executable == 'mkfifo' ? 1 : 0, '', ''),
        start: (executable, arguments) async => fail('nothing to start'),
      );
      expect(await wayland.openFeed(maxWidth: 1280, maxHeight: 720, framesPerSecond: 30), isNull);
      expect(wayland.problem, WaylandProblem.failed);
    });
  });

  group('the replay buffer', () {
    late List<List<String>> ffmpegRuns;
    late FakeProcess ffmpeg;

    ReplayBuffer buffer(WaylandCapture wayland) => ReplayBuffer(
      ffmpeg: 'ffmpeg',
      folder: p.join(temp.path, 'buffer'),
      seconds: 30,
      system: HostSystem.linux,
      environment: _wayland,
      wayland: wayland,
      start: (_, arguments) async {
        ffmpegRuns.add(arguments);
        return ffmpeg;
      },
      run: (_, _) async => ProcessResult(1, 0, '', ''),
    );

    setUp(() {
      ffmpegRuns = [];
      ffmpeg = FakeProcess();
    });

    test('records the shared window at 720p, with no x11grab', () async {
      final recorder = buffer(capture());
      expect(await recorder.start(), isTrue);
      final arguments = ffmpegRuns.single;
      expect(arguments, isNot(contains('x11grab')));
      expect(arguments, containsAllInOrder(['-f', 'rawvideo', '-video_size', '1280x720', '-framerate', '30']));
      expect(started.single.$1, 'gst-launch-1.0');
      await recorder.stop();
      expect(gstreamer.killed, isNotEmpty);
    });

    test('the buffer does not start when the desktop shares nothing', () async {
      portal.grant = null;
      final wayland = capture();
      expect(await buffer(wayland).start(), isFalse);
      expect(wayland.problem, WaylandProblem.declined);
      expect(ffmpegRuns, isEmpty);
    });

    test('stopped during the dialog, ffmpeg never starts', () async {
      portal.dialog = Completer();
      final recorder = buffer(capture());
      final starting = recorder.start();
      await pumpEventQueue();
      await recorder.stop();
      portal.dialog!.complete();
      expect(await starting, isFalse);
      expect(ffmpegRuns, isEmpty);
    });

    test('GStreamer ending stops ffmpeg, which would wait on the pipe for ever', () async {
      final recorder = buffer(capture());
      await recorder.start();
      gstreamer.kill();
      await pumpEventQueue();
      expect(ffmpeg.killed, isNotEmpty);
      expect(recorder.running, isFalse);
    });
  });

  test('Remote Play sends the shared window through the feed', () async {
    final ffmpeg = FakeProcess();
    final arguments = <List<String>>[];
    final wayland = capture();
    await wayland.share();
    final stream = RemotePlayStream(
      ffmpeg: 'ffmpeg',
      system: HostSystem.linux,
      environment: _wayland,
      encoders: EncoderChoice(
        ffmpeg: 'ffmpeg',
        system: HostSystem.linux,
        run: (_, _) async => ProcessResult(1, 0, '', ''),
      ),
      areaOf: (_) => wayland.area,
      soundOf: (_) => SilentGameSound(),
      wayland: wayland,
      start: (_, list) async {
        arguments.add(list);
        return ffmpeg;
      },
    );
    final result = await stream.start(pid: 9, width: 1280, height: 720, send: (_) {});
    expect(result, RemotePlayStart.on);
    expect(arguments.single, isNot(contains('x11grab')));
    expect(arguments.single, containsAllInOrder(['-f', 'rawvideo', '-video_size', '1280x720']));
    await stream.stop();
    await pumpEventQueue();
    expect(gstreamer.killed, isNotEmpty);
  });

  group('the portal\'s answers', () {
    Map<String, DBusValue> results({String? token}) => {
      'streams': DBusArray(DBusSignature('(ua{sv})'), [
        DBusStruct([
          const DBusUint32(91),
          DBusDict.stringVariant({
            'size': DBusStruct([const DBusInt32(2560), const DBusInt32(1440)]),
            'source_type': const DBusUint32(2),
          }),
        ]),
      ]),
      if (token != null) 'restore_token': DBusString(token),
    };

    test('read as the spec gives them', () {
      final grant = DbusScreenCastPortal.grantFrom(results(token: 'abc'))!;
      expect(grant.node, 91);
      expect((grant.width, grant.height), (2560, 1440));
      expect(grant.restoreToken, 'abc');
    });

    test('no restore token on a desktop that keeps none', () {
      expect(DbusScreenCastPortal.grantFrom(results())!.restoreToken, isNull);
    });

    test('no stream, no grant', () {
      expect(DbusScreenCastPortal.grantFrom({}), isNull);
      expect(DbusScreenCastPortal.grantFrom({'streams': DBusArray(DBusSignature('(ua{sv})'), const [])}), isNull);
    });

    test('a window with no size gives a usable shape', () {
      const grant = PortalGrant(node: 1);
      expect(grant.area, isNull);
      expect(const PortalGrant(node: 1, width: 800, height: 600).area, const ScreenArea(0, 0, 800, 600));
    });
  });
}

class _ThrowingPortal implements ScreenCastPortal {
  @override
  Future<PortalInfo?> probe() async => const PortalInfo(version: 5, sharesWindows: true);

  @override
  Future<PortalGrant?> shareWindow({String? restoreToken}) => Future.error(StateError('bus gone'));

  @override
  Future<void> close() async {}
}
