#!/bin/bash
# The launcher with the system's libmpv, then without one, on a clean Ubuntu (CI: ubuntu:22.04
# and ubuntu:24.04 containers, as root; never on a desktop of yours):
#
#   1. installs the .deb in <folder> with its Depends, which bring libmpv2 or libmpv1 from apt;
#   2. libanyps5_mpv.so reaches that libmpv (mpv-shim-check with), and the launcher starts under
#      Xvfb and is still running after a while, without saying libmpv is missing;
#   3. takes libmpv away (dpkg --force-depends): the launcher and every library it carries still
#      find all they link, libanyps5_mpv.so fails cleanly (mpv-shim-check without), and the
#      launcher still starts and keeps running, and says (its log) that libmpv is not installed.
#
#   check-libmpv.sh <folder with anyps5-desktop_*_amd64.deb> <mpv-shim-check>
set -euo pipefail
FOLDER="${1:?usage: check-libmpv.sh <folder with the .deb> <mpv-shim-check>}"
CHECK="${2:?usage: check-libmpv.sh <folder with the .deb> <mpv-shim-check>}"
APP=/opt/anyps5-desktop
# How long the launcher has to keep running.
RUN_SECONDS="${RUN_SECONDS:-25}"
MISSING_LINE='libmpv is not installed'

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends "$FOLDER"/anyps5-desktop_*_amd64.deb >/dev/null
# To start it: an X server and Mesa's software OpenGL and GLES, which Flutter's engine opens
# (libGLESv2.so.2) and every desktop has.
apt-get install -y -qq --no-install-recommends xvfb xauth libgl1-mesa-dri libgles2 libegl1 libegl-mesa0 >/dev/null
sed -n 's/^VERSION=//p' /etc/os-release

libmpv=$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'libmpv*' 2>/dev/null | awk '$1 == "ii" && $2 ~ /^libmpv[0-9]+$/ {print $2}')
[ -n "$libmpv" ] || { echo "the .deb's Depends brought no libmpv"; exit 1; }
echo "libmpv from apt: $libmpv $(dpkg-query -W -f='${Version}' "$libmpv")"

# Starts the launcher for RUN_SECONDS under Xvfb. It has to be running still at the end (timeout
# stops it: 124) and the loader must not have complained. The log goes to $1.
start() {
  local log="$1" code=0
  HOME="$(mktemp -d)" xvfb-run -a -s '-screen 0 1280x720x24' \
    timeout "$RUN_SECONDS" "$APP/anyps5_desktop" >"$log" 2>&1 || code=$?
  if grep -E 'error while loading shared libraries|symbol lookup error|undefined symbol' "$log"; then
    echo "the loader could not start the launcher"
    return 1
  fi
  if [ "$code" != 124 ]; then
    echo "the launcher stopped after less than ${RUN_SECONDS}s (exit $code):"
    tail -n 40 "$log"
    return 1
  fi
  echo "the launcher ran for ${RUN_SECONDS}s"
}

echo "== with $libmpv"
"$CHECK" "$APP/lib/libanyps5_mpv.so" with
start /tmp/with.log
if grep -q "$MISSING_LINE" /tmp/with.log; then
  echo "the launcher says libmpv is missing although $libmpv is installed"
  exit 1
fi

echo "== without libmpv"
dpkg --remove --force-depends "$libmpv" >/dev/null
ldconfig
if ldconfig -p | grep -q 'libmpv\.so'; then
  echo "a libmpv is still installed:"
  ldconfig -p | grep 'libmpv\.so'
  exit 1
fi
not_found() { grep 'not found' | grep -v 'libjvm\.so' || true; }
missing=$(
  ldd "$APP/anyps5_desktop" | not_found
  for file in "$APP"/lib/*.so "$APP"/lib/*.so.*; do
    [ -f "$file" ] || continue
    { LD_LIBRARY_PATH="$APP/lib" ldd "$file" 2>/dev/null || true; } | not_found | sed "s#^#$(basename "$file"): #"
  done
)
if [ -n "$missing" ]; then
  echo "without libmpv, not found:"
  echo "$missing"
  exit 1
fi
echo "the launcher and its libraries find everything they link without libmpv"
"$CHECK" "$APP/lib/libanyps5_mpv.so" without
start /tmp/without.log
if ! grep -q "$MISSING_LINE" /tmp/without.log; then
  echo "the launcher did not notice libmpv is missing:"
  tail -n 40 /tmp/without.log
  exit 1
fi
echo "the launcher started without libmpv and said so: $(grep -m1 "$MISSING_LINE" /tmp/without.log)"
