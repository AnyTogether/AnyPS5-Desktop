import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// An extracted PS3 disc: a folder with PS3_DISC.SFB and PS3_GAME, which RPCS3 boots from
/// PS3_GAME/USRDIR/EBOOT.BIN.
abstract final class Ps3Disc {
  /// The disc's PARAM.SFO, which names the game.
  static String paramsFile(String folder) => p.join(folder, 'PS3_GAME', 'PARAM.SFO');

  /// Whether [folder] holds a whole extracted disc.
  static bool isDisc(String folder) =>
      File(p.join(folder, 'PS3_DISC.SFB')).existsSync() &&
      File(p.join(folder, 'PS3_GAME', 'USRDIR', 'EBOOT.BIN')).existsSync() &&
      File(paramsFile(folder)).existsSync();

  /// The text values of the disc's PARAM.SFO (TITLE, TITLE_ID, APP_VER...), null when [folder]
  /// is no disc or its PARAM.SFO cannot be read.
  static Map<String, String>? metadata(String folder) {
    final file = File(paramsFile(folder));
    if (!isDisc(folder)) return null;
    try {
      if (file.lengthSync() > 1024 * 1024) return null;
      final bytes = file.readAsBytesSync();
      final data = ByteData.sublistView(bytes);
      if (bytes.length < 20 || data.getUint32(0) != 0x00505346) return null;
      final keyStart = data.getUint32(8, Endian.little);
      final valueStart = data.getUint32(12, Endian.little);
      final count = data.getUint32(16, Endian.little);
      if (20 + count * 16 > keyStart || keyStart > valueStart || valueStart > bytes.length) return null;
      final result = <String, String>{};
      for (var i = 0; i < count; i++) {
        final entry = 20 + i * 16;
        if (data.getUint16(entry + 2, Endian.little) != 0x0204) continue;
        final key = keyStart + data.getUint16(entry, Endian.little);
        final size = data.getUint32(entry + 4, Endian.little);
        final value = valueStart + data.getUint32(entry + 12, Endian.little);
        if (key >= valueStart || value + size > bytes.length) continue;
        result[_string(bytes, key, valueStart)] = _string(bytes, value, value + size);
      }
      return result;
    } on FileSystemException {
      return null;
    }
  }

  static String _string(Uint8List bytes, int start, int limit) {
    final end = bytes.indexOf(0, start);
    return utf8.decode(bytes.sublist(start, end < 0 || end > limit ? limit : end), allowMalformed: true);
  }
}
