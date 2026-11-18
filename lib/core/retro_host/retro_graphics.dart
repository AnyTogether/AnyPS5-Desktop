/// The few graphics settings the in-game menu's Graphics page offers besides the internal
/// resolution (`retro_resolution.dart`), each a small set of plain values that set one or two core
/// options, and the values the launcher starts a game with when the player has chosen none. The
/// rest of the cores' graphics options stay at their defaults, which defer to each core's own
/// per-game list (SwanStation's `Main_ApplyGameSettings`, LRPS2's game database).
library;

import 'retro_host_protocol.dart';
import 'retro_resolution.dart';

/// What a Graphics row says under its value.
enum RetroGraphicsNote {
  /// Nothing to say: the value chosen is the one the game runs with.
  none,

  /// The value chosen is being applied and shows in a moment.
  applying,

  /// The value chosen takes effect when the game is started again.
  nextStart,

  /// The game runs with the value it started with, and any change takes effect at its next start.
  changesAtNextStart,

  /// The host could not use the internal resolution saved and draws at the largest it can
  /// (`status.resolutionError`). Only the internal resolution says this.
  refused,
}

/// Which setting a Graphics row is; each console has its own widescreen.
enum RetroGraphicsKind { smoothTextures, fixWobbly3d, widescreen, sharperTextures }

/// The launcher's name of a value a Graphics row offers.
enum RetroGraphicsLevel { off, on, smooth, extraSmooth }

/// One value a setting offers: its name, and the core option values it sets.
class RetroGraphicsOffer {
  const RetroGraphicsOffer(this.level, this.options);

  final RetroGraphicsLevel level;

  /// The value each core option takes, by key. The first key is the setting's own
  /// ([RetroGraphicsSetting.key]); any other follows it (widescreen's aspect ratio).
  final Map<String, String> options;
}

/// A graphics setting of one console's core, as a Graphics row offers it.
class RetroGraphicsSetting {
  const RetroGraphicsSetting({required this.kind, required this.ps2, required this.needsGpu, required this.offers});

  /// Which setting it is; its name is the row's id.
  final RetroGraphicsKind kind;

  /// It is LRPS2's (a PS2 game's); otherwise SwanStation's.
  final bool ps2;

  /// It changes only what the core draws with the GPU, so it is offered only while the host does
  /// (`status.hardware`).
  final bool needsGpu;

  /// The values offered, in the row's order.
  final List<RetroGraphicsOffer> offers;

  /// The core option the row shows: the one whose chosen value says which value is chosen.
  String get key => offers.first.options.keys.first;

  /// Every core option the setting sets.
  Set<String> get keys => {for (final offer in offers) ...offer.options.keys};

  @override
  String toString() => 'RetroGraphicsSetting(${kind.name}${ps2 ? ', ps2' : ''})';
}

/// SwanStation's texture filtering: nearest (the console's own look), bilinear, or xBR.
const retroSmoothTextures = RetroGraphicsSetting(
  kind: RetroGraphicsKind.smoothTextures,
  ps2: false,
  needsGpu: true,
  offers: [
    RetroGraphicsOffer(RetroGraphicsLevel.off, {_textureFilter: 'Nearest'}),
    RetroGraphicsOffer(RetroGraphicsLevel.smooth, {_textureFilter: 'Bilinear'}),
    RetroGraphicsOffer(RetroGraphicsLevel.extraSmooth, {_textureFilter: 'xBR'}),
  ],
);

/// SwanStation's PGXP geometry correction, which keeps polygons and their textures from wobbling.
/// Its culling and texture correction stay at their defaults, both on.
const retroFixWobbly3d = RetroGraphicsSetting(
  kind: RetroGraphicsKind.fixWobbly3d,
  ps2: false,
  needsGpu: true,
  offers: [
    RetroGraphicsOffer(RetroGraphicsLevel.off, {_pgxp: 'false'}),
    RetroGraphicsOffer(RetroGraphicsLevel.on, {_pgxp: 'true'}),
  ],
);

