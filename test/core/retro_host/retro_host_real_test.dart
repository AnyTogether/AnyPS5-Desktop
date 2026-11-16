import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/retro_host/retro_host_client.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The client against the real emulator host and the real SwanStation core, as the host
/// repository's tests/real_core.py drives them: a freely licensed BIOS (OpenBIOS) boots a PS-EXE
/// put on a disc image by that repository's tests/make_test_disc.py.
///
/// ANYPS5_RETRO_HOST_REAL names a JSON file:
///
/// ```json
/// {"host": "/path/to/anyps5-retro-host", "core": "/path/to/swanstation_libretro.dll",
///  "bios": "/path/to/openbios.bin", "program": "/path/to/hello.exe",
///  "discBuilder": "/path/to/anyps5-retro-host/tests/make_test_disc.py",
///  "environment": {"PATH": "..."}}
/// ```
///
/// `environment` is optional and is added to the launcher's environment for the host. Python 3
/// must be on PATH to build the disc. Without ANYPS5_RETRO_HOST_REAL the test is skipped.
void main() {
  final configPath = Platform.environment['ANYPS5_RETRO_HOST_REAL'];
  if (configPath == null || configPath.isEmpty) {
    test('the real host runs a game', () {}, skip: 'ANYPS5_RETRO_HOST_REAL is not set');
    return;
  }
  test('the real host runs a game', () async {
    final config = jsonDecode(File(configPath).readAsStringSync()) as Map<String, Object?>;
    String path(String key) => File(config[key]! as String).absolute.path;
    final work = Directory.systemTemp.createTempSync('retro-host-real-');
    RetroHostClient? client;
    StreamSubscription<RetroFrameEvent>? frames;
    try {
      final system = Directory(p.join(work.path, 'system'))..createSync();
      File(path('bios')).copySync(p.join(system.path, 'openbios.bin'));
      final disc = p.join(work.path, 'program.cue');
      final built = Process.runSync(_python(), [path('discBuilder'), path('program'), disc]);
      expect(built.exitCode, 0, reason: 'make_test_disc.py: ${built.stderr}');

      final started = RetroHostClient.start(
        command: [path('host')],
        environment: (config['environment'] as Map<String, Object?>?)?.cast<String, String>(),
        volume: 0,
        muted: true,
      );
      client = started;
      await started.ready;
      _report('welcome: host ${started.hostVersion}, pixel format ${started.pixelFormat}');

      var drawn = 0;
      final pictures = <Uint8List>[];
      frames = started.frames.listen((event) {
        final frame = event.frame;
        if (!event.drawn || frame == null) return;
        drawn++;
        if (pictures.length >= 2) return;
        final pixels = Uint8List.fromList(frame.pixels.asTypedList(frame.width * frame.height * 4));
        if (!_shows(pixels)) return;
        if (pictures.isEmpty || !_same(pictures.first, pixels)) pictures.add(pixels);
      });

      final epoch = await started.startGame({
        'core': path('core'),
        'system': system.path,
        'saves': p.join(work.path, 'saves'),
        'disc': disc,
        'options': {
          'swanstation_BIOS_PathNTSCU': 'openbios.bin',
          'swanstation_BIOS_PathNTSCJ': 'openbios.bin',
          'swanstation_BIOS_PathPAL': 'openbios.bin',
          'swanstation_GPU_ResolutionScale': '2',
        },
      });
      _report('start: epoch $epoch');

      final ready = await _waitFor(started, (s) => s.ready || s.ended, const Duration(seconds: 60));
      expect(ready.ended, isFalse, reason: 'the game ended at start: ${ready.errorCode} ${ready.error}');
      _report('ready: hardware=${ready.hardware} resolutionError=${jsonEncode(ready.resolutionError)}');

      final before = drawn;
      await Future<void>.delayed(const Duration(seconds: 10));
      final shown = drawn - before;
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (pictures.length < 2 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      final last = started.frame;
      _report(
        '$shown drawn frames in 10 s; ${pictures.length} different pictures that are not black; '
        'last frame ${last?.width}x${last?.height}',
      );
      expect(shown, greaterThanOrEqualTo(100), reason: 'drawn frames in 10 s');
      expect(pictures, hasLength(2), reason: 'two pinned frames that are not black and differ');

      final stopped = await started.stopGame();
      _report('stop: ended=${stopped?.ended} errorCode=${jsonEncode(stopped?.errorCode)}');
      expect(stopped?.ended, isTrue);
      expect(stopped?.errorCode, RetroErrorCode.none);
      expect(await started.call('release'), isNull);
      expect(await started.status(), isNull);

      started.shutdown();
      final end = await started.ended;
      final code = await started.exited;
      _report('end: $end, exit code $code');
      expect(end, RetroHostEnd.clean, reason: started.failureReason);
      expect(code, 0);
    } finally {
      await frames?.cancel();
      await client?.close();
      work.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}

Future<RetroStatus> _waitFor(RetroHostClient client, bool Function(RetroStatus) done, Duration limit) async {
  final deadline = DateTime.now().add(limit);
  RetroStatus? last;
  while (DateTime.now().isBefore(deadline)) {
    last = await client.status();
    if (last != null && done(last)) return last;
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  fail('no wanted status within $limit; last ${last?.toJson()}');
}

bool _shows(Uint8List pixels) {
  for (var i = 0; i < pixels.length; i += 4) {
    if (pixels[i] != 0 || pixels[i + 1] != 0 || pixels[i + 2] != 0) return true;
  }
  return false;
}

bool _same(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

String _python() {
  final name = Platform.isWindows ? 'python' : 'python3';
  final found = Process.runSync(Platform.isWindows ? 'where' : 'which', [name]);
  final path = (found.stdout as String)
      .split(RegExp(r'\r?\n'))
      .firstWhere((line) => line.trim().isNotEmpty, orElse: () => '');
  if (path.isEmpty) throw StateError('$name is not on PATH');
  return path.trim();
}

void _report(String line) => stdout.writeln(line);
