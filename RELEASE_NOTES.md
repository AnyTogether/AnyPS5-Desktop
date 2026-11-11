# Release notes

Notes for the next GitHub release, written as changes land. Each change adds one file,
`release-notes/next/<date>-<topic>.md`, holding its bullet (`- **What changed**, ...`), so that
pull requests do not conflict here. Do not add to the list under Next release below.
`bash packaging/release-notes.sh` prints the next release's notes: that list, then the files by
name. When a release is made, they go under its own heading here, the files are deleted, and the
section is copied into the release.

## Next release

Nothing yet.

## 0.1.22

- **Delete game.** Game Settings has a new action under Remove installation that takes the game
  itself off the disk: its own folder, the update and add-ons dumped beside it, and the zip or
  .ffpfsc it was unpacked from go to the Recycle Bin (the trash on Linux), and the installation
  AnyPS5 made from them is removed. The card names the folder and its size and starts on Cancel.
  Your saves and trophies are kept and come back when you add the game to the same folder again.
  Backups, cloud saves, captures and your AnyTogether profile are not touched. Where the files
  cannot go to the Recycle Bin (a drive without one, a folder too big for it), AnyPS5 asks again
  before deleting them for good. It never deletes a games folder itself, a game reached through a
  link that leads out of your games folders, or a game that is playing or being unlocked.
- **A module the dump holds twice no longer spoils the unlock.** Some dumps carry the same module in
  two folders: a `decrypted/sce_module` folder beside `sce_module` (Lost in Play), or `.prx` files
  next to `eboot.bin` that `sce_module` holds too (Minecraft). The relinker refuses two modules with
  one name. On older engines the unlock stopped with "Conflicting guest output filename". On newer
  ones it went on with the wrong copy, and Lost in Play stopped as it started. AnyPS5 now takes one
  copy of each such module, the one in `sce_module` first, and the unlock log names the copy it set
  aside. Every other module is converted where the dump has it, as before. For a game that failed
  this way, choose ⋯ → Unlock Again. Thanks to Slick Daddy for the report and its log, and to
  Lenny4250gh for tracking down the Minecraft case and proposing a fix.
- **Add Profile's name can be typed without the mouse**. Up from the two cards puts the cursor in
  the name, and Enter or Esc gives the keys back to the cards. While the name is typed, space,
  Backspace and letters such as O, Q and E are the name's (before, they chose a card, went back or
  ran a shortcut, and the cursor could jump out of the field).
- **A game made with another engine is rebuilt before it starts**. After an engine update (or
  another engine chosen), a game unlocked with the old one was offered "Update and play or Play
  now", and Play Together and a friend's game started it as it was, so two up-to-date launchers
  could end up with different builds that cannot connect. Play, Play Together and Join now rebuild
  the copy first with the usual progress, then go on. A newer engine to download is still offered,
  and after a rebuild that fails the old copy can still be played as it is.
- **A join that cannot go on says why in full**. A different game version or engine build opens a
  panel that names which of the two differs and shows the host's and yours whole, each on its own
  line (before: a one-line notice with the builds cut to six characters, such as "arm-ni" and
  "arm-f7"). It offers what fits: Rebuild and join when only your copy is stale, Check for updates
  when your release is the older one, Try anyway for a game version, and it no longer says "update"
  to the side that is already newer.
- **Play on a game a friend already hosts asks first**. When a party member or friend hosts a game
  of the same title that still has room, Play asks "Ana is playing this. Join their game, or start
  your own?" with Join first, instead of quietly opening a second session. Start my own game says
  that a separate session was made.
- **The party shows who is in whose game**. Each member's row in the party, and the quick menu over
  a game, says "In your game", "In another game of Orbit Runner", "Playing Orbit Runner" or "Not in
  a game", with Join right there for a game that takes players. Play Together explains in one line
  that a party is voice and chat and that the game session is what connects the games.
- **Now playing in the quick menu** (asked for by Slick Daddy), as on the Mac. While a music or
  video player plays or is paused, the menu over a game shows its title, artist, player and cover,
  with previous, play or pause and next: left, right and ✕ on the controller, the arrow keys and
  Enter, or the mouse. It reads Windows' media session and MPRIS on Linux, so it works with any
  player that tells the system what it plays and needs no account. Settings › Behaviour has its
  switch, and a second one, off until you turn it on, that shows your AnyTogether friends what you
  are listening to. The player is read only while the menu is open or while friends are shown it.
- **Remove installation keeps your saves.** A game's saves and trophies live inside the installation
  AnyPS5 builds, and Remove installation used to delete them with it without saying so. It now keeps
  them, together with the game's download data, in the games folder under `.AnyPS5/Saves`, and they
  come back when you unlock the game again, the same way as after Delete game. The card says they
  are kept. When they cannot be moved aside the installation stays as it is and AnyPS5 says why.
  Saves are also safe when an unlock is interrupted or fails just as the new installation takes the
  old one's place: they go back into the game or wait for the next unlock.
- **Update from Git says everything it needs at once, and how to install it.** When build tools were
  missing, Update from Git named one, and after you installed it, the next. Now it looks for all of
  them before it pulls anything (Git, CMake and, for a checkout without a build folder, Ninja and
  the C and C++ compilers, plus the X11 development files on Linux) and lists every missing one
  together. Under the failure there is the command that installs them, ready to copy: winget on
  Windows (WinLibs GCC 15.2, which brings gcc, g++, CMake and Ninja), Scoop where only Scoop is
  installed, and apt, dnf or pacman on Linux. On Windows, WinLibs and Ninja install for your user
  only, so the launcher can also run that command itself and show what it prints. Commands that need
  administrator rights (Git's installer, sudo on Linux) are only ever shown to copy. Check again
  looks for the tools again without restarting AnyPS5: on Windows it reads PATH anew, so what you
  just installed is found. On an Ubuntu whose own GCC is older than 12, gcc-12 and g++-12 are used
  when they are installed, as the build guide does. Reported by Slick Daddy.
- **Switch profile from the picture on Home.** Point at your profile picture at the top right (or
  click it, or move to it with the keys or the controller, one step past the last button) and a list
  drops down under it: the other profiles with their picture and name, AnyTogether's mark on the
  ones linked to an account, and Add profile at the end. Choosing one plays as that profile at once,
  with the same rules as the "Who's playing?" screen (not while a game runs or saves sync). Escape,
  Back, moving the pointer away or a click elsewhere closes it. Suggested by Slick Daddy.
- **Pick your country by name.** Settings › AnyTogether › Country was a text field that wanted a
  two-letter code and took more than two letters. It is now a list of countries by name in the
  launcher's language, with a search that ignores capitals and accents and also finds a country by
  its English name or its code, and None at the top to clear it. Messages AnyTogether sends back
  when it refuses something are now said in the launcher's language too, where the server's English
  sentence was shown before. Reported by Slick Daddy.
- **Paired phones show what they are.** In Settings › Phones each paired device has a sign before
  its name: Android, an iPhone or iPad, a browser, or a plain phone when the name does not say. A
  browser used as a controller is listed as "Android browser" or "iPhone browser" in your language
  in place of "Android · Web", and a device connected now says so under its name. Suggested by Slick
  Daddy.

## 0.1.21

- **A game in one .ffpfsc file installs like a zip**, as on the Mac: drop it in a games folder or
  use Add game file in Settings. AnyPS5 unpacks it into a normal game folder with its name, title ID
  and icon, and says so plainly when a file is compressed or of a kind it cannot unpack.
- **ffmpeg can be downloaded with one press** when Replay, Remote Play, Go Live, a video background
  or clip tools need it and none is found: progress, Stop and a true error message, from a signed
  build this project publishes, kept beside the toolkits. An ffmpeg already beside the launcher or
  on the PATH keeps being used.
- **The activity feed reads as on the Mac**: game icons from the server, a new friend's picture and
  milestone signs when a game isn't in your library, the rarity on trophies, hidden trophies
  labelled instead of left out, and the four reactions as emoji, shown on the focused item and where
  someone chose them. A new item coming in no longer moves the focus.
- **Captures says when this server keeps no files** instead of a read failure.
- **Leaderboards**: the number of players next to the board, and Enter (or the new chip) on a game's
  trophies opens its board.
- **Challenges**: the page shows who is leading before it is final, says "Score" and a plain number
  for a metric this launcher doesn't know, says when a challenge was deleted, and reads it again
  after a conflict on Join or Leave.
- **Play Together player rows say how each player is reached** (Direct or Relay, with the round trip
  in ms), as on the Mac. Where the system cannot say, the row stays at Connected.
- **A Play Together offer or a game invite is said over the game** in a desktop notice, as on the
  Mac, unless you're on Do Not Disturb. The party offer shows a friend's private name.
- **Party chat has quick replies**, as on the Mac: Hello, GG and the others, sent with one press.
  The Party tile gets a dot when someone writes while the party screen is closed, a parent's rule
  against messages hides the chat, and after a lost connection the chat reads every page it missed.
- **Play on a second game from the phone switches games**, as on the Mac. The game playing closes
  and the one you picked starts once it has gone and its saves have synced. Before, the first game
  closed and nothing else happened.
- **The phone sees a game starting**, as on the Mac: its activity card says when a game is waiting
  or starting, counts the time from when the launcher began, and shows on a phone that connects
  later. Close on the phone gives a game's start up.
- **The phone's D-pad brings the launcher forward**, and a phone pairing or connecting while a game
  is in front is said in a desktop notice, as on the Mac.
- **Game art and trophy icons reach the phone smaller**, as on the Mac: 256 pixels for icons, 1280
  for backgrounds and 160 for trophy icons, kept after the first time.
- **While a game runs, the main button brings it to the front**, as on the Mac. Stopping it stays in
  the game's menu and the quick menu.
- **With the family media setting off, no trophy picture is taken**, as on the Mac.
- **Noise suppression has its own switch** beside the microphone in voice settings, on by default.
- **Public profile switch** in AnyTogether settings, as on the website.
- **Lower resolution applies at each start** on Windows and Linux, as on the Mac, when the toolkit's
  output can take it. Otherwise the game keeps the resolution it was installed with.
- **Choose the broadcast microphone on Windows** in Settings › Broadcasting.
- **The replay buffer, Remote Play and broadcasting can record under Wayland on Linux.** Your
  desktop asks which window to share, and you choose the game. The launcher says so when you turn
  the replay buffer on, and the desktop can remember the window next time. It needs PipeWire,
  xdg-desktop-portal and GStreamer's tools with its PipeWire plugin. The launcher names what is
  missing. Not yet tested on a real Wayland desktop. X11 records as before.
- **Join with a code works for watching a share play too**, as on the Mac: Party › Join with a code
  looks a code up as you type it (a party's or a share play's), even while you're in a party, and
  asks to join or to watch. A yes shows up as an invite.
- **A share play guest can help player 1** instead of playing their own, as on the Mac: Assist
  Player 1 in the share play's quick menu rows.
- **A friend's trophy level and the party's lead now say so**, as on the Mac: a word when a friend
  levels up (not while you're in a game), when you lead the party, and when you hand it over or
  remove someone.
- **Nightly now updates the launcher too**, as on the Mac. On the Nightly channel the launcher
  offers the newest build of main for itself, once it is signed, beside the engine in the engine
  picker. Going back to Stable keeps that build until a newer release comes out.
- **Send a picture in any chat**, as on the Mac: a conversation's options (△) have Send a photo, for
  several files at once, in conversations that aren't encrypted too. Each one is drawn again here,
  so no location or camera data goes along.
- **Drop pictures on an open chat** to send them, as on the Mac.
- **Voice notes play inside the launcher**, as on the Mac: play and pause in the bubble, bars and
  the time as it goes, one at a time. One the launcher cannot open goes to the system's player, as
  before.
- **The typing line names everyone who is typing** in a group, as on the Mac.
- **Update from Git sets up the build folder itself**, as on the Mac. An engine folder that is a git
  checkout without a build folder no longer stops at "no build folder yet". With Git, CMake, Ninja
  and a C++ compiler (g++) on PATH, the launcher runs the CMake setup the build guide shows, with
  its progress, then pulls and builds. When a tool is missing it names it and opens the right guide:
  upstream AnyPS5's build guide for an upstream checkout, AnyPS5-ARM's for its own.
- **A new install gets the AnyPS5-ARM engine.** On a first start the welcome downloads AnyPS5-ARM's
  engine, which reads the phone controller and opens games full screen or at the window size you
  chose. If you already use upstream's engine, nothing changes on its own.
- **Switch to the AnyPS5-ARM engine in one press when your phone can't reach a game.** With
  upstream's engine in use, connecting a phone or a browser pad, or ending a game that ran with one,
  offers the switch. It downloads the engine and uses it, and Update and play unlocks each game with
  it. Settings › Phones offers the same.
- **A dump without PlayGo chunk files no longer ends at a dead end.** When a game stops because
  sce_sys/playgo-chunk.dat and playgo-scenario.json are missing, the crash report offers to switch
  to the AnyPS5-ARM engine and play again, or to play once more with the missing chunks counted as
  installed (that start only).
- **Quit AnyPS5? is a small yes or no**, as on the Mac: Cancel and Quit side by side, ← and →
  between them, Esc still cancels, Quit in red. Close the game? asks the same way.
- **Linked profiles show it on Who's playing?**: AnyTogether's mark on the tile of a profile linked
  to an account, with its @handle, and Local under one that stays on this PC.
- **Appearance › Themes opens beside the home screen**, like the Theme Studio, so a theme you pick
  shows behind the list at once. A row that takes the focus no longer reads dark on dark while its
  highlight fades in.
- **A game's window or full screen is easier to find**: the row in the game's options (… / △) is now
  called Window or full screen, and says that full screen is borderless with the AnyPS5-ARM engine.
  Settings › Default display still sets it for every game.
- **Clearer words in Turkish for friends**: Arkadaşlardan çıkar, and what your handle is for.
- **Clips play inside the launcher**, as on the Mac. A clip in a game's gallery, a clip post in
  Captures and a clip in a chat play over the whole screen, from the start and over again, with
  their sound. In the gallery ← and → move to the next picture or clip, and ✕ or ○ close it. The
  pointer brings a bar to pause and move through the clip. A clip the launcher cannot open goes to
  the system's video player, as before. Photos in chats open over the whole screen too.
- **Photos sent from the website show in chats**, with their caption and in their own shape. A photo
  sent as it is (not end-to-end encrypted) used to show only as "[photo]".
- **Delete for everyone** is what the message menu calls removing your own message now (it was
  Unsend, "Geri al" in Turkish). It still asks first.
- **Devices in the encryption sheet go by their kind** ("Windows PC", "iPhone") and the day they
  were added, never by the computer's own name. This launcher now registers itself as "AnyPS5 on
  Windows" or "AnyPS5 on Linux".
- **How many are online now** by Find players' heading, as on the Mac and the website. It is a
  number only. Accounts that are invisible or hide their status are not counted, and the line's
  tooltip says so.
- **A game's name in recent activity opens its hub**, as the website links it to the game's page.
  Click the name in the feed or on a profile, or select an item on a profile.
- **The browser pad goes full screen when you turn the phone**, as on the Mac. Turned to landscape,
  the next touch on the pad takes it full screen and holds it in landscape, where the browser allows
  it (Android, iPad). Before, it tried once on the first press, which browsers refuse, so full
  screen was only in the menu. On an iPhone, add the page to the Home Screen.
- **Share play for more than four viewers**, as on the Mac. With AnyTogether's media server (up to
  16 viewers now), the Viewers row goes up to what the server takes. Past four, the game's picture
  and sound go once to the media server and everyone watches from there, while viewers you let play
  keep their direct link. A viewer's line says when they watch through the media server.
- **List your share play in public**, as on the Mac: off, anyone can ask, or anyone can watch, under
  Live now if you like, and in a language. People who ask to watch show in the quick menu with Let
  them watch and Not now, and the ones who asked with your code say so.
- **A join code for your share play**, as on the Mac: make one, copy it or its link, make a new one
  or stop it. Anyone with it can ask to watch, and you still say yes to each one.
- **Watch a big share play through the media server**, as on the Mac. In a share play with more than
  four viewers you watch from the media server until the host lets you play, then straight from the
  host, and back when they take the pad. The corner chip says when the picture comes through the
  media server.
- **A controller's battery in percent** where the system measures it, as on the Mac. On Linux it
  comes from the pad's power supply (DualSense, DualShock 4 and other pads whose driver gives a
  percentage). On Windows a DualSense or DualShock 4 is read from its own report. Pads the system
  has no percentage for keep the four levels.
