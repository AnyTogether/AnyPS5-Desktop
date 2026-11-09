# AnyPS5 Desktop embedded PS3 Vulkan preview

This review slice builds on [the embedded PS1 and PS2 host](<AnyPS5 Desktop - Embedded PS1 and PS2.md>).
On Windows and Linux x64, a verified RPCS3 Libretro package runs an extracted PS3 disc
in the launcher's existing window. The standalone RPCS3 option remains
available in Settings. This preview does not use PS3 firmware download services.

For PS3-only review, [compare the PS3 branch against the PS1/PS2 branch](https://github.com/B-Howell/AnyPS5-Desktop/compare/codex/pr84-embedded-ps12...codex/pr84-embedded-ps3).
The combined build sends PS1 playlist selection and swaps through the same
runner channel as PS3 sessions. The PS3 core uses Vulkan and reports compilation
progress through that channel. PS3 leaves the PS1 disk-control callbacks unused.

The combined host passed 29 focused Flutter tests and the native test suite
on Windows and Ubuntu 22.04 WSL. Headless Windows probes booted Metal Gear
Solid and Final Fantasy VII directly on Disc 2 and retained one memory card
per title through swaps. A separate probe of the same host booted LittleBigPlanet
GOTY with Vulkan and stereo PCM, then changed resolution from 1280 × 720 to
1920 × 1080 in the same session.

## Build the Windows review package

Use a disposable [MSYS2](https://www.msys2.org/) installation. The pinned
[upstream CLANG64 recipe](https://github.com/WizzardSK/rpcs3-libretro/blob/74b3fa37beb294418230b1f039bab4de97f18479/.ci/build-windows-clang-libretro.sh)
replaces several import archives with static libraries. Run the commands
in CLANG64 after updating that installation, and use a short, new build path.

```bash
pacman -S --needed base-devel curl git p7zip \
  mingw-w64-clang-x86_64-{clang,cmake,lld,ninja,llvm,nasm,pkgconf,opencv,glew,vulkan-headers,vulkan-loader}
bash tool/build-rpcs3-preview.sh /c/anyps5-ps3-review
```

The [package builder](../tool/build-rpcs3-preview.sh) pins RPCS3 Libretro,
FFmpeg and Abseil by commit. RPCS3 submodules follow the pinned tree. Its
[frontend patch](../tool/patches/rpcs3-libretro-frontend.patch) forwards
compilation progress to AnyPS5, reports active controller ports and
restricts offline peer-to-peer traffic to loopback. MSYS2 dependencies,
ZIP metadata and the optional upstream game-patch database can vary
between builds. The builder records MSYS2 package versions and writes
`packages/rpcs3_libretro.dll.zip` and `packages/ps3-core-digests.txt`.
The [checkout attributes](../.gitattributes) preserve LF line endings for
the builder and patch.

## Build the Linux review package

Use an amd64 OCI runner and the pinned Ubuntu 22.04 image used by the RPCS3
Libretro build. From the launcher checkout:

```sh
out="$(mktemp -d)"
docker run --rm --platform linux/amd64 --user "$(id -u):$(id -g)" \
  -e HOME=/tmp -v "$PWD:/src:ro" -v "$out:/out" \
  rpcs3/rpcs3-ci-jammy@sha256:e5f21d10b6e897d578537776877690c75879d0bf0bd4e2745c06588d580d53ff \
  bash /src/tool/build-rpcs3-preview.sh /out/ps3-linux
```

The Linux builder verifies the pinned FFmpeg archive from the upstream
Linux recipe. It checks the SO's exported Libretro entry points, dynamic
dependencies and glibc version before packaging. The output under
`$out/ps3-linux/packages` includes `rpcs3_libretro.so.zip` and its ZIP/SO digests.
On Ubuntu 22.04, the core needs `libvulkan1`, a Vulkan ICD such as
`mesa-vulkan-drivers`, `libegl1`, `libopengl0`, `libasound2`, `zlib1g`
and `libgcc-s1`. Install the regular launcher build dependencies for the GTK
and audio runner.

## Test from a fresh profile

Build the Windows launcher with `flutter build windows --release`. The
runner fetches a pinned, hash-verified Vulkan-Headers snapshot during
CMake configuration and uses the Vulkan loader from the graphics driver
at runtime. In a fresh PowerShell session, set these process-local
variables before starting that build. On Linux use `flutter build linux --release`
and a fresh set of XDG paths.

```powershell
$env:APPDATA = 'C:\anyps5-ps3-clean\Roaming'
$env:LOCALAPPDATA = 'C:\anyps5-ps3-clean\Local'
$env:ANYPS5_PS3_CORE_DIGESTS = (Get-Content 'C:\anyps5-ps3-review\packages\ps3-core-digests.txt' -Raw).Trim()
& .\build\windows\x64\runner\Release\anyps5_desktop.exe
```

On Linux:

```sh
profile="$(mktemp -d)"
export XDG_CONFIG_HOME="$profile/config" XDG_DATA_HOME="$profile/data"
export XDG_CACHE_HOME="$profile/cache" XDG_STATE_HOME="$profile/state"
export ANYPS5_PS3_CORE_DIGESTS="$(cat "$out/ps3-linux/packages/ps3-core-digests.txt")"
./build/linux/x64/release/bundle/anyps5_desktop
```

1. Finish regular launcher onboarding. For a PS3-only check, skip the PS5
   engine and choose Offline.
2. Open **Settings → Emulators**, select the embedded PS3 installation
   row and point the picker to the ZIP built above.
3. Use the **PS3 firmware** row to choose your local `PS3UPDAT.PUP`.
   The launcher validates and stages the file. RPCS3 installs it at first boot.
4. Add the directory containing your extracted PS3 disc under **Settings
   → Game Library**. Play the game. Compilation should stay on one AnyPS5
   card and show a percentage as the core reports one. New progress updates
   extend the three-minute inactivity limit, up to a 15-minute total.
5. Press PS or Escape to open Quick Menu. Resume returns to the same
   session. During play, Game Settings exposes resolution scale and
   anisotropic filtering. The pre-launch title settings group the
   boot-time graphics, CPU, I/O, and audio choices by category.
6. Open the title's trophy list to see trophy metadata from its disc
   package. Unlocks in the managed RPCS3 profile are refreshed when you open
   Trophies or end play.

The [package and firmware manager](../lib/core/managed_retro.dart) validates
the ZIP and library separately and rechecks the installed library at launch.
The default digests identify the exact Windows and Linux preview packages.
For your own build, use the ZIP and library SHA-256 pair emitted by the
builder. The digest override applies only to RPCS3. The [launcher setup](../lib/ui/embedded_emulators.dart)
uses the existing embedded session contract and the [PS3 option
catalogue](../lib/ui/ps3_settings_model.dart). The [trophy
reader](../lib/core/ps3_trophies.dart) reads the disc's trophy configuration
and locally earned unlocks. Its [fixture tests](../test/core/ps3_trophies_test.dart)
cover trophy parsing without the reviewer's game files.
The [session contract tests](../test/ui/embedded_ps3_session_test.dart) cover
local PUP staging, compile progress, section navigation, live setting
persistence and release.

The [shared Vulkan adapter](../native/retro/retro_vulkan_video.cpp)
and [factory](../native/retro/retro_vulkan_video.h) negotiate the device and
copy completed frames for the Flutter texture. The [native build](../native/retro/CMakeLists.txt)
pins the Vulkan headers. The [Linux GTK adapter](../linux/runner/retro_core_host_linux.cc)
selects Vulkan for PS3 and forwards the worker's progress. Windows PS1 and
PS2 use D3D11, and Linux PS1 and PS2 use EGL/OpenGL. The same
[worker](../native/retro/retro_session.cpp) handles loading, input, audio and
teardown for all three consoles.

## Stock core comparison

RetroArch served as an independent frontend for the stock-core boot test.
AnyPS5 loads RPCS3 directly through Libretro and needs no RetroArch installation.

The Windows Buildbot DLL with SHA-256
`27ad0dccc2b9c464b7fa78c60cc4ce1717e2c31ca31836f337e2981bb9efe64b`
booted the same LittleBigPlanet disc in a separate RetroArch control. It
opened a wildcard UDP socket in that run. The stock core lacks the
launcher's compilation-progress callback and the patch's offline network
and controller-port handling. The default pin in this preview is for
the patched core. A public package choice belongs to the maintainers.

## Platform and release gates

- The embedded preview covers Windows and Linux x64. Linux standalone RPCS3
  remains available.
- The native macOS launcher is Swift and needs its companion port and
  testing under the maintainer's direction.
- A public one-click core install still needs maintainer approval for
  the RPCS3 fork and patch, immutable package hosting, corresponding
  source distribution and signed-off per-platform hashes. Firmware is
  provided by the user.
- Full desktop interaction and long gameplay runs are separate from the
  headless core and launcher contract checks.


## Verification

In a new Windows scratch profile, the Dart installer verified the cold-built
ZIP and DLL and staged a byte-identical copy of the selected PUP. The shared
native host installed that firmware and cold-booted LittleBigPlanet Game of
the Year Edition with the exact rebuilt DLL. The first Vulkan frame arrived
between roughly 187 and 193 seconds. The run recorded 87 distinct compile
percentages, captured 228 frames at 1280 × 720 and 502,272 stereo PCM frames
with nonzero samples, then shut down cleanly. Sampled UDP activity was
loopback only. The run used an in-memory frame and audio sink with no window.
A warm replay changed the scale from 100% to 150% in the same session.
Vulkan output changed from 1280 × 720 to 1920 × 1080 within about 1.3 seconds
and PCM delivery continued.

The trophy reader loaded 59 definitions directly from the LittleBigPlanet
disc's trophy package. The fixture also covers local unlock parsing.

Native CTest passed on Windows and Ubuntu 22.04. MSVC compiled the Windows
runner adapter and Vulkan bridge with warnings treated as errors.

The Windows Flutter regression run had 48 passes and nine platform skips.
The Turkish Settings screenshot differed from its golden by 101,530 pixels.
Repeating that test on the unchanged PS1/PS2 base produced the same
difference and byte-identical actual and diff images. Hosted macOS
goldens still need their own run. Scoped Dart analysis and the English
and Turkish translation checks passed.

### Linux headless qualification

The pinned Linux SO loaded as Libretro API 1 on Ubuntu 22.04. The ELF
requires glibc 2.35 or earlier and has no GLIBCXX version requirement
or X11/Wayland dependency. The builder links a private C++ runtime with
its archive symbols hidden. The host process kept the system libstdc++.

The Linux Dart installer verified the exact ZIP and SO and staged a
byte-identical local PUP in a clean scratch profile. The launcher pin
matched the installed SO. The shared worker installed firmware, emitted
86 distinct compile percentages and cold-booted LittleBigPlanet GOTY
into its game intro. The first game frame arrived at about 212 seconds.
After 190 frames at 1280 × 720, the test paused and confirmed emulation
steps stopped. It set the live scale to 150% while paused and resumed the
same session. Output reached 1920 × 1080 in 1.27 seconds while stereo PCM
continued with nonzero samples. The session shut down without an error.
Two additional warm sessions in the same host process both rendered,
paused, switched live resolution and stopped cleanly.

The run used Mesa lavapipe and in-memory frame and audio sinks with no
desktop display. A stock Linux core control reached Vulkan startup frames
with a replacement libstdc++ in its scratch environment. That control
only qualified the loader and readback. The patched package used the
regular Ubuntu 22.04 system runtime.

The Linux GTK channel adapter compiled against Flutter Linux engine and
GTK headers. Native CTest passed on Windows and Linux, and the Windows
focused Flutter run passed 16 tests, including the Linux ZIP/SO install
and corruption checks. Full GTK window presentation and hosted runner
builds remain separate checks.
