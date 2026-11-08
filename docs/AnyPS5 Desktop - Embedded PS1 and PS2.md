# AnyPS5 Desktop embedded PS1 and PS2

The embedded host runs SwanStation and ParaLLEl PS2 in the launcher window
on Windows x64 and Linux x64. It builds on the
[standalone emulator library](<AnyPS5 Desktop - Standalone Emulator Library.md>).
Native macOS launcher parity is a companion Swift change. The PS3 core
and Vulkan bridge have their own review scope.

## Review setup

1. Add a game from the existing library. The launcher uses the same cover,
   wallpaper and playlist formats as the standalone library.
2. Under **Settings → Emulators**, choose the embedded core for the console
   and select its verified ZIP for your operating system.
3. Select your local console BIOS. Play uses the embedded core when its
   library and BIOS are present. Existing standalone paths remain available
   for consoles without embedded setup.
4. Press PS or Escape to open Quick Menu. Resume returns to the same
   native session. Game settings lists the graphics controls reported by
   the active core. Supported resolution and filtering changes are
   persisted per game after the core accepts them.

The [package installer](../lib/core/managed_retro.dart) checks both the
ZIP and the library against the repository pins, then rechecks the
installed library before each launch. It stages replacements so a
rejected ZIP cannot replace the current core. The following file names
identify the pinned review archives.

| Core | Windows x64 | Linux x64 |
| --- | --- | --- |
| SwanStation 1.0.0 631f0fb | `swanstation_libretro.dll.zip` | `swanstation_libretro.so.zip` |
| ParaLLEl PS2 v2.0.0-da5b07e | `pcsx2_libretro.dll.zip` | `pcsx2_libretro.so.zip` |

Use the hashes in the installer to identify these exact builds. The
Libretro Buildbot's individual core URLs can change their contents.
Public one-click installation still needs an approved immutable
distribution source. The launcher imports BIOS from the user.

## Session behavior

The [application integration](../lib/ui/embedded_emulators.dart) selects
the configured core, passes a title's saved graphics choices and
supplies controller state. The [channel session](../lib/ui/embedded_retro_game.dart)
polls the native host, sends input and waits for native release before
reporting exit. [The texture view](../lib/ui/embedded_retro_view.dart)
draws the game in the same window. Losing focus clears game input while
the emulator keeps running. Quick Menu pauses the game and Resume
continues the current session. The close path waits for the core to
finish writing saves.

The [headless Flutter tests](../test/ui/embedded_ps12_session_test.dart)
use a mocked native channel to verify the contract, including the exact
library names, input, focus loss, release and persistence after accepted
graphics changes. They do not exercise actual rendering or emulator
compatibility.
