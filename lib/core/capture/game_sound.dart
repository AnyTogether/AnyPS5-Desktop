import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../child_processes.dart';
import '../host.dart';
import '../replay_buffer.dart' show ProcessRunner, ProcessStarter;
import 'game_sound_native.dart';

/// The game's sound as it comes: 16-bit little-endian stereo at 48 kHz.
typedef SoundSink = void Function(Uint8List samples);

/// What a [GameSound] hears.
enum SoundReach {
  /// Only the game (Windows' process loopback, PulseAudio's stream of the game).
  game,

  /// Everything the computer plays: where the game alone cannot be told apart yet.
  system,

  /// Nothing: no way to hear the computer here.
  none,
}

/// The game's sound for Remote Play, broadcasting and clips. Windows: WASAPI loopback of the
/// game's process tree, else of the output device (native/capture). Linux: PulseAudio (or
/// PipeWire's PulseAudio server) through parec, on the game's own stream once it has one and on
/// the output's monitor until then; ffmpeg's pulse input where parec is missing.
abstract class GameSound {
  Future<void> start(SoundSink sink);
  Future<void> stop();
  SoundReach get reach;

  static GameSound forGame(
    int pid, {
    required HostSystem system,
    Map<String, String> environment = const {},
    String? ffmpeg,
    ProcessStarter? start,
    ProcessRunner? run,
  }) => switch (system) {
    HostSystem.windows => WindowsGameSound(pid),
    HostSystem.linux => PulseGameSound(pid, environment: environment, ffmpeg: ffmpeg, start: start, run: run),
  };
}

/// No sound (macOS in tests, or a desktop that cannot be heard).
class SilentGameSound implements GameSound {
  @override
  SoundReach get reach => SoundReach.none;
  @override
  Future<void> start(SoundSink sink) async {}
  @override
  Future<void> stop() async {}
}

/// Windows: native/capture's loopback, read every 10 ms.
class WindowsGameSound implements GameSound {
  WindowsGameSound(this.pid, {this.allowSystem = true});

  final int pid;

  /// The whole output device where Windows has no process loopback (before build 20348).
  final bool allowSystem;

  Pointer<Void> _handle = nullptr;
  Pointer<Uint8> _buffer = nullptr;
  Timer? _timer;
  int _state = NativeSoundState.starting;
  static const _chunk = 32768;

  @override
  SoundReach get reach => switch (_state) {
    NativeSoundState.game => SoundReach.game,
    NativeSoundState.system => SoundReach.system,
    _ => SoundReach.none,
  };

  @override
  Future<void> start(SoundSink sink) async {
    if (_handle != nullptr) return;
    try {
      _handle = soundOpen(pid, allowSystem ? 1 : 0);
    } on Object {
      _handle = nullptr;
    }
    if (_handle == nullptr) {
      _state = NativeSoundState.failed;
      return;
    }
    _buffer = malloc<Uint8>(_chunk);
    _timer = Timer.periodic(const Duration(milliseconds: 10), (_) {
      final handle = _handle;
      if (handle == nullptr) return;
      _state = soundState(handle);
      if (_state == NativeSoundState.failed) {
        unawaited(stop());
        return;
      }
      while (true) {
        final read = soundRead(handle, _buffer, _chunk);
        if (read <= 0) break;
        sink(Uint8List.fromList(_buffer.asTypedList(read)));
        if (read < _chunk) break;
      }
    });
  }

  @override
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    final handle = _handle;
    _handle = nullptr;
    if (handle != nullptr) soundClose(handle);
    if (_buffer != nullptr) malloc.free(_buffer);
    _buffer = nullptr;
  }
}