- **An iPhone on a USB cable reaches the launcher without Wi-Fi**, as on the Mac. The launcher opens
  the phone app's port over the cable through usbmuxd and joins it to its phone server. On Windows
  that is Apple Mobile Device Support (it comes with iTunes or the Apple Devices app), on Linux the
  usbmuxd package (libimobiledevice).
- **Arabic and Urdu are laid out right to left**, as on the Mac. Every screen is mirrored, the games
  after the selected one sit on its left, and ← and → (and a mouse drag on the games and the
  sliders) follow what the screen shows. A share play you watch keeps the controller as it is.
- **Hide the launcher while a game runs**, as on the Mac (Settings › Behaviour). The launcher's
  window is minimized once the game starts and comes back when it closes. PS still brings it back
  with the quick menu, and Resume puts it aside again.
- **Check for updates can be turned off**, as on the Mac (Settings › Behaviour). Off, the launcher
  and the engine look for new versions only when you ask in Settings › About.
- **A game's Advanced page**, as on the Mac (Game settings › Advanced): each stick's dead zone, the
  mouse as the camera (sensitivity, vertical speed, response curve, minimum tilt, maximum speed,
  smoothing, center after), the slow movement amount and the keyboard's stick and trigger ramps,
  written to the engine's input file as the Mac writes them. The shader cache switch and Export and
  Import settings moved there, with Reset advanced settings.
- **Edit your AnyTogether profile here**, as on the Mac: **Settings › AnyTogether › Your profile**
  has your display name, bio and two-letter country, with **Save profile**, and your handle with
  **Change handle** and the day it may change again.
- **Who sees what**, as on the Mac: under it, a choice of Everyone, Friends or Only me for your
  games and play time, trophies, friends list and being online and playing, and whether people find
  you by name. Where the server keeps files, your gallery has its own choice too.
- **Start a group chat**, as on the Mac: **Messages** lists **New group** under your conversations.
  Pick the friends, give it a name if you like, and **Start the group** opens it to write in.
- **Call a friend**, as on the Mac: **Friends** has **Call** under every online friend. A call to
  you rings with their picture over the launcher (Enter answers, Esc declines). Over a game a notice
  says who calls, and where the launcher reads keys over a game (Windows, and X11 on Linux, as for
  the talk key) Alt+A answers or Alt+D declines without leaving it. A call nobody answers is said as
  a missed call. In a call, Friends shows who you talk to, whether they muted or deafened, the
  microphone, Deafen, push-to-talk and **Hang up**. The voice is the party's, so the same microphone
  and talk key work.
- **Captures**, as on the Mac: **Friends › Captures** shows the screenshots and clips you, your
  friends and players you met shared. Like one at once, read and write comments with one level of
  replies (quick ones like GG too), view the picture, delete your own, and △ opens who posted it.
- **Share from the gallery**, as on the Mac: △ on a screenshot or clip opens **Share**. **Share to
  AnyTogether** writes a post with a caption and Friends or Public, **Send to** puts it in one of
  your chats (sealed where the chat is end-to-end encrypted), and **Share to my gallery** pins it to
  your profile. A clip longer than a post takes is said before anything goes up, and one too big is
  made smaller with ffmpeg first. Without a server that keeps files, △ shows the file in its folder.
  Photos and clips sent this way show in the chat, here and on the Mac.
- **Place and zoom your profile picture**, as on the Mac: a picture you choose opens in a crop,
  where you drag it inside the circle and zoom with the slider or ← →, then **Save**. Signed in,
  **Use as my AnyTogether picture** puts it on your AnyTogether profile, and **Use my AnyTogether
  picture** brings the one there to this profile.
- **Deafen in party voice**, as on the Mac: hear nobody, with your microphone off, and the others
  see you deafened. Turning it off puts your microphone back as it was, and turning the microphone
  on hears everyone again.
- **Each game can have its own engine**, as on the Mac: Game Settings › Engine picks the default or
  any downloaded engine, of either source, with what unlocked the game under it. A game whose chosen
  engine is not on this computer says so before unlocking and offers the download.
- **Delete one engine version**: a row for each downloaded version in Settings › AnyPS5 Engine, as
  on the Mac. An engine a game or the default is using stays.
- **Battery & heat can lower the resolution**, the row the Mac already had: a game with a resolution
  option is installed one step lower while the profile holds. On Windows and Linux the resolution is
  written when a game is installed, so it takes effect at the next install.
- **About has What's new, Made by, GitHub and the upstream project**, as on the Mac. What's new
  shows while an update is on offer and opens that release's page.
- **Settings › Fonts lists Latin Italic**, the row the Mac has, beside Latin.
- **Settings › Phones says which paired phone is connected now**: the count at the top and Connected
  beside the phone's name, as on the Mac.
- **Broadcasting has a microphone**, as on the Mac: Settings › Broadcasting mixes your commentary
  over the game's sound at the level you set, and it can be switched while you are live. Windows
  shows a small LIVE badge over the game that viewers do not see. Linux has no badge, because
  anything drawn over the game would be recorded too.
- **Cloud storage lists your photos, clips and voice notes**, as on the Mac: delete one with a
  second press, and a bar shows how much saves and media take.
