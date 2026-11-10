import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/capture/broadcast.dart';
import 'package:anyps5_desktop/core/capture/game_sound.dart';
import 'package:anyps5_desktop/core/capture/video_encoders.dart';
import 'package:anyps5_desktop/core/desktop/desktop.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../support/capture_fakes.dart';

void main() {
  group('the server', () {
    test('Twitch and YouTube go to their own TLS ingest', () {
      final twitch = RtmpEndpoint.parse(BroadcastService.twitch.ingest!, 'live_123');
      expect(twitch.tls, isTrue);
      expect(twitch.port, 443);
      expect(twitch.publishUrl, 'rtmps://ingest.global-contribute.live-video.net/app/live_123');
      expect(
        RtmpEndpoint.parse(BroadcastService.youtube.ingest!, ' abcd-efgh ').publishUrl,
        'rtmps://a.rtmps.youtube.com/live2/abcd-efgh',
      );
    });

    test('a custom server may carry its key and port', () {
      final whole = RtmpEndpoint.parse('rtmp://example.org:1936/live/app/secret/', '');
      expect(whole.app, 'live/app');
      expect(whole.streamKey, 'secret');
      expect(whole.port, 1936);
      expect(whole.publishUrl, 'rtmp://example.org:1936/live/app/secret');
      expect(RtmpEndpoint.parse('rtmp://[::1]/live', 'k').publishUrl, 'rtmp://[::1]/live/k');
    });

    test('what is missing is said', () {
      expect(() => RtmpEndpoint.parse('http://example.org/live', 'k'), throwsA(EndpointProblem.notRtmp));
      expect(() => RtmpEndpoint.parse('rtmp:///live', 'k'), throwsA(EndpointProblem.noHost));
      expect(() => RtmpEndpoint.parse('rtmp://example.org', 'k'), throwsA(EndpointProblem.noApplication));
      expect(() => RtmpEndpoint.parse('rtmp://example.org/live', ''), throwsA(EndpointProblem.noKey));
    });
  });

  test('settings and keys are kept apart, the keys masked when shown', () {
    final folder = Directory.systemTemp.createTempSync('broadcast');
    addTearDown(() => folder.deleteSync(recursive: true));
    final file = Broadcaster.settingsFile(folder.path);
    expect(BroadcastSettings.load(file).service, BroadcastService.twitch);
    BroadcastSettings(
      service: BroadcastService.custom,
      customUrl: 'rtmp://x/live',
      quality: BroadcastQuality.hd1080p60,
    ).save(file);
    final loaded = BroadcastSettings.load(file);
    expect(loaded.service, BroadcastService.custom);
    expect(loaded.quality, BroadcastQuality.hd1080p60);
    expect(jsonDecode(File(file).readAsStringSync()), isNot(contains('key')));
    final keys = BroadcastKeys(Broadcaster.keysFile(folder.path), system: HostSystem.windows);
    keys.setKey(BroadcastService.twitch, ' live_abcdef3f9a ');
    expect(keys.keyFor(BroadcastService.twitch), 'live_abcdef3f9a');
    expect(keys.keyFor(BroadcastService.youtube), '');
    expect(BroadcastKeys.masked('live_abcdef3f9a'), '••••••••••3f9a');
    expect(BroadcastQuality.hd1080p30.title, '1080p30, 4.5 Mbit/s');
    expect(BroadcastSettings(viewerLink: 'twitch.tv/me').viewerUri.toString(), 'https://twitch.tv/me');
    expect(p.basename(Broadcaster.keysFile(folder.path)), 'keys.json');
  });

  group('the microphone', () {
    test('DirectShow\'s listing, either form', () {
      expect(
        BroadcastMicrophone.audioDevices('''
[dshow @ 01] "Integrated Camera" (video)
[dshow @ 01]   Alternative name "@device_pnp_x"
[dshow @ 01] "Microphone (Realtek Audio)" (audio)
[dshow @ 01]   Alternative name "@device_cm_y"
[dshow @ 01] "Stereo Mix" (audio)
'''),
        ['Microphone (Realtek Audio)', 'Stereo Mix'],
      );
      expect(
        BroadcastMicrophone.audioDevices('''
[dshow @ 02] DirectShow video devices (some may be both video and audio devices)
[dshow @ 02]  "Integrated Camera"
[dshow @ 02] DirectShow audio devices
[dshow @ 02]  "Line In"
[dshow @ 02]    Alternative name "@device_cm_z"
'''),
        ['Line In'],
      );
    });

    test('Windows asks ffmpeg for the first microphone and has none when it lists none', () async {
      var listed = 'x';
      Future<ProcessResult> run(String executable, List<String> arguments) async => ProcessResult(1, 1, '', listed);
      listed = '[dshow] "Stereo Mix" (audio)\n[dshow] "Mic A" (audio)\n';
      expect(await BroadcastMicrophone.input(system: HostSystem.windows, ffmpeg: 'ffmpeg', run: run), [
        '-thread_queue_size',
        '1024',
        '-f',
        'dshow',
        '-i',
        'audio=Mic A',
      ]);
      listed = '';
      expect(await BroadcastMicrophone.input(system: HostSystem.windows, ffmpeg: 'ffmpeg', run: run), isNull);
    });

    test('Windows takes the device picked while ffmpeg lists it, else finds one', () async {
      Future<ProcessResult> run(String executable, List<String> arguments) async =>
          ProcessResult(1, 1, '', '[dshow] "Stereo Mix" (audio)\n[dshow] "Mic A" (audio)\n');
      expect(
        await BroadcastMicrophone.input(system: HostSystem.windows, ffmpeg: 'ffmpeg', run: run, device: 'Stereo Mix'),
        contains('audio=Stereo Mix'),
      );
      expect(
        await BroadcastMicrophone.input(system: HostSystem.windows, ffmpeg: 'ffmpeg', run: run, device: 'Unplugged'),
        contains('audio=Mic A'),
      );
    });

    test('the settings keep the microphone and the badge', () {
      final folder = Directory.systemTemp.createTempSync('broadcast');
      addTearDown(() => folder.deleteSync(recursive: true));
      final file = Broadcaster.settingsFile(folder.path);
      expect(BroadcastSettings.load(file).microphone, isFalse);
      expect(BroadcastSettings.load(file).microphoneLevel, 80);
      expect(BroadcastSettings.load(file).liveBadge, isTrue);
      BroadcastSettings(microphone: true, microphoneLevel: 40, liveBadge: false).save(file);
      final back = BroadcastSettings.load(file);
      expect(back.microphone, isTrue);
      expect(back.microphoneLevel, 40);
      expect(back.liveBadge, isFalse);
    });
  });

  group('broadcasting', () {
    late List<List<String>> started;
    late List<StreamingProcess> processes;
    late List<BroadcastPhase> phases;

    setUp(() {
      started = [];
      processes = [];
      phases = [];
    });

    Broadcaster broadcaster() {
      late Broadcaster made;
      made = Broadcaster(
        ffmpeg: 'ffmpeg',
        system: HostSystem.linux,
        environment: const {'DISPLAY': ':0'},
        encoders: EncoderChoice(
          ffmpeg: 'ffmpeg',
          system: HostSystem.linux,
          run: (executable, arguments) async => ProcessResult(1, arguments.contains('h264_vaapi') ? 0 : 1, '', ''),
        ),
        areaOf: (_) => const ScreenArea(0, 0, 1920, 1080),
        soundOf: (_) => SilentGameSound(),
        changed: () {
          if (phases.isEmpty || phases.last.runtimeType != made.phase.runtimeType) phases.add(made.phase);
        },
        retryDelays: const [Duration(milliseconds: 10)],
        start: (executable, arguments) async {
          started.add(arguments);
          final process = StreamingProcess();
          processes.add(process);
          return process;
        },
      );
      return made;
    }

    final endpoint = RtmpEndpoint.parse('rtmps://a.rtmps.youtube.com/live2', 'key-1');

    test('the microphone is mixed over the game at its level, and goes on without it when it will not open', () async {
      const level = 80;
      final told = <String>[];
      late Broadcaster made;
      made = Broadcaster(
        ffmpeg: 'ffmpeg',
        system: HostSystem.linux,
        environment: const {'DISPLAY': ':0'},
        encoders: EncoderChoice(
          ffmpeg: 'ffmpeg',
          system: HostSystem.linux,
          run: (executable, arguments) async => ProcessResult(1, arguments.contains('h264_vaapi') ? 0 : 1, '', ''),
        ),
        areaOf: (_) => const ScreenArea(0, 0, 1920, 1080),
        soundOf: (_) => SilentGameSound(),
        changed: () {},
        microphoneLevel: () => level,
        noMicrophone: () => told.add('no microphone'),
        retryDelays: const [Duration(milliseconds: 10)],
        start: (executable, arguments) async {
          started.add(arguments);
          final process = StreamingProcess();
          processes.add(process);
          return process;
        },
      );
      await made.start(pid: 9, endpoint: endpoint, quality: BroadcastQuality.hd720p60);
      final arguments = started.single.join(' ');
      expect(arguments, contains('-f pulse -ar 48000 -ac 2 -i default'));
      expect(arguments, contains('volume=0.80'));
      expect(arguments, contains('[game][mic]amix=inputs=2'));
      expect(arguments, contains('-map [mixed]'));
      expect(arguments, isNot(contains('aresample=async=1 ')), reason: 'the filter graph carries it');
      // ffmpeg stops before any picture goes out: the microphone is left out and it starts again.
      processes.single.end(1);
      await pumpEventQueue();
      expect(told, ['no microphone']);
      expect(started, hasLength(2));
      expect(started.last.join(' '), isNot(contains('-filter_complex')));
      expect(started.last.join(' '), contains('-map 1:a'));
      expect(made.phase.active, isTrue);
      made.stop();
    });

    test('switching the microphone during the broadcast starts ffmpeg again, not as a dropped connection', () async {
      var level = 0;
      late Broadcaster made;
      made = Broadcaster(
        ffmpeg: 'ffmpeg',
        system: HostSystem.linux,
        environment: const {'DISPLAY': ':0'},
        encoders: EncoderChoice(
          ffmpeg: 'ffmpeg',
          system: HostSystem.linux,
          run: (executable, arguments) async => ProcessResult(1, arguments.contains('h264_vaapi') ? 0 : 1, '', ''),
        ),
        areaOf: (_) => const ScreenArea(0, 0, 1920, 1080),
        soundOf: (_) => SilentGameSound(),
        changed: () {},
        microphoneLevel: () => level,
        retryDelays: const [Duration(milliseconds: 10)],
        start: (executable, arguments) async {
          started.add(arguments);
          final process = StreamingProcess();
          processes.add(process);
          return process;
        },
      );
      await made.start(pid: 9, endpoint: endpoint, quality: BroadcastQuality.hd720p60);
      processes.single.write(utf8.encode('frame=30\nprogress=continue\n'));
      await pumpEventQueue();
      expect(made.phase, isA<BroadcastLive>());
      expect(started.single.join(' '), isNot(contains('-filter_complex')));
      level = 50;
      made.microphoneChanged();
      await Future<void>.delayed(const Duration(milliseconds: 1000));
      for (var tries = 0; tries < 100 && started.length < 2; tries++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(processes.first.ended, isTrue);
      expect(started, hasLength(2));
      expect(started.last.join(' '), contains('volume=0.50'));
      expect(made.phase, isA<BroadcastLive>(), reason: 'no Reconnecting shown');
      made.stop();
    });

    test('publishes picture and sound, live once frames go out, numbers from the progress', () async {
      final caster = broadcaster();
      await caster.start(pid: 9, endpoint: endpoint, quality: BroadcastQuality.hd720p60);
      final arguments = started.single.join(' ');
      expect(arguments, startsWith('-hide_banner -loglevel error -nostdin -vaapi_device /dev/dri/renderD128'));
      expect(arguments, contains('-f x11grab -framerate 60 -draw_mouse 0 -video_size 1920x1080 -i :0+0,0'));
      expect(arguments, contains('-f s16le -ar 48000 -ac 2 -i pipe:0'));
      expect(arguments, contains('pad=1280:720:(ow-iw)/2:(oh-ih)/2,fps=60,format=nv12,hwupload'));
      expect(arguments, contains('-c:v h264_vaapi -bf 0 -b:v 3000000 -maxrate 3000000 -bufsize 6000000 -g 120'));
      expect(arguments, contains('-c:a aac -b:a 160000'));
      expect(arguments, endsWith('-f flv rtmps://a.rtmps.youtube.com/live2/key-1'));
      expect(caster.phase, isA<BroadcastStarting>());
      processes.single.write(
        utf8.encode('frame=120\nfps=60\nbitrate=4400.5kbits/s\ndrop_frames=3\nprogress=continue\n'),
      );
      await pumpEventQueue();
      expect(caster.phase, isA<BroadcastLive>());
      expect(caster.stats.bitRate, 4400500);
      expect(caster.stats.dropped, 3);
      expect(caster.stats.droppedPercent, 2.5);
      caster.stop();
      expect(caster.phase, isA<BroadcastOff>());
      expect(processes.single.ended, isTrue);
    });

    Broadcaster onX11({required bool windowGrab, List<List<String>>? probes, List<String>? log}) => Broadcaster(
      ffmpeg: 'ffmpeg',
      system: HostSystem.linux,
      environment: const {'DISPLAY': ':0'},
      encoders: EncoderChoice(
        ffmpeg: 'ffmpeg',
        system: HostSystem.linux,
        run: (executable, arguments) async => ProcessResult(1, arguments.contains('h264_vaapi') ? 0 : 1, '', ''),
      ),
      areaOf: (_) => const ScreenArea(1920, 0, 2560, 1440, window: 77594631),
      soundOf: (_) => SilentGameSound(),
      changed: () {},
      retryDelays: const [Duration(milliseconds: 10)],
      run: (executable, arguments) async {
        probes?.add(arguments);
        return ProcessResult(
          1,
          0,
          windowGrab ? 'x11grab indev AVOptions:\n  -window_id         <int>  .D......... Window to capture.\n' : '',
          '',
        );
      },
      start: (executable, arguments) async {
        started.add(arguments);
        final process = StreamingProcess();
        processes.add(process);
        return process;
      },
      log: log?.add,
    );

    test('on X11 the game\'s window is recorded by itself, where ffmpeg can', () async {
      final probes = <List<String>>[];
      final caster = onX11(windowGrab: true, probes: probes);
      await caster.start(pid: 9, endpoint: endpoint, quality: BroadcastQuality.hd1080p60);
      await pumpEventQueue();
      expect(probes, [
        ['-hide_banner', '-h', 'demuxer=x11grab'],
      ]);
      final arguments = started.single.join(' ');
      expect(
        arguments,
        contains(
          '-thread_queue_size 64 -f x11grab -framerate 60 -draw_mouse 0 -window_id 77594631 -video_size 2560x1440 -i :0 ',
        ),
      );
      expect(arguments, isNot(contains(':0+1920,0')), reason: 'the window, not where it is on the screen');
      expect(caster.recordsWindowOnly, isTrue);
      caster.stop();
      expect(caster.recordsWindowOnly, isFalse);
    });

    test('an ffmpeg without window_id records the screen as before', () async {
      final caster = onX11(windowGrab: false);
      await caster.start(pid: 9, endpoint: endpoint, quality: BroadcastQuality.hd720p60);
      await pumpEventQueue();
      expect(
        started.single.join(' '),
        contains('-f x11grab -framerate 60 -draw_mouse 0 -video_size 2560x1440 -i :0+1920,0'),
      );
      expect(caster.recordsWindowOnly, isFalse);
      caster.stop();
    });

    test('x11grab refusing the window before anything went out records the screen instead', () async {
      final log = <String>[];
      final caster = onX11(windowGrab: true, log: log);
      await caster.start(pid: 9, endpoint: endpoint, quality: BroadcastQuality.hd720p60);
      await pumpEventQueue();
      expect(started.single, contains('-window_id'));
      processes.single.writeError("[x11grab @ 0x5581] Can't find window '0x4a00007', aborting.\n");
      await pumpEventQueue();
      processes.single.end(1);
      await pumpEventQueue();
      expect(started, hasLength(2));
      expect(started.last, isNot(contains('-window_id')));
      expect(started.last.join(' '), contains('-i :0+1920,0'));
      expect(caster.phase, isA<BroadcastStarting>(), reason: 'not a dropped connection');
      expect(caster.recordsWindowOnly, isFalse);
      expect(log, contains("broadcast: recording the screen instead of the game's window"));
      // Live on the screen's picture: a server dropping it later does not go back to the window.
      processes.last.write(utf8.encode('frame=30\nprogress=continue\n'));
      await pumpEventQueue();
      expect(caster.phase, isA<BroadcastLive>());
      caster.stop();
    });

    test('a server refusing a window recording still fails at once', () async {
      final caster = onX11(windowGrab: true);
      await caster.start(pid: 9, endpoint: endpoint, quality: BroadcastQuality.hd720p60);
      await pumpEventQueue();
      processes.single.writeError('rtmps://a.rtmps.youtube.com/live2/key-1: Input/output error\n');
      await pumpEventQueue();
      processes.single.end(1);
      await pumpEventQueue();
      expect(started, hasLength(1));
      expect(caster.phase, isA<BroadcastFailed>());
    });

    test('a server that refuses at the start fails at once, saying why without the key', () async {
      final caster = broadcaster();
      final starting = caster.start(pid: 9, endpoint: endpoint, quality: BroadcastQuality.hd720p60);
      await pumpEventQueue();
      processes.single.end(1);
      await starting;
      await pumpEventQueue();
      expect(caster.phase, isA<BroadcastFailed>());
      expect((caster.phase as BroadcastFailed).reason, isNot(contains('key-1')));
    });

    test('a dropped connection is tried again, then given up', () async {
      final caster = broadcaster();
      unawaited(caster.start(pid: 9, endpoint: endpoint, quality: BroadcastQuality.hd720p60));
      await pumpEventQueue();
      processes.single.write(utf8.encode('frame=10\nprogress=continue\n'));
      await pumpEventQueue();
      processes.single.end(1);
      await pumpEventQueue();
      expect(caster.phase, isA<BroadcastReconnecting>());
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(processes, hasLength(2));
      processes.last.end(1);
      await pumpEventQueue();
      expect(caster.phase, isA<BroadcastFailed>());
      expect(phases.map((phase) => phase.runtimeType), [
        BroadcastStarting,
        BroadcastLive,
        BroadcastReconnecting,
        BroadcastFailed,
      ]);
    });
  });
}
