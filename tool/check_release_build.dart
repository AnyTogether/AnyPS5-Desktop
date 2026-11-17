// Fails when a launcher built for release or a nightly is a test build (docs/AnyPS5 Desktop -
// Emulator Host Client.md "Debug and test builds"), which may run an unchecked PS1 host and must
// never be published. Run from the repository after `flutter build <system> --release`:
//
//     dart run tool/check_release_build.dart <windows|linux> <built folder>
//
// or on the files of a release before they are signed (packaging/sign-release.sh does):
//
//     dart run tool/check_release_build.dart files <release file>...
//
// A built folder is checked by what Flutter compiled with and what it built, not the command
// that asked for it:
//
// - The build's configuration: `flutter build windows|linux` writes every --dart-define it was
//   given (on the command line or from --dart-define-from-file) into
//   <system>/flutter/ephemeral/generated_config.cmake as DART_DEFINES, each "NAME=value" base64
//   encoded and the list comma separated (flutter_tools' encodeDartDefines), and passes that to
//   the Dart compiler. The check fails if the test build's define is among them, with any value.
//   flutter_tools writes the line only when there are defines, but every `flutter build` gives
//   its own FLUTTER_VERSION define (FlutterCommand.flutterVersionDefine), so a configuration
//   without the line, or without that define, is one the check cannot read and fails too.
// - The compiled program: a test build writes RetroHostBuild.testMark where it looks for the
//   unchecked host (RetroHostInstall.locate), and the Dart compiler leaves that text out of every
//   other build, as it does with code under kDebugMode in a release. The check fails if the AOT
//   snapshot (data/app.so on Windows, lib/libapp.so on Linux) holds it, or if there is no
//   snapshot to look in.
//
// Release files are checked by the snapshot each holds (tool/release_files.dart reads it out):
// the Windows zip's, the .tar.gz's, the .deb's and the AppImage's. The Windows installer is read
// whole and must hold no mark and, byte for byte, the snapshot of the Windows zip checked with
// it. Any other file, or one that cannot be read as its packaging writes it, fails.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/retro_host/retro_host_build.dart';
import 'package:path/path.dart' as p;

import 'release_files.dart';

/// The systems the check knows a Flutter release build of.
enum BuiltSystem { windows, linux }

/// The define every `flutter build` compiles with, giving the Flutter version.
const flutterVersionDefine = 'FLUTTER_VERSION';

/// The defines a `generated_config.cmake` says the Dart program was compiled with, decoded as
/// "NAME=value". Null when it has no DART_DEFINES line.
List<String>? dartDefinesIn(String generatedConfig) {
  List<String>? defines;
  for (final match in RegExp(r'^\s*"DART_DEFINES=([^"]*)"\s*$', multiLine: true).allMatches(generatedConfig)) {
    defines ??= [];
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

/// Why the defines make a test build, or cannot be read, or null: the test build's define given at
/// all, whatever its value, since no release is compiled with it; no DART_DEFINES line, or none
/// with the [flutterVersionDefine] `flutter build` always gives.
String? testDefineProblem(List<String>? defines) {
  if (defines == null) return 'no DART_DEFINES line, which every flutter build writes';
  for (final define in defines) {
    final name = define.split('=').first;
    if (name == RetroHostBuild.testDefine) return 'the build was compiled with --dart-define=$define';
  }
  if (!defines.any((define) => define.split('=').first == flutterVersionDefine)) {
    return 'DART_DEFINES has no $flutterVersionDefine, which every flutter build gives';
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
  return indexOfBytes(bytes, ascii) >= 0 || indexOfBytes(bytes, wide) >= 0;
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

/// Why the release [files], about to be signed, may not be: each one a test build's, or one the
/// check cannot read, as [ReleaseFile] says. Empty when every one holds a release's snapshot.
List<String> releaseFileProblems(List<String> files) {
  final problems = <String>[];
  final zipSnapshots = <Uint8List>[];
  final installers = <String>[];
  for (final path in files) {
    final kind = ReleaseFile.named(p.basename(path));
    if (kind == null) {
      problems.add(
        '$path is no launcher release file the check can read (the installer .exe, the Windows '
        '.zip, the Linux .tar.gz, the .deb or the AppImage), and only checked files are signed',
      );
    } else if (kind == ReleaseFile.installer) {
      installers.add(path);
    } else {
      try {
        final snapshot = kind.snapshotIn(File(path).readAsBytesSync());
        if (holdsText(snapshot, RetroHostBuild.testMark)) {
          problems.add('$path is a test build\'s: its ${kind.snapshot} holds "${RetroHostBuild.testMark}"');
        } else if (kind == ReleaseFile.windowsZip) {
          zipSnapshots.add(snapshot);
        }
      } on Object catch (error) {
        problems.add('$path cannot be read as ${kind.description}: ${_reason(error)}');
      }
    }
  }
  for (final path in installers) {
    try {
      final data = installerData(File(path).readAsBytesSync());
      if (holdsText(data, RetroHostBuild.testMark)) {
        problems.add('$path is a test build\'s: a file it installs holds "${RetroHostBuild.testMark}"');
      } else if (!zipSnapshots.any((snapshot) => indexOfBytes(data, snapshot) >= 0)) {
        problems.add(
          '$path installs no data/app.so of a checked Windows zip: an installer is signed only with '
          'the zip built beside it, whose snapshot it must install byte for byte',
        );
      }
    } on Object catch (error) {
      problems.add('$path cannot be read as ${ReleaseFile.installer.description}: ${_reason(error)}');
    }
  }
  return problems;
}

String _reason(Object error) => switch (error) {
  FormatException(:final message) => message,
  FileSystemException(:final message, :final osError) => osError == null ? message : '$message ($osError)',
  _ => '$error',
};

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
      if (problem != null) problems.add('${config.path}: $problem');
    } on FormatException catch (error) {
      problems.add('${config.path}: ${error.message}');
    }
  }
  final problem = snapshotProblem(snapshotIn(system, built));
  if (problem != null) problems.add(problem);
  return problems;
}

void main(List<String> arguments) {
  if (arguments.length > 1 && arguments.first == 'files') return _checkFiles(arguments.sublist(1));
  final system = arguments.length == 2 ? BuiltSystem.values.asNameMap()[arguments[0]] : null;
  if (system == null) {
    stderr
      ..writeln('usage: dart run tool/check_release_build.dart <windows|linux> <built folder>')
      ..writeln('       dart run tool/check_release_build.dart files <release file>...');
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

void _checkFiles(List<String> files) {
  final problems = releaseFileProblems(files);
  if (problems.isNotEmpty) {
    for (final problem in problems) {
      stderr.writeln('refused: $problem');
    }
    stderr.writeln('A test build may run an unchecked PS1 host and must never be published.');
    exit(1);
  }
  for (final file in files) {
    stdout.writeln('$file holds a release build: no test build in it');
  }
}
