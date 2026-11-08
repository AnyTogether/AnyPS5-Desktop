import 'app_model.dart';

abstract final class Ps3SettingsModel {
  static final graphicsKeys = Set<String>.unmodifiable({
    for (final entry in _sections.entries)
      if (entry.key.startsWith('graphics'))
        for (final option in entry.value.options) 'rpcs3_${option.id}',
  });

  static List<PanelCategory> categories({
    required Map<String, String> defaults,
    required Map<String, String>? overrides,
    required void Function(String key, String? value) save,
    required List<PanelRow> setup,
  }) => [
    PanelCategory(id: 'retro-ps3', title: 'RPCS3', rows: setup),
    for (final section in _sections.entries)
      PanelCategory(
        id: 'retro-ps3-${section.key}',
        title: section.value.title,
        rows: [
          if (section.key == 'graphics')
            const PanelRow(
              id: 'rpcs3_renderer',
              title: 'Renderer',
              kind: InfoRow('Vulkan'),
              detail: 'The embedded PS3 game view uses Vulkan.',
            ),
          if (section.key == 'audio')
            const PanelRow(id: 'rpcs3_audio_format', title: 'Audio Format', kind: InfoRow('Stereo')),
          for (final option in section.value.options) _row(option, defaults, overrides, save),
        ],
      ),
  ];

  static PanelRow _row(
    _Ps3Option option,
    Map<String, String> defaults,
    Map<String, String>? overrides,
    void Function(String key, String? value) save,
  ) {
    final key = 'rpcs3_${option.id}';
    final values = option.choices.keys.toList();
    final savedDefault = defaults[key];
    final shared = option.choices.containsKey(savedDefault) ? savedDefault! : option.defaultValue;
    final override = overrides?[key];
    final local = overrides != null;
    final selected = local ? values.indexOf(override ?? '') + 1 : values.indexOf(shared);
    return PanelRow(
      id: key,
      title: option.title,
      detail: [
        ?option.detail,
        if (local) 'Applies to this game on next launch.' else 'Shared PS3 default. Applies on next launch.',
      ].join(' '),
      kind: ChoiceRow(
        [if (local) 'Use shared default (${option.choices[shared]})', ...option.choices.values],
        selected,
        (index) {
          if (local && index == 0) {
            save(key, null);
            return;
          }
          final value = values[index - (local ? 1 : 0)];
          save(key, !local && value == option.defaultValue ? null : value);
        },
      ),
    );
  }
}

class _Ps3Option {
  const _Ps3Option(this.id, this.title, this.defaultValue, this.choices, {this.detail});

  final String id;
  final String title;
  final String defaultValue;
  final Map<String, String> choices;
  final String? detail;
}

