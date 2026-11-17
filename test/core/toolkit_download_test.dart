import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/release_signing.dart';
import 'package:anyps5_desktop/core/toolkit.dart';
import 'package:anyps5_desktop/core/toolkit_download.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_github.dart';
import '../support/fixtures.dart';
import '../support/signing.dart';

void main() {
  late FakeGitHub github;
  late Directory temp;
  late GitHubReleases releases;

  setUp(() async {
    github = await FakeGitHub.start();
    temp = temporaryFolder('toolkits');
    releases = GitHubReleases(api: github.api);
  });

  tearDown(() async {
    await github.close();
    temp.deleteSync(recursive: true);
  });

  ToolkitStore store(HostSystem system) => ToolkitStore(p.join(temp.path, 'Toolkits'), system: system);

  Future<ToolkitFailure> failure(Future<Object?> future) async {
    try {
      await future;
    } on ToolkitFailure catch (error) {
      return error;
    }
    fail('expected a ToolkitFailure');
  }

  group('releases', () {
    test('the latest release and the older ones come from the API, newest first, without drafts', () async {
      github.releases.addAll([
        upstreamRelease('0.1.10'),
        FakeRelease('v0.2.0-rc1', {}, prerelease: true),
        upstreamRelease('0.1.9'),
        FakeRelease('v0.3.0', {}, draft: true),
        upstreamRelease('0.1.2'),
      ]);
      final latest = await releases.latest();
      expect(latest.tag, 'v0.1.10');
      expect(latest.version, '0.1.10');
      expect(latest.published, DateTime.utc(2026, 10, 20, 9, 31, 13));
      final all = await releases.all();
      expect(all.map((release) => release.tag), ['v0.2.0-rc1', 'v0.1.10', 'v0.1.9', 'v0.1.2']);
      expect(all.first.prerelease, isTrue);
      expect(github.requests.first.$1, '/api/repos/boykopovar/AnyPS5/releases/latest');
    });

    test('each system gets its relinker and its libraries, the other archive format as a fallback', () async {
      github.releases.add(upstreamRelease('0.1.3'));
      final release = await releases.latest();
      final linux = release.packageFor(HostSystem.linux)!;
      expect(linux.relinker.name, 'relinker-v0.1.3');
      expect(linux.libraries.name, 'prx-linux-v0.1.3.tar.gz');
      final windows = release.packageFor(HostSystem.windows)!;
      expect(windows.relinker.name, 'relinker-v0.1.3.exe');
      expect(windows.libraries.name, 'prx-windows-v0.1.3.zip');
      expect(windows.size, windows.relinker.size + windows.libraries.size);
      expect(windows.verified, isTrue);
      expect(windows.toolkitVersion, 'upstream-v0.1.3');
      expect(windows.libraries.sha256, hasLength(64));

      final onlyTar = UpstreamRelease(
        tag: 'v1.0.0',
        assets: [
          for (final name in ['relinker-v1.0.0.exe', 'prx-windows-v1.0.0.tar.gz', 'relinker-v1.0.0'])
            ReleaseAsset(name: name, size: 1, url: Uri.parse('http://x/$name')),
        ],
      );
      expect(onlyTar.packageFor(HostSystem.windows)!.libraries.name, 'prx-windows-v1.0.0.tar.gz');
      expect(onlyTar.packageFor(HostSystem.windows)!.verified, isFalse);
      expect(onlyTar.packageFor(HostSystem.linux), isNull);
    });

    test('versions order by their numbers, a release after its pre-release', () {
      expect(compareVersions('0.1.10', '0.1.9'), greaterThan(0));
      expect(compareVersions('v0.2.0', '0.1.99'), greaterThan(0));
      expect(compareVersions('0.2.0', '0.2.0-rc1'), greaterThan(0));
      expect(compareVersions('0.1.3', 'v0.1.3'), isNot(lessThan(0)));
      expect(compareVersions('1.0', '1.0.0'), lessThanOrEqualTo(0));
    });

    test('GitHub answering with an error is a network failure', () async {
      github.apiStatus = 403;
      final error = await failure(releases.latest());
      expect(error.kind, ToolkitFailureKind.network);
      expect(error.message, contains('403'));
      await github.close();
      expect((await failure(releases.all())).kind, ToolkitFailureKind.network);
    });
  });

  group('install', () {
    test('Linux: the relinker and libs/ from the .tar.gz, executable, with version.txt', () async {
      github.releases.add(upstreamRelease('0.1.3'));
      final package = (await releases.latest()).packageFor(HostSystem.linux)!;
      final progress = <ToolkitProgress>[];
      final toolkit = await store(HostSystem.linux).install(package, onProgress: progress.add);
      expect(toolkit.root, p.join(temp.path, 'Toolkits', '0.1.3'));
      expect(toolkit.problem, isNull);
      expect(toolkit.version, 'upstream-v0.1.3');
      expect(File(p.join(toolkit.root, 'version.txt')).readAsStringSync(), 'upstream-v0.1.3\n');
      expect(File(toolkit.relinker).readAsStringSync(), contains('relinker 0.1.3'));
      expect(p.basename(toolkit.relinker), 'relinker');
      if (!Platform.isWindows) {
        expect(File(toolkit.relinker).statSync().mode & 0x49, 0x49, reason: 'executable for everyone');
        expect(Process.runSync(toolkit.relinker, const []).stdout, contains('relinker 0.1.3'));
      }
      expect(toolkit.libraryFiles.map(p.basename), ['libSceVideoOut.prx', 'libkernel.prx']);
      expect(File(p.join(toolkit.libraries, 'libkernel.prx')).readAsBytesSync(), filler('kernel0.1.3'));
      // Only the two files for this system were downloaded, both through the redirect.
      expect(github.downloads, ['/blob/v0.1.3/relinker-v0.1.3', '/blob/v0.1.3/prx-linux-v0.1.3.tar.gz']);
      // Progress only grows, ends with the whole size and walks through the phases.
      for (var index = 1; index < progress.length; index++) {
        expect(progress[index].received, greaterThanOrEqualTo(progress[index - 1].received));
      }
      expect(progress.last.received, package.size);
      expect(progress.map((step) => step.phase).toSet(), ToolkitPhase.values.toSet());
      // Nothing is left over beside the toolkit.
      expect(Directory(store(HostSystem.linux).root).listSync().map((entity) => p.basename(entity.path)).toSet(), {
        '0.1.3',
        '.downloads',
      });
      expect(Directory(p.join(store(HostSystem.linux).root, '.downloads')).listSync(), isEmpty);
    });

    test('Windows: relinker.exe and the zip, with libraries at the top as 0.1.0 had them, DLLs kept', () async {
      github.releases.add(upstreamRelease('0.1.0', flat: true));
      final package = (await releases.latest()).packageFor(HostSystem.windows)!;
      final toolkit = await store(HostSystem.windows).install(package);
      expect(p.basename(toolkit.relinker), 'relinker.exe');
      expect(File(toolkit.relinker).readAsBytesSync().take(2), [0x4D, 0x5A]);
      expect(toolkit.problem, isNull);
      expect(toolkit.libraryFiles.map(p.basename).toSet(), {
        'libSceVideoOut.prx',
        'libkernel.prx',
        'libwinpthread-1.dll',
        'libstdc++-6.dll',
      });
      expect(toolkit.version, 'upstream-v0.1.0');
      expect(github.downloads.last, '/blob/v0.1.0/prx-windows-v0.1.0.zip');
    });

    test('what sits beside libs/ in the archive (patches) is kept', () async {
      final release = upstreamRelease('0.2.0');
      release.files['prx-linux-v0.2.0.tar.gz'] = tarGzOf({
        'libs/libkernel.prx': filler('k'),
        'patches/PPSA01234.toml': utf8.encode('[patch]\n'),
        'version.txt': utf8.encode('not ours\n'),
      });
      github.releases.add(release);
      final toolkit = await store(HostSystem.linux).install((await releases.latest()).packageFor(HostSystem.linux)!);
      expect(toolkit.patchFile('PPSA01234'), isNotNull);
      expect(toolkit.version, 'upstream-v0.2.0');
    });

    test('a dropped connection carries on from where it stopped', () async {
      github.releases.add(upstreamRelease('0.1.3', librarySize: 60000));
      final package = (await releases.latest()).packageFor(HostSystem.linux)!;
      final archive = package.libraries.name;
      github.dropAfter[archive] = 20000;
      final error = await failure(store(HostSystem.linux).install(package));
      expect(error.kind, ToolkitFailureKind.network);
      final part = File(p.join(store(HostSystem.linux).root, '.downloads', '$archive.part'));
      expect(part.lengthSync(), 20000);

      final toolkit = await store(HostSystem.linux).install(package);
      expect(toolkit.problem, isNull);
      final ranges = github.requests.where((request) => request.$1.endsWith(archive)).map((request) => request.$2);
      expect(ranges, contains('bytes=20000-'));
      // The relinker, already complete, was not downloaded again.
      expect(github.downloads.where((path) => path.endsWith('relinker-v0.1.3')), hasLength(1));
      expect(part.existsSync(), isFalse);
    });

    test('a server that ignores the range sends the file again from the start', () async {
      github.releases.add(upstreamRelease('0.1.3', librarySize: 60000));
      final package = (await releases.latest()).packageFor(HostSystem.linux)!;
      github.dropAfter[package.libraries.name] = 10000;
      await failure(store(HostSystem.linux).install(package));
      github.ignoreRange = true;
      final toolkit = await store(HostSystem.linux).install(package);
      expect(toolkit.problem, isNull);
    });

    test('a file that does not match its checksum is refused and thrown away', () async {
      final release = upstreamRelease('0.1.3');
      release.wrongDigests['prx-linux-v0.1.3.tar.gz'] = 'ab' * 32;
      github.releases.add(release);
      final package = (await releases.latest()).packageFor(HostSystem.linux)!;
      final error = await failure(store(HostSystem.linux).install(package));
      expect(error.kind, ToolkitFailureKind.checksum);
      expect(store(HostSystem.linux).installed(), isEmpty);
      final downloads = Directory(p.join(store(HostSystem.linux).root, '.downloads'));
      expect(downloads.listSync().map((entity) => p.basename(entity.path)), ['relinker-v0.1.3']);
    });

    test('without checksums from GitHub nothing is downloaded unless the user agrees', () async {
      github.releases.add(upstreamRelease('0.1.3')..digests = false);
      final package = (await releases.latest()).packageFor(HostSystem.linux)!;
      expect(package.verified, isFalse);
      final error = await failure(store(HostSystem.linux).install(package));
      expect(error.kind, ToolkitFailureKind.unverified);
      expect(github.downloads, isEmpty);
      final toolkit = await store(HostSystem.linux).install(package, allowUnverified: true);
      expect(toolkit.problem, isNull);
    });

    test('stopping a download keeps what came, to carry on later', () async {
      github.releases.add(upstreamRelease('0.1.3', librarySize: 60000));
      final package = (await releases.latest()).packageFor(HostSystem.linux)!;
      github.holdAfter[package.libraries.name] = 30000;
      final cancel = DownloadCancel();
      final future = failure(
        store(HostSystem.linux).install(
          package,
          cancel: cancel,
          onProgress: (progress) {
            if (progress.received >= package.relinker.size + 30000) cancel.cancel();
          },
        ),
      );
      final error = await future;
      github.release();
      expect(error.kind, ToolkitFailureKind.cancelled);
      final part = File(p.join(store(HostSystem.linux).root, '.downloads', '${package.libraries.name}.part'));
      expect(part.lengthSync(), 30000);
      expect(store(HostSystem.linux).installed(), isEmpty);
      final toolkit = await store(HostSystem.linux).install(package);
      expect(toolkit.problem, isNull);
    });

    test('a release without this system\'s files is not a package', () async {
      github.releases.add(
        FakeRelease('v0.0.1', {
          'relinker-v0.0.1': [1],
        }),
      );
      expect((await releases.latest()).packageFor(HostSystem.linux), isNull);
    });

    test('an archive without libraries is not a toolkit', () async {
      final release = upstreamRelease('0.1.3');
      release.files['prx-linux-v0.1.3.tar.gz'] = tarGzOf({'README.md': utf8.encode('hi')});
      github.releases.add(release);
      final error = await failure(
        store(HostSystem.linux).install((await releases.latest()).packageFor(HostSystem.linux)!),
      );
      expect(error.kind, ToolkitFailureKind.badLayout);
      expect(store(HostSystem.linux).installed(), isEmpty);
      expect(Directory(store(HostSystem.linux).folderFor('0.1.3')).existsSync(), isFalse);
    });
  });

  group('signed source', () {
    final key = TestReleaseKey('release');
    late FakeGitHub ours;
    late GitHubReleases signedReleases;

    setUp(() async {
      ours = await FakeGitHub.start(repository: 'AnyTogether/AnyPS5-ARM');
      signedReleases = GitHubReleases(api: ours.api, repository: 'AnyTogether/AnyPS5-ARM', signingKeys: [key.key]);
    });
    tearDown(() => ours.close());

    test('a signed release is checked against its signed sums and installed', () async {
      ours.releases.add(signed(upstreamRelease('0.2.17'), [key]));
      final package = (await signedReleases.latest()).packageFor(HostSystem.linux)!;
      expect(package.trust, ReleaseTrust.signed);
      final kit = await store(HostSystem.linux).install(package);
      expect(kit.problem, isNull);
    });

    test('a file that does not match the signed sums is refused, even when GitHub agrees with it', () async {
      final release = signed(upstreamRelease('0.2.17'), [key]);
      release.files['prx-linux-v0.2.17.tar.gz'] = tarGzOf({'libs/libkernel.prx': filler('evil')});
      ours.releases.add(release);
      final package = (await signedReleases.latest()).packageFor(HostSystem.linux)!;
      expect((await failure(store(HostSystem.linux).install(package))).kind, ToolkitFailureKind.checksum);
    });

    test('a signature by another key is refused before the files are downloaded', () async {
      ours.releases.add(signed(upstreamRelease('0.2.17'), [TestReleaseKey('stranger')]));
      final package = (await signedReleases.latest()).packageFor(HostSystem.linux)!;
      final refused = await failure(store(HostSystem.linux).install(package));
      expect(refused.kind, ToolkitFailureKind.signature);
      expect(ours.downloads.where((path) => !path.contains('SHA256SUMS')), isEmpty);
    });

    test('an unsigned release after signing began is refused; an older one only when the user agrees', () async {
      ours.releases.addAll([upstreamRelease('0.2.17'), upstreamRelease('0.2.15')]);
      final all = await signedReleases.all();
      final newer = all.firstWhere((release) => release.version == '0.2.17').packageFor(HostSystem.linux)!;
      expect(newer.trust, ReleaseTrust.unsignedRefused);
      expect((await failure(store(HostSystem.linux).install(newer))).kind, ToolkitFailureKind.signature);
      final older = all.firstWhere((release) => release.version == '0.2.15').packageFor(HostSystem.linux)!;
      expect(older.trust, ReleaseTrust.unsignedOlder);
      expect((await failure(store(HostSystem.linux).install(older))).kind, ToolkitFailureKind.unsigned);
      expect(ours.downloads, isEmpty);
      expect((await store(HostSystem.linux).install(older, allowUnsigned: true)).problem, isNull);
    });

    test('upstream releases are not signed and stay on GitHub checksums', () async {
      github.releases.add(upstreamRelease('0.1.3'));
      expect((await releases.latest()).packageFor(HostSystem.linux)!.trust, isNull);
    });
  });

  group('unpacking safely', () {
    late String outside;
    late String destination;

    setUp(() {
      outside = p.join(temp.path, 'outside');
      destination = p.join(temp.path, 'box', 'unpacked');
    });

    Future<ToolkitFailure> unpack(String name, List<int> bytes) async {
      final archive = p.join(temp.path, name);
      File(archive).writeAsBytesSync(bytes);
      return failure(SafeUnpack.unpack(archive, destination));
    }

    test('names climbing out with .. are refused, in zip and tar.gz', () async {
      for (final (name, bytes) in [
        (
          'a.zip',
          zipOf({
            'libs/a.prx': [1],
            '../outside/evil.prx': [2],
          }),
        ),
        (
          'b.tar.gz',
          tarGzOf({
            'libs/a.prx': [1],
            'libs/../../outside/evil.prx': [2],
          }),
        ),
        (
          'c.zip',
          zipOf({
            r'libs\..\..\outside\evil.prx': [2],
          }),
        ),
      ]) {
        final error = await unpack(name, bytes);
        expect(error.kind, ToolkitFailureKind.unsafeArchive, reason: name);
        expect(File(p.join(outside, 'evil.prx')).existsSync(), isFalse, reason: name);
        expect(File(p.join(temp.path, 'box', 'outside', 'evil.prx')).existsSync(), isFalse, reason: name);
      }
    });

    test('absolute names and drive letters are refused', () {
      for (final name in ['/etc/passwd', r'C:\Windows\evil.dll', 'C:evil', r'\\server\share\x', 'a/b:stream']) {
        expect(
          () => SafeUnpack.safeName(name),
          throwsA(isA<ToolkitFailure>().having((error) => error.kind, 'kind', ToolkitFailureKind.unsafeArchive)),
          reason: name,
        );
      }
      expect(SafeUnpack.safeName('./libs//a.prx'), ['libs', 'a.prx']);
      expect(SafeUnpack.safeName('libs/'), ['libs']);
      expect(SafeUnpack.safeName('./'), isNull);
    });

    test('a link leading out of the folder is refused, in tar.gz and zip', () async {
      Directory(outside).createSync(recursive: true);
      for (final (name, bytes) in [
        (
          'a.tar.gz',
          tarGzOf(
            {
              'libs/a.prx': [1],
            },
            links: {'libs/escape': '../../../outside'},
          ),
        ),
        (
          'b.tar.gz',
          tarGzOf(
            {
              'libs/a.prx': [1],
            },
            links: {'libs/abs': '/etc'},
          ),
        ),
        (
          'c.zip',
          zipOf(
            {
              'libs/a.prx': [1],
            },
            links: {'libs/escape': '../../outside'},
          ),
        ),
      ]) {
        if (Directory(destination).existsSync()) Directory(destination).deleteSync(recursive: true);
        final error = await unpack(name, bytes);
        expect(error.kind, ToolkitFailureKind.unsafeArchive, reason: name);
        expect(
          FileSystemEntity.typeSync(p.join(destination, 'libs', 'escape'), followLinks: false),
          FileSystemEntityType.notFound,
          reason: name,
        );
      }
    });

    test('a link that stays inside is made after the files', () async {
      final archive = p.join(temp.path, 'ok.tar.gz');
      File(archive).writeAsBytesSync(
        tarGzOf(
          {
            'libs/libkernel.prx': [7, 7],
          },
          links: {'libs/libkernel_sys.prx': 'libkernel.prx'},
        ),
      );
      await SafeUnpack.unpack(archive, destination);
      expect(File(p.join(destination, 'libs', 'libkernel.prx')).readAsBytesSync(), [7, 7]);
      if (!Platform.isWindows) {
        expect(Link(p.join(destination, 'libs', 'libkernel_sys.prx')).targetSync(), 'libkernel.prx');
      }
      expect(File('$destination.tar').existsSync(), isFalse);
    });
  });

  group('store', () {
    Future<Toolkit> installVersion(ToolkitStore toolkits, String version) async {
      github.releases.insert(0, upstreamRelease(version));
      return toolkits.install((await releases.latest()).packageFor(toolkits.system)!);
    }

    test('several versions are kept, newest first; unused ones are deleted', () async {
      final toolkits = store(HostSystem.linux);
      for (final version in ['0.1.0', '0.1.2', '0.1.10', '0.1.3']) {
        await installVersion(toolkits, version);
      }
      Directory(p.join(toolkits.root, '.staging-0.1.11')).createSync(recursive: true);
      Directory(p.join(toolkits.root, 'broken')).createSync(recursive: true);
      expect(toolkits.installed().map((toolkit) => p.basename(toolkit.root)), ['0.1.10', '0.1.3', '0.1.2', '0.1.0']);
      expect(toolkits.find('0.1.2')?.version, 'upstream-v0.1.2');
      expect(toolkits.find('9.9.9'), isNull);

      // The two newest stay, and 0.1.0 because an installed game was made with it.
      final removed = toolkits.removeUnused(keep: {'upstream-v0.1.0'});
      expect(removed, ['0.1.2']);
      expect(toolkits.installed().map((toolkit) => p.basename(toolkit.root)), ['0.1.10', '0.1.3', '0.1.0']);
      expect(Directory(p.join(toolkits.root, '.staging-0.1.11')).existsSync(), isFalse);

      toolkits.remove('0.1.3');
      toolkits.remove('../outside');
      expect(toolkits.installed().map((toolkit) => p.basename(toolkit.root)), ['0.1.10', '0.1.0']);
      expect(toolkits.removeUnused(keep: {}, keepNewest: 0), ['0.1.10', '0.1.0']);
      expect(toolkits.installed(), isEmpty);
    });

    test('installing a version again replaces it', () async {
      final toolkits = store(HostSystem.linux);
      final first = await installVersion(toolkits, '0.1.3');
      File(p.join(first.libraries, 'stale.prx')).writeAsStringSync('old');
      final second = await toolkits.install((await releases.latest()).packageFor(HostSystem.linux)!);
      expect(second.root, first.root);
      expect(File(p.join(second.libraries, 'stale.prx')).existsSync(), isFalse);
    });

    test('the upstream version is read back from version.txt', () {
      expect(ToolkitStore.upstreamVersion('upstream-v0.1.3'), '0.1.3');
      expect(ToolkitStore.upstreamVersion('toolkit-1'), isNull);
      expect(ToolkitStore.versionText('0.1.3'), 'upstream-v0.1.3');
    });
  });

  group('redirects', () {
    test('a download asked for over https is never sent on to plain http', () {
      final from = Uri.parse('https://github.com/AnyTogether/anyps5-retro-host/releases/download/v1.0.0/SHA256SUMS');
      expect(
        AssetDownload.redirected(from, 'https://release-assets.githubusercontent.com/x?sig=1'),
        Uri.parse('https://release-assets.githubusercontent.com/x?sig=1'),
      );
      expect(AssetDownload.redirected(from, '/other'), Uri.parse('https://github.com/other'));
      for (final location in ['http://release-assets.githubusercontent.com/x', 'ftp://example.org/x']) {
        expect(
          () => AssetDownload.redirected(from, location),
          throwsA(isA<ToolkitFailure>().having((failure) => failure.kind, 'kind', ToolkitFailureKind.network)),
          reason: location,
        );
      }
    });

    test('a plain http address may still redirect within http, as the fake GitHub does', () {
      final from = Uri.parse('http://127.0.0.1:8080/download/v1/a.zip');
      expect(AssetDownload.redirected(from, '/blob/v1/a.zip'), Uri.parse('http://127.0.0.1:8080/blob/v1/a.zip'));
    });
  });
}
