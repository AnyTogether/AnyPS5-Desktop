import 'app_model.dart';
import 'strings.dart';

abstract final class Ps3SettingsModel {
  static final _options = {
    for (final section in _sections.values)
      for (final option in section.options) 'rpcs3_${option.id}': option,
  };

  static String? optionTitle(String key) => switch (_options[key]) {
    final option? => T.text(option.title),
    null => null,
  };

  static String? optionLabel(String key, String value) => switch (_options[key]?.choices[value]) {
    final label? => T.text(label),
    null => null,
  };

  static List<PanelCategory> categories({
    required Map<String, String> saved,
    required void Function(String key, String? value) save,
    required List<PanelRow> setup,
  }) => [
    PanelCategory(id: 'retro-ps3', title: 'RPCS3', rows: setup),
    for (final section in _sections.entries)
      PanelCategory(
        id: 'retro-ps3-${section.key}',
        title: T.text(section.value.title),
        rows: [
          if (section.key == 'graphics')
            PanelRow(
              id: 'rpcs3_renderer',
              title: T.text('retroPs3Renderer'),
              kind: const InfoRow('Vulkan'),
              detail: T.text('retroPs3RendererDetail'),
            ),
          if (section.key == 'audio')
            PanelRow(
              id: 'rpcs3_audio_format',
              title: T.text('retroPs3AudioFormat'),
              kind: InfoRow(T.text('retroPs3Stereo')),
            ),
          for (final option in section.value.options) _row(option, saved, save),
        ],
      ),
  ];