// Options and defaults from RPCS3 Libretro revision 74b3fa37.
const _sections = <String, ({String title, List<_Ps3Option> options})>{
  'graphics': (
    title: 'Graphics',
    options: [
      _Ps3Option('resolution_scale', 'Resolution Scale', '100', {
        '25': '25%',
        '50': '50%',
        '66': '66%',
        '75': '75%',
        '100': '100% (Native)',
        '150': '150%',
        '200': '200%',
      }, detail: 'Controls internal render resolution.'),
      _Ps3Option('default_resolution', 'Default Resolution', '720p', {
        '720p': '720p (Default)',
        '1080p': '1080p',
        '480p': '480p',
        '576p': '576p',
      }, detail: 'Changes the resolution reported to the game. Use Resolution Scale for upscaling.'),
      _Ps3Option('anisotropic_filter', 'Anisotropic Filtering', 'auto', {
        'auto': 'Auto',
        '2': '2x',
        '4': '4x',
        '8': '8x',
        '16': '16x',
      }),
      _Ps3Option('msaa', 'Anti-Aliasing', 'auto', {'auto': 'Auto', 'disabled': 'Disabled'}),
      _Ps3Option('frame_limit', 'Frame Limit', 'auto', {
        'auto': 'Auto',
        'ps3': 'PS3 Native',
        'off': 'Off',
        '30': '30 FPS',
        '50': '50 FPS',
        '60': '60 FPS',
        '120': '120 FPS',
        '144': '144 FPS',
        '240': '240 FPS',
      }),
    ],
  ),
  'graphics-rendering': (
    title: 'Rendering',
    options: [
      _Ps3Option('aspect_ratio', 'Aspect Ratio', '16:9', {'16:9': '16:9 (default)', '4:3': '4:3'}),
      _Ps3Option('zcull_accuracy', 'ZCULL Accuracy', 'precise', {
        'precise': 'Precise (Default)',
        'approximate': 'Approximate',
        'relaxed': 'Relaxed (Fastest)',
      }),
      _Ps3Option('scale_threshold', 'Resolution Scale Threshold', '16', {
        '1': '1x1',
        '16': '16x16 (Default)',
        '64': '64x64',
        '128': '128x128',
        '160': '160x160',
        '256': '256x256',
        '320': '320x320',
        '512': '512x512',
        '592': '592x592',
        '640': '640x640',
        '1024': '1024x1024',
      }),
      _Ps3Option('write_color_buffers', 'Write Color Buffers', 'disabled', {
        'disabled': 'Disabled',
        'enabled': 'Enabled',
      }),
      _Ps3Option('strict_rendering', 'Strict Rendering Mode', 'disabled', {
        'disabled': 'Disabled',
        'enabled': 'Enabled',
      }, detail: 'Some games require this for correct rendering.'),
      _Ps3Option('stretch_to_display', 'Stretch to Display Area', 'disabled', {
        'disabled': 'Disabled',
        'enabled': '16:9',
        '16:10': '16:10',
        '21:9': '21:9',
        '32:9': '32:9',
        '4:3': '4:3',
        '5:4': '5:4',
      }),
      _Ps3Option('host_gpu_labels', 'Allow Host GPU Labels', 'disabled', {
        'disabled': 'Disabled',
        'enabled': 'Enabled',
      }),
      _Ps3Option('disable_blit_upscaling', 'Disable Blit Engine Upscaling', 'disabled', {
        'disabled': 'Disabled',
        'enabled': 'Enabled',
      }),
      _Ps3Option('emulate_depth_compare', 'Emulate Special Depth Comparison', 'disabled', {
        'disabled': 'Disabled',
        'enabled': 'Enabled',
      }),
      _Ps3Option('force_hw_msaa_resolve', 'Force Hardware MSAA Resolve', 'disabled', {
        'disabled': 'Disabled',
        'enabled': 'Enabled',
      }),
      _Ps3Option('handle_tiled_memory', 'Handle RSX Memory Tiling', 'disabled', {
        'disabled': 'Disabled',
        'enabled': 'Enabled',
      }),
      _Ps3Option('read_depth_buffers', 'Read Depth Buffers', 'disabled', {
        'disabled': 'Disabled',
        'enabled': 'Enabled',
      }),
      _Ps3Option('read_color_buffers', 'Read Color Buffers', 'disabled', {
        'disabled': 'Disabled',
        'enabled': 'Enabled',
      }),
      _Ps3Option('write_depth_buffers', 'Write Depth Buffers', 'disabled', {
        'disabled': 'Disabled',
        'enabled': 'Enabled',
      }),
    ],
  ),
  'graphics-textures': (
    title: 'Textures & Shaders',
    options: [
      _Ps3Option('shader_mode', 'Shader Mode', 'async', {
        'async': 'Async (Recommended)',
        'async_interpreter': 'Async with Shader Interpreter (no stalls)',
        'async_recompiler': 'Async with Recompiler',
        'interpreter': 'Shader Interpreter only',
        'sync': 'Synchronous',
      }),
      _Ps3Option('shader_quality', 'Shader Quality', 'high', {'low': 'Low', 'high': 'High', 'ultra': 'Ultra'}),
      _Ps3Option('async_texture_streaming', 'Asynchronous Texture Streaming', 'disabled', {
        'disabled': 'Disabled',
        'enabled': 'Enabled',
      }),
      _Ps3Option('disable_vertex_cache', 'Disable Vertex Cache', 'disabled', {
        'disabled': 'Disabled',
        'enabled': 'Enabled',
      }),
      _Ps3Option('use_rebar', 'Use Re-BAR Memory for GPU Uploads', 'enabled', {
        'enabled': 'Enabled',
        'disabled': 'Disabled',
      }),
    ],
  ),
  'graphics-timing': (
    title: 'Frame Timing',
    options: [
      _Ps3Option('multithreaded_rsx', 'Multithreaded RSX', 'disabled', {'disabled': 'Disabled', 'enabled': 'Enabled'}),
      _Ps3Option('rsx_fifo_accuracy', 'RSX FIFO Accuracy', 'atomic', {
        'fast': 'Fast',
        'atomic': 'Atomic',
        'atomic_ordered': 'Ordered & Atomic',
        'as_ps3': 'PS3',
      }),
      _Ps3Option('driver_wakeup_delay', 'Driver Wake-Up Delay', '0', {
        '0': '0 (Default)',
        '20': '20',
        '50': '50',
        '100': '100',
        '200': '200',
        '400': '400',
        '800': '800',
      }),
      _Ps3Option('vblank_rate', 'VBlank Frequency', '60', {
        '50': '50 Hz (PAL)',
        '60': '60 Hz (NTSC)',
        '120': '120 Hz',
        '144': '144 Hz',
        '240': '240 Hz',
        'list': 'From List',
      }),
    ],
  ),
  'cpu': (
    title: 'CPU',
    options: [
      _Ps3Option('ppu_decoder', 'PPU Decoder', 'llvm', {
        'llvm': 'Recompiler (LLVM)',
        'interpreter': 'Interpreter (static)',
      }),
      _Ps3Option('spu_decoder', 'SPU Decoder', 'llvm', {
        'llvm': 'Recompiler (LLVM)',
        'asmjit': 'Recompiler (ASMJIT)',
        'dynamic': 'Interpreter (dynamic)',
        'interpreter': 'Interpreter (static)',
      }),
      _Ps3Option('llvm_precompilation', 'PPU/SPU LLVM Precompilation', 'enabled', {
        'enabled': 'Enabled',
        'disabled': 'Disabled',
      }),
    ],
  ),
  'scheduling': (
    title: 'Scheduling',
    options: [
      _Ps3Option('preferred_spu_threads', 'Preferred SPU Threads', '0', {
        '0': 'Auto',
        '1': '1',
        '2': '2',
        '3': '3',
        '4': '4',
        '5': '5',
        '6': '6',
      }, detail: 'Auto lets RPCS3 choose.'),
      _Ps3Option('llvm_threads', 'PPU/SPU LLVM Compiler Threads', '0', {
        '0': 'Auto',
        '1': '1',
        '2': '2',
        '3': '3',
        '4': '4',
        '6': '6',
        '8': '8',
      }),
      _Ps3Option('shader_compiler_threads', 'Shader Compiler Threads', 'auto', {
        'auto': 'Auto',
        '1': '1',
        '2': '2',
        '3': '3',
        '4': '4',
        '6': '6',
        '8': '8',
      }),
    ],
  ),
  'io': (
    title: 'I/O & Cache',
    options: [
      _Ps3Option('emulate_hdd_speed', 'Emulate HDD Read Speed', 'disabled', {
        'disabled': 'Disabled',
        'enabled': 'Enabled',
      }, detail: 'Use for games that need original hard-drive timing.'),
      _Ps3Option('emulate_bdvd_speed', 'Emulate BD-ROM Read Speed', 'disabled', {
        'disabled': 'Disabled',
        'enabled': 'Enabled',
      }, detail: 'Use for games that need original disc-drive timing.'),
      _Ps3Option('disk_cache_size', 'Disk Cache Size', '1gb', {
        'unlimited': 'Unlimited',
        '1gb': '1 GB',
        '5gb': '5 GB',
      }, detail: 'A lower limit can remove old game caches. Save files are separate.'),
      _Ps3Option('spu_cache', 'SPU Cache', 'enabled', {'enabled': 'Enabled', 'disabled': 'Disabled'}),
    ],
  ),
  'audio': (
    title: 'Audio',
    options: [
      _Ps3Option('master_volume', 'Master Volume', '100', {
        '0': '0%',
        '10': '10%',
        '20': '20%',
        '30': '30%',
        '40': '40%',
        '50': '50%',
        '60': '60%',
        '70': '70%',
        '80': '80%',
        '90': '90%',
        '100': '100%',
      }),
    ],
  ),
  'system': (
    title: 'System',
    options: [
      _Ps3Option('language', 'System Language', 'english', {
        'english': 'English',
        'japanese': 'Japanese',
        'french': 'French',
        'spanish': 'Spanish',
        'german': 'German',
        'italian': 'Italian',
        'dutch': 'Dutch',
        'portuguese': 'Portuguese',
        'russian': 'Russian',
        'korean': 'Korean',
        'chinese_trad': 'Chinese (Traditional)',
        'chinese_simp': 'Chinese (Simplified)',
      }),
      _Ps3Option('license_area', 'Console Region', 'usa', {
        'usa': 'SCEA (Americas)',
        'eu': 'SCEE (Europe, Oceania)',
        'jp': 'SCEJ (Japan)',
        'hk': 'SCEH (Hong Kong, Southeast Asia)',
        'kr': 'SCEK (Korea)',
        'cn': 'SCH (China)',
      }),
      _Ps3Option('enter_button', 'Enter Button Assignment', 'cross', {
        'cross': 'Cross (Western)',
        'circle': 'Circle (Japanese)',
      }),
    ],
  ),
};
