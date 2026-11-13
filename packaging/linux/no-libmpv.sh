#!/bin/bash
# Checks that a Linux bundle carries no libmpv and that nothing in it links one: the launcher is
# GPL-2.0-only and uses the system's libmpv (libmpv2 or libmpv1, mpv on Arch). The clip player's
# plugin links libanyps5_mpv.so (linux/mpv_shim), which opens the system's libmpv when a clip
# plays, so the launcher starts without one. common.sh runs it before the .deb and the AppImage
# are packed; CI runs it on the bundle the .tar.gz is made from.
#
#   no-libmpv.sh <bundle>
set -euo pipefail
BUNDLE="${1:?usage: no-libmpv.sh <bundle folder>}"
LIB="$BUNDLE/lib"

problems=()
while IFS= read -r -d '' file; do
  problems+=("${file#"$BUNDLE"/}: a libmpv in the bundle")
done < <(find "$BUNDLE" -name 'libmpv.so*' -print0)
[ -d "$LIB/licenses" ] && problems+=("lib/licenses: the copyright files of a carried libmpv")

for file in "$BUNDLE/anyps5_desktop" "$LIB"/*.so "$LIB"/*.so.*; do
  [ -f "$file" ] || continue
  # libapp.so (the Dart snapshot) has no dynamic section to read.
  needed=$(objdump -p "$file" 2>/dev/null | awk '/NEEDED/ {print $2}' || true)
  linked=$(grep '^libmpv\.so' <<<"$needed" || true)
  if [ -n "$linked" ]; then problems+=("${file#"$BUNDLE"/}: links $(tr '\n' ' ' <<<"$linked")"); fi
done

plugin="$LIB/libmedia_kit_video_plugin.so"
if [ -f "$plugin" ] && ! grep -qx 'libanyps5_mpv.so' <<<"$(objdump -p "$plugin" | awk '/NEEDED/ {print $2}')"; then
  problems+=("lib/libmedia_kit_video_plugin.so: does not link libanyps5_mpv.so")
fi
if [ -f "$plugin" ] && [ ! -f "$LIB/libanyps5_mpv.so" ]; then
  problems+=("lib/libanyps5_mpv.so: missing")
fi

if [ ${#problems[@]} -gt 0 ]; then
  echo "no-libmpv: the bundle has to use the system's libmpv:" >&2
  printf '  %s\n' "${problems[@]}" >&2
  exit 1
fi
echo "no-libmpv: no libmpv in $BUNDLE, and nothing there links one"