/// Linux: PulseAudio's parec (pulseaudio-utils; PipeWire answers it as well), or ffmpeg's pulse
/// input when parec is missing.
class PulseGameSound implements GameSound {
  PulseGameSound(
    this.pid, {
    this.environment = const {},
    this.ffmpeg,
    ProcessStarter? start,
    ProcessRunner? run,
    this.lookEvery = const Duration(seconds: 3),
  }) : _start = start ?? ((executable, arguments) => ChildProcesses.start(executable, arguments, environment: _cLocale)),
       _run = run ?? ((executable, arguments) => Process.run(executable, arguments, environment: _cLocale));

  final int pid;
  final Map<String, String> environment;
  final String? ffmpeg;
  final Duration lookEvery;
  final ProcessStarter _start;
  final ProcessRunner _run;

  /// pactl's words untranslated, so its list can be read.
  static const _cLocale = {'LC_ALL': 'C'};

  Process? _process;
  int? _stream;
  bool _running = false;
  bool _usesParec = true;
  Timer? _look;
  SoundSink? _sink;

  @override
  SoundReach get reach => _process == null ? SoundReach.none : (_stream != null ? SoundReach.game : SoundReach.system);

  /// parec's arguments: the game's stream when known ([stream], a sink input), else the output's
  /// monitor.
  static List<String> parecArguments(int? stream) => [
    '--format=s16le',
    '--rate=48000',
    '--channels=2',
    '--latency-msec=20',
    '--client-name=AnyPS5',
    if (stream != null) '--monitor-stream=$stream' else '--device=@DEFAULT_MONITOR@',
  ];

  /// ffmpeg's arguments for the output's monitor, where there is no parec.
  static List<String> ffmpegArguments() => [
    '-hide_banner',
    '-loglevel',
    'error',
    '-nostdin',
    '-f',
    'pulse',
    '-fragment_size',
    '3840',
    '-i',
    '@DEFAULT_MONITOR@',
    '-f',
    's16le',
    '-ac',
    '2',
    '-ar',
    '48000',
    'pipe:1',
  ];

  /// The sink input (PulseAudio's name for a program's playing stream) of one of [pids], from
  /// `pactl list sink-inputs` in the C locale; null when none of them plays.
  static int? sinkInputOf(String listing, Set<int> pids) {
    int? current;
    for (final line in listing.split('\n')) {
      final header = RegExp(r'^Sink Input #(\d+)').firstMatch(line.trim());
      if (header != null) {
        current = int.parse(header.group(1)!);
        continue;
      }
      final property = RegExp(r'^application\.process\.id = "(\d+)"').firstMatch(line.trim());
      if (property != null && current != null && pids.contains(int.parse(property.group(1)!))) return current;
    }
    return null;
  }

  /// [pid] and every process under it, from /proc.
  static Set<int> processTree(int pid, {String proc = '/proc'}) {
    final parents = <int, int>{};
    try {
      for (final entry in Directory(proc).listSync(followLinks: false)) {
        final id = int.tryParse(entry.path.split('/').last);
        if (id == null) continue;
        try {
          final stat = File('${entry.path}/stat').readAsStringSync();
          // "pid (name) state ppid ...": the name may hold spaces and brackets.
          final fields = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
          parents[id] = int.parse(fields[1]);
        } on Object {
          continue;
        }
      }
    } on FileSystemException {
      return {pid};
    }
    final tree = {pid};
    var grew = true;
    while (grew) {
      grew = false;
      parents.forEach((child, parent) {
        if (tree.contains(parent) && tree.add(child)) grew = true;
      });
    }
    return tree;
  }

  Future<int?> _findStream() async {
    try {
      final listed = await _run('pactl', ['list', 'sink-inputs']);
      if (listed.exitCode != 0) return null;
      return sinkInputOf(listed.stdout as String, processTree(pid));
    } on Object {
      return null;
    }
  }

  @override
  Future<void> start(SoundSink sink) async {
    if (_running) return;
    _running = true;
    _sink = sink;
    await _open(await _findStream());
    // The game opens its sound a little after its window: until then the output's monitor, then
    // the game's stream alone.
    _look = Timer.periodic(lookEvery, (_) async {
      if (!_running || !_usesParec || _stream != null) return;
      final stream = await _findStream();
      if (stream != null && _running && _stream == null) await _open(stream);
    });
  }