- **Restore saves… restores the backup you choose**, as on the Mac. The latest backup can still be
  restored in one press.
- **A profile shows its pinned gallery**, as on the Mac: the photos and clips someone pinned, as
  their privacy setting shows them, open over the whole screen.
- **The community's verdict is on the home screen**, as on the Mac: how the game runs on this
  platform, once people have said so.
- **A game's options lead to its hub**, as on the Mac.
- **Family notifications say what they're about**, as on the Mac: who asks for more time or a game,
  what a parent answered, and family alerts and invites.
- **Notices while you play are now a card over the game**, as on the Mac: captures, phone pairing,
  invites, calls and family time limits on Windows and X11. Wayland, where nothing can be placed
  over a game, keeps the system notice.
- **One player now reads as one player** in Find players, leaderboards and game invites, instead of
  "1 players".
- **Screen readers now read Activity, Leaderboards, Challenges, Compare, Profile, Share Play and the
  first-start steps**, and Party, Play Together and Find Players rows read their words, as on the
  Mac.
- **Stop share play and Remove ask first** in the quick menu, in place with Cancel focused, as on
  the Mac.
- **Launcher crash reports say how the run ended.** After the launcher closed without being closed,
  Send Report now adds what Windows Error Reporting kept of it (the module that faulted and the
  exception code, with the report file to attach) or Linux's core dump of it (the signal and the
  crashed thread), or the kernel's out-of-memory kill, and says so when the system kept nothing.
  Each line of the last seconds also has the launcher's memory.
- **The .deb names every library the launcher needs**: 0.1.20's Depends left out the libraries the
  bundled SDL2 links (ALSA, Wayland, xkbcommon, Xcursor, Xi, Xinerama and the rest), so on a system
  without them SDL2 could not load and controllers fell back to the older reader. The packaging now
  stops when a linked library has no package to name, Ubuntu 24.04's renamed packages are listed as
  alternatives (`libasound2 | libasound2t64`), and every change installs the .deb on clean Ubuntu
  22.04 and 24.04 and checks that the launcher and each library it carries find everything they
  link.
- **Do Not Disturb is quiet now**, as on the Mac: a message, a friend request, a party invite, a
  game invite, a Play Together offer and a share play invite come in without a sound while you are
  on Do Not Disturb (the toast still says them). Off Do Not Disturb a share play invite now brings
  the notice sound behind another window, like the other invites.
- **Do Not Disturb keeps the controller still for invites**, as on the Mac: a game invite, a party
  invite and a Play Together offer no longer ring on the controller while you are on Do Not Disturb.
  Off Do Not Disturb they ring as before, and a call still rings either way.
- **The LIVE badge on Linux (X11)**, as on the Mac and Windows: while you broadcast, the small badge
  shows over the game and viewers do not see it. The broadcast now records the game's window by
  itself (x11grab's window_id, ffmpeg 4.4 or later) instead of its area of the screen, so under a
  compositor nothing drawn over the game is in it. The badge needs a compositor and stays hidden
  while the replay buffer or Remote Play records the screen. Under Wayland it stays off for now.
- **No build folders in the Linux packages' library paths**: some plugin libraries in the .deb, the
  AppImage and the .tar.gz kept the release build machine's folders (`/home/runner/...`) in their
  RUNPATH, which namcap reports as insecure, as a folder by that name could hand them other
  libraries. The packaging now leaves every bundled library looking only beside itself and in the
  bundle (`$ORIGIN`), and every change checks that no library in the bundle, the .deb, the AppImage
  or the .tar.gz looks anywhere else.
- **Scoop and Arch package copies leave updates to their package manager**: the launcher sees when
  Scoop installed it (its app folder, also under a custom `SCOOP` or `SCOOP_GLOBAL` root) or when
  pacman owns it (`anyps5-desktop-bin`). It still checks for updates when **Settings → Behaviour →
  Check for updates** is on, but instead of downloading and running the installer, which under Scoop
  put a second copy in `%LOCALAPPDATA%\Programs\AnyPS5 Desktop`, it says a new version is out and
  how to get it: `scoop update anyps5-desktop` (Settings › About copies the command), or your
  package manager on Arch. These copies follow the stable releases, so Update Channel is not shown
  for them. The installer, the zip, the AppImage, the .deb and winget update as before.
- **Install with Scoop or winget.** On Windows, `scoop bucket add anytogether
  https://github.com/AnyTogether/scoop-bucket` then `scoop install anytogether/anyps5-desktop`
  installs the portable zip with a Start menu shortcut. `winget install AnyTogether.AnyPS5Desktop`
  installs the installer once its submission to winget's repository is accepted (pending review).
  Update a Scoop copy with `scoop update anyps5-desktop`. On Arch Linux, the `anyps5-desktop-bin`
  package is in [AnyTogether/linux-packages](https://github.com/AnyTogether/linux-packages) (not on
  the AUR yet). The Scoop manifest and the Arch package follow each stable release by themselves.
- **Relinker options per game.** A game's Advanced settings have a Rebuild options section with
  Trace system library calls (`--trace-imports`), so detailed logging can record the game's system
  library calls. It is used on the game's next rebuild (Unlock again). An engine that does not have
  it says so, and the game is rebuilt without it.
- **Friends, parties and messages reach you over the game**, as on the Mac: a friend request, a
  party invite, a message, a share play invite, someone in for your Find players post, someone
  asking to join your party or to watch, and being let in from a post now show as the card over the
  game (the system notice on Wayland or with no game open). Do Not Disturb keeps requests, invites
  and messages off the game. A request to join your party now reads "asks to join your party", as on
  the Mac.
- **Uninstall no longer freezes the launcher on a big game.** The game is uninstalled at once and
  its files are removed in the background, so the screen keeps answering however often it is clicked
  meanwhile. Unlocking it again right away waits until the old files are gone.
- **Cards over the game under Wayland on KDE Plasma, Sway, Hyprland and the other desktops with
  wlr-layer-shell**, as on the Mac: trophies and notices while you play are a card over the game
  instead of a system notice, and the LIVE badge shows while you broadcast (the desktop shares the
  game's window alone, so viewers do not see it). It needs gtk-layer-shell (libgtk-layer-shell0 on
  Ubuntu and Debian, which the .deb recommends). GNOME has no such layer and keeps the system
  notice.
- **The heat profile works on Windows**, as on the Mac and Linux: the launcher reads the graphics
  card's temperature from the NVIDIA or AMD driver (on a laptop only while a game runs, so a
  sleeping card is not woken) and the thermal zones Windows gives every program. Where the
  processor's temperature needs administrator rights, Settings › Battery & heat offers Read the
  processor's temperature: Windows asks once each time the launcher starts and a small reader runs
  beside it, while the launcher itself never runs as administrator. Say no and the row says so, and
  the battery profile keeps working.
- **Your own relinker options and launch options per game** (asked for by Hog). A game's Advanced
  settings have Custom relinker options under Rebuild options, added after the launcher's own on the
  next rebuild (Unlock again), and Launch options in a new Launch section: variables as NAME=value
  first, then arguments for the game, as in `APS5_REPORT=0 --aps5-report=off`. A variable the
  launcher already sets keeps the launcher's value, and the game's log says which ones. Every
  keystroke is checked: an option the launcher sets itself, one that would break the rebuilt game,
  one the relinker does not have, or a quote left open is not saved and the row says why. A relinker
  that stops with your options rebuilds the game without them.
- **Linux uses the system's libmpv for clips and voice notes**: the packages no longer carry a
  libmpv and the 129 libraries it pulled in, so the .deb, the AppImage and the .tar.gz are much
  smaller. The .deb brings libmpv from apt (`libmpv2`, or `libmpv1` on Ubuntu 22.04), and the Arch
  package depends on `mpv`. With the AppImage or the .tar.gz on a system without libmpv the launcher
  still starts and works: a clip shows its picture with the command that installs libmpv on your
  distribution and a button that opens it in another player, and voice notes open in the system's
  player.
- **Remote Play recovers faster on Windows and Linux**: when the phone loses part of the picture and
  asks for a key frame, ffmpeg now makes one on request instead of the phone waiting for the next
  regular key frame, up to a second away. An older ffmpeg without this ability keeps the
  once-a-second key frame.
- **The Windows package now carries the clip player's licences**: `libmpv-LICENSE.txt` beside
  `libmpv-2.dll` (GNU LGPL version 3 or later, with where its source is) and `ANGLE-LICENSE.txt`
  beside the ANGLE libraries. The .zip and the installer both take them. On Linux the bundle now
  also carries the full licence texts its libraries' copyright files refer to.
- **A Windows build can no longer leave out SDL2**: a failed `SDL2.dll` download now stops the build
  (three tries first), and packaging stops if the DLL is missing from the build output, so no
  package goes out with SDL2 controller support missing.

## 0.1.20

- **A profile shows the person's recent activity**, as on the Mac: the trophies, platinums,
  first plays, long sessions, new friends and milestones they shared, under their recent
  trophies, with the reactions each item got. It follows what they let you see, and an item
  that changes while the profile is open changes there too.
- **Watch a friend's share play here**, as on the Mac. An invite shows in **Friends**, with
  **Not now** beside it. A friend sharing who lets friends walk in shows there too, and **Find
  Players › Live now & parties** lists the share plays anyone can watch or ask to watch. The
  game fills the screen with who shares it, the round trip and the picture's size in a corner.
  Once the host lets you play, your controller is their player 2, 3 or 4, and a badge shows
  which. PS leaves. While you only watch, Esc and ○ leave too. The sound comes as an Opus track,
  or as plain sound on the data channel from hosts that send only that.
