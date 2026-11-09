import 'dart:io';
import 'dart:typed_data';

import 'game_settings.dart' show ResolutionPatch;

/// What [LaunchResolution.apply] did.
enum LaunchResolutionResult { unchanged, written, refused }

/// A game's resolution set again at each start, as the Mac's launch script does: the width and
/// height written into the unlocked executable, at the places the title's patch file names.
///
/// The relinker keeps the title's code bytes in its output: on Windows at RVA 0x10000 plus the
/// guest address (the PE sections), on Linux at 0x400000 plus it (the ELF's load segments), with
/// the guest's lowest address 0. What is there must already read as a resolution the game can
/// have, or nothing is written: a toolkit that lays its output out otherwise keeps working, at
/// the resolution it was unlocked with.
abstract final class LaunchResolution {
  static const _peImageStart = 0x10000;
  static const _linuxBase = 0x400000;

  /// Sets the game at [executable] to [wanted]. [known] are the resolutions it may hold now; the
  /// patch file gives the addresses. The new bytes go into a copy that takes the file's place,
  /// so a relink the launcher keeps hard linked to it stays as it was.
  static Future<LaunchResolutionResult> apply({
    required String executable,
    required String patch,
    required String wanted,
    required Iterable<String> known,
  }) async {
    final size = ResolutionPatch.parse(wanted);
    final width = ResolutionPatch.addressOf(patch, 'width');
    final height = ResolutionPatch.addressOf(patch, 'height');
    if (size == null || width == null || height == null) return LaunchResolutionResult.refused;
    final (int, int)? offsets;
    final (int, int) current;
    final file = File(executable).openSync();
    try {
      offsets = _offsets(file, width, height);
      if (offsets == null) return LaunchResolutionResult.refused;
      current = (_readU32(file, offsets.$1), _readU32(file, offsets.$2));
    } on RangeError {
      return LaunchResolutionResult.refused;
    } finally {
      file.closeSync();
    }
    if (!known.contains('${current.$1}x${current.$2}')) return LaunchResolutionResult.refused;
    if (current == size) return LaunchResolutionResult.unchanged;
    final temporary = '$executable.resolution';
    await File(executable).copy(temporary);
    final copy = File(temporary).openSync(mode: FileMode.append);
    try {
      _writeU32(copy, offsets.$1, size.$1);
      _writeU32(copy, offsets.$2, size.$2);
    } finally {
      copy.closeSync();
    }
    File(temporary).renameSync(executable);
    return LaunchResolutionResult.written;
  }

  static (int, int)? _offsets(RandomAccessFile file, int width, int height) {
    final magic = _read(file, 0, 4);
    if (magic.length == 4 && magic[0] == 0x4d && magic[1] == 0x5a) {
      final at = _peOffsets(file, [width, height]);
      return at == null ? null : (at[0], at[1]);
    }
    if (magic.length == 4 && magic[0] == 0x7f && magic[1] == 0x45 && magic[2] == 0x4c && magic[3] == 0x46) {
      final at = _elfOffsets(file, [width, height]);
      return at == null ? null : (at[0], at[1]);
    }
    return null;
  }

  /// File offsets of [addresses] in a relinked PE: a section's file bytes hold its RVA range.
  static List<int>? _peOffsets(RandomAccessFile file, List<int> addresses) {
    final lfanew = _readU32(file, 0x3c);
    final coff = lfanew + 4;
    final sections = _read(file, coff + 2, 2);
    final optionalSize = _read(file, coff + 16, 2);
    if (sections.length < 2 || optionalSize.length < 2) return null;
    final count = sections[0] | sections[1] << 8;
    final table = coff + 20 + (optionalSize[0] | optionalSize[1] << 8);
    final out = <int>[];
    for (final address in addresses) {
      final rva = _peImageStart + address;
      int? found;
      for (var index = 0; index < count && found == null; index++) {
        final header = table + index * 40;
        final start = _readU32(file, header + 12);
        final rawSize = _readU32(file, header + 16);
        final raw = _readU32(file, header + 20);
        if (rva >= start && rva + 4 <= start + rawSize) found = raw + rva - start;
      }
      if (found == null) return null;
      out.add(found);
    }
    return out;
  }

  /// File offsets of [addresses] in a relinked Linux ELF: placed at 0x400000 unless it is
  /// position independent.
  static List<int>? _elfOffsets(RandomAccessFile file, List<int> addresses) {
    final type = _read(file, 0x10, 2);
    if (type.length < 2) return null;
    final base = (type[0] | type[1] << 8) == 2 ? _linuxBase : 0;
    final programHeaders = _readU64(file, 0x20);
    final entrySize = _read(file, 0x36, 2);
    final count = _read(file, 0x38, 2);
    if (entrySize.length < 2 || count.length < 2) return null;
    final size = entrySize[0] | entrySize[1] << 8;
    final total = count[0] | count[1] << 8;
    final out = <int>[];
    for (final address in addresses) {
      final wanted = address + base;
      int? found;
      for (var index = 0; index < total && found == null; index++) {
        final header = programHeaders + index * size;
        if (_readU32(file, header) != 1) continue;
        final offset = _readU64(file, header + 8);
        final mapped = _readU64(file, header + 16);
        final fileSize = _readU64(file, header + 32);
        if (wanted >= mapped && wanted + 4 <= mapped + fileSize) found = offset + wanted - mapped;
      }
      if (found == null) return null;
      out.add(found);
    }
    return out;
  }

  static Uint8List _read(RandomAccessFile file, int offset, int length) {
    file.setPositionSync(offset);
    return file.readSync(length);
  }

  static int _readU32(RandomAccessFile file, int offset) {
    final bytes = _read(file, offset, 4);
    if (bytes.length < 4) throw RangeError('past the end');
    return ByteData.sublistView(bytes).getUint32(0, Endian.little);
  }

  static int _readU64(RandomAccessFile file, int offset) {
    final bytes = _read(file, offset, 8);
    if (bytes.length < 8) throw RangeError('past the end');
    return ByteData.sublistView(bytes).getUint64(0, Endian.little);
  }

  static void _writeU32(RandomAccessFile file, int offset, int value) {
    final bytes = ByteData(4)..setUint32(0, value, Endian.little);
    file
      ..setPositionSync(offset)
      ..writeFromSync(bytes.buffer.asUint8List());
  }
}
