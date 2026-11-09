import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'host.dart';

/// A git checkout of the AnyPS5 engine's source (upstream's tree or AnyPS5-ARM's) chosen as the
/// engine folder, built in place with CMake:
///
/// ```text
/// <checkout>/
///     CMakeLists.txt, core/relinker/, core/libs/, .git
///     build/                       the configured build folder (CMakeCache.txt)
///         core/relinker/relinker | relinker.exe
///         core/libs/libs/*.prx     (mimalloc.dll and mimalloc-redirect.dll beside them on Windows)
/// ```
///
/// On Windows the MinGW runtime (libgcc_s_seh-1.dll, libstdc++-6.dll, libwinpthread-1.dll) is
/// in the compiler's folder, which the build's CMakeCache.txt names; a game's libs/ gets it as
/// the release archives carry it.
class EngineCheckout {
  EngineCheckout._(this.root, this.system, this.buildFolder);

  /// The checkout at [root], null when the folder is not the engine's source tree.
  static EngineCheckout? at(String root, {HostSystem system = HostSystem.linux}) {
    try {
      if (!File(p.join(root, 'CMakeLists.txt')).existsSync()) return null;
      if (!Directory(p.join(root, 'core', 'relinker')).existsSync()) return null;
      if (!Directory(p.join(root, 'core', 'libs')).existsSync()) return null;
    } on FileSystemException {
      return null;
    }
    return EngineCheckout._(root, system, findBuild(root, system));
  }

  /// The MinGW runtime a Windows game needs beside its libraries.
  static const windowsRuntime = ['libgcc_s_seh-1.dll', 'libstdc++-6.dll', 'libwinpthread-1.dll'];

  /// The configured build folder of [root]: build/ when CMake set it up, else another folder at
  /// the top (build-*, cmake-build-*) with a CMakeCache.txt, one with the relinker built first;
  /// null when none was configured yet.
  static String? findBuild(String root, HostSystem system) {
    bool configured(String folder) => File(p.join(folder, 'CMakeCache.txt')).existsSync();
    bool built(String folder) => File(p.join(folder, 'core', 'relinker', system.relinkerName)).existsSync();
    final preferred = p.join(root, 'build');
    if (configured(preferred)) return preferred;
    List<String> others;
    try {
      others =
          Directory(root)
              .listSync()
              .whereType<Directory>()
              .map((folder) => folder.path)
              .where((folder) {
                final name = p.basename(folder).toLowerCase();
                return name.startsWith('build') || name.startsWith('cmake-build');
              })
              .where(configured)
              .toList()
            ..sort();
    } on FileSystemException {
      return null;
    }
    return others.where(built).firstOrNull ?? others.firstOrNull;
  }

  final String root;
  final HostSystem system;

  /// The configured build folder, null before CMake set one up.
  final String? buildFolder;

  /// The build folder the relinker and the libraries come from (build/ before one is configured).
  String get build => buildFolder ?? p.join(root, 'build');

  String get relinker => p.join(build, 'core', 'relinker', system.relinkerName);
  String get libraries => p.join(build, 'core', 'libs', 'libs');

  /// Whether the folder is a git checkout (.git is a folder, or a file in a worktree).
  bool get isGit => FileSystemEntity.typeSync(p.join(root, '.git')) != FileSystemEntityType.notFound;

  /// Whether it is AnyPS5-ARM's tree (it packages AnyPS5-ARM's engine), not upstream's.
  bool get isArm {
    try {
      return File(p.join(root, 'tools', 'package_arm_toolkit.py')).existsSync();
    } on FileSystemException {
      return false;
    }
  }

  /// The guide to building this tree on this system: AnyPS5-ARM's Windows and Linux engine guide
  /// for its tree, upstream's build guide (its Windows or its Linux part) for upstream's.
  Uri get guide {
    if (isArm) return armGuide;
    return system == HostSystem.windows ? upstreamWindowsGuide : upstreamLinuxGuide;
  }

  static final armGuide = Uri.parse(
    'https://github.com/AnyTogether/AnyPS5-ARM/blob/main/docs/dev/WINDOWS_LINUX_ENGINE.md',
  );
  static final upstreamWindowsGuide = Uri.parse(
    'https://github.com/boykopovar/AnyPS5/blob/main/docs/dev/BUILD.md#windows-setup-and-troubleshooting',
  );
  static final upstreamLinuxGuide = Uri.parse(
    'https://github.com/boykopovar/AnyPS5/blob/main/docs/dev/BUILD.md#requirements',
  );