  static PanelRow _row(_Ps3Option option, Map<String, String> saved, void Function(String key, String? value) save) {
    final key = 'rpcs3_${option.id}';
    final values = option.choices.keys.toList();
    final selected = values.indexOf(saved[key] ?? option.defaultValue);
    final choices = option.choices.map((value, label) => MapEntry(value, T.text(label)));
    return PanelRow(
      id: key,
      title: T.text(option.title),
      detail: [if (option.detail case final detail?) T.text(detail), T.text('retroPs3GameLaunchDetail')].join(' '),
      kind: ChoiceRow(choices.values.toList(), selected < 0 ? values.indexOf(option.defaultValue) : selected, (index) {
        final value = values[index];
        save(key, value == option.defaultValue ? null : value);
      }),
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
    title: 'retroPs3Graphics',
    options: [
      _Ps3Option('resolution_scale', 'retroPs3ResolutionScale', '100', {
        '25': '25%',
        '50': '50%',
        '66': '66%',
        '75': '75%',
        '100': 'retroPs3100Native',
        '150': '150%',
        '200': '200%',
      }, detail: 'retroPs3ResolutionScaleDetail'),
      _Ps3Option('default_resolution', 'retroPs3DefaultResolution', '720p', {
        '720p': 'retroPs3720pDefault',
        '1080p': '1080p',
        '480p': '480p',
        '576p': '576p',
      }, detail: 'retroPs3DefaultResolutionDetail'),
      _Ps3Option('anisotropic_filter', 'retroPs3AnisotropicFiltering', 'auto', {
        'auto': 'retroPs3Auto',
        '2': '2x',
        '4': '4x',
        '8': '8x',
        '16': '16x',
      }),
      _Ps3Option('msaa', 'retroPs3AntiAliasing', 'auto', {'auto': 'retroPs3Auto', 'disabled': 'retroPs3Disabled'}),
      _Ps3Option('frame_limit', 'retroPs3FrameLimit', 'auto', {
        'auto': 'retroPs3Auto',
        'ps3': 'retroPs3PS3Native',
        'off': 'off',
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
    title: 'retroPs3Rendering',
    options: [
      _Ps3Option('aspect_ratio', 'retroPs3AspectRatio', '16:9', {'16:9': 'retroPs3169Default', '4:3': '4:3'}),
      _Ps3Option('zcull_accuracy', 'retroPs3ZCULLAccuracy', 'precise', {
        'precise': 'retroPs3PreciseDefault',
        'approximate': 'retroPs3Approximate',
        'relaxed': 'retroPs3RelaxedFastest',
      }),
      _Ps3Option('scale_threshold', 'retroPs3ResolutionScaleThreshold', '16', {
        '1': '1x1',
        '16': 'retroPs316x16Default',
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
      _Ps3Option('write_color_buffers', 'retroPs3WriteColorBuffers', 'disabled', {
        'disabled': 'retroPs3Disabled',
        'enabled': 'retroPs3Enabled',
      }),
      _Ps3Option('strict_rendering', 'retroPs3StrictRenderingMode', 'disabled', {
        'disabled': 'retroPs3Disabled',
        'enabled': 'retroPs3Enabled',
      }, detail: 'retroPs3StrictRenderingDetail'),
      _Ps3Option('stretch_to_display', 'retroPs3StretchToDisplayArea', 'disabled', {
        'disabled': 'retroPs3Disabled',
        'enabled': '16:9',
        '16:10': '16:10',
        '21:9': '21:9',
        '32:9': '32:9',
        '4:3': '4:3',
        '5:4': '5:4',
      }),
      _Ps3Option('host_gpu_labels', 'retroPs3AllowHostGPULabels', 'disabled', {
        'disabled': 'retroPs3Disabled',
        'enabled': 'retroPs3Enabled',
      }),
      _Ps3Option('disable_blit_upscaling', 'retroPs3DisableBlitEngineUpscaling', 'disabled', {
        'disabled': 'retroPs3Disabled',
        'enabled': 'retroPs3Enabled',
      }),
      _Ps3Option('emulate_depth_compare', 'retroPs3EmulateSpecialDepthComparison', 'disabled', {
        'disabled': 'retroPs3Disabled',
        'enabled': 'retroPs3Enabled',
      }),
      _Ps3Option('force_hw_msaa_resolve', 'retroPs3ForceHardwareMSAAResolve', 'disabled', {
        'disabled': 'retroPs3Disabled',
        'enabled': 'retroPs3Enabled',
      }),
      _Ps3Option('handle_tiled_memory', 'retroPs3HandleRSXMemoryTiling', 'disabled', {
        'disabled': 'retroPs3Disabled',
        'enabled': 'retroPs3Enabled',
      }),
      _Ps3Option('read_depth_buffers', 'retroPs3ReadDepthBuffers', 'disabled', {
        'disabled': 'retroPs3Disabled',
        'enabled': 'retroPs3Enabled',
      }),
      _Ps3Option('read_color_buffers', 'retroPs3ReadColorBuffers', 'disabled', {
        'disabled': 'retroPs3Disabled',
        'enabled': 'retroPs3Enabled',
      }),
      _Ps3Option('write_depth_buffers', 'retroPs3WriteDepthBuffers', 'disabled', {
        'disabled': 'retroPs3Disabled',
        'enabled': 'retroPs3Enabled',
      }),
    ],
  ),
  'graphics-textures': (
    title: 'retroPs3TexturesShaders',
    options: [
      _Ps3Option('shader_mode', 'retroPs3ShaderMode', 'async', {
        'async': 'retroPs3AsyncRecommended',
        'async_interpreter': 'retroPs3AsyncWithShaderInterpreter',
        'async_recompiler': 'retroPs3AsyncWithRecompiler',
        'interpreter': 'retroPs3ShaderInterpreterOnly',
        'sync': 'retroPs3Synchronous',
      }),
      _Ps3Option('shader_quality', 'retroPs3ShaderQuality', 'high', {
        'low': 'retroPs3Low',
        'high': 'retroPs3High',
        'ultra': 'retroPs3Ultra',
      }),
      _Ps3Option('async_texture_streaming', 'retroPs3AsynchronousTextureStreaming', 'disabled', {
        'disabled': 'retroPs3Disabled',
        'enabled': 'retroPs3Enabled',
      }),
      _Ps3Option('disable_vertex_cache', 'retroPs3DisableVertexCache', 'disabled', {
        'disabled': 'retroPs3Disabled',
        'enabled': 'retroPs3Enabled',
      }),
      _Ps3Option('use_rebar', 'retroPs3UseReBARMemoryForGPUUploads', 'enabled', {
        'enabled': 'retroPs3Enabled',
        'disabled': 'retroPs3Disabled',
      }),
    ],
  ),
  'graphics-timing': (
    title: 'retroPs3FrameTiming',
    options: [
      _Ps3Option('multithreaded_rsx', 'retroPs3MultithreadedRSX', 'disabled', {
        'disabled': 'retroPs3Disabled',
        'enabled': 'retroPs3Enabled',
      }),
      _Ps3Option('rsx_fifo_accuracy', 'retroPs3RSXFIFOAccuracy', 'atomic', {
        'fast': 'retroPs3Fast',
        'atomic': 'retroPs3Atomic',
        'atomic_ordered': 'retroPs3OrderedAndAtomic',
        'as_ps3': 'PS3',
      }),
      _Ps3Option('driver_wakeup_delay', 'retroPs3DriverWakeUpDelay', '0', {
        '0': 'retroPs30Default',
        '20': '20',
        '50': '50',
        '100': '100',
        '200': '200',
        '400': '400',
        '800': '800',
      }),
      _Ps3Option('vblank_rate', 'retroPs3VBlankFrequency', '60', {
        '50': '50 Hz (PAL)',
        '60': '60 Hz (NTSC)',
        '120': '120 Hz',
        '144': '144 Hz',
        '240': '240 Hz',
        'list': 'retroPs3FromList',
      }),
    ],
  ),
  'cpu': (
    title: 'retroPs3CPU',
    options: [
      _Ps3Option('ppu_decoder', 'retroPs3PPUDecoder', 'llvm', {
        'llvm': 'retroPs3RecompilerLLVM',
        'interpreter': 'retroPs3InterpreterStatic',
      }),
      _Ps3Option('spu_decoder', 'retroPs3SPUDecoder', 'llvm', {
        'llvm': 'retroPs3RecompilerLLVM',
        'asmjit': 'retroPs3RecompilerASMJIT',
        'dynamic': 'retroPs3InterpreterDynamic',
        'interpreter': 'retroPs3InterpreterStatic',
      }),
      _Ps3Option('llvm_precompilation', 'retroPs3PPUSPULLVMPrecompilation', 'enabled', {
        'enabled': 'retroPs3Enabled',
        'disabled': 'retroPs3Disabled',
      }),
    ],
  ),
  'scheduling': (
    title: 'retroPs3Scheduling',
    options: [
      _Ps3Option('preferred_spu_threads', 'retroPs3PreferredSPUThreads', '0', {
        '0': 'retroPs3Auto',
        '1': '1',
        '2': '2',
        '3': '3',
        '4': '4',
        '5': '5',
        '6': '6',
      }, detail: 'retroPs3PreferredSpuThreadsDetail'),
      _Ps3Option('llvm_threads', 'retroPs3PPUSPULLVMCompilerThreads', '0', {
        '0': 'retroPs3Auto',
        '1': '1',
        '2': '2',
        '3': '3',
        '4': '4',
        '6': '6',
        '8': '8',
      }),
      _Ps3Option('shader_compiler_threads', 'retroPs3ShaderCompilerThreads', 'auto', {
        'auto': 'retroPs3Auto',
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
    title: 'retroPs3IOCache',
    options: [
      _Ps3Option('emulate_hdd_speed', 'retroPs3EmulateHDDReadSpeed', 'disabled', {
        'disabled': 'retroPs3Disabled',
        'enabled': 'retroPs3Enabled',
      }, detail: 'retroPs3HddReadSpeedDetail'),
      _Ps3Option('emulate_bdvd_speed', 'retroPs3EmulateBDROMReadSpeed', 'disabled', {
        'disabled': 'retroPs3Disabled',
        'enabled': 'retroPs3Enabled',
      }, detail: 'retroPs3BdReadSpeedDetail'),
      _Ps3Option('disk_cache_size', 'retroPs3DiskCacheSize', '1gb', {
        'unlimited': 'retroPs3Unlimited',
        '1gb': '1 GB',
        '5gb': '5 GB',
      }, detail: 'retroPs3DiskCacheDetail'),
      _Ps3Option('spu_cache', 'retroPs3SPUCache', 'enabled', {
        'enabled': 'retroPs3Enabled',
        'disabled': 'retroPs3Disabled',
      }),
    ],
  ),
  'audio': (
    title: 'retroPs3Audio',
    options: [
      _Ps3Option('master_volume', 'retroPs3MasterVolume', '100', {
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
    title: 'retroPs3System',
    options: [
      _Ps3Option('language', 'retroPs3SystemLanguage', 'english', {
        'english': 'retroPs3English',
        'japanese': 'retroPs3Japanese',
        'french': 'retroPs3French',
        'spanish': 'retroPs3Spanish',
        'german': 'retroPs3German',
        'italian': 'retroPs3Italian',
        'dutch': 'retroPs3Dutch',
        'portuguese': 'retroPs3Portuguese',
        'russian': 'retroPs3Russian',
        'korean': 'retroPs3Korean',
        'chinese_trad': 'retroPs3ChineseTraditional',
        'chinese_simp': 'retroPs3ChineseSimplified',
      }),
      _Ps3Option('license_area', 'retroPs3ConsoleRegion', 'usa', {
        'usa': 'retroPs3SCEAAmericas',
        'eu': 'retroPs3SCEEEuropeOceania',
        'jp': 'retroPs3SCEJJapan',
        'hk': 'retroPs3SCEHHongKongSoutheastAsia',
        'kr': 'retroPs3SCEKKorea',
        'cn': 'retroPs3SCHChina',
      }),
      _Ps3Option('enter_button', 'retroPs3EnterButtonAssignment', 'cross', {
        'cross': 'retroPs3CrossWestern',
        'circle': 'retroPs3CircleJapanese',
      }),
    ],
  ),
};