- **Share play sound reaches every viewer.** The host now sends the game's sound the way the
  Mac does: plain sound on the data channel to everyone (the phone app and older launchers play
  only that), and an Opus track to viewers who ask for it (the website, the Mac and this
  launcher), with no doubled sound. The Linux build now has the loopback capture the Opus track
  needs (it links PulseAudio's client library, which PipeWire systems have too).
- **Each viewer's line in the quick menu** says whether they play or watch, whether the link is
  direct or through the relay, its round trip, and the picture they get (720p60, 540p30).

- **Party chat.** The party screen has a text chat beside the voice, with replies, reactions,
  edits and typing. It stays out of the inbox, so it adds no unread count or toast.
- **End-to-end encrypted direct messages.** A one-to-one conversation is sealed on this
  computer, and only the two people's devices can open it. The lock under the name shows the
  safety number to compare, and a notice says when someone's devices change. Groups, community
  chats and calls are as before. Chats with apps that have no keys yet stay plain and say so.
- **Challenges on the leaderboards.** A strip of challenges sits over the board. A challenge's
  page shows its window, the standings and your place, with Join and Leave. Challenges are made
  on the website.
- **Profile themes and a showcase.** A profile wears its theme's colours and picture and shows
  up to six pinned trophies and games. **Edit showcase** and **Profile theme** are on your own
  profile, and a Hub theme can be worn on your profile from **Settings → Appearance → Themes**.
- **The phone as a headset.** When the party's voice moves to your phone, this launcher goes
  quiet without leaving, and **Take the voice back** brings it here again.
- **Share play and voice for bigger groups.** The launcher can watch a share play and join party
  voice through AnyTogether's media server. The media server is still being set up. Until it is
  live, share play and party voice stay peer to peer as before, with up to four viewers and
  eight voices.
- **Settings search.** A field in Settings finds settings by name and description in any
  section. Ctrl+F or up from the first row reaches it.
- **Launcher volume** in **Settings → Behaviour**, from 0 to 100 percent, over the interface
  sounds and the music.
- **Messages open the right conversation.** A click or a message notification now opens that
  conversation, ready to answer. Before, the thread could stay on the one open before.
- **Theme Studio steps** are bigger: 20° for hue and accent, so a full turn takes 20 presses or
  fewer.
- **A phone drives the launcher.** The phone app and the browser pad move around the launcher
  while no game runs, and Options opens Settings.
- **The browser pad's menu** is a small round key between the sticks. A tap outside closes it,
  "Disconnect" replaces "Leave", Reconnect works without a new scan, and the pairing code shows
  in portrait.
- **Upstream's nightly engine** on the **Nightly** update channel: **Settings → AnyPS5 Engine →
  Upstream** offers upstream AnyPS5's newest main, built daily and signed. It is untested.

## 0.1.19

- **Fourteen more languages, by VK:** Amharic, Czech, Danish, Filipino, Hungarian, Khmer,
  Korean, Lao, Malay, Norwegian, Romanian, Swedish, and Simplified and Traditional Chinese.
  Each is about three quarters translated, and the rest shows in English.
- **The first start speaks your language.** Without saved settings, the launcher starts in the
  first of the computer's languages it has.
- **The first step fits.** The language cards now take seven columns and share the space, so all
  of them fit at 1600 by 900. A long name is drawn smaller and never cut off.
- **Back goes where you came from.** From My profile, the feed, leaderboards or comparisons,
  Back returns to the row you left.
- **Faster theme steppers.** Colour and Accent go round the circle the short way, and a held
  arrow speeds up.
- **Cancel a friend request you sent**, and **hand the party over** to someone else as leader.
  The launcher asks first.
- **Battery caps up to the display's rate**: 60, 90, 120, 144, 165, 240 or 360 FPS, with the
  display's own rate marked.
- **The phone controller pill** shows only while a phone is connected or connecting, and it
  reads "Phone controller".
- **Clearer settings.** Setting titles are in sentence case in English and Turkish. "Key
  location" and "Detailed logging" read more plainly, and Fonts moved near the end. Notifications
  say "Nothing new" once.
- **The repository is now AnyTogether/AnyPS5-Desktop.** Updates, crash reports and links use
  the new name. GitHub redirects the old one, so older launchers keep finding updates.
- **The .deb recommends the Noto fonts** for Khmer, Lao, Amharic and Chinese, Japanese and Korean.

## 0.1.18

- **Save Sync** in **Settings › Behaviour**: each game's saves and trophies stay the same on
  your other computers. They are brought over before a game starts and sent after it ends. It
  works through a folder your computers share (OneDrive, Dropbox, Syncthing or a network drive,
  and iCloud Drive where iCloud for Windows set it up), in the Mac launcher's own layout, so a Mac
  and a PC can share one folder. Signed in to AnyTogether, it can go through your AnyTogether
  cloud instead, in parts that pick up where they stopped. When both sides changed, the launcher
  asks which to keep, and the other stays as a backup. **Cloud Storage** shows each game's cloud
  saves, with Restore and Delete. While saves sync, the game does not start twice and the profile
  does not change. A server that keeps no files yet hides the cloud choices.
- **Settings › Battery & Heat.** On battery (or with battery saver on) and when the processor
  runs hot, a game can be held to 30, 40 or 45 FPS, its frame generation paused and the
  launcher's Glass blur and animations turned down. Plugged in and cool, nothing changes. The
  cap and the pause change at once, during a game too, with the AnyPS5-ARM engine. A note shows
  over a game that runs hot, and **Undo** is in the quick menu. The battery is read with
  GetSystemPowerStatus on Windows and from /sys on Linux. The heat comes from the processor's
  sensors on Linux. Windows tells programs no temperature, so there only the battery profile
  works, and the page says so. The profiles are the Mac's, with its settings keys.
- **Theme Hub**, as on the Mac. **Settings › Appearance › Themes** lists the themes people share
  on AnyTogether's Hub, and one choice downloads, installs and uses a theme. **Share on the Hub**
  uploads the theme in use with a picture in its colours while you are signed in. A theme shared
  before goes up as its new version. Signed out, it saves the file and opens the page to send it
  from. An `anyps5://theme/<ID>` link installs that theme from the Hub.
- **Theme Studio.** Make your own look in **Settings › Appearance › Theme Studio**, with the
  launcher showing each change behind it: the motion, the colour, the highlight, the lightness,
  the accent, a picture or video behind it all, and menu music. **Save as a File…** makes one
  `.anyps5theme` file. It is the same file as the Mac launcher's, so themes move between the two.
- **Theme files open with the launcher.** Double-click a `.anyps5theme` and the launcher
  installs it and puts it on. A launcher already open takes it. **Settings › Appearance ›
  Themes** lists the built-in looks and yours, and has **Install from a File…**.
- **Your own picture or video as the background, and your own menu music**, in **Settings ›
  Appearance**. A video loops without sound. It plays with ffmpeg, beside the launcher or
  installed, as clips do. The menu music plays when the selected game has no song of its own.
- **Update Channel** in **Settings › About**: Stable or Nightly. On Nightly the engine picker
  also offers the nightly AnyPS5-ARM engine, built from main on the days it changes, once it is
  signed. Stable never offers going back to an older engine than the one in use.
- **Activity, leaderboards and notifications from AnyTogether**, as on the Mac. **Friends ›
  Activity** shows what your friends have been playing: trophies, platinums, first plays, long
  sessions, new friends and milestones. Each item takes one of four reactions. Left and right
  pick one, Enter gives it and △ opens the person's profile. **Friends › Leaderboard** ranks
  trophy points among friends or everyone, with your own place. A game's settings open its own
  board by points, play time or completion. A **bell** in the top bar, while you are signed in,
  holds AnyTogether's notifications with the unread count. Choosing one marks it read and opens
  where it points.
- **How did it run?** After a game of a minute or more, the launcher asks once per game and
  launcher version how far it got. One choice sends the report to AnyTogether's compatibility
  list with the launcher and engine versions, the computer and the system. A game's settings
  show what the community found on Windows or Linux and send a report any time. **Don't ask
  after games** turns the question off.
- **Find Players**, as on the Mac. **Friends › Find Players** shows people looking for a group,
  filtered by game, purpose, language and what starts soon. Select a post to say I'm in, and
  select it again to take that back. **Find players for** a game, in its settings or on the
  board, posts what you want to play with the slots, languages, start, how long it stays up and
  a note. **My Posts** lists who wants in, to let them into your party or say not now. **Public
  Parties** lists parties their leader opened to everyone, to ask to join or walk in. **People**
  suggests players to add. A game's **hub** shows who plays it now, its posts and parties, its
  leaderboard and how it runs. A party's leader can list it in public from the party panel.
  **Settings › AnyTogether** chooses whether people who don't know you find you, and the
  languages you play in. Share plays under Live now are left out, since this launcher has no
  share play to watch yet.
- **Share play: friends watch your game, and up to three play along.** While a game runs, the
  quick menu has **Share** for it (signed in to AnyTogether). Friends watch live in a browser on
  anytogether.net. **Let Them Play** hands a friend player 2, 3 or 4, and
  their controller reaches the game through the phone server's bridges, so it needs the phone
  server on and the AnyPS5-ARM engine. Invite online friends, open it to friends, choose how many
  may watch, and stop it from the same menu. It ends with the game. The picture and sound go
  from this PC straight to each friend over WebRTC, as from the Mac. Watching a friend's share
  play in this launcher is not here yet: use the website for that.
- **Remote Play: the game's picture and sound on the phone.** The phone app's Remote Play now
  works with the Windows and Linux launcher, with the same app as on the Mac. The launcher
  records the game's window with ffmpeg and encodes it at once on the graphics card (NVIDIA,
  Intel, AMD, or VA-API on Linux) when it can, and with x264 otherwise. Sound comes from the game
  alone on Windows 11 and on PulseAudio or PipeWire. Older Windows 10 sends everything the PC
  plays. It needs ffmpeg beside AnyPS5 or on the PATH, and an X11 session on Linux. A key frame
  comes every second, so a picture broken by a lost packet mends within a second.
- **Broadcasting to Twitch, YouTube or any RTMP server.** Set the service, the stream key and the
  quality in **Settings › Broadcasting**. The key shows as dots and is kept in a file only your
  account can read. Go live from the quick menu while a game plays, or with **Go Live** on the
  phone. The launcher shows how long you have been on air, the bit rate and dropped frames, and
  tries again a few times when the connection drops. It uses ffmpeg, with the graphics card's
  encoder when one works.
- **Clips carry the game's sound,** and the replay buffer encodes on the graphics card when it
  can, which takes far less of the processor. **Create** on the phone's pad saves a clip too.
- **Frame Generation** in a game's settings: a generated frame between each two of the
  game's, with vertical sync on while it is. It needs the AnyPS5-ARM engine, and the row says so
  on upstream's.
- **Export and Import Settings** in a game's settings: the game's keys and every setting in one
  JSON file. The file is the Mac launcher's own format, so it moves between Windows, Linux and
  macOS. A resolution only comes along when the game offers it.
- **anyps5:// links and Copy Link.** Copy Link in a game's settings puts its link on the
  clipboard. Opening `anyps5://game/<title ID>` shows the game, `anyps5://play/<title ID>` plays
  it, and `anyps5://library` and `anyps5://settings` open those screens, the same links as on the
  Mac. A link opened while the launcher runs goes to the open launcher. The launcher registers
  the links for your user at start (the registry on Windows, a desktop entry on Linux), and the
  installer and the .deb do it too.
- **Choose the screenshots folder** in **Settings › Captures**. Screenshots, trophy pictures and
  clips go there, and **Show Screenshots** opens it.
- **Unreal games show what each button does.** A game's Controls page reads the game's own
  input settings from its .pak files and writes the game's action under each pad button, such as
  Jump under Cross. It reads them once, the first time the page opens. Games with encrypted paks,
  Oodle compression or only Enhanced Input assets show nothing extra.
- **Your game on Discord.** With Discord open, your profile shows the game you play and for how
  long, as the Mac launcher does. A game Discord knows shows under its own name and icon. In a
  party it says **In a party** with the party's size, and a **Join on AnyTogether** button opens
  the party's join page. You still say yes to whoever asks. Both are on by default and switch off
  in **Settings › Behaviour**: **Show the game you play on Discord** and **Show a Join button on
  Discord**.