  /// The build folder Update from Git sets up when there is none, as both guides name it.
  String get newBuildFolder => p.join(root, 'build');

  /// The C and C++ compilers the guides configure with: MinGW-w64's on Windows, the system's GCC
  /// on Linux, found on PATH.
  static const cCompiler = 'gcc';
  static const cxxCompiler = 'g++';

  /// `cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=gcc
  /// -DCMAKE_CXX_COMPILER=g++`: the configure both guides run once.
  static const configureArguments = [
    '-S',
    '.',
    '-B',
    'build',
    '-G',
    'Ninja',
    '-DCMAKE_BUILD_TYPE=Release',
    '-DCMAKE_C_COMPILER=$cCompiler',
    '-DCMAKE_CXX_COMPILER=$cxxCompiler',
  ];

  /// The build folder's CMakeCache.txt entries (NAME:TYPE=value), read once.
  late final Map<String, String> cache = () {
    final folder = buildFolder;
    if (folder == null) return const <String, String>{};
    try {
      final entries = <String, String>{};
      for (final line in File(p.join(folder, 'CMakeCache.txt')).readAsLinesSync()) {
        if (line.startsWith('#') || line.startsWith('//')) continue;
        final colon = line.indexOf(':');
        final equals = line.indexOf('=');
        if (colon <= 0 || equals <= colon) continue;
        entries[line.substring(0, colon)] = line.substring(equals + 1);
      }
      return entries;
    } on FileSystemException {
      return const <String, String>{};
    }
  }();

  /// The CMake that configured the build (CMAKE_COMMAND), else `cmake` from PATH.
  String get cmake {
    final command = cache['CMAKE_COMMAND'];
    if (command != null && command.isNotEmpty && File(command).existsSync()) return command;
    return 'cmake';
  }

  /// The folder of the C++ compiler the build uses, null when the cache does not name one with
  /// its full path.
  String? get compilerFolder {
    final compiler = cache['CMAKE_CXX_COMPILER'];
    if (compiler == null || compiler.isEmpty || compiler.endsWith('-NOTFOUND')) return null;
    if (!p.isAbsolute(compiler)) return null;
    return p.dirname(compiler);
  }

  /// On Windows, the MinGW runtime DLLs in the compiler's folder; none elsewhere.
  List<String> get runtimeLibraries {
    final folder = compilerFolder;
    if (system != HostSystem.windows || folder == null) return const [];
    return [
      for (final name in windowsRuntime)
        if (File(p.join(folder, name)).existsSync()) p.join(folder, name),
    ];
  }

  /// Folders a tool of the build needs on PATH (the compiler's, for its DLLs on Windows).
  List<String> get pathFolders => [?compilerFolder];
}

/// A request to stop a running command.
class CommandCancel {
  bool _cancelled = false;
  final _listeners = <void Function()>[];

  bool get cancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final listener in List.of(_listeners)) {
      listener();
    }
  }

  /// Calls [listener] when cancelled (at once when already); the returned function forgets it.
  void Function() listen(void Function() listener) {
    if (_cancelled) {
      listener();
      return () {};
    }
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }
}

/// Runs a program away from the interface and hands each line it prints (stdout and stderr);
/// replaceable in tests.
abstract class CommandRunner {
  const CommandRunner();

  /// Runs [executable] in [workingDirectory] and returns its exit code. Throws ProcessException
  /// when it cannot start (not installed); [cancel] stops it and its children.
  Future<int> run(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    Map<String, String>? environment,
    void Function(String line)? onLine,
    CommandCancel? cancel,
  });
}

/// dart:io's processes: stopped with taskkill /T on Windows, the children first on POSIX.
class SystemCommands extends CommandRunner {
  const SystemCommands();

