import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

abstract final class Ps3Disc {
  static Map<String, String>? metadata(String folder) {
    final file = File(p.join(folder, 'PS3_GAME', 'PARAM.SFO'));
    if (!File(p.join(folder, 'PS3_DISC.SFB')).existsSync() ||
        !File(p.join(folder, 'PS3_GAME', 'USRDIR', 'EBOOT.BIN')).existsSync() ||
        !file.existsSync()) {
      return null;
    }
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
