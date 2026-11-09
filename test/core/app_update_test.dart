import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/app_update.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/toolkit_download.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_github.dart';
import '../support/fixtures.dart';
import '../support/signing.dart';

void main() {
  final key = TestReleaseKey('desktop release');
  late FakeGitHub github;
  late Directory temp;
  late GitHubReleases releases;

  FakeRelease desktopRelease(String version) => FakeRelease('v$version', {
    'AnyPS5-Desktop-Setup-$version-x64.exe': [0x4D, 0x5A, ...filler('setup$version')],
    'AnyPS5-Desktop-$version-x86_64.AppImage': filler('appimage$version'),
    'AnyPS5-Desktop-linux-x64.tar.gz': filler('tar$version'),
    'AnyPS5-Desktop-windows-x64.zip': filler('zip$version'),
  });

  setUp(() async {
    github = await FakeGitHub.start(repository: LauncherUpdates.repository);
    temp = temporaryFolder('updates');
    releases = LauncherUpdates.source(api: github.api, keys: [key.key]);
  });

  tearDown(() async {
    await github.close();
    temp.deleteSync(recursive: true);
  });

  Future<ToolkitFailure> failure(Future<Object?> future) async {
    try {
      await future;
    } on ToolkitFailure catch (error) {
      return error;
    }
    fail('expected a ToolkitFailure');
  }

  test('a newer signed release is found and its installer for this system downloaded and checked', () async {
    github.releases.add(signed(desktopRelease('0.1.3'), [key]));
    final latest = await releases.latest();
    expect(LauncherUpdates.isNewer(latest, '0.1.2'), isTrue);
    expect(LauncherUpdates.isNewer(latest, '0.1.3'), isFalse);
    expect(LauncherUpdates.assetFor(latest, HostSystem.windows)!.name, 'AnyPS5-Desktop-Setup-0.1.3-x64.exe');
    expect(LauncherUpdates.assetFor(latest, HostSystem.linux)!.name, 'AnyPS5-Desktop-linux-x64.tar.gz');
    final appImage = LauncherUpdates.assetFor(latest, HostSystem.linux, appImage: true)!;
    expect(appImage.name, 'AnyPS5-Desktop-0.1.3-x86_64.AppImage');
    final path = await LauncherUpdates.download(latest, appImage, temp.path);
    expect(p.basename(path), appImage.name);
    expect(File(path).readAsBytesSync(), filler('appimage0.1.3'));
    // The sums and the signature are not left behind.
    expect(Directory(temp.path).listSync().map((entry) => p.basename(entry.path)), [appImage.name]);
  });

  test('an installer that does not match the signed sums is refused and thrown away', () async {
    final release = signed(desktopRelease('0.1.3'), [key]);
    release.files['AnyPS5-Desktop-Setup-0.1.3-x64.exe'] = utf8.encode('something else');
    github.releases.add(release);
    final latest = await releases.latest();
    final setup = LauncherUpdates.assetFor(latest, HostSystem.windows)!;
    expect((await failure(LauncherUpdates.download(latest, setup, temp.path))).kind, ToolkitFailureKind.checksum);
    expect(File(p.join(temp.path, setup.name)).existsSync(), isFalse);
  });

  test('an unsigned release, or one signed by another key, is never downloaded', () async {
    github.releases.add(desktopRelease('0.1.3'));
    var latest = await releases.latest();
    var refused = await failure(
      LauncherUpdates.download(latest, LauncherUpdates.assetFor(latest, HostSystem.windows)!, temp.path),
    );
    expect(refused.kind, ToolkitFailureKind.signature);
    expect(refused.message, 'AnyPS5 Desktop 0.1.3 is not signed');
    github.releases
      ..clear()
      ..add(signed(desktopRelease('0.1.4'), [TestReleaseKey('stranger')]));
    latest = await releases.latest();
    refused = await failure(
      LauncherUpdates.download(latest, LauncherUpdates.assetFor(latest, HostSystem.windows)!, temp.path),
    );
    expect(refused.kind, ToolkitFailureKind.signature);
    expect(refused.message, contains('does not trust'));
    expect(github.downloads.where((path) => !path.contains('SHA256SUMS')), isEmpty);
  });

  group('the Nightly channel', () {
    const signedTag = '0.1.21-nightly.20261109.1';
    const unsignedTag = '0.1.21-nightly.20261110.1';

    FakeRelease nightly(String version) {
      final release = desktopRelease(version);
      return FakeRelease(release.tag, release.files, prerelease: true);
    }

    test('offers the newest signed build, not one CI has just published unsigned', () async {
      github.releases
        ..add(nightly(unsignedTag))
        ..add(signed(nightly(signedTag), [key]))
        ..add(signed(desktopRelease('0.1.20'), [key]));
      final found = LauncherUpdates.newestNightly(await releases.all(), HostSystem.windows)!;
      expect(found.version, signedTag);
      expect(found.prerelease, isTrue);
      final setup = LauncherUpdates.assetFor(found, HostSystem.windows)!;
      expect(setup.name, 'AnyPS5-Desktop-Setup-$signedTag-x64.exe');
      expect(File(await LauncherUpdates.download(found, setup, temp.path)).existsSync(), isTrue);
    });

    test('takes the unsigned build once it is signed, and a release once one is newer', () async {
      github.releases
        ..add(signed(nightly(unsignedTag), [key]))
        ..add(signed(nightly(signedTag), [key]));
      expect(LauncherUpdates.newestNightly(await releases.all(), HostSystem.linux)!.version, unsignedTag);
      github.releases.add(signed(desktopRelease('0.1.21'), [key]));
      expect(LauncherUpdates.newestNightly(await releases.all(), HostSystem.linux)!.version, '0.1.21');
    });

    test('leaves out a build without a file for this system', () async {
      final noWindows = nightly(signedTag)..files.remove('AnyPS5-Desktop-Setup-$signedTag-x64.exe');
      github.releases
        ..add(signed(noWindows, [key]))
        ..add(signed(desktopRelease('0.1.20'), [key]));
      final all = await releases.all();
      expect(LauncherUpdates.newestNightly(all, HostSystem.windows)!.version, '0.1.20');
      expect(LauncherUpdates.newestNightly(all, HostSystem.linux, appImage: true)!.version, signedTag);
    });

    test('Stable never sees a nightly: GitHub calls the release the latest', () async {
      github.releases
        ..add(signed(nightly(signedTag), [key]))
        ..add(signed(desktopRelease('0.1.20'), [key]));
      expect((await releases.latest()).version, '0.1.20');
    });

    test('an installer left by Later for a newer nightly runs, an older one does not', () {
      final installer = p.join(temp.path, 'setup.exe');
      File(installer).writeAsBytesSync([1, 2, 3]);
      LauncherUpdates.writePending(temp.path, '0.1.21-nightly.20261109.10', installer);
      expect(LauncherUpdates.takePending(temp.path, '0.1.21-nightly.20261109.9'), installer);
      LauncherUpdates.writePending(temp.path, '0.1.21-nightly.20261109.1', installer);
      expect(LauncherUpdates.takePending(temp.path, '0.1.21-nightly.20261109.2'), isNull);
      LauncherUpdates.writePending(temp.path, '0.1.21', installer);
      expect(LauncherUpdates.takePending(temp.path, '0.1.21-nightly.20261109.2'), installer);
    });
  });

  test('the launcher reads its own repository with the built-in keys', () {
    final source = LauncherUpdates.source();
    expect(source.repository, 'AnyTogether/AnyPS5-Desktop');
    expect(source.signingKeys, isNotEmpty);
  });
}