- **Show me as Online, Idle, Do Not Disturb or Invisible**, in **Settings › AnyTogether**.
  Friends who are idle show a yellow moon, and Do Not Disturb a red dot with a bar. Your own dot
  and word show on the home screen, your profile and the account rows.
- **A translation in the Languages folder only changes the texts it has.** Before, a file there
  replaced the built-in language whole, and every text it lacked showed in English, the home
  screen's hints too. A regional file (de-AT) now falls back to its base language before
  English, and a file saved with a byte order mark is read.
- **A controller's battery shows as a level.** SDL2 reports one of four levels, never a
  percentage, so the pill showed a made-up number. It now shows a battery with its bars and a
  word: Nearly empty, Low, Medium or Full.

## 0.1.17

- **Upscaling: Bilinear or FSR 1.** A new choice in a game's settings, beside Resolution. With
  AMD FidelityFX Super Resolution 1, a game image smaller than the window is brought up to it
  sharp instead of blurred, so a lower Resolution gives more frames on a weaker PC without the
  soft look. **FSR Sharpness** (shown with FSR 1) goes from 0, the sharpest, to 2 in AMD's stops;
  0.2 by default. It needs an AnyPS5-ARM engine with FSR 1; upstream's engine always scales
  bilinearly.
- **Twelve more languages, by VK:** German, Spanish, French, Portuguese, Indonesian, Russian,
  Japanese, Hindi, Bengali, Bhojpuri, Arabic and Urdu, in **Settings › Language**. Arabic and
  Urdu read right to left, but the screens are not mirrored for them yet.
- **A new language shows everywhere at once.** The hint bar at the bottom and a few other
  texts kept the old language until the next start.
- **A name or handle changed on the website shows in the launcher.** It reads your profile
  again when the launcher comes back in front, every few minutes while it is in front, and
  when Friends, your profile or Settings opens.
- **A game dropped into the games folder as a .zip.** The launcher offers to unpack it into a
  folder next to it, with its progress, and then reads it as any other game. A zip with a file
  that would land outside that folder is refused, and the free space is checked first. A zip
  of a newer version of a game in the library unpacks as that game's update.
- **Add Update…** in a game's settings: choose the folder of the game's update dump, and it
  goes next to the game as `<game folder>-UPDATE`. The game's own folder stays as it is, and
  the next unlock applies the update.
- **The launcher says when a game can't read the phone.** The phone controller reaches a game
  only through the AnyPS5-ARM engine. Upstream's engine has no phone input, so a game on it
  ignored the phone while the phone still moved the launcher, and nothing said why. Now a game
  started on upstream's engine with a phone connected says so at once, in the launcher and as a
  desktop notice over the game. A phone that connects during such a game hears it too. Settings ›
  Phones says it while upstream's engine is in use. A game on an engine the launcher can't tell
  (a folder of your own) is said only when it hasn't answered the phone for 30 seconds. The game
  log notes the phones and the engine at each start.
- **One progress bar while a game updates.** The step and its bar beside the buttons are the
  only ones now; the main button no longer draws a second line inside itself, and the status
  under the game's name reads just **Updating**.

## 0.1.16

- **A shorter note when a game is ready without some files.** After an unlock that left a few
  modules out, the notice is one sentence instead of a list of every file: the files are in the
  unlock's log, and encrypted ones still say to dump the game again.
- **Messages:** the title has its own line, with **Back** level with it at the right edge, and
  the list and the conversation start together under it.
- **Check for Updates** reads "Newest: 0.1.15 · current: 0.1.14" (Turkish "mevcut").

## 0.1.15

- **A game's button always says what is happening to it.** Each game now has one state the
  whole screen follows: locked, unlocking, ready, needing an update, updating, waiting for the
  engine, starting, playing, stopping, or failed. After Play with a new engine build, the
  button reads **Updating Engine…** while the engine is pulled and built, then
  **Updating… 42%** with the progress along the button while the game relinks, then
  **Starting…**; pressing it again says what is going on instead of cancelling (its settings
  have **Cancel Update**). Its tile and the line under its name show the same, and Home shows
  **Engine build · …** next to Games while the engine builds, wherever you are.
- **Stop.** Back in the launcher while a game plays (Alt+Tab or the PS button), its button is a
  red **Stop**: the game is asked to close as closing its window would, so it can save, and is
  ended if it is still there a few seconds later. **Close Game** in the quick menu does the
  same.
- **The library stays usable while a game updates or the engine builds.** Other games can be
  picked, opened and unlocked; an unlock asked for during an engine build waits for it
  (**Waiting for the engine build**) instead of being refused, and Update from Git says so when
  a game is being unlocked. A game's settings open in every state: what cannot change mid-update
  or while it plays (Reinstall, Uninstall, Restore Saves, Resolution) says why in place.
- **The launcher no longer freezes while a game is unlocked or updated.** Copying a game's
  files (a games folder on another drive than the dump, without Developer Mode on Windows),
  measuring the dump, unwrapping its executable and removing the old install after an update
  all ran on the launcher's own thread: for seconds or minutes at a time the screen stopped,
  no other game could be picked, opening a game's settings seemed to crash the launcher until
  it came back, and Windows called the window not responding. That work now runs on the
  system's file threads and in a separate isolate, so the library stays usable while a game
  relinks. The old install is renamed aside at once and removed afterwards (a removal cut short
  is cleaned up at the next start).
- **Full screen means full screen, and the close button in full screen no longer crashes.**
  On Windows, the title bar's Maximize (its button, a double click on the title bar, Win+Up
  or dragging the window to the top) used to make a maximized window that kept its dark title
  bar along the top, and Settings still said Window. It now switches to the launcher's own
  full screen, with no bar, and the window buttons and **Settings → Full Screen** follow. On
  Linux, full screen turned on or off by the window manager is followed too. Clicking the red
  close at the top right in full screen used to crash the launcher, and the next start offered
  no report. Quit now closes the window the same way its title bar's close does. If closing
  ever fails, the next start offers a report of a crash while closing. Each full-screen
  change, and how long it took, is now in a report's last seconds.
- **Crash reports you can write in, and Windows 11 called Windows 11.** On the GitHub form
  that **Send Report** opens, the launcher used to fill in the same box you were meant to
  write in (What happened, ending in "What I was doing:"), and what you typed there could be
  wiped out. Now the launcher fills in its own boxes (**What the launcher noticed**, the system,
  the version, the error and the last seconds) and leaves **What you were doing** empty for you.
  The game crash form works the same way, and its **Report file** box is left empty for
  crash_log.txt. The system line read "Windows 10" on Windows 11, because the registry's
  product name still says 10. It now says Windows 11 from build 22000 on, with the version and
  the full build (for example "Windows 11 Home 25H2 (Build 26200.6899)"). On Linux the
  distribution name is read from os-release whichever quotes it uses. When the link has no
  room for every line, the oldest lines are left out, the log says how many, and the whole
  report is put on the clipboard so you can paste it into the issue.
- **Relinking a dump that holds an earlier relink's files.** A relink done by hand (or by
  another tool) with the dump as its `app0` writes its converted modules into the dump's own
  `sce_module` as `*.guest.prx` files. The launcher took those for modules of the game and
  stopped with "libSceFace.prx.guest.prx is neither an ELF nor a decrypted SELF container (an
  encrypted dump cannot be used)". They are no longer inputs of a relink and no longer laid
  into the installed game, so only this relink's modules go in; unlocking again (or **Update
  and Play**) puts a game that failed this way right, with nothing to clean by hand.
- **A module that cannot be used no longer stops the whole game.** A module of the dump that is
  still encrypted, or one the relinker cannot convert, is left out and the game is unlocked
  without it. The engine starts a game without a module it imports nothing from, answers the
  game's own load of it with an error, and uses its own library of that name where it has one
  (libSceNpCppWebApi, for example). The launcher says which file it left out and why once the
  game is ready, and the unlock log has the relinker's reason. Only `eboot.bin` still stops an
  unlock: an encrypted one says so in plain words.
- **The relinker's whole error.** A failed unlock showed only the relinker's last line (often
  just `Input: …\source\sce_module\libX.prx`, cut off). It now shows the reason (the `FAIL:`
  line) and the file, named as the dump has it, wrapped over a few lines, with **Copy Error**
  beside it and as the first row of the game's settings: it copies the error and all the
  relinker printed.
- **A profile picture of your own.** **Settings › Profiles › Choose Profile Picture** opens the
  file dialog for a PNG, JPEG or WebP; its middle square is kept at 256 × 256 in the launcher's
  data folder (`Profiles/Pictures`), for that profile only, and shows on Home, in **Who's
  Playing?** and on the profile rows. **Remove Profile Picture** brings the initial back. Both
  rows are reached with a controller too; the file dialog itself is the mouse's.
