import '../core/game_library.dart';
import '../core/retro_settings.dart';
import 'app_model.dart';

abstract final class RetroControllerSettings {
  static const _actions = {
    'Up': 'D-pad up',
    'Right': 'D-pad right',
    'Down': 'D-pad down',
    'Left': 'D-pad left',
    'Triangle': 'Triangle',
    'Circle': 'Circle',
    'Cross': 'Cross',
    'Square': 'Square',
    'Select': 'Select',
    'Start': 'Start',
    'L1': 'L1',
    'R1': 'R1',
    'L2': 'L2',
    'R2': 'R2',
    'L3': 'L3',
    'R3': 'R3',
    'LLeft': 'Left stick left',
    'LRight': 'Left stick right',
    'LDown': 'Left stick down',
    'LUp': 'Left stick up',
    'RLeft': 'Right stick left',
    'RRight': 'Right stick right',
    'RDown': 'Right stick down',
    'RUp': 'Right stick up',
    'LargeMotor': 'Strong vibration',
    'SmallMotor': 'Light vibration',
  };

  static const _inputs = {
    'DPadUp': 'D-pad up',
    'DPadRight': 'D-pad right',
    'DPadDown': 'D-pad down',
    'DPadLeft': 'D-pad left',
    'Back': 'Select',
    'Start': 'Start',
    'LeftShoulder': 'L1',
    'RightShoulder': 'R1',
    '+LeftTrigger': 'L2',
    '+RightTrigger': 'R2',
    'LeftStick': 'L3',
    'RightStick': 'R3',
    '-LeftX': 'Left stick left',
    '+LeftX': 'Left stick right',
    '+LeftY': 'Left stick down',
    '-LeftY': 'Left stick up',
    '-RightX': 'Right stick left',
    '+RightX': 'Right stick right',
    '+RightY': 'Right stick down',
    '-RightY': 'Right stick up',
  };

  static bool handles(String key) => key == 'Type' || _actions.containsKey(key);

  static List<PanelRow> rows({
    required RetroSettings settings,
    required RetroPlatform platform,
    required String section,
    required void Function(void Function()) save,
  }) {
    final options = settings.options.where((option) => option.section == section).toList();
    final types = {
      'None': 'Disconnected',
      if (platform == RetroPlatform.ps1) ...{
        'AnalogController': 'DualShock',
        'DigitalController': 'Digital controller',
      } else
        'DualShock2': 'DualShock 2',
    };
    final port = section.startsWith('Pad') ? section.substring(3) : section;
    final rows = <PanelRow>[];
    for (final key in ['Type', ..._actions.keys]) {
      final matches = options.where((option) => option.key == key).toList();
      final entries = matches.isEmpty ? <RetroOption?>[null] : matches;
      for (final option in entries) {
        final value = option?.value ?? (key == 'Type' ? 'None' : '');
        final choices = key == 'Type' ? {...types} : _bindingChoices(platform, motor: key.endsWith('Motor'));
        choices.putIfAbsent(value, () => 'Custom · $value');
        final values = choices.keys.toList();
        rows.add(
          PanelRow(
            id: 'retro-${platform.name}-$section-$key-${option?.line ?? 'new'}',
            title: key == 'Type' ? 'Port $port controller' : _actions[key]!,
            detail: key == 'Type'
                ? 'Controller connected to console port $port.'
                : 'Choose Unbound to clear this input.',
            kind: ChoiceRow(choices.values.toList(), values.indexOf(value), (index) {
              final next = values[index];
              if (next == value) return;
              save(() {
                if (option == null) {
                  settings.add(section, key, next);
                } else {
                  settings.replace(option, next);
                }
              });
            }),
          ),
        );
      }
    }
    return rows;
  }

  static Map<String, String> _bindingChoices(RetroPlatform platform, {required bool motor}) {
    final inputs = motor
        ? {'LargeMotor': 'Strong vibration', 'SmallMotor': 'Light vibration'}
        : {
            ..._inputs,
            if (platform == RetroPlatform.ps1) ...{
              'Y': 'Triangle',
              'B': 'Circle',
              'A': 'Cross',
              'X': 'Square',
            } else ...{
              'FaceNorth': 'Triangle',
              'FaceEast': 'Circle',
              'FaceSouth': 'Cross',
              'FaceWest': 'Square',
            },
          };
    final arrowSuffix = platform == RetroPlatform.ps1 ? 'Arrow' : '';
    final enter = platform == RetroPlatform.ps1 ? 'Enter' : 'Return';
    return {
      '': 'Unbound',
      for (var device = 0; device < 4; device++)
        for (final input in inputs.entries) 'SDL-$device/${input.key}': 'Controller ${device + 1} · ${input.value}',
      if (!motor) ...{
        'Keyboard/Up$arrowSuffix': 'Keyboard · Up arrow',
        'Keyboard/Right$arrowSuffix': 'Keyboard · Right arrow',
        'Keyboard/Down$arrowSuffix': 'Keyboard · Down arrow',
        'Keyboard/Left$arrowSuffix': 'Keyboard · Left arrow',
        'Keyboard/$enter': 'Keyboard · Enter',
        'Keyboard/Space': 'Keyboard · Space',
        'Keyboard/Backspace': 'Keyboard · Backspace',
        'Keyboard/Escape': 'Keyboard · Escape',
        for (var key = 65; key <= 90; key++)
          'Keyboard/${String.fromCharCode(key)}': 'Keyboard · ${String.fromCharCode(key)}',
        for (var key = 0; key < 10; key++) 'Keyboard/$key': 'Keyboard · $key',
        for (var key = 1; key <= 12; key++) 'Keyboard/F$key': 'Keyboard · F$key',
      },
    };
  }
}
