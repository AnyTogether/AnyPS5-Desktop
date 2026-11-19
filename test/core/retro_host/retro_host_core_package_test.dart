import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/release_signing.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_release.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_store.dart';
import 'package:anyps5_desktop/core/toolkit_download.dart';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../support/fake_github.dart';
import '../../support/fixtures.dart';
import '../../support/retro_host_release_fixture.dart';
import '../../support/signing.dart';

/// The LRPS2 package, a core package of its own beside the host package (anyps5-retro-host
/// protocol.md "Finding and checking the host"), against the release in
/// test/fixtures/retro_host_release_lrps2, packed by host PR #22's tools/package_release.py and
/// signed with the fixture's throwaway key: added from the installed host's release, checked with
/// the host before every start, moved with the host on an update, gone with a release that lacks
/// it, and removed again. The 1.0.0 release in test/fixtures/retro_host_release has no core
/// package and offers none.
void main() {
  const system = RetroHostSystem.windowsX64;
  const lrps2 = RetroHostCorePackage.lrps2;
  final keys = retroHostFixtureKeys();
  late Directory temp;

  setUp(() => temp = temporaryFolder('retro_host_core_package'));
  tearDown(() => temp.deleteSync(recursive: true));

  Directory installed() => Directory(p.join(temp.path, 'RetroHost', 'host'));

  /// [files] written into a new folder, as a download leaves them.
  Directory folderOf(Map<String, List<int>> files, String name) {
    final folder = Directory(p.join(temp.path, name))..createSync(recursive: true);
    for (final MapEntry(key: file, value: bytes) in files.entries) {
      File(p.join(folder.path, file)).writeAsBytesSync(bytes);
    }
    return folder;
  }

  Future<String?> failure(Future<Object?> Function() body) async {
    try {
      await body();
    } on RetroHostReleaseFailure catch (error) {
      return error.message;
    }
    return null;
  }

  Future<void> installHost({bool addPs2 = false}) =>
      installRetroHostFixture(installed(), system: system, ps2: true, addPs2: addPs2);

  Future<void> addPs2([Directory? from]) =>
      RetroHostRelease.addCore(from ?? Directory(retroHostPs2Fixture), installed(), lrps2, keys: keys, system: system);

  Future<RetroHostChecked> check() => RetroHostRelease.checkBeforeStart(installed(), keys: keys, system: system);

  String inHost(String name) => p.joinAll([installed().path, ...name.split('/')]);

  test("the recorded release is the packer's: each system's two packages under one signed SHA256SUMS", () {
    final sums = File(p.join(retroHostPs2Fixture, ReleaseSigning.sumsName)).readAsBytesSync();
    final listed = ReleaseSigning.parseSums(sums).keys.toSet();
    for (final name in ['windows-x64', 'linux-x64', 'macos-arm64']) {
      expect(
        listed,
        containsAll([
          for (final ending in ['.zip', '.files', '-lrps2.zip', '-lrps2.files']) 'anyps5-retro-host-1.1.0-$name$ending',
        ]),
      );
    }
    expect(
      File(p.join(retroHostPs2Fixture, ReleaseSigning.signatureName)).readAsStringSync(),
      '${retroHostFixtureKey().signatureLine(sums)}\n',
    );
    final host = RetroHostRelease.parseFileList(
      File(p.join(retroHostPs2Fixture, 'anyps5-retro-host-1.1.0-windows-x64.files')).readAsBytesSync(),
    );
    expect(host.keys, isNot(contains(system.ps2Core)), reason: 'LRPS2 is not in the host package');
    final package = RetroHostRelease.parseFileList(
      File(p.join(retroHostPs2Fixture, 'anyps5-retro-host-1.1.0-windows-x64-lrps2.files')).readAsBytesSync(),
    );
    expect(package.keys.toSet(), {'SOURCE-lrps2.txt', 'licenses/lrps2-GPL-3.0.txt', system.ps2Core});
  });

  test('a host installed alone offers LRPS2 but has none, and is checked without it', () async {
    await installHost();
    expect(RetroHostRelease.offeredCores(installed(), system: system), {lrps2});
    expect(RetroHostRelease.installedCores(installed(), system: system), isEmpty);
    expect(RetroHostRelease.installedHasPs2Core(installed(), system: system), isFalse);
    expect(File(inHost(system.ps2Core)).existsSync(), isFalse, reason: 'never downloaded unasked');
    final checked = await check();
    addTearDown(checked.release);
    expect(checked.ps2Core, isNull);
  });

  test('the 1.0.0 release, from before LRPS2 shipped, offers no core package', () async {
    await installRetroHostFixture(installed(), system: system);
    expect(RetroHostRelease.offeredCores(installed(), system: system), isEmpty);
    expect(await failure(addPs2), 'the installed host 1.0.0 has no lrps2 package');
    expect(RetroHostRelease.installedCores(installed(), system: system), isEmpty);
  });

  test('LRPS2 added from the release is checked and held with the host before every start', () async {
    await installHost();
    await addPs2();
    expect(RetroHostRelease.installedCores(installed(), system: system), {lrps2});
    expect(RetroHostRelease.installedHasPs2Core(installed(), system: system), isTrue);
    for (final name in ['SOURCE-lrps2.txt', 'licenses/lrps2-GPL-3.0.txt', system.ps2Core]) {
      expect(File(inHost(name)).existsSync(), isTrue, reason: name);
    }
    final checked = await check();
    addTearDown(checked.release);
    expect(checked.ps2Core, inHost(system.ps2Core));
    if (Platform.isWindows) {
      expect(() => File(inHost(system.ps2Core)).writeAsStringSync('changed'), throwsA(isA<FileSystemException>()));
    }
  });

  test('a changed LRPS2, or a changed LRPS2 .files, fails the check for any game', () async {
    await installHost(addPs2: true);
    File(inHost(system.ps2Core)).writeAsStringSync('changed');
    try {
      (await check()).release();
      fail('a changed LRPS2 passed the check');
    } on RetroHostReleaseFailure catch (error) {
      expect(error.file, system.ps2Core);
    }

    await installHost(addPs2: true);
    final listing = File(inHost('anyps5-retro-host-1.1.0-windows-x64-lrps2.files'));
    listing.writeAsStringSync('${sha256.convert(utf8.encode('x'))}  ${system.ps2Core}\n');
    expect(await failure(check), 'anyps5-retro-host-1.1.0-windows-x64-lrps2.files does not match the signed release');
  });

  test('a pcsx2_libretro no installed .files lists is never given to the host', () async {
    await installHost();
    File(inHost(system.ps2Core)).writeAsStringSync("not the release's LRPS2");
    expect(RetroHostRelease.installedHasPs2Core(installed(), system: system), isFalse);
    final checked = await check();
    addTearDown(checked.release);
    expect(checked.ps2Core, isNull);
  });

  test("a package that is not the installed release's is refused, and nothing is added", () async {
    await installHost();
    final zipName = 'anyps5-retro-host-1.1.0-windows-x64-lrps2.zip';
    final changed = retroHostFixtureFiles(ps2: true);
    final zip = changed[zipName]!;
    changed[zipName] = [...zip.take(zip.length - 1), zip.last ^ 1];
    expect(await failure(() => addPs2(folderOf(changed, 'changed'))), '$zipName does not match the signed release');

    final newer = folderOf(retroHostFixtureFiles(version: '1.1.1', ps2: true), 'newer');
    expect(await failure(() => addPs2(newer)), contains('is missing'), reason: 'named for another release');
    final release = retroHostFixtureFiles(ps2: true);
    final other = folderOf({
      for (final ending in ['-lrps2.files', '-lrps2.zip'])
        'anyps5-retro-host-1.1.0-windows-x64$ending': release['anyps5-retro-host-1.1.0-linux-x64$ending']!,
    }, 'other');
    expect(
      await failure(() => addPs2(other)),
      contains('does not match the signed release'),
      reason: "another package's bytes under this package's names",
    );
    expect(RetroHostRelease.installedCores(installed(), system: system), isEmpty);
    expect(File(inHost(system.ps2Core)).existsSync(), isFalse);
  });

  test('a package with a name of the host package is refused before anything is written', () async {
    await installHost();
    final files = retroHostFixtureFiles(ps2: true);
    final stem = 'anyps5-retro-host-1.1.0-windows-x64-lrps2';
    final contents = {system.ps2Core: utf8.encode('lrps2 stand-in\n'), 'source.txt': utf8.encode('over the host\n')};
    final archive = Archive();
    for (final MapEntry(key: name, value: bytes) in contents.entries) {
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }
    files['$stem.zip'] = ZipEncoder().encode(archive);
    files['$stem.files'] = utf8.encode(
      contents.entries.map((entry) => '${sha256.convert(entry.value)}  ${entry.key}\n').join(),
    );
    final signedFiles = {
      for (final MapEntry(:key, :value) in files.entries)
        if (key.startsWith('anyps5-retro-host-')) key: value,
    };
    final sums = sumsOf(signedFiles);
    final host = installed();
    host.deleteSync(recursive: true);
    final release = folderOf({
      ...signedFiles,
      ReleaseSigning.sumsName: sums,
      ReleaseSigning.signatureName: utf8.encode('${retroHostFixtureKey().signatureLine(sums)}\n'),
    }, 'clash');
    await RetroHostRelease.install(release, host, tag: 'v1.1.0', keys: keys, system: system);
    expect(await failure(() => addPs2(release)), contains('shares a name with an installed package'));
    expect(File(inHost(system.ps2Core)).existsSync(), isFalse);
    expect(File(inHost('SOURCE.txt')).readAsStringSync(), isNot(contains('over the host')));
  });

  test('a .files cut short while it was written is not installed, and the next add writes it whole', () async {
    await installHost();
    final listing = File(inHost('anyps5-retro-host-1.1.0-windows-x64-lrps2.files'));
    final whole = File(p.join(retroHostPs2Fixture, p.basename(listing.path))).readAsBytesSync();
    File('${listing.path}.part').writeAsBytesSync(whole.take(whole.length ~/ 2).toList());
    expect(RetroHostRelease.installedCores(installed(), system: system), isEmpty);
    await addPs2();
    expect(listing.readAsBytesSync(), whole);
    expect(File('${listing.path}.part').existsSync(), isFalse);
    expect(RetroHostRelease.installedCores(installed(), system: system), {lrps2});
  });

  test('removing LRPS2 deletes its files and leaves the host whole', () async {
    await installHost(addPs2: true);
    RetroHostRelease.removeCore(installed(), lrps2, keys: keys, system: system);
    expect(RetroHostRelease.installedCores(installed(), system: system), isEmpty);
    for (final name in ['SOURCE-lrps2.txt', 'licenses/lrps2-GPL-3.0.txt', system.ps2Core]) {
      expect(File(inHost(name)).existsSync(), isFalse, reason: name);
    }
    expect(File(inHost('licenses/swanstation-GPL-3.0.txt')).existsSync(), isTrue);
    final checked = await check();
    addTearDown(checked.release);
    expect(checked.ps2Core, isNull);
    RetroHostRelease.removeCore(installed(), lrps2, keys: keys, system: system);
  });

  group('a host update', () {
    test('installs the LRPS2 it had from the new release in the same step', () async {
      await installHost(addPs2: true);
      final newer = folderOf(retroHostFixtureFiles(version: '1.1.1', ps2: true), 'newer');
      await RetroHostRelease.install(newer, installed(), tag: 'v1.1.1', keys: keys, system: system, cores: {lrps2});
      expect(RetroHostRelease.installedVersion(installed(), system: system), const RetroHostVersion(1, 1, 1));
      expect(RetroHostRelease.installedCores(installed(), system: system), {lrps2});
      expect(File(inHost('anyps5-retro-host-1.1.1-windows-x64-lrps2.files')).existsSync(), isTrue);
      expect(File(inHost('anyps5-retro-host-1.1.0-windows-x64-lrps2.files')).existsSync(), isFalse);
      final checked = await check();
      addTearDown(checked.release);
      expect(checked.ps2Core, inHost(system.ps2Core));
    });

    test('to a release without LRPS2 removes it', () async {
      await installHost(addPs2: true);
      final newer = folderOf(retroHostFixtureFiles(version: '1.2.0'), 'newer');
      await RetroHostRelease.install(newer, installed(), tag: 'v1.2.0', keys: keys, system: system, cores: {lrps2});
      expect(RetroHostRelease.installedCores(installed(), system: system), isEmpty);
      expect(RetroHostRelease.offeredCores(installed(), system: system), isEmpty);
      expect(File(inHost(system.ps2Core)).existsSync(), isFalse);
    });

    test('of a host without LRPS2 does not add it', () async {
      await installHost();
      final newer = folderOf(retroHostFixtureFiles(version: '1.1.1', ps2: true), 'newer');
      await RetroHostRelease.install(newer, installed(), tag: 'v1.1.1', keys: keys, system: system);
      expect(RetroHostRelease.installedCores(installed(), system: system), isEmpty);
      expect(RetroHostRelease.offeredCores(installed(), system: system), {lrps2});
    });
  });

  group('from GitHub', () {
    late FakeGitHub github;
    late GitHubReleases releases;
    setUp(() async {
      github = await FakeGitHub.start(repository: RetroHostStore.repository);
      releases = GitHubReleases(api: github.api, repository: RetroHostStore.repository, signingKeys: keys);
    });
    tearDown(() async => github.close());

    RetroHostStore store() => RetroHostStore(p.join(temp.path, 'RetroHost'), keys: keys, system: system);

    Future<ToolkitFailure> toolkitFailure(Future<Object?> future) async {
      try {
        await future;
      } on ToolkitFailure catch (error) {
        return error;
      }
      fail('expected a ToolkitFailure');
    }

    test('the host alone is fetched, then LRPS2 only for this system, against the kept sums', () async {
      github.releases.add(retroHostFixtureRelease(ps2: true));
      final host = store();
      await host.putInPlace(await host.fetch(RetroHostStore.newest(await releases.all())));
      expect(github.downloads.map(p.posix.basename).where((name) => name.contains('lrps2')), isEmpty);
      expect(host.offeredCores, {lrps2});

      var seen = github.downloads.length;
      final release = (await releases.all()).single;
      await host.putCoreInPlace(await host.fetchCore(release, lrps2), lrps2);
      expect(github.downloads.skip(seen).map(p.posix.basename).toSet(), {
        'anyps5-retro-host-1.1.0-windows-x64-lrps2.files',
        'anyps5-retro-host-1.1.0-windows-x64-lrps2.zip',
      });
      expect(host.installedCores, {lrps2});
      expect(host.installed()!.ps2Core, inHost(system.ps2Core));
      expect(Directory(p.join(temp.path, 'RetroHost', '.downloads', 'v1.1.0-lrps2')).existsSync(), isFalse);

      github.releases.insert(0, retroHostFixtureRelease(tag: 'v1.1.1', ps2: true));
      seen = github.downloads.length;
      final update = await host.fetch(RetroHostStore.newest(await releases.all()), cores: host.installedCores);
      expect(
        github.downloads.skip(seen).map(p.posix.basename),
        contains('anyps5-retro-host-1.1.1-windows-x64-lrps2.zip'),
      );
      await host.putInPlace(update, cores: host.installedCores);
      expect(host.version, const RetroHostVersion(1, 1, 1));
      expect(host.installedCores, {lrps2});

      host.removeCore(lrps2);
      expect(host.installed()!.ps2Core, isNull);
    });

    test("only from the installed host's own release", () async {
      github.releases
        ..add(retroHostFixtureRelease(tag: 'v1.1.1', ps2: true))
        ..add(retroHostFixtureRelease(ps2: true));
      final host = store();
      await installHost();
      final other = (await releases.all()).firstWhere((release) => release.tag == 'v1.1.1');
      final error = await toolkitFailure(host.fetchCore(other, lrps2));
      expect(error.kind, ToolkitFailureKind.notAvailable);
      expect(github.downloads, isEmpty);
      expect((await toolkitFailure(host.fetchCore(null, lrps2))).kind, ToolkitFailureKind.notAvailable);
    });
  });
}