- **The profile colour shows on Home at once.** The picture at the top right is the profile's
  own colour now (it used the theme's accent), so changing **Colour** changes it straight away.
- **Turkish capitals.** Labels written in capitals (the game's **OYUN KİMLİĞİ** card, the
  menus' kickers, level tiers, initials) use İ and I as Turkish does; Dart's own toUpperCase
  had turned "Kimliği" into "KIMLIĞI". Game IDs (CUSA…, PPSA…) are shown as the game has them.
- **Smaller game info cards.** Status, Size, Title ID and Version on Home take the width their
  text needs (up to the old width, longer translations end in "…") and are lower.
- **A padlock that reads as one.** Locked games show a solid padlock (after Hugeicons'
  square-lock-02, MIT) instead of the small lock that was taken for a shopping bag; the focused
  tile adds **Locked**.
- **A profile left without a name is "Oyuncu" in Turkish**, "Player" in English: the language's
  word, numbered when another profile has it ("Oyuncu 2"). It was always "Player".
- **Settings' sections are as large as its rows.** The list on the left no longer shrinks to fit
  a short window: it scrolls, with a scrollbar that shows when there are more sections than fit,
  and a controller's focus keeps the selected one in view.
- **Descriptions end with a full stop.** Every setting description in English and Turkish ends
  as a sentence, and the translation check (`tool/check_translations.dart`) now flags a
  description (`…Detail`, `…Hint`, `…Subtitle`, `…Text`) that does not.

## 0.1.14

- **Update from Git for an engine you build yourself.** **Use My Own Folder** now takes a git
  checkout of the engine's source (AnyPS5 or AnyPS5-ARM) as it is: the relinker and libraries
  are read from its CMake build folder (`build/core/relinker`, `build/core/libs/libs`, plus the
  MinGW runtime DLLs on Windows). **Update from Git** pulls it (`git pull --ff-only`), updates
  its submodules and builds the relinker and libraries, with the step and the last output lines
  shown as it goes; selecting it again stops it. A tree with uncommitted changes, a missing git
  or CMake, or a folder never configured with CMake is said up front (the last one opens the
  build guide), and a failed pull or build shows the end of its output with a way to copy it.
  Afterwards installed games offer **Update and Play**, or **Relink All Installed Games Now**
  does them at once. **Update from Git Before Playing** (off by default) checks the remote
  before a game starts and pulls and builds first when there are new commits; offline it just
  plays. The Upstream choice still downloads release builds and never pulls a clone.
- **Default display settings for every game.** **Settings → Default Display** sets Window or
  Full Screen, the window size and vertical sync once for all games. A game's own choice in its
  Game Settings still wins; there **Display** and **Vertical Sync** now start with
  **Default (…)**, which shows what the default is, the window size reads **Default (75%)**
  until the game picks one, and **Use Default Display** puts a game back on the defaults.
  Choices made before the update stay: a game set to Full Screen, a window size of its own or
  vertical sync off keeps it; values never changed follow the defaults, which start as
  before (Window, 75%, vertical sync on).
- **The stick's up and down on Home are calmer.** With an Xbox pad (or any pad) a push to the
  side could also move up or down and leave the tiles for the top bar or the buttons: the
  thumb's arc on the way out, a light push or a stick snapping back from a diagonal counted as
  up or down. Up and down on the stick now need a firmer, clearly upright push (0.65 instead of
  0.5, letting go below 0.4), a diagonal goes sideways, a held left or right gives way only to
  a clearly vertical push, and held up or down repeats first after 0.55 s instead of 0.40 s.
  Left and right, the D-pad and the keys feel as before.
- **Every text is in the language files, ready for Weblate.** The accent colour names, the
  mouse button, wheel and key labels, the controls' button names and the number formats were
  still in the code; they are in `assets/l10n` now, so a translation covers them too. Turkish
  sizes and percentages read `52,5 GB` and `%75`. The files are flat JSON objects with the
  language's name as the text `languageName`, the format Weblate reads; a file in the old
  format in the `Languages` folder still loads. **TRANSLATING.md** is now the guide for the
  Mac launcher, this launcher and the phone app.

## 0.1.13

- **More than one games folder.** **Settings → Game Library** lists each folder with its game
  count, takes one out of the library (nothing on its drive is deleted) and has **Add Folder**,
  with the keys and a controller as well as the mouse; Select on the empty shelf adds one too.
  The library is all the folders together; a game in more than one shows once, from the folder
  listed first. A folder whose drive is unplugged stays in the list as **Not connected** and its
  games come back when the drive does. Each game is unlocked into the folder it was found in,
  so its files are linked on their own drive instead of copied to another; games unlocked
  before stay where they are. The saved single folder carries over as the first.
- **A controller reaches the top bar with no games.** With an empty library the home screen
  answered only Select, so an Xbox pad (or any pad) could not get to Settings. Up from the
  empty shelf now moves to the top bar, as it does with games.
- **Languages are JSON files.** Every text is in `assets/l10n/en.json` and `tr.json`; a new
  language is one more file there and shows in **Settings → Language** and on the first start.
  A file in the `Languages` folder beside the settings (`%APPDATA%\AnyPS5\Languages`,
  `~/.config/AnyPS5/Languages`) comes first, so a translation can be tried in a released
  launcher. **TRANSLATING.md** is the guide for translators; CI checks every language file.
- **Mouse side buttons.** Back does what Circle does everywhere (closes a panel, goes back a
  step); Forward opens again the screen Back just closed. A keyboard's Browser Back / Forward
  keys do the same.
- **Escape on the home screen asks "Quit AnyPS5?"**, with **Cancel** first. Everywhere else
  Escape keeps its meaning.
- **Window buttons in full screen.** The pointer at the top edge brings down **Minimize**,
  **Leave Full Screen** and **Quit AnyPS5**. **Settings → Appearance → Window Buttons at the
  Top Edge** turns them off.
- **No stalls on fast input.** A game's size was measured by walking its folder on the
  interface thread for every game passed, which froze the launcher for seconds while a
  direction was held; it now runs in the background, for the game the selection rests on.
  Switching back before a fade ended put two items with one key on screen, a likely cause of
  the rare crashes; that is fixed too.
- **Engine settings say where each engine comes from.** Upstream and AnyPS5-ARM are release
  downloads, and your own folder is used as it is (nothing is pulled or built). A folder you
  rebuild in place now makes installed games offer **Update and Play**, as a new engine does.
- **Reports for the launcher's own crashes and stalls.** After a crash or a freeze of 5 seconds
  or more, the next start offers **Send Report**: a GitHub issue filled in with the version, the
  system and the last seconds, without your paths or names. Nothing is sent by itself.

## 0.1.12

- **AnyTogether moved to anytogether.net.** The default server and the join links use the new
  address; the old one keeps working.
- **AppImage updates are staged beside the AppImage.** The new AppImage was written to a file
  literally named `$appImage.new` in the current folder and renamed from there, which fails
  across file systems; it now goes next to the AppImage it replaces.
- **New engine.** AnyPS5-ARM 0.2.26's Windows and Linux engine brings about 3,500 upstream
  commits (**Settings → AnyPS5 Engine**).

## 0.1.11

- **Gyro aiming for every game.** Each game's **Controls** page starts with **Aim with the
  Gyro**: a DualSense, DualShock 4, Switch Pro Controller or a phone aims in any game that aims
  with the right stick, on top of the stick itself. Set the sensitivity, when it aims (always,
  while L2 is held, while touching the touchpad), invert and the dead zone. Needs AnyPS5-ARM
  0.2.25's engine (`ANYPS5_GYRO_AIM`); other engines ignore it.
- **Type on your phone.** When a game opens its text dialog or keyboard, the phones get a
  typing sheet with their own keyboard (and one that connects later gets it at once), and the
  browser pad page a text card; the text goes back to the game, then Enter or cancel.
- **Assist Player 1.** **Settings → Controllers → Assist Player 1** picks who plays player 1
  together with its holder: the computer's other controllers, or one phone or browser pad. Its
  buttons, sticks and touch join player 1's; a change is said to the engine at once.
- **New engine.** Gyro aiming, typing on the phone and Assist Player 1 need AnyPS5-ARM 0.2.25's
  Windows and Linux engine (**Settings → AnyPS5 Engine**).

## 0.1.10

- **Profiles.** The first start asks **How do you want to play?**: **Play Offline** (no
  account; trophies and progress stay on this PC, nothing is synced or shared) or **Play
  Online** (create an AnyTogether account or sign in with an email code, the website or your
  phone). Add more people with **Add Profile**; with more than one, **Who's playing?** greets
  you at start (**Ask Who's Playing at Every Start** makes it ask always). Each profile keeps
  its own AnyTogether session, settings, saves, trophies and Game Presets; its saves are put in
  place when it plays. **Switch Profile** is in the PS button's long-press menu and in the
  **Options** menu (Options/Start on a pad, or right-click on Home), which also has **Go
  Online** / **Go Offline** and the other profiles. Switching, or going online or offline, is
  refused while a game runs (**Close <game> first**) or while saves sync. **Settings →
  Profiles** sets the name, picture and tile colour, and switches to or deletes a profile (its
  saves and trophies are backed up first). An existing install becomes the first profile by
  itself, with its account, saves and settings.
- **Friends-only name and picture.** **Settings → AnyTogether → Friends-Only Name and Picture**
  sets a name (your real name, say, up to 40 characters) and a picture that only your accepted
  friends see, always next to your @handle, in friends, party, Play Together and profiles, in
  the launchers and in the phone app; everyone else sees your public ones.
- **DLC and game updates from your own dumps.** Put them beside the game, as shadPS4 does:
  `<game>-UPDATE` (or `-patch`), `<game>-DLC/<label or content ID>`, or an add-on named by its
  content ID next to the game (the game's folder name or title ID, any case). They are no longer
  listed as games. The game page shows **DLC (n)** and **Update vX applied**; an update dumped
  after the unlock says **unlock to apply** (saves and trophies stay). Each start passes
  `ANYPS5_UPDATE_DIR` and `ANYPS5_ADDCONT_DIRS`: the engine reads the update's files in place of
  the game's and mounts the add-ons the game asks for. Only what is on your disk is reported to
  the game; nothing contacts Sony.
- **Game Presets per profile.** **Settings → Game Presets** sets what the PS5 keeps under that
  name, once for every game: difficulty, Performance Mode or Resolution Mode, inverted
  vertical and horizontal view (first and third person), subtitles and the audio language,
  passed as `ANYPS5_GAME_PRESETS`. Games that read the console's presets start with them.
  Performance Mode is seen to work in games; the other values follow the console's menus and are
  **experimental** (not checked against a console).
- **New engine.** DLC, updates and Game Presets need AnyPS5-ARM 0.2.24's Windows and Linux
  engine from ce334c86b (**Settings → AnyPS5 Engine**); with an older one they are ignored.

## 0.1.9

- **Full screen.** The launcher starts full screen the first time, then as you left it. **F11**
  (it can be rebound) or **Settings → Appearance → Full Screen** switch it (Windows: a
  borderless window over the monitor and back; Linux: GTK's full screen).
- **Settings with a controller.** The sections' column takes the focus with left; up and down
  change the section, right or ✕ go back into the rows; L1/R1 as before. Option rows (theme,
  window mode, ...) no longer change by just moving over them: **✕** enters edit mode (an
  accent ring and its arrows), **←/→** change the value, **✕** or **○** leave it. Keyboard and
  mouse work as before.
- **Hints follow your input, live.** After a pad button the hints show only the pad's buttons,
  and the Back pill, the step arrows and the gallery's arrows hide outside edit mode; a key or
  the mouse brings the keyboard's hints back.
- **PS button.** Held in the launcher: **Quit AnyPS5** (Switch Profile is coming). In a game:
  the game is paused first, then a **quick menu** (Resume, Game Settings, Close Game) that says
  Paused or Still running over the game's name. Held in a game: **Close game?** at once. PS now
  acts when let go (held 500 ms it is the long press). The pause works even with a controller
  on player 1: with an engine that takes presses (AnyPS5-ARM's Windows and Linux engine from
  a29698606, below), the launcher sends one press packet through the remote pad bridge that
  holds Options 160 ms on player 1's pad, whoever drives it; an older or upstream engine keeps
  the fallback, the Options key typed into the game's window. **Settings → Behaviour → Pause
  Game When Opening the Menu** turns the pause off.
- **Share / Create button: clips and screenshots.** With **Settings → Captures → Replay Buffer**
  on (off by default, about one CPU core; needs **ffmpeg**), the last 30 s to 5 min are kept,
  and a short press saves them as a clip in the game's gallery; a long press (or a press with the
  buffer off) takes a screenshot. Clips show in the gallery with a play badge and open in the
  system's player.
- **Settings → Shortcuts.** Put Home, Quick Menu, Screenshot, Save Clip, Full Screen and the
  Settings sections on a key (with modifiers) and on a pad button or chord, pressed or held.
  Conflicts, and the launcher's own keys and buttons, are refused and said; **Reset to
  Defaults**; the game's own buttons link to Game Settings → Controls.
- **Play from a browser.** **Settings → Phones → Play from a browser** shows a QR code with a
  one-time link: a phone that scans it becomes a DualSense in its browser, with no app, as
  player 2 to 4. It pairs with the same pairing code as the phone app, works on your LAN only
  (one-time token, session cookie, origin, host and LAN checks, rate limits) and the server runs
  only while it is wanted; **Keep browser play on** keeps it up. Each browser is a phone on the
  phone server's own channel, so seats, the pairing card and the pad path are the same.
- **Credits.** The README credits AnyPlay's bridge spec and the ideas we followed.

## 0.1.8

- **Online play (experimental), as on the Mac.** **Settings → AnyTogether → Online play
  (experimental)**, off by default, starts games with the launcher's online bridge: a loopback
  service on 127.0.0.1 the engine connects to with a fresh secret every start (both sides prove
  it, the secret never crosses the socket). Games see you signed in as your AnyTogether handle,
  with your AnyTogether friends, their profiles and presence, an empty block list and no
  communication restriction; Player Sessions (`sessionManager`) are kept by the launcher for the
  game run, with push events to the game when someone joins or leaves. Game packets ride WebRTC
  data channels to the other players of the AnyTogether game session, signalled through
  AnyTogether's gateway with its STUN and TURN, each player at the same virtual address on every
  computer, broadcasts and LAN-style discovery included; Windows, Linux and Mac launchers play
  together. Nothing ever goes to Sony; groups the launcher does not know answer "not offered",
  as offline. What each game asks for is written to its online log (Windows
  `%LOCALAPPDATA%\AnyPS5\Logs\Online\<TitleID>.jsonl`, Linux `~/.local/state/AnyPS5/online/`),
  opened from **Open online log**; a crash report carries the last lines of it. Needs an engine
  with the online bridge (AnyPS5-ARM's engine, once its Windows and Linux toolkits carry it);
  with an engine without it the setting changes nothing.
- **Play Together, as on the Mac.** In a party, **Play Together: <game>** starts the game picked
  on Home for the party, with online play on for that game only (the setting stays as you left
  it). Everyone else in the party hears "<host> started <game> — Join"; **Join** checks you have
  the same game, version and AnyPS5 engine (or offers **Unlock and Play** / **Update and Play**,
  or says who should update), then starts it in the host's session so the games find each other
  on the virtual LAN. The party panel shows who plays and whether each connection is up; the
  host can hand out a join code for someone outside the party, and it ends for everyone when the
  host's game exits. Friends see "Playing <game> together (2/8)".
- **Human Fall Flat online: Host Public and Join work.** Player Sessions answer as the platform
  does (201 for every request that makes something, with Content-Type and Content-Length), so
  hosting a public game no longer crashes it; a join into a session made on the host's machine
  is taken, and the session fetch after the join is answered from its session IDs header, so
  Join gets into the host's game.
- **Games that stream between players play online too.** Stream P2P sockets (TCP between
  players) ride the bridge and a second, reliable data channel next to the game's packets,
  byte for byte as the Mac launcher carries them, so a PC and a Mac stream to each other. A
  stream a game or player closed stays closed; one left open when a game or player goes is
  reset on the other side. A Mac that restarted its answer is met with a fresh connection.
- **Try Anyway in Play Together.** When only the game version keeps you out (never the engine),
  Join offers **Try Anyway**, and the party sees who tried anyway.
- **Asks first.** Leaving the party, removing someone from it, ending or leaving Play Together
  and removing a friend ask first, with Cancel focused; Back answers Cancel.
- **Update Required.** When AnyTogether retires this version, the launcher says so once, with
  its own download and restart, or the downloads page.
- **The newest engine is offered.** When a release keeps an older AnyPS5-ARM engine beside a
  newer one, the newest upload is the one offered.

## 0.1.7

- **Play from Steam and the Steam Deck.** **Settings → Steam → Add to Steam** puts AnyPS5 in
  your Steam library as a non-Steam game, with artwork in the Cosmic look (cover, wide capsule,
  hero, logo and icon), tagged **AnyPS5**, so Big Picture, Steam Input and the Steam Deck's Game
  Mode start it like any other game. **Add My Games Too** gives every unlocked game its own
  entry with its own art that starts straight into the game; the launcher closes when the game
  ends so Steam sees it end. Steam has to be closed while its shortcuts are written: the
  launcher offers **Close Steam and Add**, keeps a backup (`shortcuts.vdf.anyps5-backup`) and
  never touches anyone else's shortcuts; **Remove from Steam** takes out only AnyPS5's entries
  and pictures. On a Steam Deck, add it from Desktop Mode. `--fullscreen` opens the launcher
  over the whole screen; `--play <title ID>` starts a game at once.

- **Controllers that just work, and a screen for them.** Controllers are read through SDL2,
  shipped with the launcher: DualSense and DualShock 4 over USB and Bluetooth (and now they
  vibrate on Windows too), Xbox, Switch Pro, 8BitDo and more, plugged in or paired at any time,
  several at once; the one used last is Player 1. **Settings → Controllers** lists them with
  USB or Bluetooth and their battery, tests every button and stick live and the vibration, sets
  the light bar's colour, lets Circle confirm (Japanese layout) and sets a stick dead zone for
  the launcher and your games. Its **troubleshooter** finds what keeps a pad away: Steam's
  PlayStation support, DS4Windows, DualSenseX, HidHide, Linux input permissions (with the
  command to copy), and gives the Bluetooth and cable tips. Started from Steam, Steam's virtual
  pad is used and the real one left to Steam. Crash reports now list the controllers.

- **No unlock without the room, and new games prepared in the background.** Unlock (and Update
  and Play) first works out what it will write and checks the games folder's drive; when it is
  short nothing starts, and the panel says how much is needed and how much is free, why the
  game's files would be copied when they would, and the ways out (a games folder on the dump's
  drive or one with more room, Developer Mode on Windows, try again). **Settings → Game Library →
  Prepare New Games Automatically** (on by default): a new, complete game found in the games
  folder is unlocked in the background, one at a time and at the lowest priority; it waits for
  your own unlocks and for a game you play, pauses where it is when one starts, and never runs on
  a battery below 30 % or a drive without the room (it says so). The **New game** notice says
  **Preparing…**, then **Ready to play**; Play on a game being prepared finishes it at full speed
  and starts it. Unlocking again is faster too: the relinker's output is kept, and the same
  game, engine and modules skip the unwrap and relink.

- **More in Messages.** Pick a message (↑ from the field, or click it) for its menu: react with
  👍 ❤️ 😂 😮 😢 🔥 or GG, reply (the answer quotes it), edit your own for 15 minutes, or unsend
  it for everyone after a confirmation; unsent ones read "Message removed". Reactions show as chips
  under the message, yours lit, and clicking one adds or takes back yours. Under your newest
  message: Sent, Delivered or Read, and "Seen by" in groups. △ on a conversation pins it to the
  top (up to five) or mutes it, with a mark in the list; muted ones come in without a notice.
  **Settings → AnyTogether → Send read receipts** turns read receipts off both ways. Unread counts
  are now the server's own.

- **Smooth on laptops and integrated graphics, and nothing drawn behind your game.** On Windows
  the launcher now draws with Skia instead of Impeller's OpenGL ES backend, which needed dozens
  of offscreen passes a frame for the launcher's glass and panels (on a Ryzen 7 3700U with Vega
  graphics a Glass settings panel drew at 3 to 13 frames a second; now it scrolls at 60, a frame
  drawn in about 4 ms). Glass draws each card, button and row once and reuses the picture, its
  frost is a small repeated tile, it no longer blurs behind every surface (only a full-screen
  layer is blurred, once; on the see-through window the home screen fades out under it instead),
  and its text plates are drawn in one step. The themes' animated backgrounds move at 30 steps a
  second (Glass 20) at half the window's resolution, which you cannot tell apart from before and
  costs a fraction. While a game is in front, or the launcher is behind any other window, the
  launcher draws nothing at all: every animation stops and the GPU is the game's (before, the
  background kept drawing behind the game and took a quarter of the GPU from it). If the
  graphics card still falls behind with Glass, it turns solid by itself after a few seconds and
  stays solid at the next starts; picking Glass again in **Settings → Appearance** tries once
  more. New installs start in Cosmic; Glass is yours to pick.
- **PS/Guide switches between the game and the launcher, both ways.** In the game, PS brings the
  launcher in front; in the launcher, PS takes you back to the game (on Windows the game window
  could refuse to come back; it is now brought in front reliably, with the launcher right behind
  it). One press is one switch, and the press that switched does nothing on the other side.
- **The game leaves the controller alone while the launcher is in front.** Games read the pad
  only while their own window is in front (SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS=0 in the game's
  environment), so moving through the launcher over a running game no longer also plays the game.
- For testers: `ANYPS5_FRAME_LOG=<file>` writes how many frames the launcher drew each second and
  how long they took; `ANYPS5_RENDERER=impeller` brings Impeller back on Windows.

- **Glass, a new theme.** The launcher's window turns see-through: your desktop and the
  windows behind it show through, blurred under a light tint so the wallpaper's colors glow,
  like a Windows 11 Acrylic window; the text sits on soft dark plates and panes of glass, so it
  reads over any wallpaper. Every card, button and panel on it is a pane of
  frosted glass with a rim of light, and the focused one turns into a bright ice chip with a
  glint that runs across it (not with reduced animations). It comes with a new **Ice** accent.
  Pick it in **Settings → Appearance → Theme** or on the first start. **Glass Transparency**
  there sets how much shows through (0 % is solid) and **Show Game Art Behind** lays the
  selected game's picture over the desktop; **Reduce Transparency** draws everything solid, and
  a graphics card too slow for Glass gets the solid look by itself. On Windows 11 22H2 and later
  the backdrop is the system's Acrylic (shown while the window is active, as for every app);
  Windows 10 and earlier Windows 11 get the older acrylic blur. On Linux the window is
  see-through wherever the desktop composites, blurred on KDE Plasma (X11), unblurred with more
  tint elsewhere (GNOME, Wayland); without a compositor Glass draws its own frosted background.
- **No more full copies across drives.** A game whose dump is on another drive than the games
  folder now links to the dump's files with symbolic links instead of copying tens of GB (on
  Windows this needs Developer Mode, or the launcher run as administrator). Where no link can be
  made, the launcher says before unlocking how many GB would be copied and why, with the two
  fixes: a games folder on the dump's drive, or Developer Mode (**Settings → System → For
  developers**, one button away), or **Copy Anyway**. A linked game whose dump moved says so
  instead of crashing.
