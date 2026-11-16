import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';

import 'retro_host_native.dart';

/// A release file held open for its check (anyps5-retro-host docs/protocol.md "Finding and checking
/// the host"). On Windows nothing can write, replace or delete it while it is held; on Linux and
/// macOS it is a close-on-exec descriptor above 3, through which the host can be started
/// ([execPath]). It is hashed from what was opened, never by its path again.
class CheckedFile {
  CheckedFile._(this.path, this._file);

  /// Opens [path]; throws [FileSystemException] when it cannot.
  factory CheckedFile.open(String path) {
    final name = path.toNativeUtf8();
    final error = calloc<Uint8>(256).cast<Utf8>();
    try {
      final file = retroHostOpenChecked(name, error, 256);
      if (file == -1) throw FileSystemException(error.toDartString(), path);
      return CheckedFile._(path, file);
    } finally {
      calloc.free(name);
      calloc.free(error);
    }
  }

  final String path;
  int _file;

  bool get isOpen => _file != -1;

  /// Where the operating system finds this very file to start it, on Linux: `/proc/self/fd/<n>`.
  /// Null elsewhere.
  String? get execPath => Platform.isLinux && isOpen ? '/proc/self/fd/$_file' : null;

  /// The sha256 of the file's bytes, lower-case hex, read on another isolate.
  Future<String> sha256Hex() {
    if (!isOpen) throw StateError('$path is no longer held.');
    final file = _file;
    return Isolate.run(() => _hash(file));
  }

  void close() {
    if (!isOpen) return;
    retroHostCloseChecked(_file);
    _file = -1;
  }

  static const _chunk = 1 << 20;

  static String _hash(int file) {
    final sink = _DigestSink();
    final input = sha256.startChunkedConversion(sink);
    final buffer = calloc<Uint8>(_chunk);
    try {
      var offset = 0;
      for (;;) {
        final got = retroHostReadChecked(file, offset, buffer, _chunk);
        if (got < 0) throw const FileSystemException('The file could not be read.');
        if (got == 0) break;
        input.add(buffer.asTypedList(got));
        offset += got;
      }
    } finally {
      calloc.free(buffer);
    }
    input.close();
    return sink.value.toString();
  }
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
