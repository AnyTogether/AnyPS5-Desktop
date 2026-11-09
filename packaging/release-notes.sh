#!/usr/bin/env bash
# Prints the next release's notes: the lines still in RELEASE_NOTES.md's "Next release", then each
# file in release-notes/next by file name, in byte order, so the same on every machine.
#
# Each file holds one change's bullet ("- **What changed**, ..."). Exits with an error naming a
# file that does not start with one: CI runs this to keep the list well formed.
set -euo pipefail

cd "$(dirname "$0")/.."

awk '/^## Next release$/ { on = 1; next } /^## / { on = 0 } on && NF && $0 != "Nothing yet." { print }' RELEASE_NOTES.md

[ -d release-notes/next ] || exit 0
while IFS= read -r note; do
  if [ "$(head -c 2 "$note")" != "- " ]; then
    echo "$note: a note starts with \"- \"" >&2
    exit 1
  fi
  # A file need not end in a newline; the next one must still start on its own line.
  cat "$note"
  [ -z "$(tail -c 1 "$note")" ] || echo
done < <(find release-notes/next -maxdepth 1 -type f -name '*.md' | LC_ALL=C sort)
