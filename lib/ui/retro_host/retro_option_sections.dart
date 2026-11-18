import '../../core/retro_host/retro_resolution.dart';

/// Where a SwanStation option is shown. The host lists every option SwanStation lets the player
/// change now (about fifty for a PS1 game, in SwanStation's order); the launcher groups them.
enum RetroOptionSection {
  /// The picture: SwanStation's `GPU`, `Display` and `TextureReplacements` options, and LRPS2's
  /// resolution scale (`pcsx2_upscale_multiplier`). The in-game menu shows none of them as a
  /// section: they are left for a Graphics page of their own. Only each console's internal
  /// resolution has a row of its own on the menu's first page ([retroResolutionKey]).
  graphics,

  /// The sound: SwanStation's `Audio` options and Mute CD Audio. The menu adds the host's volume.
  audio,

  /// The controllers: SwanStation's `Controller`, `Controller1`, `Controller2`, … and
  /// `ControllerPorts` options.
  controller,

  /// The console: its region and BIOS (`Console`, `BIOS`), the CD-ROM's region check and speed,
  /// and the CPU's clock.
  console,

  /// Everything else: how SwanStation runs the CPU and reads the disc, its compatibility settings
  /// and hacks, and any option a later SwanStation adds.
  advanced,
}

/// The section a SwanStation option key is shown in, or null for an option players have no use
/// for in the launcher (they are not shown, and a value kept for one is not sent):
///
/// - the on-screen messages (`Display_ShowOSDMessages`): the host draws no messages;
/// - the four display offsets (`Display_ActiveStartOffset`, `Display_ActiveEndOffset`,
///   `Display_LineStartOffset`, `Display_LineEndOffset`), sixty-one values of SwanStation's own
///   calibration each;
/// - texture replacements (`TextureReplacements_*`), which read a texture folder the host does
///   not give SwanStation;
/// - the development console's 8 MB of RAM (`Console_Enable8MBRAM`), which no game sold uses;
/// - the CPU recompiler's debugging switches (`CPU_RecompilerICache`,
///   `CPU_RecompilerBlockLinking`, `CPU_FastmemMode`);
/// - the light gun crosshair (`Controller_ShowCrosshair`): the host plugs in only DualShocks;
/// - LRPS2's VR (every `pcsx2_vr_...` key: `pcsx2_vr_mode` and its `pcsx2_vr_depth`), whose stereo
///   mode draws a picture for each eye side by side for a VR headset or a 3D display. AnyPS5 has
///   no VR, and SwanStation no stereo option.
///
/// Keys are `swanstation_<Group>_<Name>`; a key of another form is [RetroOptionSection.advanced], as
/// every other LRPS2 option of a PS2 game is (`pcsx2_...`), its BIOS (`pcsx2_bios`) included, but
/// its resolution scale, which is [RetroOptionSection.graphics].
RetroOptionSection? retroOptionSection(String key) {
  const prefix = 'swanstation_';
  if (key == retroResolutionKeyPs2) return RetroOptionSection.graphics;
  if (key.startsWith(_ps2Vr)) return null;
  if (!key.startsWith(prefix)) return RetroOptionSection.advanced;
  final name = key.substring(prefix.length);
  if (_hidden.contains(name) || name.startsWith('TextureReplacements_')) return null;
  if (_console.contains(name)) return RetroOptionSection.console;
  if (name == 'CDROM_MuteCDAudio') return RetroOptionSection.audio;
  final separator = name.indexOf('_');
  final group = separator < 0 ? name : name.substring(0, separator);
  if (group == 'GPU' || group == 'Display') return RetroOptionSection.graphics;
  if (group == 'Audio') return RetroOptionSection.audio;
  if (group.startsWith('Controller')) return RetroOptionSection.controller;
  if (group == 'Console' || group == 'BIOS') return RetroOptionSection.console;
  return RetroOptionSection.advanced;
}

/// Whether the option at [key] is shown somewhere, so a value kept for it is sent to the host.
bool retroOptionShown(String key) => retroOptionSection(key) != null;

/// Whether a value kept for [key] goes to a game's `start`: one the in-game menu shows. A graphics
/// option is kept back, since the launcher has no page yet where the player could see or change
/// it, but for the console's internal resolution, which the menu's first page offers
/// ([retroResolutionKey]). The two cores' options share one list of values the player chose, so
/// LRPS2's (`pcsx2_...`) go to a [ps2] game only and every other to a PS1 game only. A PS2
/// internal resolution still goes only to a host that limits it (`RetroHostGame.start`).
bool retroOptionSent(String key, {bool ps2 = false}) {
  if (key.startsWith('pcsx2_') != ps2) return false;
  if (key == retroResolutionKey(ps2: ps2)) return true;
  final section = retroOptionSection(key);
  return section != null && section != RetroOptionSection.graphics;
}

/// An option's title without SwanStation's own " (Restart)": the menu says that under every option
/// that takes effect only when the game starts again, not only under those SwanStation named so.
String retroOptionTitle(String title) {
  const mark = '(Restart)';
  final trimmed = title.trimRight();
  if (!trimmed.endsWith(mark)) return title;
  final rest = trimmed.substring(0, trimmed.length - mark.length).trimRight();
  return rest.isEmpty ? title : rest;
}

const _hidden = {
  'Display_ShowOSDMessages',
  'Display_ActiveStartOffset',
  'Display_ActiveEndOffset',
  'Display_LineStartOffset',
  'Display_LineEndOffset',
  'Console_Enable8MBRAM',
  'CPU_RecompilerICache',
  'CPU_RecompilerBlockLinking',
  'CPU_FastmemMode',
  'Controller_ShowCrosshair',
};

const _ps2Vr = 'pcsx2_vr_';

const _console = {'CDROM_RegionCheck', 'CDROM_ReadSpeedup', 'CDROM_SeekSpeedup', 'CPU_Overclock'};
