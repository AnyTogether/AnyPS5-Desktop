import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../../core/retro_host/retro_state_slots.dart';
import 'retro_host_game.dart';
import 'retro_state_picture.dart';

/// Makes the picture kept beside a saved state from the game's [image] at its display [aspect].
typedef RetroStatePictureMaker = Future<Uint8List?> Function(ui.Image image, double aspect);

/// A game's save states in the emulator host: its slots as its states folder holds them, and
/// saving into one and loading one back. A save keeps a picture of its moment beside the state:
/// the frame shown, which is the paused game's while its menu is open. One save or load runs at a
/// time; another asked meanwhile is [RetroStateOutcome.notNow].
class RetroSaveStates extends ChangeNotifier {
  RetroSaveStates(this.game, this.folder, {RetroStatePictureMaker? picture, this.log})
    : _picture = picture ?? ((image, aspect) => retroStatePicture(image, aspect: aspect));

  final RetroHostGame game;
  final RetroStateFolder folder;

  /// Where a picture that could not be kept is told.
  final void Function(String line)? log;

  final RetroStatePictureMaker _picture;

  /// Whether the game's host saves and loads its states ([RetroHostGame.savesStates]).
  bool get available => game.savesStates;

  /// Every slot, as the folder held it when it was last read ([refresh]); all empty before.
  List<RetroStateSlot> get slots => _slots;
  List<RetroStateSlot> _slots = [for (var slot = 0; slot < RetroStateFolder.slots; slot++) RetroStateSlot(slot)];

  /// Whether any slot holds a state.
  bool get anySaved => _slots.any((slot) => !slot.empty);

  /// The slot [slot] as last read.
  RetroStateSlot slot(int slot) => _slots[slot];

  /// Whether a save or a load is under way.
  bool get busy => _running != null;

  /// The slot a save or a load is under way in, and whether it is a save; null when none is.
  ({int slot, bool saving})? get running => _running;
  ({int slot, bool saving})? _running;
  bool _disposed = false;

  /// Reads the slots from the folder again.
  Future<void> refresh() async {
    final read = await folder.read();
    if (_disposed) return;
    _slots = read;
    notifyListeners();
  }

  /// Saves the game's state into [slot], replacing the one it held, with a picture of the frame
  /// shown; the slots are read again after. Only a save the core refused (it gave no state, so the
  /// host wrote nothing) is sure to have left the slot as it was, and keeps its picture. Any other
  /// save that did not work takes the picture away: after a `fileError` the host's late write may
  /// still put the new state in place (protocol.md "saveState and loadState"), and a host that went
  /// away after writing it answers `false` as one that never ran does, so no picture is better than
  /// one of a moment the slot may no longer hold.
  Future<RetroStateOutcome> save(int slot) => _run(slot, saving: true, () async {
    final shown = game.picture.value?.clone();
    try {
      final outcome = await game.saveState(slot);
      switch (outcome) {
        case RetroStateOutcome.done:
          await _keepPicture(slot, shown);
        case RetroStateOutcome.coreRefused:
          break;
        default:
          await _keepPicture(slot, null);
      }
      await refresh();
      return outcome;
    } finally {
      shown?.dispose();
    }
  });

  /// Loads the state in [slot] back into the game. A slot found empty is read again, so it shows
  /// as such.
  Future<RetroStateOutcome> load(int slot) => _run(slot, saving: false, () async {
    final outcome = await game.loadState(slot);
    if (outcome == RetroStateOutcome.noState) await refresh();
    return outcome;
  });

  Future<RetroStateOutcome> _run(int slot, Future<RetroStateOutcome> Function() work, {required bool saving}) async {
    if (busy || !available) return RetroStateOutcome.notNow;
    _running = (slot: slot, saving: saving);
    _notify();
    try {
      return await work();
    } finally {
      _running = null;
      _notify();
    }
  }

  /// The picture of the state just saved in [slot], or none: a picture of the state before would
  /// show a moment the slot no longer holds.
  Future<void> _keepPicture(int slot, ui.Image? shown) async {
    Uint8List? png;
    if (shown != null) {
      try {
        png = await _picture(shown, game.aspect);
      } on Object catch (error) {
        log?.call('emulator host: no picture for state slot $slot: $error');
      }
    }
    // A game closed while its picture was made writes nothing: the next game may already be
    // saving into the same slot. The state it saved shows without a picture, or with an older one,
    // which RetroStateFolder.read leaves out.
    if (_disposed) return;
    try {
      await folder.keepPicture(slot, png);
    } on FileSystemException catch (error) {
      log?.call('emulator host: the picture of state slot $slot was not kept: $error');
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
