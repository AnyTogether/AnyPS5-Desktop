import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/retro_host/retro_host_protocol.dart';
import 'retro_host_controls.dart';
import 'retro_host_game.dart';
import 'retro_option_sections.dart';

/// One row of the in-game menu.
sealed class RetroMenuRow {
  const RetroMenuRow();
}

/// A disc of a multi-disc game (`status.discs`), to insert with `changeDisc`.
class RetroDiscRow extends RetroMenuRow {
  const RetroDiscRow({required this.index, required this.label, required this.inserted, required this.enabled});

  /// The index into `discs.labels`, which is the `changeDisc` argument.
  final int index;
  final String label;

  /// This disc is in the console now.
  final bool inserted;

  /// It can be chosen: it is not in the console and no change is in progress.
  final bool enabled;

  @override
  bool operator ==(Object other) =>
      other is RetroDiscRow &&
      other.index == index &&
      other.label == label &&
      other.inserted == inserted &&
      other.enabled == enabled;

  @override
  int get hashCode => Object.hash(index, label, inserted, enabled);

  @override
  String toString() => 'RetroDiscRow($index, $label, inserted: $inserted, enabled: $enabled)';
}

/// A core option the status lists (`status.options`), to change with `option`.
class RetroOptionRow extends RetroMenuRow {
  const RetroOptionRow(this.option);

  final RetroOption option;

  String get key => option.key;

  /// The option's title, without SwanStation's own " (Restart)" ([retroOptionTitle]).
  String get title => retroOptionTitle(option.title);

  /// Where it is shown ([retroOptionSection]); rows are made only for options that are shown.
  RetroOptionSection get section => retroOptionSection(key)!;

  /// The label of the value chosen.
  String get choice => option.labels[option.selected];

  /// The chosen value is not the one the core runs with yet: it waits for a graphics change or,
  /// with [restartNeeded], for the game to be started again.
  bool get pending => option.values[option.selected] != option.activeValue;

  /// A change only takes effect when the game is started again.
  bool get restartNeeded => option.restart;

  @override
  bool operator ==(Object other) =>
      other is RetroOptionRow &&
      other.key == key &&
      other.choice == choice &&
      other.pending == pending &&
      other.restartNeeded == restartNeeded;

  @override
  int get hashCode => Object.hash(key, choice, pending, restartNeeded);

  @override
  String toString() => 'RetroOptionRow($key, $choice${pending ? ', pending' : ''})';
}

/// The host's output volume (`volume`).
class RetroVolumeRow extends RetroMenuRow {
  const RetroVolumeRow({required this.level, required this.muted});

  final double level;
  final bool muted;

  @override
  bool operator ==(Object other) => other is RetroVolumeRow && other.level == level && other.muted == muted;

  @override
  int get hashCode => Object.hash(level, muted);

  @override
  String toString() => 'RetroVolumeRow($level, muted: $muted)';
}

/// The in-game menu of a [RetroHostGame]: its rows and what choosing them does. Opening it pauses
/// the game and keeps the controllers' presses from it ([RetroHostControls.suspended]); closing
/// it gives both back. It shows no widget itself: a menu view lists [rows] and calls the actions.
class RetroGameMenu extends ChangeNotifier {
  RetroGameMenu(this.game, {this.controls, this.volumeStep = 0.1}) {
    game.addListener(notifyListeners);
  }

  final RetroHostGame game;
  final RetroHostControls? controls;

  /// How far one step of the volume row moves it.
  final double volumeStep;

  bool get isOpen => _open;
  bool _open = false;

  /// Whether the last disc change failed (`discs.failed`).
  bool get discChangeFailed => game.status?.discs?.failed ?? false;

  /// The rows for the game's last status: the discs of a multi-disc game, then the core options
  /// that are shown ([retroOptionSection]) in the order the host lists them, then the volume.
  List<RetroMenuRow> get rows => rowsFor(game.status, volume: game.volume, muted: game.muted);

  /// The core options of [section], in the order the host lists them.
  List<RetroOptionRow> optionsIn(RetroOptionSection section) => [
    for (final row in rows.whereType<RetroOptionRow>())
      if (row.section == section) row,
  ];

  /// The rows for [status] (null before the first one) and the volume.
  static List<RetroMenuRow> rowsFor(RetroStatus? status, {required double volume, required bool muted}) {
    final discs = status?.discs;
    return [
      if (discs != null && discs.labels.length > 1)
        for (final (index, label) in discs.labels.indexed)
          RetroDiscRow(
            index: index,
            label: label,
            inserted: discs.inserted == index,
            enabled: !discs.busy && discs.inserted != index,
          ),
      for (final option in status?.options.values ?? const <RetroOption>[])
        if (retroOptionShown(option.key)) RetroOptionRow(option),
      RetroVolumeRow(level: volume, muted: muted),
    ];
  }

  /// Opens the menu: the game is paused and the controllers' presses stay out of it.
  Future<void> open() async {
    if (_open || !game.loaded) return;
    _open = true;
    controls?.suspended = true;
    notifyListeners();
    await game.pause(true);
  }

  /// Closes the menu and gives the game back its controllers; a button still held from the menu
  /// reaches the game only once it is let go and pressed again.
  Future<void> close() async {
    if (!_open) return;
    _open = false;
    controls?.suspended = false;
    notifyListeners();
    await game.pause(false);
  }

  /// Inserts a disc; false when the row cannot be chosen now or the host refused.
  Future<bool> chooseDisc(RetroDiscRow row) async {
    final current = rows.whereType<RetroDiscRow>().where((disc) => disc.index == row.index).firstOrNull;
    if (current == null || !current.enabled) return false;
    return game.changeDisc(row.index);
  }

  /// Moves an option [steps] values on (back when negative), stopping at the first and last;
  /// false when it is already there, the option is gone, or the host refused.
  Future<bool> stepOption(String key, int steps) async {
    final option = game.status?.options[key];
    if (option == null) return false;
    final next = (option.selected + steps).clamp(0, option.values.length - 1);
    if (next == option.selected) return false;
    return game.setOption(key, option.values[next]);
  }

  /// Moves the volume [steps] of [volumeStep] up (down when negative), from 0 to 1. Turning it up
  /// unmutes. The level is counted in whole steps and divided last, so three tenths is 0.3, not
  /// 3 × 0.1 (0.30000000000000004).
  Future<void> stepVolume(int steps) {
    final perUnit = (1 / volumeStep).round();
    final next = ((game.volume * perUnit).round() + steps).clamp(0, perUnit);
    return game.setVolume(level: next / perUnit, muted: steps > 0 ? false : null);
  }

  Future<void> toggleMute() => game.setVolume(muted: !game.muted);

  /// A menu that goes away while open gives the game back its controllers and resumes it.
  @override
  void dispose() {
    game.removeListener(notifyListeners);
    if (_open) {
      _open = false;
      controls?.suspended = false;
      unawaited(game.pause(false));
    }
    super.dispose();
  }
}
