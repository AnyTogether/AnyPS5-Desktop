# The emulator host in the launcher's UI

[The emulator host client](<AnyPS5 Desktop - Emulator Host Client.md>) talks to the emulator host
(the separate program that runs PS1 games, and PS2 games on a host with
LRPS2). This page covers the UI built on it: a game's picture in the launcher,
the object that runs one game in one host, the controllers that play it, the
model of its in-game menu, and how the launcher plays a PS1 or PS2 disc from
its emulator library through all of them (behind settings that are off by
default, see "In the launcher" and "PS2 games").

## Files

| File | What it does |
| --- | --- |
| [`lib/core/retro_host/retro_host_session.dart`](../lib/core/retro_host/retro_host_session.dart) | `RetroFrameSource` and `RetroHostSession`: the parts of `RetroHostClient` the UI uses. `RetroHostClient` implements them, and tests give a fake. Also `RetroHostStartRequest`, the `start` call's argument. |
| [`lib/ui/retro_host/retro_frame_image.dart`](../lib/ui/retro_host/retro_frame_image.dart) | Turns the host's frames into a `ui.Image`. |
| [`lib/ui/retro_host/retro_frame_view.dart`](../lib/ui/retro_host/retro_frame_view.dart) | Draws a picture on black at an aspect ratio. |
| [`lib/ui/retro_host/retro_host_focus.dart`](../lib/ui/retro_host/retro_host_focus.dart) | Reports whether the launcher's window has input focus. |
| [`lib/ui/retro_host/retro_host_game.dart`](../lib/ui/retro_host/retro_host_game.dart) | `RetroHostGame`: one game in one host. |
| [`lib/ui/retro_host/retro_host_keeper.dart`](../lib/ui/retro_host/retro_host_keeper.dart) | `RetroHostKeeper`: keeps the host of the last game running for the next one, and shuts it down when it is no longer wanted. |
| [`lib/ui/retro_host/retro_host_game_view.dart`](../lib/ui/retro_host/retro_host_game_view.dart) | Puts the last three together: a game's picture that pauses the game when focus is lost. |
| [`lib/core/retro_host/retro_pad.dart`](../lib/core/retro_host/retro_pad.dart) | `RetroPadInput`: one controller's state as the protocol's `input` carries it, made from the launcher's `PadState`. |
| [`lib/core/retro_host/retro_seats.dart`](../lib/core/retro_host/retro_seats.dart) | `RetroSeats`: which controller sits at each of the PS1's two ports. |
| [`lib/ui/retro_host/retro_host_controls.dart`](../lib/ui/retro_host/retro_host_controls.dart) | `RetroHostControls`: plays a `RetroHostGame` with the launcher's controllers, connects port 2 and forwards vibration. `RetroPadReader` is how it reads the controllers. |
| [`lib/ui/retro_host/retro_game_menu.dart`](../lib/ui/retro_host/retro_game_menu.dart) | `RetroGameMenu`: the in-game menu's rows (discs, core options, volume) and what choosing them does. |
| [`lib/core/retro_host/retro_resolution.dart`](../lib/core/retro_host/retro_resolution.dart) | `RetroResolutionChoice`: the internal resolution the menu offers for a status, each console's option key, and what the row says under it (see "Internal resolution"). |
| [`lib/ui/retro_host/retro_save_states.dart`](../lib/ui/retro_host/retro_save_states.dart) | `RetroSaveStates`: a game's save state slots as its states folder holds them, and saving into one (with a picture of the moment) and loading one, one at a time. |
| [`lib/ui/retro_host/retro_state_picture.dart`](../lib/ui/retro_host/retro_state_picture.dart) | `retroStatePicture`: the small PNG of the game's picture kept beside a saved state. |
| [`lib/ui/retro_host/retro_option_sections.dart`](../lib/ui/retro_host/retro_option_sections.dart) | `RetroOptionSection` and `retroOptionSection`: which section of the menu each SwanStation option belongs to, which options are graphics options the menu leaves out, and which options are not shown. |
| [`lib/core/retro_host/retro_host_install.dart`](../lib/core/retro_host/retro_host_install.dart) | `RetroHostInstall`: the host and SwanStation library a build runs, and whether it is checked before each start. |
| [`lib/ui/retro_host/retro_host_download_model.dart`](../lib/ui/retro_host/retro_host_download_model.dart) | `RetroHostDownloadModel`: Settings › Emulators' row that downloads, updates and repairs the signed host, and what a failed check before a start leaves it saying. |
| [`lib/core/retro_host/retro_keyboard.dart`](../lib/core/retro_host/retro_keyboard.dart) | `RetroKeyboard`: the keyboard as a PS1 controller, with the keys of a game's Controls. |
| [`lib/ui/retro_host_play.dart`](../lib/ui/retro_host_play.dart) | `RetroPlay` and the `RetroHostPlaying` part of `AppModel`: the PS1 and PS2 settings and BIOS folders, starting a disc in the host, the commands while it plays, the menu's panel rows, closing. |
| [`lib/ui/retro_host/retro_play_view.dart`](../lib/ui/retro_host/retro_play_view.dart) | `RetroPlayView`: the game over the whole window, with `RetroGameNotice` for the loading and error screens. |
| [`lib/ui/retro_host/retro_unchecked_mark.dart`](../lib/ui/retro_host/retro_unchecked_mark.dart) | `RetroUncheckedMark`: the small corner label over a game on an unchecked host, only in debug and test builds. |

Each piece does one job and can be used alone. A settings preview can use
`RetroFrameView` with any picture, and a menu can follow `RetroHostGame` without
showing the picture.

## From frame to picture

The host writes each frame into shared memory and sends `frame`. The client
pins the newest frame and adds an event to `frames`
(`RetroHostClient.frames`). `RetroFrameImage` listens to that stream:

1. **It copies the frame right away.** On each event marked `drawn`, it copies
   the frame's `height` rows of `width` × 4 bytes into a Dart list. The
   client's documentation says why it cannot wait: a frame "stays readable until
   another frame replaces it", and a frame that was not drawn "can be read only
   until the next message". So the copy is made while the event is handled,
   before any other message can arrive. After that, nothing the host writes can
   change the picture. The copy goes through `PinnedFrame.copyPixels()`, which
   gives null once the frame's ring has been unmapped (by `close()` or a third
   ring); such a frame is dropped and the picture before it stays. Only the
   Dart copy reaches the raster thread, so it never reads the shared memory.
2. **It makes an image from the copy.** `decodeImageFromPixels` uploads it,
   with `PixelFormat.rgba8888` or `PixelFormat.bgra8888` to match the frame's
   format. Both formats come out as the same colours.
3. **It keeps up by skipping.** Uploading takes time. Frames that arrive during
   an upload are not queued: only the newest one is kept, and it is uploaded
   next. The protocol's `frame` section says this is correct: "Frames can be
   skipped; only the newest frame matters."
4. **It owns the image.** When a new image is ready, the old one is disposed
   and listeners are told. `RawImage` keeps its own clone, so a picture being
   painted is never disposed under it.

Only events marked `drawn` are shown. The client marks a frame drawn only when
its `epoch` belongs to the current game, so a frame left over from a game that
was stopped is never shown. When a game starts or ends, `clear()` removes the
picture and drops any upload still running. `RetroHostGame` also sets
`accepting` to false from the moment its game ends, is stopped or the host is
being shut down, until the next game is accepted. A frame that still arrives in
that time (the client keeps marking frames drawn until `release`) is ignored,
so the old game's last picture never comes back.

When the ring has no frame, the client adds an event with no frame. The picture
then stays as it is, which is what the protocol asks: "the launcher keeps
showing what it showed before".

## The picture on screen

`RetroFrameView` draws a black box. Inside it, centred, is an `AspectRatio`
with the core's display aspect ratio, which holds a `RawImage` stretched to
fill it. So the PS1's non-square pixels look right, and any spare space is
black bars. Pixels are not smoothed by default (`FilterQuality.none`). Before
the first frame only the black box is drawn.

`RetroHostGameView` takes the aspect ratio from `RetroHostGame.aspect`, which
comes from the game's last `status` ("aspect": "The display aspect ratio the
core reports; 1.3333333333333333 until it reports one").

## One game in one host: `RetroHostGame`

`RetroHostGame` runs one game on one `RetroHostSession` and owns the
`RetroFrameImage` of its frames. The session is its own until it is shut down
or detached (below), so the next game can start on the same host.
`RetroHostGame.launch(command: …)` starts a real host;
`RetroHostGame(session)` takes any session: one the launcher just started,
one kept from the last game, or a fake in the tests.

| Phase | Meaning |
| --- | --- |
| `idle` | No game started yet. |
| `starting` | Waiting for the host's `welcome` and the reply to `start`. |
| `loading` | `start` was accepted; `status.ready` is still false. |
| `playing` | `status.ready` is true. |
| `ended` | The game ended. `endStatus` holds the status it ended with (`errorCode` says why), and `failure` holds the reason when `start` was refused or no status came. |
| `closed` | The host was shut down. |

