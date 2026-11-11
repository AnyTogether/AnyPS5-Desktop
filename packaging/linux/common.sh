# Shared by build-appimage.sh and build-deb.sh: the version, the Flutter bundle and the output folder.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
VERSION="$(sed -nE 's/^version:[[:space:]]*([0-9][^+[:space:]]*).*/\1/p' "$ROOT/pubspec.yaml")"
BUNDLE="$ROOT/build/linux/x64/release/bundle"
OUT="$ROOT/build/packages"
mkdir -p "$OUT"
build_bundle() {
  if [ "${SKIP_BUILD:-0}" != 1 ]; then (cd "$ROOT" && flutter build linux --release); fi
  [ -x "$BUNDLE/anyps5_desktop" ] || { echo "no release bundle in $BUNDLE" >&2; exit 1; }
  # No build folder in any library's RUNPATH: only $ORIGIN-relative folders inside the bundle.
  bash "$HERE/runpaths.sh" fix "$BUNDLE"
  bash "$HERE/no-libmpv.sh" "$BUNDLE"
}