- **New games show up by themselves.** A game copied into the games folder, in a subfolder too,
  appears as soon as its copy is far enough along (a big copy that started before its
  eboot.bin and param.json were there no longer goes unnoticed, and an unlock going on no longer
  holds it back), with **New game: <name>** and its icon (or **3 new games**), the select sound,
  and the game selected on the home screen; a desktop notice says it too while the launcher is
  behind other windows. On Linux every folder down to the scan's depth is watched, and a games
  folder on a drive that is not plugged in yet is found when it is.
- **Controller vibration.** Soft, short pulses in the controller for select, back, errors,
  trophies, invitations and the end of a row (**Settings → Behaviour → Controller Vibration**, on
  by default). Only while the launcher is in front and the controller is what you are using; the
  motors stop the moment a game comes in front. Xbox and other XInput pads on Windows, pads with
  force feedback on Linux; a pad without motors (or a PlayStation pad read through winmm) stays
  still.
- **Input feel.** A held direction repeats at the same pace on the controller and the arrow keys
  (0.4 s, then 0.08 s, a little faster after six); the stick engages at half and lets go only
  below a third, so a resting stick no longer jitters; a direction with nowhere to go answers
  with a quiet knock (once per press). A soft tick plays when the mouse arrives on a tile, row or
  button.
