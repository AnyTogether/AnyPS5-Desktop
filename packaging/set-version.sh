#!/bin/sh
# Names a build after a version, for a build that is not the version in the repository (the
# nightly builds, .github/workflows/nightly.yml):
#
#     packaging/set-version.sh 0.1.21-nightly.20261109.1
#
# pubspec.yaml's version (the build number after the + stays, the packages take their file names
# from it) and lib/ui/together_model.dart's launcherVersion (what the launcher calls itself:
# the update check compares it with the release tags, and AnyTogether hears it).
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
[ $# -eq 1 ] || { echo "usage: $0 <version>" >&2; exit 2; }
version="$1"
case "$version" in
    '' | *[!0-9A-Za-z.-]* | -* | .*) echo "$version is no version" >&2; exit 1 ;;
esac
pubspec="$root/pubspec.yaml"
launcher="$root/lib/ui/together_model.dart"
# The patterns stop at what may follow: the build number, or a CRLF on a Windows checkout.
sed -E -i.bak "s/^version:[[:space:]]*[^+[:space:]]*/version: $version/" "$pubspec"
sed -E -i.bak "s/^const launcherVersion = '[^']*';/const launcherVersion = '$version';/" "$launcher"
rm -f "$pubspec.bak" "$launcher.bak"
grep -q "^version: $version\([+[:space:]]\|\$\)" "$pubspec" || { echo "pubspec.yaml's version was not set" >&2; exit 1; }
grep -q "^const launcherVersion = '$version';" "$launcher" || { echo "launcherVersion was not set" >&2; exit 1; }
echo "version $version"
