import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'retro_host_protocol.dart';

/// What saving or loading a state came to (anyps5-retro-host docs/protocol.md "saveState and
/// loadState").
enum RetroStateOutcome {
  /// The host saved the state, or loaded it into the game.
  done,

  /// The call returned `false`: no game is loaded, it has not shown its first frame, it has ended,
  /// or the game's thread did not get to the call in time.
  notNow,

  /// `noState`: the slot holds no state.
  noState,

  /// `badState`: the file is not a state this host reads, or it is damaged.
  badState,

  /// `otherGame`: the state was saved from another game.
  otherGame,

  /// `otherCore`: the state was saved by another core or core build, so the host refuses it
  /// rather than give the core data it may misread.
  otherCore,

  /// `coreRefused`: the core gave no state, or refused the one in the file; the game runs on.
  coreRefused,

  /// `fileError`: the file could not be written or read in time.
  fileError,

  /// Any other error: an `argument` error, a code this launcher does not know, or a host that
  /// went away.
  failed;

  /// The outcome of an `error` reply with [code].
  static RetroStateOutcome ofError(String code) => switch (code) {
    RetroCallError.noState => noState,
    RetroCallError.badState => badState,
    RetroCallError.otherGame => otherGame,
    RetroCallError.otherCore => otherCore,
    RetroCallError.coreRefused => coreRefused,
    RetroCallError.fileError => fileError,
    _ => failed,
  };
}

/// One save state slot of a game, as the launcher's states folder holds it: when its state was
/// saved (the file's time), and the picture the launcher kept of that moment.
class RetroStateSlot {
  const RetroStateSlot(this.slot, {this.savedAt, this.picture});

  /// The host's slot number, 0 to [RetroStateFolder.slots] - 1; the player sees it from 1.
  final int slot;

  /// When the state in it was saved; null for an empty slot.
  final DateTime? savedAt;

  /// A PNG of the game's picture when it was saved; null when none was kept.
  final Uint8List? picture;

  bool get empty => savedAt == null;
}

/// The save states of one game in the launcher's states folder for its console
/// (`retro/states/<console>`, [AppPaths.retroStates]): the folder `start.states` names, so the
/// host writes each slot there as `<disc's name without its extension>.<slot>.state`, as it names
/// the memory card `<name>.srm` in `saves`. The launcher keeps each slot's picture beside it as
/// `<name>.<slot>.png`; the host reads and writes nothing but its `.state` files there.
class RetroStateFolder {
  RetroStateFolder({required this.folder, required String disc}) : name = discName(disc);

  /// How many slots a game has: the host's slots 0 to 7.
  static const slots = 8;

  /// The largest picture read back: a picture larger than this is not one the launcher wrote.
  static const pictureLimit = 1 << 20;

  /// The folder `start.states` names.
  final String folder;

  /// The disc's name without its extension, as the host takes it: the last part of the path after
  /// its last `/` (on Windows also `\`), without what follows its last dot, unless that dot is its
  /// first letter.
  final String name;

  /// The name the host gives [disc]'s states and memory card (protocol.md "start", `saves`): on
  /// Windows, or with [windows] false on Linux and macOS, where `\` is a letter of a file's name.
  static String discName(String disc, {bool? windows}) {
    final base = disc.split((windows ?? Platform.isWindows) ? RegExp(r'[\\/]') : '/').last;
    final dot = base.lastIndexOf('.');
    return dot <= 0 ? base : base.substring(0, dot);
  }

  String statePath(int slot) => p.join(folder, '$name.$slot.state');

  String picturePath(int slot) => p.join(folder, '$name.$slot.png');

  /// When [slot]'s state file was last written; null when there is none.
  Future<DateTime?> written(int slot) async {
    try {
      final state = await File(statePath(slot)).stat();
      return state.type == FileSystemEntityType.file ? state.modified : null;
    } on FileSystemException {
      return null;
    }
  }

  /// Every slot as the folder holds it now. A slot whose state cannot be read is empty; a picture
  /// that cannot be read, or is far larger than one the launcher writes, is left out.
  Future<List<RetroStateSlot>> read() async => [for (var slot = 0; slot < slots; slot++) await _read(slot)];

  Future<RetroStateSlot> _read(int slot) async {
    final savedAt = await written(slot);
    if (savedAt == null) return RetroStateSlot(slot);
    Uint8List? picture;
    try {
      final file = File(picturePath(slot));
      if (await file.length() <= pictureLimit) picture = await file.readAsBytes();
    } on FileSystemException {
      picture = null;
    }
    return RetroStateSlot(slot, savedAt: savedAt, picture: picture);
  }

  /// Keeps [png] as [slot]'s picture: written beside it, then renamed over it, so a picture is
  /// whole or not there. With [png] null, the picture of the state the slot held before goes.
  Future<void> keepPicture(int slot, Uint8List? png) async {
    final path = picturePath(slot);
    if (png == null) {
      await _delete(path);
      return;
    }
    final writing = File('$path.writing');
    try {
      await writing.writeAsBytes(png, flush: true);
      await writing.rename(path);
    } on FileSystemException {
      await _delete(writing.path);
      await _delete(path);
      rethrow;
    }
  }

  static Future<void> _delete(String path) async {
    try {
      await File(path).delete();
    } on FileSystemException {
      return;
    }
  }
}
