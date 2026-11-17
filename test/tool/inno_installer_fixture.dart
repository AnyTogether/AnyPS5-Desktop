import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../../tool/release_files.dart';

/// [data] as LZMA2 chunks that store it, each up to 64 KiB, and the end marker.
List<int> lzma2Stored(List<int> data) => [
  for (var at = 0; at < data.length; at += 0x10000) ...[
    at == 0 ? 1 : 2,
    (data.length - at).clamp(1, 0x10000) - 1 >> 8,
    (data.length - at).clamp(1, 0x10000) - 1 & 0xff,
    ...data.sublist(at, (at + 0x10000).clamp(0, data.length)),
  ],
  0,
];

/// An installer laid out as Inno Setup 6.7's: a loader, its version 2 offset table, the file data
/// ("zlb" 0x1a, one LZMA2 dictionary byte, then [chunks]' LZMA2 data, one after the other), the
/// setup header and the uninstaller.
Uint8List innoInstaller(List<List<int>> chunks) {
  final loader = [0x4d, 0x5a, for (var i = 0; i < 98; i++) 0];
  final files = [
    for (final chunk in chunks) ...[0x7a, 0x6c, 0x62, 0x1a, ...chunk],
  ];
  const header = 64;
  final offset1 = loader.length + 64;
  final offset0 = offset1 + files.length;
  final exe = offset0 + header;
  final total = exe + 32;
  final table = Uint8List(64);
  table.setAll(0, innoOffsetTableId);
  ByteData.sublistView(table)
    ..setUint32(12, 2, Endian.little)
    ..setUint64(16, total, Endian.little)
    ..setUint64(24, exe, Endian.little)
    ..setUint64(40, offset0, Endian.little)
    ..setUint64(48, offset1, Endian.little)
    ..setUint32(60, getCrc32(table.sublist(0, 60)), Endian.little);
  return Uint8List.fromList([...loader, ...table, ...files, ...Uint8List(header), ...Uint8List(32)]);
}
