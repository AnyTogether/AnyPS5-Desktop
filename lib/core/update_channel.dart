import 'toolkit_download.dart';

/// Settings › About › Update Channel, as the macOS launcher's (Updates.swift): Stable follows the
/// releases, Nightly the newest build including pre-releases. Nightly builds of AnyPS5-ARM are
/// tagged `v<next release>-arm-nightly.<YYYYMMDD>.<n>` and this launcher's own
/// `v<next release>-nightly.<YYYYMMDD>.<n>` (.github/workflows/nightly.yml), the next release
/// being the last one with its last number raised and n counting the day's builds from 1, so that
/// they sort after the release before them and before the release they lead to.
enum UpdateChannel {
  stable,
  nightly;

  /// The channel kept in the preferences (null or anything unknown is Stable).
  static UpdateChannel of(String? saved) => saved == nightly.name ? nightly : stable;

  /// What the preferences keep: nothing for Stable.
  String? get saved => this == nightly ? name : null;
}

/// A release tag or version in the order releases come out (Updates.Version on the Mac):
/// "v0.2.16-arm", "0.2.16-arm-766-gee1fab911" (git describe between releases),
/// "v0.2.17-arm-nightly.20261025.1", and git describe past a nightly tag.
///
/// 0.2.16 < 0.2.16 + 766 commits < 0.2.17-nightly.20261025.1 < 0.2.17-nightly.20261025.2 <
/// 0.2.17-nightly.20261026.1 < 0.2.17.
class ReleaseVersion implements Comparable<ReleaseVersion> {
  const ReleaseVersion._(this.numbers, this.nightly, this.build);

  /// The version in [text]; null for a text that is no version.
  static ReleaseVersion? parse(String text) {
    final bare = text.startsWith('v') ? text.substring(1) : text;
    final head = RegExp(r'^[0-9.]*').firstMatch(bare)!.group(0)!;
    final fields = head.split('.');
    final numbers = [for (final field in fields) ?int.tryParse(field)];
    if (head.isEmpty || numbers.length != fields.length) return null;
    while (numbers.length < 3) {
      numbers.add(0);
    }
    final parts = bare.split('-');
    ({int day, int count})? nightly;
    final part = parts.where((part) => part.startsWith('nightly.')).firstOrNull;
    if (part != null) {
      final pieces = part.substring('nightly.'.length).split('.');
      if (pieces.isEmpty || pieces.length > 2 || pieces[0].length != 8) return null;
      final day = int.tryParse(pieces[0]);
      final count = pieces.length == 2 ? int.tryParse(pieces[1]) : 0;
      if (day == null || count == null) return null;
      nightly = (day: day, count: count);
    }
    // git describe appends -<commits since the tag>-g<hash>.
    final build = parts.length >= 3 && parts.last.startsWith('g') ? int.tryParse(parts[parts.length - 2]) ?? 0 : 0;
    return ReleaseVersion._(List.unmodifiable(numbers), nightly, build);
  }

  /// The release number, at least three parts.
  final List<int> numbers;

  /// A nightly build of [numbers] (before it is released): its day (YYYYMMDD) and its count
  /// that day; null for the release itself.
  final ({int day, int count})? nightly;

  /// Commits past the tag (git describe).
  final int build;

  bool get isNightly => nightly != null;

  @override
  int compareTo(ReleaseVersion other) {
    for (var index = 0; index < numbers.length || index < other.numbers.length; index++) {
      final a = index < numbers.length ? numbers[index] : 0;
      final b = index < other.numbers.length ? other.numbers[index] : 0;
      if (a != b) return a.compareTo(b);
    }
    final (x, y) = (nightly, other.nightly);
    if (x == null && y != null) return 1;
    if (x != null && y == null) return -1;
    if (x != null && y != null && x != y) return x.day != y.day ? x.day.compareTo(y.day) : x.count.compareTo(y.count);
    return build.compareTo(other.build);
  }

  bool operator <(ReleaseVersion other) => compareTo(other) < 0;
  bool operator >(ReleaseVersion other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) => other is ReleaseVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(Object.hashAll(numbers), nightly, build);

  /// The release number, a nightly's part after it: 0.2.17 or 0.2.17-nightly.20261025.1.
  @override
  String toString() => numbers.join('.') + (nightly == null ? '' : '-nightly.${nightly!.day}.${nightly!.count}');
}

/// What a channel offers of a repository's releases.
abstract final class ChannelReleases {
  /// Whether [tag] is past [current]: a development build is past its own tag but before the
  /// next release, a nightly before the release it leads to, so going back to Stable never offers
  /// an older release. A tag or version that cannot be read is never newer.
  static bool isNewer(String tag, String current) {
    final offered = ReleaseVersion.parse(tag), running = ReleaseVersion.parse(current);
    return offered != null && running != null && running < offered;
  }

  /// A nightly [current] on Stable, with nothing newer on offer: it stays as it is until a newer
  /// release comes out, as on the Mac.
  static bool stays(UpdateChannel channel, String current) =>
      channel == UpdateChannel.stable && (ReleaseVersion.parse(current)?.isNightly ?? false);

  /// The releases [channel] offers, newest first: pre-releases only on Nightly, tags that are no
  /// version left out; the later published first when two tie.
  static List<UpstreamRelease> offered(List<UpstreamRelease> releases, UpdateChannel channel) {
    final kept = [
      for (final release in releases)
        if ((channel == UpdateChannel.nightly || !release.prerelease) && ReleaseVersion.parse(release.tag) != null)
          release,
    ];
    final epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    return kept..sort((a, b) {
      final order = ReleaseVersion.parse(b.tag)!.compareTo(ReleaseVersion.parse(a.tag)!);
      return order != 0 ? order : (b.published ?? epoch).compareTo(a.published ?? epoch);
    });
  }

  /// The newest release [channel] offers, or null.
  static UpstreamRelease? newest(List<UpstreamRelease> releases, UpdateChannel channel) =>
      offered(releases, channel).firstOrNull;
}
