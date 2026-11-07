#!/bin/bash
# The in-app clip player's libmpv, carried in the Linux bundle: media_kit_video's plugin links the
# build machine's libmpv (libmpv.so.1 on Ubuntu 22.04, libmpv.so.2 on newer systems), so a system
# with the other one, or none, could not start the launcher. This copies that libmpv into the
# bundle's lib/ with the libraries it needs that the launcher does not need already (FFmpeg's and
# the rest), points each of them and the plugin at lib/ ($ORIGIN), and copies their packages'
# copyright files to lib/licenses/. Left to the system: glibc, the C++ runtime, the GPU drivers'
# libraries (GL, EGL, DRM, GBM) and the X11 and Wayland client libraries, as AppImages leave them
# (pkg2appimage's excludelist), and every library the launcher already links (GTK and the rest).
#
# linux/CMakeLists.txt runs it at the end of the install step: bash bundle-libmpv.sh <bundle>.
# Without patchelf it only says so: the bundle then needs the system's libmpv, as on the build
# machine. ANYPS5_REQUIRE_LIBMPV=1 (CI) makes a missing patchelf or libmpv an error.
set -euo pipefail
BUNDLE="${1:?usage: bundle-libmpv.sh <bundle folder>}"
LIB="$BUNDLE/lib"
PLUGIN="$LIB/libmedia_kit_video_plugin.so"
require="${ANYPS5_REQUIRE_LIBMPV:-0}"

problem() {
  echo "bundle-libmpv: $1" >&2
  if [ "$require" = 1 ]; then exit 1; fi
  exit 0
}

[ -e "$PLUGIN" ] || problem "no $PLUGIN: nothing to carry"
command -v patchelf >/dev/null || problem "patchelf is not installed: the bundle uses the system's libmpv"

# The libmpv the plugin resolves to on this machine.
mpv=$(ldd "$PLUGIN" | awk '$1 ~ /^libmpv\.so/ && $3 ~ /^\// {print $3; exit}')
[ -n "$mpv" ] || problem "the plugin does not resolve a libmpv (is libmpv-dev installed?)"
mpv_name=$(basename "$(objdump -p "$mpv" | awk '/SONAME/ {print $2}')")

# What stays with the system: glibc's libraries, the C++ runtime, the GPU drivers' and the
# window system's client libraries.
system_library() {
  case "$1" in
    ld-linux*|libc.so.*|libm.so.*|libdl.so.*|libpthread.so.*|librt.so.*|libresolv.so.*|libutil.so.*|libmvec.so.*|libanl.so.*|libnss_*|libthread_db.so.*|libBrokenLocale.so.*|libcidn.so.*) return 0 ;;
    libstdc++.so.*|libgcc_s.so.*) return 0 ;;
    libGL.so.*|libEGL.so.*|libGLX.so.*|libGLdispatch.so.*|libOpenGL.so.*|libglapi.so.*|libGLESv2.so.*|libgbm.so.*|libdrm.so.*) return 0 ;;
    libX11.so.*|libX11-xcb.so.*|libxcb.so.*|libxcb-dri2.so.*|libxcb-dri3.so.*|libwayland-client.so.*|libwayland-egl.so.*|libwayland-cursor.so.*) return 0 ;;
    libasound.so.*|libpipewire-0.3.so.*|libfontconfig.so.*|libfreetype.so.*|libharfbuzz.so.*|libexpat.so.*|libz.so.*|libuuid.so.*|libcom_err.so.*|libgpg-error.so.*|libusb-1.0.so.*|libICE.so.*|libSM.so.*|libfribidi.so.*|libgmp.so.*) return 0 ;;
  esac
  return 1
}

# What the launcher links already, without the clip player: what every other library in the
# bundle resolves to here, and the launcher's own direct needs (ldd on it would follow the plugin).
declare -A base=()
for file in "$LIB"/*.so "$LIB"/*.so.*; do
  case "$(basename "$file")" in libmedia_kit_video_plugin.so|libmpv.so*) continue ;; esac
  [ -f "$file" ] || continue
  while read -r name; do base["$name"]=1; done < <(ldd "$file" 2>/dev/null | awk '$2 == "=>" {print $1}')
done
while read -r name; do base["$name"]=1; done < <(objdump -p "$BUNDLE/anyps5_desktop" | awk '/NEEDED/ {print $2}')

# name -> where it came from on this machine.
declare -A origin=()
origin["$mpv_name"]="$mpv"
while read -r name path; do
  if system_library "$name" || [ -n "${base[$name]:-}" ]; then continue; fi
  origin["$name"]="$path"
done < <(ldd "$mpv" | awk '$2 == "=>" && $3 ~ /^\// {print $1, $3}')

copied=()
# shellcheck disable=SC2016 # $ORIGIN is for the loader, not the shell.
for name in "${!origin[@]}"; do
  if [ -e "$LIB/$name" ]; then continue; fi
  cp -L "${origin[$name]}" "$LIB/$name"
  chmod 644 "$LIB/$name"
  # Each one looks for the others beside itself.
  patchelf --set-rpath '$ORIGIN' "$LIB/$name"
  copied+=("$name")
done
# shellcheck disable=SC2016
patchelf --set-rpath '$ORIGIN' "$PLUGIN"

# The copyright files of the packages they came from (Debian and Ubuntu).
if command -v dpkg >/dev/null; then
  mkdir -p "$LIB/licenses"
  packages=$(for name in "${copied[@]}"; do
      path="${origin[$name]}"
      { dpkg -S "$(readlink -f "$path")" 2>/dev/null || dpkg -S "$path" 2>/dev/null || true; } | cut -d: -f1
    done | sort -u)
  for package in $packages; do
    if [ -f "/usr/share/doc/$package/copyright" ]; then
      cp "/usr/share/doc/$package/copyright" "$LIB/licenses/$package.txt"
    fi
  done
fi

size=$(for name in "${copied[@]}"; do stat -c %s "$LIB/$name"; done | awk '{s += $1} END {printf "%.1f", s / 1048576}')
echo "bundle-libmpv: $mpv_name and ${#copied[@]} libraries in all ($size MiB) carried in $LIB"
