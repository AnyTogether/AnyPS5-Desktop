import 'dart:io';

import 'package:anyps5_desktop/core/capture/video_encoders.dart';
import 'package:anyps5_desktop/core/desktop/desktop.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:test/test.dart';

void main() {
  test('hardware encoders are tried first, x264 after them', () {
    expect(VideoEncoder.candidates(HostSystem.windows), [
      VideoEncoder.nvenc,
      VideoEncoder.qsv,
      VideoEncoder.amf,
      VideoEncoder.x264,
      VideoEncoder.mediaFoundation,
    ]);
    expect(VideoEncoder.candidates(HostSystem.linux), [
      VideoEncoder.nvenc,
      VideoEncoder.vaapi,
      VideoEncoder.qsv,
      VideoEncoder.x264,
    ]);
  });

  test('Remote Play holds nothing back: no B frames, zero latency', () {
    for (final encoder in VideoEncoder.values) {
      final arguments = encoder.arguments(use: EncodeUse.live, bitRate: 8000000, keyEvery: 60);
      expect(arguments.sublist(0, 2), ['-c:v', encoder.codec]);
      expect(arguments.join(' '), contains('-bf 0'));
      expect(arguments.join(' '), contains('-g 60'));
      expect(arguments.join(' '), contains('-b:v 8000000 -maxrate 8000000 -bufsize 4000000'));
    }
    expect(VideoEncoder.x264.arguments(use: EncodeUse.live, bitRate: 1, keyEvery: 1).join(' '), contains('-tune zerolatency'));
    expect(VideoEncoder.nvenc.arguments(use: EncodeUse.live, bitRate: 1, keyEvery: 1).join(' '), contains('-tune ull'));
    expect(VideoEncoder.vaapi.deviceArguments, ['-vaapi_device', '/dev/dri/renderD128']);
    expect(VideoEncoder.vaapi.filterTail, 'format=nv12,hwupload');
  });

  test('the first encoder that works is chosen once', () async {
    final asked = <String>[];
    final choice = EncoderChoice(
      ffmpeg: 'ffmpeg',
      system: HostSystem.windows,
      run: (executable, arguments) async {
        final codec = arguments[arguments.indexOf('-c:v') + 1];
        asked.add(codec);
        return ProcessResult(1, codec == 'h264_amf' ? 0 : 1, '', '');
      },
    );
    expect(await choice.encoder, VideoEncoder.amf);
    expect(await choice.encoder, VideoEncoder.amf);
    expect(asked, ['h264_nvenc', 'h264_qsv', 'h264_amf']);
    expect(choice.tried, hasLength(3));
  });

  test('no encoder at all is said as none', () async {
    final choice = EncoderChoice(
      ffmpeg: 'ffmpeg',
      system: HostSystem.linux,
      run: (executable, arguments) async => throw const ProcessException('ffmpeg', [], 'missing'),
    );
    expect(await choice.encoder, isNull);
  });

  test('the game\'s area of the screen, on Windows and X11', () {
    const area = ScreenArea(-1920, 40, 1281, 721);
    final windows = ScreenGrab.input(system: HostSystem.windows, environment: const {}, framesPerSecond: 60, area: area);
    expect(windows.join(' '), contains('-f gdigrab -framerate 60 -draw_mouse 0 -offset_x -1920 -offset_y 40 -video_size 1280x720 -i desktop'));
    final x11 = ScreenGrab.input(system: HostSystem.linux, environment: const {'DISPLAY': ':1'}, framesPerSecond: 30, area: area);
    expect(x11.join(' '), contains('-f x11grab -framerate 30 -draw_mouse 0 -video_size 1280x720 -i :1+-1920,40'));
    expect(ScreenGrab.input(system: HostSystem.linux, environment: const {'DISPLAY': ':0'}, framesPerSecond: 30).last, ':0');
  });

  test('on X11 the game\'s window by itself: x11grab\'s window_id, its size, no offset', () {
    const area = ScreenArea(-1920, 40, 1281, 721, window: 0x2c00009);
    final window = ScreenGrab.input(
      system: HostSystem.linux,
      environment: const {'DISPLAY': ':1'},
      framesPerSecond: 60,
      area: area,
      windowOnly: true,
    );
    expect(window, [
      '-thread_queue_size',
      '64',
      '-f',
      'x11grab',
      '-framerate',
      '60',
      '-draw_mouse',
      '0',
      '-window_id',
      '${0x2c00009}',
      '-video_size',
      '1280x720',
      '-i',
      ':1',
    ]);
    // Asked for, but nothing to record by itself: the screen's area as before.
    final screen = ScreenGrab.input(
      system: HostSystem.linux,
      environment: const {'DISPLAY': ':1'},
      framesPerSecond: 60,
      area: const ScreenArea(0, 0, 800, 600),
      windowOnly: true,
    );
    expect(screen.join(' '), endsWith('-video_size 800x600 -i :1+0,0'));
    // Windows has no window_id: gdigrab's desktop as before.
    expect(
      ScreenGrab.input(
        system: HostSystem.windows,
        environment: const {},
        framesPerSecond: 60,
        area: area,
        windowOnly: true,
      ),
      isNot(contains('-window_id')),
    );
  });

  test('whether ffmpeg\'s x11grab takes window_id is asked from its options', () async {
    final asked = <List<String>>[];
    Future<ProcessResult> answer(String stdout, {int code = 0}) async => ProcessResult(1, code, stdout, '');
    expect(
      await ScreenGrab.windowGrab('ffmpeg', (executable, arguments) {
        asked.add(arguments);
        return answer('x11grab indev AVOptions:\n  -window_id         <int>        .D......... Window to capture.\n');
      }),
      isTrue,
    );
    expect(asked.single, ['-hide_banner', '-h', 'demuxer=x11grab']);
    // FFmpeg 4.3 and older: x11grab without it.
    expect(
      await ScreenGrab.windowGrab('ffmpeg', (_, _) => answer('x11grab indev AVOptions:\n  -grab_x  <int>\n')),
      isFalse,
    );
    expect(await ScreenGrab.windowGrab('ffmpeg', (_, _) => answer("Unknown format 'x11grab'.", code: 1)), isFalse);
    expect(
      await ScreenGrab.windowGrab('ffmpeg', (_, _) async => throw const ProcessException('ffmpeg', [], 'missing')),
      isFalse,
    );
  });

  test('the game\'s area keeps its window: a new window is a new area', () {
    expect(const ScreenArea(0, 0, 10, 10, window: 1), isNot(const ScreenArea(0, 0, 10, 10, window: 2)));
    expect(const ScreenArea(0, 0, 10, 10, window: 1), const ScreenArea(0, 0, 10, 10, window: 1));
    expect(const ScreenArea(0, 0, 10, 10), isNot(const ScreenArea(0, 0, 10, 10, window: 1)));
  });

  test('X11 and Windows have a screen input; Wayland has the portal instead', () {
    expect(ScreenGrab.supported(HostSystem.windows, const {}), isTrue);
    expect(ScreenGrab.supported(HostSystem.linux, const {'DISPLAY': ':0', 'XDG_SESSION_TYPE': 'x11'}), isTrue);
    expect(ScreenGrab.supported(HostSystem.linux, const {'DISPLAY': ':0', 'XDG_SESSION_TYPE': 'wayland'}), isFalse);
    expect(ScreenGrab.supported(HostSystem.linux, const {}), isFalse);
  });

  test('the picture fits what the phone asked, in its own shape, never larger', () {
    expect(ScreenGrab.fit(const ScreenArea(0, 0, 1920, 1080), 1280, 720), (1280, 720));
    expect(ScreenGrab.fit(const ScreenArea(0, 0, 1920, 1200), 1280, 720), (1152, 720));
    expect(ScreenGrab.fit(const ScreenArea(0, 0, 801, 451), 1280, 720), (800, 450));
    expect(ScreenGrab.fit(null, 1281, 721), (1280, 720));
  });

  test('the graphics card encoders are told a requested key frame must be an IDR frame', () {
    expect(VideoEncoder.nvenc.keyRequestArguments, ['-force_key_frames', 'scd_metadata', '-forced-idr', '1']);
    expect(VideoEncoder.qsv.keyRequestArguments, ['-force_key_frames', 'scd_metadata', '-forced_idr', '1']);
    expect(VideoEncoder.amf.keyRequestArguments, ['-force_key_frames', 'scd_metadata', '-forced_idr', '1']);
    expect(VideoEncoder.x264.keyRequestArguments, ['-force_key_frames', 'scd_metadata']);
    expect(VideoEncoder.vaapi.keyRequestArguments, ['-force_key_frames', 'scd_metadata']);
  });

  test('whether key frames can be requested is asked once, and a refusal says no', () async {
    var probes = 0;
    final choice = EncoderChoice(
      ffmpeg: 'ffmpeg',
      system: HostSystem.windows,
      run: (executable, arguments) async {
        if (arguments.contains('scd_metadata')) {
          probes++;
          expect(arguments.join(' '), contains('${KeyRequest.filter},format=nv12'));
          return ProcessResult(1, 1, '', '');
        }
        return ProcessResult(1, arguments.contains('h264_nvenc') ? 0 : 1, '', '');
      },
    );
    expect(await choice.keyRequests, isFalse);
    expect(await choice.keyRequests, isFalse);
    expect(probes, 1);
  });
}
