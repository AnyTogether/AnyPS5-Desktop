import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart' show ArchiveException;
import 'package:path/path.dart' as p;

import 'game_archives.dart';

/// Why a .ffpfsc is not unpacked though it reads as one: the two the launcher can say for sure,
/// unlike a file that is damaged or still being copied.
enum ArchiveProblem {
  /// Its PFSC blocks are compressed. AnyDevKit's packager never writes those, other tools do.
  compressed,

  /// A layout the launcher does not read: signed, encrypted, 64-bit inodes, or any other than the
  /// one AnyDevKit's FfpfscPackager writes.
  unsupported,
}

/// A game in one file, as AnyDevKit's FfpfscPackager writes it: an outer PFS image with a single
/// file `pfs_image.dat`, that file a PFSC container of stored (never compressed) 64 KiB blocks,
/// and in them an inner PFS image holding the dump. So the inner image's bytes are one contiguous
/// slice of the file, and each game file is one contiguous slice of that.
///
/// Everything about the file is untrusted: every count, offset and size is bounded against the
/// file before use, no read is larger than the bounds below, each inode is visited once (a
/// directory cannot loop and two names cannot share one file), and the bytes the files come to
/// can never exceed the image they sit in. A name that would land outside the game's folder, or a
/// link, is listed in [ArchivePlan.refused] as a zip's is; anything else out of shape is refused
/// whole.
abstract final class Ffpfsc {
  static const maxDirectoryBytes = 16 * 1024 * 1024;

  /// All directories together: a file cannot make the reader hold more than this.
  static const maxTotalDirectoryBytes = 64 * 1024 * 1024;
  static const maxEntries = 500000;
  static const maxInodes = 2000000;
  static const maxDepth = 32;
  static const maxPath = 1024;
  static const maxParameters = 1024 * 1024;
  static const maxIcon = 8 * 1024 * 1024;
  static const maxIconSide = 4096;

  static const _pfscMagic = 0x43534650;
  static const _pfscBlock = 0x10000;
  static const _inodeSize = 0xA8;
  static const _tableChunk = 0x10000;
  static const _chunk = 1024 * 1024;
  static const _reportEvery = 8 * 1024 * 1024;

  static final _reserved = {
    'CON',
    'PRN',
    'AUX',
    'NUL',
    for (var number = 1; number <= 9; number++) ...['COM$number', 'LPT$number'],
  };

  static bool matches(String path) => p.extension(path).toLowerCase() == '.ffpfsc';

