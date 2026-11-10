import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'toolkit.dart';

/// A relinker option a player can switch on for one game (Advanced › Rebuild options), used by
/// the game's next rebuild. Only these ever reach the relinker: whatever else a settings file
/// names is ignored. An option that chooses the platform, the target or a path, or that can give
/// a broken game without saying so, does not belong here.
enum RelinkerFlag {
  /// Passes each function import of the executable through libc.prx's call tracer, so that
  /// detailed logging (APS5_TRACE_CALLS) can record the game's system library calls.
  traceImports('--trace-imports', 'TraceImport_nid_no_patch');

  const RelinkerFlag(this.option, this.libcExport);

  /// As the relinker spells it.
  final String option;

  /// What the toolkit's libc.prx has to export for a game relinked with this option to start:
  /// the executable binds it without a fallback. Null when it needs nothing.
  final String? libcExport;
}

extension RelinkerFlagSupport on Toolkit {
  /// Whether this toolkit can relink with [flag]: its relinker knows the option and its libc.prx
  /// has what the option needs. An engine that lacks it (an older one, upstream's) unlocks the
  /// game without it. Read from the files, once per change of them.
  bool supports(RelinkerFlag flag) {
    if (!_fileContains(relinker, flag.option)) return false;
    final export = flag.libcExport;
    return export == null || _fileContains(p.join(libraries, 'libc.prx'), export);
  }
}

final _answers = <String, bool>{};

bool _fileContains(String path, String text) {
  final stat = File(path).statSync();
  if (stat.type == FileSystemEntityType.notFound) return false;
  return _answers.putIfAbsent(
    '$path\n$text\n${stat.size}\n${stat.modified.microsecondsSinceEpoch}',
    () => _scan(path, utf8.encode(text)),
  );
}

/// Searches a file in 1 MiB reads, keeping the end of each so a match across two reads is found.
bool _scan(String path, List<int> needle) {
  RandomAccessFile? file;
  try {
    file = File(path).openSync();
    final buffer = Uint8List(1 << 20);
    var kept = 0;
    while (true) {
      final read = file.readIntoSync(buffer, kept);
      if (read == 0) return false;
      final end = kept + read;
      if (_contains(buffer, end, needle)) return true;
      kept = min(needle.length - 1, end);
      buffer.setAll(0, buffer.sublist(end - kept, end));
    }
  } on FileSystemException {
    return false;
  } finally {
    file?.closeSync();
  }
}

bool _contains(Uint8List bytes, int end, List<int> needle) {
  final last = end - needle.length;
  for (var start = 0; start <= last; start++) {
    var matched = 0;
    while (matched < needle.length && bytes[start + matched] == needle[matched]) {
      matched++;
    }
    if (matched == needle.length) return true;
  }
  return false;
}
