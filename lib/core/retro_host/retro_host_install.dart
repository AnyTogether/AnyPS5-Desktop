import 'dart:io';

import 'package:path/path.dart' as p;

import '../game_process.dart';
import '../host.dart';
import 'retro_host_build.dart';
import 'retro_host_store.dart';

/// The emulator host and the SwanStation library it loads for a PS1 game: the signed release the
/// launcher downloaded ([RetroHostStore.installed]), checked before each start, or in a debug or
/// test build ([RetroHostBuild]) the host `ANYPS5_RETRO_HOST` names ([locate]), which is not.
/// protocol.md "Finding and checking the host" says "Debug builds of the launcher MAY run the host
/// named by the environment variable `ANYPS5_RETRO_HOST`, and any core, without the checks.
/// Release builds ignore that variable." A test build is compiled in release mode but is not a
/// release, and never published (docs/AnyPS5 Desktop - Emulator Host Client.md "Debug and test builds").
/// The core is the SwanStation library beside the host, as a host release's zip holds the two. A
/// host release with the `ps2` capability has LRPS2 beside them too (anyps5-retro-host docs/ps2.md
/// "Releases"), and so may an unchecked host: that is [ps2Core].
class RetroHostInstall {
  const RetroHostInstall({required this.host, required this.core, this.ps2Core, this.checked = false});

  /// The environment variable that names the host in a debug or test build.
  static const variable = 'ANYPS5_RETRO_HOST';

  /// The host executable.
  final String host;

  /// The SwanStation library, given to the host in `start`.
  final String core;

  /// The LRPS2 library a PS2 game is started with (`start.console` `ps2`), or null when this host
  /// has none beside it: a release that does not ship LRPS2, or an unchecked host built without it.
  final String? ps2Core;

  /// A signed release's host: its files are checked before each start and held until the host
  /// has exited ([RetroHostStore.check], `RetroHostClient.start(checked: ...)`). False for the
  /// host of a debug or test build.
  final bool checked;

  /// SwanStation's file name on [system], as libretro builds name it.
  static String coreName(HostSystem system) =>
      system == HostSystem.windows ? 'swanstation_libretro.dll' : 'swanstation_libretro.so';

  /// LRPS2's file name on [system], as the host's build and its release zips name it
  /// (`pcsx2_libretro`, the name libretro gives the PS2 core).
  static String ps2CoreName(HostSystem system) =>
      system == HostSystem.windows ? 'pcsx2_libretro.dll' : 'pcsx2_libretro.so';

  /// The host's whole environment on [system], from the launcher's [launcher] environment, or
  /// null where the host gets the launcher's own. On Linux it is the launcher's without what the
  /// launcher's AppImage set ([GameProcess.withoutAppImage]), as for a standalone emulator: the
  /// AppImage's runtime variables and its own `usr/share` at the head of `XDG_DATA_DIRS` belong to
  /// the launcher, not to a program it starts.
  static Map<String, String>? environmentFor(HostSystem system, Map<String, String> launcher) =>
      system == HostSystem.linux ? GameProcess.withoutAppImage(launcher) : null;

  /// The host [environment] names and the SwanStation library beside it, when [build] runs an
  /// unchecked host and both files are there; null otherwise, and always for a release. LRPS2 is
  /// its [ps2Core] when it is beside them too, unchecked like them.
  ///
  /// A test build writes [RetroHostBuild.testMark] to its standard error first, every time it
  /// looks. The mark is here, where the unchecked host is found, and written by this function
  /// itself, so that no test build can have this lookup without the mark that
  /// `tool/check_release_build.dart` finds in its compiled program; it is under
  /// [RetroHostBuild.testDefined], so every other build is compiled without it.
  static RetroHostInstall? locate(
    Map<String, String> environment, {
    required RetroHostBuild build,
    required HostSystem system,
  }) {
    if (!build.runsUnchecked) return null;
    if (RetroHostBuild.testDefined) {
      stderr.writeln('${RetroHostBuild.testMark}: runs the emulator host $variable names without checking it');
    }
    final named = environment[variable];
    if (named == null || named.isEmpty || !p.isAbsolute(named)) return null;
    final host = p.normalize(named);
    if (!File(host).existsSync()) return null;
    final core = p.join(p.dirname(host), coreName(system));
    if (!File(core).existsSync()) return null;
    final ps2Core = p.join(p.dirname(host), ps2CoreName(system));
    return RetroHostInstall(host: host, core: core, ps2Core: File(ps2Core).existsSync() ? ps2Core : null);
  }
}
