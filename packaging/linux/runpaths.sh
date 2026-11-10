#!/bin/bash
# shellcheck disable=SC2016 # $ORIGIN is for the loader, not the shell.
# The RUNPATH (or older RPATH) of every ELF file in a Linux bundle may only name folders inside
# the bundle, written from $ORIGIN (the file's own folder). The Flutter build installs the plugin
# libraries as CMake built them, with the build machine's folders (/home/runner/...) in their
# RUNPATH: on a user's machine a folder by that name could hand them other libraries, and namcap
# reports it as insecure.
#
#   runpaths.sh fix <bundle>      drops every other entry (patchelf). A file left with none gets
#                                 $ORIGIN, as what the bundle's libraries link sits beside them.
#   runpaths.sh check <folder>... lists every RUNPATH and RPATH and fails on an entry that is not
#                                 $ORIGIN-relative or leads out of that folder.
#
# common.sh runs fix on the bundle before the .deb and the AppImage are packed (the .tar.gz is
# the same bundle), and CI runs check on all three.
set -euo pipefail
MODE="${1:?usage: runpaths.sh fix <bundle> | runpaths.sh check <folder>...}"
shift
[ $# -gt 0 ] || { echo "runpaths: no folder given" >&2; exit 2; }

is_elf() { [ "$(head -c 4 "$1" 2>/dev/null | od -An -c | tr -d ' \n')" = '177ELF' ]; }

# "RUNPATH <entries>" or "RPATH <entries>" for each such tag of an ELF file.
tags() { readelf -d "$1" 2>/dev/null | sed -nE 's/.*\((RUNPATH|RPATH)\)[^[]*\[(.*)\]$/\1 \2/p'; }

# Whether one entry of a file's RUNPATH stays inside <root>: $ORIGIN or ${ORIGIN}, alone or
# followed by a relative path, that leads to a folder under <root>.
inside() {
  local entry="$1" file="$2" root="$3" rest dir
  case "$entry" in
    '$ORIGIN' | '${ORIGIN}') rest='' ;;
    '$ORIGIN/'* | '${ORIGIN}/'*) rest="/${entry#*/}" ;;
    *) return 1 ;;
  esac
  dir="$(realpath -m "$(dirname "$file")$rest")"
  [ "$dir" = "$root" ] || [[ "$dir" == "$root"/* ]]
}

elf_files() {
  find "$1" -type f -print0 | while IFS= read -r -d '' file; do
    if is_elf "$file"; then printf '%s\0' "$file"; fi
  done
}

fix() {
  local root changed=0 file tag value entry new
  local -a entries kept
  root="$(realpath "$1")"
  while IFS= read -r -d '' file; do
    while read -r tag value; do
      kept=()
      IFS=: read -r -a entries <<<"$value"
      [ ${#entries[@]} -gt 0 ] || entries=('')
      for entry in "${entries[@]}"; do
        if inside "$entry" "$file" "$root"; then kept+=("$entry"); fi
      done
      if [ ${#kept[@]} -eq ${#entries[@]} ]; then continue; fi
      command -v patchelf >/dev/null || { echo "runpaths: patchelf is needed to fix ${file#"$root"/}" >&2; exit 1; }
      [ ${#kept[@]} -gt 0 ] || kept=('$ORIGIN')
      new="$(IFS=:; printf '%s' "${kept[*]}")"
      patchelf --set-rpath "$new" "$file"
      echo "runpaths: ${file#"$root"/}: $tag $value -> $(tags "$file" | tr '\n' ' ' | sed 's/ $//')"
      changed=$((changed + 1))
    done < <(tags "$file")
  done < <(elf_files "$root")
  echo "runpaths: $changed RUNPATH entries rewritten in $root"
}

check() {
  local root file tag value entry count=0
  local -a entries bad=()
  for folder in "$@"; do
    root="$(realpath "$folder")"
    while IFS= read -r -d '' file; do
      count=$((count + 1))
      while read -r tag value; do
        echo "  ${file#"$root"/}: $tag $value"
        IFS=: read -r -a entries <<<"$value"
        [ ${#entries[@]} -gt 0 ] || entries=('')
        for entry in "${entries[@]}"; do
          inside "$entry" "$file" "$root" || bad+=("${file#"$root"/}: $tag entry '$entry'")
        done
      done < <(tags "$file")
    done < <(elf_files "$root")
    echo "runpaths: checked $root"
  done
  if [ ${#bad[@]} -gt 0 ]; then
    echo "runpaths: these entries are absolute, empty or lead out of the bundle:" >&2
    printf '  %s\n' "${bad[@]}" >&2
    exit 1
  fi
  echo "runpaths: $count ELF files, every RUNPATH and RPATH entry is \$ORIGIN-relative and inside"
}

case "$MODE" in
  fix) fix "$1" ;;
  check) check "$@" ;;
  *) echo "runpaths: unknown mode $MODE (fix or check)" >&2; exit 2 ;;
esac
