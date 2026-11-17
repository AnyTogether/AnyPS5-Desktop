#!/bin/sh
# Signs the files of an AnyPS5 Desktop release with the AnyPS5 release key, as AnyPS5-ARM's
# releases are (docs/dev/SIGNED_UPDATES.md there), so that the launcher's update check accepts it:
#
#     packaging/sign-release.sh [-k <private key>]... [-o <folder>] <file>...
#
# Run on the release Mac once the Windows and Linux builds are collected in one folder; writes
# SHA256SUMS and SHA256SUMS.sig beside the first file (or in -o's folder; -k as sign.sh takes
# it). Attach both to the release with the files. Uses AnyPS5-ARM's tools/release/sign.sh:
# ANYPS5_ARM names that checkout (default: the AnyPS5-ARM checkout beside this one, ../AnyPS5).
# Fails when the keys built into this launcher (lib/core/release_keys.dart) are not the release
# keys.
#
# Signs nothing unless every file passes tool/check_release_build.dart's `files` check first: a
# launcher test build may run an unchecked PS1 host and must never reach the updater (docs/AnyPS5
# Desktop - Emulator Host Client.md "What keeps a test build from being published"). The check
# reads the AOT snapshot out of the Windows zip, the Linux .tar.gz, the .deb and the AppImage,
# reads every file the Windows installer installs, and refuses any other file and any it cannot
# read. It runs with the dart of Flutter, after `flutter pub get` in this checkout.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
arm="${ANYPS5_ARM:-$here/../AnyPS5}"
usage() { echo "usage: $0 [-k <private key>]... [-o <folder>] <file>..." >&2; exit 2; }
[ -x "$arm/tools/release/sign.sh" ] || { echo "no AnyPS5-ARM checkout at $arm (set ANYPS5_ARM)" >&2; exit 1; }
command -v dart >/dev/null || { echo "no dart on PATH: the files are checked with Flutter's dart" >&2; exit 1; }
[ -f "$here/.dart_tool/package_config.json" ] || { echo "run flutter pub get in $here first" >&2; exit 1; }

check_files() {
    while getopts k:o: option; do
        case "$option" in
            k|o) ;;
            *) usage ;;
        esac
    done
    shift $((OPTIND - 1))
    [ $# -gt 0 ] || usage
    dart run --packages="$here/.dart_tool/package_config.json" "$here/tool/check_release_build.dart" files "$@"
}

check_files "$@"
"$arm/tools/release/embed_keys.sh" --check "$here"
"$arm/tools/release/sign.sh" "$@"
