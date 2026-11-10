#!/bin/bash
# Installs the .deb in <folder> with its Depends and nothing else (no Recommends) and checks that
# the launcher and every library in /opt/anyps5-desktop/lib find all they link. Run as root on a
# clean Ubuntu (CI: ubuntu:22.04 and ubuntu:24.04 containers), never on a desktop of yours.
#
# The launcher is checked as it starts (its RUNPATH, $ORIGIN/lib). The libraries in lib/ are
# checked with lib/ on the path, as when the launcher has loaded its neighbours: SDL2, the clip
# player and the native assets are opened at run time. libjvm.so is package:jni's (libdartjni.so),
# which only Android opens.
set -euo pipefail
FOLDER="${1:?usage: check-deb.sh <folder with anyps5-desktop_*_amd64.deb>}"
APP=/opt/anyps5-desktop

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends "$FOLDER"/anyps5-desktop_*_amd64.deb >/dev/null
sed -n 's/^VERSION=//p' /etc/os-release
dpkg -s anyps5-desktop | sed -n '/^Depends: /p'

not_found() { grep 'not found' | grep -v 'libjvm\.so' || true; }

missing=()
while IFS= read -r line; do missing+=("anyps5_desktop: $line"); done < <(ldd "$APP/anyps5_desktop" | not_found)
count=0
for file in "$APP"/lib/*.so "$APP"/lib/*.so.*; do
  [ -f "$file" ] || continue
  count=$((count + 1))
  # ldd says "not a dynamic executable" (and fails) for libapp.so, the Dart snapshot.
  while IFS= read -r line; do
    missing+=("lib/$(basename "$file"): $line")
  done < <({ LD_LIBRARY_PATH="$APP/lib" ldd "$file" 2>/dev/null || true; } | not_found)
done

if [ ${#missing[@]} -gt 0 ]; then
  echo "not found:"
  printf '  %s\n' "${missing[@]}"
  exit 1
fi
echo "the launcher and $count libraries in lib/ find everything they link"
