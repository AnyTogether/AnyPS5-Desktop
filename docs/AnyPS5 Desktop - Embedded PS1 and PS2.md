# AnyPS5 Desktop embedded PS1 and PS2

The embedded host runs SwanStation and ParaLLEl PS2 in the launcher window
on Windows x64 and Linux x64. It builds on the
[standalone emulator library](<AnyPS5 Desktop - Standalone Emulator Library.md>).
Native macOS launcher parity is a companion Swift change. The PS3 core
and Vulkan bridge have their own review scope.

## Review setup

1. Under **Settings → Emulators**, choose the embedded core for the console
   and select its verified ZIP for your operating system.
2. Select your local console BIOS.
3. Add your games through **Settings → Game Library** if needed. The library
   accepts the same cover, wallpaper and playlist formats as the standalone
   slice. Play uses the embedded core when its library and BIOS are present.
   Existing standalone paths remain available for consoles without embedded setup.
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

## Changing PS1 discs

Use one M3U playlist with the discs in order. When the embedded core
reports multiple discs, press PS or Escape and choose **Change disc**.
Select the disc the game requests, confirm the inserted label, and
return to the game. Back returns to Quick Menu and keeps the game
paused. PS resumes the running game from either menu.

The [Quick Menu rows](../lib/ui/app_model.dart) and
[disc picker](../lib/ui/embedded_emulators.dart) read the inserted disc
from the core and use the core's disc labels when available. The
[channel session](../lib/ui/embedded_retro_game.dart) queues a selection
and reads completion from the next status update. A failed insert shows
an error and leaves the picker available for another attempt. If the
previous disc also cannot be reinserted, the picker shows the tray as
open.

The [session worker](../native/retro/retro_session.cpp) performs the
Libretro eject, select and insert callbacks before its pause wait, so
the game stays paused throughout the swap. The playlist stays loaded
in the same session. Its filename stem determines the memory-card
filename. When converting an existing single-disc library entry to a
playlist, use the same stem as the original disc to keep using its
existing embedded memory card.

## Native host

The [shared session worker](../native/retro/retro_session.cpp) owns core
callbacks, option transitions, input, memory-card writes and pacing.
Its [adapter contract](../native/retro/retro_session.h) keeps renderer,
audio and frame delivery outside the session. The
[Libretro declarations](../native/retro/libretro_abi.h) describe the C
callback types used by the worker. The
[dynamic loader](../native/retro/retro_library.cpp) and
[its interface](../native/retro/retro_library.h) scope the DLL or SO
handle to the session. The [software frame converter](../native/retro/retro_frame.cpp)
and [frame representation](../native/retro/retro_frame.h) give both
platforms immutable RGBA frames.

The [Linux adapter](../linux/runner/retro_core_host_linux.cc) and
[registration interface](../linux/runner/retro_core_host_linux.h)
connect the session to the GTK Flutter texture registrar. The
[EGL renderer](../linux/runner/retro_linux_video.cc) keeps a private
desktop OpenGL context on the worker. The
[PulseAudio sink](../linux/runner/retro_linux_audio.cc) uses a bounded
audio queue. Their [platform factories](../linux/runner/retro_linux_platform.h)
keep the device-specific objects out of the shared worker.
[Linux runner startup](../linux/runner/my_application.cc) registers
the channel for its view. Its [CMake target](../linux/runner/CMakeLists.txt)
links EGL, epoxy and PulseAudio. The [Windows adapter](../windows/runner/retro_core_host.cpp)
uses D3D11 and waveOut. The [Windows channel interface](../windows/runner/retro_core_host.h)
is owned by the [runner window](../windows/runner/flutter_window.cpp)
through its [window member](../windows/runner/flutter_window.h).
The [Windows CMake target](../windows/runner/CMakeLists.txt) links the
shared worker from [the native build](../native/retro/CMakeLists.txt).

Run the native checks in an isolated build directory. The
[fixture core](../native/retro/test/fake_core.cpp) exercises the callback
contract without a game. The [test driver](../native/retro/test/retro_native_test.cpp)
checks the loader, frame conversion, session behavior and disc swaps
through both the extended and legacy Libretro disk interfaces. It
checks worker-thread ownership, a paused swap without calls to
`retro_run`, recovery from a failed insertion, and retry after a failed
recovery.
[The CMake test target](../native/retro/test/CMakeLists.txt) builds the fixture and runs the driver.

```sh
cmake -S native/retro/test -B /tmp/anyps5-retro-test
cmake --build /tmp/anyps5-retro-test --parallel 3
ctest --test-dir /tmp/anyps5-retro-test --output-on-failure
```

## Verification

On Ubuntu 22.04 in WSL, the four Linux runner source files compiled with
GCC 11.4 against Flutter, GTK, EGL and PulseAudio headers. The native
tests passed. A headless test used the same session and EGL renderer with
the exact pinned libraries. Crash Team Racing rendered 760 frames at
1024 × 432. Gran Turismo 4 rendered 854 at 1280 × 896. Both produced
non-silent PCM and exited cleanly. These runs used Mesa llvmpipe with no
display and captured audio samples in memory. They cover the worker's
real game paths. The full Flutter desktop bundle, display and audio
output still need hosted or desktop qualification.

The Windows runner and host translation units compiled with MSVC 19.29,
and Windows CTest passed. All four Windows and Linux packages passed the installer ZIP and library
checks in a new directory. The 59-test Flutter suite covered the session,
standalone launch, library and navigation. Translation validation passed
with matching English and Turkish keys.

The Change Disc follow-up passed the native tests and compiled the
updated channel adapter on Windows with MSVC 19.29 and on Linux with
GCC 11.4. The focused Flutter run passed all 16 tests, including Quick
Menu navigation, failed insertion, retry and Resume. Dart analysis and
English and Turkish translation validation passed.

A separate Windows headless run used the pinned SwanStation 1.0.0
631f0fb DLL in software mode at 1x. Metal Gear Solid changed discs
1 to 2 and back to 1. Final Fantasy VII changed discs 1 to 2 to 3 and
back to 1. Each swap reported the requested disc while the frame counter
stayed fixed, and each game resumed on its existing session. Each run
created exactly one 128 KiB memory card named after the original
playlist. A second run seeded known bytes into those scratch cards
and confirmed both full file hashes stayed identical after swapping
and closing. Both runs used temporary BIOS and save storage. A story
prompt that requests a different disc and a physical controller still
need interactive verification.