  /// The name when it is safe as one path component on every system, else null.
  static String? safeName(Uint8List raw) {
    if (raw.any((byte) => byte < 0x20 || byte > 0x7E)) return null;
    final name = String.fromCharCodes(raw);
    if (name.contains('/') || name.contains(r'\') || name.endsWith('.') || name.endsWith(' ')) return null;
    if (GameArchives.safeParts(name)?.length != 1) return null;
    final stem = name.split('.').first.toUpperCase();
    return _reserved.contains(stem) ? null : name;
  }

  /// PNG signature, and an IHDR no larger than [maxIconSide] a side: the picture is decoded for
  /// the panel, and a very large one (or a decompression bomb) is simply not shown.
  static bool isReasonablePng(Uint8List bytes) {
    const signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    const ihdr = [0x49, 0x48, 0x44, 0x52];
    if (bytes.length < 24) return false;
    for (var i = 0; i < 8; i++) {
      if (bytes[i] != signature[i]) return false;
    }
    for (var i = 0; i < 4; i++) {
      if (bytes[12 + i] != ihdr[i]) return false;
    }
    final view = ByteData.sublistView(bytes);
    return view.getUint32(16) <= maxIconSide && view.getUint32(20) <= maxIconSide;
  }

  /// What the file at [path] holds, as a zip's plan. A compressed or unsupported file is a plan
  /// that says so; a damaged one throws, as a zip that does not read yet does.
  static ArchivePlan plan(String path) {
    final _Source source;
    try {
      source = _Source.open(path);
    } on _Failure catch (failure) {
      throw ArchiveException(_message(path, failure.message));
    }
    try {
      final _Manifest manifest;
      try {
        manifest = _read(source);
      } on _Compressed {
        return const ArchivePlan(
          files: 0,
          size: 0,
          strip: '',
          looksLikeGame: false,
          refused: [],
          problem: ArchiveProblem.compressed,
        );
      } on _Unsupported {
        return const ArchivePlan(
          files: 0,
          size: 0,
          strip: '',
          looksLikeGame: false,
          refused: [],
          problem: ArchiveProblem.unsupported,
        );
      } on _Failure catch (failure) {
        throw ArchiveException(_message(path, failure.message));
      }
      final names = {
        for (final item in manifest.items)
          if (!item.directory) item.path.toLowerCase(),
      };
      String? titleId;
      String? version;
      String? titleName;
      final parameters = _item(manifest, 'sce_sys/param.json', maxParameters);
      if (parameters != null) {
        final about = _parameters(source, parameters);
        if (about != null) {
          titleId = _string(about['titleId']);
          version = _string(about['contentVersion']);
          final localized = about['localizedParameters'] is Map<String, dynamic>
              ? about['localizedParameters'] as Map<String, dynamic>
              : const <String, dynamic>{};
          final language = _string(localized['defaultLanguage']) ?? _string(about['defaultLanguage']) ?? 'en-US';
          for (final key in [language, 'en-US']) {
            final value = localized[key];
            if (value is Map<String, dynamic>) {
              final title = _string(value['titleName']);
              if (title != null && title.isNotEmpty) {
                titleName = title;
                break;
              }
            }
          }
        }
      }
      Uint8List? icon;
      final picture = _item(manifest, 'sce_sys/icon0.png', maxIcon);
      if (picture != null) {
        try {
          final bytes = source.bytes(picture.offset, picture.size);
          if (isReasonablePng(bytes)) icon = bytes;
        } on Object {
          // No icon: the panel shows its symbol.
        }
      }
      return ArchivePlan(
        files: manifest.files,
        size: manifest.size,
        strip: '',
        looksLikeGame: names.contains('eboot.bin') && names.contains('sce_sys/param.json'),
        refused: List.unmodifiable(manifest.refused),
        titleId: titleId,
        version: version,
        titleName: titleName,
        icon: icon,
      );
    } finally {
      source.close();
    }
  }

  static String? _string(Object? value) => value is String ? value : null;

  static Map<String, dynamic>? _parameters(_Source source, _Item item) {
    try {
      var bytes = source.bytes(item.offset, item.size);
      if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) bytes = bytes.sublist(3);
      final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
      return decoded is Map<String, dynamic> ? decoded : null;
    } on Object {
      return null;
    }
  }

  static _Item? _item(_Manifest manifest, String path, int limit) {
    for (final item in manifest.items) {
      if (!item.directory && item.path == path && item.size < limit) return item;
    }
    return null;
  }

  static String _message(String path, String reason) => '${p.basename(path)} is damaged or not fully copied: $reason';

  /// Unpacks the file at [path] into [into] (made fresh; it must not be there) with the same
  /// progress and stops as a zip: [into] is removed again on any failure or a stop.
  static void unpackSync(
    String path,
    String into, {
    void Function(int done, int total)? progress,
    bool Function()? cancelled,
  }) {
    final _Source source;
    try {
      source = _Source.open(path);
    } on _Failure catch (failure) {
      throw ArchiveException(_message(path, failure.message));
    }
    try {
      final _Manifest manifest;
      try {
        manifest = _read(source);
      } on _Compressed {
        throw ArchiveException('${p.basename(path)} is compressed');
      } on _Unsupported catch (failure) {
        throw ArchiveException('${p.basename(path)} is not a kind AnyPS5 unpacks: ${failure.message}');
      } on _Failure catch (failure) {
        throw ArchiveException(_message(path, failure.message));
      }
      if (manifest.files == 0) throw ArchiveException('The file holds no game files');
      if (manifest.refused.isNotEmpty) {
        throw ArchiveException(
          '${manifest.refused.length} names would land outside the folder: ${manifest.refused.first}',
        );
      }
      if (FileSystemEntity.typeSync(into) != FileSystemEntityType.notFound) {
        throw FileSystemException('A folder of that name is there already', into);
      }
      try {
        Directory(into).createSync(recursive: true);
        var done = 0;
        var reported = 0;
        progress?.call(0, manifest.size);
        final buffer = Uint8List(_chunk);
        for (final entry in manifest.items) {
          if (cancelled?.call() ?? false) throw const UnpackCancelled();
          final target = GameArchives.safePath(into, entry.path);
          if (target == null) throw ArchiveException('${entry.path} would land outside the folder');
          if (entry.directory) {
            Directory(target).createSync(recursive: true);
            continue;
          }
          Directory(p.dirname(target)).createSync(recursive: true);
          // Exclusive: no file is written over, not even one the disk's case folding made the same.
          File(target).createSync(exclusive: true);
          final output = File(target).openSync(mode: FileMode.writeOnlyAppend);
          try {
            var remaining = entry.size;
            var position = entry.offset;
            while (remaining > 0) {
              final wanted = remaining < _chunk ? remaining : _chunk;
              try {
                source.fill(position, buffer, wanted);
              } on _Failure catch (failure) {
                throw ArchiveException(_message(path, failure.message));
              }
              output.writeFromSync(buffer, 0, wanted);
              position += wanted;
              remaining -= wanted;
              done += wanted;
              if (done - reported >= _reportEvery) {
                reported = done;
                if (cancelled?.call() ?? false) throw const UnpackCancelled();
                progress?.call(done, manifest.size);
              }
            }
          } finally {
            output.closeSync();
          }
        }
        progress?.call(manifest.size, manifest.size);
      } on Object {
        if (Directory(into).existsSync()) {
          try {
            Directory(into).deleteSync(recursive: true);
          } on FileSystemException {
            // Left for the next try, which clears it first.
          }
        }
        rethrow;
      }
    } finally {
      source.close();
    }
  }

  static _Manifest _read(_Source source) {
    final outer = _Image(_Slice(source, 0, source.length));
    final budget = _Budget();
    final outerRoot = outer.root(budget);
    final children = [
      for (final entry in outer.entries(outerRoot, budget))
        if (entry.type != 4 && entry.type != 5) entry,
    ];
    if (children.length != 1 ||
        children.single.type != 2 ||
        String.fromCharCodes(children.single.name) != 'pfs_image.dat') {
      throw const _Unsupported('an outer image without just pfs_image.dat');
    }
    final packed = outer.inode(children.single.inode);
    if (!packed.isRegular || packed.flags & 1 != 1) throw const _Unsupported('pfs_image.dat is not a PFSC container');
    final inner = _Image(_innerSlice(outer, packed, source));
    final root = inner.root(budget);
    final manifest = _Manifest();
    final seen = <int>{root.number};
    final paths = <String>{};

    void walk(_Inode directory, List<String> prefix, int depth) {
      for (final entry in inner.entries(directory, budget)) {
        if (entry.type == 4 || entry.type == 5) continue;
        final shown = [...prefix, String.fromCharCodes(entry.name)].join('/');
        final name = safeName(entry.name);
        if ((entry.type != 2 && entry.type != 3) || name == null) {
          manifest.refused.add(shown);
          continue;
        }
        final relative = [...prefix, name].join('/');
        if (relative.length > maxPath) {
          manifest.refused.add(shown);
          continue;
        }
        if (depth >= maxDepth) throw const _Failure('folders nested too deeply');
        if (!seen.add(entry.inode)) throw const _Failure('two names for one file');
        if (!paths.add(relative.toLowerCase())) throw const _Failure('the same path twice');
        if (manifest.items.length >= maxEntries) throw const _Failure('too many files');
        final inode = inner.inode(entry.inode);
        if (entry.type == 3) {
          if (!inode.isDirectory) throw const _Failure('a directory entry is no directory');
          manifest.items.add(_Item(relative, true, 0, 0));
          walk(inode, [...prefix, name], depth + 1);
          continue;
        }
        if (inode.isLink) {
          manifest.refused.add(shown);
          continue;
        }
        if (!inode.isRegular) throw const _Failure('a file entry is no file');
        if (inode.flags & 1 != 0) throw const _Compressed();
        if (inode.flags & ~0x10 != 0) throw _Unsupported('file flags ${inode.flags.toRadixString(16)}');
        if (inode.size > inner.slice.length - manifest.size) {
          throw const _Failure('the files add up to more than the image');
        }
        manifest.files++;
        manifest.size += inode.size;
        manifest.items.add(_Item(relative, false, inner.slice.base + inner.offset(inode), inode.size));
      }
    }

    walk(root, const [], 0);
    return manifest;
  }

  /// The slice of the outer image the inner image's bytes are, once its PFSC header and table
  /// are shown to be stored blocks.
  static _Slice _innerSlice(_Image outer, _Inode inode, _Source source) {
    final start = outer.offset(inode);
    if (inode.size < 0x30) throw const _Failure('pfs_image.dat is too short');
    final header = _Reader(outer.slice.read(start, 0x30));
    if (header.u32(0) != _pfscMagic) throw const _Failure('no PFSC header');
    if (header.u32(12) != _pfscBlock || header.size(16) != _pfscBlock) {
      throw const _Unsupported('a PFSC block size other than 64 KiB');
    }
    final table = header.size(24);
    final dataStart = header.size(32);
    final dataLength = header.size(40);
    if (dataLength <= 0 ||
        dataLength % _pfscBlock != 0 ||
        table < 0x30 ||
        dataStart < 0 ||
        dataStart > inode.size ||
        dataLength > inode.size - dataStart) {
      throw const _Failure('the PFSC header is out of range');
    }
    final count = dataLength ~/ _pfscBlock;
    final tableBytes = (count + 1) * 8;
    if (table > dataStart || tableBytes > dataStart - table) throw const _Failure('the PFSC table is out of range');
    var previous = -1;
    var compressed = false;
    var first = true;
    var position = start + table;
    var remaining = tableBytes;
    while (remaining > 0) {
      final chunk = remaining < _tableChunk ? remaining : _tableChunk;
      final bytes = _Reader(outer.slice.read(position, chunk));
      for (var index = 0; index < chunk; index += 8) {
        final value = bytes.size(index);
        if (first) {
          if (value != dataStart) throw const _Failure('the PFSC table starts in the wrong place');
          first = false;
        } else {
          final delta = value - previous;
          if (delta <= 0 || delta > _pfscBlock) throw const _Failure('the PFSC table is out of order');
          if (delta < _pfscBlock) compressed = true;
        }
        previous = value;
      }
      position += chunk;
      remaining -= chunk;
    }
    if (compressed) throw const _Compressed();
    return _Slice(source, outer.slice.base + start + dataStart, dataLength);
  }
}

/// A file out of shape, or still being copied.
class _Failure implements Exception {
  const _Failure(this.message);

