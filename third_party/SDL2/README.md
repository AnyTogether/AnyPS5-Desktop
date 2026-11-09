# SDL2

The launcher reads controllers through SDL2's game controller API (lib/core/controllers/sdl_pads.dart),
the library the AnyPS5 engine reads them with too. It is the zlib-licensed Simple DirectMedia Layer,
https://www.libsdl.org/ (LICENSE.txt beside this file).

- **Windows:** the official runtime, `SDL2-2.32.10-win32-x64.zip` from
  https://github.com/libsdl-org/SDL/releases/tag/release-2.32.10, downloaded by windows/CMakeLists.txt
  at build time and checked against its SHA-256
  (`6cf9706eefd0a4a06dc764007934d428afaf029fabdd408a9e646048c91e18fb`); `SDL2.dll` goes beside the
  launcher with `SDL2-LICENSE.txt`. A failed download stops the build, and the installer script
  stops when `SDL2.dll` is not in the build output.
- **Linux:** the system's `libSDL2-2.0.so.0` (package `libsdl2-2.0-0`, `SDL2` or `sdl2`), copied into
  the bundle's `lib/` when the build machine has it, so the AppImage carries its own.

Without SDL2 the launcher falls back to its older readers (XInput and winmm on Windows, evdev on Linux)
and says so in Settings › Controllers.
