# AnyPS5 Desktop standalone emulator library

Install and configure DuckStation for PS1, PCSX2 for PS2 or RPCS3 for PS3
on Windows or Linux. In AnyPS5, open **Settings → Emulators** and select
the emulator executable for each console you want to use. Choose the
application executable or AppImage directly. Make an AppImage executable
before selecting it. Add your games through **Settings → Game Library**.
The emulators handle BIOS, firmware, graphics, controller setup and saves.

**Show as folders** groups titles for configured emulators after the main
game row. Select a folder to preview its titles below it. Press Down to
enter the row and Up to return. Play starts the installed emulator in a
separate window. Window focus depends on the desktop environment.

[Game discovery](../lib/core/game_library.dart) recognizes PS1 cue sheets
with local tracks, PBP files and local M3U playlists, PS2 ISO images with
a PS2 boot entry, and CHD images under a console-named PS1 or PS2 folder.
[PS3 disc discovery](../lib/core/ps3_disc.dart) reads the title from
`PS3_GAME/PARAM.SFO` in an extracted disc folder. The file
`PS3_GAME/USRDIR/EBOOT.BIN` is the RPCS3 launch target. A PS1 or PS2 game folder
can also contain a `retro.json` descriptor with `platform`, `name`,
`disc` and `titleId` fields. Optional `icon` and `background` fields point
to artwork. Paths
are relative to the descriptor. Discovery is opt-in for the launcher so
the existing PS5 command-line tools keep their library scope.

[Executable selection and launch](../lib/ui/standalone_emulators.dart)
store paths in launcher preferences and hand the selected file to the
[existing process and log lifecycle](../lib/core/game_process.dart).
The [launcher model](../lib/ui/app_model.dart) exposes the setup rows and
keeps standalone discs out of PS5 unlocking and trophy discovery. The
[file picker adapter](../lib/main.dart) leaves Linux executable names
unfiltered. The [game action](../lib/ui/game_action.dart) opens the picker
when a title needs an emulator. The [folder selection model](../lib/ui/retro_home_folders.dart) keeps
the focused console separate from its game selection. The [folder tile](../lib/ui/retro_folder_tile.dart)
shows the console abbreviation and indicates the lower row in
[Home](../lib/ui/home.dart). The [English](../assets/l10n/en.json) and
[Turkish](../assets/l10n/tr.json) dictionaries provide the launcher copy.
[Discovery tests](../test/core/retro_library_test.dart) cover mixed
libraries and cue-sheet grouping. [Standalone launcher tests](../test/ui/standalone_retro_test.dart)
use synthetic files and fake processes to verify selection, navigation
and the launch arguments for all three consoles.
