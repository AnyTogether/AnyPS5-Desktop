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
| [`lib/core/retro_host/retro_host_release.dart`](../lib/core/retro_host/retro_host_release.dart) | Finds the host and checks its signed release before it is unpacked and before each start (see "Finding and checking the host" below). |
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

- **Where the host lives.** In `retro-host/` beside the launcher's executable
  (`Platform.resolvedExecutable`). The folder holds the unpacked zip, with
  `SHA256SUMS`, `SHA256SUMS.sig` and the `.files` kept beside it.
- **Which files are this system's.** Only the names for `windows-x64`,
  `linux-x64` or `macos-arm64`, by exact name. A release with no `.files` for
  this system, or more than one, is refused. The version is read from that
  name, so it is covered by the signature.
- **Minimum version.** `RetroHostRelease.minimumVersion` (1.0.0 now) is built
  in. An older host is refused even when it is signed, so a signed host with a
  known fault cannot be put back. Versions are exactly three numbers.
- **On download** (`install`). The signature is checked, then the zip and the
  `.files` against `SHA256SUMS`, then every file in the zip against the
  `.files`. A file that is missing, an extra file, or a symbolic link is
  refused, and so is any name with `..`, `\`, `:` or an empty part. Only then
  is the zip written out, first into `retro-host.new`, which then replaces
  `retro-host`. Stop the host before installing: on Windows its files are
  held.
- **Before each start** (`checkBeforeStart`). The signature is checked again,
  then the `.files` against `SHA256SUMS`, then the host executable and
  SwanStation against the `.files`. Each of the two is hashed from a
  `CheckedFile`, on another isolate.
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
  - A file swapped for something that is not a regular file (a FIFO, say) is
    refused at once; the descriptor is opened without blocking.
- **When a check fails.** `RetroHostReleaseFailure` is thrown and the host is
  not started. The UI should then say that the emulator needs to be downloaded
  again.
- **Debug builds.** `RetroHostRelease.locate()` runs the host that
  `ANYPS5_RETRO_HOST` names, without checks, and leaves the core to the caller.
  Release and profile builds (`dart.vm.product`, `dart.vm.profile`) ignore the
  variable; the `debug` argument can only turn it off, never on. A release launcher
  only ever runs the SwanStation of the checked release
  (`RetroHostLaunch.core`).

## Threads and the UI

The control stream is read and written only by the native threads. Messages
reach Dart through a `NativeCallable.listener`, which never blocks them. On
Linux and macOS the writer and the exit watcher wait on one condition variable
(the watcher from the start in lost mode), so queueing a message wakes every
waiter: waking only one could wake the watcher and leave the message unsent.

`close()` waits, inside `Isolate.run`, for the host and the threads; when the
client gave up on the host itself, `close()` waits for that same release. Nothing on
the UI isolate ever waits on the host, as the protocol's "Timeouts" section
requires.

## Time limits and failures

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
answered the same way, and never left waiting.

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
  message.

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
  takes away port 2, and on a clean shutdown.

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
covers the release checks. It uses what the host repository's packer wrote,
from small stand-in files, in
[`test/fixtures/retro_host_release`](../test/fixtures/retro_host_release):
each system's zip and `.files`, and the unsigned `SHA256SUMS`. The tests sign
that `SHA256SUMS` with a throwaway key. They check:

- that a signed download unpacks and checks out before a start;
- that each of these is refused: an untrusted key, a changed zip or `.files`,
  an extra or missing file in the zip, a host below the minimum version, a
  changed, missing or replaced host or core, and unsafe names;
- that on Windows the held files cannot be written, renamed or deleted;
- that on Linux a real program started from a checked release runs from the
  checked descriptor even after its path was replaced, and that the
  descriptor does not reach it;
- that the debug variable works in debug builds only.

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
checks that a focus change after `close()` is ignored.

[`test/core/retro_host/strict_json_test.dart`](../test/core/retro_host/strict_json_test.dart)
covers the JSON rules, and
[`test/core/retro_host/frame_ring_test.dart`](../test/core/retro_host/frame_ring_test.dart)
covers pinning, including three tries that all miss.

To run the fixture test, point `ANYPS5_RETRO_HOST_CHECKOUT` at a checkout of
the host repository. Python 3 must be on `PATH`:

```bash
ANYPS5_RETRO_HOST_CHECKOUT=/path/to/anyps5-retro-host flutter test test/core/retro_host
```

CI runs the test on Linux (in the test shards) and on macOS (in the goldens
job), against the host repository at the commit named in
`.github/workflows/ci.yml`. It also passes on Windows. That commit is the host
repository's `main` at 9052aff with its fake host added, until the fake host is
merged there.

[`test/core/retro_host/retro_status_test.dart`](../test/core/retro_host/retro_status_test.dart)
covers how a `status` is read, and reads every status the fixture sessions send
when `ANYPS5_RETRO_HOST_CHECKOUT` is set.

## Not yet

- **Debug builds only.** A PS1 game plays through the host behind a setting
  ([Emulator host UI](<AnyPS5 Desktop - Emulator Host UI.md>), "In the launcher"), and only debug
  builds find a host, through `ANYPS5_RETRO_HOST`.
- **No download.** `RetroHostRelease.install` checks and unpacks a release
  that is already on disk. Fetching it from the host's GitHub releases, and the
  UI that offers it, are not written yet.
- **No host log.** The host's standard error is not captured.