- **Start.** `start(RetroHostStartRequest)` waits for `ready`, sends `start`
  with the protocol's fields (`core`, `disc`, `system`, `saves`, and `options`
  and `initialDisc` only when given), clears the picture, and then asks
  `status` every 500 ms while a game is loaded. Only one game is started per
  `RetroHostGame`.
- **Status.** Each `status` updates the aspect ratio. A ready status moves the
  game from `loading` to `playing`. An ended status ends it. After a host
  failure, the client's own short failure report (`errorCode` `hostExited` or
  `hostHung`) ends it the same way. When the host's connection ends, the game
  asks `status` at once instead of waiting for the next poll. Listeners hear
  of a status only when it says something new (`RetroStatus.sameAs`, which
  compares every field as protocol.md "status" writes it): a game that plays
  on with the same status, asked twice a second, rebuilds nothing.
- **Input.** `input(port, buttons, …)` forwards a controller state to the host,
  but only while a game is loaded and the window has input focus
  (`acceptsInput`). The client zeroes both ports when focus is lost, so
  dropping input while the window has no focus keeps them at zero.
- **Game calls.** `connectedPorts`, `changeDisc` and `setOption` send the
  protocol's methods of the same names, and only while a game is loaded. Each
  gives the host's `true` or `false`. It gives `false` when the call fails,
  and a host failure is then seen by the next status. After a disc change or
  an option the host took, `status` is asked at once, so the menu shows it.
- **Volume.** `setVolume` sends `volume` once the host has greeted the
  launcher, with or without a game. `volume` and `muted` keep what the player
  chose. `RetroHostGame.launch` starts the host with them, and the client
  sends them after `welcome`, as the protocol asks.
- **Pausing.** The game is paused while the player paused it or while the
  window has no focus, and these two are tracked apart. Losing focus pauses
  the game (`pause` with `true`). Getting focus back resumes it, unless the
  player had paused it. A game started while the window has no focus is
  paused as soon as `start` is accepted. `pause` is sent only when the
  combined state changes.
- **Focus.** `setFocused` also sets `RetroHostClient.inputFocus`, which zeroes
  the controllers and their motors, as the protocol's `input` and `rumble`
  sections require. `RetroHostFocus` takes focus from the app's lifecycle:
  the window has focus while it is `resumed`, and loses it when it is
  inactive, hidden or paused. After its first frame, and whenever it is given
  another game, it also passes on the state the app is already in. So a view
  opened while the window has no focus still pauses its game.
  Once the host has ended or been shut down, focus is still recorded but no
  longer passed to the client, whose streams are closed by then.
- **How the host ended.** `hostEnd` is the connection's end once it has one.
  `RetroHostEnd.unsupported` means the host speaks no protocol version this
  launcher offered, which the launcher shows as an emulator that needs
  updating (protocol.md "Host failure").
- **Stop.** `stop()` calls `stopGame()` (which enforces the 10-second stop
  limit), then `release`, and returns the status the game ended with. Stopping
  a game that is still `starting` cancels it. If `start` was not sent yet, it
  never is. If it was sent, the game is stopped and released as soon as the
  host's reply comes, and `stop()` waits for that.
- **Shut down.** `shutdown()` sends `shutdown`, waits for the connection to
  end (the client kills a host that has not exited within 15 seconds), then
  calls `close()`. `dispose()` shuts down too. Calling `shutdown()` again
  returns the same shutdown.
- **Detach.** `detach()` lets go of the host without shutting it down, so the
  next game can start on it. protocol.md "Processes" says "One host runs games
  one after another until the launcher exits or the host fails." It stops the
  game if it still runs, then calls `release` even for a game that ended on
  its own, since `start` is `busy` "if a game is loaded, running or ended",
  and asks `status`. It gives true only when the host still runs and `status`
  is `null`, that is, no game is loaded. Otherwise it shuts the host down and
  gives false. That covers a host that crashed, one still holding a game, a
  failed call, and the host protocol.md "release" describes, which "sends the
  reply to `release` and exits" after a game stuck in its core: it answers
  no `status` after that reply, so the call fails. A detached game's phase is
  `closed`, it sends nothing more, and `dispose()` leaves the host running.
  The window's focus is given back to the host (`inputFocus` true), as a new
  host starts with it, since the next game tells it its own.

After the host process exists, nothing here waits on the host on the UI
thread: every wait is a `Future`, and the client's time limits make sure each
one ends. Starting the process is the exception. `RetroHostClient.start` runs
on the UI isolate and returns once the process exists, so on Windows it takes
as long as `CreateProcessW`, which can be slow while antivirus scans a new
host executable.

## Controllers: `RetroHostControls`

`RetroHostControls` turns the launcher's controllers into the protocol's
`input` messages for one `RetroHostGame`. It reads them through a
`RetroPadReader`: the ids of the controllers connected now, in the launcher's
order with Player 1 first, and each one's `PadState`.
`RetroPadReader.inventory` reads a reader's `PadInventory` (SDL, or XInput
and winmm, or evdev).

**Buttons and sticks.** `RetroPadInput.fromPad` follows the bit table of the
protocol's `input` section: Cross 0, Square 1, Select 2, Start 3, D-pad up,
down, left and right 4 to 7, Circle 8, Triangle 9, L1 10, R1 11, L2 12, R2
13, L3 14, R3 15. Buttons go by their place on the pad, as the launcher's
readers name them (`south` is Cross, `east` Circle, `west` Square, `north`
Triangle), so an Xbox pad's A is Cross. PS/Guide, the touchpad and the extra
button send nothing: PS stays the launcher's (home, close the game). A trigger
counts as L2 or R2 from the point where the SDL reader counts it pressed
(0.35). The protocol says "-32768 is fully left or fully up". The launcher's
sticks go from -1 to 1 with down positive, so -1 becomes -32768 and 1
becomes 32767. Settings › Controllers › Stick Dead Zone (`deadzonePercent`)
applies to each stick. The older readers (XInput and winmm, evdev) give no
right stick or analogue triggers, so with them the right stick stays centred.

**Ports.** `RetroSeats` gives each controller a port and keeps it there while
the controller stays connected, so a press on another pad never swaps the
players. When the game starts, Player 1 (the controller used last) is at port
1 and the next controller at port 2. A controller that leaves frees its port.
The other player stays where they are, and the next controller to connect
takes the free port. Port 2 counts as connected while a controller sits
there. The protocol's `connectedPorts` section says "A game starts with 1",
so `connectedPorts` with `2` is sent when the game loads with two
controllers or a second one sits down, and `1` when it leaves. Port 1 always
has a controller in the host. Controls made for a game that is already loaded
do not know what the host has, so they send the count on their first read.
A count is the host's only once it answered `true`: one it did not take, or
a call that failed, is asked again by the next read, and nothing is asked
twice while a call waits.

**Sending.** The controllers are read every 16 ms, as the SDL reader polls
them. A port's state is sent when it changes. The protocol says the launcher
sends it "when the state changes, and once with all zeros when a game starts
or input focus is lost", and the client sends those zeros itself. So whenever
the game stops taking input (not loaded, or no focus), the controls forget
what they sent, and send both ports again in full once it takes input again.
They follow the game's changes as they happen, not only at each read, so
focus lost and back within 16 ms is not missed. A controller held through a
focus change therefore reaches the game again when focus comes back. A port
whose controller left is sent as idle. While `suspended` is true (the in-game
menu is open), both ports are sent as idle. When it becomes false, the
controllers are seated again first, and the buttons held at that moment stay
out of the game until they are let go, as
the launcher's own `PadGate` does when the launcher comes back in front. The
sticks come back at once.

**Vibration.** The protocol's `rumble` section says the launcher "forwards
them to the controller seated at that port, if it can vibrate". So each
`RetroHostGame.rumble` event goes to the controller at that port when the
reader's `PadRumble.canRumble` says it can, as `strong / 65535` and
`weak / 65535`. The controllers are seated again before a `rumble` is routed,
so one that just took a free port gets it. A `rumble` holds until the next one, but the SDL and evdev
readers stop the motors after the length they are given. So a level that is
not zero is given for `rumbleHold` (2 s) and given again every second. The
client already gives zeros for both ports when the game starts, pauses, ends
or loses focus, and gives nothing while paused or without focus. The controls
add the protocol's last case, "when a controller leaves its port": its motors
stop. They also stop every motor once no game is loaded, because a host that
is shut down sends no `rumble` and the client gives no zeros for a clean end.
From then on they ignore any `rumble` that still comes. Setting `vibration`
to false stops the motors and keeps later rumble away. `dispose` stops any
motor the game left running. It also sends idle for a port whose controller
held something, so a game that goes on is not left with a held button.

