#!/bin/bash
# Builds build/packages/anyps5-desktop_<version>_amd64.deb from the Linux release bundle:
# /opt/anyps5-desktop, /usr/bin/anyps5-desktop, a desktop entry and the icon. The dependencies
# are read from the bundle's libraries (dpkg -S on what ldd resolves outside it), so build on
# the oldest distro it should install on (Ubuntu 22.04). SKIP_BUILD=1 packs an existing bundle.
source "$(dirname "$0")/common.sh"
build_bundle

PKG="$ROOT/build/deb/anyps5-desktop"
rm -rf "$ROOT/build/deb"
mkdir -p "$PKG/DEBIAN" "$PKG/opt/anyps5-desktop" "$PKG/usr/bin" "$PKG/usr/share/applications" \
  "$PKG/usr/share/icons/hicolor/256x256/apps" "$PKG/usr/share/icons/hicolor/512x512/apps"
cp -a "$BUNDLE/." "$PKG/opt/anyps5-desktop/"
ln -s /opt/anyps5-desktop/anyps5_desktop "$PKG/usr/bin/anyps5-desktop"
cp "$HERE/anyps5-desktop.desktop" "$PKG/usr/share/applications/"
# .anyps5theme files (the MIME type the desktop entry opens).
mkdir -p "$PKG/usr/share/mime/packages"
cp "$HERE/anyps5-desktop-mime.xml" "$PKG/usr/share/mime/packages/anyps5-desktop.xml"
cp "$HERE/anyps5-desktop.png" "$PKG/usr/share/icons/hicolor/256x256/apps/anyps5-desktop.png"
cp "$HERE/anyps5-desktop-512.png" "$PKG/usr/share/icons/hicolor/512x512/apps/anyps5-desktop.png"

# The packages that hold the system libraries the bundle links directly (its NEEDED entries
# that are not in the bundle), and the newest glibc symbol version it needs. lib/*.so.* is SDL2
# (the build machine's libsdl2-2.0-0, linux/CMakeLists.txt), whose X11, Wayland, ALSA, PulseAudio,
# DRM/GBM and xkbcommon libraries are NEEDED entries too. SDL2 opens a few more only when asked
# (GL, EGL and Vulkan for video, PipeWire and sndio for audio, D-Bus): the launcher starts only its
# joystick and game controller parts, which open the system's libudev. A NEEDED library this
# machine cannot name a package for stops the build, so none is left out quietly: build on the
# oldest distro it should install on, with every library installed (CI's linux job).
#
# libmpv is not carried (common.sh checks it): the clip player's libanyps5_mpv.so opens the
# system's when a clip plays, so it is no NEEDED entry and is named below by hand, libmpv2
# (Ubuntu 24.04, Debian 12 and newer) or libmpv1 (Ubuntu 22.04).
# libjvm.so: package:jni's libdartjni.so, which only Android opens.
not_packaged='libjvm.so'
files=("$PKG/opt/anyps5-desktop/anyps5_desktop" "$PKG"/opt/anyps5-desktop/lib/*.so "$PKG"/opt/anyps5-desktop/lib/*.so.*)
needed=$(for f in "${files[@]}"; do objdump -p "$f" | awk '/NEEDED/ {print $2}'; done | sort -u)
# The package that installed a library, by any of the names usrmerge gives it (/lib and /usr/lib).
owner() {
  local path real candidate out
  path="$1"
  real="$(readlink -f "$path")"
  for candidate in "$real" "$path" "${real#/usr}" "${path#/usr}" "/usr$real" "/usr$path"; do
    out=$(dpkg -S "$candidate" 2>/dev/null) || continue
    out=${out%%$'\n'*}
    printf '%s\n' "${out%%:*}"
    return 0
  done
  return 1
}
found=()
unnamed=()
for lib in $needed; do
  [ -e "$PKG/opt/anyps5-desktop/lib/$lib" ] && continue
  [[ " $not_packaged " == *" $lib "* ]] && continue
  path=$(ldconfig -p | awk -v l="$lib" '$1 == l && /x86-64/ {print $NF; exit}')
  if [ -n "$path" ] && package=$(owner "$path"); then
    found+=("$package")
  else
    unnamed+=("$lib")
  fi
done
if [ ${#unnamed[@]} -gt 0 ]; then
  echo "build-deb: no installed package has ${unnamed[*]}: install it here, or list it in not_packaged" >&2
  exit 1
fi
# By their Ubuntu 22.04 names, the t64 suffix taken off when built on 24.04. Ubuntu 24.04 renamed
# some for its 64-bit time_t (libasound2t64): those get the new name as an alternative, though
# the t64 packages provide the old names too.
packages=$(printf '%s\n' "${found[@]}" | sed 's/t64$//' | grep -v '^libc6$' | sort -u)
renamed=' libasound2 libatk1.0-0 libatk-bridge2.0-0 libglib2.0-0 libgtk-3-0 libpng16-16 libcups2 libssl3 libgnutls30 libcurl4 '
glibc=$(for f in "${files[@]}"; do objdump -T "$f"; done \
  | grep -o 'GLIBC_[0-9.]*' | sed 's/GLIBC_//' | sort -uV | tail -1)
depends="libc6 (>= $glibc)"
for package in $packages; do
  case "$renamed" in
    *" $package "*) depends="$depends, $package | ${package}t64" ;;
    *) depends="$depends, $package" ;;
  esac
done
depends="$depends, libmpv2 | libmpv1, xdg-utils"

# The launcher's own font has Latin letters only. Flutter draws every other script with a
# system font that has it (fontconfig), so the Noto fonts are recommended: Khmer, Lao, Ethiopic,
# Devanagari, Bengali and Arabic in fonts-noto-core, Chinese, Japanese and Korean in fonts-noto-cjk.
# gtk-layer-shell puts cards and the LIVE badge over the game under Wayland (KDE Plasma, Sway,
# Hyprland); the launcher loads it when it is there and keeps the system notice when it is not.
recommends="libsecret-tools, libsdl2-2.0-0, libgtk-layer-shell0, fonts-noto-core | fonts-noto, fonts-noto-cjk"

# A nightly (0.1.21-nightly.20261109.1) comes before its release: dpkg sorts ~ before nothing.
DEB_VERSION="$(printf '%s' "$VERSION" | sed 's/-/~/')"
size=$(du -sk "$PKG" | cut -f1)
cat > "$PKG/DEBIAN/control" <<CONTROL
Package: anyps5-desktop
Version: $DEB_VERSION
Section: games
Priority: optional
Architecture: amd64
Maintainer: Utku Halis <personal@utkuhalis.com.tr>
Installed-Size: $size
Depends: $depends
Recommends: $recommends
Homepage: https://github.com/AnyTogether/AnyPS5-Desktop
Description: PS5-style launcher for AnyPS5
 Finds PS5 game dumps in a games folder, unlocks them with the AnyPS5 toolkit
 (relinker and system libraries) and starts them, with controls, settings,
 saves, trophies and a phone controller per game.
CONTROL

TARGET="$OUT/anyps5-desktop_${VERSION}_amd64.deb"
dpkg-deb --root-owner-group -Zxz --build "$PKG" "$TARGET"
dpkg-deb --info "$TARGET" | sed -n '/Depends/p'
ls -l "$TARGET"