- **Updates while it stays open.** The launcher looks for a new version every six hours and when
  it comes back to the front after half an hour, downloads it in the background (signature
  checked as before), then shows a quiet notice beside the top bar: **Restart Now** or **Later**
  (it goes in at the next launch, and the notice does not come back). Restart Now with a game
  running waits for the game. On Windows the installer runs silently and opens the launcher
  again; an AppImage is swapped for the new one; with the archive, **Show File**. About shows
  checking, up to date, downloading with its percent, or ready.
- **Hidden trophies.** Checked: a hidden trophy you earned always shows its name; only unearned
  hidden ones are masked.
- **Controller presses no longer reach the launcher while you play.** The controller is read
  whichever window is in front, and on Windows the launcher could believe it was still in front
  behind the game, so Cross in the game also pressed what the launcher had focused. Now, while a
  game (or any other program) is in front, the launcher takes nothing from the controller but
  the PS/Guide button, which brings it in front as before; no vibration either. Back in front, a
  button still held from the game does nothing until you let go of it and press it again, and a
  stick still pushed moves nothing until it comes back to the middle.
- **Lists no longer follow the mouse; scroll with the wheel or drag.** Moving the mouse over a
  row still highlights it, but the list no longer scrolls to it (it used to slide away under the
  pointer). Scroll with the wheel or the touchpad, or hold the left button and drag, as on a
  phone or an Android emulator: lists, the library and the game tiles on the home screen follow
  the pointer and glide on when you let go fast; a drag never clicks what it started on, and a
  click that moves a few pixels is still a click. The arrow keys and the controller scroll the
  focused row into view as before.

## 0.1.6

Pre-release, superseded by 0.1.7.

## 0.1.5

### Trophy levels, showcases and comparing trophies

Your trophy level (all your trophy points, bronze up to platinum, in a hexagon that grows a
frame every 100 levels) is beside your name on the home screen and in the friends panel, and on
your profile with how far the next level is. Friends' rows show their levels. Reaching a level
says so with the trophy sound. A friend's profile shows their showcase, their pinned trophies
and favourite games, and **Compare trophies**: the games either of you has trophies in, the
ones you both play first, then a game's trophies side by side, who earned what and when. A
friend who keeps their trophies private is said so.

### Appear offline

**Settings → AnyTogether → Show me as** has **Online** and **Appear offline**: friends see you
as offline, while messages, parties and cloud saves keep working. Your other devices follow the
choice, and your name says "Appearing offline" while it is on.

## 0.1.4

### Crash reports and detailed logging

When a game stops on an error (not when you close it), the launcher shows its crash report:
why it stopped (the engine's crash report, a signal or exception, an abort, the exit code), the
system, the engine, the GPU and the end of the log. From there:

- **Save crash_log.txt** asks where to save the report with the whole log of that start and
  the last unlock's output.
- **Copy Report** puts the report and the last 200 log lines on the clipboard, for Discord.
- **Open an Issue** first shows exactly what will be shared, then opens a pre-filled bug report
  on the engine's GitHub (boykopovar/AnyPS5, or AnyPS5-ARM when its engine is in use), or
  **Report a Launcher Bug** on AnyPS5-Desktop. Your home folder, user and computer names,
  e-mail addresses and AnyTogether tokens are taken out of everything, and the link stays
  within GitHub's length.

The same report is in a game's options as **Last Session's Report**. **Detailed Logging
(Trace)** in a game's options starts it with the engine's trace switches every time; **Play
with Detailed Logging** does it once; starting the launcher with `--trace` does it for every
game until it closes. Game logs no longer grow without end: a log over 32 MB is set aside
before a start, and one passing 256 MB while the game runs starts again.

## 0.1.3

### System fonts for every game

Games that ask for the console's system fonts get them without anything to set up: Noto Sans,
Noto Sans Mono, Thai and Arabic come with the launcher (5.5 MB), and Japanese, Chinese and
Korean (Noto Sans CJK, 100 MB) download the first time a game needs them. A game started in
Japanese, Korean or Chinese waits for them, with the download in a toast; a game seen asking
for them in its log gets them in the background, and its next start waits for them. (Some
games, Astro's Playroom among them, stop at start-up without system fonts.)
**Settings → Fonts** shows which font each script gets and from where, downloads or removes
the CJK fonts, and takes a folder of your own (the console's fonts, say): its files come first
and the launcher's fill in what it lacks. The Noto fonts are under the SIL Open Font License
1.1, shipped beside them.

### Hidden trophies

In the trophy list, △ / Y (or O, or a click on **Show**) shows a hidden trophy's name,
description and icon until the list closes; △ again hides it. **Settings → Behaviour → Always
Show Hidden Trophies** shows them all.

### Party join codes and a Discord link

A party's leader can make a join code (**Party → Make a join code**), shown as XXXX-XXXX, and
copy it or its link for people who are not friends yet. Whoever has it asks to join; the
leader lets them in or turns them down, and a yes is an invite they answer. **New code** and
**Stop the code** replace or end it. **Party → Join with a code** shows whose party a code opens
and asks to join it. The leader can also set the party's Discord link; everyone in the party
gets **Open in Discord**.

### Controllers in the launcher

A controller moves through the launcher as on the console, on Windows and Linux: the D-pad or
the left stick moves (held, it repeats), Cross/A selects, Circle/B goes back, Triangle/Y or
Options opens a game's options, L1 and R1 go to the game before or after, and **PS/Guide**
brings the launcher in front of the game and takes you back to it. Xbox and other XInput pads
and PlayStation pads (DualSense, DualShock 4) work on Windows; any pad the kernel gives a
joystick on Linux. Several at once, and pads plugged in later, are picked up by themselves.

### Trophies while you play

- A PS5-style card drops in at the top of the screen when the game earns a trophy, with the
  trophy sound, above the game and without taking its keyboard, mouse or controller. On Linux
  under X11 it is a card too; under Wayland it is a desktop notification.
- At that moment the launcher keeps a picture of the game in `Pictures/AnyPS5/<game>/`. The
  trophy list shows it beside the trophy, and **Game settings → Screenshots** shows every
  picture of the game, F12 ones included. (Wayland lets no program read another's window: no
  picture there.)

### Full screen and window size work with upstream's engine

Upstream's engine reads neither choice: it opens at 60% of the screen and switches with F11.
The launcher now does it for it: once the game's window opens it sizes it, or presses F11 for
full screen; the setting says so. **Settings → AnyPS5 Engine → Engine** also offers the
**AnyPS5-ARM engine**, which opens at your size or full screen by itself and takes the phone
controller. It downloads from AnyPS5-ARM's signed GitHub releases and is checked against their
signed checksums.

### The mouse and the keyboard

- Every panel has a **Close/Back** button, closes when you click beside it, and the right mouse
  button is Back everywhere, as Esc is.
- The **‹ ›** of a choice and the **− +** of a number are buttons of their own; **←** now always
  goes to the option before (it went to the next one on rows of two). Rows, tabs, tiles and
  buttons light up under the pointer, and the focus follows the pointer without fighting the
  keys.
- The key hints at the bottom are buttons: click **Enter**, **Esc**, **O**, **Q** or **E**.
- A click on a game selects it at once (it used to wait to see whether a second click came);
  a double click plays or unlocks it, in the library too. The wheel moves between games on the
  home screen.
- Smoother screens: layers open and close within 200 ms, the background holds still under them
  (the blur is no longer worked out again on every frame), pictures load away from the
  interface, and nothing reads the disk while a screen is drawn.

### Game music

Games with a theme song (`sce_sys/snd0.at9`, as Hollow Knight: Silksong's dump has it) play it
on the home screen; games without one stay quiet.

### Sounds

The launcher was silent; it now sounds like the macOS launcher.

- **Interface sounds:** soft ticks for moving between games, buttons, the top bar, rows and
  tabs, a rising pair for selecting and opening, a falling one for going back, and a brighter
  three-note sound when a game finishes unlocking, the engine finishes downloading or a trophy
  pops. They are the Mac launcher's own tones, made on the spot.
- **Game music:** rest on a game and, after a moment, its theme song (the dump's
  `sce_sys/snd0.at9`) fades in and repeats from its loop point, as on the PS5. It fades out
  when you move on, switch to another window, or start a game.
- **Settings → Behaviour:** **Interface Sounds** and **Game Music** volumes (Off at 0).
- While a game is in front, the launcher stays quiet.

### The toolkit downloads itself on first start

No more downloading upstream files by hand, renaming the relinker and arranging `libs/`. The
first start's last step offers **Download the AnyPS5 engine (recommended)**: the launcher reads
the latest [boykopovar/AnyPS5](https://github.com/boykopovar/AnyPS5/releases/latest) release,
shows its version and size, downloads the relinker and system libraries for your system with a
progress bar, checks them against GitHub's checksums and sets them up. A folder of your own
still works: choose **I have my own folder**.

- **Settings → AnyPS5 Engine:** the engine in use, **Check for engine updates**, every version
  GitHub lists (switch to a downloaded one or download another), **Delete other versions**,
  **Use my own folder**.
- **Engine updates:** at start the launcher looks for a newer engine. When one is out, your
  installed games offer **Update and Play**, which downloads the new engine and unlocks the game
  again; saves and trophies stay.
- An interrupted download carries on where it stopped. A file GitHub has no checksum for is
  only used if you choose it a second time.
- Engines are kept in `%LOCALAPPDATA%\AnyPS5\Toolkits` (Windows) and
  `~/.local/share/AnyPS5/Toolkits` (Linux).

### Install

1. Install AnyPS5 Desktop as before (Windows installer or portable zip; Linux AppImage, .deb or
   tar.gz).
2. Start it, pick a language, a theme and your games folder, then choose **Download the AnyPS5
   engine**. That's all.
