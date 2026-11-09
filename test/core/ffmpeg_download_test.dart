import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/ffmpeg_download.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/replay_buffer.dart' show ProcessRunner;
import 'package:anyps5_desktop/core/toolkit_download.dart';
import 'package:anyps5_desktop/core/update_channel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_github.dart';
import '../support/fixtures.dart';
import '../support/signing.dart';

Map<String, List<int>> _contents(String executable) => {
  executable: filler('ffmpeg', 9000),
  'LICENSE.txt': utf8.encode('GNU GENERAL PUBLIC LICENSE\n'),
  'SOURCE.txt': utf8.encode('https://github.com/BtbN/FFmpeg-Builds\n'),
};

FakeRelease _ffmpegRelease() => FakeRelease(FfmpegBuild.tag, {
  FfmpegBuild.assetName(HostSystem.linux): tarGzOf(_contents('ffmpeg')),
  FfmpegBuild.assetName(HostSystem.windows): zipOf(_contents('ffmpeg.exe')),
}, prerelease: true);

void main() {
  final key = TestReleaseKey('release');
  late FakeGitHub github;
  late Directory temp;
  late GitHubReleases releases;
  late List<List<String>> ran;

  setUp(() async {
    github = await FakeGitHub.start(repository: FfmpegBuild.repository);
    temp = temporaryFolder('ffmpeg');
    releases = GitHubReleases(api: github.api, repository: FfmpegBuild.repository, signingKeys: [key.key]);
    ran = [];
  });

  tearDown(() async {
    await github.close();
    temp.deleteSync(recursive: true);
  });

  ProcessRunner works(int exitCode, [String stderr = '']) => (executable, arguments) async {
    ran.add([executable, ...arguments]);
    return ProcessResult(1, exitCode, '', stderr);
  };

  FfmpegStore store({HostSystem system = HostSystem.linux, ProcessRunner? run}) =>
      FfmpegStore(p.join(temp.path, 'FFmpeg'), system: system, run: run ?? works(0));

  Future<ToolkitFailure> failure(Future<Object?> future) async {
    try {
      await future;
    } on ToolkitFailure catch (error) {
      return error;
    }
    fail('expected a ToolkitFailure');
  }

  Future<void> until(bool Function() condition) async {
    for (var i = 0; i < 400 && !condition(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(condition(), isTrue);
  }

  Future<UpstreamRelease?> pinned() => releases.byTag(FfmpegBuild.tag);

  test('a signed release is checked, unpacked and put in place, executable', () async {
    github.releases.add(signed(_ffmpegRelease(), [key]));
    final progress = <ToolkitProgress>[];
    final ffmpeg = store();
    final path = await ffmpeg.install(await pinned(), onProgress: progress.add);
    expect(path, p.join(temp.path, 'FFmpeg', FfmpegBuild.tag, 'ffmpeg'));
    expect(File(path).readAsBytesSync(), filler('ffmpeg', 9000));
    expect(File(p.join(p.dirname(path), 'LICENSE.txt')).existsSync(), isTrue);
    expect(File(p.join(p.dirname(path), 'SOURCE.txt')).existsSync(), isTrue);
    if (!Platform.isWindows) expect(File(path).statSync().mode & 0x40, isNonZero);
    expect(ffmpeg.installed(), path);
    // It is tried while still being laid out, before it can be found by anything.
    expect(p.basename(ran.single.first), 'ffmpeg');
    expect(ran.single.skip(1), ['-hide_banner', '-version']);
    expect(progress.last.phase, ToolkitPhase.finish);
    expect(
      File(p.join(temp.path, 'FFmpeg', '.downloads', FfmpegBuild.assetName(HostSystem.linux))).existsSync(),
      isFalse,
    );
  });

  test('Windows takes its zip and its ffmpeg.exe', () async {
    github.releases.add(signed(_ffmpegRelease(), [key]));
    final path = await store(system: HostSystem.windows).install(await pinned());
    expect(p.basename(path), 'ffmpeg.exe');
    expect(github.downloads.where((url) => url.endsWith('.zip')), hasLength(1));
    expect(github.downloads.where((url) => url.endsWith('.tar.gz')), isEmpty);
  });

  test('no release yet: not available, nothing to download', () async {
    final error = await failure(store().install(await pinned()));
    expect(error.kind, ToolkitFailureKind.notAvailable);
    expect(github.downloads, isEmpty);
    expect(store().installed(), isNull);
  });

  test('a release not signed yet is not available and nothing of it is downloaded', () async {
    github.releases.add(_ffmpegRelease());
    final error = await failure(store().install(await pinned()));
    expect(error.kind, ToolkitFailureKind.notAvailable);
    expect(github.downloads, isEmpty);
  });

  test('a release without this system\'s file is not available', () async {
    final release = _ffmpegRelease()..files.remove(FfmpegBuild.assetName(HostSystem.linux));
    github.releases.add(signed(release, [key]));
    expect((await failure(store().install(await pinned()))).kind, ToolkitFailureKind.notAvailable);
  });

  test('a signature by another key is refused before the file is downloaded', () async {
    github.releases.add(signed(_ffmpegRelease(), [TestReleaseKey('stranger')]));
    final error = await failure(store().install(await pinned()));
    expect(error.kind, ToolkitFailureKind.signature);
    expect(github.downloads.where((path) => !path.contains('SHA256SUMS')), isEmpty);
    expect(store().installed(), isNull);
  });

  test('a file that does not match the signed sums is refused, even when GitHub agrees with it', () async {
    final release = signed(_ffmpegRelease(), [key]);
    release.files[FfmpegBuild.assetName(HostSystem.linux)] = tarGzOf({'ffmpeg': filler('evil', 9000)});
    github.releases.add(release);
    final error = await failure(store().install(await pinned()));
    expect(error.kind, ToolkitFailureKind.checksum);
    expect(store().installed(), isNull);
  });

  test('stopping the download leaves nothing installed and keeps what came', () async {
    final release = signed(_ffmpegRelease(), [key]);
    final name = FfmpegBuild.assetName(HostSystem.linux);
    github.releases.add(release);
    github.holdAfter[name] = 200;
    final cancel = DownloadCancel();
    final install = failure(store().install(await pinned(), cancel: cancel));
    final part = File(p.join(temp.path, 'FFmpeg', '.downloads', '$name.part'));
    await until(() => part.existsSync() && part.lengthSync() >= 200);
    cancel.cancel();
    github.release();
    expect((await install).kind, ToolkitFailureKind.cancelled);
    expect(store().installed(), isNull);
    expect(part.existsSync(), isTrue);
  });

  test('a build that cannot start here says so and is not kept', () async {
    github.releases.add(signed(_ffmpegRelease(), [key]));
    final error = await failure(store(run: works(1, "version `GLIBC_2.34' not found")).install(await pinned()));
    expect(error.kind, ToolkitFailureKind.badLayout);
    expect(error.message, contains('GLIBC_2.34'));
    expect(store().installed(), isNull);
  });

  test('an unsafe name in the archive is refused', () async {
    final release = signed(
      FakeRelease(FfmpegBuild.tag, {
        FfmpegBuild.assetName(HostSystem.linux): tarGzOf({'../ffmpeg': filler('evil')}),
      }, prerelease: true),
      [key],
    );
    github.releases.add(release);
    expect((await failure(store().install(await pinned()))).kind, ToolkitFailureKind.unsafeArchive);
  });

  test('neither update channel takes the ffmpeg tag for a launcher version', () {
    const ffmpeg = UpstreamRelease(tag: FfmpegBuild.tag, assets: [], prerelease: true);
    expect(ChannelReleases.offered([ffmpeg], UpdateChannel.stable), isEmpty);
    expect(ChannelReleases.offered([ffmpeg], UpdateChannel.nightly), isEmpty);
    expect(ChannelReleases.newest([ffmpeg], UpdateChannel.nightly), isNull);
  });

  test('the pin in the repository names the tag the launcher asks for', () {
    final pinned = File('packaging/ffmpeg/pinned.env').readAsLinesSync();
    expect(pinned, contains('FFMPEG_TAG=${FfmpegBuild.tag}'));
    expect(FfmpegBuild.tag, contains(FfmpegBuild.version));
  });

  test('the store finds nothing in an empty folder, and prefers only when told', () {
    final ffmpeg = store();
    expect(ffmpeg.installed(), isNull);
    expect(ffmpeg.preferred, isFalse);
    ffmpeg.prefer();
    expect(ffmpeg.preferred, isTrue);
  });
}
