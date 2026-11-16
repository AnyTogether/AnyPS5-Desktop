import 'dart:io';

import 'package:path/path.dart' as p;

import '../game_process.dart';
import '../host.dart';

/// The emulator host and the SwanStation library it loads for a PS1 game.
///
/// Only debug builds find one for now: protocol.md "Finding and checking the host" says "Debug
/// builds of the launcher MAY run the host named by the environment variable `ANYPS5_RETRO_HOST`,
/// and any core, without the checks. Release builds ignore that variable." The core is the
/// SwanStation library beside that host, as a host release's zip holds the two. Release builds
/// get the signed host release later.
class RetroHostInstall {
  const RetroHostInstall({required this.host, required this.core});

  /// The environment variable that names the host in a debug build.
  static const variable = 'ANYPS5_RETRO_HOST';

  /// The host executable.
  final String host;

  /// The SwanStation library, given to the host in `start`.
  final String core;

  /// SwanStation's file name on [system], as libretro builds name it.
  static String coreName(HostSystem system) =>
      system == HostSystem.windows ? 'swanstation_libretro.dll' : 'swanstation_libretro.so';

  /// The host's whole environment on [system], from the launcher's [launcher] environment, or
  /// null where the host gets the launcher's own. On Linux it is the launcher's without what the
  /// launcher's AppImage set ([GameProcess.withoutAppImage]), as for a standalone emulator: the
  /// AppImage's runtime variables and its own `usr/share` at the head of `XDG_DATA_DIRS` belong to
  /// the launcher, not to a program it starts.
  static Map<String, String>? environmentFor(HostSystem system, Map<String, String> launcher) =>
      system == HostSystem.linux ? GameProcess.withoutAppImage(launcher) : null;

  /// The host [environment] names and the SwanStation library beside it, when this is a [debug]
  /// build and both files are there; null otherwise.
  static RetroHostInstall? locate(Map<String, String> environment, {required bool debug, required HostSystem system}) {
    if (!debug) return null;
    final named = environment[variable];
    if (named == null || named.isEmpty || !p.isAbsolute(named)) return null;
    final host = p.normalize(named);
    if (!File(host).existsSync()) return null;
    final core = p.join(p.dirname(host), coreName(system));
    if (!File(core).existsSync()) return null;
    return RetroHostInstall(host: host, core: core);
  }
}
