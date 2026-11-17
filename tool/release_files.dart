// Reads the launcher's AOT snapshot out of each file a release publishes, for
// tool/check_release_build.dart's `files` check, which packaging/sign-release.sh runs before it
// signs them (docs/AnyPS5 Desktop - Emulator Host Client.md "What keeps a test build from being
// published"). Each file is read as the packaging that makes it writes it, and anything else
// about it is refused rather than guessed:
//
// - the Windows zip (ci.yml, Compress-Archive of the release folder): data/app.so at its root;
// - the Linux .tar.gz (ci.yml, the bundle as AnyPS5-Desktop/): AnyPS5-Desktop/lib/libapp.so;
// - the .deb (packaging/linux/build-deb.sh, the bundle in /opt/anyps5-desktop): the ar member
//   data.tar.xz (or .zst, .gz, none), and in it opt/anyps5-desktop/lib/libapp.so;
// - the AppImage (packaging/linux/build-appimage.sh, the bundle in usr/lib/anyps5-desktop): the
//   SquashFS 4.0 image after the ELF runtime (where the runtime finds it: the end of the ELF
//   section headers), compressed with gzip, xz or zstd, and in it
//   usr/lib/anyps5-desktop/lib/libapp.so;
// - the Windows installer (packaging/windows/AnyPS5-Desktop.iss, Inno Setup 6, lzma2, solid):
//   Inno Setup names no file outside the setup header, whose records change with every Inno
//   Setup version, so it is not looked into. Instead every file it installs is read: the loader's
//   offset table (ID rDlPtS..., version 2, CRC32 checked) gives where the file data begins, and
//   each chunk there is "zlb" 0x1a, one LZMA2 dictionary byte and raw LZMA2, up to the setup
//   header. tool/check_release_build.dart then looks for the mark in all of it, and for the
//   Windows zip's data/app.so in it byte for byte, so the installer passes only with the zip it
//   was built beside.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// A launcher release file, told by its name as the packaging names it.
enum ReleaseFile {
  installer('the Windows installer'),
  windowsZip('the Windows zip'),
  linuxTar('the Linux .tar.gz'),
  deb('the .deb'),
  appImage('the AppImage');

  const ReleaseFile(this.description);

  /// What the file is, in words.
  final String description;

  /// The kind of release file [name] is, or null for a file no release publishes.
  static ReleaseFile? named(String name) => name.endsWith('.exe')
      ? installer
      : name.endsWith('.zip')
      ? windowsZip
      : name.endsWith('.tar.gz')
      ? linuxTar
      : name.endsWith('.deb')
      ? deb
      : name.endsWith('.AppImage')
      ? appImage
      : null;

  /// Where the file holds the launcher's AOT snapshot; null for the installer, which is read
  /// whole ([installerData]).
  String? get snapshot => switch (this) {
    installer => null,
    windowsZip => 'data/app.so',
    linuxTar => 'AnyPS5-Desktop/lib/libapp.so',
    deb => 'opt/anyps5-desktop/lib/libapp.so',
    appImage => 'usr/lib/anyps5-desktop/lib/libapp.so',
  };

  /// The AOT snapshot in [bytes], a file of this kind.
  Uint8List snapshotIn(Uint8List bytes) => switch (this) {
    installer => throw StateError('an installer is read whole'),
    windowsZip => _zipEntry(bytes, snapshot!),
    linuxTar => _tarEntry(Uint8List.fromList(gzip.decode(bytes)), snapshot!),
    deb => fileInDeb(bytes, snapshot!),
    appImage => fileInAppImage(bytes, snapshot!),
  };
}

/// The file at [path] in the zip [bytes], checked against the CRC-32 the zip gives it (the zip
/// decoder does not check it).
Uint8List _zipEntry(Uint8List bytes, String path) {
  final decoder = ZipDecoder();
  final archive = decoder.decodeBytes(bytes);
  final file = _entry(archive, [for (final header in decoder.directory.fileHeaders) header.filename], path);
  final content = file.content;
  if (file.crc32 != getCrc32(content)) throw FormatException('its $path does not match its CRC-32');
  return content;
}

