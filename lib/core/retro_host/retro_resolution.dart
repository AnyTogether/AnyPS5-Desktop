/// The internal resolution a PS1 or PS2 game in the emulator host is drawn at, as the in-game menu
/// offers it: the core option of each console, the scales the launcher offers, and what the
/// host's `status` says of them (anyps5-retro-host docs/protocol.md "status").
library;

import 'retro_graphics.dart';
import 'retro_host_protocol.dart';

/// SwanStation's internal resolution, whose values are whole scales (`"1"` to `"16"`). Every host
/// limits it to what it can pass on while it draws with the GPU (`status.hardware`).
const retroResolutionKeyPs1 = 'swanstation_GPU_ResolutionScale';

/// LRPS2's internal resolution (`"1x (Native)"`, `"2x"`, `"4x"`, `"8x"`), applied only when the
/// game starts. Only a host that lists [retroCapabilityPs2ResolutionLimits] limits it.
const retroResolutionKeyPs2 = 'pcsx2_upscale_multiplier';

/// The internal resolution's option key for a PS1 game, or with [ps2] for a PS2 game.
String retroResolutionKey({bool ps2 = false}) => ps2 ? retroResolutionKeyPs2 : retroResolutionKeyPs1;

/// The values the launcher offers, by console, with the scale each one draws at: Native to 4x.
/// LRPS2 lists no 3x. Larger scales are not offered: on a 1080p or 1440p display most of the gain
/// is at 2x to 4x, and PS2 games at 8x ran at about half speed on a fast graphics card
/// (anyps5-retro-host docs/ps2.md "Drawing"). The host may list fewer, and only those it lists
/// are offered.
const _offered = {
  false: {'1': 1, '2': 2, '3': 3, '4': 4},
  true: {'1x (Native)': 1, '2x': 2, '4x': 4},
};

/// One value the row offers.
class RetroResolutionValue {
  const RetroResolutionValue({required this.value, required this.scale, required this.label});

  /// The option's value, sent with `option`.
  final String value;

  /// The scale it draws at, 1 for Native; null for a value the launcher does not offer, which is
  /// shown only while the host has it chosen.
  final int? scale;

  /// The host's label of the value.
  final String label;

  @override
  bool operator ==(Object other) =>
      other is RetroResolutionValue && other.value == value && other.scale == scale && other.label == label;

  @override
  int get hashCode => Object.hash(value, scale, label);

  @override
  String toString() => 'RetroResolutionValue($value, $scale)';
}

/// The internal resolution of a running game, as its menu offers it.
class RetroResolutionChoice {
  const RetroResolutionChoice({
    required this.key,
    required this.values,
    required this.selected,
    required this.active,
    required this.note,
  });

  /// The choice [status] allows, or null when the menu offers none: no status yet, the host draws
  /// without the GPU (`hardware` false, when it does not limit the value), the core lists no
  /// internal resolution, or it is a PS2 game's and the host does not limit it ([limitsPs2]
  /// false, the host's `ps2ResolutionLimits`). The console is the status's own (`console`, which
  /// only a host with `ps2` sends).
  ///
  /// The values are those the launcher offers that the host lists, in the host's order, and the
  /// value chosen even when the launcher does not offer it, so the row always shows what the game
  /// has.
  static RetroResolutionChoice? of(RetroStatus? status, {required bool limitsPs2}) {
    if (status == null || !status.hardware) return null;
    final ps2 = status.console == RetroConsole.ps2;
    if (ps2 && !limitsPs2) return null;
    final option = status.options[retroResolutionKey(ps2: ps2)];
    if (option == null) return null;
    final offered = _offered[ps2]!;
    final chosen = option.values[option.selected];
    RetroResolutionValue valueAt(int index) => RetroResolutionValue(
      value: option.values[index],
      scale: offered[option.values[index]],
      label: option.labels[index],
    );
    final values = [
      for (final (index, value) in option.values.indexed)
        if (offered.containsKey(value) || value == chosen) valueAt(index),
    ];
    final activeIndex = option.values.indexOf(option.activeValue);
    return RetroResolutionChoice(
      key: option.key,
      values: values,
      selected: values.indexWhere((entry) => entry.value == chosen),
      active: activeIndex < 0
          ? RetroResolutionValue(
              value: option.activeValue,
              scale: offered[option.activeValue],
              label: option.activeValue,
            )
          : valueAt(activeIndex),
      note: _note(status, option, chosen),
    );
  }

  static RetroGraphicsNote _note(RetroStatus status, RetroOption option, String chosen) {
    if (status.resolutionError.isNotEmpty) return RetroGraphicsNote.refused;
    if (option.restart) {
      return chosen == option.activeValue ? RetroGraphicsNote.changesAtNextStart : RetroGraphicsNote.nextStart;
    }
    if (chosen != option.activeValue || status.graphicsPending) return RetroGraphicsNote.applying;
    return RetroGraphicsNote.none;
  }

  /// The option's key ([retroResolutionKey]).
  final String key;

  /// The values offered, in the host's order.
  final List<RetroResolutionValue> values;

  /// The index into [values] of the value chosen.
  final int selected;

  /// The value the game draws at now (`activeValue`), which the refusal names.
  final RetroResolutionValue active;

  final RetroGraphicsNote note;

  @override
  String toString() => 'RetroResolutionChoice($key, $values, selected: $selected, ${note.name})';
}
