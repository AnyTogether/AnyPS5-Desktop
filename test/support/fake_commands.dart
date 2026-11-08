import 'dart:async';
import 'dart:io';

import 'package:anyps5_desktop/core/engine_checkout.dart';
import 'package:path/path.dart' as p;

import 'fake_toolkit.dart';

/// One command a [FakeCommands] was asked to run.
class FakeCall {
  FakeCall(this.executable, this.arguments, this.workingDirectory, this.environment);
  final String executable;
  final List<String> arguments;
  final String workingDirectory;
  final Map<String, String>? environment;

  /// `git pull --ff-only`, as a test names it.
  String get line => [p.basename(executable), ...arguments].join(' ');

  @override
  String toString() => line;
}

/// What a command does in a [FakeCommands]: the lines it prints and its exit code; [missing]
/// throws ProcessException as a program not installed does; [hold] waits until it completes
/// (or the command is cancelled); [effect] changes the disk the way the real command would.
class FakeResult {
  const FakeResult({this.code = 0, this.lines = const [], this.missing = false, this.hold, this.effect, this.output});
  final int code;
  final List<String> lines;

  /// The lines, read when the command runs (a commit that changes).
  final List<String> Function()? output;
  final bool missing;
  final Completer<void>? hold;
  final void Function()? effect;
}

/// A [CommandRunner] answering from a table: the first key a command's line starts with.
/// Unknown commands succeed and print nothing.
class FakeCommands extends CommandRunner {
  FakeCommands([Map<String, FakeResult>? results]) : results = results ?? {};

  final Map<String, FakeResult> results;
  final calls = <FakeCall>[];

  /// The lines of the commands run, `git status --porcelain --untracked-files=no` and so on.
  List<String> get lines => [for (final call in calls) call.line];

  @override
  Future<int> run(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    Map<String, String>? environment,
    void Function(String line)? onLine,
    CommandCancel? cancel,
  }) async {
    final call = FakeCall(executable, arguments, workingDirectory, environment);
    calls.add(call);
    final result = results.entries.where((entry) => call.line.startsWith(entry.key)).firstOrNull?.value;
    if (result == null) return 0;
    if (result.missing) throw ProcessException(executable, arguments, 'No such file or directory', 2);
    await Future<void>.delayed(Duration.zero);
    for (final line in result.output?.call() ?? result.lines) {
      onLine?.call(line);
    }
    if (result.hold case final Completer<void> hold) {
      final stopped = Completer<void>();
      final forget = cancel?.listen(stopped.complete);
      await Future.any([hold.future, stopped.future]);
      forget?.call();
      if (cancel?.cancelled ?? false) return -15;
    }
    result.effect?.call();
    return result.code;
  }
}

/// A git checkout of the engine's source with a configured build/ whose relinker and libraries
/// are the fake toolkit's, in the CMake build tree's layout. [built] false leaves the build
/// folder configured but empty; [configured] false leaves no build folder at all. Upstream's tree
/// unless [arm] (AnyPS5-ARM's, which has tools/package_arm_toolkit.py).
String makeFakeCheckout(
  String folder, {
  bool configured = true,
  bool built = true,
  String? compiler,
  bool arm = false,
}) {
  Directory(p.join(folder, 'core', 'relinker')).createSync(recursive: true);
  Directory(p.join(folder, 'core', 'libs', 'prx')).createSync(recursive: true);
  Directory(p.join(folder, '.git')).createSync(recursive: true);
  File(p.join(folder, 'CMakeLists.txt')).writeAsStringSync('project(AnyPS5)\n');
  if (arm) {
    Directory(p.join(folder, 'tools')).createSync(recursive: true);
    File(p.join(folder, 'tools', 'package_arm_toolkit.py')).writeAsStringSync('# AnyPS5-ARM\n');
  }
  if (!configured) return folder;
  configureFakeCheckout(folder, compiler: compiler);
  if (built) buildFakeCheckout(folder);
  return folder;
}

/// What `cmake -S . -B build -G Ninja ...` writes: build/CMakeCache.txt.
void configureFakeCheckout(String folder, {String? compiler}) {
  final build = p.join(folder, 'build');
  Directory(build).createSync(recursive: true);
  File(p.join(build, 'CMakeCache.txt')).writeAsStringSync(
    '# This is the CMakeCache file.\n'
    'CMAKE_CXX_COMPILER:FILEPATH=${compiler ?? '/usr/bin/g++'}\n'
    'CMAKE_HOME_DIRECTORY:INTERNAL=$folder\n',
  );
}

/// What `cmake --build build --target relinker libs` writes: the relinker and the libraries.
void buildFakeCheckout(String folder, {String kernel = 'kernel library'}) {
  final staging = makeFakeToolkit(p.join(folder, '.staging'));
  final relinkerFolder = p.join(folder, 'build', 'core', 'relinker');
  final libs = p.join(folder, 'build', 'core', 'libs', 'libs');
  Directory(relinkerFolder).createSync(recursive: true);
  Directory(libs).createSync(recursive: true);
  for (final name in ['relinker', 'relinker.exe']) {
    File(p.join(staging, name)).copySync(p.join(relinkerFolder, name));
    if (!Platform.isWindows) Process.runSync('chmod', ['755', p.join(relinkerFolder, name)]);
  }
  File(p.join(libs, 'libkernel.prx')).writeAsStringSync(kernel);
  File(p.join(libs, 'libSceVideoOut.prx')).writeAsStringSync('video library');
  File(p.join(libs, 'mimalloc.dll')).writeAsStringSync('mimalloc');
  Directory(staging).deleteSync(recursive: true);
}
