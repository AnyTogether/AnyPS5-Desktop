import '../core/game_library.dart';
import 'retro_game_tuning.dart';

typedef RestartTuningChoice = ({String key, String value, String label, String group});

List<RestartTuningChoice> restartTuningChoices(RetroPlatform platform, Map<String, EmbeddedOption> options) {
  final candidates = switch (platform) {
    RetroPlatform.ps1 => const {
      'swanstation_CPU_ExecutionMode': ('CPU', ['Recompiler', 'CachedInterpreter']),
      'swanstation_GPU_Renderer': ('Renderer', ['D3D11', 'Software']),
      'swanstation_CDROM_ReadThread': ('I/O', ['true', 'false']),
      'swanstation_CDROM_ReadaheadSectors': ('I/O', ['0', '8', '16']),
    },
    RetroPlatform.ps2 => const {
      'pcsx2_mtvu': ('CPU', ['disabled', 'enabled']),
      'pcsx2_renderer': ('Renderer', ['D3D11', 'Software (SW)']),
      'pcsx2_fastcdvd': ('I/O', ['disabled', 'enabled']),
    },
    RetroPlatform.ps3 => const {
      'rpcs3_preferred_spu_threads': ('CPU', ['0', '2']),
      'rpcs3_spu_decoder': ('CPU', ['llvm', 'asmjit']),
      'rpcs3_shader_mode': ('Shaders', ['async', 'async_interpreter']),
      'rpcs3_emulate_hdd_speed': ('I/O', ['disabled', 'enabled']),
      'rpcs3_emulate_bdvd_speed': ('I/O', ['disabled', 'enabled']),
    },
  };

  final choices = <RestartTuningChoice>[];
  for (final entry in candidates.entries) {
    final option = options[entry.key];
    if (option == null || !option.restart) continue;
    final (group, values) = entry.value;
    for (final value in values) {
      final index = option.values.indexOf(value);
      if (index < 0 || index == option.selected) continue;
      final label = index < option.labels.length ? option.labels[index] : value;
      choices.add((key: entry.key, value: value, label: '${option.title} · $label', group: group));
    }
  }
  return choices;
}

bool restartRendererMatches(RestartTuningChoice choice, {required bool hardware}) => switch (choice.group) {
  'Renderer' when choice.value == 'D3D11' => hardware,
  'Renderer' => !hardware,
  _ => true,
};