/// SwanStation's widescreen hack, with the 16:9 aspect ratio it needs: the two change together. It
/// widens the view of 3D games and breaks 2D and pre-rendered ones, and SwanStation's per-game list
/// turns it off for no game, so it is never chosen for the player.
const retroWidescreenPs1 = RetroGraphicsSetting(
  kind: RetroGraphicsKind.widescreen,
  ps2: false,
  needsGpu: false,
  offers: [
    RetroGraphicsOffer(RetroGraphicsLevel.off, {_widescreenHack: 'false', _aspectRatio: '4:3'}),
    RetroGraphicsOffer(RetroGraphicsLevel.on, {_widescreenHack: 'true', _aspectRatio: '16:9'}),
  ],
);

/// LRPS2's anisotropic filtering, off or at its largest (16x), which cost nothing measurable.
const retroSharperTextures = RetroGraphicsSetting(
  kind: RetroGraphicsKind.sharperTextures,
  ps2: true,
  needsGpu: true,
  offers: [
    RetroGraphicsOffer(RetroGraphicsLevel.off, {_anisotropic: 'disabled'}),
    RetroGraphicsOffer(RetroGraphicsLevel.on, {_anisotropic: '16x'}),
  ],
);

/// LRPS2's widescreen patch from its game database, applied when the game boots, only for a game
/// it has a patch for. Its 16:10, 21:9 and 32:9 values are not offered (LRPS2 never parses
/// `enabled (32:9)`), and it is never chosen for the player.
const retroWidescreenPs2 = RetroGraphicsSetting(
  kind: RetroGraphicsKind.widescreen,
  ps2: true,
  needsGpu: false,
  offers: [
    RetroGraphicsOffer(RetroGraphicsLevel.off, {_widescreenHint: 'disabled'}),
    RetroGraphicsOffer(RetroGraphicsLevel.on, {_widescreenHint: 'enabled (16:9)'}),
  ],
);

/// The settings of both consoles, in the order the Graphics page lists them after the internal
/// resolution.
const retroGraphicsSettings = [
  retroSmoothTextures,
  retroFixWobbly3d,
  retroWidescreenPs1,
  retroSharperTextures,
  retroWidescreenPs2,
];

/// The settings of a PS1 game, or with [ps2] of a PS2 game.
Iterable<RetroGraphicsSetting> retroGraphicsSettingsOf({required bool ps2}) =>
    retroGraphicsSettings.where((setting) => setting.ps2 == ps2);

/// Every core option a Graphics row sets, of both consoles.
final retroGraphicsKeys = {for (final setting in retroGraphicsSettings) ...setting.keys};

/// The core options a game starts with for the settings the player has not chosen ([kept] holds
/// the values the player chose), and SwanStation's true colour, which the menu does not offer:
///
/// - PS1: smooth textures (bilinear) from 2x up, off at Native, as the internal resolution kept
///   says (Native when none is); fix wobbly 3D on; true colour on, which DuckStation now has by
///   default, with SwanStation's scaled dithering left on;
/// - PS2: sharper textures on.
///
/// Widescreen is not among them: the cores start without it. A setting the player chose any value
/// of is left out whole, so a widescreen hack is never started without its aspect ratio.
Map<String, String> retroGraphicsDefaults(Map<String, String> kept, {required bool ps2}) {
  bool chosen(RetroGraphicsSetting setting) => setting.keys.any(kept.containsKey);
  if (ps2) {
    return {if (!chosen(retroSharperTextures)) _anisotropic: '16x'};
  }
  final scale = int.tryParse(kept[retroResolutionKeyPs1] ?? '') ?? 1;
  return {
    if (!chosen(retroSmoothTextures)) _textureFilter: scale >= 2 ? 'Bilinear' : 'Nearest',
    if (!chosen(retroFixWobbly3d)) _pgxp: 'true',
    retroTrueColorKey: 'true',
  };
}

/// SwanStation's true colour, which removes the console's dithering. Always on: the menu does not
/// offer it, and SwanStation's per-game list still turns it off for the games it breaks.
const retroTrueColorKey = 'swanstation_GPU_TrueColor';

