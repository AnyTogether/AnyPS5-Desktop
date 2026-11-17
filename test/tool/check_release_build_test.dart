import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/retro_host/retro_host_build.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../tool/check_release_build.dart';
import 'inno_installer_fixture.dart';

/// The check the release and nightly builds run after `flutter build`, and sign-release.sh runs
/// on a release's files: a test build is refused by what it was compiled with and by what its
/// compiled program holds.
void main() {
  String encoded(String define) => base64.encode(utf8.encode(define));

  String config(List<String> defines) => [
    '# Generated code do not commit.',
    'list(APPEND FLUTTER_TOOL_ENVIRONMENT',
    '  "FLUTTER_ROOT=C:\\\\flutter"',
    if (defines.isNotEmpty) '  "DART_DEFINES=${defines.map(encoded).join(',')}"',
    '  "DART_OBFUSCATION=false"',
    ')',
  ].join('\n');

  group('the build configuration', () {
    test('reads DART_DEFINES as flutter_tools writes it', () {
      expect(dartDefinesIn(config(['FLUTTER_VERSION=3.47.1', 'A=b=c'])), ['FLUTTER_VERSION=3.47.1', 'A=b=c']);
      expect(dartDefinesIn(config([])), isNull);
      expect(() => dartDefinesIn('  "DART_DEFINES=not*base64"'), throwsFormatException);
    });

    test("refuses the test build's define with any value, and nothing else", () {
      for (final value in ['true', 'false', '']) {
        expect(
          testDefineProblem(['FLUTTER_VERSION=3.47.1', '${RetroHostBuild.testDefine}=$value']),
          contains('--dart-define'),
          reason: value,
        );
      }
      expect(testDefineProblem(['FLUTTER_VERSION=3.47.1', '${RetroHostBuild.testDefine}X=true']), isNull);
    });

    test('refuses a configuration without the DART_DEFINES and FLUTTER_VERSION every flutter build writes', () {
      expect(testDefineProblem(null), contains('no DART_DEFINES'));
      expect(testDefineProblem(['FLUTTER_CHANNEL=stable']), contains('no FLUTTER_VERSION'));
    });
  });

  group('the compiled program', () {
    test('finds the mark as one-byte or UTF-16 text and nothing like it', () {
      final mark = RetroHostBuild.testMark;
      Uint8List bytes(List<int> middle) => Uint8List.fromList([0, 1, ...middle, 2, 3]);
      expect(holdsText(bytes(latin1.encode(mark)), mark), isTrue);
      expect(
        holdsText(
          bytes([
            for (final unit in mark.codeUnits) ...[unit, 0],
          ]),
          mark,
        ),
        isTrue,
      );
      expect(holdsText(bytes(latin1.encode(mark.substring(1))), mark), isFalse);
      expect(holdsText(bytes(latin1.encode(mark.toLowerCase())), mark), isFalse);
    });

    test('a launcher with no snapshot cannot pass', () {
      final folder = Directory.systemTemp.createTempSync('check_release_build');
      addTearDown(() => folder.deleteSync(recursive: true));
      expect(snapshotProblem(snapshotIn(BuiltSystem.windows, folder.path)), contains('no AOT snapshot'));
      expect(snapshotIn(BuiltSystem.windows, 'r'), p.join('r', 'data', 'app.so'));
      expect(snapshotIn(BuiltSystem.linux, 'r'), p.join('r', 'lib', 'libapp.so'));
    });

    test('the lookup of the unchecked host compiles the mark into a test build alone, and every release file holding it is refused', () async {
      final folder = Directory.systemTemp.createTempSync('check_release_build');
      addTearDown(() => folder.deleteSync(recursive: true));
      final program = File(p.join(folder.path, 'starts.dart'))
        ..writeAsStringSync(
          "import 'package:anyps5_desktop/core/host.dart';\n"
          "import 'package:anyps5_desktop/core/retro_host/retro_host_build.dart';\n"
          "import 'package:anyps5_desktop/core/retro_host/retro_host_install.dart';\n"
          'void main() => RetroHostInstall.locate(const {}, build: RetroHostBuild.of(debug: false), '
          'system: HostSystem.current, log: print);\n',
        );
      Future<String> compile(String name, List<String> defines) async {
        final out = p.join(folder.path, '$name.aot');
        final run = await Process.run(_dart(), [
          'compile',
          'aot-snapshot',
          '--packages=${p.absolute('.dart_tool', 'package_config.json')}',
          ...defines,
          '-o',
          out,
          program.path,
        ]);
        expect(run.exitCode, 0, reason: '${run.stdout}${run.stderr}');
        return out;
      }

      final release = await compile('release', []);
      final testBuild = await compile('test', ['-D${RetroHostBuild.testDefine}=true']);
      expect(snapshotProblem(release), isNull);
      expect(snapshotProblem(testBuild), contains(RetroHostBuild.testMark));
      final looked = await Process.run(_dart(), [
        'run',
        '--packages=${p.absolute('.dart_tool', 'package_config.json')}',
        '-D${RetroHostBuild.testDefine}=true',
        program.path,
      ]);
      expect('${looked.stdout}', contains(RetroHostBuild.testMark), reason: 'the lookup writes it');

      List<String> files(String name, Uint8List snapshot, Uint8List installs) {
        final dir = Directory(p.join(folder.path, name))..createSync();
        String write(String file, List<int> bytes) => (File(p.join(dir.path, file))..writeAsBytesSync(bytes)).path;
        Uint8List tar(String path) => TarEncoder().encodeBytes(Archive()..addFile(ArchiveFile.bytes(path, snapshot)));
        final debData = XZEncoder().encodeBytes(tar('./opt/anyps5-desktop/lib/libapp.so'));
        return [
          write(
            'AnyPS5-Desktop-Setup-1.0.0-x64.exe',
            innoInstaller([
              [
                0,
                ...lzma2Stored([...utf8.encode('anyps5_desktop.exe'), ...installs, 1, 2, 3]),
              ],
            ]),
          ),
          write(
            'AnyPS5-Desktop-windows-x64.zip',
            ZipEncoder().encodeBytes(Archive()..addFile(ArchiveFile.bytes('data/app.so', snapshot))),
          ),
          write('AnyPS5-Desktop-linux-x64.tar.gz', gzip.encode(tar('AnyPS5-Desktop/lib/libapp.so'))),
          write('anyps5-desktop_1.0.0_amd64.deb', [
            ...ascii.encode('!<arch>\n'),
            ...ascii.encode('data.tar.xz     0           0     0     100644  ${'${debData.length}'.padRight(10)}`\n'),
            ...debData,
            if (debData.length.isOdd) 0x0a,
          ]),
        ];
      }

      final releaseSnapshot = File(release).readAsBytesSync();
      final testSnapshot = File(testBuild).readAsBytesSync();
      expect(releaseFileProblems(files('release', releaseSnapshot, releaseSnapshot)), isEmpty);
      final refused = releaseFileProblems(files('test', testSnapshot, testSnapshot));
      expect(refused, hasLength(4));
      expect(refused, everyElement(contains('is a test build\'s')));
      final mixed = releaseFileProblems(files('mixed', releaseSnapshot, testSnapshot));
      expect(mixed.single, allOf(contains('Setup'), contains('a file it installs holds')));
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  group('the files of a release', () {
    late Directory folder;
    setUp(() => folder = Directory.systemTemp.createTempSync('check_release_files'));
    tearDown(() => folder.deleteSync(recursive: true));
    String write(String name, List<int> bytes) => (File(p.join(folder.path, name))..writeAsBytesSync(bytes)).path;
    Uint8List zip(List<int> snapshot) =>
        ZipEncoder().encodeBytes(Archive()..addFile(ArchiveFile.bytes('data/app.so', snapshot)));

    test('a file no release has, or one that is missing or damaged, is refused', () {
      final problems = releaseFileProblems([
        write('SHA256SUMS', [1]),
        write('AnyPS5-Desktop.dmg', [1]),
        p.join(folder.path, 'AnyPS5-Desktop-windows-x64.zip'),
        write('AnyPS5-Desktop-linux-x64.tar.gz', [1, 2, 3]),
        write('anyps5-desktop_1.0.0_amd64.deb', utf8.encode('!<arch>\n')),
        write('AnyPS5-Desktop-1.0.0-x86_64.AppImage', [0x7f, 0x45]),
        write('AnyPS5-Desktop-Setup-1.0.0-x64.exe', [0x4d, 0x5a]),
      ]);
      expect(problems, hasLength(7));
      expect(problems.take(2), everyElement(contains('no launcher release file')));
      expect(problems.skip(2), everyElement(contains('cannot be read as')));
    });

    test('an installer is signed only with the checked zip whose snapshot it installs', () {
      final snapshot = utf8.encode('a release snapshot');
      final installer = write(
        'AnyPS5-Desktop-Setup-1.0.0-x64.exe',
        innoInstaller([
          [
            0,
            ...lzma2Stored([0, ...snapshot, 0]),
          ],
        ]),
      );
      expect(releaseFileProblems([installer]).single, contains('installs no data/app.so'));
      final other = write('AnyPS5-Desktop-windows-x64.zip', zip(utf8.encode('another snapshot')));
      expect(releaseFileProblems([installer, other]).single, contains('installs no data/app.so'));
      final own = write('AnyPS5-Desktop-windows-x64.zip', zip(snapshot));
      expect(releaseFileProblems([installer, own]), isEmpty);
      expect(releaseFileProblems([own, installer]), isEmpty, reason: 'in any order');
    });
  });

  test('a built folder passes only with a release configuration and snapshot', () {
    final root = Directory.systemTemp.createTempSync('check_release_build');
    addTearDown(() => root.deleteSync(recursive: true));
    final built = p.join(root.path, 'build');
    final configFile = File(p.join(root.path, 'linux', 'flutter', 'ephemeral', 'generated_config.cmake'));
    final snapshot = File(snapshotIn(BuiltSystem.linux, built));
    expect(releaseBuildProblems(BuiltSystem.linux, built, root: root.path), hasLength(2));
    configFile
      ..createSync(recursive: true)
      ..writeAsStringSync(config(['FLUTTER_VERSION=3.47.1']));
    snapshot
      ..createSync(recursive: true)
      ..writeAsBytesSync([1, 2, 3]);
    expect(releaseBuildProblems(BuiltSystem.linux, built, root: root.path), isEmpty);
    configFile.writeAsStringSync(config(['FLUTTER_VERSION=3.47.1', '${RetroHostBuild.testDefine}=true']));
    expect(releaseBuildProblems(BuiltSystem.linux, built, root: root.path).single, contains('--dart-define'));
    configFile.writeAsStringSync(config([]));
    expect(releaseBuildProblems(BuiltSystem.linux, built, root: root.path).single, contains('no DART_DEFINES'));
    configFile.writeAsStringSync(config(['FLUTTER_VERSION=3.47.1']));
    snapshot.writeAsBytesSync(latin1.encode('...${RetroHostBuild.testMark}...'));
    expect(releaseBuildProblems(BuiltSystem.linux, built, root: root.path).single, contains('test build'));
  });
}

/// The Dart SDK's `dart` of the Flutter running the tests: FLUTTER_ROOT's, or the one beside
/// flutter_tester (`bin/cache/artifacts/engine/<platform>/flutter_tester`).
String _dart() {
  final name = Platform.isWindows ? 'dart.exe' : 'dart';
  final root = Platform.environment['FLUTTER_ROOT'];
  final cache = root != null && root.isNotEmpty
      ? p.join(root, 'bin', 'cache')
      : p.dirname(p.dirname(p.dirname(p.dirname(Platform.resolvedExecutable))));
  return p.join(cache, 'dart-sdk', 'bin', name);
}
