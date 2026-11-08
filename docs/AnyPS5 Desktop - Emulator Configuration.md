# AnyPS5 Desktop emulator configuration

This Windows x64 preview adds optional PS1, PS2 and PS3 support to the PS5
launcher. It uses the existing Home, library, controller navigation and
Quick Menu. Emulator setup stays under Settings. On Windows x64 the
existing onboarding library step adds a Skip option for users who want
to configure a library later.

## Set up a console

1. Open **Settings → Emulators → PS1**, **PS2**, or **PS3**, then **Setup**.
2. Select the embedded emulator. PS1 uses SwanStation and PS2 uses LRPS2.
   PS3 uses a verified RPCS3 Libretro package and needs a Vulkan driver.
3. For PS1 or PS2, select a BIOS dumped from your console. The launcher
   imports a private copy. PS3 Setup downloads Sony's official firmware
   after the RPCS3 package has been verified.
4. Optionally select a games folder. Setup shows its path and a preview
   of the recognized games. **Finish setup** returns to Home, including
   when the folder is empty.

[Managed setup](../lib/core/managed_retro.dart) installs Windows x64 cores
into launcher storage. The PS1 and PS2 prototype uses Libretro Buildbot
over HTTPS, validates the archive's expected size and the indexed DLL CRC,
and checks SHA-256 for known archive revisions. Before a general release,
the maintainers should decide how to pin, verify and license core
distribution. Cores, games, BIOS images, firmware and memory cards are
separate from the launcher source.

## Library and media

The [library scanner](../lib/core/game_library.dart) recognizes PS1 CUE
sheets with their tracks, M3U playlists, PBP images and CHDs. It recognizes
PS2 DVD dumps with a PS2 boot marker and PS2 CHDs. Use a console-named
root to disambiguate CHDs or supply a manifest. The
[PS3 disc reader](../lib/core/ps3_disc.dart) recognizes extracted disc
folders with PS3_DISC.SFB and PS3_GAME. Extract archives before scanning.

An optional retro.json beside a PS1 or PS2 image can supply the platform,
title ID, name and media. Paths are relative to that title's folder.

```json
{
  "platform": "ps1",
  "titleId": "SCUS00000",
  "name": "My game",
  "disc": "game.cue",
  "icon": "cover.png",
  "background": "wallpaper.jpg",
  "music": "theme.wav"
}
```

For PS3, cover.webp, cover.png or cover.jpg at the disc root takes
precedence over PS3_GAME/ICON0.PNG. Per-title wallpapers and music come
from local media. The [selection audio player](../lib/core/audio/theme_music.dart)
can also play one optional local WAV per console from ConsoleAudio in the
launcher config folder, using ps1-startup.wav, ps2-startup.wav and
ps3-startup.wav. Moving into the game row selects the game's usual music.

**Settings → Emulators → Show as folders** puts each installed console
after the regular games on Home. Highlight a console to preview its
titles, then press Down to enter the row or Up to return. Before a core is
installed, its games remain individual tiles so First Play can offer
setup. The [folder projection](../lib/ui/retro_home_folders.dart) uses real
library titles and preserves their IDs. Console indicators in this
submission use text labels. Experiment artwork stays in its local profile.

## Play and tune

Press PS/Guide or Escape to open the Quick Menu over the embedded game.
Resume and Close return to the same session. Losing focus clears held
inputs. Settings for existing portable DuckStation and PCSX2
installations remain available as an advanced path.

| Core | Controls exercised in the same session |
| --- | --- |
| SwanStation | Internal resolution and texture filtering |
| LRPS2 | Internal resolution, anisotropic filtering and trilinear filtering |
| RPCS3 | Internal resolution and anisotropic filtering |

The [Windows host](../windows/runner/retro_core_host.cpp) retains the last
frame when applying settings that require an in-memory checkpoint.
SwanStation restores the checkpoint after changing its active renderer.
LRPS2 reopens its core for a resolution change and restores the checkpoint
behind the same Flutter texture. The launcher saves a selected resolution
after the new frame is available. RPCS3's tested live options use its
existing Vulkan device.

[Tune This Game](../lib/ui/retro_game_tuning.dart) measures a baseline and
a temporary candidate while the player repeats the same section. It
restores the baseline before offering Apply. The comparison uses frame
pacing and audio telemetry. Check the image yourself before applying a
candidate. [Restart Trials](../lib/ui/retro_restart_workflow.dart) are a
separate path for startup settings such as CPU or renderer selection.
Save in-game first for those trials. The menu marks startup-only settings.

## RPCS3 preview and release gates

