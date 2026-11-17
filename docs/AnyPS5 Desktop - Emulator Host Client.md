# The emulator host client

PS1 games run in a separate program, the emulator host
([anyps5-retro-host](https://github.com/AnyTogether/anyps5-retro-host)), which
runs SwanStation through libretro. It talks to the launcher over a private
control stream and shares each picture through shared memory. Both sides follow
that repository's
[`docs/protocol.md`](https://github.com/AnyTogether/anyps5-retro-host/blob/9052aff59c94c3ae3aa8ff63bef5df241acec713/docs/protocol.md),
version 1, as it stands on its `main` at 9052aff. This page explains the
launcher's side. It was written from the protocol alone. The UI built on it,
the game's picture, the controls, the in-game menu and the settings, is
described in [The emulator host in the launcher's UI](<AnyPS5 Desktop - Emulator Host UI.md>).

## Files

| File | What it does |
| --- | --- |
| [`native/retro_host/anyps5_retro_host.c`](../native/retro_host/anyps5_retro_host.c) | Starts the host with its control stream. Reads and writes whole messages on threads of its own. Watches the host exit. Maps the frame ring after the protocol's memory checks. Built by [`hook/build.dart`](../hook/build.dart). |
| [`lib/core/retro_host/retro_host_native.dart`](../lib/core/retro_host/retro_host_native.dart) | The Dart bindings for that library. |
| [`lib/core/retro_host/strict_json.dart`](../lib/core/retro_host/strict_json.dart) | Reads message bodies as the protocol's "Values" section says. `dart:convert` silently keeps the last of two equal keys and keeps lone surrogates; the protocol makes both errors. |
| [`lib/core/retro_host/retro_host_protocol.dart`](../lib/core/retro_host/retro_host_protocol.dart) | The protocol's values, field checks and the game's `status`. |
| [`lib/core/retro_host/frame_ring.dart`](../lib/core/retro_host/frame_ring.dart) | Checks a ring's header and growth. Pins the newest frame and checks its size. |
| [`lib/core/retro_host/retro_host_client.dart`](../lib/core/retro_host/retro_host_client.dart) | One host process, as described in the sections below. |
| [`lib/core/retro_host/retro_host_release.dart`](../lib/core/retro_host/retro_host_release.dart) | Checks a signed host release before it is unpacked and before each start, and installs it whole or not at all (see "Finding and checking the host" below). |
| [`lib/core/retro_host/retro_host_store.dart`](../lib/core/retro_host/retro_host_store.dart) | `RetroHostStore`: the host downloaded from the host repository's signed GitHub releases into the launcher's own storage, and its check before each start. |
| [`lib/core/retro_host/retro_host_install.dart`](../lib/core/retro_host/retro_host_install.dart) | `RetroHostInstall`: the host and SwanStation a build runs, the downloaded release's (checked) or, in a debug or test build (`RetroHostBuild`), the one `ANYPS5_RETRO_HOST` names (unchecked). |
| [`lib/core/retro_host/retro_host_build.dart`](../lib/core/retro_host/retro_host_build.dart) | `RetroHostBuild`: whether this launcher was compiled as a release, a test build or a debug build, and the mark only a test build's compiled program carries (see "Debug and test builds"). |
| [`tool/check_release_build.dart`](../tool/check_release_build.dart) | Run after every release and nightly `flutter build`: fails on a test build, from the defines Flutter compiled it with and from the mark in its AOT snapshot. |
| [`lib/core/retro_host/checked_file.dart`](../lib/core/retro_host/checked_file.dart) | A release file held open while it is checked and started: no sharing for writing or deleting on Windows, a close-on-exec descriptor above 3 elsewhere. It hashes what it holds, never the path again. |

`retro_host_client.dart` handles:

- `hello` and `welcome`, and the first `volume` call;
- calls and pings in order, with their time limits;
- frames and rumble;
- what to report when the host fails.

## What a status holds

`RetroStatus.parse` reads a `status` result by the protocol's "status" section
and throws `RetroProtocolError` for a field outside it. Unknown fields are
ignored.
`RetroStatus.sameAs` says whether two statuses hold the same values, field by
field as `toJson` writes them, options in their order; the UI uses it to
tell no one of a status that says nothing new.

- **`cardUnreadable`.** True when memory card 1's file is there but the host
  could not read it as a card, so this game's saves are not written anywhere.
  A status without the field reads as false, as the protocol asks.
- **`errorCode`.** Kept as the host sent it, so a code this launcher does not
  know stays a failure with no known cause. The two codes only the client may
  report, `hostExited` and `hostHung`, are read as `other` when a host sends
  them, so they always mean the client's own report.
- **`discs`.** At most 128 labels; more is a protocol error. `inserted` is null
  while the tray is open, and also when the core inserted a disc past the
  128th.

## Starting the host

The client adds the protocol's own arguments after the command it is given:

- `--ipc-fd 3 --parent-pid <pid>` on Linux and macOS;
- `--ipc-read <h> --ipc-write <h> --parent-pid <pid>` on Windows.

**The environment.** The host inherits the launcher's environment, with any
variables the caller adds on top. On Windows names that differ only in case are
one variable, so an added `Path` replaces the inherited `PATH` instead of
sitting beside it, where the host would read whichever came first. When the
caller adds variables on Windows, the native code builds the block for
`CreateProcessW` itself:

- it adds the launcher's hidden entries whose names start with `=`, such as
  the drives' current directories (`=C:`), which `Platform.environment` leaves
  out and `CreateProcessW` does not add to a block it is given;
- it sorts the entries by name without regard to case, as Windows requires.

With `inheritEnvironment: false` the variables the caller gives are the host's
whole environment, and nothing is inherited. The launcher does this on Linux,
where it gives the host its own environment without what its AppImage set
([Emulator host UI](<AnyPS5 Desktop - Emulator Host UI.md>), "The host's environment"). That
environment cannot be empty: the native code gives the host the launcher's own
environment when it is given no entries, so `start` refuses an empty one with
an `ArgumentError` instead.

**Windows.**

- The host gets two anonymous pipes. Their host ends are made inheritable only
  for the moment of `CreateProcessW`, under one lock, and are passed with
  `PROC_THREAD_ATTRIBUTE_HANDLE_LIST`.
- `dart:io` starts its own processes with a handle list too, so its processes
  never inherit these pipes.
- The host starts suspended. It is assigned to a job object with
  `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`, then resumed, so it never outlives the
  launcher.

**macOS.** `posix_spawn` with:

- `POSIX_SPAWN_CLOEXEC_DEFAULT`;
- a `dup2` of the socket to descriptor 3;
- an empty signal mask, with `SIGTERM` at its default.

The Dart VM waits for its own process ids through kqueue, so the host's exit
code belongs to this client.

**Linux.** The same `posix_spawn` call as macOS, with two differences:

- **A dedicated start thread.** The host is started from one thread that lives
  as long as the launcher, because the host's `PR_SET_PDEATHSIG` fires when
  the thread that started it exits.
- **The Dart VM can reap the host.** Whenever a `dart:io` process is running,
  the VM reaps children with a plain `wait()` (`runtime/bin/process_linux.cc`),
  and that can take the host. So the client watches the host through a pidfd:
  - its exit is seen even when the VM reaps it first;
  - the exit code is read with `WNOWAIT` while the process still exists;
  - kills go through `pidfd_send_signal`, so they can never reach a later
    process given the same id.

  With glibc 2.39 or later, `pidfd_spawn` makes the pidfd together with the
  process. Where it is missing, or the kernel cannot do it, the host is started
  with `posix_spawn` and its pidfd is opened just after. A pidfd fixes its
  process once opened, so the client then checks that the process is the host:
  its descriptor 3 must be the launcher's own socket (`/proc/<pid>/fd/3`).
  This guards against a host that ended at once, was reaped by the VM, and had
  its id given to another process, even another child of the launcher.
  - If the check fails, the client never signals or waits for that id, and takes
    the end of the control stream as the host's exit. That includes systems
    where `/proc` hides a child's descriptors (`ptrace_scope` 2 or 3) and the
    glibc is older than 2.39. A host that has to be ended is then ended by
    closing its stream, which the protocol makes it exit on within 10 seconds.
  - On Linux 5.3, which has `pidfd_open` but not `waitid(P_PIDFD)`, the pidfd
    still shows the exit, but the exit code is unknown and the host is left for
    the VM to reap, since waiting by id could reach a later process.
  - Before 5.3 there is no pidfd, and the client kills and waits by id, as
    programs did before pidfd existed.

**The exit code is not always known.** If the VM reaps the host before the
client reads its exit code, the code is lost. That can happen on any Linux
kernel, and on kernels without pidfd it applies to kills too. The client then
reports the code as unknown, and treats an unknown code after `shutdown` as a
clean exit.

**The last reply comes before the exit.** On every system, the exit is
reported only after the reader has passed on everything the host wrote, so a
reply sent just before the host exits is not overtaken. The exception is when
something else still holds the host's end of the stream: the reader then
cannot see the stream end, and the exit is reported after 2 seconds anyway.
(In lost mode, where a Linux host's identity could not be checked, the end of
the stream is the exit, so there is no such limit.)

## Finding and checking the host

`RetroHostRelease` does what the protocol's "Finding and checking the host"
section asks of a launcher. A host release is signed like a launcher release:
`SHA256SUMS` and `SHA256SUMS.sig`, checked with
[`release_signing.dart`](../lib/core/release_signing.dart) and the keys in
[`release_keys.dart`](../lib/core/release_keys.dart). Beside them, each system
has `anyps5-retro-host-<version>-<os>-<arch>.zip` and its `.files`, which lists
every file in the zip in `shasum` format. The host repository's
`tools/package_release.py` writes them, and its `docs/host.md` "Releases" says
where the maintainers sign.

- **Where the host lives.** In `RetroHost/host` in the launcher's own data
  folder, beside its toolkits and its ffmpeg (`AppPaths.retroHost`:
  `%LOCALAPPDATA%\AnyPS5\RetroHost` on Windows,
  `~/.local/share/AnyPS5/RetroHost` on Linux). The folder holds the unpacked
  zip, with `SHA256SUMS`, `SHA256SUMS.sig`, this system's `.files` and
  `.release-tag` (the tag the release was published under) kept beside it. This departs from protocol.md as written (at
  9052aff), which says a release launcher runs "a host it ships with or
  downloads into its own storage: from its own directory on Windows and
  Linux", found with `GetModuleFileNameW` or `/proc/self/exe`. The launcher's
  own directory cannot take a download: the AppImage mounts it read-only, and
  the Windows installer may put it where the user cannot write. The data
  folder is the launcher's own storage that only the user can write, which is
  what the protocol's Linux rule for SwanStation relies on, and the toolkits
  and ffmpeg already live there. The host repository's release pull request
  makes the same change to the protocol text (see "Not yet").
- **Which files are this system's.** Only the names for `windows-x64`,
  `linux-x64` or `macos-arm64`, by exact name. A release with no `.files` for
  this system, or more than one, is refused. The version is read from that
  name, so it is covered by the signature.
- **The tag must be the signed version.** The launcher picks a release by its
  tag, but installs the version its signed `.files` name gives. Someone who
  can publish releases without the signing key could otherwise publish an
  older signed release again under a higher tag, and launchers would take it
  for an update. So a release tagged anything but `v<signed version>` is
  refused (`RetroHostRelease.checkTag`): on download, right after the
  signature and before the zip is fetched; on install; and before every
  start, against the tag kept in `.release-tag`. A host with no
  `.release-tag`, or with another tag in it, does not start and is offered
  for download again. The name starts with a dot, which no file of a release
  may, so it never clashes with one.
- **Minimum version.** `RetroHostRelease.minimumVersion` (1.0.0 now) is built
  in. An older host is refused even when it is signed, so a signed host with a
  known fault cannot be put back. Versions are exactly three numbers.
- **The download** (`RetroHostStore`,
  [`retro_host_store.dart`](../lib/core/retro_host/retro_host_store.dart)).
  Host releases are read from the GitHub releases of
  `AnyTogether/anyps5-retro-host`, tagged `v<version>`. `RetroHostStore.newest`
  takes the newest that is not a draft or a pre-release, is at or above the
  minimum version, and has `SHA256SUMS` and `SHA256SUMS.sig`. `fetch` then
  downloads `SHA256SUMS` and `SHA256SUMS.sig` first and checks the signature
  (`RetroHostRelease.signed`) before anything else is fetched. Only then does it
  download this system's `.files` and zip, each checked against the digest the
  signed sums give it. The other systems' files and the source archive are not
  downloaded. A redirect from https to plain http is refused for every
  download (`AssetDownload.redirected`); GitHub's release downloads only
  redirect within https. Files go to `RetroHost/.downloads/<tag>`, resuming as the ffmpeg
  and toolkit downloads do. A release with no signature is "not available yet",
  and there is no way to take one unsigned. A release that has no host for
  this system is also "not available". `fetch` gives the folder with the tag,
  and `putInPlace` then installs it under that tag.
- **On install** (`RetroHostRelease.install`). The signature and the tag are
  checked again from the files on disk, then the zip and the `.files` against
  `SHA256SUMS`, then every file in the zip against the `.files`. A file that
  is missing, an extra file, or a symbolic link is refused. Names follow the
  host's `package_release.py --check`: each part is letters, digits and
  `._+-`, does not start or end with a dot and is no Windows device name
  (`con`, `prn`, `aux`, `nul`, `com0`-`com9`, `lpt0`-`lpt9`, with or without
  an extension), and no two names differ only in case or are a file and a
  folder of each other (`parseFileList`). The names are signed, so this is
  defence in depth. Only then is the zip written out, into `host.new`. The
  reading, hashing and writing run on another isolate (`Isolate.run`), so the
  window stays responsive through a large zip. The two renames then run on
  the UI isolate, one after the other: the old host is moved aside to
  `host.old`, `host.new` takes its place, and `host.old` is removed. On
  Windows the first move fails while a host started from that folder still
  holds its files. The install then stops with the old host whole ("the host
  is in use"), never half deleted. Stop the host before installing.
- **A launcher stopped between the two renames.** It leaves no `host` and
  the old host in `host.old`. `RetroHostRelease.restore` puts `host.old`
  back whenever `host` is missing: on the next look for the installed host
  (`RetroHostStore.installed`, when the launcher starts) and before the next
  install's renames. The host put back is checked before every start, like
  any other.
- **Before each start** (`checkBeforeStart`, through `RetroHostStore.check`).
  The signature is checked again, then the kept tag against the signed
  version, then the `.files` against `SHA256SUMS`, then
  the host executable and SwanStation against the `.files`. Each of the two is
  hashed from a `CheckedFile`, on another isolate.
  - On Windows both stay open with read sharing only (no `FILE_SHARE_WRITE`
    or `FILE_SHARE_DELETE`). Nothing can write, rename or delete them, or
    rename another file onto them, until the host has exited. The host loads
    SwanStation again for every game it starts, so a file let go after the
    first game would leave the next game's load unchecked.
  - On Linux the host's descriptor is above 3 and close-on-exec. The host is
    started through it: `RetroHostChecked.program` is `/proc/self/fd/<n>`,
    which the native start passes to `posix_spawn` as the path, while
    `argv[0]` stays the real path. So the file that was checked is the file
    that runs, even if the path is replaced in between. SwanStation is checked
    by path, as the protocol allows on Linux.
  - `RetroHostClient.start(checked: ...)` releases the files once the host
    has exited, whether it was shut down, exited unasked or was killed after
    a time limit or a broken rule, and before `exited` completes; a start that
    fails releases them at once. It refuses a command whose program is not
    the checked executable, and for the whole life of that host it refuses
    any `start` whose `core` is not the release's SwanStation, so a checked
    host never loads another core. A check is good for one start: a second
    start with it, or a start after it was released, is refused, so run
    `checkBeforeStart` again before each start.
  - A kept host that plays another game is checked again before that game
    (`AppModel._recheckKeptRetroHost`): its own check's files are still held,
    but on Linux SwanStation was checked by path and is loaded again for each
    game. The second check is let go at once. A host that fails it is shut
    down, and so is a kept host while a download is installing.
  - A file swapped for something that is not a regular file (a FIFO, say) is
    refused at once; the descriptor is opened without blocking.
- **When a check fails.** `RetroHostReleaseFailure` is thrown and the host is
  not started. The UI says that the emulator needs to be downloaded again
  ([Emulator host UI](<AnyPS5 Desktop - Emulator Host UI.md>), "In the launcher").
- **Debug and test builds.** `RetroHostInstall.locate`
  ([`retro_host_install.dart`](../lib/core/retro_host/retro_host_install.dart))
  finds the host that `ANYPS5_RETRO_HOST` names, with the SwanStation library
  beside it, only in a debug build or a test build (`RetroHostBuild`, below).
  That host is started without any check, and Settings › Emulators says so
  ("Unchecked PS1 emulator (test build)"), as does a mark in the corner of
  the game's screen while a game plays on it. It has no `.release-tag` and is
  not held to one: the tag belongs to the signed release it was downloaded
  as, and an unchecked host (`checked` false) never reaches
  `checkBeforeStart`. It is also played in preference to a downloaded host
  (`retroHostInstall` is `retroHostUnchecked ?? retroHostDownload.installed`),
  so a downloaded host that would fail its check, a missing tag included, is
  neither checked nor marked broken while the unchecked one is used. A release, and a profile build,
  ignore the variable and only run the downloaded release's host
  (`RetroHostStore.installed`, a `RetroHostInstall` with `checked` set), and
  only with that release's SwanStation.

## Debug and test builds

A tester's PS1 host is usually one they built themselves, and no signed host
release exists yet. A debug launcher can run it, but a debug Windows build
links Microsoft's debug C++ runtime (`MSVCP140D`, `VCRUNTIME140D`,
`ucrtbased`), which may not be redistributed, so a friend without Visual
Studio cannot start it. A **test build** is the way to hand someone an
unchecked host: it is compiled in release mode, so it ships the normal
release runtime (`windows/CMakeLists.txt` installs it beside the launcher with
`InstallRequiredSystemLibraries`), and it is told at compile time that it may
run the host `ANYPS5_RETRO_HOST` names.

```bash
flutter build windows --release --dart-define=ANYPS5_UNCHECKED_RETRO_HOST_BUILD=true
flutter build linux --release --dart-define=ANYPS5_UNCHECKED_RETRO_HOST_BUILD=true
```

Then start it with `ANYPS5_RETRO_HOST` set to the absolute path of the host
executable, with `swanstation_libretro.dll` (or `.so`) beside it, as for a
debug build.

On Windows the build folder's path must stay short (MSBuild's 260-character
limit). Built this way with Flutter 3.47.1 and the VS 2022 Build Tools, the
launcher and every plugin import only the release runtime (`MSVCP140`,
`VCRUNTIME140`, `VCRUNTIME140_1` and the system's UCRT), and
`runner/Release` holds those DLLs. media_kit's ANGLE archive also brings a
`zlib.dll` that imports `VCRUNTIME140D` and `ucrtbased`; release builds leave
it out and check that nothing in the bundle needs the debug runtime (#156,
README "Packages"), so a test build passes the same check.

**How it is decided.** `RetroHostBuild.of(debug: kDebugMode)` gives `debug`,
`test` or `release`. `test` comes only from `RetroHostBuild.testDefined`,
which is `const bool.fromEnvironment('ANYPS5_UNCHECKED_RETRO_HOST_BUILD')`:
the Dart compiler folds it into the compiled program, so it is `true` only
when that `--dart-define` was given to `flutter build`. No setting, file,
command-line argument or environment variable of the running launcher can
change it (an environment variable of that name is ignored, which the tests
check). A build without it is a `release`, and `RetroHostInstall.locate`
returns nothing for a `release` whatever the environment holds. So
everything a normal release does is unchanged: only the signed, checked host
runs. `RetroHostBuild` is in
[`retro_host_build.dart`](../lib/core/retro_host/retro_host_build.dart).

**What keeps a test build from being published.** Every package and nightly
is built by `.github/workflows/ci.yml` (`nightly.yml` calls it) or by
`packaging/windows/build-installer.ps1` and `packaging/linux/common.sh`. Each
runs [`tool/check_release_build.dart`](../tool/check_release_build.dart) right
after `flutter build`, and fails on a test build in two ways:

- **What Flutter compiled with.** `flutter build windows` and `flutter build
  linux` write every `--dart-define` they were given, on the command line or
  from `--dart-define-from-file`, into
  `<windows or linux>/flutter/ephemeral/generated_config.cmake` as
  `DART_DEFINES`: each `NAME=value` base64 encoded and the list comma
  separated (flutter_tools' `encodeDartDefines`), which is what the Dart
  compiler is given. The check decodes it and fails if the test build's define
  is there with any value, however the build step was written.
- **What it built.** A test build writes `RetroHostBuild.testMark`
  ("AnyPS5 launcher test build") to its log when it starts
  (`RetroHostBuild.announce`, called by `main`). That code is under
  `if (testDefined)`, and the Dart compiler drops it, and the text with it, from
  every other build, as it does with code under `kDebugMode` in a release. Dart
  keeps an ASCII string in an AOT snapshot as its bytes, so the check reads the
  snapshot Flutter ships (`data/app.so` on Windows, `lib/libapp.so` on Linux)
  and fails if the text is there, or if there is no snapshot.

[`check_release_build_test.dart`](../test/tool/check_release_build_test.dart)
reads `DART_DEFINES` as flutter_tools writes it, refuses the define with any
value, and compiles a program that calls `announce` with `dart compile
aot-snapshot`, with and without the define: only the test build's snapshot
holds the mark, and the check passes the other. A test in
[`retro_host_install_test.dart`](../test/core/retro_host/retro_host_install_test.dart)
also fails if any file in `.github`, `packaging` or `tool` names the define.

**Why this design.** It is the usual way to keep a developer route out of a
shipped program:

- Flutter's own build modes leave no room for it. A debug build has the debug
  runtime above, and Flutter's documentation keeps profile mode for measuring
  performance, with DevTools still able to connect and some service
  extensions on (<https://docs.flutter.dev/testing/build-modes>); release mode
  is the one for deploying. Flutter's `--flavor` is not offered for Windows
  and Linux builds, so `--dart-define` read by `bool.fromEnvironment` is
  Flutter's way to make a release-mode build that differs at compile time.
- Firefox enforces add-on signatures the same way: release and beta builds are
  compiled with `MOZ_REQUIRE_SIGNING`, which makes the
  `xpinstall.signatures.required` preference ignored, and developers who need
  unsigned add-ons use differently built (unbranded, Developer Edition or
  Nightly) builds instead of a switch in the release
  (<https://wiki.mozilla.org/Add-ons/Extension_Signing>).
- RetroArch and Lutris let a tester point at any core or runner build, but
  they check no signatures, so they have no secure path to keep. Emulators
  that publish both kinds, as Dolphin does with its development builds and
  releases, make them separate builds on separate update tracks; that is the
  part that applies here: a test build is a different program, not a setting.

A runtime switch (a setting, a command-line flag, a variable read by a
release) was rejected: anyone, or any program, able to set it for a normal
user's launcher could make that launcher run an unchecked program.

**How a tester's screenshot is told apart.** While a game plays on the
unchecked host, a debug or test build marks the game's screen with a small
corner label, "Unchecked PS1 emulator (test build)", on every screen of the
game and over every layer above it, so a screenshot of a test build can never
pass for a release. The review of host #14 made this a condition of test
builds; the Settings row alone is not enough. The mark is drawn only under the
compile-time constant `kDebugMode || RetroHostBuild.testDefined`
(`RetroHostPlaying.marksUnchecked`), so a release does not have it at all
([Emulator host UI](<AnyPS5 Desktop - Emulator Host UI.md>) "The unchecked-host
mark").

**What a test build is not.** It is never published. It still checks a
downloaded host as a release does; it only also runs the named one, which
comes first, as in a debug build. It is still updated by the launcher's own
update check like any build, and an update replaces it with a normal release.

## Threads and the UI

The control stream is read and written only by the native threads. Messages
reach Dart through a `NativeCallable.listener`, which never blocks them. On
Linux and macOS the writer and the exit watcher wait on one condition variable
(the watcher from the start in lost mode), so queueing a message wakes every
waiter: waking only one could wake the watcher and leave the message unsent.

`close()` waits, inside `Isolate.run`, for the host and the threads; when the
client gave up on the host itself, `close()` waits for that same release. Once
the host is started, nothing on the UI isolate ever waits on it, as the
protocol's "Timeouts" section requires; the start itself is the one exception
(below).

**The last event.** Every close, and every start that fails, ends with a
`closed` event, which the native side sends once every thread that reports
events has finished. The client closes its callback only after handling it.
Messages still queued for the isolate at that point (the exit is not always
the last: the reader can still be passing on the stream when the 2 second
limit above lets the exit through) are then freed, with any ring descriptor
that came with them, instead of being dropped with the callback. A start that
fails on Windows after the host's threads began tears them down the way
`close()` does, so its `closed` event still comes.

**Starting is not off the UI isolate.** `RetroHostClient.start` makes the
process on the calling isolate and returns once it exists, with its pid, so
`hello` goes out at once. On Windows that is as long as `CreateProcessW` takes,
which can be slow while antivirus scans a new executable; on Linux it is the
wait for the start thread. Moving it to another isolate would make `start`
asynchronous for every caller, so it stays here; the UI should start the host
where a short pause does not show.

**Descriptors.** The reader looks at every control message of a read. If one
is not `SCM_RIGHTS`, the control data was cut short, or a descriptor came
where the protocol allows none, the message is a framing error and every
descriptor that came with it is closed, also those in later items, as the
protocol's "Framing" section asks of the receiver.

## Time limits and failures

The limits are measured on a `Stopwatch`, which follows a monotonic clock, so
a change of the wall clock, such as a correction after waking from sleep,
cannot set one off.

| Limit | Time | When it is missed |
| --- | --- | --- |
| `welcome` after the start | 10 s | The host is killed: `hostHung` |
| A reply to each call | 5 s | The host is killed: `hostHung` |
| A `pong` to each ping (pings every 2 s) | 5 s | The host is killed: `hostHung` |
| A write in progress | 5 s | The host is killed: `hostHung` |
| The game ends after `stopGame()` sends `stop`, counted from the send, also while `start` is still waiting | 10 s | The host is killed: `hostHung` |
| The host exits after `shutdown()` | 15 s | The host is killed: `hostHung` |

"Killed" means signalled through its pidfd, `TerminateProcess` on Windows, or
by id only where the system has no pidfd. In every case the client then closes
the connection, so a host it could not signal sees its stream end and exits.

`stopGame()` asks for `status` until the game has ended, because the client
has to see the end to enforce the stop limit. So `call('stop')` is refused:
`stop` goes only through `stopGame()`. Only a reply to a call sent after
that `stop` can lift the limit: a `status` sent before it, still answered
null or ended for an earlier state, does not. `failureReason` names the limit
that was missed.

If the host breaks a rule, exits unasked or misses a limit while a game is
loaded:

- `status()` gives the short report from the protocol's "Host failure"
  section;
- `pause`, `stop`, `release` and `volume` give null;
- `connectedPorts`, `changeDisc` and `option` give false.

This lasts until `release`. A call still waiting when the connection ends is
answered the same way, and never left waiting. `start` is not on the
protocol's list: once the connection has ended it throws `RetroHostGone`, also
while a failed game is still reported, since the next game needs a new host.
Every other call throws `RetroHostGone` when no game was loaded.

## Frames

- **Each `frame` message.** The client pins the newest frame and checks it, as
  the protocol's "Checks the launcher makes" section says, and adds an event to
  `frames`.
- **Which frames are drawn.** Only a frame of the current game (its `epoch` is
  the one `start` returned) is drawn and kept as `frame`.
- **How long a frame stays readable.** A ring stays mapped while the frame
  being shown is in it, but the client never maps more than two rings: when a
  third arrives, it lets go of the oldest, and the frame shown from it, before
  mapping the new one. So
  `frame` stays readable until another frame replaces it, or until a second
  newer ring arrives first, or until a `frame` message moves the pin without
  pinning a newer frame of this game (the host may then write the old slot);
  in the last two cases `frame` becomes null. Read `frame` again after
  each message. A frame that was not drawn can be read only until the next
  message. `close()` and a third ring unmap a ring while a `PinnedFrame` from
  it may still be held, so each frame shares its ring's `RingMapping`:
  `FrameRing.unmap` ends it, and `PinnedFrame.copyPixels()` then gives null
  instead of reading memory that is gone. Read pixels only through
  `copyPixels()`.

## Which game is loaded

The client counts a game as loaded from `start`'s reply until `release` is
answered for a game a `status` showed ended, or until a `status` returns null,
which means no game is loaded. `release` does nothing while the game still
runs, and its reply is null either way, so a `release` answered before the end
was seen leaves the game loaded. The protocol has the launcher call `release`
for an ended game, so the client relies on a `status` showing the end first:
the host may then answer `release` and exit with no game loaded (a stuck
core), which reports no failed game, while a host that exits after a
`release` of a running game reports the game failed. A host failure reports a
failed game (see above) only while a game is loaded, and zeroes the motors
whenever one is.

## Resets

- **Input.** Losing input focus zeroes both controllers' input. A started game
  gets zero input on both ports.
- **Rumble.** All motors are set to zero:
  - on `start`, `release` and `pause(true)`;
  - when a `status` first shows the game ended;
  - when input focus is lost;
  - when `connectedPorts(1)` takes the controller out of port 2. Rumble for a
    port without a controller (port 2 until `connectedPorts(2)`, and again
    after `connectedPorts(1)`) is not forwarded;
  - when the connection ends with a game loaded, a clean shutdown included;
  - on a host failure.
- **Which rumble is forwarded.** Only rumble of a running game: none while no
  game is loaded, and none once a `status` showed the game ended, until the
  next `start` is answered. The host takes calls in order, so the client
  judges each `rumble` by the state the host will have once it has taken every
  call sent so far: what the replies confirmed, then each call still waiting as
  if it succeeds. A `pause(true)` or `connectedPorts(1)` stops rumble as soon
  as it is sent, a `pause` or `connectedPorts` sent before an earlier `start`
  was answered still counts, and a call the host refuses changes nothing. A
  `start` sent while a game is loaded counts for nothing, since the host
  refuses it with `busy`. When a reply leaves rumble stricter than before (a
  refused resume, say), the motors are zeroed again.
- **Rumble events** come asynchronously, so a listener may call anything on the
  client, `close()` included. Frame events stay synchronous because a frame
  that is not drawn can be read only until the next message.
- **After the end.** Once the connection has ended, a change of input focus is
  ignored: there is no host to send input to, no rumble comes, and after
  `close()` the rumble stream is closed.

## Tests

[`test/core/retro_host/retro_host_fixtures_test.dart`](../test/core/retro_host/retro_host_fixtures_test.dart)
is the launcher's conformance test.

- **How it works.** It plays every fixture session whose `tests` includes
  `launcher` against the host repository's fake host (`tests/fake_host.py`).
  The client starts the fake host through its real start path, as if it were
  the host.
- **What the test does.** It does what the UI would: the calls, `input`,
  `shutdown` and `stopGame()`, reading frames, and `status()` after a failure.
- **What it checks.** The outcome, and the fake host's report of every message
  the client sent.
- **Extra sessions.** Sessions of its own check that a reply with a wrong
  result still answers its call, that a frame of another game takes away the
  frame shown, that a refused call keeps the calls in order, that a pause with
  no game does not silence the next game's rumble, and that the motors are
  zeroed when a rumble listener closes the client, when `connectedPorts(1)`
  takes away port 2, and on a clean shutdown. Two check that `start` after a
  host failure, and a `start` still waiting when the host fails, throw
  `RetroHostGone` while the failed game stays reported.

[`test/core/retro_host/retro_host_real_test.dart`](../test/core/retro_host/retro_host_real_test.dart)
runs the client against the real host and the real SwanStation core, as the
host repository's `tests/real_core.py` does:

- **What it plays.** The free OpenBIOS boots a small PS-EXE that the host
  repository's `tests/make_test_disc.py` puts on a disc image.
- **What it checks.** `start` with the BIOS options, `status` until `ready`, at
  least 100 drawn frames in 10 seconds, two pinned frames that are not black
  and differ, then `stopGame()`, `release` and `shutdown`, ending `clean` with
  exit code 0.
- **How to run it.** Set `ANYPS5_RETRO_HOST_REAL` to a JSON file naming
  `host`, `core`, `bios`, `program` and `discBuilder` (the path of
  `make_test_disc.py`), with an optional `environment` for the host, such as
  a `PATH` that has the host's runtime libraries. Python 3 must be on `PATH`.
  Add `packer` (the host repository's `tools/package_release.py`) and
  `coreLicence` (SwanStation's `LICENSE`) to start the host from a checked
  release. Without the variable the test is skipped, so CI skips it.

[`test/core/retro_host/retro_host_release_test.dart`](../test/core/retro_host/retro_host_release_test.dart)
covers the release checks. It replays a recorded release in
[`test/fixtures/retro_host_release`](../test/fixtures/retro_host_release), as
the host repository publishes one: each system's zip and `.files` and a source
archive, packed from small stand-in files by that repository's
`tools/package_release.py` (from the host's release pull request), `SHA256SUMS` from its
`--sums`, and `SHA256SUMS.sig` written by AnyPS5-ARM's `tools/release/sign.sh`
with a throwaway key kept beside them (`test-release-signing.key`, its public
half in `test-release-signing.pub`). No launcher trusts that key; it is not a
secret. [`retro_host_release_fixture.dart`](../test/support/retro_host_release_fixture.dart)
reads the fixture for the tests. They check:

- that the recorded `SHA256SUMS.sig` is exactly the fixture key's signature
  (Ed25519 signatures are deterministic, so the launcher's own signing of the
  same sums gives the same line), and that the recorded release installs and
  checks out unchanged for all three systems;
- that a signed download unpacks and checks out before a start;
- that the unchecked host of a debug or test build, with no `.release-tag`,
  plays without a check while a downloaded host missing its tag sits beside
  it, and that host is not marked broken
  (`test/ui/retro_host_release_play_test.dart`);
- that each of these is refused: an untrusted key, a changed zip or `.files`,
  an extra or missing file in the zip, a host below the minimum version, a
  release under a tag that is not its signed version (an older signed
  release published again under a higher tag, on install, and a changed,
  missing or unreadable `.release-tag` before a start), a changed, missing or
  replaced host or core, unsafe names (dots at either end, device names,
  other characters) and names that differ only in case or are a file and a
  folder;
- that on Windows the held files cannot be written, renamed or deleted;
- that on Linux a real program started from a checked release runs from the
  checked descriptor even after its path was replaced, and that the
  descriptor does not reach it;
- that installing over a host replaces it whole, that a launcher stopped
  between the two renames gets its old host back (and that the next install
  over that state works), and that on Windows a host whose files are held is
  left whole and is replaced once they are let go.

Tests that change the release sign the copy again with keys of their own,
to tell the trusted key from a stranger's.

To make the fixture again, pack each system's stand-in files with
`package_release.py --version 1.0.0 --system <system> --host <stand-in>
--core <stand-in> --core-licence <stand-in> --core-notices <folder>
--notice swanstation-vulkan-headers-Apache-2.0.txt=<stand-in> --host-commit
<sha> --swanstation-commit <sha> --out <folder>`, add a stand-in source archive,
write `SHA256SUMS` with `--sums`, then sign it with `sign.sh -k <key> -o
<folder> <zips> <.files> <source archive>`, after adding the key's public line
to a copy of `tools/release/release-signing.pub`. Keep the key file beside the
release.

[`test/core/retro_host/retro_host_store_test.dart`](../test/core/retro_host/retro_host_store_test.dart)
serves the recorded release from a fake GitHub
([`fake_github.dart`](../test/support/fake_github.dart)) and checks the
download. It checks that only this system's `.files` and zip are fetched after
the signed sums, and that the result installs and checks before a start. It
checks that the newest signed release at or above the minimum is taken, never
a pre-release. A release without a signature downloads nothing, and one signed
by an untrusted key stops after the sums. An older signed release published
again under a higher tag also stops after the sums, a newer one installs as
its tag's version (and not under another tag), and a host left in `host.old`
is found again. A changed zip is refused before it is
unpacked, a release with no host for this system is not available, and a
stopped download resumes.

With `packer` and `coreLicence` in its JSON, the real-host test packs the host
and SwanStation as a release, signs it, installs it, checks it and starts it
from the checked files. It also checks that both files stay held while the
game loads and after it was stopped and released, ready for the next game's
core load (on Windows, that nothing can write them), and that they are
released once the host has exited.

The fixture test also starts the fake host as a checked host, with the
session's core as the checked file. It checks that the file stays held after
every reply through a game that gets ready, ends and is released, and a second
game, then is let go once the host exits; on Windows it tries to write,
replace, rename and delete the core after each reply. Two more sessions check
the same when the host exits unasked and when it is killed for a broken rule.

[`test/core/retro_host/retro_host_environment_test.dart`](../test/core/retro_host/retro_host_environment_test.dart)
covers how the host's environment is put together, and
[`test/core/retro_host/retro_host_close_test.dart`](../test/core/retro_host/retro_host_close_test.dart)
checks that a start that fails throws `ProcessException` and that a focus
change after `close()` is ignored.

[`test/core/retro_host/strict_json_test.dart`](../test/core/retro_host/strict_json_test.dart)
covers the JSON rules, and
[`test/core/retro_host/frame_ring_test.dart`](../test/core/retro_host/frame_ring_test.dart)
covers pinning, including three tries that all miss, and that a frame pinned
before its ring was unmapped gives no pixels.

To run the fixture test, point `ANYPS5_RETRO_HOST_CHECKOUT` at a checkout of
the host repository. Python 3 must be on `PATH`:

```bash
ANYPS5_RETRO_HOST_CHECKOUT=/path/to/anyps5-retro-host flutter test test/core/retro_host
```

CI runs `test/core/retro_host` against the host repository at the commit
named in `.github/workflows/ci.yml`:

- on `ubuntu-latest` in the test shards, where glibc has `pidfd_spawn`;
- on Ubuntu 22.04 in the Linux build job, where glibc 2.35 has none, so the
  host is started with `posix_spawn` and its pidfd opened after and checked
  through `/proc/<pid>/fd/3`, the path Debian 12 takes too;
- on macOS in the goldens job, with `posix_spawn`;
- on Windows in the Windows build job, with the handle list, the job object
  and the ring's `DuplicateHandle`, `MapViewOfFile` and `VirtualQuery` checks.
  The sessions that are only for Linux and macOS skip themselves there.

That commit is the host repository's `main` with its fake host merged
(AnyTogether/anyps5-retro-host#10).

[`test/core/retro_host/retro_status_test.dart`](../test/core/retro_host/retro_status_test.dart)
covers how a `status` is read, and reads every status the fixture sessions send
when `ANYPS5_RETRO_HOST_CHECKOUT` is set.

## Not yet

- **protocol.md names debug builds only.** The host repository's protocol.md
  at 9052aff, "Finding and checking the host", says "Debug builds of the
  launcher MAY run the host named by the environment variable
  `ANYPS5_RETRO_HOST`" and "Release builds ignore that variable". A test build
  ("Debug and test builds" above) is compiled in release mode but is no
  release and is never published. A host pull request of its own, separate
  from the host's release packaging, adds test builds to that text.
- **No signed release yet.** The download reads the host repository's
  GitHub releases, and none is published there yet: until the maintainers
  sign and publish one (that repository's `docs/host.md` "Releases"), a
  release build says no signed PS1 emulator has been published yet, and has no
  host to run. The whole path was tested with a real release that the host
  repository's release workflow packed, signed with the test key
  ([Emulator host UI](<AnyPS5 Desktop - Emulator Host UI.md>), "Against the real host").
- **The protocol's storage sentence.** protocol.md at 9052aff still says the
  host lives in the launcher's own directory; the launcher keeps a downloaded
  host in its data folder (above), since an AppImage's directory is read-only.
  The host repository's release pull request changes that text.
- **No update check on its own.** A newer host is looked for only when the
  player selects the emulator's row in Settings › Emulators, as ffmpeg's
  download works. Nothing asks GitHub unprompted.
- **No host log.** The host's standard error is not captured.