  @override
  Future<int> run(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    Map<String, String>? environment,
    void Function(String line)? onLine,
    CommandCancel? cancel,
  }) async {
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
    );
    final forget = cancel?.listen(() => unawaited(_stop(process)));
    try {
      Future<void> read(Stream<List<int>> stream) => stream
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .forEach((line) => onLine?.call(line));
      final out = read(process.stdout);
      final err = read(process.stderr);
      final code = await process.exitCode;
      // A child left behind can hold the output open; what the program printed is in by now.
      await Future.wait([out, err]).timeout(const Duration(seconds: 2), onTimeout: () => const []);
      return code;
    } finally {
      forget?.call();
    }
  }

  static Future<void> _stop(Process process) async {
    try {
      if (Platform.isWindows) {
        await Process.run('taskkill', ['/PID', '${process.pid}', '/T', '/F']);
      } else {
        // cmake --build leaves ninja and the compilers to their own; they go first.
        await Process.run('pkill', ['-TERM', '-P', '${process.pid}']);
        process.kill(ProcessSignal.sigterm);
      }
    } on Object {
      process.kill();
    }
  }
}

/// The steps of an update from git; [configuring] only for a checkout without a build folder.
enum GitStep { checking, pulling, submodules, configuring, building }

/// Why an update from git stopped.
enum GitFailureKind {
  /// git is not installed (or not on PATH).
  noGit,

  /// CMake is not installed (or not on PATH).
  noCmake,

  /// Ninja is not installed (or not on PATH): setting up a build folder needs it.
  noNinja,

  /// No C++ compiler (g++) on PATH: setting up a build folder needs it.
  noCompiler,

  /// The folder is not a git checkout.
  notGit,

  /// The tree has changes not committed: nothing was pulled.
  dirty,

  /// CMake never configured a build folder (no longer said: the update sets one up).
  noBuild,

  /// CMake could not set up the build folder (a library or tool it looks for is missing).
  configure,

  /// git pull --ff-only failed (the branch went another way, no upstream, offline).
  pull,

  /// git submodule update failed.
  submodules,

  /// The build failed.
  build,

  /// Stopped by the user.
  cancelled,
}

class GitUpdateFailure implements Exception {
  const GitUpdateFailure(this.kind, [this.tail = const []]);

  final GitFailureKind kind;

  /// The last lines the failing command printed.
  final List<String> tail;

  /// Whether nothing was changed: the tree and the build are as they were.
  bool get untouched => kind != GitFailureKind.submodules && kind != GitFailureKind.build;

  /// Whether the build guide says how to put it right (a tool to install, CMake's setup).
  bool get guideHelps => const {
    GitFailureKind.noGit,
    GitFailureKind.noCmake,
    GitFailureKind.noNinja,
    GitFailureKind.noCompiler,
    GitFailureKind.configure,
  }.contains(kind);

  @override
  String toString() => 'GitUpdateFailure(${kind.name}${tail.isEmpty ? '' : ': ${tail.last}'})';
}

/// What an update from git did: the commit before and after.
class GitUpdateResult {
  const GitUpdateResult(this.before, this.after);
  final String before;
  final String after;
  bool get pulled => before != after;
}

/// Pulls an engine checkout and builds its relinker and libraries:
/// `git pull --ff-only`, `git submodule update --init --recursive`,
/// `cmake --build <build> --target relinker libs`. Refuses a tree with changes not committed.
/// A checkout without a build folder gets one first, as the build guides set it up
/// ([EngineCheckout.configureArguments]), once Ninja and a C++ compiler are found.
class EngineGit {
  EngineGit(this.checkout, {this.runner = const SystemCommands(), Map<String, String>? environment})
    : _environment = environment ?? Platform.environment;

  final EngineCheckout checkout;
  final CommandRunner runner;
  final Map<String, String> _environment;

  /// The most lines kept of what the commands printed.
  static const keptLines = 400;

  /// The lines a failure shows.
  static const tailLines = 40;

  /// What the commands printed, the last [keptLines].
  final output = <String>[];

  /// git asks nothing on a terminal the launcher does not have: a remote that wants a password
  /// fails instead of waiting forever.
  Map<String, String> get gitEnvironment => {
    'GIT_TERMINAL_PROMPT': '0',
    'GCM_INTERACTIVE': 'never',
    if (!_environment.containsKey('GIT_SSH_COMMAND') && !_environment.containsKey('GIT_SSH'))
      'GIT_SSH_COMMAND': 'ssh -o BatchMode=yes',
  };

  /// The build's environment: the compiler's folder first on PATH (its DLLs on Windows).
  Map<String, String> get buildEnvironment => _buildEnvironment(checkout);