## The in-game menu: `RetroGameMenu`

`RetroGameMenu` is the menu's model. It shows no widget: a menu view lists
`rows` and calls the actions. The rows come from the game's last `status`:

- **Discs.** For a game with more than one disc, one `RetroDiscRow` per entry
  of `status.discs.labels`, with the inserted disc marked. A row can be
  chosen when it is not the inserted disc and no change is in progress
  (`discs.busy`). `chooseDisc` sends `changeDisc` with the row's index, which
  the protocol defines as "the index into `discs.labels`". `discChangeFailed`
  is `discs.failed`.
- **Core options.** One `RetroOptionRow` per entry of `status.options` that
  is shown (below), in the host's order. `title` is SwanStation's title
  without its own " (Restart)", since the menu says that under every option
  whose `restart` is true. `section` is where the row goes, and
  `optionsIn(section)` gives the rows of one section. `choice` is the label of
  `selected`. `pending` is true while the chosen value is not yet the
  `activeValue`, and `restartNeeded` is the option's `restart`.
  `stepOption(key, steps)` moves through `values` and stops at the first and
  last. It sends `option` with `key` and `value`.
- **Volume.** A `RetroVolumeRow` with the game's `volume` and `muted`.
  `stepVolume` moves it by tenths from 0 to 1, and turning it up unmutes.
  `toggleMute` switches `muted`.

**Sections.** The host lists every option SwanStation lets the player change
now: fifty for a PS1 game with the host and SwanStation recorded in
[`test/fixtures/retro-host-swanstation-status.json`](../test/fixtures/retro-host-swanstation-status.json).
`retroOptionSection(key)` sorts them by SwanStation's key,
`swanstation_<Group>_<Name>`, so an option a later SwanStation adds still
finds its place:

| Section | SwanStation options |
| --- | --- |
| Graphics (not in the menu, see "Not yet"; only the internal resolution has a row of its own) | `GPU_*` and `Display_*`; LRPS2's `pcsx2_upscale_multiplier` |
| Audio | `Audio_*` and Mute CD Audio (`CDROM_MuteCDAudio`) |
| Controller | `Controller*` (`Controller_`, `Controller1_`, `Controller2_`, `ControllerPorts_`) |
| Console | `Console_*`, `BIOS_*`, CD-ROM Region Check, Read Speedup and Seek Speedup, CPU Overclocking |
| Advanced | everything else: the CPU's execution mode, how the disc is read, compatibility settings, run-ahead, hacks, and any group not named here |

