import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/retro_host/retro_host_release.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_store.dart';
import 'package:anyps5_desktop/core/toolkit_download.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../support/fake_github.dart';
import '../../support/fixtures.dart';
import '../../support/retro_host_release_fixture.dart';
import '../../support/signing.dart';

/// The download of the emulator host from its GitHub releases (RetroHostStore), against a fake
/// GitHub serving the recorded release of test/fixtures/retro_host_release as the host repository
/// publishes it: packed by its tools/package_release.py and signed by sign.sh with the fixture's
/// throwaway key.
void main() {
  const system = RetroHostSystem.windowsX64;
  late FakeGitHub github;
  late Directory temp;
  late GitHubReleases releases;

  setUp(() async {
    github = await FakeGitHub.start(repository: RetroHostStore.repository);
    temp = temporaryFolder('retro_host_store');
    releases = GitHubReleases(
      api: github.api,
      repository: RetroHostStore.repository,
      signingKeys: retroHostFixtureKeys(),
    );
  });

  tearDown(() async {
    await github.close();
    temp.deleteSync(recursive: true);
  });

  RetroHostStore store({RetroHostSystem? on = system}) =>
      RetroHostStore(p.join(temp.path, 'RetroHost'), keys: retroHostFixtureKeys(), system: on);

  Future<ToolkitFailure> failure(Future<Object?> future) async {
    try {
      await future;
    } on ToolkitFailure catch (error) {
      return error;
    }
    fail('expected a ToolkitFailure');
  }

  Future<UpstreamRelease?> newest() async => RetroHostStore.newest(await releases.all());

  test('the recorded release is downloaded, checked and installed, and checks before a start', () async {
    github.releases.add(retroHostFixtureRelease());
    final host = store();
    expect(host.installed(), isNull);
    expect(host.version, isNull);

    final progress = <ToolkitProgress>[];
    final download = await host.fetch(await newest(), onProgress: progress.add);
    final version = await host.putInPlace(download);

    expect(version, const RetroHostVersion(1, 0, 0));
    expect(host.version, const RetroHostVersion(1, 0, 0));
    expect(github.downloads.map((path) => path.split('/').last).toSet(), {
      'SHA256SUMS',
      'SHA256SUMS.sig',
      'anyps5-retro-host-1.0.0-windows-x64.files',
      'anyps5-retro-host-1.0.0-windows-x64.zip',
    }, reason: "only this system's files, not the other systems' or the source archive");
    expect(progress.last.received, progress.last.total);
    expect(Directory(p.join(temp.path, 'RetroHost', '.downloads')).existsSync(), isFalse);

    final install = host.installed()!;
    expect(install.checked, isTrue);
    expect(install.host, p.join(host.folder.path, 'anyps5-retro-host.exe'));
    expect(install.core, p.join(host.folder.path, 'swanstation_libretro.dll'));
    final checked = await host.check();
    expect((checked.executable, checked.core), (install.host, install.core));
    expect(checked.held, isTrue);
    checked.release();
  });

  test('LRPS2 is the one the release lists: a stray pcsx2_libretro file is no LRPS2, before or at a start', () async {
    final host = store();
    await installRetroHostFixture(host.folder, system: system);
    final stray = File(p.join(host.folder.path, system.ps2Core))..writeAsStringSync("not the release's LRPS2");
    expect(host.installed()!.ps2Core, isNull, reason: 'the .files does not list it');
    final checked = await host.check();
    expect(checked.ps2Core, isNull);
    checked.release();

    stray.deleteSync();
    host.folder.deleteSync(recursive: true);
    await installRetroHostFixture(host.folder, system: system, ps2: true);
    expect(host.installed()!.ps2Core, p.join(host.folder.path, system.ps2Core));
    File(p.join(host.folder.path, system.ps2Core)).writeAsStringSync('changed');
    try {
      (await host.check()).release();
      fail('a changed LRPS2 passed the check');
    } on RetroHostReleaseFailure catch (failure) {
      expect(failure.file, system.ps2Core, reason: 'the log names LRPS2 as the file that failed');
    }
  });

  test('the newest signed release at or above the minimum is taken, never a pre-release', () async {
    final signedSums = retroHostFixtureFiles();
    github.releases
      ..add(FakeRelease('v2.0.0', {'notes.txt': utf8.encode('no sums\n')}))
      ..add(FakeRelease('v1.5.0', Map.of(signedSums), prerelease: true))
      ..add(FakeRelease('nightly-1.4.0', Map.of(signedSums)))
      ..add(FakeRelease('v1.2.0', Map.of(signedSums)))
      ..add(FakeRelease('v0.9.0', Map.of(signedSums)));
    expect((await newest())?.tag, 'v1.2.0');
    github.releases.removeWhere((release) => release.tag == 'v1.2.0');
    expect(await newest(), isNull, reason: 'v0.9.0 is below the minimum ${RetroHostRelease.minimumVersion}');
  });

  test('without a signed release nothing is downloaded: not available yet', () async {
    expect((await failure(store().fetch(null))).kind, ToolkitFailureKind.notAvailable);
    final unsigned = Map.of(retroHostFixtureFiles())..remove('SHA256SUMS.sig');
    final release = FakeRelease('v1.0.0', unsigned);
    github.releases.add(release);
    expect((await failure(store().fetch((await releases.all()).single))).kind, ToolkitFailureKind.notAvailable);
    expect(github.downloads, isEmpty);
    expect((await failure(store(on: null).fetch(await newest()))).kind, ToolkitFailureKind.notAvailable);
  });

  test('a release signed by a key the launcher does not trust: only the sums were fetched', () async {
    final files = retroHostFixtureFiles();
    files['SHA256SUMS.sig'] = utf8.encode('${TestReleaseKey('someone else').signatureLine(files['SHA256SUMS']!)}\n');
    github.releases.add(FakeRelease('v1.0.0', files));
    final error = await failure(store().fetch(await newest()));
    expect(error.kind, ToolkitFailureKind.signature);
    expect(error.message, contains('does not trust'));
    expect(github.downloads.map((path) => path.split('/').last).toSet(), {'SHA256SUMS', 'SHA256SUMS.sig'});
    expect(store().installed(), isNull);
  });

  test('a zip that is not the signed one is refused before it is unpacked', () async {
    final files = retroHostFixtureFiles();
    final zip = files['anyps5-retro-host-1.0.0-windows-x64.zip']!;
    files['anyps5-retro-host-1.0.0-windows-x64.zip'] = [...zip.take(zip.length - 1), zip.last ^ 1];
    github.releases.add(FakeRelease('v1.0.0', files));
    final error = await failure(store().fetch(await newest()));
    expect(error.kind, ToolkitFailureKind.checksum);
    expect(store().installed(), isNull);
  });

  test('a release that names no host for this system is not available', () async {
    github.releases.add(retroHostFixtureRelease());
    const other = RetroHostSystem(
      'linux-arm64',
      executable: 'anyps5-retro-host',
      core: 'swanstation_libretro.so',
      ps2Core: 'pcsx2_libretro.so',
    );
    final error = await failure(store(on: other).fetch(await newest()));
    expect(error.kind, ToolkitFailureKind.notAvailable);
    expect(error.message, contains('no host for linux-arm64'));
  });

  test('an older signed release published again under a higher tag is refused before its zip is fetched', () async {
    github.releases.add(retroHostFixtureRelease(tag: 'v1.2.0', signedAs: '1.0.0'));
    final release = await newest();
    expect(release?.tag, 'v1.2.0', reason: 'picked by its tag, as any newer release');
    final error = await failure(store().fetch(release));
    expect(error.kind, ToolkitFailureKind.signature);
    expect(error.message, 'v1.2.0: the release tagged v1.2.0 is signed as host 1.0.0');
    expect(github.downloads.map((path) => path.split('/').last).toSet(), {'SHA256SUMS', 'SHA256SUMS.sig'});
    expect(Directory(p.join(temp.path, 'RetroHost', '.downloads', 'v1.2.0')).existsSync(), isFalse);
    expect(store().installed(), isNull);
  });

  test('a newer release is signed as its own tag, and installs as that version', () async {
    github.releases.add(retroHostFixtureRelease(tag: 'v1.2.0'));
    final host = store();
    final download = await host.fetch(await newest());
    expect(download.tag, 'v1.2.0');
    expect(
      (await failure(host.putInPlace((folder: download.folder, tag: 'v1.3.0')))).message,
      'the release tagged v1.3.0 is signed as host 1.2.0',
      reason: 'the tag is held to the signed version on install too',
    );
    expect(host.installed(), isNull);
    expect(await host.putInPlace(download), const RetroHostVersion(1, 2, 0));
    expect(host.version, const RetroHostVersion(1, 2, 0));
    (await host.check()).release();
  });

  test('a host left in host.old by a launcher stopped while putting a new one in place is found again', () async {
    github.releases.add(retroHostFixtureRelease());
    final host = store();
    await host.putInPlace(await host.fetch(await newest()));
    host.folder.renameSync('${host.folder.path}.old');
    final found = store().installed();
    expect(found?.host, p.join(host.folder.path, 'anyps5-retro-host.exe'));
    expect(Directory('${host.folder.path}.old').existsSync(), isFalse);
    (await host.check()).release();
  });

  test('a host that cannot be written on the unpacking isolate fails as a write, leaving the old host', () async {
    github.releases.add(retroHostFixtureRelease());
    final host = store();
    await host.putInPlace(await host.fetch(await newest()));
    File('${host.folder.path}.new').writeAsStringSync('in the way\n');
    final error = await failure(host.putInPlace(await host.fetch(await newest())));
    expect(error.kind, ToolkitFailureKind.badLayout);
    expect(error.message, startsWith('the host could not be written'));
    (await host.check()).release();
  });

  test('a stopped download keeps what came, and the next try carries on', () async {
    github.releases.add(retroHostFixtureRelease());
    final zip = 'anyps5-retro-host-1.0.0-windows-x64.zip';
    github.dropAfter[zip] = 1000;
    final host = store();
    expect((await failure(host.fetch(await newest()))).kind, ToolkitFailureKind.network);
    await host.putInPlace(await host.fetch(await newest()));
    expect(github.requests.where((request) => request.$1.endsWith('/$zip') && request.$2 == 'bytes=1000-'), isNotEmpty);
    expect(host.version, const RetroHostVersion(1, 0, 0));
  });
}