Uint8List _tarEntry(Uint8List bytes, String path) {
  final decoder = TarDecoder();
  final archive = decoder.decodeBytes(bytes);
  return _entry(archive, [
    for (final file in decoder.files)
      file.filenamePrefix.isEmpty ? file.filename : '${file.filenamePrefix}/${file.filename}',
  ], path).content;
}

/// The one regular file at [path] in [archive], whose entries are [names] (an [Archive] keeps
/// one file of a name given twice), with any `./` or `/` before names and `\` between them read
/// as nothing and `/`.
ArchiveFile _entry(Archive archive, List<String> names, String path) {
  String normal(String name) => name.replaceAll(r'\', '/').replaceFirst(RegExp(r'^(\./|/)+'), '');
  final times = names.where((name) => normal(name) == path).length;
  if (times > 1) throw FormatException('it has $path $times times');
  final file = archive.files.where((file) => normal(file.name) == path).firstOrNull;
  if (times == 0 || file == null) throw FormatException('it has no $path');
  if (!file.isFile || file.isSymbolicLink) throw FormatException('its $path is not a file');
  return file;
}

/// The file at [path] in the data of the .deb [bytes]: its `data.tar` member, uncompressed or
/// compressed as dpkg-deb can (xz, zstd, gzip).
Uint8List fileInDeb(Uint8List bytes, String path) {
  if (bytes.length < 8 || ascii.decode(bytes.sublist(0, 8), allowInvalid: true) != '!<arch>\n') {
    throw const FormatException('it is not an ar archive');
  }
  var at = 8;
  while (at + 60 <= bytes.length) {
    final header = latin1.decode(bytes.sublist(at, at + 60));
    final name = header.substring(0, 16).trim().replaceFirst(RegExp(r'/$'), '');
    final size = int.tryParse(header.substring(48, 58).trim());
    if (size == null || header.substring(58, 60) != '`\n' || at + 60 + size > bytes.length) {
      throw const FormatException('its ar archive is damaged');
    }
    final member = Uint8List.sublistView(bytes, at + 60, at + 60 + size);
    if (name.startsWith('data.tar')) {
      final tar = switch (name) {
        'data.tar' => member,
        'data.tar.xz' => XZDecoder().decodeBytes(member, verify: true, throwOnError: true),
        'data.tar.zst' => ZstdDecoder().decodeBytes(member, verify: true, throwOnError: true),
        'data.tar.gz' => Uint8List.fromList(gzip.decode(member)),
        _ => throw FormatException('its $name is compressed in a way the check cannot read'),
      };
      return _tarEntry(tar, path);
    }
    at += 60 + size + size % 2;
  }
  throw const FormatException('it has no data.tar');
}

/// The file at [path] in the AppImage [bytes]: the SquashFS image the ELF runtime carries after
/// its section headers.
Uint8List fileInAppImage(Uint8List bytes, String path) {
  final data = ByteData.sublistView(bytes);
  if (bytes.length < 64 || data.getUint32(0, Endian.big) != 0x7f454c46 || bytes[4] != 2 || bytes[5] != 1) {
    throw const FormatException('it is not a 64-bit little-endian ELF program');
  }
  final end =
      data.getUint64(0x28, Endian.little) + data.getUint16(0x3a, Endian.little) * data.getUint16(0x3c, Endian.little);
  if (end >= bytes.length) throw const FormatException('it has nothing after its ELF runtime');
  return SquashFs(Uint8List.sublistView(bytes, end)).file(path);
}

/// A SquashFS 4.0 image, read as far as finding a regular file by its path
/// (https://dr-emann.github.io/squashfs/squashfs.html).
class SquashFs {
  SquashFs(this.bytes) : _data = ByteData.sublistView(bytes) {
    if (bytes.length < 96 || _data.getUint32(0, Endian.little) != 0x73717368) {
      throw const FormatException('it has no SquashFS image after its ELF runtime');
    }
    if (_data.getUint16(28, Endian.little) != 4 || _data.getUint16(30, Endian.little) != 0) {
      throw const FormatException('its SquashFS image is not version 4.0');
    }
    final compressor = _data.getUint16(20, Endian.little);
    if (!_compressors.containsKey(compressor)) {
      throw FormatException('its SquashFS image is compressed in a way the check cannot read ($compressor)');
    }
    _decompress = _compressors[compressor]!;
  }

  final Uint8List bytes;
  final ByteData _data;
  late final Uint8List Function(Uint8List) _decompress;
  final _blocks = <int, (Uint8List, int)>{};

  static final _compressors = <int, Uint8List Function(Uint8List)>{
    1: (data) => Uint8List.fromList(zlib.decode(data)),
    4: (data) => XZDecoder().decodeBytes(data, verify: true, throwOnError: true),
    6: (data) => ZstdDecoder().decodeBytes(data, verify: true, throwOnError: true),
  };

  static const _noFragment = 0xffffffff;

  int get _blockSize => _data.getUint32(12, Endian.little);
  int get _inodeTable => _data.getUint64(64, Endian.little);
  int get _directoryTable => _data.getUint64(72, Endian.little);
  int get _fragmentTable => _data.getUint64(80, Endian.little);

  /// The regular file at [path], `/` between names.
  Uint8List file(String path) {
    var inode = _inode(_data.getUint64(32, Endian.little));
    for (final name in path.split('/')) {
      final ref = inode is _Directory ? _list(inode)[name] : null;
      if (ref == null) throw FormatException('it has no $path');
      inode = _inode(ref);
    }
    if (inode is! _File) throw FormatException('its $path is not a file');
    return _content(inode);
  }

  (Uint8List, int) _metadataBlock(int at) => _blocks[at] ??= () {
    final header = _data.getUint16(at, Endian.little);
    final size = header & 0x7fff;
    final raw = Uint8List.sublistView(bytes, at + 2, at + 2 + size);
    return (header & 0x8000 != 0 ? raw : _decompress(raw), at + 2 + size);
  }();

  _Inode _inode(int ref) {
    final cursor = _Cursor(this, _inodeTable + (ref >> 16), ref & 0xffff);
    final type = ByteData.sublistView(cursor.read(16)).getUint16(0, Endian.little);
    switch (type) {
      case 1:
        final d = ByteData.sublistView(cursor.read(16));
        return _Directory(d.getUint32(0, Endian.little), d.getUint16(10, Endian.little), d.getUint16(8, Endian.little));
      case 8:
        final d = ByteData.sublistView(cursor.read(24));
        return _Directory(d.getUint32(8, Endian.little), d.getUint16(18, Endian.little), d.getUint32(4, Endian.little));
      case 2 || 9:
        final d = ByteData.sublistView(cursor.read(type == 2 ? 16 : 40));
        final (start, size, fragment, offset) = type == 2
            ? (
                d.getUint32(0, Endian.little),
                d.getUint32(12, Endian.little),
                d.getUint32(4, Endian.little),
                d.getUint32(8, Endian.little),
              )
            : (
                d.getUint64(0, Endian.little),
                d.getUint64(8, Endian.little),
                d.getUint32(28, Endian.little),
                d.getUint32(32, Endian.little),
              );
        final count = fragment == _noFragment ? (size + _blockSize - 1) ~/ _blockSize : size ~/ _blockSize;
        final sizes = ByteData.sublistView(cursor.read(count * 4));
        return _File(start, size, fragment, offset, [
          for (var i = 0; i < count; i++) sizes.getUint32(i * 4, Endian.little),
        ]);
      default:
        return const _Other();
    }
  }

  Map<String, int> _list(_Directory directory) {
    final entries = <String, int>{};
    var left = directory.size - 3;
    final cursor = _Cursor(this, _directoryTable + directory.block, directory.offset);
    while (left > 0) {
      final header = ByteData.sublistView(cursor.read(12));
      final count = header.getUint32(0, Endian.little) + 1;
      final block = header.getUint32(4, Endian.little);
      left -= 12;
      for (var i = 0; i < count; i++) {
        final entry = ByteData.sublistView(cursor.read(8));
        final length = entry.getUint16(6, Endian.little) + 1;
        entries[utf8.decode(cursor.read(length))] = block << 16 | entry.getUint16(0, Endian.little);
        left -= 8 + length;
      }
    }
    return entries;
  }

  Uint8List _content(_File file) {
    final out = BytesBuilder(copy: false);
    var at = file.start;
    var left = file.size;
    for (final entry in file.blocks) {
      final length = entry & 0xffffff;
      final block = length == 0 ? Uint8List(min(_blockSize, left)) : _dataBlock(at, entry);
      at += length;
      final used = min(block.length, left);
      out.add(Uint8List.sublistView(block, 0, used));
      left -= used;
    }
    if (file.fragment != _noFragment) {
      final pointer = _data.getUint64(_fragmentTable + file.fragment ~/ 512 * 8, Endian.little);
      final entry = ByteData.sublistView(_Cursor(this, pointer, file.fragment % 512 * 16).read(16));
      final block = _dataBlock(entry.getUint64(0, Endian.little), entry.getUint32(8, Endian.little));
      out.add(Uint8List.sublistView(block, file.offset, file.offset + left));
      left = 0;
    }
    if (left != 0 || out.length != file.size) throw const FormatException('its SquashFS image is damaged');
    return out.takeBytes();
  }

  Uint8List _dataBlock(int at, int entry) {
    final raw = Uint8List.sublistView(bytes, at, at + (entry & 0xffffff));
    return entry & 0x1000000 != 0 ? raw : _decompress(raw);
  }
}

sealed class _Inode {
  const _Inode();
}

class _Directory extends _Inode {
  const _Directory(this.block, this.offset, this.size);
  final int block;
  final int offset;
  final int size;
}

class _File extends _Inode {
  const _File(this.start, this.size, this.fragment, this.offset, this.blocks);
  final int start;
  final int size;
  final int fragment;
  final int offset;
  final List<int> blocks;
}

class _Other extends _Inode {
  const _Other();
}

/// Reads on through a SquashFS metadata table from [_at], a block's start, [_skip] bytes in.
class _Cursor {
  _Cursor(this._image, this._at, this._skip);
  final SquashFs _image;
  int _at;
  int _skip;

  Uint8List read(int length) {
    final out = BytesBuilder(copy: false);
    while (out.length < length) {
      final (block, next) = _image._metadataBlock(_at);
      if (_skip >= block.length) {
        if (block.isEmpty) throw const FormatException('its SquashFS image is damaged');
        _skip -= block.length;
        _at = next;
        continue;
      }
      final take = min(block.length - _skip, length - out.length);
      out.add(Uint8List.sublistView(block, _skip, _skip + take));
      _skip += take;
    }
    return out.takeBytes();
  }
}

/// The Inno Setup loader's offset table ID: "rDlPtS" and six bytes.
const innoOffsetTableId = [0x72, 0x44, 0x6c, 0x50, 0x74, 0x53, 0xcd, 0xe6, 0xd7, 0x7b, 0x0b, 0x2a];

/// Every file the Inno Setup installer [bytes] installs, one after the other as its chunks hold
/// them: everything from the start of its file data (the offset table's Offset1) to the next part
/// of the installer, each chunk decompressed.
Uint8List installerData(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  int? table;
  for (var at = indexOfBytes(bytes, innoOffsetTableId); at >= 0; at = indexOfBytes(bytes, innoOffsetTableId, at + 1)) {
    if (at + 64 <= bytes.length &&
        data.getUint32(at + 12, Endian.little) == 2 &&
        getCrc32(Uint8List.sublistView(bytes, at, at + 60)) == data.getUint32(at + 60, Endian.little)) {
      table = at;
      break;
    }
  }
  if (table == null) throw const FormatException('it has no Inno Setup 6 offset table (version 2) the check can read');
  final total = data.getUint64(table + 16, Endian.little);
  final exe = data.getUint64(table + 24, Endian.little);
  final header = data.getUint64(table + 40, Endian.little);
  final files = data.getUint64(table + 48, Endian.little);
  if (total != bytes.length) throw const FormatException('its Inno Setup offset table gives another size');
  final end = [header, exe, total].where((offset) => offset > files).fold(total, min);
  final out = OutputMemoryStream();
  var at = files;
  while (at < end) {
    if (at + 5 > end || ascii.decode(bytes.sublist(at, at + 3), allowInvalid: true) != 'zlb' || bytes[at + 3] != 0x1a) {
      throw const FormatException('its Inno Setup file data is not lzma2 chunks the check can read');
    }
    at = _lzma2(bytes, at + 5, _dictionarySize(bytes[at + 4]), end, out);
  }
  return out.getBytes();
}

int _dictionarySize(int property) {
  if (property > 40) throw const FormatException('its LZMA2 dictionary size is not one LZMA2 has');
  return property == 40 ? 0xffffffff : (2 | property & 1) << (property ~/ 2 + 11);
}

/// Decodes the raw LZMA2 stream in [bytes] from [at] to its end marker into [out], and returns
/// where it ends.
int _lzma2(Uint8List bytes, int at, int dictionary, int end, OutputMemoryStream out) {
  final decoder = LzmaDecoder();
  InputMemoryStream take(int length) {
    if (at + length > end) throw const FormatException('its LZMA2 data ends early');
    return InputMemoryStream(Uint8List.sublistView(bytes, at, at += length));
  }

  while (true) {
    final control = take(1).readByte();
    if (control == 0) return at;
    if (control == 1 || control == 2) {
      final head = take(2);
      final length = (head.readByte() << 8 | head.readByte()) + 1;
      if (control == 1) decoder.reset(resetDictionary: true);
      out.writeBytes(decoder.decodeUncompressed(take(length), length));
    } else if (control >= 0x80) {
      final head = take(4);
      final reset = control >> 5 & 3;
      final unpacked = ((control & 0x1f) << 16 | head.readByte() << 8 | head.readByte()) + 1;
      final packed = (head.readByte() << 8 | head.readByte()) + 1;
      if (reset >= 2) {
        var properties = take(1).readByte();
        if (properties > 224) throw const FormatException('its LZMA2 properties are not ones LZMA has');
        final positionBits = properties ~/ 45;
        properties -= positionBits * 45;
        final literalPositionBits = properties ~/ 9;
        final literalContextBits = properties - literalPositionBits * 9;
        if (literalContextBits + literalPositionBits > 4) {
          throw const FormatException('its LZMA2 properties are not ones LZMA2 has');
        }
        decoder.reset(
          literalContextBits: literalContextBits,
          literalPositionBits: literalPositionBits,
          positionBits: positionBits,
          resetDictionary: reset == 3,
        );
      } else if (reset == 1) {
        decoder.reset();
      }
      decoder.decodeToOutput(take(packed), unpacked, out);
      if (!decoder.isRangeCoderFinished) throw const FormatException('its LZMA2 data is damaged');
    } else {
      throw FormatException('its LZMA2 data has the control byte $control, which LZMA2 has not');
    }
    decoder.trimDictionary(dictionary);
  }
}

/// Where [needle] first is in [bytes] from [from], or -1.
int indexOfBytes(Uint8List bytes, List<int> needle, [int from = 0]) {
  final first = needle.first;
  for (
    var i = bytes.indexOf(first, from);
    i >= 0 && i <= bytes.length - needle.length;
    i = bytes.indexOf(first, i + 1)
  ) {
    var j = 1;
    while (j < needle.length && bytes[i + j] == needle[j]) {
      j++;
    }
    if (j == needle.length) return i;
  }
  return -1;
}
