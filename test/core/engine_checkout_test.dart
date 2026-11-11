import 'dart:async';
import 'dart:io';

import 'package:anyps5_desktop/core/engine_checkout.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/toolkit.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_commands.dart';
import '../support/fake_toolkit.dart';
import '../support/fixtures.dart';

/// A git checkout of the engine's source as the engine folder, and updating it from git.
void main() {
  late Directory temp;

  setUp(() => temp = temporaryFolder('checkout'));
  tearDown(() => temp.deleteSync(recursive: true));

  group('the checkout as the engine folder', () {
    test('its relinker and libraries come from the configured build folder', () {
      final root = makeFakeCheckout(p.join(temp.path, 'AnyPS5'));
      final kit = Toolkit(root);
      expect(kit.checkout, isNotNull);
      expect(kit.problem, isNull);
      expect(kit.relinker, p.join(root, 'build', 'core', 'relinker', 'relinker'));
      expect(kit.libraries, p.join(root, 'build', 'core', 'libs', 'libs'));
      expect(kit.libraryFiles.map(p.basename), ['libSceVideoOut.prx', 'libkernel.prx']);
      expect(kit.version, startsWith('local-'), reason: 'a build of its own has a fingerprint');
      expect(Toolkit.locate([root], system: HostSystem.linux, environment: const {})?.root, root);
    });

    test('not built yet: no relinker, so not usable, but still the checkout', () {
      final root = makeFakeCheckout(p.join(temp.path, 'AnyPS5'), built: false);
      final kit = Toolkit(root);
      expect(kit.checkout?.buildFolder, p.join(root, 'build'));
      expect(kit.problem, ToolkitProblem.noRelinker);
      final unconfigured = EngineCheckout.at(makeFakeCheckout(p.join(temp.path, 'Bare'), configured: false))!;
      expect(unconfigured.buildFolder, isNull);
      expect(unconfigured.isGit, isTrue);
    });

    test('another configured build folder is used when build/ is not one', () {
      final root = makeFakeCheckout(p.join(temp.path, 'AnyPS5'));
      Directory(p.join(root, 'build')).renameSync(p.join(root, 'build-release'));
      Directory(p.join(root, 'build-empty')).createSync();
      final kit = Toolkit(root);
      expect(kit.checkout?.buildFolder, p.join(root, 'build-release'));
      expect(kit.problem, isNull);
    });

    test('a toolkit folder (relinker at the top) is never taken for a checkout', () {
      final folder = makeFakeToolkit(p.join(temp.path, 'toolkit'));
      File(p.join(folder, 'CMakeLists.txt')).writeAsStringSync('');
      Directory(p.join(folder, 'core', 'relinker')).createSync(recursive: true);
      Directory(p.join(folder, 'core', 'libs')).createSync(recursive: true);
      expect(Toolkit(folder).checkout, isNull);
      expect(EngineCheckout.at(p.join(temp.path, 'nothing-here')), isNull);
    });

    test('Windows: the MinGW runtime from the compiler\'s folder goes with the libraries', () {
      final mingw = p.join(temp.path, 'winlibs', 'mingw64', 'bin');
      Directory(mingw).createSync(recursive: true);
      for (final name in EngineCheckout.windowsRuntime) {
        File(p.join(mingw, name)).writeAsStringSync(name);
      }
      final root = makeFakeCheckout(p.join(temp.path, 'AnyPS5'), compiler: p.join(mingw, 'g++.exe'));
      final kit = Toolkit(root, system: HostSystem.windows);
      expect(kit.relinker, p.join(root, 'build', 'core', 'relinker', 'relinker.exe'));
      expect(kit.problem, isNull);
      expect(kit.libraryFiles.map(p.basename), [
        'libSceVideoOut.prx',
        'libkernel.prx',
        'mimalloc.dll',
        'libgcc_s_seh-1.dll',
        'libstdc++-6.dll',
        'libwinpthread-1.dll',
      ]);
      expect(kit.toolFolders, [mingw]);
    });
  });

  test('the system runner hands every line and stops a command with its children', () async {
    final lines = <String>[];
    final cancel = CommandCancel();
    final started = Completer<void>();
    final run = const SystemCommands().run(
      'sh',
      ['-c', 'echo out; echo err >&2; sleep 30 & wait \$!'],
      workingDirectory: temp.path,
      cancel: cancel,
      onLine: (line) {
        lines.add(line);
        if (lines.length == 2 && !started.isCompleted) started.complete();
      },
    );
    await started.future.timeout(const Duration(seconds: 10));
    final clock = Stopwatch()..start();
    cancel.cancel();
    final code = await run.timeout(const Duration(seconds: 10));
    expect(code, isNot(0));
    expect(clock.elapsed, lessThan(const Duration(seconds: 5)));
    expect(lines.take(2).toList()..sort(), ['err', 'out']);
    await expectLater(
      const SystemCommands().run('anyps5-no-such-program', const [], workingDirectory: temp.path),
      throwsA(isA<ProcessException>()),
    );
  }, skip: Platform.isWindows);

  group('update from git', () {
    late String root;
    late FakeCommands commands;
    late EngineGit git;

    setUp(() {
      root = makeFakeCheckout(p.join(temp.path, 'AnyPS5'));
      commands = FakeCommands();
      git = EngineGit(EngineCheckout.at(root)!, runner: commands, environment: const {'PATH': '/usr/bin'});
    });

    Future<GitUpdateFailure> failure() async {
      try {
        await git.update();
      } on GitUpdateFailure catch (failure) {
        return failure;
      }
      fail('the update went through');
    }

    test('pulls, updates the submodules, then builds the relinker and the libraries', () async {
      var head = 'aaaa';
      commands.results['git rev-parse HEAD'] = FakeResult(output: () => [head]);
      commands.results['git pull --ff-only'] = FakeResult(
        lines: ['Updating aaaa..bbbb', 'Fast-forward'],
        effect: () => head = 'bbbb',
      );
      final steps = <GitStep>[];
      final lines = <String>[];
      final result = await git.update(onStep: steps.add, onLine: lines.add);
      expect(steps, [GitStep.checking, GitStep.pulling, GitStep.submodules, GitStep.building]);
      expect(commands.lines, [
        'git --version',
        'cmake --version',
        'git status --porcelain --untracked-files=no',
        'git rev-parse HEAD',
        'git pull --ff-only',
        'git submodule update --init --recursive',
        'cmake --build ${p.join(root, 'build')} --target relinker libs',
        'git rev-parse HEAD',
      ]);
      expect(commands.calls.every((call) => call.workingDirectory == root), isTrue);
      expect(lines, ['Updating aaaa..bbbb', 'Fast-forward']);
      expect((result.before, result.after, result.pulled), ('aaaa', 'bbbb', true));
      expect(git.output, contains('\$ git pull --ff-only'));
      final pull = commands.calls.firstWhere((call) => call.line == 'git pull --ff-only');
      expect(pull.environment?['GIT_TERMINAL_PROMPT'], '0', reason: 'a password prompt fails instead of hanging');
    });

    test('a tree with changes not committed is refused before anything is pulled', () async {
      commands.results['git status'] = const FakeResult(lines: [' M core/relinker/main.cpp', ' M README.md']);
      final refused = await failure();
      expect(refused.kind, GitFailureKind.dirty);
      expect(refused.tail, [' M core/relinker/main.cpp', ' M README.md']);
      expect(refused.untouched, isTrue);
      expect(commands.lines.where((line) => line.startsWith('git pull')), isEmpty);
    });

    test('git or CMake not installed: said, nothing run', () async {
      commands.results['git --version'] = const FakeResult(missing: true);
      final noGit = await failure();
      expect(noGit.kind, GitFailureKind.prerequisites);
      expect(noGit.missing, const [MissingNeed(BuildNeed.git)]);
      commands
        ..results.clear()
        ..calls.clear()
        ..results['cmake --version'] = const FakeResult(missing: true);
      final noCmake = await failure();
      expect(noCmake.kind, GitFailureKind.prerequisites);
      expect(noCmake.missing, const [MissingNeed(BuildNeed.cmake)]);
      expect(commands.lines, ['git --version', 'cmake --version']);
      // Both gone: one answer names both.
      commands
        ..calls.clear()
        ..results['git --version'] = const FakeResult(missing: true);
      expect((await failure()).missing, const [MissingNeed(BuildNeed.git), MissingNeed(BuildNeed.cmake)]);
    });

    test('no build folder: set up with CMake as the build guides do, then pulled and built', () async {
      final bare = makeFakeCheckout(p.join(temp.path, 'Bare'), configured: false);
      git = EngineGit(EngineCheckout.at(bare)!, runner: commands, environment: const {'PATH': '/usr/bin'});
      commands.results['git rev-parse HEAD'] = const FakeResult(lines: ['aaaa']);
      commands.results['cmake -S'] = FakeResult(
        lines: const ['-- The CXX compiler identification is GNU 15.2.0', '-- Generating done'],
        effect: () => configureFakeCheckout(bare),
      );
      commands.results['cmake --build'] = FakeResult(effect: () => buildFakeCheckout(bare));
      final steps = <GitStep>[];
      final lines = <String>[];
      await git.update(onStep: steps.add, onLine: lines.add);
      expect(steps, GitStep.values);
      expect(commands.lines, [
        'git --version',
        'cmake --version',
        'ninja --version',
        'g++ --version',
        'gcc --version',
        'pkg-config --exists x11 xext xrandr',
        'git status --porcelain --untracked-files=no',
        'git rev-parse HEAD',
        'git pull --ff-only',
        'git submodule update --init --recursive',
        'cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=gcc -DCMAKE_CXX_COMPILER=g++',
        'cmake --build ${p.join(bare, 'build')} --target relinker libs',
        'git rev-parse HEAD',
      ]);
      expect(commands.calls.every((call) => call.workingDirectory == bare), isTrue);
      expect(lines, contains('-- Generating done'));
      expect(EngineCheckout.at(bare)!.buildFolder, p.join(bare, 'build'));
    });

    test('no build folder and no Ninja or no compiler: said before anything is pulled', () async {
      final bare = makeFakeCheckout(p.join(temp.path, 'Bare'), configured: false);
      git = EngineGit(EngineCheckout.at(bare)!, runner: commands);
      commands.results['ninja --version'] = const FakeResult(missing: true);
      final noNinja = await failure();
      expect(noNinja.kind, GitFailureKind.prerequisites);
      expect(noNinja.missing, const [MissingNeed(BuildNeed.ninja)]);
      expect((noNinja.untouched, noNinja.guideHelps), (true, true));
      // Ninja and the compiler both missing: named together, not one after the other.
      commands
        ..calls.clear()
        ..results['g++ --version'] = const FakeResult(missing: true);
      expect((await failure()).missing, const [MissingNeed(BuildNeed.ninja), MissingNeed(BuildNeed.compiler)]);
      expect(commands.lines, [
        'git --version',
        'cmake --version',
        'ninja --version',
        'g++ --version',
        'gcc --version',
        'pkg-config --exists x11 xext xrandr',
      ]);
    });

    test('a setup CMake cannot finish leaves no build folder to be taken for one', () async {
      final bare = makeFakeCheckout(p.join(temp.path, 'Bare'), configured: false);
      git = EngineGit(EngineCheckout.at(bare)!, runner: commands);
      commands.results['cmake -S'] = FakeResult(
        code: 1,
        lines: const ['CMake Error at CMakeLists.txt:12 (find_package):', 'Could NOT find Python3'],
        effect: () => configureFakeCheckout(bare),
      );
      final stopped = await failure();
      expect(stopped.kind, GitFailureKind.configure);
      expect(stopped.tail.last, 'Could NOT find Python3');
      expect(stopped.guideHelps, isTrue);
      expect(Directory(p.join(bare, 'build')).existsSync(), isFalse);
      expect(EngineCheckout.at(bare)!.buildFolder, isNull);
      expect(commands.lines.where((line) => line.contains('--build')), isEmpty);
    });

    test('the build guide follows the tree: upstream\'s for upstream\'s, AnyPS5-ARM\'s for its own', () {
      final upstream = makeFakeCheckout(p.join(temp.path, 'Upstream'), configured: false);
      final arm = makeFakeCheckout(p.join(temp.path, 'Arm'), configured: false, arm: true);
      expect(EngineCheckout.at(upstream, system: HostSystem.windows)!.guide, EngineCheckout.upstreamWindowsGuide);
      expect(EngineCheckout.at(upstream)!.guide, EngineCheckout.upstreamLinuxGuide);
      expect(EngineCheckout.upstreamWindowsGuide.toString(), contains('boykopovar/AnyPS5'));
      expect(EngineCheckout.at(arm, system: HostSystem.windows)!.guide, EngineCheckout.armGuide);
      expect(EngineCheckout.at(arm)!.isArm, isTrue);
      expect(EngineCheckout.at(upstream)!.isArm, isFalse);
    });

    test('a pull that cannot fast-forward stops with what git said', () async {
      commands.results['git pull'] = const FakeResult(
        code: 128,
        lines: ['hint: Diverging branches can\'t be fast-forwarded', 'fatal: Not possible to fast-forward, aborting.'],
      );
      final stopped = await failure();
      expect(stopped.kind, GitFailureKind.pull);
      expect(stopped.tail.last, 'fatal: Not possible to fast-forward, aborting.');
      expect(stopped.untouched, isTrue);
      expect(commands.lines.where((line) => line.contains('--build')), isEmpty);
    });

    test('a failed build keeps the end of its output', () async {
      commands.results['cmake --build'] = FakeResult(
        code: 1,
        lines: [for (var line = 0; line < 100; line++) '[$line/100] Building CXX object', 'error: no member named'],
      );
      final stopped = await failure();
      expect(stopped.kind, GitFailureKind.build);
      expect(stopped.tail, hasLength(EngineGit.tailLines));
      expect(stopped.tail.last, 'error: no member named');
      expect(stopped.untouched, isFalse);
    });

    test('cancel stops the running command', () async {
      final hold = Completer<void>();
      commands.results['cmake --build'] = FakeResult(hold: hold);
      final cancel = CommandCancel();
      final steps = <GitStep>[];
      final running = git.update(cancel: cancel, onStep: steps.add);
      while (!steps.contains(GitStep.building)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      cancel.cancel();
      await expectLater(
        running,
        throwsA(isA<GitUpdateFailure>().having((failure) => failure.kind, 'kind', GitFailureKind.cancelled)),
      );
      expect(hold.isCompleted, isFalse);
    });

    test('new commits on the remote: fetch, then HEAD..@{u}; offline says nothing', () async {
      commands.results['git rev-list'] = const FakeResult(lines: ['3']);
      expect(await git.needsUpdate(), isTrue);
      expect(commands.lines, ['git fetch --quiet', 'git rev-list --count HEAD..@{u}']);
      commands.results['git rev-list'] = const FakeResult(lines: ['0']);
      commands.results['git rev-parse HEAD'] = const FakeResult(lines: ['cccc']);
      expect(await git.needsUpdate(built: 'cccc'), isFalse);
      expect(await git.needsUpdate(built: 'aaaa'), isTrue, reason: 'pulled by hand since the last build');
      commands.results['git fetch'] = const FakeResult(code: 128, lines: ['fatal: unable to access']);
      expect(await git.needsUpdate(), isNull);
      commands.results['git fetch'] = FakeResult(hold: Completer<void>());
      expect(await git.needsUpdate(timeout: const Duration(milliseconds: 20)), isNull);
    });

    test('the build gets the compiler\'s folder first on PATH', () {
      final mingw = p.join(temp.path, 'mingw64', 'bin');
      final windows = makeFakeCheckout(p.join(temp.path, 'Win'), compiler: p.join(mingw, 'g++.exe'));
      final build = EngineGit(
        EngineCheckout.at(windows, system: HostSystem.windows)!,
        runner: commands,
        environment: const {'Path': r'C:\Windows'},
      ).buildEnvironment;
      expect(build, {'Path': '$mingw;C:\\Windows'});
    });
  });
}
