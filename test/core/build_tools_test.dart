import 'dart:io';

import 'package:anyps5_desktop/core/engine_checkout.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_commands.dart';
import '../support/fixtures.dart';

/// Update from Git's tools: everything missing found at once, the commands that install it on
/// each system, and PATH read again on Windows so nothing needs a restart.
void main() {
  late Directory temp;

  setUp(() => temp = temporaryFolder('tools'));
  tearDown(() => temp.deleteSync(recursive: true));

  const everything = [
    MissingNeed(BuildNeed.git),
    MissingNeed(BuildNeed.cmake),
    MissingNeed(BuildNeed.ninja),
    MissingNeed(BuildNeed.compiler),
  ];
  const accept = '--accept-source-agreements --accept-package-agreements';

  group('the commands that install what is missing', () {
    test('Windows: WinLibs brings the compilers, CMake and Ninja in one, Git on its own', () {
      final fixes = BuildTools.fixes(HostSystem.windows, everything);
      expect(
        [for (final fix in fixes) fix.line],
        [
          'winget install -e --id Git.Git $accept',
          'winget install -e --id BrechtSanders.WinLibs.POSIX.UCRT --version 15.2.0-14.0.0-r7 $accept',
        ],
      );
      // Git's installer raises itself: copied, never run. WinLibs installs for the user.
      expect((fixes[0].admin, fixes[0].runnable), (true, false));
      expect((fixes[1].admin, fixes[1].runnable), (false, true));
      expect(fixes[1].needs, [BuildNeed.compiler, BuildNeed.cmake, BuildNeed.ninja]);
    });

    test('Windows: with the compilers there, CMake and Ninja each get their own package', () {
      final fixes = BuildTools.fixes(HostSystem.windows, const [
        MissingNeed(BuildNeed.cmake),
        MissingNeed(BuildNeed.ninja),
      ]);
      expect(
        [for (final fix in fixes) fix.line],
        ['winget install -e --id Kitware.CMake $accept', 'winget install -e --id Ninja-build.Ninja $accept'],
      );
      expect([for (final fix in fixes) fix.runnable], [false, true]);
    });

    test('Windows with Scoop and no winget: one Scoop line, to copy', () {
      final fixes = BuildTools.fixes(HostSystem.windows, everything, winget: false, scoop: true);
      expect(fixes.single.line, 'scoop install git mingw-winlibs cmake ninja');
      expect((fixes.single.admin, fixes.single.runnable), (false, false));
    });

    test('Linux: one sudo line for the system\'s package manager, never run by the launcher', () {
      const missing = [...everything, MissingNeed(BuildNeed.x11)];
      final apt = BuildTools.fixes(HostSystem.linux, missing, osRelease: 'ID=ubuntu\nID_LIKE=debian\n').single;
      expect(apt.line, startsWith('sudo apt-get install -y git cmake ninja-build gcc g++ pkg-config libx11-dev'));
      expect(apt.line, contains('libxrandr-dev'));
      expect((apt.admin, apt.runnable), (true, false));
      final dnf = BuildTools.fixes(HostSystem.linux, everything, osRelease: 'ID=fedora\n').single;
      expect(dnf.line, 'sudo dnf install -y git cmake ninja-build gcc gcc-c++');
      final pacman = BuildTools.fixes(HostSystem.linux, everything, osRelease: 'ID=cachyos\nID_LIKE="arch"\n').single;
      expect(pacman.line, 'sudo pacman -S --needed git cmake ninja gcc');
      // An older GCC on Ubuntu: the guide's gcc-12 and g++-12.
      final older = BuildTools.fixes(HostSystem.linux, const [
        MissingNeed(BuildNeed.newerCompiler, '11.4.0'),
      ], osRelease: 'ID=ubuntu\n').single;
      expect(older.line, 'sudo apt-get install -y gcc-12 g++-12');
    });

    test('a Linux system the launcher has no command for gets none (the guide says what to install)', () {
      expect(BuildTools.fixes(HostSystem.linux, everything, osRelease: 'ID=nixos\n'), isEmpty);
      expect(BuildTools.fixes(HostSystem.linux, everything), isEmpty);
      expect(BuildTools.linuxManager('NAME="Linux Mint"\nID=linuxmint\nID_LIKE="ubuntu debian"\n'), 'apt');
    });

    test('the GCC version, from what g++ --version prints', () {
      expect(BuildTools.gccVersion(['g++ (Ubuntu 11.4.0-1ubuntu1~22.04) 11.4.0', 'Copyright (C) 2021']), (
        11,
        '11.4.0',
      ));
      expect(BuildTools.gccVersion(['g++ (GCC) 15.2.0']), (15, '15.2.0'));
      expect(BuildTools.gccVersion(const []), isNull);
    });
  });

  group('the check before anything is pulled', () {
    late FakeCommands commands;
    late String bare;

    setUp(() {
      commands = FakeCommands();
      bare = makeFakeCheckout(p.join(temp.path, 'Bare'), configured: false);
    });

    EngineGit git({
      HostSystem system = HostSystem.linux,
      Map<String, String> environment = const {'PATH': '/usr/bin'},
    }) => EngineGit(
      EngineCheckout.at(bare, system: system)!,
      runner: commands,
      environment: environment,
      osRelease: () => 'ID=ubuntu\n',
    );

    test('Linux: every tool and the X11 files missing are found in one go', () async {
      for (final tool in ['git', 'cmake', 'ninja', 'g++']) {
        commands.results['$tool --version'] = const FakeResult(missing: true);
      }
      commands.results['pkg-config'] = const FakeResult(code: 1);
      final update = git();
      final missing = await update.missingNeeds();
      expect(missing, const [...everything, MissingNeed(BuildNeed.x11)]);
      expect((await update.fixes(missing)).single.line, startsWith('sudo apt-get install -y git cmake ninja-build'));
      // The update itself stops there, with the same list.
      try {
        await update.update();
        fail('the update went through');
      } on GitUpdateFailure catch (stopped) {
        expect(stopped.kind, GitFailureKind.prerequisites);
        expect(stopped.missing, missing);
        expect((stopped.untouched, stopped.guideHelps), (true, true));
      }
      expect(commands.lines.where((line) => line.startsWith('git pull')), isEmpty);
    });

    test('Linux without pkg-config: the X11 files are left to CMake to ask for', () async {
      commands.results['pkg-config'] = const FakeResult(missing: true);
      expect(await git().missingNeeds(), isEmpty);
    });

    test('Linux with an older GCC: gcc-12 and g++-12 stand in, as the guide sets it up', () async {
      commands.results['g++ --version'] = const FakeResult(lines: ['g++ (Ubuntu 11.4.0-1ubuntu1~22.04) 11.4.0']);
      commands.results['git rev-parse HEAD'] = const FakeResult(lines: ['aaaa']);
      commands.results['cmake -S'] = FakeResult(effect: () => configureFakeCheckout(bare));
      commands.results['cmake --build'] = FakeResult(effect: () => buildFakeCheckout(bare));
      await git().update();
      expect(
        commands.lines,
        contains(
          'cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=gcc-12 -DCMAKE_CXX_COMPILER=g++-12',
        ),
      );
    });

    test('Linux with an older GCC and no gcc-12: said with the version found', () async {
      commands.results['g++ --version'] = const FakeResult(lines: ['g++ (Ubuntu 11.4.0-1ubuntu1~22.04) 11.4.0']);
      commands.results['g++-12 --version'] = const FakeResult(missing: true);
      expect(await git().missingNeeds(), const [MissingNeed(BuildNeed.newerCompiler, '11.4.0')]);
    });

    test('Windows: PATH is read again from the registry, and a tool installed since is started from there', () async {
      final tools = Directory(p.join(temp.path, 'tools'))..createSync();
      final user = Directory(p.join(temp.path, 'user'))..createSync();
      File(p.join(tools.path, 'git.exe')).writeAsStringSync('');
      File(p.join(user.path, 'ninja.exe')).writeAsStringSync('');
      commands.results['reg query HKLM'] = const FakeResult(
        lines: [
          '',
          r'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Session Manager\Environment',
          r'    Path    REG_EXPAND_SZ    %tools%;C:\Windows\system32',
        ],
      );
      commands.results['reg query HKCU'] = FakeResult(
        lines: ['', r'HKEY_CURRENT_USER\Environment', '    Path    REG_SZ    ${user.path}'],
      );
      final update = git(system: HostSystem.windows, environment: {'Path': r'C:\Old', 'TOOLS': tools.path});
      expect(await update.missingNeeds(), isEmpty);
      final gitCall = commands.calls.firstWhere((call) => call.line == 'git.exe --version');
      expect(gitCall.executable, p.join(tools.path, 'git.exe'), reason: 'by its full path: not on the old PATH');
      expect(gitCall.environment?['Path'], '${tools.path};C:\\Windows\\system32;${user.path};C:\\Old');
      expect(commands.calls.firstWhere((call) => call.line == 'ninja.exe --version').executable, startsWith(user.path));
      // Not in any of the folders: asked for by name, as before.
      expect(commands.calls.where((call) => call.executable == 'cmake'), isNotEmpty);
      // Nothing is looked up in the registry elsewhere.
      commands.calls.clear();
      await git().missingNeeds();
      expect(commands.lines.where((line) => line.startsWith('reg')), isEmpty);
    });

    test('Windows: winget where it is installed, Scoop where only Scoop is', () async {
      final update = git(system: HostSystem.windows);
      expect((await update.fixes(everything)).first.executable, 'winget');
      commands.results['winget --version'] = const FakeResult(missing: true);
      expect((await update.fixes(everything)).single.executable, 'scoop');
    });

    test('installing runs only what installs for the user', () async {
      final update = git(system: HostSystem.windows);
      final fixes = await update.fixes(everything);
      commands.calls.clear();
      expect(await update.install(fixes.first), isFalse, reason: 'Git\'s installer asks for administrator rights');
      expect(commands.calls, isEmpty);
      final lines = <String>[];
      commands.results['winget install'] = const FakeResult(lines: ['Successfully installed']);
      expect(await update.install(fixes.last, onLine: lines.add), isTrue);
      expect(commands.lines.single, startsWith('winget install -e --id BrechtSanders.WinLibs.POSIX.UCRT'));
      expect(lines, ['Successfully installed']);
    });
  });
}
