import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../core/game_deletion.dart';

/// Windows' Recycle Bin through the runner's "anyps5/window" channel (windows/runner/recycle.cpp:
/// the shell's IFileOperation on a thread of its own). An item Windows would delete for good
/// instead (a drive without a Recycle Bin, a folder too big for it) is left untouched and
/// answered [NoTrash].
class ChannelTrash extends Trash {
  const ChannelTrash();

  static const _channel = MethodChannel('anyps5/window');

  @override
  Future<TrashResult> move(String path) async {
    try {
      return switch (await _channel.invokeMethod<int>('recycle', p.normalize(p.absolute(path)))) {
        0 => const Trashed(),
        1 => const NoTrash(),
        _ => const TrashFailed('Windows could not move it to the Recycle Bin'),
      };
    } on PlatformException catch (error) {
      return TrashFailed(error.message ?? error.code);
    } on MissingPluginException {
      return const NoTrash();
    }
  }
}
