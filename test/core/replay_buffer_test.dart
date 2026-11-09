import 'dart:async';
import 'dart:io';

import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/replay_buffer.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A process that runs until it is killed.
class FakeProcess implements Process {
  final Completer<int> _exit = Completer();
  final List<ProcessSignal> killed = [];

  @override
  Future<int> get exitCode => _exit.future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed.add(signal);
    if (!_exit.isCompleted) _exit.complete(-1);
    return true;
  }

  @override
  int get pid => 4242;

  @override
  IOSink get stdin => IOSink(StreamController<List<int>>().sink);

  @override
  Stream<List<int>> get stdout => const Stream.empty();

  @override
  Stream<List<int>> get stderr => const Stream.empty();
}

void main() {
  late Directory temp;
  late String folder;
  late List<List<String>> started;
  late List<List<String>> ran;
  late FakeProcess process;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('replay');
    folder = p.join(temp.path, 'buffer');
    started = [];
    ran = [];
    process = FakeProcess();
  });
  tearDown(() => temp.deleteSync(recursive: true));

  ReplayBuffer buffer({HostSystem system = HostSystem.windows, int seconds = 60}) => ReplayBuffer(
    ffmpeg: 'ffmpeg',
    folder: folder,
    seconds: seconds,
    system: system,
    environment: const {'DISPLAY': ':1'},
    start: (executable, arguments) async {
      started.add([executable, ...arguments]);
      return process;
    },
    run: (executable, arguments) async {
      ran.add([executable, ...arguments]);
      // The join writes its output; the picture is asked for after it.
      File(arguments.last).writeAsStringSync('mp4');
      return ProcessResult(1, 0, '', '');
    },
  );

  test('records the screen into wrapping segments: gdigrab on Windows, x11grab on X11, 720p30', () async {
    final windows = buffer();
    expect(await windows.start(), isTrue);
    final arguments = started.single;
    expect(arguments.join(' '), contains('-f gdigrab -framerate 30 -draw_mouse 0 -i desktop'));
    expect(arguments.join(' '), contains('scale=-2:720'));
    expect(arguments.join(' '), contains('-preset ultrafast'));
    expect(
      arguments.join(' '),
      contains('-segment_time 5 -segment_wrap 14'),
      reason: '60 s in 5 s segments, and two more',
    );
    expect(arguments.last, p.join(folder, 'segment%03d.ts'));
    expect(windows.running, isTrue);
    await windows.stop();
    expect(process.killed, isNotEmpty);
    expect(Directory(folder).existsSync(), isFalse, reason: 'nothing is kept once it stops');

    final linux = buffer(system: HostSystem.linux, seconds: 30);
    process = FakeProcess();
    await linux.start();
    expect(started.last.join(' '), contains('-f x11grab -framerate 30 -draw_mouse 0 -i :1'));
    expect(started.last.join(' '), contains('-segment_wrap 8'));
    await linux.stop();
  });

  test('X11 and Windows record directly; Wayland goes through the portal, no display cannot', () {
    expect(ReplayBuffer.supported(HostSystem.windows, const {}), isTrue);
    expect(ReplayBuffer.supported(HostSystem.linux, const {'DISPLAY': ':0', 'XDG_SESSION_TYPE': 'x11'}), isTrue);
    expect(ReplayBuffer.supported(HostSystem.linux, const {'DISPLAY': ':0', 'XDG_SESSION_TYPE': 'wayland'}), isFalse);
    expect(ReplayBuffer.supported(HostSystem.linux, const {}), isFalse);
  });

  test('ffmpeg is found beside the launcher first, then on the PATH', () {
    final there = {r'C:\AnyPS5\ffmpeg.exe', r'C:\tools\ffmpeg.exe'};
    expect(
      ReplayBuffer.locate(
        system: HostSystem.windows,
        environment: const {'Path': r'C:\Windows;C:\tools'},
        launcherFolder: r'C:\AnyPS5',
        exists: there.contains,
      ),
      r'C:\AnyPS5\ffmpeg.exe',
    );
    expect(
      ReplayBuffer.locate(
        system: HostSystem.linux,
        environment: const {'PATH': '/usr/local/bin:/usr/bin'},
        exists: (path) => path == '/usr/bin/ffmpeg',
      ),
      '/usr/bin/ffmpeg',
    );
    expect(
      ReplayBuffer.locate(system: HostSystem.linux, environment: const {'PATH': '/usr/bin'}, exists: (_) => false),
      isNull,
    );
  });

  test('saving joins the newest segments for the length asked, oldest first, without re-encoding', () async {
    final replay = buffer(seconds: 30);
    await replay.start();
    final base = DateTime(2026, 10, 26, 12);
    // Ten segments written five seconds apart, wrapping: segment003 is the newest.
    for (var index = 0; index < 10; index++) {
      final number = (index + 4) % 10;
      final file = File(p.join(folder, 'segment${number.toString().padLeft(3, '0')}.ts'))..writeAsStringSync('ts');
      file.setLastModifiedSync(base.add(Duration(seconds: index * 5)));
    }
    File(p.join(folder, 'segment999.ts')).writeAsStringSync('');
    final parts = replay.segments().map(p.basename).toList();
    expect(parts, [
      'segment007.ts',
      'segment008.ts',
      'segment009.ts',
      'segment000.ts',
      'segment001.ts',
      'segment002.ts',
      'segment003.ts',
    ]);
    final destination = p.join(temp.path, 'Pictures', 'Game', 'PPSA01001-clip-20261026-120000.mp4');
    expect(await replay.save(destination), destination);
    final join = ran.first.join(' ');
    expect(join, contains('-f concat -safe 0'));
    expect(join, contains('-c copy'));
    expect(ran.first.last, destination);
    expect(File(p.join(folder, 'join.txt')).readAsLinesSync(), hasLength(7));
    expect(ran.last.last, ReplayBuffer.thumbnailOf(destination));
    expect(ReplayBuffer.thumbnailOf(destination), endsWith('PPSA01001-clip-20261026-120000.thumb.jpg'));
    await replay.stop();
  });

  test('nothing recorded yet: nothing saved', () async {
    final replay = buffer();
    await replay.start();
    expect(await replay.save(p.join(temp.path, 'clip.mp4')), isNull);
    expect(ran, isEmpty);
    await replay.stop();
  });
}
