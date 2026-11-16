// Fails when a launcher built for release or a nightly is a test build (docs/AnyPS5 Desktop -
// Emulator Host Client.md "Debug and test builds"), which may run an unchecked PS1 host and must
// never be published. Run from the repository after `flutter build <system> --release`:
//
//     dart run tool/check_release_build.dart <windows|linux> <built folder>
//
// It reads what Flutter compiled with and what it built, not the command that asked for it:
//
// - The build's configuration: `flutter build windows|linux` writes every --dart-define it was
//   given (on the command line or from --dart-define-from-file) into
//   <system>/flutter/ephemeral/generated_config.cmake as DART_DEFINES, each "NAME=value" base64
//   encoded and the list comma separated (flutter_tools' encodeDartDefines), and passes that to
//   the Dart compiler. The check fails if the test build's define is among them, with any value.
// - The compiled program: a test build writes RetroHostBuild.testMark at start, and the Dart
//   compiler leaves that text out of every other build, as it does with code under kDebugMode
//   in a release. The check fails if the AOT snapshot (data/app.so on Windows, lib/libapp.so on
//   Linux) holds it, or if there is no snapshot to look in.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/retro_host/retro_host_build.dart';
import 'package:path/path.dart' as p;

/// The systems the check knows a Flutter release build of.
enum BuiltSystem { windows, linux }

/// The defines a `generated_config.cmake` says the Dart program was compiled with, decoded as
/// "NAME=value". None when it gives no DART_DEFINES.
List<String> dartDefinesIn(String generatedConfig) {
  final defines = <String>[];
  for (final match in RegExp(r'^\s*"DART_DEFINES=([^"]*)"\s*$', multiLine: true).allMatches(generatedConfig)) {
    for (final encoded in match.group(1)!.split(',')) {
      if (encoded.isEmpty) continue;
      try {
        defines.add(utf8.decode(base64.decode(encoded)));
      } on FormatException {
        throw FormatException('DART_DEFINES holds "$encoded", which is not a base64 define');
      }
    }
  }
  return defines;
}

/// Why the defines make a test build, or null: the test build's define given at all, whatever its
/// value, since no release is compiled with it.
String? testDefineProblem(List<String> defines) {
  for (final define in defines) {
    final name = define.split('=').first;
    if (name == RetroHostBuild.testDefine) return 'the build was compiled with --dart-define=$define';
  }
  return null;
}

/// Where Flutter puts the AOT snapshot in [system]'s built folder.
String snapshotIn(BuiltSystem system, String built) =>
    system == BuiltSystem.windows ? p.join(built, 'data', 'app.so') : p.join(built, 'lib', 'libapp.so');

/// Whether [bytes] hold [text], as the one-byte string a Dart snapshot keeps an ASCII text in, or
/// as UTF-16LE.
bool holdsText(Uint8List bytes, String text) {
  final ascii = latin1.encode(text);
  final wide = Uint8List(ascii.length * 2);
  for (var i = 0; i < ascii.length; i++) {
    wide[i * 2] = ascii[i];
  }
  return _indexOf(bytes, ascii) >= 0 || _indexOf(bytes, wide) >= 0;
}

int _indexOf(Uint8List bytes, List<int> needle) {
  final first = needle.first;
  for (var i = bytes.indexOf(first); i >= 0 && i <= bytes.length - needle.length; i = bytes.indexOf(first, i + 1)) {
    var j = 1;
    while (j < needle.length && bytes[i + j] == needle[j]) {
      j++;
    }
    if (j == needle.length) return i;
  }
  return -1;
}

/// Why the AOT snapshot at [snapshot] is a test build's, or cannot be checked; null when it is not.
String? snapshotProblem(String snapshot) {
  final file = File(snapshot);
  if (!file.existsSync()) return 'no AOT snapshot at $snapshot: is this a release build?';
  if (holdsText(file.readAsBytesSync(), RetroHostBuild.testMark)) {
    return '$snapshot is a test build\'s: it holds "${RetroHostBuild.testMark}"';
  }
  return null;
}

/// Everything wrong with [system]'s build in [built], from the repository at [root]: empty when
/// it is no test build.
List<String> releaseBuildProblems(BuiltSystem system, String built, {String root = '.'}) {
  final problems = <String>[];
  final config = File(p.join(root, system.name, 'flutter', 'ephemeral', 'generated_config.cmake'));
  if (!config.existsSync()) {
    problems.add('no ${config.path}: run the check after flutter build ${system.name}');
  } else {
    try {
      final problem = testDefineProblem(dartDefinesIn(config.readAsStringSync()));
      if (problem != null) problems.add(problem);
    } on FormatException catch (error) {
      problems.add('${config.path}: ${error.message}');
    }
  }
  final problem = snapshotProblem(snapshotIn(system, built));
  if (problem != null) problems.add(problem);
  return problems;
}

void main(List<String> arguments) {
  final system = arguments.length == 2 ? BuiltSystem.values.asNameMap()[arguments[0]] : null;
  if (system == null) {
    stderr.writeln('usage: dart run tool/check_release_build.dart <windows|linux> <built folder>');
    exit(64);
  }
  final problems = releaseBuildProblems(system, arguments[1]);
  if (problems.isNotEmpty) {
    for (final problem in problems) {
      stderr.writeln('test build: $problem');
    }
    stderr.writeln('A test build may run an unchecked PS1 host and must never be published.');
    exit(1);
  }
  stdout.writeln(
    '${arguments[1]} is a release build: no test build define, no test build in ${snapshotIn(system, arguments[1])}',
  );
}