  Map<String, String> _buildEnvironment(EngineCheckout checkout) {
    final folders = checkout.pathFolders;
    if (folders.isEmpty) return const {};
    final windows = checkout.system == HostSystem.windows;
    final key = _environment.keys.firstWhere((name) => name.toUpperCase() == 'PATH', orElse: () => 'PATH');
    final rest = _environment[key];
    return {
      key: [...folders, if (rest != null && rest.isNotEmpty) rest].join(windows ? ';' : ':'),
    };
  }

  void _keep(String line) {
    output.add(line);
    if (output.length > keptLines) output.removeRange(0, output.length - keptLines);
  }

  /// Runs one command; its exit code and lines. A program that cannot start throws
  /// [GitUpdateFailure] of [missing].
  Future<(int, List<String>)> _run(
    String executable,
    List<String> arguments, {
    required GitFailureKind missing,
    Map<String, String>? environment,
    void Function(String line)? onLine,
    CommandCancel? cancel,
    bool quiet = false,
  }) async {
    if (cancel?.cancelled ?? false) throw const GitUpdateFailure(GitFailureKind.cancelled);
    final lines = <String>[];
    if (!quiet) _keep('\$ ${p.basename(executable)} ${arguments.join(' ')}');
    final int code;
    try {
      code = await runner.run(
        executable,
        arguments,
        workingDirectory: checkout.root,
        environment: environment,
        cancel: cancel,
        onLine: (line) {
          lines.add(line);
          if (quiet) return;
          _keep(line);
          onLine?.call(line);
        },
      );
    } on ProcessException catch (error) {
      throw GitUpdateFailure(missing, [error.message]);
    }
    if (cancel?.cancelled ?? false) throw GitUpdateFailure(GitFailureKind.cancelled, _tail(lines));
    return (code, lines);
  }

  static List<String> _tail(List<String> lines) =>
      lines.length <= tailLines ? List.of(lines) : lines.sublist(lines.length - tailLines);

  Future<String> _head(CommandCancel? cancel) async {
    final (code, lines) = await _run(
      'git',
      ['rev-parse', 'HEAD'],
      missing: GitFailureKind.noGit,
      environment: gitEnvironment,
      cancel: cancel,
      quiet: true,
    );
    if (code != 0) throw GitUpdateFailure(GitFailureKind.notGit, _tail(lines));
    return lines.firstWhere((line) => line.trim().isNotEmpty, orElse: () => '').trim();
  }

  /// The commit checked out now, null when git cannot say.
  Future<String?> head({CommandCancel? cancel}) async {
    try {
      return await _head(cancel);
    } on GitUpdateFailure {
      return null;
    }
  }

