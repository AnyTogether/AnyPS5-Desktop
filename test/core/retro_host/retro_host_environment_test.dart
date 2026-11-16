import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:anyps5_desktop/core/retro_host/retro_host_client.dart';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('on Windows an added variable replaces one whose name differs only in case', () {
    expect(
      retroHostEnvironment({'PATH': r'C:\old', 'TEMP': r'C:\t'}, {'Path': r'C:\new'}, windows: true),
      unorderedEquals([r'TEMP=C:\t', r'Path=C:\new']),
    );
  });

  test('on Windows the last of two added names that differ only in case is kept', () {
    expect(retroHostEnvironment({'PATH': r'C:\old'}, {'PATH': r'C:\first', 'Path': r'C:\second'}, windows: true), [
      r'Path=C:\second',
    ]);
  });

  test('elsewhere names that differ in case are different variables', () {
    expect(
      retroHostEnvironment({'PATH': '/old'}, {'Path': '/new'}, windows: false),
      unorderedEquals(['PATH=/old', 'Path=/new']),
    );
  });

  test('an added variable replaces one of the same name', () {
    expect(retroHostEnvironment({'A': '1', 'B': '2'}, {'A': '3'}, windows: false), unorderedEquals(['A=3', 'B=2']));
  });

  test('on Windows a host given added variables gets a sorted block with the hidden drive directories', () async {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final setVariable = kernel32
        .lookupFunction<Int32 Function(Pointer<Utf16>, Pointer<Utf16>), int Function(Pointer<Utf16>, Pointer<Utf16>)>(
          'SetEnvironmentVariableW',
        );
    final work = Directory.systemTemp.createTempSync('retro-host-env-');
    final name = '=Q:'.toNativeUtf16();
    final value = r'Q:\retro-host-test'.toNativeUtf16();
    try {
      expect(setVariable(name, value), isNot(0), reason: 'SetEnvironmentVariableW');
      final out = p.join(work.path, 'out.txt');
      final client = RetroHostClient.start(
        command: [_python(), '-I', '-c', _reportEnvironment, out],
        environment: const {'ANYPS5_RETRO_HOST_TEST': '1'},
      );
      unawaited(client.ready.then((_) {}, onError: (_) {}));
      await client.exited.timeout(const Duration(seconds: 20));
      await client.close();
      expect(File(out).readAsLinesSync(), [r'Q:\retro-host-test', 'sorted', '1']);
    } finally {
      setVariable(name, nullptr);
      calloc.free(name);
      calloc.free(value);
      work.deleteSync(recursive: true);
    }
  }, skip: Platform.isWindows ? null : 'Windows only');
}

/// Writes to the file named by its first argument: the value of `=Q:`, whether the environment
/// block is sorted by name without regard to case, and the value of ANYPS5_RETRO_HOST_TEST.
const _reportEnvironment = r'''
import ctypes, os, sys
k = ctypes.windll.kernel32
k.GetEnvironmentStringsW.restype = ctypes.c_void_p
at = k.GetEnvironmentStringsW()
names = []
while True:
    entry = ctypes.wstring_at(at)
    if not entry:
        break
    names.append(entry[:entry.index("=", 1)].upper())
    at += (len(entry) + 1) * 2
b = ctypes.create_unicode_buffer(1024)
n = k.GetEnvironmentVariableW("=Q:", b, 1024)
lines = [b.value if n else "<none>", "sorted" if names == sorted(names) else "unsorted", os.environ.get("ANYPS5_RETRO_HOST_TEST", "")]
open(sys.argv[1], "w").write("\n".join(lines) + "\n")
''';

String _python() {
  final found = Process.runSync('where', ['python']);
  final path = (found.stdout as String)
      .split(RegExp(r'\r?\n'))
      .firstWhere((line) => line.trim().isNotEmpty, orElse: () => '');
  if (path.isEmpty) throw StateError('python is not on PATH');
  return path.trim();
}
