import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// A process whose stdout a test writes and which runs until it is killed or told to end.
class StreamingProcess implements Process {
  StreamingProcess({this.pid = 5151});

  @override
  final int pid;

  final _out = StreamController<List<int>>();
  final _err = StreamController<List<int>>.broadcast();
  final _exit = Completer<int>();
  final stdinBytes = BytesBuilder(copy: true);
  final killed = <ProcessSignal>[];

  bool get ended => _exit.isCompleted;

  void write(List<int> bytes) => _out.add(bytes);

  /// What the process says on its standard error.
  void writeError(String text) => _err.add(text.codeUnits);

  void end([int code = 0]) {
    if (!_exit.isCompleted) _exit.complete(code);
    unawaited(_out.close());
    unawaited(_err.close());
  }

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed.add(signal);
    end(-1);
    return true;
  }

  @override
  Future<int> get exitCode => _exit.future;

  @override
  Stream<List<int>> get stdout => _out.stream;

  @override
  Stream<List<int>> get stderr => _err.stream;

  @override
  IOSink get stdin {
    final controller = StreamController<List<int>>();
    controller.stream.listen(stdinBytes.add);
    return IOSink(controller.sink);
  }
}

/// FLV as ffmpeg writes it for H.264: the file header, then tags.
abstract final class FlvBuilder {
  static Uint8List header() => Uint8List.fromList([0x46, 0x4C, 0x56, 1, 1, 0, 0, 0, 9, 0, 0, 0, 0]);

  static Uint8List tag(int type, List<int> data, {int time = 0}) {
    final size = data.length;
    return Uint8List.fromList([
      type,
      size >> 16 & 0xFF,
      size >> 8 & 0xFF,
      size & 0xFF,
      time >> 16 & 0xFF,
      time >> 8 & 0xFF,
      time & 0xFF,
      time >> 24 & 0xFF,
      0,
      0,
      0,
      ...data,
      (size + 11) >> 24 & 0xFF,
      (size + 11) >> 16 & 0xFF,
      (size + 11) >> 8 & 0xFF,
      (size + 11) & 0xFF,
    ]);
  }

  static const sps = [0x67, 0x4D, 0x40, 0x1F, 0xAA];
  static const pps = [0x68, 0xEE, 0x3C, 0x80];

  /// The AVC sequence header with [sps] and [pps].
  static Uint8List sequence() => tag(9, [
    0x17, 0, 0, 0, 0,
    1, 0x4D, 0x40, 0x1F, 0xFF, 0xE1, 0, sps.length, ...sps, 1, 0, pps.length, ...pps,
  ]);

  /// A frame of NAL units, each with a 4-byte length.
  static Uint8List frame(List<List<int>> units, {required bool key, int time = 0}) => tag(9, [
    key ? 0x17 : 0x27, 1, 0, 0, 0,
    for (final unit in units) ...[unit.length >> 24 & 0xFF, unit.length >> 16 & 0xFF, unit.length >> 8 & 0xFF, unit.length & 0xFF, ...unit],
  ], time: time);

  /// The onMetaData script tag ffmpeg writes first.
  static Uint8List metadata() => tag(18, [2, 0, 10, ...'onMetaData'.codeUnits, 8, 0, 0, 0, 0, 0, 0, 9]);
}