  /// Pulls and builds; [onStep] and [onLine] say how far it is. Throws [GitUpdateFailure].
  Future<GitUpdateResult> update({
    void Function(GitStep step)? onStep,
    void Function(String line)? onLine,
    CommandCancel? cancel,
  }) async {
    output.clear();
    onStep?.call(GitStep.checking);
    final (gitCode, gitLines) = await _run(
      'git',
      ['--version'],
      missing: GitFailureKind.noGit,
      environment: gitEnvironment,
      cancel: cancel,
      quiet: true,
    );
    if (gitCode != 0) throw GitUpdateFailure(GitFailureKind.noGit, _tail(gitLines));
    final cmake = checkout.cmake;
    final (cmakeCode, cmakeLines) = await _run(
      cmake,
      ['--version'],
      missing: GitFailureKind.noCmake,
      environment: buildEnvironment,
      cancel: cancel,
      quiet: true,
    );
    if (cmakeCode != 0) throw GitUpdateFailure(GitFailureKind.noCmake, _tail(cmakeLines));
    if (!checkout.isGit) throw const GitUpdateFailure(GitFailureKind.notGit);
    final configure = checkout.buildFolder == null;
    if (configure) {
      // What the build folder's setup needs beside CMake, looked for before anything is pulled.
      for (final (tool, missing) in [
        ('ninja', GitFailureKind.noNinja),
        (EngineCheckout.cxxCompiler, GitFailureKind.noCompiler),
      ]) {
        final (code, lines) = await _run(tool, ['--version'], missing: missing, cancel: cancel, quiet: true);
        if (code != 0) throw GitUpdateFailure(missing, _tail(lines));
      }
    }
    final (statusCode, changes) = await _run(
      'git',
      ['status', '--porcelain', '--untracked-files=no'],
      missing: GitFailureKind.noGit,
      environment: gitEnvironment,
      cancel: cancel,
      quiet: true,
    );
    if (statusCode != 0) throw GitUpdateFailure(GitFailureKind.notGit, _tail(changes));
    final changed = changes.where((line) => line.trim().isNotEmpty).toList();
    if (changed.isNotEmpty) throw GitUpdateFailure(GitFailureKind.dirty, _tail(changed));
    final before = await _head(cancel);

    onStep?.call(GitStep.pulling);
    final (pullCode, pullLines) = await _run(
      'git',
      ['pull', '--ff-only'],
      missing: GitFailureKind.noGit,
      environment: gitEnvironment,
      onLine: onLine,
      cancel: cancel,
    );
    if (pullCode != 0) throw GitUpdateFailure(GitFailureKind.pull, _tail(pullLines));

    onStep?.call(GitStep.submodules);
    final (subCode, subLines) = await _run(
      'git',
      ['submodule', 'update', '--init', '--recursive'],
      missing: GitFailureKind.noGit,
      environment: gitEnvironment,
      onLine: onLine,
      cancel: cancel,
    );
    if (subCode != 0) throw GitUpdateFailure(GitFailureKind.submodules, _tail(subLines));

    var configured = checkout;
    if (configure) {
      onStep?.call(GitStep.configuring);
      final folder = checkout.newBuildFolder;
      final existed = Directory(folder).existsSync();
      try {
        final (configureCode, configureLines) = await _run(
          cmake,
          EngineCheckout.configureArguments,
          missing: GitFailureKind.noCmake,
          onLine: onLine,
          cancel: cancel,
        );
        if (configureCode != 0) throw GitUpdateFailure(GitFailureKind.configure, _tail(configureLines));
      } on GitUpdateFailure {
        // A setup that stopped half way leaves no cache behind to be taken for a build folder.
        _forgetSetup(folder, existed: existed);
        rethrow;
      }
      // The new build folder's cache names the compiler, whose folder the build puts on PATH.
      configured = EngineCheckout.at(checkout.root, system: checkout.system) ?? checkout;
    }
    final build = configured.buildFolder ?? checkout.newBuildFolder;

    onStep?.call(GitStep.building);
    final (buildCode, buildLines) = await _run(
      cmake,
      ['--build', build, '--target', 'relinker', 'libs'],
      missing: GitFailureKind.noCmake,
      environment: _buildEnvironment(configured),
      onLine: onLine,
      cancel: cancel,
    );
    if (buildCode != 0) throw GitUpdateFailure(GitFailureKind.build, _tail(buildLines));
    return GitUpdateResult(before, await _head(cancel));
  }

  static void _forgetSetup(String folder, {required bool existed}) {
    try {
      if (!existed) {
        final made = Directory(folder);
        if (made.existsSync()) made.deleteSync(recursive: true);
        return;
      }
      final cache = File(p.join(folder, 'CMakeCache.txt'));
      if (cache.existsSync()) cache.deleteSync();
    } on FileSystemException {
      // What CMake left stays; the next update sets it up again or says why it cannot.
    }
  }

  /// Whether the remote has commits the checkout lacks (git fetch, then HEAD..@{u}), or the
  /// checkout is not at [built] (pulled by hand since the launcher last built it). Null when it
  /// cannot tell (offline, no upstream branch, no git) or [timeout] passed.
  Future<bool?> needsUpdate({String? built, Duration timeout = const Duration(seconds: 20)}) async {
    final cancel = CommandCancel();
    final timer = Timer(timeout, cancel.cancel);
    try {
      final (fetchCode, _) = await _run(
        'git',
        ['fetch', '--quiet'],
        missing: GitFailureKind.noGit,
        environment: gitEnvironment,
        cancel: cancel,
        quiet: true,
      );
      if (fetchCode != 0) return null;
      final (countCode, count) = await _run(
        'git',
        ['rev-list', '--count', 'HEAD..@{u}'],
        missing: GitFailureKind.noGit,
        environment: gitEnvironment,
        cancel: cancel,
        quiet: true,
      );
      if (countCode != 0) return null;
      final behind = int.tryParse(count.firstWhere((line) => line.trim().isNotEmpty, orElse: () => '').trim());
      if (behind == null) return null;
      if (behind > 0) return true;
      if (built == null) return false;
      final now = await _head(cancel);
      return now.isNotEmpty && now != built;
    } on GitUpdateFailure {
      return null;
    } finally {
      timer.cancel();
    }
  }
}
