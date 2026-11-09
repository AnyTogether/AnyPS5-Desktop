import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// One game file or folder in a test .ffpfsc.
class FfpfscItem {
  const FfpfscItem(this.path, {this.data = const [], this.directory = false, this.type, this.mode, this.rawName});

  final String path;
  final List<int> data;
  final bool directory;

  /// The dirent type when not the regular one (a link's, say).
  final int? type;

  /// The inode's mode when not the regular one.
  final int? mode;

  /// The name as it is in the directory, when not the last part of [path].
  final String? rawName;
}

class _Node {
  List<int> data = const [];
  bool directory = false;
  bool internalNode = false;
  int flags = 0;
  int? mode;
  int size = 0;
  int start = 0;
  int blocks = 0;
}

/// A small .ffpfsc written byte by byte as AnyDevKit's FfpfscPackager lays one out, so a test can
/// also write what no packager would. The block size is 4 KiB to keep the images small.
class TestFfpfsc {
  factory TestFfpfsc(List<FfpfscItem> items, {List<FfpfscItem> outerExtra = const []}) {
    final inner = _pfs(items, false);
    final packed = _pfsc(inner.bytes);
    final outer = _pfs([FfpfscItem('pfs_image.dat', data: packed.bytes), ...outerExtra], true);
    final index = outerExtra.isEmpty ? 3 : 4;
    final start = outer.nodes[index].start * blockSize;
    return TestFfpfsc._(outer.bytes, start, start + packed.header, packed.blocks);
  }

  TestFfpfsc._(this.bytes, this.pfscStart, this.innerStart, this.blocks);

  static const blockSize = 0x1000;

  Uint8List bytes;

  /// Where the PFSC container and the inner image start in the file.
  final int pfscStart;
  final int innerStart;

  /// The blocks in the PFSC container: the table has one entry more.
  final int blocks;

  static List<FfpfscItem> game({String titleName = 'Small Quest'}) => [
    const FfpfscItem('sce_module', directory: true),
    const FfpfscItem('sce_sys', directory: true),
    FfpfscItem('eboot.bin', data: List.filled(3000, 7)),
    FfpfscItem('sce_module/libc.prx', data: [for (var i = 0; i < 150000; i++) i & 0xFF]),
    FfpfscItem(
      'sce_sys/param.json',
      data: utf8.encode(
        jsonEncode({
          'titleId': 'PPSA07007',
          'contentVersion': '01.000.000',
          'localizedParameters': {
            'defaultLanguage': 'en-US',
            'en-US': {'titleName': titleName},
          },
        }),
      ),
    ),
    const FfpfscItem('sce_sys/icon0.png', data: pngStub),
    const FfpfscItem('sce_sys/empty.dat'),
  ];

  /// A PNG signature and IHDR saying 16 x 16: all the launcher reads of an icon.
  static const pngStub = <int>[
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
    0,
    0,
    0,
    13,
    0x49,
    0x48,
    0x44,
    0x52, //
    0, 0, 0, 16, 0, 0, 0, 16, 8, 6, 0, 0, 0,
  ];

  void write(String path) => File(path).writeAsBytesSync(bytes);

  TestFfpfsc copy() => TestFfpfsc._(Uint8List.fromList(bytes), pfscStart, innerStart, blocks);

  TestFfpfsc put32(int value, int at) => copy()..set(value, at, 4);
  TestFfpfsc put64(int value, int at) => copy()..set(value, at, 8);

  void set(int value, int at, int width) {
    for (var index = 0; index < width; index++) {
      bytes[at + index] = (value >> (index * 8)) & 0xFF;
    }
  }

  int get64(int at) {
    var value = 0;
    for (var index = 0; index < 8; index++) {
      value |= bytes[at + index] << (index * 8);
    }
    return value;
  }

  /// The offset of [needle], the first found at or past [from].
  int find(String needle, int from) {
    final target = ascii.encode(needle);
    for (var at = from; at + target.length <= bytes.length; at++) {
      var match = true;
      for (var index = 0; index < target.length; index++) {
        if (bytes[at + index] != target[index]) {
          match = false;
          break;
        }
      }
      if (match) return at;
    }
    throw StateError('$needle is not in the image');
  }

  /// The inner image's inode [number] table entry.
  int innerInode(int number) {
    final perBlock = blockSize ~/ 0xA8;
    return innerStart + (1 + number ~/ perBlock) * blockSize + (number % perBlock) * 0xA8;
  }

  static int _align(int value, int to) => (value + to - 1) ~/ to * to;

  static void _put(List<int> bytes, int value, int at, int width) {
    for (var index = 0; index < width; index++) {
      bytes[at + index] = (value >> (index * 8)) & 0xFF;
    }
  }

  static void _dirent(List<int> data, int inode, int type, String name) {
    final bytes = ascii.encode(name);
    final size = _align(bytes.length + 17, 8);
    final entry = List<int>.filled(size, 0);
    _put(entry, inode, 0, 4);
    _put(entry, type, 4, 4);
    _put(entry, bytes.length, 8, 4);
    _put(entry, size, 12, 4);
    entry.setRange(16, 16 + bytes.length, bytes);
    data.addAll(entry);
  }

