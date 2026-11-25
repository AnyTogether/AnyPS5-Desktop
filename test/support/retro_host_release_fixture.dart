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

/// A host release that ships LRPS2 in a package of its own, recorded in
/// test/fixtures/retro_host_release_lrps2: for each system the host package
/// (`anyps5-retro-host-1.1.0-<system>.zip` and `.files`, the host and SwanStation) and the LRPS2
/// package (`…-<system>-lrps2.zip` and `.files`, `pcsx2_libretro`, SOURCE-lrps2.txt and its
/// licence), each packed from small stand-in files by the host repository's
/// tools/package_release.py at its `ps2-release` branch (4599660, host PR #22) and passing its
/// `--check`, SHA256SUMS from its `--sums`, and SHA256SUMS.sig signed by [retroHostFixtureKey] as
/// the release in [retroHostFixture] is. It has no source archive.
const retroHostPs2Fixture = 'test/fixtures/retro_host_release_lrps2';

/// The version the release with LRPS2 was packed as: adding a core is a minor version.
const retroHostPs2FixtureVersion = '1.1.0';

/// The fixture key's public half, release-signing.pub's format: the only key its release passes.
List<ReleaseKey> retroHostFixtureKeys() =>
    ReleaseSigning.keysFrom(File(p.join(retroHostFixture, 'test-release-signing.pub')).readAsStringSync());

/// The fixture's throwaway key itself, to sign changed copies of its release in tests.
TestReleaseKey retroHostFixtureKey() => TestReleaseKey.fromPem(
  File(p.join(retroHostFixture, 'test-release-signing.key')).readAsStringSync(),
  name: 'retro-host-test',
);

/// The release's files by name, as published: those SHA256SUMS lists, SHA256SUMS and its signature;
/// with [ps2], the release with the LRPS2 package ([retroHostPs2Fixture]). With another [version],
/// the same files named for that version and signed again by the fixture key, as the host
/// repository would publish a newer release of them.
Map<String, List<int>> retroHostFixtureFiles({String? version, bool ps2 = false}) {
  final folder = ps2 ? retroHostPs2Fixture : retroHostFixture;
  final recorded = ps2 ? retroHostPs2FixtureVersion : retroHostFixtureVersion;
  final sums = File(p.join(folder, ReleaseSigning.sumsName)).readAsBytesSync();
  final files = {
    for (final name in ReleaseSigning.parseSums(sums).keys) name: File(p.join(folder, name)).readAsBytesSync(),
  };
  if (version == null || version == recorded) {
    return {
      ...files,
      ReleaseSigning.sumsName: sums,
      ReleaseSigning.signatureName: File(p.join(folder, ReleaseSigning.signatureName)).readAsBytesSync(),
    };
  }
  final renamed = {
    for (final MapEntry(key: name, value: bytes) in files.entries)
      name.replaceFirst('anyps5-retro-host-$recorded-', 'anyps5-retro-host-$version-'): bytes,
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

/// The release on a fake GitHub under [tag] (its recorded version by default), as the host
/// repository tags it: its files signed as the tag's version, or as [signedAs] for a release
/// published under a tag it was not signed for; with [ps2], the release with the LRPS2 package.
FakeRelease retroHostFixtureRelease({String? tag, String? signedAs, bool ps2 = false}) {
  final named = tag ?? 'v${ps2 ? retroHostPs2FixtureVersion : retroHostFixtureVersion}';
  return FakeRelease(named, retroHostFixtureFiles(version: signedAs ?? named.substring(1), ps2: ps2));
}

/// The release unpacked into [into] as a download leaves it, for [system] (this one by default):
/// [retroHostFixture], or with [ps2] the release with the LRPS2 package ([retroHostPs2Fixture]),
/// that package added beside the host too unless [addPs2] is false.
Future<void> installRetroHostFixture(Directory into, {RetroHostSystem? system, bool ps2 = false, bool? addPs2}) =>
    RetroHostRelease.install(
      Directory(ps2 ? retroHostPs2Fixture : retroHostFixture),
      into,
      tag: 'v${ps2 ? retroHostPs2FixtureVersion : retroHostFixtureVersion}',
      keys: retroHostFixtureKeys(),
      system: system,
      cores: {if (addPs2 ?? ps2) RetroHostCorePackage.lrps2},
    );