  Future<void> _open(int? stream) async {
    final old = _process;
    _process = null;
    old?.kill();
    Process? process;
    if (_usesParec) {
      try {
        process = await _start('parec', parecArguments(stream));
      } on Object {
        _usesParec = false;
      }
    }
    if (process == null && ffmpeg != null) {
      try {
        process = await _start(ffmpeg!, ffmpegArguments());
        stream = null;
      } on Object {
        process = null;
      }
    }
    if (process == null || !_running) {
      process?.kill();
      return;
    }
    _process = process;
    _stream = stream;
    final sink = _sink;
    process.stdout.listen((data) {
      if (_process == process && sink != null) sink(data is Uint8List ? data : Uint8List.fromList(data));
    }, onError: (_) {});
    process.stderr.listen((_) {}, onError: (_) {});
    unawaited(
      process.exitCode.then((_) async {
        if (_process != process || !_running) return;
        // The game's stream ended (it reopened its sound) or parec failed: look again shortly.
        _process = null;
        _stream = null;
        await Future<void>.delayed(const Duration(seconds: 1));
        if (_running && _process == null) await _open(await _findStream());
      }),
    );
  }

  @override
  Future<void> stop() async {
    _running = false;
    _look?.cancel();
    _look = null;
    final process = _process;
    _process = null;
    _stream = null;
    process?.kill();
  }
}

/// Sound made steady for an encoder that takes it as a continuous stream (ffmpeg's stdin):
/// whatever came is passed on as time goes, silence is put in where the computer played
/// nothing (a loopback gives no samples while nothing plays) so the sound keeps pace with the
/// picture, and a backlog is cut short so it never runs late.
class SteadyPcm {
  SteadyPcm(this.out, {int Function()? microseconds})
    : _clock = microseconds ?? Stopwatch().elapsedMicrosecondsStarted();

  final void Function(Uint8List samples) out;
  final int Function() _clock;

  static const bytesPerSecond = 48000 * 4;

  /// How far behind time the sound may run before silence fills the gap: room for a source
  /// that delivers in bursts.
  static const cushion = bytesPerSecond * 40 ~/ 1000;

  /// The most that may wait; past [backlog] it is cut to [keep].
  static const backlog = bytesPerSecond * 250 ~/ 1000;
  static const keep = bytesPerSecond * 100 ~/ 1000;

  final _queue = BytesBuilder(copy: true);
  int? _begin;
  int _written = 0;

  int get written => _written;
  int get waiting => _queue.length;

  void add(Uint8List samples) {
    _begin ??= _clock();
    _queue.add(samples);
  }

  /// Passes on what is due now; called often (every 10 to 20 ms).
  void tick() {
    final begin = _begin ??= _clock();
    final elapsed = _clock() - begin;
    final due = (elapsed * 48000 ~/ 1000000) * 4;
    var need = due - _written;
    if (need <= 0) return;
    if (_queue.isNotEmpty) {
      final all = _queue.takeBytes();
      // Whole frames only: a pipe may cut one in two.
      final whole = all.length & ~3;
      final take = need < whole ? need : whole;
      if (take > 0) out(take == all.length ? all : Uint8List.sublistView(all, 0, take));
      _written += take;
      need -= take;
      if (take < all.length) _queue.add(Uint8List.sublistView(all, take));
    }
    if (need > cushion) {
      final silence = (need - cushion) & ~3;
      out(Uint8List(silence));
      _written += silence;
    }
    if (_queue.length > backlog) {
      final all = _queue.takeBytes();
      _queue.add(Uint8List.sublistView(all, (all.length - keep) & ~3));
    }
  }
}

extension on Stopwatch {
  int Function() elapsedMicrosecondsStarted() {
    start();
    return () => elapsedMicroseconds;
  }
}
