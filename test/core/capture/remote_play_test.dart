import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/capture/flv_video.dart';
import 'package:anyps5_desktop/core/capture/game_sound.dart';
import 'package:anyps5_desktop/core/capture/remote_play.dart';
import 'package:anyps5_desktop/core/capture/stream_packet.dart';
import 'package:anyps5_desktop/core/capture/video_encoders.dart';
import 'package:anyps5_desktop/core/desktop/desktop.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:test/test.dart';

import '../../support/capture_fakes.dart';

/// Sound a test plays into.
class FakeSound implements GameSound {
  SoundSink? sink;
  bool stopped = false;
  @override
  SoundReach get reach => SoundReach.game;
  @override
  Future<void> start(SoundSink sink) async => this.sink = sink;
  @override
  Future<void> stop() async => stopped = true;
}

void main() {
  late List<List<String>> started;
  late List<StreamingProcess> processes;
  late ScreenArea? area;
  late FakeSound sound;
  late List<Uint8List> sent;

  setUp(() {
    started = [];
    processes = [];
    area = const ScreenArea(0, 0, 1920, 1080);
    sound = FakeSound();
    sent = [];
  });

  RemotePlayStream stream({Duration keyGap = const Duration(milliseconds: 200), bool keyRequests = true}) => RemotePlayStream(
    ffmpeg: 'ffmpeg',
    system: HostSystem.windows,
    encoders: EncoderChoice(ffmpeg: 'ffmpeg', system: HostSystem.windows, run: (executable, arguments) async {
      if (arguments.contains('scd_metadata') && !keyRequests) return ProcessResult(1, 1, '', '');
      return ProcessResult(1, arguments.contains('libx264') ? 0 : 1, '', '');
    }),
    areaOf: (_) => area,
    soundOf: (_) => sound,
    followEvery: const Duration(milliseconds: 20),
    keyGap: keyGap,
    start: (executable, arguments) async {
      started.add(arguments);
      final process = StreamingProcess();
      processes.add(process);
      return process;
    },
  );

  test('the game\'s picture and sound reach the phone in the Mac\'s packets', () async {
    final play = stream();
    expect(await play.start(pid: 77, width: 1280, height: 720, send: sent.addAll), RemotePlayStart.on);
    final arguments = started.single.join(' ');
    expect(arguments, contains('-video_size 1920x1080 -i desktop'));
    expect(arguments, contains('scale=1280:720:flags=bilinear,format=yuv420p'));
    expect(arguments, contains('-c:v libx264'));
    expect(arguments, contains('-b:v 11059200'));
    expect(arguments, endsWith('-f flv pipe:1'));
    processes.single
      ..write(FlvBuilder.header())
      ..write(FlvBuilder.sequence())
      ..write(FlvBuilder.frame([[0x65, 1, 2]], key: true));
    sound.sink!(Uint8List(SoundChunker.bytes * 2));
    await pumpEventQueue();
    final video = sent.where((packet) => ByteData.sublistView(packet).getUint32(0, Endian.little) == StreamPacket.videoMagic);
    final audio = sent.where((packet) => ByteData.sublistView(packet).getUint32(0, Endian.little) == StreamPacket.audioMagic);
    expect(video, hasLength(1));
    expect(ByteData.sublistView(video.single).getUint16(16, Endian.little), 1, reason: 'a key frame');
    expect(audio, hasLength(2));
    await play.stop();
    expect(processes.single.ended, isTrue);
    expect(sound.stopped, isTrue);
  });

  test('no window: the phone hears there is no game', () async {
    area = null;
    expect(await stream().start(pid: 77, width: 1280, height: 720, send: sent.addAll), RemotePlayStart.noGame);
    expect(started, isEmpty);
  });

  test('a window that moves is recorded again where it is, the frames numbered on', () async {
    final play = stream();
    await play.start(pid: 77, width: 1280, height: 720, send: sent.addAll);
    processes.last
      ..write(FlvBuilder.header())
      ..write(FlvBuilder.sequence())
      ..write(FlvBuilder.frame([[0x65, 1]], key: true));
    await pumpEventQueue();
    area = const ScreenArea(100, 50, 1280, 720);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(processes.length, greaterThanOrEqualTo(2));
    expect(processes.first.ended, isTrue);
    expect(started.last.join(' '), contains('-offset_x 100 -offset_y 50 -video_size 1280x720'));
    processes.last
      ..write(FlvBuilder.header())
      ..write(FlvBuilder.sequence())
      ..write(FlvBuilder.frame([[0x65, 2]], key: true));
    await pumpEventQueue();
    final numbers = [
      for (final packet in sent)
        if (ByteData.sublistView(packet).getUint32(0, Endian.little) == StreamPacket.videoMagic)
          ByteData.sublistView(packet).getUint32(8, Endian.little),
    ];
    expect(numbers, [1, 2]);
    await play.stop();
  });

  test('asking again for the same size keeps the stream going', () async {
    final play = stream();
    await play.start(pid: 77, width: 1280, height: 720, send: sent.addAll);
    await play.start(pid: 77, width: 1280, height: 720, send: sent.addAll);
    expect(started, hasLength(1));
    await play.stop();
  });

  test('an ask for a key frame goes to ffmpeg\'s standard input', () async {
    final play = stream();
    await play.start(pid: 77, width: 1280, height: 720, send: sent.addAll);
    final arguments = started.single;
    expect(arguments, isNot(contains('-nostdin')));
    expect(arguments.join(' '), contains('-stats_period 0.05'));
    expect(arguments.join(' '), contains('${KeyRequest.filter},scale=1280:720'));
    expect(arguments.join(' '), contains('-force_key_frames scd_metadata'));
    expect(processes.single.stdinBytes.isEmpty, isTrue);
    play.wantKey();
    await pumpEventQueue();
    expect(String.fromCharCodes(processes.single.stdinBytes.takeBytes()), KeyRequest.command);
    await play.stop();
  });

  test('asks that come together make one request, and one more for what came after', () async {
    final play = stream(keyGap: const Duration(milliseconds: 40));
    await play.start(pid: 77, width: 1280, height: 720, send: sent.addAll);
    play
      ..wantKey()
      ..wantKey()
      ..wantKey();
    await pumpEventQueue();
    expect(String.fromCharCodes(processes.single.stdinBytes.takeBytes()), KeyRequest.command);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await pumpEventQueue();
    expect(String.fromCharCodes(processes.single.stdinBytes.takeBytes()), KeyRequest.command, reason: 'the ask that came during the gap');
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await pumpEventQueue();
    expect(processes.single.stdinBytes.isEmpty, isTrue, reason: 'nothing more was asked');
    await play.stop();
  });

  test('an ffmpeg that cannot do it gets the old arguments, and a request does nothing', () async {
    final play = stream(keyRequests: false);
    await play.start(pid: 77, width: 1280, height: 720, send: sent.addAll);
    final arguments = started.single;
    expect(arguments, contains('-nostdin'));
    expect(arguments.join(' '), isNot(contains('metadata')));
    expect(arguments, isNot(contains('-force_key_frames')));
    play.wantKey();
    await pumpEventQueue();
    expect(processes.single.stdinBytes.isEmpty, isTrue);
    await play.stop();
  });

  test('a request with no stream running is ignored', () {
    final play = stream();
    expect(play.wantKey, returnsNormally);
  });

  test('ffmpeg\'s echo of each command is not kept for the log', () {
    const echoed = '\nEnter command: <target>|all <time>|-1 <command>[ <argument>]\n\nCommand reply for stream -1: ret:0 res:\nreal error\n';
    expect(KeyRequest.withoutEcho(echoed).trim(), 'real error');
  });

  // CI runs this one with the pinned ffmpeg on Linux and Windows (the key-frames job).
  final realFfmpeg = Platform.environment['ANYPS5_TEST_FFMPEG'];

  test('a real ffmpeg makes a key frame when asked, on that frame only', () async {
    const encoder = VideoEncoder.x264;
    final process = await Process.start(realFfmpeg!, [
      '-hide_banner', '-loglevel', 'error',
      ...KeyRequest.globalArguments,
      '-re', '-f', 'lavfi', '-i', 'testsrc=size=640x360:rate=60', '-t', '6', '-an',
      '-vf', '${KeyRequest.filter},scale=480:270:flags=bilinear,${encoder.filterTail}',
      ...encoder.arguments(use: EncodeUse.live, bitRate: 2000000, keyEvery: 600),
      ...encoder.keyRequestArguments,
      '-flush_packets', '1', '-flvflags', 'no_duration_filesize', '-f', 'flv', 'pipe:1',
    ]);
    final errors = StringBuffer();
    process.stderr.listen((data) => errors.write(String.fromCharCodes(data)));
    final clock = Stopwatch()..start();
    final keyTimes = <int>[];
    var frameCount = 0;
    final reader = FlvVideoReader((frame) {
      if (frame.key) keyTimes.add(clock.elapsedMilliseconds);
      frameCount++;
    });
    process.stdout.listen(reader.add);
    // Twice, a good way apart and well before the end.
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    final firstAsk = clock.elapsedMilliseconds;
    process.stdin.write(KeyRequest.command);
    await process.stdin.flush();
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    final secondAsk = clock.elapsedMilliseconds;
    process.stdin.write(KeyRequest.command);
    await process.stdin.flush();
    expect(await process.exitCode, 0, reason: errors.toString());
    await Future<void>.delayed(const Duration(milliseconds: 100));
    // ignore: avoid_print
    print('frames $frameCount, key frames at $keyTimes ms, asked at $firstAsk and $secondAsk ms');
    expect(keyTimes, hasLength(3), reason: 'the first frame, then one for each ask: $keyTimes');
    expect(keyTimes[1] - firstAsk, inInclusiveRange(0, 500), reason: 'first ask answered ${keyTimes[1] - firstAsk} ms later');
    expect(keyTimes[2] - secondAsk, inInclusiveRange(0, 500), reason: 'second ask answered ${keyTimes[2] - secondAsk} ms later');
  }, skip: realFfmpeg == null ? 'ANYPS5_TEST_FFMPEG is not set' : false, timeout: const Timeout(Duration(seconds: 30)));
}
