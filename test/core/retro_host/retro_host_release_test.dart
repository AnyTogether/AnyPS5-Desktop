import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/retro_host/retro_host_client.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_protocol.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_release.dart';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../support/fixtures.dart';
import '../../support/signing.dart';

/// test/fixtures/retro_host_release holds what the host repository's release workflow writes for
/// a release, made by its tools/package_release.py from small stand-in files: each system's zip
/// and `.files`, and the unsigned SHA256SUMS. The tests sign that SHA256SUMS with a throwaway key,
/// as the maintainers sign it with AnyPS5-ARM's tools/release/sign.sh.
const _fixtures = 'test/fixtures/retro_host_release';
const _linux = RetroHostSystem.linuxX64;
const _windows = RetroHostSystem.windowsX64;

void main() {
  final key = TestReleaseKey('retro host release');
  final stranger = TestReleaseKey('someone else');
  final keys = [key.key];
  late Directory temp;

  setUp(() => temp = temporaryFolder('retro_host_release'));
  tearDown(() => temp.deleteSync(recursive: true));

  Directory download({TestReleaseKey? signer}) {
    final folder = Directory(p.join(temp.path, 'download'))..createSync();
    for (final file in Directory(_fixtures).listSync().whereType<File>()) {
      if (p.basename(file.path).startsWith('.')) continue;
      file.copySync(p.join(folder.path, p.basename(file.path)));
    }
    final sums = File(p.join(folder.path, 'SHA256SUMS')).readAsBytesSync();
    File(p.join(folder.path, 'SHA256SUMS.sig')).writeAsStringSync('${(signer ?? key).signatureLine(sums)}\n');
    return folder;
  }

  Directory installed() => Directory(p.join(temp.path, 'retro-host'));

  Future<String?> failure(Future<Object?> Function() body) async {
    try {
      await body();
    } on RetroHostReleaseFailure catch (error) {
      return error.message;
    }
    return null;
  }

  test('the recorded SHA256SUMS lists each zip and .files as sign.sh writes it', () {
    final names = Directory(_fixtures)
        .listSync()
        .whereType<File>()
        .map((file) => p.basename(file.path))
        .where((name) => name.startsWith('anyps5-retro-host-'))
        .toList();
    final files = {for (final name in names) name: File(p.join(_fixtures, name)).readAsBytesSync()};
    expect(File(p.join(_fixtures, 'SHA256SUMS')).readAsBytesSync(), sumsOf(files));
  });

  test('a signed download is unpacked with its sums, signature and file list, and checks before a start', () async {
    final version = await RetroHostRelease.install(download(), installed(), keys: keys, system: _linux);
    expect('$version', '1.0.0');
    expect(
      installed()
          .listSync(recursive: true)
          .whereType<File>()
          .map((file) => p.relative(file.path, from: installed().path).replaceAll(r'\', '/'))
          .toSet(),
      {
        'SHA256SUMS',
        'SHA256SUMS.sig',
        'anyps5-retro-host-1.0.0-linux-x64.files',
        'SOURCE.txt',
        'anyps5-retro-host',
        'swanstation_libretro.so',
        'licenses/anyps5-retro-host-GPL-2.0-or-later.txt',
        'licenses/swanstation-GPL-3.0.txt',
      },
    );
    expect(File(p.join(installed().path, 'anyps5-retro-host')).readAsStringSync(), 'anyps5-retro-host stand-in\n');

    final checked = await RetroHostRelease.checkBeforeStart(installed(), keys: keys, system: _linux);
    expect('${checked.version}', '1.0.0');
    expect(checked.executable, p.join(installed().path, 'anyps5-retro-host'));
    expect(checked.core, p.join(installed().path, 'swanstation_libretro.so'));
    expect(checked.held, isTrue);
    expect(checked.program, Platform.isLinux ? startsWith('/proc/self/fd/') : isNull);
    checked.release();
    expect(checked.held, isFalse);
    checked.release();
  });

  test('a download signed by a key the launcher does not trust is not unpacked', () async {
    expect(
      await failure(
        () => RetroHostRelease.install(
          download(signer: stranger),
          installed(),
          keys: keys,
          system: _linux,
        ),
      ),
      contains('does not trust'),
    );
    expect(installed().existsSync(), isFalse);
  });

  test('a changed zip or file list is not unpacked', () async {
    final folder = download();
    final zip = File(p.join(folder.path, 'anyps5-retro-host-1.0.0-linux-x64.zip'));
    final bytes = zip.readAsBytesSync();
    zip.writeAsBytesSync([...bytes.take(bytes.length - 1), bytes.last ^ 1]);
    expect(
      await failure(() => RetroHostRelease.install(folder, installed(), keys: keys, system: _linux)),
      'anyps5-retro-host-1.0.0-linux-x64.zip does not match the signed release',
    );
    File(p.join(folder.path, 'anyps5-retro-host-1.0.0-linux-x64.files')).writeAsStringSync('changed\n');
    expect(
      await failure(() => RetroHostRelease.install(folder, installed(), keys: keys, system: _linux)),
      'anyps5-retro-host-1.0.0-linux-x64.files does not match the signed release',
    );
    expect(installed().existsSync(), isFalse);
  });

  test('a zip that holds a file its signed list does not, or misses one, is not unpacked', () async {
    final folder = download();
    final zipPath = p.join(folder.path, 'anyps5-retro-host-1.0.0-linux-x64.zip');
    final original = ZipDecoder().decodeBytes(File(zipPath).readAsBytesSync());
    final extra = Archive();
    for (final entry in original) {
      extra.add(ArchiveFile.bytes(entry.name, entry.content));
    }
    extra.add(ArchiveFile.bytes('extra.dll', utf8.encode('extra')));
    resign(folder, zipPath, ZipEncoder().encodeBytes(extra), key);
    expect(
      await failure(() => RetroHostRelease.install(folder, installed(), keys: keys, system: _linux)),
      contains('holds extra.dll'),
    );

    final missing = Archive();
    for (final entry in original) {
      if (entry.name != 'SOURCE.txt') missing.add(ArchiveFile.bytes(entry.name, entry.content));
    }
    resign(folder, zipPath, ZipEncoder().encodeBytes(missing), key);
    expect(
      await failure(() => RetroHostRelease.install(folder, installed(), keys: keys, system: _linux)),
      contains('does not hold SOURCE.txt'),
    );
    expect(installed().existsSync(), isFalse);
  });

  test('a host older than the launcher\'s minimum is refused even signed', () async {
    const newer = RetroHostVersion(1, 0, 1);
    expect(
      await failure(
        () => RetroHostRelease.install(download(), installed(), keys: keys, system: _linux, minimum: newer),
      ),
      contains('older than 1.0.1'),
    );
    await RetroHostRelease.install(download(), installed(), keys: keys, system: _linux);
    expect(
      await failure(() => RetroHostRelease.checkBeforeStart(installed(), keys: keys, system: _linux, minimum: newer)),
      contains('older than 1.0.1'),
    );
  });

  test('only the names of the launcher\'s own system are used', () async {
    expect(
      await failure(
        () => RetroHostRelease.install(download(), installed(), keys: keys, system: RetroHostSystem.macosArm64),
      ),
      'the release has no host for macos-arm64',
    );
    await RetroHostRelease.install(download(), installed(), keys: keys, system: _windows);
    final checked = await RetroHostRelease.checkBeforeStart(installed(), keys: keys, system: _windows);
    expect(p.basename(checked.executable), 'anyps5-retro-host.exe');
    checked.release();
  });

  group('before each start', () {
    setUp(() async => RetroHostRelease.install(download(), installed(), keys: keys, system: _linux));

    test('the signature is checked again', () async {
      final sums = File(p.join(installed().path, 'SHA256SUMS')).readAsBytesSync();
      File(p.join(installed().path, 'SHA256SUMS.sig')).writeAsStringSync('${stranger.signatureLine(sums)}\n');
      expect(
        await failure(() => RetroHostRelease.checkBeforeStart(installed(), keys: keys, system: _linux)),
        contains('does not trust'),
      );
    });

    test('a changed file list is refused', () async {
      final files = File(p.join(installed().path, 'anyps5-retro-host-1.0.0-linux-x64.files'));
      files.writeAsStringSync(files.readAsStringSync().replaceFirst('SOURCE.txt', 'SOURCE.TXT'));
      expect(
        await failure(() => RetroHostRelease.checkBeforeStart(installed(), keys: keys, system: _linux)),
        'anyps5-retro-host-1.0.0-linux-x64.files does not match the signed release',
      );
    });

    for (final name in ['anyps5-retro-host', 'swanstation_libretro.so']) {
      test('a changed $name is refused', () async {
        File(p.join(installed().path, name)).writeAsStringSync('changed\n');
        expect(
          await failure(() => RetroHostRelease.checkBeforeStart(installed(), keys: keys, system: _linux)),
          '$name does not match the signed release',
        );
      });

      test('a missing $name is refused', () async {
        File(p.join(installed().path, name)).deleteSync();
        expect(
          await failure(() => RetroHostRelease.checkBeforeStart(installed(), keys: keys, system: _linux)),
          '$name is missing or not a file',
        );
      });
    }

    test('on Windows the checked files cannot be written, replaced or deleted until released', () async {
      final checked = await RetroHostRelease.checkBeforeStart(installed(), keys: keys, system: _linux);
      for (final name in ['anyps5-retro-host', 'swanstation_libretro.so']) {
        final path = p.join(installed().path, name);
        expect(() => File(path).openSync(mode: FileMode.append).closeSync(), throwsA(isA<FileSystemException>()));
        expect(() => File(path).renameSync('$path.moved'), throwsA(isA<FileSystemException>()));
        expect(() => File(path).deleteSync(), throwsA(isA<FileSystemException>()));
        expect(File(path).readAsStringSync(), isNotEmpty);
      }
      checked.release();
      File(p.join(installed().path, 'anyps5-retro-host')).openSync(mode: FileMode.append).closeSync();
      File(p.join(installed().path, 'swanstation_libretro.so')).deleteSync();
    }, skip: Platform.isWindows ? null : 'Windows only');
  });

  test('a host is started from the checked file and lets it go when the connection ends', () async {
    final host = await _realProgram(temp);
    final folder = signedRelease(temp, host.program, key);
    final checked = await RetroHostRelease.checkBeforeStart(folder, keys: keys, system: _current);
    final descriptor = checked.program?.split('/').last;
    final out = p.join(temp.path, 'out.txt');
    if (Platform.isLinux) {
      final path = p.join(folder.path, _current.executable);
      File('$path.new').writeAsStringSync('replaced\n');
      File('$path.new').renameSync(path);
    }
    final client = RetroHostClient.start(command: [checked.executable, ...host.arguments(out)], checked: checked);
    unawaited(client.ready.then((_) {}, onError: (_) {}));
    await client.exited.timeout(const Duration(seconds: 20));
    await client.ended.timeout(const Duration(seconds: 20));
    expect(checked.held, isFalse);
    await client.close();
    if (Platform.isLinux) {
      final lines = File(out).readAsLinesSync();
      expect(lines.first, '${checked.executable} (deleted)');
      expect(lines.skip(1), contains('3'));
      expect(lines.skip(1), isNot(contains(descriptor)), reason: 'the checked descriptor must not reach the host');
    } else {
      expect(client.pid, greaterThan(0));
    }
  }, skip: Platform.isLinux || Platform.isWindows ? null : 'Linux and Windows');

  test('a checked host is started only as the checked executable, and only with its SwanStation', () async {
    final host = await _realProgram(temp);
    final folder = signedRelease(temp, host.program, key);
    final out = p.join(temp.path, 'out.txt');

    final empty = await RetroHostRelease.checkBeforeStart(folder, keys: keys, system: _current);
    expect(() => RetroHostClient.start(command: const [], checked: empty), throwsArgumentError);
    expect(empty.held, isFalse);

    final other = await RetroHostRelease.checkBeforeStart(folder, keys: keys, system: _current);
    expect(
      () => RetroHostClient.start(command: [host.program, ...host.arguments(out)], checked: other),
      throwsArgumentError,
    );
    expect(other.held, isFalse);

    final checked = await RetroHostRelease.checkBeforeStart(folder, keys: keys, system: _current);
    final client = RetroHostClient.start(command: [checked.executable, ...host.arguments(out)], checked: checked);
    unawaited(client.ready.then((_) {}, onError: (_) {}));
    await expectLater(
      client.call('start', {'core': p.join(temp.path, 'other_core'), 'disc': 'x'}),
      throwsA(isA<RetroCallError>().having((error) => error.code, 'code', RetroCallError.argument)),
    );
    await client.ended.timeout(const Duration(seconds: 20));
    await expectLater(
      client.call('start', {'core': p.join(temp.path, 'other_core'), 'disc': 'x'}),
      throwsA(isA<RetroCallError>()),
    );
    await client.close();
    expect(
      () => RetroHostClient.start(command: [checked.executable, ...host.arguments(out)], checked: checked),
      throwsArgumentError,
      reason: 'a check is good for one start',
    );
  }, skip: Platform.isLinux || Platform.isWindows ? null : 'Linux and Windows');

  test("a refused second start leaves the first start's files held", () async {
    final host = await _realProgram(temp);
    final folder = signedRelease(temp, host.program, key);
    final checked = await RetroHostRelease.checkBeforeStart(folder, keys: keys, system: _current);
    expect(checked.claim(), isTrue, reason: 'the first start owns it');
    expect(() => RetroHostClient.start(command: const [], checked: checked), throwsArgumentError);
    expect(() => RetroHostClient.start(command: [host.program], checked: checked), throwsArgumentError);
    expect(checked.held, isTrue);
    checked.release();
  });

  test('a check is taken by one start only', () async {
    final host = await _realProgram(temp);
    final folder = signedRelease(temp, host.program, key);
    final checked = await RetroHostRelease.checkBeforeStart(folder, keys: keys, system: _current);
    expect(checked.claim(), isTrue);
    expect(checked.claim(), isFalse);
    checked.release();
    final released = await RetroHostRelease.checkBeforeStart(folder, keys: keys, system: _current);
    released.release();
    expect(released.claim(), isFalse);
  });

  test('a FIFO in the place of a checked file is refused without blocking', () async {
    await RetroHostRelease.install(download(), installed(), keys: keys, system: _linux);
    final core = p.join(installed().path, 'swanstation_libretro.so');
    File(core).deleteSync();
    expect(Process.runSync('mkfifo', [core]).exitCode, 0);
    expect(
      await failure(() => RetroHostRelease.checkBeforeStart(installed(), keys: keys, system: _linux))
          .timeout(const Duration(seconds: 10)),
      'swanstation_libretro.so is missing or not a file',
    );
  }, skip: Platform.isLinux ? null : 'Linux only');

  test('the host override is for debug builds only', () {
    expect(RetroHostRelease.debugBuild, isTrue, reason: 'tests run as a debug build');
  });

  group('locate', () {
    test('a debug build runs the host ANYPS5_RETRO_HOST names, unchecked, with any core', () async {
      final launch = await RetroHostRelease.locate(
        environment: {'ANYPS5_RETRO_HOST': p.join(temp.path, 'my-host')},
        debug: true,
        from: installed(),
      );
      expect(launch.command, [p.join(temp.path, 'my-host')]);
      expect(launch.checked, isNull);
      expect(launch.core, isNull);
    });

    test('with debug false, ANYPS5_RETRO_HOST is ignored and the host beside it is checked', () async {
      expect(
        await failure(
          () => RetroHostRelease.locate(
            environment: {'ANYPS5_RETRO_HOST': p.join(temp.path, 'my-host')},
            debug: false,
            from: installed(),
            keys: keys,
            system: _linux,
          ),
        ),
        'SHA256SUMS is missing',
      );
      await RetroHostRelease.install(download(), installed(), keys: keys, system: _linux);
      final launch = await RetroHostRelease.locate(
        environment: {'ANYPS5_RETRO_HOST': p.join(temp.path, 'my-host')},
        debug: false,
        from: installed(),
        keys: keys,
        system: _linux,
      );
      expect(launch.command, [p.join(installed().path, 'anyps5-retro-host')]);
      expect(launch.core, p.join(installed().path, 'swanstation_libretro.so'));
      launch.checked!.release();
    });
  });

  group('file lists', () {
    for (final name in ['../escape', '/root', 'a//b', r'a\b', 'C:x', './a', 'a/']) {
      test('refuse the name "$name"', () {
        expect(
          () => RetroHostRelease.parseFileList(utf8.encode('${'0' * 64}  $name\n')),
          throwsA(isA<RetroHostReleaseFailure>()),
        );
      });
    }

    test('take names with directories', () {
      expect(RetroHostRelease.parseFileList(utf8.encode('${'a' * 64}  licenses/x.txt\n')), {
        'licenses/x.txt': 'a' * 64,
      });
    });
  });

  test('versions are three numbers and compare by number', () {
    expect(RetroHostVersion.tryParse('1.10.0')!.compareTo(RetroHostVersion.tryParse('1.9.9')!), greaterThan(0));
    for (final text in ['1.0', '1.0.0-rc1', 'v1.0.0', '01.0.0', '1.0.0.0']) {
      expect(RetroHostVersion.tryParse(text), isNull, reason: text);
    }
  });
}

RetroHostSystem get _current => Platform.isWindows ? _windows : _linux;

/// Replaces [zipPath] by [bytes] and signs the release again with [key].
void resign(Directory folder, String zipPath, List<int> bytes, TestReleaseKey key) {
  File(zipPath).writeAsBytesSync(bytes);
  final names = folder
      .listSync()
      .whereType<File>()
      .map((file) => p.basename(file.path))
      .where((name) => name.startsWith('anyps5-retro-host-'));
  final sums = sumsOf({for (final name in names) name: File(p.join(folder.path, name)).readAsBytesSync()});
  File(p.join(folder.path, 'SHA256SUMS')).writeAsBytesSync(sums);
  File(p.join(folder.path, 'SHA256SUMS.sig')).writeAsStringSync('${key.signatureLine(sums)}\n');
}

/// An installed release for this system whose host is a copy of [program], signed by [key].
Directory signedRelease(Directory temp, String program, TestReleaseKey key) {
  final folder = Directory(p.join(temp.path, 'real'))..createSync();
  final files = {_current.executable: File(program).readAsBytesSync(), _current.core: utf8.encode('core\n')};
  for (final MapEntry(key: name, value: bytes) in files.entries) {
    File(p.join(folder.path, name)).writeAsBytesSync(bytes);
  }
  if (!Platform.isWindows) Process.runSync('chmod', ['755', p.join(folder.path, _current.executable)]);
  final names = files.keys.toList()..sort();
  final listing = utf8.encode(names.map((name) => '${sha256.convert(files[name]!)}  $name\n').join());
  final listName = 'anyps5-retro-host-1.0.0-${_current.name}.files';
  File(p.join(folder.path, listName)).writeAsBytesSync(listing);
  final sums = sumsOf({listName: listing});
  File(p.join(folder.path, 'SHA256SUMS')).writeAsBytesSync(sums);
  File(p.join(folder.path, 'SHA256SUMS.sig')).writeAsStringSync('${key.signatureLine(sums)}\n');
  return folder;
}

/// A real program to stand in for the host: `/bin/sh` reporting its own executable and descriptors
/// on Linux, `cmd.exe` exiting at once on Windows, started while its file is held.
Future<({String program, List<String> Function(String out) arguments})> _realProgram(Directory temp) async {
  if (Platform.isWindows) {
    return (
      program: p.join(Platform.environment['SystemRoot'] ?? r'C:\Windows', 'System32', 'cmd.exe'),
      arguments: (String out) => ['/c', 'exit 0'],
    );
  }
  return (
    program: File('/bin/sh').resolveSymbolicLinksSync(),
    arguments: (String out) => ['-c', r'exec >"$0"; readlink /proc/$$/exe; ls /proc/$$/fd', out],
  );
}
