# AnyPS5 Desktop

The [AnyPS5-ARM](https://github.com/AnyTogether/AnyPS5-ARM) launcher, ported to **Windows** and
**Linux** with Flutter: the same PS5-style home screen, library, unlocking, controls, trophies,
saves and phone controller, for the PCs [AnyPS5](https://github.com/boykopovar/AnyPS5) runs on.

**Status:** in development. The logic and the interface are tested headlessly (unit, widget and
golden tests); native Windows and Linux builds and a real game run are being checked now.

AnyPS5 runs PS5 game dumps on PCs: the upstream relinker turns a game's executable into a
native Linux ELF or Windows PE, linked against AnyPS5's own implementations of the system
libraries (`libs/*.prx`). This launcher does what the macOS launcher does, for those two
systems: it finds dumps in a games folder, unwraps their SELF executables, runs the relinker
for the host, lays out the game with the system libraries, starts it, and keeps controls,
settings, saves and trophies per game. A phone running the AnyPS5 Remote app pairs with it and
works as a controller (the protocol in section 12.4 of the
[AnyTogether platform notes](https://github.com/AnyTogether/AnyPS5-ARM/blob/anytogether/docs/en/12-platforms.md)).

A phone without the app plays too: **Settings › Phones › Show QR code**, scanned with the
phone's camera, turns its browser into a touch DualSense (sticks, D-pad, face buttons, L1/R1,
L2/R2, Options, Create, PS, touchpad, the game's light bar and rumble where the browser can
vibrate). The browser goes through the same pairing card, seats (players 2 to 4) and pad relay
as the app. The link works once for two minutes and becomes a cookie for that browser; the page
is served on the local network address only, to the local network only, refusing other sites and
hosts, with rate limits; the server runs only while the code is shown and its browsers are
connected, or always with Keep browser play on. Plain HTTP, so no tilt (browsers give motion
sensors to HTTPS pages only). The page is the macOS launcher's own file
(`assets/browser_pad/index.html`, copied by `tool/sync_browser_pad.sh`).

**Languages:** English, Turkish, German, Spanish, French, Portuguese, Indonesian, Russian,
Japanese, Hindi, Bengali, Bhojpuri, Arabic and Urdu, one JSON file each in `assets/l10n`. Arabic
and Urdu read right to left, but the screens are not mirrored yet. A new language is one more
file there, no code: see [TRANSLATING.md](TRANSLATING.md).

## Install

Every [release](https://github.com/AnyTogether/AnyPS5-Desktop/releases/latest) has the Windows
installer (`AnyPS5-Desktop-Setup-<version>-x64.exe`, per user, no administrator rights), a
portable Windows zip, an AppImage, a `.deb` and a `.tar.gz`, with `SHA256SUMS` and its signature.

**Windows with [Scoop](https://scoop.sh)** (the portable zip, with a Start menu shortcut):

```powershell
scoop bucket add anytogether https://github.com/AnyTogether/scoop-bucket
scoop install anytogether/anyps5-desktop
```

Update it with `scoop update anyps5-desktop`. The launcher sees that Scoop installed it: it still
says when a new version is out, with that command (Settings › About copies it), and never downloads
or runs the installer itself. Version 0.1.20 and earlier do not: on those, turn off **Settings →
Behaviour → Check for updates**, since their update puts a second copy in
`%LOCALAPPDATA%\Programs\AnyPS5 Desktop`.

**Windows with winget** (the installer; pending review in
[microsoft/winget-pkgs#476211](https://github.com/microsoft/winget-pkgs/pull/476211), so it works
once that is merged):

```powershell
winget install AnyTogether.AnyPS5Desktop
```

The launcher's own updates run the same installer, so winget and the launcher keep one copy.

**Linux:** clips and voice notes play inside the launcher through the system's libmpv, which
the packages do not carry. The `.deb` brings it from apt (`libmpv2`, or `libmpv1` on Ubuntu
22.04) and the Arch package depends on `mpv`. With the AppImage or the `.tar.gz`, install it
yourself:

```sh
sudo apt install libmpv2        # Ubuntu 24.04, Debian 12 and newer (Ubuntu 22.04: libmpv1)
sudo dnf install mpv-libs       # Fedora
sudo pacman -S mpv              # Arch Linux
sudo zypper install libmpv2     # openSUSE
```

Without it the launcher still starts and works. A clip shows its picture with the command for
your distribution and a button that opens it in another player, and voice notes open in the
system's player.

**Arch Linux:** the `anyps5-desktop-bin` package (the release's `.deb`, repacked) is in
[AnyTogether/linux-packages](https://github.com/AnyTogether/linux-packages). It is not on the AUR
yet. Build it from there with `makepkg -si` in `aur/anyps5-desktop-bin`. The launcher sees that
pacman owns it: it says when a new version is out and leaves the update to the package manager.

The Scoop manifest and the Arch package follow the latest stable release by themselves: a
scheduled workflow in each repository moves them within six hours of a release.

The [standalone emulator library](<docs/AnyPS5 Desktop - Standalone Emulator Library.md>)
can open PS1, PS2 and PS3 games in an emulator you have already installed.

## Layout

- `lib/core/` platform-independent logic in pure Dart (no Flutter), unit tested:
  - `game_library.dart` dumps in a games folder (param.json names per language, version,
    icon0/pic0/snd0, executable kind)
  - `self_unwrap.dart` SELF/fSELF to ELF, byte-identical to upstream `tools/unwrap_self.py`
  - `installer.dart`, `toolkit.dart`, `file_links.dart`, `host.dart` unwrap, relink, lay out
    (links through FFI: `link(2)` / `CreateHardLinkW` / `CreateSymbolicLinkW`), carry saves
    over, start
  - `toolkit_download.dart` the AnyPS5 engine from upstream's GitHub releases: resumable,
    checksum-checked downloads, safe unpacking, one toolkit folder per version
  - `game_settings.dart`, `controls.dart` per-game choices, the game environment and
    `anyps5-input.ini`
  - `game_log.dart`, `crash_report.dart` capped per-game logs, detailed logging (the engine's
    trace switches), the crash report of a game's last start with personal details taken out,
    and the pre-filled GitHub issue for it
  - `remote/` the phone server (WebSocket 47700, pairing, UDP pad relay, cable frames), an
    mDNS responder for `_anyps5-remote._tcp`, the adb and usbmuxd (iPhone) cable tunnels
    and the browser pad server (HTTP and WebSocket 47710 on the LAN address: one-time token,
    session cookie, each browser a phone on the phone server's own control channel)
  - `trophies.dart`, `save_backup.dart`, `screenshots.dart` (a game's F12 and trophy pictures,
    a small PNG encoder)
  - `gamepad/` controllers as launcher commands (`pad_navigation.dart`: the mapping, repeat on
    hold, several pads), read with XInput and winmm on Windows (`windows_pads.dart`) and evdev
    on Linux (`linux_pads.dart`), through FFI
  - `desktop/` the game's window and the trophy card over it: Win32 through FFI on Windows
    (foreground, F11 and window size for upstream's engine, the window's picture, a layered
    click-through topmost card), Xlib on Linux X11 (override-redirect card, XGetImage), and
    on Wayland the runner's layer-shell surfaces (`linux/runner/layer_overlay.cc`, gtk-layer-shell
    loaded at run time where the compositor has wlr-layer-shell) or a desktop notification (GNOME)
  - `themes/` the Theme Studio's themes (`theme_design.dart`, `theme_library.dart`): one folder
    each under the config folder's `Themes`, shared as one `.anyps5theme` zip, the same file as
    the macOS launcher's; `looping_video.dart` a background video looped through ffmpeg;
    `opened_files.dart` theme files the launcher is started with (handed to a launcher already
    open over `link_relay.dart`);
    `desktop/file_types.dart` `.anyps5theme` registered for the zip, the AppImage and the archive
  - `update_channel.dart` Settings › About › Update Channel (Stable or Nightly) and the macOS
    launcher's order of versions, a nightly before the release it leads to
  - `package_install.dart` whether Scoop or pacman installed this copy (a Scoop app folder, or a
    file pacman's database lists): the launcher's own update then only says a new version is out
  - `audio/` the interface sounds (the macOS launcher's tones, synthesized sample for sample),
    a game's theme song (`snd0.at9` decoded with LibAtrac9 through FFI) and the music's fades
  - `capture/` the game's picture and sound sent somewhere: Remote Play to the phone (the
    macOS launcher's packets, `stream_packet.dart`), broadcasting to Twitch, YouTube or RTMP
    (`broadcast.dart`), and the encoders the replay buffer shares. All record with ffmpeg
    (gdigrab on Windows, x11grab on X11) and encode on the graphics card when ffmpeg has an
    encoder that works there (NVENC, Quick Sync, AMF, VA-API), x264 otherwise. The sound is
    WASAPI loopback of the game's process tree on Windows (`native/capture`) and PulseAudio's
    `parec` on the game's stream on Linux
- `native/atrac9/` LibAtrac9 (MIT), built by `hook/build.dart` into a small shared library
  beside the launcher (MSVC on Windows, the system compiler on Linux and for `flutter test`);
  `native/capture/` the game's sound on Windows (WASAPI loopback), built the same way
- `lib/ui/` the PS5-style interface: home row, hero, library grid, settings panels, controls,
  trophies, onboarding, pairing card; `shaders/background.frag` is the macOS launcher's Metal
  background shader in GLSL (cosmic, aurora, sunset); `soloud_audio.dart` plays the sounds
  through `flutter_soloud` (miniaudio: WASAPI on Windows, PulseAudio or ALSA on Linux).
- `assets/l10n/` every text, one JSON file per language (`T.text` in `lib/ui/strings.dart`
  reads them through the asset manifest; English for a text a language lacks);
  `tool/check_translations.dart` checks them in CI ([TRANSLATING.md](TRANSLATING.md)).
- `test/` unit, widget and golden tests; `test/support/` synthetic fixtures (made-up dumps,
  SELF containers, PNGs, trophy packages, a fake relinker and adb, and the phone app's own
  protocol code as the fake phone). No real game files.
- `tool/anyps5_tool.dart` the pipeline on the command line (unwrap, scan, install, play, a
  headless phone server) for checks on a Windows or Linux machine without the interface;
  `tool/docker/linux-build.Dockerfile` a headless Linux build check.

## Working on it

```sh
flutter pub get
flutter analyze
flutter test                         # everything, headless (about 35 s)
flutter test --update-goldens        # re-render the golden images in test/ui/goldens
flutter build linux                  # on a Linux host (or the Docker check below)
flutter build windows                # on a Windows host
dart run tool/anyps5_tool.dart unwrap eboot.bin eboot.elf
dart run tool/anyps5_tool.dart engine --folder ~/toolkits   # upstream's latest toolkit for this system
ANYPS5_TOOLKIT=~/toolkit dart run tool/anyps5_tool.dart install ~/Games/PPSA01234 ~/Games
dart run tool/anyps5_tool.dart remote --allow-all   # a phone server until Ctrl-C
dart run tool/check_translations.dart   # the language files: keys, placeholders, coverage
```

The SELF test compares the Dart unwrapper with upstream's Python script on 300 random
containers when `python3` and the script are present (`ANYPS5_UNWRAP_SELF_PY` points at it).

## The toolkit

The launcher needs an AnyPS5 toolkit (the "AnyPS5 engine") built for the host. **It downloads
itself on first start:** the onboarding's last step offers *Download the AnyPS5 engine*, which
reads [boykopovar/AnyPS5](https://github.com/boykopovar/AnyPS5/releases)'s latest release from
GitHub's API and takes the two files for this system:

| System  | Relinker              | System libraries                                   |
| ------- | --------------------- | -------------------------------------------------- |
| Windows | `relinker-v<ver>.exe` | `prx-windows-v<ver>.zip` (the `.tar.gz` if missing) |
| Linux   | `relinker-v<ver>`     | `prx-linux-v<ver>.tar.gz` (the `.zip` if missing)   |

Downloads go into `.part` files that carry on after a dropped connection or a restart; each
file's size and the sha256 digest GitHub publishes for it are checked (a file without a digest
is only used after the user agrees). The archive is unpacked without letting any name or link
leave its folder, the folder holding the `.prx` files becomes `libs/` (0.1.0 had them at the
archive's top, later releases in `libs/`), the relinker is renamed and made executable, and
`version.txt` says `upstream-v<ver>`. Toolkits live in `%LOCALAPPDATA%\AnyPS5\Toolkits\<ver>`
(Windows) or `$XDG_DATA_HOME/AnyPS5/Toolkits/<ver>` (`~/.local/share/...`, Linux).

Settings → AnyPS5 Engine shows the engine in use, checks for updates, lists the versions
GitHub has and the downloaded ones (switch to one, or download an older one), deletes the
others, or takes a folder of your own. The launcher keeps the engine in use, the two newest
and the ones installed games were made with, and deletes the rest after a download. At start
it looks for a newer engine; when one is out, installed games show the usual update offer, and
*Update and Play* downloads the engine first, then unlocks the game again.

A toolkit of your own (a fork's build, say) is chosen with *I have my own folder* in the
onboarding or *Use my own folder* in Settings, or given with `ANYPS5_TOOLKIT`:

```text
toolkit/
    relinker            (relinker.exe on Windows)
    libs/*.prx          system libraries built for the host (plus the mingw DLLs on Windows)
    version.txt         changes when the relinker or libraries change; games made with an
                        older one are offered an update
    patches/<TITLE>.toml   optional relinker patch files; entries named width and height make
                        the per-game resolution choice
```

### Update from Git

The engine folder can also be a **git checkout of the engine's source** (upstream's AnyPS5 or
AnyPS5-ARM) built with CMake: choose the checkout's top folder. The launcher spots it
(`CMakeLists.txt`, `core/relinker/`, `core/libs/`, `.git`) and takes the relinker from
`build/core/relinker/relinker[.exe]` and the libraries from `build/core/libs/libs/` (another
configured folder at the top, `build-*` or `cmake-build-*` with a `CMakeCache.txt`, when
`build/` is not one). On Windows the MinGW runtime DLLs come from the compiler's folder that
`CMakeCache.txt` names, and that folder is put first on `PATH` for the relinker.

Settings → AnyPS5 Engine → *Update from Git* then runs, in the checkout:

```text
git pull --ff-only
git submodule update --init --recursive
cmake --build <build folder> --target relinker libs
```

It refuses a tree with uncommitted changes (`git status --porcelain`), says so when git or CMake
is missing, and never configures a build folder itself: without one it points to the
[build guide](https://github.com/AnyTogether/AnyPS5-ARM/blob/main/docs/dev/WINDOWS_LINUX_ENGINE.md).
The row shows the step and the last lines printed, and selecting it stops the update; a failure
keeps the end of the output, copied with one select. git never prompts (`GIT_TERMINAL_PROMPT=0`,
SSH in batch mode), so a remote that wants a password fails instead of hanging. The build changes
the folder's fingerprint, so installed games offer *Update and Play*; *Relink all installed games
now* unlocks them all again at once.

*Update from Git before playing* (off by default) runs `git fetch` before a game starts and,
when the remote has new commits (or the checkout was pulled by hand since the launcher last
built it), pulls and builds first, then unlocks the game again and starts it. Offline, or with no
upstream branch, it says nothing and the game starts; when nothing could be pulled (uncommitted
changes, no CMake) the current build plays and the reason is shown; a failed build starts
nothing. The *Upstream* engine choice is different: it downloads upstream's release builds and
never touches a clone of yours.

Some environment variables the launcher passes exist only in the fork's engine
(`ANYPS5_FULLSCREEN`, `ANYPS5_WINDOW_SIZE`, `ANYPS5_OVERLAY_STYLE`, `ANYPS5_FRAME_GEN`,
`ANYPS5_REMOTE_PAD*`); with upstream's libraries they are ignored. For full screen and window
size the launcher stands in: with upstream's engine (which opens at 60% of the screen and
switches with F11) it sizes the game's window once it opens, or presses F11 for it.

Settings → AnyPS5 Engine → *Engine* switches to the **AnyPS5-ARM engine**: the fork's toolkit,
built for Windows (and Linux, when published) and attached to
[AnyPS5-ARM's releases](https://github.com/AnyTogether/AnyPS5-ARM/releases) as one archive,
`AnyPS5-toolkit-<windows|linux>-<commit>.zip` (relinker, `libs/`, `version.txt`). The launcher
takes it from the newest release that has one, checks it against the release's signed
`SHA256SUMS`, and keeps it as `Toolkits/arm-<commit>` with `version.txt` `arm-<commit>`. That
engine reads the variables above itself, including the phone controller's bridge.

On Linux the launcher reads the glibc version the engine's libraries ask for (their ELF version
needs) and compares it with the system's: upstream v0.1.3's Linux libraries need glibc 2.38
(Ubuntu 24.04, Debian 13), so on Ubuntu 22.04 (2.35) Settings › AnyPS5 Engine, the download and
every unlock say "Games need glibc 2.38 or newer; this system has 2.35". Games are still
unlocked; they would not start there.

## AnyTogether

The launcher signs in to [AnyTogether](https://github.com/AnyTogether/AnyTogether), the AnyPS5
online layer (Settings → AnyTogether): with a code sent by email, with a code approved on the
website (it opens in the browser; passkeys and the website's other sign-ins work there), or with
the paired phone, which approves the launcher with one tap when it is signed in (the phone
protocol's `togetherHandoff` / `togetherHandoffAnswer`, both ways). Another server can be chosen
there; `ANYTOGETHER_URL` overrides the choice. Code: `lib/core/together/`.

Signed in, the launcher is online for friends (in a game, with its title ID, while one runs),
and each play session and every trophy earned goes to AnyTogether through an outbox on disk
(`Together/outbox.json` in the config folder): playing offline loses nothing and nothing counts
twice. Rules as the macOS launcher's: this computer is registered first (`windows`/`linux`),
then the game's name, its trophy set (keyed by a hash of its trophies and grades, a trophy's ID
being the package's service label × 1000 plus its number), the sessions (more than 5 s), the
earned trophies.

The top bar's friends, messages and party buttons open the friends panel (requests, adding by
handle, what each friend plays), the messages (conversations and friends on the left, the thread
on the right with quick replies a controller can send and a field to type in, typing shown both
ways) and the party (start one, invite, walk into a friend's open party, its voice). Voice is the
website's protocol: the call from `/calls` with its relays, offers and candidates through the
gateway, a mesh of peer connections with Opus tuned for voice, through `flutter_webrtc` (its
Windows and Linux builds fetch Google's prebuilt libwebrtc at build time). The talk key (V by
default, chosen in the party panel) turns the microphone on and off, or with push-to-talk is
held to talk; it is read from the whole desktop, a game in front included: `GetAsyncKeyState` on
Windows, `XQueryKeymap` on X11 (on Wayland only while an X11 window such as the game is in
front, else only while the launcher has the keyboard).

Profiles (the user's own from Settings or the friends panel, a friend's from their options) show
the games with play time and trophy progress and the recent trophies with their rarity, each part
as private as its owner keeps it. While a game runs, the launcher opens an AnyTogether game
session for it (unless "Let friends join my game" is off), so friends see it as joinable; a
friend's Join (from their presence or an invite) checks the game is here and unlocked, that the
game version and the engine build (the toolkit the game was installed with) match the host's,
joins and starts it. The session, with the players' own properties, is written for the engine's
online bridge at `Together/game-session.json` in the config folder (`ANYPS5_TOGETHER_SESSION`
points at it), which does the playing together.

The trophy level (from all trophy points, bronze to platinum in its hexagon) is beside the
user's name on the home screen, in the friends panel and on their profile with the way to the
next level; each friend's row shows theirs when they let the user see their trophies. A level
reached comes as a toast with the trophy sound (the gateway's `level.up`). A friend's profile
shows their showcase (pinned trophies and favourite games) and **Compare trophies** (also in
their options): the games either has trophies in, both-play first, then one game's trophies
side by side with when each earned them. **Show me as → Appear offline** (Settings →
AnyTogether) hides the user from everyone else (`PATCH /me/presence`, followed on the user's
other devices through `presence.mode`); the socket, messages, parties and cloud saves go on as
ever.

The session (an access token and a refresh token) is kept per system:

- **Windows**: `%APPDATA%\AnyPS5\Together\session.bin`, sealed with DPAPI
  (`CryptProtectData`, for the current Windows user, with the launcher's own entropy): another
  account or another computer cannot open it.
- **Linux**: the Secret Service (GNOME Keyring, KWallet) through `secret-tool` when it is
  installed (`libsecret-tools` / `libsecret`) and a keyring answers. Without one (no
  `secret-tool`, a headless session, a desktop with no keyring) it is
  `~/.config/AnyPS5/Together/session.json` with mode 0600 in a 0700 folder, as the macOS
  launcher keeps it: readable only by this user, which is what an unlocked keyring gives too.
  Calling libsecret through FFI would tie the launcher to GLib and D-Bus at start; the command
  keeps it optional.

## Play from Steam / Steam Deck

**Settings → Steam → Add to Steam** adds AnyPS5 to the Steam library as a non-Steam game, so
Big Picture, Steam Input and the Steam Deck's Game Mode start it like any other game. It finds
Steam where it installs itself (Windows: `HKCU\Software\Valve\Steam` `SteamPath`, else
`C:\Program Files (x86)\Steam`; Linux: `~/.steam/steam`, `~/.local/share/Steam`, Flatpak
`~/.var/app/com.valvesoftware.Steam/.local/share/Steam`) and the account signed in last
(`config/loginusers.vdf`; a choice when there are several), then writes
`userdata/<id>/config/shortcuts.vdf`:

- **AnyPS5**: the AppImage (`$APPIMAGE`) or the installed executable, started with
  `--steam --fullscreen` (**Open Full Screen from Steam** turns the second off), tagged
  `AnyPS5`, overlay on.
- With **Add My Games Too**, one entry per unlocked game started with
  `--steam --play <title ID>`: the game starts at once and the launcher closes when it ends
  normally (a crash keeps it open on the report).
- Artwork in `config/grid`, named after each shortcut's ID (the CRC-32 of the quoted program
  and the name, top bit set, written into the shortcut so Steam uses it): `<id>p.png` 600×900,
  `<id>.png` 920×430, `<id>_hero.png` 1920×620, `<id>_logo.png`, `<id>_icon.png`, drawn by the
  launcher in the Cosmic look, a game's from its `sce_sys/pic0.png` and `icon0.png`.

Steam writes its own copy of `shortcuts.vdf` when it exits, so the launcher writes only while
Steam is closed: with Steam open it offers **Close Steam and Add** (`steam -shutdown`). The
file is read and written back to the byte with only AnyPS5's entries changed, after a copy to
`shortcuts.vdf.anyps5-backup`. **Remove from Steam** takes out only AnyPS5's entries (tagged
`AnyPS5` and started with `--steam`) and their pictures. On a Steam Deck, add it in Desktop
Mode (in Game Mode Steam is the whole session and cannot be closed); Flatpak Steam only sees
the home folder, so keep the AppImage there. `anyps5_tool steam status|add|remove` does the same
from the command line, without the artwork.

## Controllers & troubleshooting

The launcher reads controllers through **SDL2**, the library the engine reads them with in
games: `SDL2.dll` ships beside the launcher on Windows (downloaded at build time and checked
against its SHA-256, `third_party/SDL2`); Linux uses the system's `libSDL2-2.0.so.0`, which the
AppImage carries. DualSense and DualShock 4 work over USB and Bluetooth with their motors, light
bar and player lights (SDL's HIDAPI driver); Xbox pads through XInput / Windows.Gaming.Input;
Switch Pro, 8BitDo and every pad in SDL's mapping database; the DualShock 3 on Linux, and on
Windows once a driver such as DsHidMini shows it. Pads can come and go at any time, several at
once; the one used last is **Player 1** (the launcher's vibration, Player 1's light). Without
SDL2 the launcher falls back to XInput and winmm (Windows) or evdev (Linux), and PlayStation
pads then do not vibrate. While a game is in front only PS / Guide reaches the launcher.

**Settings → Controllers** lists the pads (family, USB or Bluetooth, battery and charging where
the pad says), **Test Buttons and Sticks** (a live drawing of the pad: every button, both sticks
inside the dead zone's ring, the triggers; hold Circle or B, or press Esc, to leave), **Test
Vibration**, **Light Bar** (the theme's accent or a colour, DualSense and DualShock 4),
**Confirm Button** (Circle confirms, as on Japanese consoles; the hints follow) and **Stick Dead
Zone** (for the launcher and for every game that sets none of its own). A controller running out
of battery shows in the top bar.

The **troubleshooter** under it says what it finds, each with what to do:

| Finding | What it looks at |
| --- | --- |
| Steam's PlayStation controller support is on | `steam.exe` / `steam` running and `SteamController_PSSupport` in Steam's `config/config.vdf`: outside its games Steam turns the pad into a mouse and presses land twice |
| Started from Steam | `--steam`, `SteamGameId`/`SteamAppId`: Steam's virtual pad (28de:11ff) is read and the pads Steam took over (`SDL_GAMECONTROLLER_IGNORE_DEVICES`) are left to it |
| DS4Windows / DualSenseX running | their processes: the real PlayStation pad is read and the virtual Xbox 360 pad made of it is ignored |
| HidHide, ViGEmBus installed | their services: HidHide may hide the pad; select the row to copy the launcher's path for its applications list |
| A pad cannot be read (Linux) | `/dev/input/event*` the user may not open: `sudo usermod -aG input "$USER"`, copied by selecting the row |
| PlayStation pads without vibration (Linux) | `/dev/hidraw*` closed: a udev rule to copy (`/etc/udev/rules.d/70-anyps5-controllers.rules`) |
| SDL2 missing, a pad without a layout, a low battery, nothing connected | the cable, Bluetooth pairing and the DualShock 3 driver tips |

Every connect and disconnect is logged with the pad's family, connection and driver; crash
reports carry the controllers at the start and the recent log (and the game's log has them after
its start line). `anyps5_tool pads [--sdl <library>] [--seconds <n>]` prints what SDL2 sees and
the troubleshooter's findings without the window.

## Installed games

With several games folders (**Settings → Game Library → Add Folder**) the library is all of them,
a title found in more than one shown once from the folder listed first, and each game is unlocked
into the store of the folder it was found in, so its files are linked on their own drive.
`<games folder>/.AnyPS5/Games/<TITLE>-<hash>/` holds `app.elf`/`app.exe`, `libs/`, `app0/`
(the dump's files as hard links where the volume allows, symbolic links otherwise, on Windows
with Developer Mode on or the launcher elevated; copies only where neither works, which the
launcher says before unlocking, with the relinked modules copied over), `anyps5-install.json` and
`launch.sh`/`launch.cmd`. The game runs there, so its saves (`_sd`), trophies (`_trophy`) and
data stay with it and move into a new install.

Settings and paired phones: `~/.config/AnyPS5` (Linux), `%APPDATA%\AnyPS5` (Windows).
Logs: `~/.local/state/AnyPS5/logs`, `%LOCALAPPDATA%\AnyPS5\Logs`: `<TITLE>.log` per game (set
aside as `<TITLE>.previous.log` past 32 MB before a start, started again past 256 MB while the
game runs, the earlier part in `<TITLE>.earlier.log`) and `<TITLE>-unlock.log`, the last
unlock's output. A game that stops on an error offers its crash report (also in the game's
options: **Last Session's Report**): **Save crash_log.txt**, **Copy Report** and **Open an
Issue**, which shows what it shares, then opens the engine's bug form (boykopovar/AnyPS5, or
AnyPS5-ARM for its engine) or this launcher's crash form pre-filled. **Detailed Logging** in a
game's options, **Play with Detailed Logging**, `AnyPS5 --trace` (every start of that run) and
`anyps5_tool play <game> <games> --trace` start the engine with its trace switches
(`APS5_LOG_SYNC`, `APS5_TRACE_EXIT`, `APS5_TRACE_MEMORY`, … see `TraceMode`).
Downloaded engines: `~/.local/share/AnyPS5/Toolkits`, `%LOCALAPPDATA%\AnyPS5\Toolkits`.

## Updates and add-ons (DLC)

Put the dumps of a game's update and add-ons next to the game, in the layout shadPS4 uses:

```
Games/
  PPSA01234/                              the game
  PPSA01234-UPDATE/                       its update (PPSA01234-patch works too)
  PPSA01234-DLC/
    EXPANSION0000001/                     one folder per add-on, named by its label
    UP0000-PPSA01234_00-COSTUMEPACK00002/ or by its content ID
  UP0000-PPSA01234_00-SOUNDTRACK000003/   or beside the game, named by its content ID
```

The game's folder name or its title ID goes before `-UPDATE`, `-patch` and `-DLC`, in any case
(`lib/core/game_addons.dart`). The game page shows **DLC (n)** and **Update v01.004 applied**;
an update dumped after the unlock says **unlock to apply**, since its `eboot.bin` and modules are
relinked (saves and trophies stay). At each start the launcher passes `ANYPS5_UPDATE_DIR` and
`ANYPS5_ADDCONT_DIRS` (`;`-separated on Windows, `:` on Linux): the engine reads the update's
files in place of the game's and mounts each add-on the game asks for. Only add-ons on the disk
are reported; nothing contacts PlayStation servers.

## Game Presets

**Settings › Game Presets** sets, once for every game, what the PS5 keeps under that name:
difficulty, Performance Mode or Resolution Mode, inverted vertical and horizontal view for
first-person and third-person games, subtitles and the audio language (`lib/core/game_presets.dart`).
Each profile has its own, kept in `Profiles/<id>/GamePresets.json` in the settings folder, and
each start passes the playing profile's as `ANYPS5_GAME_PRESETS` (nothing when none is set),
which the engine's `sceUserServiceGetGamePresets` answers with. Games that keep their own settings
use those once changed in the game.

## Packages

- Windows: `packaging/windows/build-installer.ps1` builds the release and an Inno Setup 6
  installer, `build/installer/AnyPS5-Desktop-Setup-<version>-x64.exe`: a per-user install in
  `%LOCALAPPDATA%\Programs\AnyPS5 Desktop` by default (all users on request), Start menu and
  optional desktop shortcuts, an uninstaller; a running launcher is closed before an upgrade.
  It opens `.anyps5theme` files with the launcher.
- Linux: `packaging/linux/build-appimage.sh` and `packaging/linux/build-deb.sh` write
  `build/packages/AnyPS5-Desktop-<version>-x86_64.AppImage` and
  `anyps5-desktop_<version>_amd64.deb` (`/opt/anyps5-desktop`, `/usr/bin/anyps5-desktop`).
  Build them on Ubuntu 22.04 so they run on glibc 2.34 and newer; GTK 3 comes from the system.
  Both bring the `application/x-anyps5theme` MIME type (`anyps5-desktop-mime.xml`), which the
  desktop entry opens. The .deb's Depends are the packages of every library the bundle links
  (SDL2's X11, Wayland and ALSA ones too), by their 22.04 names with 24.04's t64 names as
  alternatives, and `libmpv2 | libmpv1` for the clip player. A library the build machine has no package for stops the build. CI installs it
  on clean Ubuntu 22.04 and 24.04 with nothing else and checks every library resolves
  (`packaging/linux/check-deb.sh`).
- The clip player (media_kit, libmpv): on Windows `libmpv-2.dll` and ANGLE come from
  media_kit_libs_windows_video and sit beside the launcher. On Linux no package carries a
  libmpv: the launcher uses the system's (`libmpv.so.2`, or `libmpv.so.1` on Ubuntu 22.04).
  media_kit_video's plugin links the launcher's `libanyps5_mpv.so` (`linux/mpv_shim`) in place of
  libmpv, which opens the system's libmpv when a clip plays, so the launcher starts without one.
  The build needs `libmpv-dev` for the headers. `packaging/linux/no-libmpv.sh` stops the
  packaging if the bundle has a libmpv or links one, and CI starts the launcher from the .deb on
  clean Ubuntu 22.04 and 24.04 with apt's libmpv and again without it
  (`packaging/linux/check-libmpv.sh`).

- Nightly builds: `.github/workflows/nightly.yml` builds main once a day when the launcher
  changed and publishes an unsigned pre-release, `v<next>-nightly.<YYYYMMDD>.<n>`. The launcher's
  Nightly channel offers it once it is signed on the release Mac (`tools/release/sign_nightly.sh`
  in AnyPS5-ARM). It never reaches Stable.

## Credits

**The core**

- **[AnyPS5](https://github.com/boykopovar/AnyPS5) by boykopovar** is where the core comes from: the relinker that turns a PS5 executable into a native program and the reimplemented system libraries. AnyPS5-ARM is its port to Apple silicon Macs, and every engine feature here starts from that work.
- **[mugurc's community macOS port](https://github.com/mugurc/AnyPS5/tree/macos-port)** of AnyPS5 is the port AnyPS5-ARM builds on.
- **[MoltenVK](https://github.com/KhronosGroup/MoltenVK)** (Khronos, Apache-2.0) runs the PS5 graphics driver's Vulkan on Metal, and **[SDL](https://github.com/libsdl-org/SDL)** (zlib) reads the controllers in games and in AnyLauncher Port.
- **[AMD FidelityFX Super Resolution 1](https://github.com/GPUOpen-Effects/FidelityFX-FSR)** (Copyright (c) 2021 Advanced Micro Devices, Inc., MIT) is the engine's FSR 1 upscaler (Game Settings › Upscaling); its sources and licence are in AnyPS5-ARM's `3rdparty/FidelityFX-FSR`.

**Online play**

- **The online design comes from [AnyPlay](https://github.com/anyplaynet).** Our bridge between the engine and the launcher follows AnyPlay's bridge spec ([anyplaynet/network](https://github.com/anyplaynet/network/blob/main/spec/bridge-protocol.md), MIT/Apache-2.0): the frame header, the message numbering, the virtual LAN range and the A/B/C screening of games come from it. Stream P2P sockets over the bridge follow the approach of AnyPlay's engine bridge ([anyplaynet/AnyPS5](https://github.com/anyplaynet/AnyPS5), GPL-2.0).
- **Ideas AnyPlay shipped first** ([anyplaynet/launcher](https://github.com/anyplaynet/launcher), [anyplaynet/cloud](https://github.com/anyplaynet/cloud)): "Try anyway" on a Play Together version mismatch, retiring old launchers with "Update required", asking before leave party / remove friend and similar actions, the noise suppression switch, the public profile switch and the compatibility filters.
- **A phone browser as a controller via a QR code** comes from [LudusCtrl](https://github.com/parl0v/ludusctrl)'s browser client by Josip Parlov (@parl0v), shipped in AnyPlay.

**Testing, feedback and translations**

- **[Slick Daddy](https://github.com/slick-daddy)** tested the launchers and the website in depth and sent the detailed feedback behind many fixes: relink errors and full screen on Windows, the game's button that follows its state, the interface polish, and the website's settings, rate limits and pages.
- **VK** translated the Windows/Linux launcher into German, Spanish, French, Portuguese, Indonesian, Russian, Japanese, Hindi, Bengali, Bhojpuri, Arabic, Urdu, Czech, Danish, Hungarian, Norwegian, Romanian, Swedish, Filipino, Malay, Simplified and Traditional Chinese, Korean, Khmer, Lao and Amharic, and tested it: default display settings, the stick sensitivity on Home, language switching and the nightly builds request came from VK's reports.

Our code is written independently; where we followed someone's design or idea, it is named here.

## License

GPL-2.0, as the AnyPS5-ARM launcher it is ported from (see `LICENSE`). LibAtrac9 in
`native/atrac9` is MIT (`native/atrac9/LICENSE`), as is `flutter_soloud`. The Noto fonts in
`assets/system-fonts` and the Noto Sans CJK fonts the launcher downloads are under the SIL Open
Font License 1.1 (`assets/system-fonts/OFL.txt`; the CJK licence is saved beside them). SDL2 is
under the zlib license (`third_party/SDL2/LICENSE.txt`, shipped as `SDL2-LICENSE.txt`). Clips
play through [media_kit](https://github.com/media-kit/media-kit) (MIT) and
[libmpv](https://mpv.io) with FFmpeg (mpv is GPL-2.0-or-later, LGPL-2.1-or-later when built
for it); the Windows package carries its libmpv's licence as `libmpv-LICENSE.txt`
(`third_party/libmpv/`; that build is under the LGPL version 3 or later) and ANGLE's as
`ANGLE-LICENSE.txt`. The Linux packages carry no libmpv: they use the one the system's package
manager installs, under that distribution's licence. The optional ffmpeg the launcher offers to download is FFmpeg
built by [BtbN/FFmpeg-Builds](https://github.com/BtbN/FFmpeg-Builds) under the GPL version 3,
not shipped with the launcher; what it downloads carries the licence and a link to the exact
source (`packaging/ffmpeg/pinned.env`, `.github/workflows/ffmpeg-release.yml`). The
padlock on locked games (`lib/ui/padlock.dart`) is drawn after Hugeicons' `square-lock-02` from
the Hugeicons Free set, MIT licensed.