Ten options are not shown, since players have no use for them in the
launcher: the on-screen messages (the host draws none), the four display
offsets (sixty-one steps of SwanStation's own calibration each), texture
replacements (the host gives SwanStation no texture folder), the development
console's 8 MB of RAM (no game sold uses it), the CPU recompiler's three
debugging switches, and the light gun crosshair (the host plugs in only
DualShocks). A value kept for one of them from before is not sent in `start`,
so nobody is left with a setting they can no longer change. For the same
reason a value kept for a graphics option is not sent either until the
Graphics page exists (`retroOptionSent`), except each console's internal
resolution, which the menu's first page offers (see "Internal resolution").

`open()` pauses the game (`pause` with `true`, the same as the player's own
pause) and sets the controls' `suspended`, so presses in the menu never reach
the game. `close()` gives the controllers back at once, so a button still
held from the menu reaches the game only once it is pressed again, then
resumes the game. Neither does anything after waiting for the host, so
opening the menu again while a close still waits for its reply keeps the
controllers out. A menu disposed while open closes the same way. A game that
is not loaded has no menu to open.

## Internal resolution

The menu's first page has an **Internal resolution** row after Audio: the
scale the game is drawn at. It is the one option of the Graphics section
(`RetroOptionSection.graphics`) the menu shows; the others wait for a
Graphics page ("Not yet").

**Which option, and when it shows.** The row is
`swanstation_GPU_ResolutionScale` for a PS1 game and
`pcsx2_upscale_multiplier` for a PS2 game (`retroResolutionKey`), told apart
by the status's own `console`. It shows only while the host limits that
option to what it can pass on, as host `docs/protocol.md` "status" says:

> For the internal resolution (`swanstation_GPU_ResolutionScale`), while
> `hardware` is `true`, `values` lists only the whole-number scales whose
> largest frame the host can pass on

and, for PS2, only with the capability the host's
`ps2-resolution-limits` branch adds (fork B-Howell/anyps5-retro-host-upstream
at 9a06327, not yet on the host's `main`):

> | `ps2ResolutionLimits` | A PS2 game's internal resolution (`pcsx2_upscale_multiplier`) is limited to what the host can pass on, as PS1's is ([`status`](#status)). A launcher offers a PS2 internal resolution only to a host that lists it |

So `RetroResolutionChoice.of(status, limitsPs2:)` gives nothing before the
first status, while `status.hardware` is false (the host then lists every
value and limits none), when the core lists no such option, or for a PS2
game on a host without `ps2ResolutionLimits` (`RetroHostGame.limitsPs2Resolution`,
from `welcome`).

**Which values.** The launcher offers Native, 2x, 3x and 4x for PS1 (`"1"`
to `"4"`) and Native, 2x and 4x for PS2 (`"1x (Native)"`, `"2x"`, `"4x"`;
LRPS2 has no 3x), and of those only the ones the host lists, in the host's
order. The value the game has is always shown, also one the launcher does not
offer, with the host's label, so the row never claims a value the game does
not use. 5x and above are not offered: on a 1080p or 1440p display most of
the gain is at 2x to 4x, and PS2 games at 8x ran at 26 to 40 frames a second
on an RTX 4080 SUPER in the host's own measurement (host `docs/ps2.md`
"Drawing"), while the host still offers 8x where it fits. The labels are the
launcher's (`retroResolutionNative`, `retroResolutionScale` "%@x"), not the
cores', which disagree ("3x (for 720p)" in SwanStation).

**What the row says** (`RetroResolutionNote`, worded by
`retroResolutionDetail`):

- the host could not use the value saved (`status.resolutionError` not
  empty): "Your graphics card can't draw the resolution you saved, so the game
  uses 4x.", naming `activeValue`. The host's English sentence goes only to
  the launcher's log, once per change;
- a PS1 value chosen and not yet drawn (`selected` is not `activeValue`, or
  `graphicsPending`): "Takes effect in a moment.";
- a PS2 value chosen: "Takes effect when the game is started again.", since
  LRPS2 reads it only while the game loads (`restart` is `true`);
- a PS2 game otherwise: "Changes take effect when the game is started again.";
- a PS1 game otherwise: "Draws the game sharper. Higher values need a faster
  graphics card."

**Choosing.** `RetroGameMenu.chooseResolution` sends `option` with the
value, only one the row offers and not the one already chosen. Once the host
takes it, `AppModel` keeps it in `Preferences.retroHostOptions`, as any
option, and `retroOptionSent` sends it in the next game's `start` of that
console. The host judges a kept value again at every start, so a value that
no longer fits (another graphics card) starts the game at the largest that
does, with `resolutionError`. `RetroHostGame.start` leaves a kept PS2 value
out of `start` on a host without `ps2ResolutionLimits`, and the client throws
`StateError` before it sends one to such a host, in `start` or `option`.

**Not in Settings yet.** Settings › Emulators has no resolution rows. A
preference chosen there would be a value no host has judged, and whether a
host limits PS2 is known only once it has greeted the launcher; the row in
the game's menu needs neither. A Settings row, the Graphics page and an
automatic choice by graphics card come later.

## In the launcher

**The host.** A release build gets its host as it gets ffmpeg: Settings ›
Emulators has a row for the PS1 emulator (`RetroHostDownloadModel`). Before
anything is installed it says **Download the PS1 emulator**. Nothing is asked
of GitHub until the player selects it. Then the row shows the download's
progress, and selecting it again stops it, even while the kept host is still
exiting. Once the checked files are being written over the old host's
(`RetroHostDownloadModel.placing`), the row says only that it is checking and
no longer stops it, so a half-replaced host is never left behind. The host comes from the host
repository's signed releases and is checked on download, as
[Emulator host client](<AnyPS5 Desktop - Emulator Host Client.md>) "Finding and checking the host"
describes. Once it is installed the row says **PS1 emulator 1.0.0** (its
version), and selecting it looks for a newer release: "PS1 emulator 1.0.0 is
up to date" when there is none and the installed host passes its checks. A
host that failed its check before a start, or that is missing a file, is
downloaded again at any version. A file that cannot be written ends the
download with its reason, and so does a release whose tag is not the version
it is signed as: an older host published again under a higher tag is not taken
for an update. With no signed release yet the row says so. In Turkish every row
and message of the PS1 emulator addresses the player in the same informal
form as the PS1 rows beside them ("seç", "koy", "dene", "indir"), and names
the emulator "emülatör", as the rest of the launcher does, never "öykünücü".
The download is refused while a PS1 game plays, while one is starting in the
host (`RetroHostDownloadModel.holdForStart`, held from the checks before a
start until the game's play is set). Before the new host is put in place, the host kept for the next game is
shut down and waited for, so its held files are let go, and no game starts
until the install is done. When the launcher goes, a download stops and one
already fetched is not put in place (`RetroHostDownloadModel.close`), since
the hosts shut down as it goes may not have exited yet. The launcher does not
wait for one already being put in place, and quitting can cut it short. That
leaves no half-replaced host: `RetroHostRelease.install` writes the new files
into `RetroHost/host.new` on another isolate, so the window stays responsive,
and only then swaps the folders with two renames in one synchronous step on
the UI isolate, so the old host stays whole until then. A launcher stopped
between the two renames leaves the old host in `host.old`, and the next start
puts it back (`RetroHostRelease.restore`). The next start checks the installed
host anyway, and a missing host is offered for download again. The first host installed turns the setting
below on, since the player asked for the emulator to play PS1 games with it.

**The setting.** Settings › Emulators › **Run PS1 games in the separate
host** (`Preferences.retroHostPs1`) is off by default. The row shows only
where a host is found (`AppModel.retroHostInstall`): the downloaded release
(`RetroHostDownloadModel.installed`), or in a debug or test build the host
that `ANYPS5_RETRO_HOST` names (`AppModel.retroHostUnchecked`, from
`RetroHostInstall.locate`), as protocol.md "Finding and checking the host"
allows: "Debug builds of the launcher MAY run the host named by the
environment variable `ANYPS5_RETRO_HOST`, and any core, without the checks.
Release builds ignore that variable." (A test build is a release-mode build
compiled to allow it, never published:
[Emulator host client](<AnyPS5 Desktop - Emulator Host Client.md>) "Debug and test builds".) That
unchecked host comes first, and while it is used no download row is shown;
instead **Unchecked emulator (test build)** says that this build runs it
without checking its signature or files, and that normal releases only run the
signed emulator. Its words name no console, since the same host plays PS1
games and, with LRPS2 beside it, PS2 games. A Settings row alone is not enough, since a screenshot of
the game would not show it, so a game on that host is also marked where it
plays ("The unchecked-host mark" below). The core is the SwanStation library beside the host
(`swanstation_libretro.dll` on Windows,
`swanstation_libretro.so` on Linux), as a host release's zip holds the two.
Neither is looked for on every read: every PS1 tile and row uses the same
answer. The unchecked host is looked for once, since the environment that names
it does not change while the launcher runs. The downloaded host is read from
`RetroHost/host` (`RetroHostStore.installed` and its version) when the model
is made and again only when that folder may have changed: after a download
reached putting its host in place, and after the installed host failed its
check before a start, so a host with a file gone stops being offered to PS1
games. With no host found the row is hidden and a PS1 disc goes to
DuckStation as before, even with the setting saved as on. With the setting
on, a PS1 disc needs no DuckStation: it is not shown as "Emulator required",
and the PS1 folder on Home groups its games. The row **PS1 BIOS folder**
opens the folder the BIOS goes in.

**PS2 games** (a proposal: host `docs/ps2.md` "The BIOS" leaves the launcher
side to the launchers). Under the PS1 rows Settings › Emulators has PS2 rows
made the same way (`_retroHostPs2SettingsRows`):

- Where the host found has LRPS2 beside it (`RetroHostInstall.ps2Core`: a
  signed release that ships `pcsx2_libretro`, or an unchecked host built with
  it), **Run PS2 games in the separate host** (`Preferences.retroHostPs2`),
  off by default. With it on a PS2 disc plays in the launcher's window instead
  of PCSX2, needs no PCSX2 (`playsInHost`), and **PS2 BIOS folder** opens
  `AppPaths.retroPs2Bios`, `pcsx2/bios` in the same system directory, where
  LRPS2 looks for the player's BIOS. The launcher does not read, check or copy
  the BIOS; the player puts it there, as for PS1. Host `docs/ps2.md` proposes a
  picked file checked as LRPS2's `IsBIOS` does and copied in; that is left
  out to keep the PS2 rows the PS1 rows' shape, and can follow if the
  maintainers want it.
- Where the host has no LRPS2 (every signed release until the host ships it),
  there are no PS2 rows at all, so Settings › Emulators is the PS1 one, and PS2
  discs start in PCSX2. The setting does nothing then, even saved as on.
- Turning the setting on or off scans the library again, and so does a
  download that adds or drops LRPS2: a PS2 cue sheet is listed only while PS2
  discs play in the host, since PCSX2 does not boot one
  ([Standalone emulator library](<AnyPS5 Desktop - Standalone Emulator Library.md>)
  "Discovery").

A PS2 disc starts on the same host as a PS1 disc, with `console` `ps2`, LRPS2
as `core`, `saves` `AppPaths.retroPs2Saves` (`retro/saves/ps2`), and only the
kept options of LRPS2 (`pcsx2_...`, `retroOptionSent(key, ps2: true)`); a PS1
disc gets only SwanStation's, so the two cores share one list of the player's
choices. A host whose `welcome` does not list `ps2` is never sent the game:
`RetroHostGame.consoleRefused` ends it and its screen says the host needs
updating; a toast says the same when a signed release's check finds no LRPS2
to hold.
LRPS2's `bios` (no BIOS it takes in `pcsx2/bios`) shows **No PS2 BIOS was
found** with the PS2 BIOS folder offered on the options key
(`retroBiosFolderOf`), as the PS1 error screen offers the PS1 folder. The
in-game menu is the PS1 one: LRPS2's options are all under Advanced
(`retroOptionSection`), with their own titles, but its resolution scale
(`pcsx2_upscale_multiplier`), which is a graphics option, is not under
Advanced: it is the Internal resolution row (see "Internal resolution"), and
only on a host that lists `ps2ResolutionLimits`; to any other host it is
neither shown nor sent. `pcsx2_bios`, the BIOS file
LRPS2 starts with when the folder holds more than one, says it takes effect at
the next start. The kept host stays for the next game while the game selected
plays in the host, PS1 or PS2. Online play stays PS1-only and is not touched.

**Starting.** `AppModel.play` sends a PS1 disc to `_playInHost` when
`playsInHost` says so. It asks the family rules first, as every start does.
For the downloaded release's host it then runs the checks before a start
(`RetroHostStore.check`). A host that fails them is not started: the toast
says the PS1 emulator did not pass its check and to download it again, and
its row in Settings › Emulators says why and offers it again. Then it opens a
host (`AppModel.openRetroHost`, which tests replace) with the player's volume.
A checked host is started through its checked files
(`RetroHostClient.start(checked: ...)`), which stay held until that host has
exited, across every game it plays. A kept host is checked again before each
later game while it stays in the keeper, so a download can still find it, and
is taken only once the check passed; one that fails is shut down through the
keeper, which a download waits for. No host starts, and no kept host is used, while
a download is putting a new host in place ("The PS1 emulator is being
updated"). Then it sends `start` with:

- `core`: the SwanStation library above (LRPS2 for a PS2 disc, with
  `console` `ps2`; see "PS2 games" above);
- `disc`: the disc's file (`.cue`, `.chd`, `.pbp` or `.m3u`; for PS2 `.iso`,
  `.chd`, `.cso`, `.zso`, `.cue` or `.elf`);
- `system`: `AppPaths.retroSystem`, `retro/system` in the launcher's
  settings folder, where protocol.md's `start` example keeps it;
- `saves`: `AppPaths.retroSaves`, `retro/saves/ps1` beside it;
- `options`: the SwanStation options the player chose in the menu before
  (`Preferences.retroHostOptions`), the internal resolution among them, and
  for a PS2 game LRPS2's (`retroOptionSent`).

The family play-time watcher follows the game as it follows any game
(`FamilyGate.followGame`), and a family limit that closes games closes it
through Close game. No other game starts while it plays. A host that cannot
be started at all (a file that is not a program) says so in a toast. Every
path is sent normalized, so it has no `.` or `..` segment (protocol.md
"Paths").

**One host for several games.** A game that is closed, or that ended, leaves
its host running for the next game when `RetroHostGame.detach()` says no game
is loaded. `RetroHostKeeper` (`AppModel.retroHostKeeper`) keeps that one host.
The next PS1 game takes it instead of starting a new one, as long as it is the
same host program, and sends it the player's volume again. The kept host is
shut down:

- once the player has left the PS1 games: the game selected is not a PS1
  disc that plays in the host, the setting was turned off, or another game
  is starting or running (`_letUnwantedRetroHostGo`, checked on every change
  of the launcher's state);
- after five minutes without a game (`RetroHostKeeper.idleLimit`);
- when the launcher quits.

**Quitting.** Every close of the launcher (its Quit, the window's close,
Alt+F4, an update's installer) comes through the exit request in
`lib/main.dart`. Before it lets the launcher go, it calls
`AppModel.shutDownRetroHosts`: a host download stops first
(`RetroHostDownloadModel.close`), so one waiting for the kept host to exit is
not put in place as the launcher goes; then the game's host and the kept one
are told to shut down, and the launcher waits up to `RetroHostPlaying.quitLimit` (3 s,
under `LauncherShutdown.fallbackAfter`) for them to exit. A host told to shut
down "stops its game as `stop` does (memory cards are written), then exits"
(protocol.md "shutdown"). On Windows that is what saves the game: a host
still running when the launcher's process ends goes with its job object,
unsaved. On Linux a host still there gets SIGTERM from `PR_SET_PDEATHSIG`,
which it handles like `shutdown`. `AppModel.dispose` lets go of the game and
shuts the hosts down too, for a launcher that goes away without quitting (the
tests).

A kept host that ends by itself (it crashed, or exited after `release` as
protocol.md "release" allows) is forgotten and freed, and the next game starts
a new host, as protocol.md "Host failure" says: "The next game starts a new
host." A host that failed during a game is shut down when the game is left,
never kept.

**The host's environment.** On Windows the host gets the launcher's
environment. On Linux it gets the launcher's environment without what the
launcher's AppImage set (`RetroHostInstall.environmentFor`, which is
`GameProcess.withoutAppImage`), as a standalone emulator does: no `APPIMAGE`,
`APPDIR`, `ARGV0` or `OWD`, and not the AppImage's own `usr/share` at the head
of `XDG_DATA_DIRS`. `RetroHostClient.start` then gets it as the whole
environment (`inheritEnvironment: false`).

**The controllers.** `RetroHostControls` reads the app's own controller
reader: `ControllersModel.pads` in the launcher's order (Player 1, the
controller used last, first) and `ControllersModel.stateOf`. It turns the
motors through the reader's (`padMotors`), takes the dead zone from Settings ›
Controllers › Stick Dead Zone, and stops vibration when Settings › Behaviour ›
Controller Vibration is off.

**The keyboard.** `RetroKeyboard` plays the PS1 pad with the keys of the
game's Controls (`Controls.sources`: the launcher's layout with the keys the
player moved). Its state joins the controller at port 1, as a libretro
frontend binds the keyboard to player 1: buttons of both count, and a stick
comes from the keys while they tilt it. The touchpad's two halves are Select.
The stick modifier tilts the keyboard's sticks by the game's stick modifier
scale. Mouse buttons and the wheel are not read. The keys are read from
Flutter's `HardwareKeyboard.physicalKeysPressed` at each poll. While the game's
screen is in front, the launcher's own keys do nothing: only the in-game
shortcuts of Settings › Shortcuts and full screen act. PS opens the game's
menu. The screenshot and clip shortcuts (and Share) take nothing for a game
in the host yet, since they follow a game the launcher started as its own
process; they say so in a toast (`retroHostNoCapture`). A PS1 game's Game
Settings has a **Controls** row for its keys.

**The game's screen.** `RetroPlayView` draws the game over the whole window,
over the home screen and under every layer. While it starts or loads it shows
the game's name and a line of what it loads, with a progress line from
`status.progressPercent` when the host gives one. The line is the host's
`status.progressLabel` where the launcher speaks English, as the host's words
are English, and "Loading the game…" in the player's language otherwise
(`retroLoadingText`). It follows its `RetroHostGame` itself (a
`ListenableBuilder`), so a loading step redraws only the game's screen.

**The home screen under the game.** A game in the host counts as a game
playing (`AppModel.gamePlaying`, true for `running` or `retroPlay`). The home
screen rests under it as under any game: the theme's animation, a background
video or picture and the game artwork's drift stay still (`Backdrop`), the
home tiles' focus ring stops (`homeRingMoves`), and Glass's frame-time watch
does not count the game's frames.

**What the launcher redraws.** `RetroHostPlaying._retroChanged` hears every
change of the game. The launcher's state changes (`_changed`: the phones'
library, every game's state) only when the game's phase or its problem
changes. Anything else, a disc change or an option, is drawn again only while
the game's menu is open, since only the menu shows it. On the
game's screen the controller is the game's: Cross, Circle, Start and the
D-pad reach the game, not the launcher. Only PS acts. PS, PS held, the quick
menu shortcut, and the mouse's right or Back button open the game's menu.
While the game loads, PS or Esc gives the start up.

**The menu.** `Layer.retroMenu` is a panel styled as the quick menu
("Paused", the game's icon and name), as tall as its rows. Its first page:
Resume, each disc of a multi-disc game ("In the console." under the inserted
one), Save state and Load state where the host saves states (see "Save
states"), a row for each section that has rows (Audio, Controller, Console,
Advanced, each with a line saying what is in it) with Internal resolution
after Audio where the menu offers it (see "Internal resolution"), and Close
game. Choosing a
section shows its page, headed with its name: its SwanStation options as
choices of their labels, and in Audio, Volume (a bar in tenths) and Mute
first. An option that takes effect only when the game starts again says so
under its title, and a chosen value not yet in effect says when it will be.
Back on a section's page goes back to the first page, on that section's row.
The menu always opens on its first page. Opening it pauses the game and keeps
the controllers out of it. PS, Options or Resume close it, and so does Back
on the first page. Any other layer over the
game (a family notice) pauses it the same way, and the game's own screen back
in front resumes it. The game's play time is counted for the family rules
until it ends, not until its error screen is left. A chosen option is kept in
`Preferences.retroHostOptions` once the host took it, and the volume and mute
in `Preferences.retroHostVolume` and `retroHostMuted`, so the next game starts
with them.

**A memory card that cannot be read.** When a `status` says
`cardUnreadable`, memory card 1's file is there but the host could not read
it as a card, so it leaves the file as it is and this game's saves are
written nowhere (protocol.md "status"). The launcher says so once per game in
a toast (`retroHostCardUnreadable`), and the game plays on.

**Ending.** Close game stops the game (the host writes the memory card,
unless it could not read it, above) and releases it, keeps the host for the next game (above), then the library comes
back. A game that
ends without an error goes back to the library the same way. A game that ends
with an error stays on its error screen ("Night Racer stopped") with the words
for its `errorCode` (`retroHostErrorKey`; a code the launcher does not know is
"The game stopped because of an error.", as protocol.md "Compatibility" asks),
and Enter or Cross goes back to the library. A game with no BIOS it can use
also offers the PS1 BIOS folder there (O or Triangle,
`openRetroBiosFolder`, as the Settings row opens it). A host that speaks another
protocol version shows that it needs updating, and a host that never greeted
the launcher shows that it could not be started.

## Save states

On a host that lists `saveStates` ([Emulator host client](<AnyPS5 Desktop - Emulator Host Client.md>)
"Save states"), a game's menu has **Save state** and **Load state** on its
first page, after the discs and before the sections, in sentence case like
every other row. They show once the game has shown its first frame
(`RetroHostGamePhase.playing`, the host's `status.ready`), since the host
answers `false` to a save or load before that; a row in focus while they
appear stays in focus (`_keepRetroMenuRow`). They are an offline feature for
one player, and nothing online uses them. On a host without the capability,
such as the signed host v1.0.0, the game starts without a states folder and
neither row shows.

How the standard emulators do it shaped this: RetroArch's Quick Menu has Save
State and Load State on a numbered slot of each game, with a picture of the
moment beside each state; DuckStation's pause menu lists each game's slots
with that picture and the date and time, and refuses a state its build cannot
read. Here the launcher shows the host's eight slots of a game as Slot 1 to 8.

- **The model.** `RetroPlay.states` is a `RetroSaveStates` over the game and
  its `RetroStateFolder` (`retro/states/<console>/<Game.titleId>`,
  `AppPaths.retroStates`), built from the same normalized disc path the
  host's `start.disc` gets, so the slot names cannot drift from the host's. It
  reads the slots when the game starts, after every save, and after a load
  that found its slot empty. Only two things change the folder while the game
  plays: the launcher's own saves, and a host's late write after a save that
  answered `fileError` (protocol.md: a save that late is still put in place if
  it had reached its rename). That late write is why a failed save takes the
  slot's picture away (below), and the slot's date shows it from the next
  read, after the next save or the next start. One save or load runs at a
  time (`RetroSaveStates.busy`); while it runs its slot says **Saving…** or
  **Loading…** (`RetroSaveStates.running`), which can take up to 4.5 seconds
  on a `fileError`, and any row chosen meanwhile does nothing.
- **One folder per game.** The host names a slot `<disc stem>.<slot>.state`
  and checks a state's game only by the console and that stem (protocol.md
  `otherGame`), so two games whose discs have the same file name (two
  "Disc 1.cue" in different folders) would share slots in one console folder,
  and one game's state would load into the other. protocol.md lets the
  launcher name any `start.states` folder, so each game gets its own, named by
  its `Game.titleId` with hyphens kept: the retro.json title ID for a game
  that has one, so its states stay when its folder moves, and otherwise the
  hash of its path and size the library names it by (a disc without a
  retro.json that is moved or renamed starts with no states, as with any other
  per-game record of it). Two games whose retro.json give the same title ID
  share their states. The memory cards stay shared by disc name in `saves`,
  as on main. No release ever wrote the per-console folder, so nothing is
  moved.
- **Save state's page.** Every slot, with the date and time its state was
  saved (`retroStateTime`, "2026-11-18 14:03", as the cloud saves show theirs)
  or Empty, and the picture kept beside it at the game's shape
  (`PanelRow.pictureAspect`, which also keeps an empty slot's place so the
  titles line up). An empty slot is saved into at once. A slot that holds a
  state asks **Overwrite slot N?** first (`Layer.retroOverwriteState`, a
  `ConfirmCard` with the game's icon): Cancel first, where the focus starts,
  then Overwrite, which says when the state it replaces was saved. Back, PS
  and Options on the question go back to Save state on that slot; held PS
  goes back to the game. A save that works says "Saved in slot N" and goes
  back to the game; one that does not says it could not be saved and stays on
  the page.
- **The picture.** `RetroSaveStates.save` takes a clone of the frame shown when
  the slot is chosen, which is the paused game's while the menu is open, and
  once the host has saved, `retroStatePicture` draws it 240 pixels wide at the
  game's display aspect and encodes it as PNG, kept beside the state. A save
  with no frame, or whose picture cannot be made or written, keeps no picture:
  the log says why, and the save still counts. A save that did not work takes
  the slot's picture away, since the new state may still land in it (a late
  write after `fileError`, or a host that went away after writing), unless the
  core refused it, which leaves the slot as it was. A game closed while its
  picture is being made writes none, since the next game may already be saving
  into that slot.
- **Late answers.** A save or load goes back to the game only if the menu still
  shows the page of the visit it was asked in (`RetroPlay.menuVisits`): one
  that answers after the player left the menu and opened it again leaves the
  new visit alone.
- **Load state's page.** The same slots; only a slot that holds a state can be
  chosen, and the focus starts on the first one. With nothing saved yet the
  first page's Load state cannot be chosen and says so. For a PS1 game its
  line says that the memory card goes back to that moment too, as the host's
  protocol.md says a PS1 state holds memory card 1. A load that works says
  "Slot N loaded" and goes back to the game, which goes on from the state. A
  load the host refused says why in plain words and stays on the page: a state
  of another version of the emulator (`otherCore`, a host release whose core
  build changed), of another game (`otherGame`), or a damaged file or one from
  a newer emulator (`badState`); anything else says only that it could not be
  loaded (`retroStateProblem`).
- **Rows that come and go.** The first page gains rows as the status changes:
  Save state and Load state at the first frame, and the discs and sections
  once the status lists them. `RetroPlay.firstPageRows` keeps the ids of the
  page last built, and `_keepRetroMenuRow` puts the focus back on the row it
  was on, wherever that row now is.
- **The game ending.** A game that ends while the menu or the question is open
  closes both (`retroMenuShown`), and the menu always opens on its first page.
  A PS1 game that ends with `errorCode` `other` right after a load the host
  answered `false` also says that its memory card may already be back at that
  moment (`retroStateCardAfterEnd`), since protocol.md says such a load may
  still have replaced card 1, also when the player closed the game while that
  load ran. Once a status asked after that reply says the game has not ended,
  the load left it untouched and it plays on, so a later `other` ending says
  nothing of the card (`RetroSaveStates.loadAnsweredFalse`).

## The unchecked-host mark

The host's protocol.md asks a launcher that runs an unchecked host to say so
where the game plays, and the review of host #14 made it a condition of test
builds: a test build running an unchecked host shows it on the game's screen,
every time, so a tester's screenshot of the game can never pass for a
release. A PS2 game on that host, on its unchecked LRPS2, is marked the same
way (`RetroPlay.unchecked` is the host's, whichever core it plays), so the
mark's words, like the Settings row's, name no console.

- **What it is.** `RetroUncheckedMark`
  ([`retro_unchecked_mark.dart`](../lib/ui/retro_host/retro_unchecked_mark.dart))
  is a small dark label in the window's bottom corner (start side, so on the
  left in left-to-right languages), with a flask icon in the warning colour
  and the same words as the Settings row, **Unchecked emulator (test
  build)**. It is drawn in the launcher's stack above the game and above every
  layer over it (the game's menu, Settings); only the starting card, call
  and pairing cards, toasts and window buttons are drawn above it. It lets the
  pointer through. So it shows on the
  loading screen, the playing picture, the paused game under its menu, any
  layer opened over the game, and the error screen, for as long as the game
  is `AppModel.retroPlay`. It is small and in a corner, as test and beta
  builds of other programs mark their output, so it does not hide the game.
- **When.** `RetroPlay.unchecked` is set when the game starts, from the
  install it starts (`!RetroHostInstall.checked`): the host `ANYPS5_RETRO_HOST`
  names. A debug or test build that plays a downloaded signed host shows no
  mark, since that host was checked.
- **Not in a release.** The launcher draws it only under
  `RetroHostPlaying.runsUnchecked`, a constant: `kDebugMode ||
  RetroHostBuild.testDefined`, which also decides whether the launcher looks
  for the unchecked host at all. Both are fixed when the launcher is compiled
  ([Emulator host client](<AnyPS5 Desktop - Emulator Host Client.md>) "Debug
  and test builds"), so in a release the condition is `false` and the
  compiler leaves the mark out, as it leaves out the unchecked host itself.
  No setting, file or environment variable can turn it on or off.

## Tests

The tests in `test/ui/retro_host` use a fake session and fake frames, kept in
native memory as a real ring slot would be, so no host is started.

- [`retro_frame_image_test.dart`](../test/ui/retro_host/retro_frame_image_test.dart):
  - `rgba8` and `bgra8` frames read back as the right colours;
  - frames not marked drawn are skipped;
  - the copy is taken when the event arrives, so later writes to the slot do
    not show;
  - a frame whose ring was unmapped is never read or shown;
  - while an upload runs, only the newest frame is uploaded next;
  - `clear()` drops a frame still being uploaded.
- [`retro_host_game_test.dart`](../test/ui/retro_host/retro_host_game_test.dart)
  covers:
  - the `start` argument;
  - the status example from the protocol's `status` section;
  - no listener told of a status the same as the last, while loading or
    playing, and told of one that changed;
  - input filtering, pausing on focus loss and the player's own pause;
  - an ended status, a refused `start`, a host that never says `welcome`, and
    a host failure while playing;
  - stopping while waiting for `welcome`, and while `start` waits for its reply;
  - frames that arrive after the game ended or during shutdown;
  - focus changes after shutdown or a host failure;
  - `stop`, `shutdown` and `dispose`, including disposing before a game was
    started on a host that is gone;
  - `detach`: a host left running with no game and the next game started on
    it, a game that ended on its own released first, and the host shut down
    instead when it still holds a game, a call fails, it has ended or it was
    shut down.
- [`retro_host_keeper_test.dart`](../test/ui/retro_host/retro_host_keeper_test.dart)
  checks that a kept host goes to the next game of the same program once,
  that one of another program, a second one kept, or one idle too long is
  shut down, and that a kept host that ends by itself is forgotten and freed.
- [`retro_option_sections_test.dart`](../test/ui/retro_host/retro_option_sections_test.dart)
  sorts the fifty options of the recorded real status into their sections and
  the ten not shown, checks keys the recording lacks (port 2, multitap, a
  group SwanStation may add, another core's key), and the " (Restart)" titles;
  the internal resolution is sent and the other graphics options are not.
- [`retro_resolution_words_test.dart`](../test/ui/retro_host/retro_resolution_words_test.dart)
  checks the row's labels (Native, the scale, the host's own label for a
  value the launcher does not offer) and the line under it for each note.
- [`test/core/retro_host/retro_resolution_test.dart`](../test/core/retro_host/retro_resolution_test.dart)
  reads the recorded SwanStation status (eight scales, the menu offers four),
  and [`test/fixtures/retro-host-ps2-resolution-status.json`](../test/fixtures/retro-host-ps2-resolution-status.json),
  the host's `call-status-ps2-resolution.json` from the `ps2-resolution-limits`
  branch at 9a06327, recorded with the real LRPS2 and Jak and Daxter started
  at 8x in stereo on an RTX 4080 SUPER: 1x to 4x listed, 4x in use and
  `resolutionError` set. It checks the notes, a value the launcher does not
  offer, and that nothing is offered without the GPU, without the option, or
  for PS2 on a host without `ps2ResolutionLimits`.
- [`retro_host_launch_environment_test.dart`](../test/ui/retro_host/retro_host_launch_environment_test.dart)
  starts `AppModel.openRetroHost` on Linux with a host that writes the
  environment it got: the AppImage's variables are gone, `XDG_DATA_DIRS` has
  lost the AppImage's folder, and nothing of the test process's own
  environment came in. It also checks that Windows keeps the launcher's
  environment and that an empty whole environment is refused.
- [`retro_host_game_view_test.dart`](../test/ui/retro_host/retro_host_game_view_test.dart)
  checks the letterboxing and that a frame from the fake host reaches the
  screen. It also checks that an `inactive` lifecycle pauses the game and
  `resumed` resumes it, and that a view opened while the window is inactive
  tells its game at once.

  It also checks that a controller held while the window loses focus reaches
  the game again when focus comes back.
- [`retro_host_controls_test.dart`](../test/ui/retro_host/retro_host_controls_test.dart)
  covers:
  - a port's state sent once, then on each change;
  - port 2 connected when a second controller sits down, or when the game
    loads with two, and let go when it leaves;
  - both ports sent again after focus comes back, also when focus is lost
    and back between two reads;
  - `suspended`, and a button held when it ends kept out until pressed
    again, also on a controller that sat down just before;
  - vibration sent to the controller at its port, a leaving controller's
    motors stopped, motors stopped when the host is shut down (also against a
    late `rumble`), vibration turned off, and `dispose`, which also lets go
    of held buttons;
  - a `rumble` that comes as one controller takes another's port, and
    controls made for a game already loaded sending the port count;
  - a button kept out after the menu closed that is let go and pressed again
    while the window has no focus;
  - a `connectedPorts` the host did not take asked again, and never twice
    while a call waits.
- [`retro_game_menu_test.dart`](../test/ui/retro_host/retro_game_menu_test.dart)
  builds the rows from the protocol's status example. It checks disc changes,
  option steps, volume steps and mute, volume set before `welcome`, and that
  opening the menu pauses the game and suspends the controls, also when it is
  opened again while closing still waits for the host, and that a menu
  disposed while open gives the controllers back. `chooseResolution` sends
  `option` only for a value the row offers and not already chosen.
- [`retro_pad_test.dart`](../test/core/retro_host/retro_pad_test.dart) checks
  every button against the protocol's bit table, the triggers, both ends of
  the stick range and the dead zone.
  [`retro_seats_test.dart`](../test/core/retro_host/retro_seats_test.dart)
  covers who sits where as controllers come and go.
- [`fake_retro_host_session.dart`](../test/ui/retro_host/fake_retro_host_session.dart)
  holds the fakes: the session, frames, controllers (`FakePads`) and motors
  (`FakeMotors`).
- [`retro_host_play_test.dart`](../test/ui/retro_host_play_test.dart)
  plays a PS1 disc from a games folder through the launcher with a fake host
  ([`ps1_launcher.dart`](../test/support/ps1_launcher.dart)): the setting off
  (DuckStation as before) and without a host, the `start` argument with the
  player's paths, volume and options, the controller kept from the launcher
  on the game's screen, PS opening and closing the menu, the menu's first page
  and each section's page against the recorded real status (Back to the first
  page on the section's row, the restart marks, what is kept), the Internal
  resolution row (Native to 4x of the eight scales the host lists, a refused
  `option` not kept, a taken one kept and sent at the next start, no row while
  the host draws without the GPU), options not shown and not sent, Close game keeping the host and the next game starting
  on it, the kept host shut down when the player leaves the PS1 games, after
  the idle limit and when another game starts, a kept host that crashed and a
  host that crashed during a game (both replaced by a new host for the next
  game), a host still holding a game after `release` (shut down), a memory
  card the host cannot read (said once), an error screen, a clean end, an
  outdated host, and a start given up. It also checks the review points of
  #161: the home screen's background and focus ring still under the game
  (`Backdrop` pumped with no fixed time); no launcher rebuild for a status that
  says nothing new, the open menu redrawn for one that does, and an error
  that is the launcher's change; the host looked for once; quitting
  (`shutDownRetroHosts`) shutting down the game's host and the kept one, and
  not waiting past its limit for a host that does not exit; the BIOS folder
  offered only for a missing BIOS; the Screenshot and Share toast; and the
  loading line in English and in Turkish.
- [`retro_host_play_golden_test.dart`](../test/ui/retro_host_play_golden_test.dart)
  draws the loading screen, the error screen (no BIOS, with its folder hint),
  the game's picture, the menu's
  first page over it (with the Internal resolution row after Audio), a PS2
  game's menu on that row with a saved 8x refused (the recorded LRPS2 status),
  its Console page, the game on an unchecked host with
  its mark in the corner, and Settings › Emulators with the
  host's rows: the debug host's with its unchecked notice, the download offered
  before a host is installed, and the downloaded release installed and turned on.
  The game's own goldens play on the signed release's host, as a release has
  it, so they show no mark.
- [`retro_host_unchecked_mark_test.dart`](../test/ui/retro_host_unchecked_mark_test.dart)
  follows a game on the host `ANYPS5_RETRO_HOST` names through every screen
  (loading, playing, its menu, Settings over it, stopped on an error) and
  finds the mark on each, finds it on none for a game on the signed release,
  and checks that `RetroHostPlaying.runsUnchecked` is the compile-time
  `kDebugMode || RetroHostBuild.testDefined` and `retroHostBuild` the build
  `RetroHostBuild.of(debug: kDebugMode)` gives.
- [`retro_host_release_play_test.dart`](../test/ui/retro_host_release_play_test.dart)
  plays a PS1 disc the release way, with the recorded signed release of
  `test/fixtures/retro_host_release` and no `ANYPS5_RETRO_HOST`. The host is
  started with a check whose files are still held, from the launcher's own
  storage and with that release's SwanStation. A host whose file changed is not
  started, the toast says so, and its row offers it again. From a fake GitHub
  the row downloads, checks and installs the release and turns the setting on.
  Selecting the row again finds it up to date and downloads nothing, while a
  broken host, or one missing a file, is downloaded again at the same version.
  A missing file is not looked for on every read: the host stays found until
  its check before a start fails, and only then is no longer offered.
  A kept host is checked again before its next game and shut down when its
  core changed, and nothing starts while a download is installing. A download
  shuts the kept host down and waits for it before the new host goes in, and
  is refused, leaving the kept host, while a game is starting; one the
  launcher closes during is not put in place. With no release the row
  says none is published yet. A download stopped while the kept host is
  still exiting is not put in place, nor is one when the launcher quits
  meanwhile (`shutDownRetroHosts`), and once the new host is being put in
  place the row no longer offers to stop it. Nothing downloads while a game plays, and a debug
  build that runs `ANYPS5_RETRO_HOST` shows no download but says its host is
  unchecked, which the signed release's rows never say.
- [`retro_keyboard_test.dart`](../test/core/retro_host/retro_keyboard_test.dart)
  checks the keyboard layout as a PS1 pad, a moved key, the stick modifier
  and the keys joining a controller.
  [`retro_host_install_test.dart`](../test/core/retro_host/retro_host_install_test.dart)
  checks where the host and core are found, that a debug or test build finds
  the named one and a release build none (even with an environment variable
  named like the test build's define), that a launcher compiled without
  `--dart-define=ANYPS5_UNCHECKED_RETRO_HOST_BUILD=true` is a release when it
  is not a debug build, and that no workflow, packaging script or tool names
  that define.

A widget test runs in fake time, but images are made by the engine in real
time. So the view test waits for a picture by taking turns: a short real wait
(`tester.runAsync`), then `tester.pump()`.

```bash
flutter test test/ui/retro_host test/ui/retro_host_play_test.dart test/ui/retro_host_play_golden_test.dart \
  test/core/retro_host/retro_pad_test.dart test/core/retro_host/retro_seats_test.dart \
  test/core/retro_host/retro_keyboard_test.dart test/core/retro_host/retro_host_install_test.dart   test/ui/retro_host_release_play_test.dart test/core/retro_host/retro_host_store_test.dart
```

### Against the real host

[`retro_host_game_real_test.dart`](../test/ui/retro_host/retro_host_game_real_test.dart)
runs `RetroHostGame`, `RetroHostControls` and `RetroGameMenu` against the real
host. It reads the same `ANYPS5_RETRO_HOST_REAL` file as the client's real
test ([Emulator host client](<AnyPS5 Desktop - Emulator Host Client.md>)), with one more optional
key, `fakeCore`: the host repository's test core (`tests/fake_core.c`, built
beside the host as `fake_core.dll` or `libfake_core.so`). Without the variable
the test is skipped, so CI skips it. Without `fakeCore` only the second case
is skipped.

- **SwanStation.** OpenBIOS boots the PS-EXE. The game reaches `playing`, and
  its `picture` shows two pictures that are not black and differ. A second
  controller sits down at port 2 and then leaves. The test records the calls
  that go through the session: the controls sent `connectedPorts` with `2`,
  then `1`, and the host answered `true` to both. `stop` then ends the game
  with no error.
- **The test core.** The test core's own description says it "rumbles port
  1's large motor while Cross is held". So holding Cross on the controller at
  port 1 must reach the core through `input`, and the core's vibration must
  come back to that controller's motors at full strength, then stop when
  Cross is let go. The menu then steps the core's `fake_color` option from
  Blue to Green, and the picture turns green. Choosing the second disc of a
  two-disc `.m3u` ends with `discs.inserted` at 1, not busy and not failed.

Both cases passed on Windows on 13 November 2026, with the host built from
the host repository's `stage2-gpu` branch (bde086e) with WinLibs GCC 15.2,
and SwanStation built for Windows. They have not been run again against the
host's `main` at 9052aff.

[`retro_host_app_real_test.dart`](../test/ui/retro_host/retro_host_app_real_test.dart)
reads the same file and runs the whole launcher against the real host. By
default the host and SwanStation are copied into one folder that
`ANYPS5_RETRO_HOST` names. With `releaseFolder` (a folder of what the host
repository's release workflow packed, such as its `release-<system>`
artifact) or `packer` and `coreLicence` (the packer packs the host and core),
the launcher gets its host as a release build does instead. The release is
signed with the fixture key of `test/fixtures/retro_host_release`, served from
a fake GitHub and downloaded through Settings › Emulators' row, and every host
is started through its checked files. Those must be held while it plays and
let go after it has exited. Then the PS-EXE is put on a disc in a games folder, OpenBIOS goes in the
PS1 BIOS folder, and `AppModel.play` starts the disc with the setting on. The
game reaches `playing` and shows two pictures that differ. A second
controller in the app's controller reader connects port 2. PS opens the menu
(the host takes `pause`) on its four sections, each section's page holds only
SwanStation options, CD-ROM Read Speedup is changed in Console and kept, the
volume is set in Audio and kept, and PS resumes. Close game leaves the host
running with a memory card written. The same disc then plays again in the
same host (its frames carry epoch 2, as protocol.md "start" counts games in a
host), Close game keeps the host again, and turning the setting off shuts it
down with a clean exit. Its helpers, shared with the test above, are
in [`real_host_support.dart`](../test/ui/retro_host/real_host_support.dart).
It passed on Windows on 13 November 2026 with the same host and SwanStation
builds, and again with the sections and the kept host the same day. On 15
November 2026 it passed on Windows the release way, with `releaseFolder` set to
the `release-windows-x64` artifact of a run of the host repository's release
workflow (fork run 43535853189): downloaded, installed into the launcher's storage,
started from the checked files, two games in one host, files let go after the
host exited. The host runs with the test's own environment, as the launcher starts
it, so WinLibs' `bin` folder has to be on `PATH` there.

Save states have tests of their own, replaying the recorded host of
[Emulator host client](<AnyPS5 Desktop - Emulator Host Client.md>) "Save states":
[`test/ui/retro_host/retro_save_states_test.dart`](../test/ui/retro_host/retro_save_states_test.dart)
gives each recorded `saveState` and `loadState` reply to `RetroHostGame` and
checks the outcome the menu acts on, the start without `states` on a host
without the capability, the picture kept, one call at a time, no other call
of the game sent until a state call's reply, and a slot found empty. [`test/ui/retro_host_save_states_test.dart`](../test/ui/retro_host_save_states_test.dart)
plays them through the launcher: each game's own states folder (also for two
games whose discs have the same name) and the PS2 one, the rows only with the
capability and only from the first frame on (the focus kept as they appear),
saving into an empty and a used slot (Overwrite slot N?, with Cancel, Back, PS
and Options on it), Saving… and Loading… on the slot while a call runs, a
failed save, loading with each recorded refusal and its words, a slot found
empty, the game ending under the question, and a PS1 game ending with
`other` after a load answered `false`.
[`retro_host_play_golden_test.dart`](../test/ui/retro_host_play_golden_test.dart)
draws the menu with Save state and Load state (and Internal resolution
after Audio), Save state's slots with two
pictures saved from the game's frame through the real path, and Overwrite slot
1?.

PS2 has tests of its own, with no BIOS of any kind:
[`test/ui/retro_host_ps2_test.dart`](../test/ui/retro_host_ps2_test.dart)
covers the PS2 rows with and without LRPS2 beside the host, the folder they
open, a PS2 disc's `start`, a PS1 disc on the same host, a host without `ps2`,
the real LRPS2's `bios` and its folder, a running PS2 game's menu, the
internal resolution from the recorded LRPS2 status (offered, chosen and kept
on a host with `ps2ResolutionLimits`; neither offered nor sent on one
without), and the signed release with LRPS2
([`test/fixtures/retro_host_release_ps2`](../test/fixtures/retro_host_release_ps2/SHA256SUMS))
and without it. It also downloads both from a fake GitHub, one after the other,
and checks that a PS2 cue sheet (`Ps1Launcher.addPs2CueSheet` in
[`test/support/ps1_launcher.dart`](../test/support/ps1_launcher.dart)) is
listed once the host gains LRPS2 and hidden again once a newer host without it
is put in place, with the setting kept on throughout: the rescan of
`RetroHostDownloadModel._lookAgain`. It replays the statuses in
[`test/support/ps2_host_recording.dart`](../test/support/ps2_host_recording.dart)
(described in [Emulator host client](<AnyPS5 Desktop - Emulator Host Client.md>) "PS2 games").
[`retro_host_play_golden_test.dart`](../test/ui/retro_host_play_golden_test.dart)
draws the PS2 rows and the PS2 missing-BIOS screen.

## Not yet

- **Save states wait for the host.** Save state and Load state show only with
  a host that lists `saveStates`, which no signed host release does yet. No
  real game was saved or loaded through the launcher: the host's own test of
  that branch saved and loaded Spyro on SwanStation and Jak and Daxter on
  LRPS2, and the launcher was tested against that host's recorded replies.
- **No resume state, no deleting a slot.** RetroArch's and DuckStation's
  resume state on quit (the host takes it as a `path` state) and a way to
  delete a slot are not in this menu yet.
- **No PS2 game seen running in the launcher.** LRPS2 boots nothing without a
  Sony BIOS, and none may be used in a test, so the launcher's tests have only
  the real core's missing BIOS. A manual run of the host alone (host main
  1b57932 with LRPS2 c0d39a58 on Windows, driven over the protocol as this
  launcher drives it, with a player's own BIOS dumps, no window) booted three
  PS2 games with a correct picture, sound, pad input and clean stops, at full
  speed but for one reading of 51.5 frames a second while the graphics card
  was near full use, probably by another program. Two of them saved to the
  memory card and loaded it after a restart; LRPS2 made each new card blank,
  and the games offered to format it. The launcher's own window, job object
  and Linux and macOS builds were not part of that run, and no signed host
  release ships LRPS2 yet (host `docs/ps2.md` "Releases").
- **No signed host release yet.** A release build offers the download, but
  the host repository has published no signed release yet, so the row says so
  ([Emulator host client](<AnyPS5 Desktop - Emulator Host Client.md>), "Not yet").
- **No phone pad.** A phone or browser pad (Remote Play's) does not play a
  PS1 game in the host, and does not move the launcher while the game's own
  screen is in front.
- **No mouse.** The mouse buttons and the wheel in a game's Controls are not
  read for a PS1 game.
- **No default menu key.** With only a keyboard, the game's menu opens with
  the mouse's right button, or with a key the player gave Home or Quick menu
  in Settings › Shortcuts: neither has one by default, and Esc is Start in the
  default Controls. A default key changes every game's shortcuts, so it is
  left for the signed install, before release builds find a host.
- **Graphics.** Of the graphics options the menu shows only the internal
  resolution. SwanStation's other graphics options (`GPU_*` and `Display_*`)
  are left for a Graphics page of their own;
  `RetroGameMenu.optionsIn(RetroOptionSection.graphics)` already gives them in
  the host's order for that page. LRPS2's other options titled "Video > …"
  (VR among them) stay under Advanced, as #171 left them; this change does not
  move them. There is no internal resolution row in
  Settings › Emulators and no automatic choice by graphics card or display
  yet. How long a PS1 change takes to show, and the row on a real game through
  the launcher, have not been seen: the tests use recorded statuses.
- **One copy per frame.** Each frame is copied once and uploaded through
  `decodeImageFromPixels`. A texture that shares the ring with the GPU would
  avoid the copy. That is worth doing only if a trace shows the copy costs
  frames.
