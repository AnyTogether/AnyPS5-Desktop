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
}