  static String _parent(String path) => path.contains('/') ? path.substring(0, path.lastIndexOf('/')) : '';

  static String _base(String path) => path.contains('/') ? path.substring(path.lastIndexOf('/') + 1) : path;

  static ({Uint8List bytes, List<_Node> nodes}) _pfs(List<FfpfscItem> items, bool pfscFile) {
    const bs = blockSize;
    final sorted = [...items]
      ..sort((a, b) {
        if (a.directory != b.directory) return a.directory ? -1 : 1;
        return a.path.compareTo(b.path);
      });
    const root = 2;
    final nodes = [for (var i = 0; i <= root; i++) _Node()];
    nodes[0]
      ..directory = true
      ..internalNode = true;
    nodes[1].internalNode = true;
    nodes[root].directory = true;
    final directories = <String, int>{'': root};
    for (final (index, item) in sorted.indexed) {
      if (item.directory) directories[item.path] = root + 1 + index;
    }
    for (final item in sorted) {
      final node = _Node()
        ..mode = item.mode
        ..flags = 0x10 | (pfscFile ? 1 : 0);
      if (item.directory) {
        node.directory = true;
      } else {
        node.data = item.data;
      }
      nodes.add(node);
    }
    final dirData = <int, List<int>>{};
    List<int> dataOf(int inode) => dirData[inode] ??= <int>[];
    for (final MapEntry(key: path, value: inode) in directories.entries) {
      _dirent(dataOf(inode), inode, 4, '.');
      _dirent(dataOf(inode), directories[_parent(path)] ?? inode, 5, '..');
    }
    for (final (index, item) in sorted.indexed) {
      final owner = directories[_parent(item.path)];
      if (owner == null) throw StateError('no parent for ${item.path}');
      _dirent(dataOf(owner), root + 1 + index, item.type ?? (item.directory ? 3 : 2), item.rawName ?? _base(item.path));
    }
    _dirent(dataOf(0), 1, 2, 'flat_path_table');
    _dirent(dataOf(0), root, 3, 'uroot');
    for (final MapEntry(key: inode, value: data) in dirData.entries) {
      nodes[inode].data = data;
    }
    final perBlock = bs ~/ 0xA8;
    final inodeBlocks = (nodes.length + perBlock - 1) ~/ perBlock;
    var next = 1 + inodeBlocks;
    for (final node in nodes) {
      final bytes = node.data.length;
      final blocks = bytes == 0 ? 1 : _align(bytes, bs) ~/ bs;
      node
        ..start = next
        ..blocks = blocks
        ..size = node.directory ? blocks * bs : bytes;
      next += blocks;
    }
    final image = Uint8List(next * bs);
    _put(image, 2, 0, 8);
    _put(image, 20130315, 8, 8);
    _put(image, bs, 0x20, 4);
    _put(image, 1, 0x28, 8);
    _put(image, nodes.length, 0x30, 8);
    _put(image, next, 0x38, 8);
    _put(image, inodeBlocks, 0x40, 8);
    for (final (index, node) in nodes.indexed) {
      final at = (1 + index ~/ perBlock) * bs + (index % perBlock) * 0xA8;
      _put(image, node.mode ?? ((node.directory ? 0x4000 : 0x8000) | 365), at, 2);
      _put(image, 1, at + 2, 2);
      _put(image, node.flags | (node.internalNode ? 0x20000 : 0), at + 4, 4);
      _put(image, node.size, at + 8, 8);
      _put(image, node.size, at + 16, 8);
      _put(image, node.blocks, at + 0x60, 4);
      _put(image, node.start, at + 0x64, 4);
      for (var pointer = 1; pointer < 12; pointer++) {
        _put(image, 0xFFFFFFFF, at + 0x64 + pointer * 4, 4);
      }
      image.setRange(node.start * bs, node.start * bs + node.data.length, node.data);
    }
    return (bytes: image, nodes: nodes);
  }

  static ({Uint8List bytes, int header, int blocks}) _pfsc(List<int> source) {
    final padded = _align(source.length, 0x10000);
    final blocks = padded ~/ 0x10000;
    final header = _align(0x400 + (blocks + 1) * 8, 0x10000);
    final bytes = Uint8List(header + padded);
    _put(bytes, 0x43534650, 0, 4);
    _put(bytes, 6, 8, 4);
    _put(bytes, 0x10000, 12, 4);
    _put(bytes, 0x10000, 16, 8);
    _put(bytes, 0x400, 24, 8);
    _put(bytes, header, 32, 8);
    _put(bytes, padded, 40, 8);
    for (var index = 0; index <= blocks; index++) {
      _put(bytes, header + index * 0x10000, 0x400 + index * 8, 8);
    }
    bytes.setRange(header, header + source.length, source);
    return (bytes: bytes, header: header, blocks: blocks);
  }
}
