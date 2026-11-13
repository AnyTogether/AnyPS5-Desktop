# AnyPS5 Desktop standalone emulator library

Install and configure DuckStation for PS1, PCSX2 for PS2 or RPCS3 for PS3
on Windows or Linux. In AnyPS5, turn on **Settings → Game Library →
Emulator games**. The switch is off by default: until it is on, the games
folders are scanned for PS5 dumps only, no disc file is opened, and
Settings shows no Emulators section. Once it is on, open **Settings →
Emulators** and select the emulator executable for each console you want
to use. Choose the application executable or AppImage directly. Make an
AppImage executable before selecting it. The emulators handle BIOS,
firmware, graphics, controller setup and saves.

**Show as folders** groups titles for configured emulators after the main
game row. Select a folder to preview its titles below it. Press Down to
enter the row and Up to return. Play starts the installed emulator in a
separate window. Window focus depends on the desktop environment. A title
whose emulator is not selected yet shows the **Emulator required** badge,
and its action opens the file picker.

## Discovery

[Game discovery](../lib/core/game_library.dart) recognizes PS1 cue sheets
with local tracks, PBP files and local M3U playlists, PS2 ISO images with
a PS2 boot entry, and CHD images under a console-named PS1 or PS2 folder.
Any cue sheet with a data track outside a PS2 folder, and any PBP (PSP ones
included), is listed as PS1.
[PS3 disc discovery](../lib/core/ps3_disc.dart) reads the title from
`PS3_GAME/PARAM.SFO` in an extracted disc folder. The file
`PS3_GAME/USRDIR/EBOOT.BIN` is the RPCS3 launch target. A PS1 or PS2 game
folder can also contain a `retro.json` descriptor with `platform`, `name`,
`disc` and `titleId` fields. Optional `icon` and `background` fields point
to artwork. Paths are relative to the descriptor. Discovery runs only when
the launcher passes `includeRetro`, which follows the Emulator games
switch, so the PS5 command-line tools and PS5-only libraries keep their
scope.

Scans run on the interface isolate, as the PS5 scan always has, so the
disc parsing is cached instead of repeated. `RetroScanCache` keeps what was
read from each disc file (a cue sheet's file names, a playlist's entries,
whether an ISO boots a PS2, a PBP or CHD header, a PARAM.SFO) by path,
size and modification time. A rescan or a folder-watch event reads again
only the files that changed. A full library scan drops the entries for
files it no longer sees. Whether a cue sheet's tracks exist is still
checked on every scan, because the tracks can disappear without the sheet
changing.

## Identity and size

A disc's `Game.libraryId` is `retro:<console>:<key>:<path inside the games
folder>`, with `/` separators on every system. The key is the title ID for
a `retro.json` or PS3 folder, and the total size of a loose disc's files
otherwise, so two games folders that hold different discs at the same path
both list them. When a drive letter or mount point changes and the same
games folder is added again, the identifier stays the same, so last played
and the measured size follow the game. The title ID of a loose disc is
derived from that identifier.

Disc images that share a folder each list their own `Game.files`: a cue
sheet and its tracks, or a playlist with every listed sheet and its
tracks. The home screen's Size card adds up only those files. A game with
its own folder (`retro.json` or a PS3 disc) is still measured as a whole
folder.

## Launch

[Executable selection and launch](../lib/ui/standalone_emulators.dart)
store paths in launcher preferences and hand the selected file to the
[existing process and log lifecycle](../lib/core/game_process.dart).
Cancelling a start (Close on the phone) clears the Starting state at once,
even if the emulator's process start never returns. If that process does
start later, it is asked to end and is killed after the same grace period
as Stop (`stopGrace`), and any start begun in the meantime is left alone.

On Linux an emulator starts with the launcher's environment minus what the
launcher's AppImage set (`GameProcess.withoutAppImage`): the AppImage
runtime's `APPIMAGE`, `APPDIR`, `ARGV0` and `OWD`, and the AppRun's own
`usr/share` folder at the front of `XDG_DATA_DIRS`. The AppRun names that
folder with symbolic links resolved, so it is matched both as `APPDIR` gives
it and resolved. An emulator that is not an AppImage then cannot pick up the
launcher's paths, and one that is starts as it would from the desktop.
Outside an AppImage none of those variables is set, so the emulator gets the
launcher's environment unchanged.

The [launcher model](../lib/ui/app_model.dart) exposes the setup rows and
keeps standalone discs out of PS5 unlocking and trophy discovery. The
[file picker adapter](../lib/main.dart) leaves Linux executable names
unfiltered. The [game action](../lib/ui/game_action.dart) opens the picker
when a title needs an emulator. The [folder selection model](../lib/ui/retro_home_folders.dart)
keeps the focused console separate from its game selection. The
[folder tile](../lib/ui/retro_folder_tile.dart) shows the console
abbreviation and indicates the lower row in [Home](../lib/ui/home.dart).
Every file in [the language folder](../assets/l10n/en.json) carries the
launcher copy.

## Tests

[Discovery tests](../test/core/retro_library_test.dart) cover mixed
libraries, cue-sheet grouping, identifiers that survive a moved games
folder, per-game file lists and the cache.
[Installer tests](../test/core/installer_test.dart) check the environment
an emulator gets from the launcher's AppImage, including a data folder named
through a symbolic link, and that a program started without the parent
environment gets only the one given.
[Standalone launcher tests](../test/ui/standalone_retro_test.dart) use
synthetic files and fake processes to verify the off-by-default switch,
selection, navigation, the launch arguments for all three consoles, a
cancelled start whose process never answers, the size of a shared-folder
disc and the last-played migration.
[Golden tests](../test/ui/standalone_retro_golden_test.dart) draw the
switch, Settings → Emulators, the Emulator required badge and the console
folder. Their images are made on macOS by CI (`ci.yml` with
`update_goldens`), like every other golden in the repository.
