#!/usr/bin/env bash
# Makes the archive the launcher downloads from the pinned BtbN/FFmpeg-Builds build
# (packaging/ffmpeg/pinned.env): checks its SHA-256, keeps ffmpeg alone with the licences and a
# link to the exact source, proves it works (check.sh) and packs it for the launcher.
#
#     prepare.sh <windows|linux> <output folder>
set -euo pipefail

system="$1"
out="$2"
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$here/pinned.env"

case "$system" in
  windows)
    asset="$WINDOWS_ASSET"
    sum="$WINDOWS_SHA256"
    executable=ffmpeg.exe
    archive=anyps5-ffmpeg-windows-x64.zip
    ;;
  linux)
    asset="$LINUX_ASSET"
    sum="$LINUX_SHA256"
    executable=ffmpeg
    archive=anyps5-ffmpeg-linux-x64.tar.gz
    ;;
  *)
    echo "usage: prepare.sh <windows|linux> <output>" >&2
    exit 2
    ;;
esac

work="$(mktemp -d)"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
# 7z and ffmpeg.exe take Windows paths.
if command -v cygpath >/dev/null; then
  work="$(cygpath -m "$work")"
  out="$(cygpath -m "$out")"
fi
stage="$work/stage"
mkdir -p "$stage"

curl -fsSL --retry 5 -o "$work/$asset" "https://github.com/BtbN/FFmpeg-Builds/releases/download/$BTBN_RELEASE/$asset"
echo "$sum  $work/$asset" | sha256sum -c -
curl -fsSL --retry 5 -o "$stage/LICENSE.FFmpeg-Builds.txt" \
  "https://raw.githubusercontent.com/BtbN/FFmpeg-Builds/$BTBN_COMMIT/LICENSE"
echo "$BTBN_LICENSE_SHA256  $stage/LICENSE.FFmpeg-Builds.txt" | sha256sum -c -

unpack="$work/unpack"
mkdir -p "$unpack"
case "$system" in
  windows) 7z x -y -o"$unpack" "$work/$asset" >/dev/null ;;
  linux) tar -xJf "$work/$asset" -C "$unpack" ;;
esac
top="$(find "$unpack" -mindepth 1 -maxdepth 1 -type d | head -n 1)"

cp "$top/bin/$executable" "$stage/$executable"
# BtbN copies FFmpeg's COPYING.GPLv3 here: this build's licence, in full.
cp "$top/LICENSE.txt" "$stage/LICENSE.txt"
cat >"$stage/SOURCE.txt" <<EOF
FFmpeg for AnyPS5 Desktop

This is FFmpeg $FFMPEG_DESCRIBE, built by BtbN/FFmpeg-Builds, unmodified. It is the ffmpeg executable
of $asset in their release $BTBN_RELEASE (sha256 $sum).

FFmpeg is licensed under the GNU General Public License, version 3 (this build is configured with
--enable-gpl --enable-version3): see LICENSE.txt, which is that licence. The build scripts are
under the licence in LICENSE.FFmpeg-Builds.txt.

The exact source:

    FFmpeg:  https://github.com/FFmpeg/FFmpeg/commit/$FFMPEG_COMMIT
    The build recipe and the libraries it links (each file in scripts.d names the exact version of one):
             https://github.com/BtbN/FFmpeg-Builds/tree/$BTBN_COMMIT
EOF

bash "$here/check.sh" "$stage/$executable" "$system"

if [ "$system" = linux ]; then
  # Runs on the oldest system the launcher is built for: the run above happened on Ubuntu 22.04
  # (glibc 2.35), and it must not ask for newer.
  newest="$(objdump -T "$stage/$executable" | grep -o 'GLIBC_[0-9.]*' | sed 's/GLIBC_//' | sort -V | tail -n 1)"
  echo "newest glibc it asks for: $newest"
  highest="$(printf '%s\n2.35\n' "$newest" | sort -V | tail -n 1)"
  [ "$highest" = "2.35" ] || {
    echo "::error::it needs glibc $newest, newer than Ubuntu 22.04's 2.35"
    exit 1
  }
  ldd "$stage/$executable"
  if ldd "$stage/$executable" | grep -q 'not found'; then
    echo "::error::it needs a library this system does not have"
    exit 1
  fi
fi

case "$system" in
  windows)
    (cd "$stage" && 7z a -tzip -mx=9 "$out/$archive" "$executable" LICENSE.txt LICENSE.FFmpeg-Builds.txt SOURCE.txt >/dev/null)
    ;;
  linux)
    GZIP=-9 tar -C "$stage" -czf "$out/$archive" "$executable" LICENSE.txt LICENSE.FFmpeg-Builds.txt SOURCE.txt
    ;;
esac
ls -l "$out/$archive"
sha256sum "$out/$archive"