  final String message;
}

class _Compressed extends _Failure {
  const _Compressed() : super('compressed');
}

class _Unsupported extends _Failure {
  const _Unsupported(super.message);
}

/// The file opened to read.
class _Source {
  _Source(this._file, this.length);

  factory _Source.open(String path) {
    try {
      final file = File(path).openSync();
      return _Source(file, file.lengthSync());
    } on FileSystemException catch (error) {
      throw _Failure('cannot be opened: ${error.osError?.message ?? error.message}');
    }
  }

  final RandomAccessFile _file;
  final int length;

  void fill(int offset, Uint8List buffer, int count) {
    if (offset < 0 || count < 0 || count > buffer.length || offset > length || count > length - offset) {
      throw const _Failure('a read lands past the end');
    }
    try {
      _file.setPositionSync(offset);
      var at = 0;
      while (at < count) {
        final read = _file.readIntoSync(buffer, at, count);
        if (read <= 0) throw const _Failure('ends early');
        at += read;
      }
    } on FileSystemException catch (error) {
      throw _Failure('cannot be read: ${error.osError?.message ?? error.message}');
    }
  }

  Uint8List bytes(int offset, int count) {
    final buffer = Uint8List(count);
    fill(offset, buffer, count);
    return buffer;
  }

  void close() => _file.closeSync();
}

/// A range of the file; every read is bounded against the range.
class _Slice {
  const _Slice(this.source, this.base, this.length);