const _textureFilter = 'swanstation_GPU_TextureFilter';
const _pgxp = 'swanstation_GPU_PGXPEnable';
const _widescreenHack = 'swanstation_GPU_WidescreenHack';
const _aspectRatio = 'swanstation_Display_AspectRatio';
const _anisotropic = 'pcsx2_anisotropic_filtering';
const _widescreenHint = 'pcsx2_widescreen_hint';

/// One value a Graphics row shows.
class RetroGraphicsValue {
  const RetroGraphicsValue({required this.offer, required this.label});

  /// The value the launcher offers, or null for one it does not, which the row shows only while
  /// the host has it chosen.
  final RetroGraphicsOffer? offer;

  /// The host's label of the setting's own option at this value, for a value the launcher does not
  /// offer.
  final String label;

  @override
  bool operator ==(Object other) => other is RetroGraphicsValue && other.offer == offer && other.label == label;

  @override
  int get hashCode => Object.hash(offer, label);

  @override
  String toString() => 'RetroGraphicsValue(${offer?.level.name ?? label})';
}

/// A graphics setting of a running game, as its Graphics row offers it.
class RetroGraphicsChoice {
  const RetroGraphicsChoice({required this.setting, required this.values, required this.selected, required this.note});

  /// The choice [status] allows for [setting], or null when the row is not shown: no status yet,
  /// a game of the other console, a setting that needs the GPU while the host draws without it, or
  /// a host that does not list the setting's option.
  ///
  /// A value is offered only when the host lists every option it sets with that value among the
  /// option's `values`, so the host's own limits hold. The value chosen is the offer whose value of
  /// the setting's option is chosen; a chosen value no offer has is shown too, with the host's
  /// label, so the row always shows what the game has.
  static RetroGraphicsChoice? of(RetroStatus? status, RetroGraphicsSetting setting) {
    if (status == null || (status.console == RetroConsole.ps2) != setting.ps2) return null;
    if (setting.needsGpu && !status.hardware) return null;
    final option = status.options[setting.key];
    if (option == null) return null;
    bool listed(RetroGraphicsOffer offer) =>
        offer.options.entries.every((entry) => status.options[entry.key]?.values.contains(entry.value) ?? false);
    final chosen = option.values[option.selected];
    final values = [
      for (final offer in setting.offers)
        if (listed(offer))
          RetroGraphicsValue(offer: offer, label: option.labels[option.values.indexOf(offer.options[setting.key]!)]),
    ];
    var selected = values.indexWhere((value) => value.offer!.options[setting.key] == chosen);
    if (selected < 0) {
      selected = values.length;
      values.add(RetroGraphicsValue(offer: null, label: option.labels[option.selected]));
    }
    return RetroGraphicsChoice(setting: setting, values: values, selected: selected, note: _note(status, setting));
  }

  static RetroGraphicsNote _note(RetroStatus status, RetroGraphicsSetting setting) {
    final options = [for (final key in setting.keys) ?status.options[key]];
    final settled = options.every((option) => option.values[option.selected] == option.activeValue);
    if (options.any((option) => option.restart)) {
      return settled ? RetroGraphicsNote.changesAtNextStart : RetroGraphicsNote.nextStart;
    }
    return settled ? RetroGraphicsNote.none : RetroGraphicsNote.applying;
  }

  final RetroGraphicsSetting setting;

  /// The values shown, in the setting's order, a chosen value no offer has last.
  final List<RetroGraphicsValue> values;

  /// The index into [values] of the value chosen.
  final int selected;

  final RetroGraphicsNote note;

  /// The core option values to send for the value at [index]: those that differ from what the
  /// host has chosen, in the offer's order; empty for the value chosen or one the launcher does not
  /// offer.
  Map<String, String> changesFor(RetroStatus status, int index) {
    final offer = index == selected ? null : values[index].offer;
    if (offer == null) return const {};
    return {
      for (final MapEntry(:key, :value) in offer.options.entries)
        if (status.options[key] case final option? when option.values[option.selected] != value) key: value,
    };
  }

  @override
  String toString() => 'RetroGraphicsChoice(${setting.kind.name}, $values, selected: $selected, ${note.name})';
}
