import 'dart:io';

import 'package:anyps5_desktop/core/release_signing.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_release.dart';
import 'package:path/path.dart' as p;

import 'fake_github.dart';
import 'signing.dart';

/// A host release as the host repository publishes it, recorded in
/// test/fixtures/retro_host_release: each system's zip and `.files` and the source archive, packed
/// from small stand-in files by that repository's tools/package_release.py, SHA256SUMS from its
/// `--sums`, and SHA256SUMS.sig written by AnyPS5-ARM's tools/release/sign.sh with the throwaway
/// key beside them (test-release-signing.key), which no launcher trusts.
const retroHostFixture = 'test/fixtures/retro_host_release';

/// The fixture key's public half, release-signing.pub's format: the only key its release passes.
List<ReleaseKey> retroHostFixtureKeys() =>
    ReleaseSigning.keysFrom(File(p.join(retroHostFixture, 'test-release-signing.pub')).readAsStringSync());

/// The fixture's throwaway key itself, to sign changed copies of its release in tests.
TestReleaseKey retroHostFixtureKey() => TestReleaseKey.fromPem(
  File(p.join(retroHostFixture, 'test-release-signing.key')).readAsStringSync(),
  name: 'retro-host-test',
);

/// The release's files by name, as published: those SHA256SUMS lists, SHA256SUMS and its signature.
Map<String, List<int>> retroHostFixtureFiles() {
  final sums = File(p.join(retroHostFixture, ReleaseSigning.sumsName)).readAsBytesSync();
  return {
    for (final name in ReleaseSigning.parseSums(sums).keys)
      name: File(p.join(retroHostFixture, name)).readAsBytesSync(),
    ReleaseSigning.sumsName: sums,
    ReleaseSigning.signatureName: File(p.join(retroHostFixture, ReleaseSigning.signatureName)).readAsBytesSync(),
  };
}

/// The release on a fake GitHub, tagged as the host repository tags it.
FakeRelease retroHostFixtureRelease({String tag = 'v1.0.0'}) => FakeRelease(tag, retroHostFixtureFiles());

/// The release unpacked into [into] as a download leaves it, for [system] (this one by default).
Future<void> installRetroHostFixture(Directory into, {RetroHostSystem? system}) =>
    RetroHostRelease.install(Directory(retroHostFixture), into, keys: retroHostFixtureKeys(), system: system);
