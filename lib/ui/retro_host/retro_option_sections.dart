import '../../core/retro_host/retro_graphics.dart';
import '../../core/retro_host/retro_resolution.dart';

/// Where a SwanStation option is shown. The host lists every option SwanStation lets the player
/// change now (about fifty for a PS1 game, in SwanStation's order); the launcher groups them.
enum RetroOptionSection {
  /// The picture: SwanStation's `GPU` and `Display` options, and LRPS2's resolution scale,
  /// anisotropic filtering and widescreen patch. The menu's Graphics page does not list them one by
  /// one: it offers the internal resolution ([retroResolutionKey]) and a few settings that set them
  /// ([retroGraphicsSettings]). The others are kept at the core's defaults.
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
/// - SwanStation's MSAA (`GPU_MSAA`), which does not work on the host: its shader needs OpenGL 4.0
///   and the host makes the 3.3 context SwanStation asks for, so the core falls back to software
///   and the game never starts;
/// - SwanStation's accuracy and compatibility settings: the PGXP options but PGXP itself, the
///   downsampling, the read-back renderer, the NTSC timings, interlacing, the display crop, 4:3 for
///   24-bit display, and `Main_ApplyGameSettings`, which stays on so SwanStation's per-game list
///   still turns enhancements off for the games they break;
/// - LRPS2's VR (every `pcsx2_vr_...` key: `pcsx2_vr_mode` and its `pcsx2_vr_depth`), whose stereo
///   mode draws a picture for each eye side by side for a VR headset or a 3D display. AnyPS5 has
///   no VR, and SwanStation no stereo option;
/// - LRPS2's paraLLEl-GS options (every `pcsx2_pgs_...` key) and its software renderer's threads,
///   for renderers the host never uses: it draws LRPS2 with GSdx on OpenGL and makes no Vulkan
///   context;
/// - LRPS2's other video options, its EE and VU options, its game patch hints but the widescreen
///   patch, and its manual hardware fixes ("HW Hacks", which LRPS2 itself calls not recommended),
///   as LRPS2 c0d39a5's `libretro/libretro_core_options.h` lists them. They stay at LRPS2's
///   defaults, which defer to its game database.
///
/// Keys are `swanstation_<Group>_<Name>`; a key of another form is [RetroOptionSection.advanced], as
/// every other LRPS2 option of a PS2 game is (`pcsx2_...`: its BIOS, fast boot, disc speed and the
/// controllers), but those a Graphics row sets, which are [RetroOptionSection.graphics].
RetroOptionSection? retroOptionSection(String key) {
  const prefix = 'swanstation_';
  if (key == retroResolutionKeyPs2 || retroGraphicsKeys.contains(key)) return RetroOptionSection.graphics;
  if (key.startsWith(_ps2Vr) || key.startsWith(_ps2Parallel) || _ps2Hidden.contains(key)) return null;
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
/// option is kept back, since the player cannot see or change it, but for the console's internal
/// resolution and the options the Graphics rows set ([retroGraphicsKeys]). A value kept for an
/// option that is not shown is not sent either, also one an older launcher kept while it showed
/// the option (LRPS2's stereo, a hardware fix). The two cores' options share one list of values
/// the player chose, so LRPS2's (`pcsx2_...`) go to a [ps2] game only and every other to a PS1
/// game only. A PS2 internal resolution still goes only to a host that limits it
/// (`RetroHostGame.start`).
bool retroOptionSent(String key, {bool ps2 = false}) {
  if (key.startsWith('pcsx2_') != ps2) return false;
  if (key == retroResolutionKey(ps2: ps2) || retroGraphicsKeys.contains(key)) return true;
  final section = retroOptionSection(key);
  return section != null && section != RetroOptionSection.graphics;
}

/// The core options a game of [ps2]'s console starts with: the values the player kept that are
/// sent ([retroOptionSent]), over the Graphics defaults for the settings the player did not choose
/// ([retroGraphicsDefaults]).
Map<String, String> retroStartOptions(Map<String, String> kept, {required bool ps2}) {
  final sent = {
    for (final MapEntry(:key, :value) in kept.entries)
      if (retroOptionSent(key, ps2: ps2)) key: value,
  };
  return {...retroGraphicsDefaults(sent, ps2: ps2), ...sent};
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
  'GPU_MSAA',
  'GPU_PGXPColorCorrection',
  'GPU_PGXPDepthBuffer',
  'GPU_PGXPPreserveProjFP',
  'GPU_PGXPVertexCache',
  'GPU_PGXPTolerance',
  'GPU_PGXPDepthClearThreshold',
  'GPU_PGXPCPU',
  'GPU_DownsampleMode',
  'GPU_UseSoftwareRendererForReadbacks',
  'GPU_ForceNTSCTimings',
  'GPU_DisableInterlacing',
  'Display_CropMode',
  'Display_Force4_3For24Bit',
  'Main_ApplyGameSettings',
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

const _ps2Parallel = 'pcsx2_pgs_';

const _ps2Hidden = {
  'pcsx2_renderer',
  'pcsx2_native_scaling',
  'pcsx2_deinterlace_mode',
  'pcsx2_nointerlacing_hint',
  'pcsx2_disable_interlace_offset',
  'pcsx2_hw_download_mode',
  'pcsx2_texture_filtering',
  'pcsx2_trilinear_filtering',
  'pcsx2_dithering',
  'pcsx2_blending_accuracy',
  'pcsx2_pcrtc_antiblur',
  'pcsx2_pcrtc_screen_offsets',
  'pcsx2_sw_renderer_threads',
  'pcsx2_disable_shader_cache',
  'pcsx2_vu_accurate_addsub',
  'pcsx2_vu_exact_mul',
  'pcsx2_vu_exact_div',
  'pcsx2_vu0_softfloat',
  'pcsx2_vu1_softfloat',
  'pcsx2_mtvu',
  'pcsx2_instant_vu1',
  'pcsx2_ee_accurate_fpu',
  'pcsx2_fpu_softfloat',
  'pcsx2_ee_cycle_rate',
  'pcsx2_ee_cpu',
  'pcsx2_ee_cycle_skip',
  'pcsx2_fastmem',
  'pcsx2_game_enhancements_hint',
  'pcsx2_uncapped_framerate_hint',
  'pcsx2_enable_hw_hacks',
  'pcsx2_cpu_sprite_size',
  'pcsx2_cpu_sprite_level',
  'pcsx2_software_clut_render',
  'pcsx2_texture_inside_rt',
  'pcsx2_disable_depth_conversion',
  'pcsx2_framebuffer_conversion',
  'pcsx2_disable_partial_invalidation',
  'pcsx2_gpu_palette_conversion',
  'pcsx2_preload_frame_data',
  'pcsx2_half_pixel_offset',
  'pcsx2_round_sprite',
  'pcsx2_align_sprite',
  'pcsx2_merge_sprite',
  'pcsx2_unscaled_palette_draw',
  'pcsx2_force_sprite_position',
};

const _console = {'CDROM_RegionCheck', 'CDROM_ReadSpeedup', 'CDROM_SeekSpeedup', 'CPU_Overclock'};
