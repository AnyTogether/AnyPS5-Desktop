AnyPS5-Desktop patch: Full Screen default

Replace the existing file at:
  lib/core/game_settings.dart

with the file at the same path in this archive.

Changes:
- New built-in DisplayDefaults uses Full Screen (fullscreen: true).
- Legacy game settings continue to be migrated using the previous built-in
  Window value, allowing games without an explicit display choice to follow
  the new Full Screen default.
- Explicit choices in current per-game settings remain unchanged.

This ZIP contains the complete replacement source file, not a Git diff.
The Flutter test suite has not been run as the complete repository was not
provided in this chat.