  final _Source source;
  final int base;
  final int length;

  void check(int offset, int count) {
    if (offset < 0 || count < 0 || offset > length || count > length - offset) {
      throw const _Failure('a read lands past the end');
    }
  }

  Uint8List read(int offset, int count) {
    check(offset, count);
    return source.bytes(base + offset, count);
  }
}

/// Little-endian fields out of bytes the caller has bounded.
class _Reader {
  _Reader(Uint8List bytes) : _view = ByteData.sublistView(bytes);

  final ByteData _view;

  int u16(int at) => _view.getUint16(at, Endian.little);
  int u32(int at) => _view.getUint32(at, Endian.little);

  /// A u64 field as a signed size; one with the high bit set cannot be a real size or offset.
  int size(int at) {
    final value = _view.getInt64(at, Endian.little);
    if (value < 0) throw const _Failure('a size is out of range');
    return value;
  }
}

class _Inode {
  const _Inode(this.number, this.mode, this.flags, this.size, this.blocks, this.start);

  final int number;
  final int mode;
  final int flags;
  final int size;
  final int blocks;
  final int start;

  bool get isDirectory => mode & 0xF000 == 0x4000;
  bool get isRegular => mode & 0xF000 == 0x8000;
  bool get isLink => mode & 0xF000 == 0xA000;
}

class _Entry {
  const _Entry(this.inode, this.type, this.name);

