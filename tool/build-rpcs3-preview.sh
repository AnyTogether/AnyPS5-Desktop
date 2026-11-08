#!/usr/bin/env bash
set -euo pipefail

if [[ ${MSYSTEM:-} != CLANG64 || $# != 1 ]]; then
  echo 'Usage in a disposable MSYS2 CLANG64 install: bash tool/build-rpcs3-preview.sh NEW_OUTPUT_DIRECTORY' >&2
  exit 2
fi

patch_dir=$(cd "$(dirname "$0")/patches" && pwd)
mkdir -- "$1"
output=$(cd "$1" && pwd)
mkdir "$output/packages"

checkout() {
  local url=$1 revision=$2 directory=$3
  git init -q "$directory"
  git -C "$directory" config core.autocrlf false
  git -C "$directory" remote add origin "$url"
  git -C "$directory" fetch --depth 1 origin "$revision"
  git -C "$directory" checkout -q --detach FETCH_HEAD
  test "$(git -C "$directory" rev-parse HEAD)" = "$revision"
}

checkout https://github.com/WizzardSK/rpcs3-libretro.git 74b3fa37beb294418230b1f039bab4de97f18479 "$output/rpcs3"
checkout https://github.com/FFmpeg/FFmpeg.git f9db090b14c255a8f1c5f8f41a4c92b723228763 "$output/rpcs3/ffmpeg-src"
checkout https://github.com/abseil/abseil-cpp.git 76bb24329e8bf5f39704eb10d21b9a80befa7c81 "$output/abseil"
export ANYPS5_ABSL_SOURCE
ANYPS5_ABSL_SOURCE=$(cygpath -m "$output/abseil")

cd "$output/rpcs3"
sed 's/\r$//' "$patch_dir/rpcs3-libretro-frontend.patch" > "$output/frontend.patch"
git apply --check "$output/frontend.patch"
git apply "$output/frontend.patch"

sed \
  -e "s/git config --global --add safe.directory '\*'/git config --local core.longpaths true/" \
  -e 's/git clone --quiet --depth 1 -b release\/7.1 .* ffmpeg-src/test -f ffmpeg-src\/configure/' \
  -e 's/make -j"\$(nproc)"/make -j3/' \
  -e 's/    -Dprotobuf_FORCE_FETCH_DEPENDENCIES/    -DFETCHCONTENT_SOURCE_DIR_ABSL="$ANYPS5_ABSL_SOURCE" -Dprotobuf_FORCE_FETCH_DEPENDENCIES/' \
  -e 's/^ninja rpcs3_libretro$/ninja -j3 rpcs3_libretro/' \
  .ci/build-windows-clang-libretro.sh > build-anyps5-core.sh
if grep -Eq 'git config --global|git clone|\$\(nproc\)|^ninja rpcs3_libretro$' build-anyps5-core.sh; then
  echo 'Unexpected upstream build recipe.' >&2
  exit 1
fi
export KEEP_SYMBOLS=0
sh -ex build-anyps5-core.sh

cd artifacts
cmake -E tar cf "$(cygpath -m "$output/packages/rpcs3_libretro.dll.zip")" --format=zip rpcs3_libretro.dll
read -r archive_digest _ < <(sha256sum "$output/packages/rpcs3_libretro.dll.zip")
read -r library_digest _ < <(sha256sum rpcs3_libretro.dll)
printf '%s:%s\n' "$archive_digest" "$library_digest" > "$output/packages/ps3-core-digests.txt"
pacman -Q > "$output/msys2-packages.txt"
printf 'Package and digest pair: %s\n' "$(cygpath -w "$output/packages")"
