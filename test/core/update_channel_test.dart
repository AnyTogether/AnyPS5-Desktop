import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/toolkit_download.dart';
import 'package:anyps5_desktop/core/update_channel.dart';
import 'package:test/test.dart';

/// Settings › About › Update Channel, with the macOS launcher's order of versions
/// (Updates.Version): a nightly sorts after the release before it and before the release it
/// leads to, so Stable never offers going back.
void main() {
  ReleaseVersion v(String text) => ReleaseVersion.parse(text)!;

  test('versions sort in the order releases come out, as on the Mac', () {
    final order = [
      'v0.2.16-arm',
      '0.2.16-arm-766-gee1fab911',
      'v0.2.17-arm-nightly.20261025.1',
      'v0.2.17-arm-nightly.20261025.2',
      'v0.2.17-arm-nightly.20261025.10',
      'v0.2.17-arm-nightly.20261026.1',
      '0.2.17-arm-nightly.20261026.1-3-gabc1234',
      'v0.2.17-arm',
      'v0.2.18-arm-nightly.20261027.1',
      'v0.3-arm',
    ];
    for (var index = 0; index + 1 < order.length; index++) {
      expect(v(order[index]) < v(order[index + 1]), isTrue, reason: '${order[index]} before ${order[index + 1]}');
      expect(v(order[index + 1]) > v(order[index]), isTrue);
    }
    expect(v('0.2'), v('0.2.0'));
    expect(v('v0.2.17-arm-nightly.20261025.1').toString(), '0.2.17-nightly.20261025.1');
    expect(v('v0.2.17-arm-nightly.20261025.1').isNightly, isTrue);
    expect(v('0.1.16').isNightly, isFalse);
  });

  test('what is no version is none', () {
    for (final text in [
      '',
      'latest',
      'v',
      'arm-0.2',
      'v0.2.x',
      'v0.2.17-arm-nightly.2026.1',
      'v0.2-nightly.20261025.x',
    ]) {
      expect(ReleaseVersion.parse(text), isNull, reason: text);
    }
  });

  test('Stable never offers going back: a nightly in use is newer than the release before it', () {
    expect(ChannelReleases.isNewer('v0.2.17-arm', '0.2.17-arm-nightly.20261025.1'), isTrue);
    expect(ChannelReleases.isNewer('v0.2.16-arm', '0.2.17-arm-nightly.20261025.1'), isFalse);
    expect(ChannelReleases.isNewer('v0.2.17-arm-nightly.20261025.2', '0.2.17-arm-nightly.20261025.1'), isTrue);
    expect(ChannelReleases.isNewer('v0.1.17', '0.1.16'), isTrue);
    expect(ChannelReleases.isNewer('v0.1.16', '0.1.16'), isFalse);
    expect(ChannelReleases.isNewer('nonsense', '0.1.16'), isFalse);
  });

  UpstreamRelease release(String tag, {bool prerelease = false, List<String> assets = const [], DateTime? published}) =>
      UpstreamRelease(
        tag: tag,
        prerelease: prerelease,
        published: published,
        assets: [
          for (final name in assets) ReleaseAsset(name: name, url: Uri.parse('https://example.invalid/$name'), size: 1),
        ],
      );

  test('pre-releases only on Nightly, in release order, not GitHub order', () {
    final releases = [
      release('v0.2.30-arm'),
      release('v0.2.31-arm-nightly.20261101.1', prerelease: true),
      release('v0.2.31-arm-nightly.20261031.2', prerelease: true),
      release('v0.2.29-arm'),
      release('not-a-version'),
    ];
    expect(ChannelReleases.offered(releases, UpdateChannel.stable).map((release) => release.tag), [
      'v0.2.30-arm',
      'v0.2.29-arm',
    ]);
    expect(ChannelReleases.offered(releases, UpdateChannel.nightly).map((release) => release.tag), [
      'v0.2.31-arm-nightly.20261101.1',
      'v0.2.31-arm-nightly.20261031.2',
      'v0.2.30-arm',
      'v0.2.29-arm',
    ]);
    // The release a nightly led to comes out: it wins over every nightly before it.
    releases.add(release('v0.2.31-arm'));
    expect(ChannelReleases.newest(releases, UpdateChannel.nightly)!.tag, 'v0.2.31-arm');
  });

  test("the engine picker's engine follows the channel", () {
    final releases = [
      release('v0.2.31-arm-nightly.20261101.1', prerelease: true, assets: ['AnyPS5-toolkit-windows-aaaaaaaaa.zip']),
      release('v0.2.30-arm', assets: ['AnyPS5-toolkit-windows-bbbbbbbbb.zip']),
    ];
    ArmToolkitPackage? on(UpdateChannel channel) =>
        ArmToolkitPackage.find(ChannelReleases.offered(releases, channel), HostSystem.windows);
    expect(on(UpdateChannel.stable)!.commit, 'bbbbbbbbb');
    expect(on(UpdateChannel.nightly)!.commit, 'aaaaaaaaa');
  });

  test("AnyPS5 Desktop's own nightly tags sort in the same order", () {
    final order = [
      'v0.1.20',
      'v0.1.21-nightly.20261109.1',
      'v0.1.21-nightly.20261109.2',
      'v0.1.21-nightly.20261109.10',
      'v0.1.21-nightly.20261110.1',
      'v0.1.21',
    ];
    for (var index = 1; index < order.length; index++) {
      expect(ChannelReleases.isNewer(order[index], order[index - 1]), isTrue, reason: order[index]);
      expect(ChannelReleases.isNewer(order[index - 1], order[index]), isFalse, reason: order[index]);
    }
    // The version the build calls itself is the tag without its v.
    expect(ChannelReleases.isNewer('v0.1.21-nightly.20261109.1', '0.1.21-nightly.20261109.1'), isFalse);
    expect(ReleaseVersion.parse('0.1.21-nightly.20261109.1')!.isNightly, isTrue);
  });

  test('a nightly in use on Stable stays until a newer release comes out', () {
    expect(ChannelReleases.stays(UpdateChannel.stable, '0.1.21-nightly.20261109.1'), isTrue);
    expect(ChannelReleases.stays(UpdateChannel.nightly, '0.1.21-nightly.20261109.1'), isFalse);
    expect(ChannelReleases.stays(UpdateChannel.stable, '0.1.20'), isFalse);
  });

  test('the channel is kept as nothing for Stable, "nightly" for Nightly', () {
    expect(UpdateChannel.of(null), UpdateChannel.stable);
    expect(UpdateChannel.of('beta'), UpdateChannel.stable);
    expect(UpdateChannel.of('nightly'), UpdateChannel.nightly);
    expect(UpdateChannel.stable.saved, isNull);
    expect(UpdateChannel.nightly.saved, 'nightly');
  });
}
