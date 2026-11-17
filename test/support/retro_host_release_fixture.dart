import 'dart:convert';
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

/// A host release with PS2, recorded in test/fixtures/retro_host_release_ps2: each system's zip and
/// `.files` packed from small stand-in files by the host repository's tools/package_release.py at
/// its `ps2-release` branch (4441cc2), which puts LRPS2 (`pcsx2_libretro`) beside the host and
/// SwanStation, SHA256SUMS from its `--sums`, and SHA256SUMS.sig signed by [retroHostFixtureKey]
/// as the release in [retroHostFixture] is. It has no source archive.
const retroHostPs2Fixture = 'test/fixtures/retro_host_release_ps2';

/// The fixture key's public half, release-signing.pub's format: the only key its release passes.
List<ReleaseKey> retroHostFixtureKeys() =>
    ReleaseSigning.keysFrom(File(p.join(retroHostFixture, 'test-release-signing.pub')).readAsStringSync());

/// The fixture's throwaway key itself, to sign changed copies of its release in tests.
TestReleaseKey retroHostFixtureKey() => TestReleaseKey.fromPem(
  File(p.join(retroHostFixture, 'test-release-signing.key')).readAsStringSync(),
  name: 'retro-host-test',
);

/// The release's files by name, as published: those SHA256SUMS lists, SHA256SUMS and its signature.
/// With another [version], the same files named for that version and signed again by the fixture
/// key, as the host repository would publish a newer release of them.
Map<String, List<int>> retroHostFixtureFiles({String version = retroHostFixtureVersion}) {
  final sums = File(p.join(retroHostFixture, ReleaseSigning.sumsName)).readAsBytesSync();
  final files = {
    for (final name in ReleaseSigning.parseSums(sums).keys)
      name: File(p.join(retroHostFixture, name)).readAsBytesSync(),
  };
  if (version == retroHostFixtureVersion) {
    return {
      ...files,
      ReleaseSigning.sumsName: sums,
      ReleaseSigning.signatureName: File(p.join(retroHostFixture, ReleaseSigning.signatureName)).readAsBytesSync(),
    };
  }
  final renamed = {
    for (final MapEntry(key: name, value: bytes) in files.entries)
      name.replaceFirst('anyps5-retro-host-$retroHostFixtureVersion-', 'anyps5-retro-host-$version-'): bytes,
  };
  final resigned = sumsOf(renamed);
  return {
    ...renamed,
    ReleaseSigning.sumsName: resigned,
    ReleaseSigning.signatureName: utf8.encode('${retroHostFixtureKey().signatureLine(resigned)}\n'),
  };
}

/// The version the recorded release was packed as.
const retroHostFixtureVersion = '1.0.0';

/// The release on a fake GitHub under [tag], as the host repository tags it: its files signed as
/// the tag's version, or as [signedAs] for a release published under a tag it was not signed for.
FakeRelease retroHostFixtureRelease({String tag = 'v$retroHostFixtureVersion', String? signedAs}) =>
    FakeRelease(tag, retroHostFixtureFiles(version: signedAs ?? tag.substring(1)));

/// The release unpacked into [into] as a download leaves it, for [system] (this one by default):
/// [retroHostFixture], or with [ps2] the release with LRPS2 ([retroHostPs2Fixture]).
Future<void> installRetroHostFixture(Directory into, {RetroHostSystem? system, bool ps2 = false}) =>
    RetroHostRelease.install(
      Directory(ps2 ? retroHostPs2Fixture : retroHostFixture),
      into,
      tag: 'v$retroHostFixtureVersion',
      keys: retroHostFixtureKeys(),
      system: system,
    );