  final int inode;
  final int type;
  final Uint8List name;
}

/// What is left of [Ffpfsc.maxTotalDirectoryBytes] for one file.
class _Budget {
  int left = Ffpfsc.maxTotalDirectoryBytes;
}

/// One PFS image, its header checked, its inodes and directories read on demand.
class _Image {
  _Image(this.slice) {
    if (slice.length < 0x400) throw const _Failure('too short for a PFS header');
    final header = _Reader(slice.read(0, 0x400));
    if (header.size(0) != 2 || header.size(8) != 20130315) throw const _Failure('not a PFS image');
    if (header.u16(0x1C) & ~8 != 0) throw const _Unsupported('signed, encrypted or 64-bit PFS');
    final block = header.u32(0x20);
    if (block < 0x1000 || block > 0x100000 || block & (block - 1) != 0) {
      throw _Unsupported('block size $block');
    }
    blockSize = block;
    inodes = header.size(0x30);
    blocks = header.size(0x38);
    inodeBlocks = header.size(0x40);
    perBlock = blockSize ~/ Ffpfsc._inodeSize;
    if (inodes < 3 || inodes > Ffpfsc.maxInodes || inodeBlocks < 1 || inodeBlocks > Ffpfsc.maxInodes) {
      throw const _Failure('impossible inode count');
    }
    if (inodes > inodeBlocks * perBlock) throw const _Failure('more inodes than the table holds');
    if (blocks <= inodeBlocks || blocks > slice.length ~/ blockSize) {
      throw const _Failure('the image is larger than the file');
    }
  }

  final _Slice slice;
  late final int blockSize;
  late final int inodes;
  late final int blocks;
  late final int inodeBlocks;
  late final int perBlock;

  _Inode inode(int number) {
    if (number < 0 || number >= inodes) throw const _Failure('an inode number is out of range');
    final bytes = _Reader(
      slice.read((1 + number ~/ perBlock) * blockSize + (number % perBlock) * Ffpfsc._inodeSize, Ffpfsc._inodeSize),
    );
    final size = bytes.size(8);
    final count = bytes.u32(0x60);
    final start = bytes.u32(0x64);
    for (var pointer = 1; pointer < 12; pointer++) {
      if (bytes.u32(0x64 + pointer * 4) != 0xFFFFFFFF) throw const _Unsupported('a file not in one piece');
    }
    if (count < 1 ||
        count > blocks ||
        start <= inodeBlocks ||
        start > blocks - count ||
        size < 0 ||
        size > count * blockSize) {
      throw const _Failure('an inode is out of range');
    }
    return _Inode(number, bytes.u16(0), bytes.u32(4), size, count, start);
  }

  int offset(_Inode inode) => inode.start * blockSize;

  List<_Entry> entries(_Inode directory, _Budget budget) {
    if (!directory.isDirectory) throw const _Failure('expected a directory');
    if (directory.size > Ffpfsc.maxDirectoryBytes || directory.size > budget.left) {
      throw const _Failure('a directory is too large');
    }
    budget.left -= directory.size;
    final data = slice.read(offset(directory), directory.size);
    final view = _Reader(data);
    final result = <_Entry>[];
    var position = 0;
    while (position + 16 <= data.length) {
      final number = view.u32(position);
      final type = view.u32(position + 4);
      final length = view.u32(position + 8);
      final size = view.u32(position + 12);
      if (size == 0) break;
      if (length < 1 || length > 255 || size < 16 + length || size > data.length - position) {
        throw const _Failure('a directory entry is out of range');
      }
      result.add(_Entry(number, type, Uint8List.sublistView(data, position + 16, position + 16 + length)));
      position += size;
    }
    return result;
  }

  /// The `uroot` directory, found through the super-root (inode 0).
  _Inode root(_Budget budget) {
    final top = inode(0);
    final uroot = entries(
      top,
      budget,
    ).where((entry) => entry.type == 3 && String.fromCharCodes(entry.name) == 'uroot').firstOrNull;
    if (uroot == null) throw const _Failure('no uroot directory');
    final root = inode(uroot.inode);
    if (!root.isDirectory) throw const _Failure('uroot is no directory');
    return root;
  }
}

class _Item {
  const _Item(this.path, this.directory, this.offset, this.size);

  final String path;
  final bool directory;

  /// From the start of the file.
  final int offset;
  final int size;
}

class _Manifest {
  final items = <_Item>[];
  final refused = <String>[];
  var files = 0;
  var size = 0;
}
