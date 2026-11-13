#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 1 ]]; then
  echo 'Usage: bash tool/build-rpcs3-preview.sh NEW_OUTPUT_DIRECTORY' >&2
  exit 2
fi

if [[ ${MSYSTEM:-} == CLANG64 ]]; then
  platform=windows
elif [[ $(uname -s) == Linux && $(uname -m) == x86_64 && -f /opt/llvm/lib/cmake/llvm/LLVMConfig.cmake ]]; then
  platform=linux
else
  echo 'Run in disposable MSYS2 CLANG64 or the pinned Linux x86_64 build image.' >&2
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
checkout https://github.com/abseil/abseil-cpp.git 76bb24329e8bf5f39704eb10d21b9a80befa7c81 "$output/abseil"

cd "$output/rpcs3"
sed 's/\r$//' "$patch_dir/rpcs3-libretro-frontend.patch" > "$output/frontend.patch"
git apply --check "$output/frontend.patch"
git apply "$output/frontend.patch"

if [[ $platform == linux ]]; then
  # Use the exact Linux FFmpeg archive selected by the pinned upstream recipe.
  mkdir -p build/3rdparty
  curl -fsSL --retry 3 https://github.com/RPCS3/ffmpeg-core/releases/download/649d9d9/ffmpeg-linux-x64.zip \
    -o build/3rdparty/ffmpeg.zip
  echo 'cb623d6492d405ce2ff1778c960f1f52393efa1df774cb27af8686d33a831354  build/3rdparty/ffmpeg.zip' | sha256sum -c

  # Omit the optional, moving game-patch database. RPCS3 can still read local patches.
  sed -i '/^    file(STRINGS /,/^    file(WRITE .*patch.yml/{ /^    file(WRITE .*patch.yml/!d; }' rpcs3/libretro/embed_patches.cmake
  sed -i '/^function(libretro_embed_patches out_file)/a\    set(patch "")' rpcs3/libretro/embed_patches.cmake
  if grep -q 'file(DOWNLOAD' rpcs3/libretro/embed_patches.cmake; then
    echo 'Unexpected upstream patch database recipe.' >&2
    exit 1
  fi

  export ANYPS5_ABSL_SOURCE="$output/abseil"
  export RPCS3_DIR="$output/rpcs3" ARTDIR="$output/artifacts" COMPILER=clang KEEP_SYMBOLS=0
  sed \
    -e '/^git config --global --add safe.directory /d' \
    -e 's/^git submodule -q update --init --force /git submodule -q update --init --depth 1 --jobs 3 /' \
    -e 's@-DCMAKE_SHARED_LINKER_FLAGS="${LINKER_FLAG}"@-DCMAKE_SHARED_LINKER_FLAGS="${LINKER_FLAG} -static-libstdc++ -shared-libgcc -Wl,--exclude-libs,ALL"@' \
    -e 's@-DLLVM_DIR=@-DFETCHCONTENT_SOURCE_DIR_ABSL="$ANYPS5_ABSL_SOURCE" -DLLVM_DIR=@' \
    -e 's/^ninja rpcs3_libretro$/ninja -j3 rpcs3_libretro/' \
    .ci/build-libretro.sh > build-anyps5-core.sh
  if grep -Eq 'git config --global|^ninja rpcs3_libretro$' build-anyps5-core.sh; then
    echo 'Unexpected upstream build recipe.' >&2
    exit 1
  fi

  nice -n 19 ionice -c 3 sh -ex build-anyps5-core.sh
  cd "$ARTDIR"
  readelf -d rpcs3_libretro.so > "$output/elf-dependencies.txt"
  readelf --version-info rpcs3_libretro.so > "$output/elf-versions.txt"
  if grep -Eq 'NEEDED.*(libGLEW|libopencv|libstdc\+\+|libX11|libGLX|libGL\.so|libxcb|libwayland)' "$output/elf-dependencies.txt" ||
     grep -q 'GLIBCXX_' "$output/elf-versions.txt"; then
    echo 'The Linux core needs an unexpected runtime library.' >&2
    exit 1
  fi
  latest_glibc=$(grep -oE 'GLIBC_[0-9.]+' "$output/elf-versions.txt" | sort -Vu | tail -1)
  if [[ $(printf '%s\n' "$latest_glibc" GLIBC_2.35 | sort -V | tail -1) != GLIBC_2.35 ]]; then
    echo "The Linux core needs $latest_glibc, newer than Ubuntu 22.04." >&2
    exit 1
  fi
  nm -D --defined-only rpcs3_libretro.so > "$output/elf-exports.txt"
  nm -D --undefined-only rpcs3_libretro.so > "$output/elf-undefined.txt"
  for api in retro_api_version retro_set_environment retro_load_game retro_run; do
    if ! grep -qE "[[:space:]]$api$" "$output/elf-exports.txt"; then
      echo "The Linux core does not export $api." >&2
      exit 1
    fi
  done
  if grep -Eq '[[:space:]](__cxa_throw|__cxa_allocate_exception|__gxx_personality_v0)$' "$output/elf-exports.txt" ||
     grep -Eq ' (X[A-Z][a-z]|glX|xcb_|wl_)' "$output/elf-undefined.txt"; then
    echo 'The Linux core has unexpected runtime exports or display imports.' >&2
    exit 1
  fi
  dpkg-query -W > "$output/linux-packages.txt"
  cmake -E tar cf "$output/packages/rpcs3_libretro.so.zip" --format=zip rpcs3_libretro.so
  archive_digest=$(sha256sum "$output/packages/rpcs3_libretro.so.zip" | cut -d ' ' -f 1)
  library_digest=$(sha256sum rpcs3_libretro.so | cut -d ' ' -f 1)
  printf '%s:%s\n' "$archive_digest" "$library_digest" > "$output/packages/ps3-core-digests.txt"
  printf 'Package and digest pair: %s\n' "$output/packages"
  exit
fi

checkout https://github.com/FFmpeg/FFmpeg.git f9db090b14c255a8f1c5f8f41a4c92b723228763 "$output/rpcs3/ffmpeg-src"
export ANYPS5_ABSL_SOURCE
ANYPS5_ABSL_SOURCE=$(cygpath -m "$output/abseil")

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
