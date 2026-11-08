import '../core/retro_settings.dart';
import '../core/game_library.dart';
import 'app_model.dart';

typedef _GraphicsChoice = ({String title, String detail, String defaultValue, Map<String, String> values});

abstract final class RetroGraphicsSettings {
  static const _ps2Section = 'EmuCore/GS';
  static const _ps1Section = 'GPU';
  static const _ps1Controls = <String, _GraphicsChoice>{
    'ResolutionScale': (
      title: 'Internal Resolution',
      detail: 'Higher resolutions smooth jagged edges and use more GPU power.',
      defaultValue: '1',
      values: {'0': 'Automatic', '1': 'Native (1×)', '2': '2×', '3': '3×', '4': '4×', '5': '5×', '6': '6×'},
    ),
  };
  static const _ps2Controls = <String, _GraphicsChoice>{
    'upscale_multiplier': (
      title: 'Internal Resolution',
      detail: 'Higher resolutions smooth jagged edges and use more GPU power. Requires a hardware renderer.',
      defaultValue: '1',
      values: {
        '1': 'Native (1×)',
        '2': '2× (~720p)',
        '3': '3× (~1080p)',
        '4': '4× (~1440p)',
        '5': '5× (~1800p)',
        '6': '6× (~2160p)',
        '7': '7×',
        '8': '8×',
        '9': '9×',
        '10': '10×',
        '11': '11×',
        '12': '12×',
      },
    ),
    'Renderer': (
      title: 'Renderer',
      detail: 'Automatic lets PCSX2 choose the graphics renderer. Software renders at native resolution.',
      defaultValue: '-1',
      values: {
        '-1': 'Automatic',
        '3': 'Direct3D 11',
        '15': 'Direct3D 12',
        '12': 'OpenGL',
        '14': 'Vulkan',
        '13': 'Software',
      },
    ),
    'filter': (
      title: 'Texture Filtering',
      detail: 'PS2 follows the game’s texture settings. Forced bilinear can soften textures and sprites.',
      defaultValue: '2',
      values: {
        '0': 'Nearest',
        '1': 'Bilinear (forced)',
        '2': 'Bilinear (PS2)',
        '3': 'Bilinear (forced, except sprites)',
      },
    ),
    'MaxAnisotropy': (
      title: 'Anisotropic Filtering',
      detail: 'Keeps textures such as roads sharper when viewed at an angle.',
      defaultValue: '0',
      values: {'0': 'Off', '2': '2×', '4': '4×', '8': '8×', '16': '16×'},
    ),
    'fxaa': (
      title: 'FXAA',
      detail: 'Smooths edges after rendering and can soften the picture.',
      defaultValue: 'false',
      values: {'false': 'Off', 'true': 'On'},
    ),
  };

  static bool handles(RetroOption option) => option.section == _ps2Section && _ps2Controls.containsKey(option.key);

  static String section(RetroPlatform platform) => platform == RetroPlatform.ps1 ? _ps1Section : _ps2Section;

  static Map<String, _GraphicsChoice> _controls(RetroPlatform platform) =>
      platform == RetroPlatform.ps1 ? _ps1Controls : _ps2Controls;

  static bool accepts(RetroPlatform platform, String key, String value) =>
      _controls(platform)[key]?.values.containsKey(value) ?? false;

  static List<PanelRow> rows({
    required RetroSettings settings,
    required void Function(void Function()) save,
    RetroPlatform platform = RetroPlatform.ps2,
    Map<String, String> queued = const {},
    void Function(String key, String value)? queue,
  }) {
    final group = section(platform);
    final options = settings.options.where((option) => option.section == group).toList();
    final rows = <PanelRow>[];
    for (final entry in _controls(platform).entries) {
      final matching = options.where((option) => option.key == entry.key).toList();
      if (queue != null && matching.length > 1) continue;
      final entries = matching.isEmpty ? <RetroOption?>[null] : matching;
      for (final option in entries) {
        final key = entry.key;
        rows.add(
          _row(
            platform,
            key,
            entry.value,
            option,
            queued[key],
            queue != null
                ? (next) => queue(key, next)
                : (next) => save(() {
                    if (option == null) {
                      settings.add(group, key, next);
                    } else {
                      settings.replace(option, next);
                    }
                  }),
          ),
        );
      }
    }
    return rows;
  }

  static PanelRow _row(
    RetroPlatform platform,
    String key,
    _GraphicsChoice control,
    RetroOption? option,
    String? queued,
    void Function(String) change,
  ) {
    final value = queued ?? option?.value ?? control.defaultValue;
    final choices = {...control.values};
    final canonical = switch (key) {
      'upscale_multiplier' => choices.keys.where((entry) => double.parse(entry) == double.tryParse(value)).firstOrNull,
      'fxaa' => value.toLowerCase(),
      _ => int.tryParse(value)?.toString(),
    };
    final selectedValue = choices.containsKey(canonical) ? canonical! : value;
    choices.putIfAbsent(selectedValue, () => 'Custom · $value');
    final values = choices.keys.toList();
    return PanelRow(
      id: 'retro-${platform.name}-graphics-$key-${option?.line ?? 'new'}',
      title: control.title,
      detail: control.detail,
      kind: ChoiceRow(choices.values.toList(), values.indexOf(selectedValue), (index) {
        final next = values[index];
        if (next == selectedValue) return;
        if (control.values.containsKey(next)) change(next);
      }),
    );
  }
}