The [frontend patch](../tool/patches/rpcs3-libretro-frontend.patch) relays
compilation progress, reports active controller ports and confines offline
peer-to-peer traffic to loopback. The [package builder](../tool/build-rpcs3-preview.sh)
uses the [RPCS3 Libretro Windows CLANG64 recipe](https://github.com/WizzardSK/rpcs3-libretro/blob/74b3fa37beb294418230b1f039bab4de97f18479/.ci/build-windows-clang-libretro.sh).
It pins RPCS3 Libretro, FFmpeg and Abseil by commit. RPCS3 submodules follow the
pinned tree. MSYS2 dependencies and upstream's optional embedded game-patch
database can change between builds. The builder records the MSYS2 versions.
Its output is a reviewer build with its own digests.

### Build a PS3 test package

Use a disposable [MSYS2](https://www.msys2.org/) installation. The upstream
recipe replaces several CLANG64 import archives with static libraries, so
keep this install separate from your normal development toolchain. Update
MSYS2 first, then run these commands in its **CLANG64** shell from a checkout
of this PR. Use a short build path with space for the compiler outputs.

```bash
pacman -S --needed base-devel curl git p7zip \
  mingw-w64-clang-x86_64-{clang,cmake,lld,ninja,llvm,nasm,pkgconf,opencv,glew,vulkan-headers,vulkan-loader}
bash tool/build-rpcs3-preview.sh /c/anyps5-ps3-review
```

The output path must be new. The resulting `packages` directory contains
`rpcs3_libretro.dll.zip` and `ps3-core-digests.txt`. Keep the two SHA-256 values
from your own build. The installer verifies the ZIP before extraction and
checks the DLL before publishing it and at subsequent launches. The default
test package hashes still apply when no digest override is configured.
The [checkout attributes](../.gitattributes) keep the shell script and patch
in LF format on Windows.

Build the launcher as described below, then set the reviewer environment in
PowerShell and start the launcher from the same shell. Use a new profile path.

```powershell
$env:ANYPS5_DESKTOP_EXPERIMENT_HOME = 'C:/anyps5-ps3-clean-profile'
$env:ANYPS5_MANAGED_CORE_PACKAGES = 'C:/anyps5-ps3-review/packages'
$env:ANYPS5_PS3_CORE_DIGESTS = (Get-Content "$env:ANYPS5_MANAGED_CORE_PACKAGES/ps3-core-digests.txt" -Raw).Trim()
& .\build\windows\x64\runner\Release\anyps5_desktop.exe
```

Finish normal launcher onboarding. For a PS3-only test, skip the games
folder and PS5 engine steps and choose Offline. Open
**Settings → Emulators → PS3 → Setup**, install the core and let the
launcher fetch the checksum-verified official Sony firmware. Add a folder
containing your extracted PS3 disc and finish setup. On the first launch,
check compilation progress, the embedded viewport and PS/Guide or Escape
opening the Quick Menu. Resume should return to the same session.

For a public one-click install, the maintainers need to approve the RPCS3 fork
and patch, where to publish the package and its corresponding source and
notices, and how to pin and update the downloadable ZIP and DLL. The reviewer
workflow uses a local build and explicit hashes. It needs no published binary.

The [Vulkan bridge](../windows/runner/retro_vulkan_video.cpp) presents the
RPCS3 frame to Flutter and rejects synchronization it cannot support.
The [trophy reader](../lib/core/ps3_trophies.dart) reads PS3 definitions and
the local RPCS3 profile. LittleBigPlanet GOTY definitions and a controlled
unlock record were read in the experiment. That does not establish
physical-controller trophy unlocks or broad game compatibility.

## Build and verify

Use the Flutter version in the [upstream CI workflow](../.github/workflows/ci.yml)
with the Windows Desktop C++ toolchain. A fresh
[Windows runner build](../windows/runner/CMakeLists.txt) fetches pinned,
hash-verified Vulkan headers. Run `flutter pub get`, `flutter analyze`
and `flutter build windows --release` from the repository root. For a
separate local test profile, set ANYPS5_DESKTOP_EXPERIMENT_HOME to an
absolute scratch directory before launching. The profile has its own
config, emulator storage and logs, and skips desktop file and URL
registration.

## Verification and suggested review order

The local experiment exercised installation with empty profiles and
manual and tuner graphics transitions offscreen. Crash Bandicoot 2
reached its first warp room. Vice City and LittleBigPlanet verification
covered the opening sequence and tutorial. These are representative
checks, not a compatibility matrix. The upstream draft is a separate
port and should be tested on its own commit.

The [package installer tests](../test/core/managed_retro_test.dart) cover
missing packages, invalid pins, ZIP and DLL mismatches, and retrying with
an installed core. Use a new profile root for the manual PS3 acceptance run.

Start review with Windows PS1 and PS2 library, setup and embedded
controls. Review the PS3 host and packaging separately. Keep core-license
compatibility, reproducible packages and complete upstream CI as release
gates. PS5 and Linux behavior require regression coverage on the proposed
branch.
