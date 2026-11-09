import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import 'ffpfsc.dart';

export 'ffpfsc.dart' show ArchiveProblem, Ffpfsc;

/// A zip a game was dropped into the games folder as, and the folder beside it that it unpacks
/// into: PPSA01234.zip becomes PPSA01234/, and PPSA01234-UPDATE.zip an update the game finds.
class GameArchive {
  const GameArchive({required this.path, required this.size});

  final String path;

  /// The zip's own size on the disk.
  final int size;

  String get name => p.basename(path);

  /// The folder it unpacks into, named as the zip without ".zip".
  String get folder => p.join(p.dirname(path), p.basenameWithoutExtension(path));

  /// Where it unpacks first: a hidden folder the library does not read, renamed to [folder] once
  /// every file is in it, so no half-unpacked dump shows as a game.
  String get partial => p.join(p.dirname(path), '.${p.basenameWithoutExtension(path)}.unpacking');

  /// A game packed in one .ffpfsc file rather than a zip.
  bool get isFfpfsc => Ffpfsc.matches(path);

  @override
  bool operator ==(Object other) => other is GameArchive && other.path == path;

  @override
  int get hashCode => path.hashCode;

  @override
  String toString() => 'GameArchive($path)';
}

/// What a zip holds, read from its list of files (not their contents).
class ArchivePlan {
  const ArchivePlan({
    required this.files,
    required this.size,
    required this.strip,
    required this.looksLikeGame,
    required this.refused,
    this.titleId,
    this.version,
    this.problem,
    this.titleName,
    this.icon,
  });

  /// The files it unpacks (folders and links left out).
  final int files;

  /// The bytes they come to unpacked.
  final int size;

  /// The one folder every file is in ("PPSA01234/"), left out when it unpacks: the folder beside
  /// the zip is the dump itself. Empty when the files are not all in one folder.
  final String strip;

  /// Whether it holds a dump: an eboot.bin and a sce_sys/param.json.
  final bool looksLikeGame;

  /// The names that would land outside the folder (an absolute path, a drive, "..", a name
  /// Windows cannot make). An archive with any is never unpacked.
  final List<String> refused;

  /// The dump's title ID and contentVersion from its param.json, null when it has none that
  /// reads: what tells an update for a game in the library from a game of its own.
  final String? titleId;
  final String? version;

  /// A .ffpfsc that reads but will not be unpacked, and why (the panel says so). Null for a zip.
  final ArchiveProblem? problem;

  /// A .ffpfsc's game name and icon0.png from its files, null when they cannot be read.
  final String? titleName;
  final Uint8List? icon;
}

/// Unpacking stopped on purpose; what was written is gone.
class UnpackCancelled implements Exception {
  const UnpackCancelled();

  @override
  String toString() => 'UnpackCancelled';
}

/// A stop asked for from outside the isolate that unpacks: a marker file it looks for between
/// chunks.
class UnpackCancel {
  UnpackCancel(this.marker);

  final String marker;

  void cancel() {
    try {
      File(marker).writeAsStringSync('stop');
    } on FileSystemException {
      // The unpack ends on its own anyway.
    }
  }

  bool get cancelled => File(marker).existsSync();
}

abstract final class GameArchives {
  static const extensions = {'.zip', '.ffpfsc'};

  /// How far below a games folder an archive is looked for: in it, and in its folders.
  static const depth = 1;

  /// Room kept free beyond what the files take, for the file system's own use.
  static const spaceMargin = 512 * 1024 * 1024;

  /// The archives in [roots] (and one folder below) with no folder of their name beside them
  /// yet, sorted by path. Hidden files and the launcher's own folder are skipped.
  static List<GameArchive> find(Iterable<String> roots) {
    final found = <GameArchive>[];
    void visit(String folder, int level) {
      List<FileSystemEntity> entries;
      try {
        entries = Directory(folder).listSync(followLinks: false);
      } on FileSystemException {
        return;
      }
      for (final entry in entries) {
        final name = p.basename(entry.path);
        if (name.startsWith('.')) continue;
        if (entry is Directory && level < depth) visit(entry.path, level + 1);
        if (entry is! File || !extensions.contains(p.extension(name).toLowerCase())) continue;
        final archive = GameArchive(path: entry.path, size: _length(entry));
        if (FileSystemEntity.typeSync(archive.folder) != FileSystemEntityType.notFound) continue;
        found.add(archive);
      }
    }

    for (final root in roots) {
      visit(root, 0);
    }
    found.sort((a, b) => a.path.compareTo(b.path));
    return found;
  }

  static int _length(File file) {
    try {
      return file.lengthSync();
    } on FileSystemException {
      return 0;
    }
  }

  static final _drive = RegExp(r'^[A-Za-z]:');

  /// Letters Windows does not allow in a name (and ":" would write an alternate data stream).
  static final _unmakeable = RegExp(r'[<>:"|?*\x00-\x1f]');

  /// The parts of an entry's name below [strip], or null when the name would leave the folder it
  /// unpacks into: an absolute path, a drive, a "..", or a name Windows cannot make.
  static List<String>? safeParts(String name, {String strip = ''}) {
    var relative = name.replaceAll(r'\', '/');
    if (relative.startsWith('/') || _drive.hasMatch(relative)) return null;
    if (strip.isNotEmpty) {
      if (!relative.startsWith(strip)) return null;
      relative = relative.substring(strip.length);
    }
    final parts = [
      for (final part in relative.split('/'))
        if (part.isNotEmpty && part != '.') part,
    ];
    if (parts.any((part) => part == '..' || _unmakeable.hasMatch(part) || part.trim() != part)) return null;
    return parts;
  }

  /// Where [name] is written under [into], null when it would land outside it ([safeParts]).
  static String? safePath(String into, String name, {String strip = ''}) {
    final parts = safeParts(name, strip: strip);
    if (parts == null) return null;
    if (parts.isEmpty) return into;
    final target = p.joinAll([into, ...parts]);
    return p.isWithin(into, target) ? target : null;
  }

  /// The one top folder every entry is in ("PPSA01234/"), or empty.
  static String _commonFolder(Iterable<String> names) {
    String? first;
    var any = false;
    for (final raw in names) {
      final name = raw.replaceAll(r'\', '/');
      final slash = name.indexOf('/');
      // A file at the top: nothing to leave out.
      if (slash <= 0) {
        if (name.isEmpty) continue;
        return '';
      }
      final top = name.substring(0, slash + 1);
      first ??= top;
      if (top != first) return '';
      if (name.length > top.length) any = true;
    }
    return any && first != null && safeParts(first) != null ? first : '';
  }

  /// What the zip at [path] holds. Throws when it is not a zip.
  static ArchivePlan plan(String path) {
    if (Ffpfsc.matches(path)) return Ffpfsc.plan(path);
    final input = InputFileStream(path);
    try {
      return _plan(ZipDecoder().decodeStream(input));
    } finally {
      input.closeSync();
    }
  }

  static ArchivePlan _plan(Archive archive) {
    final entries = archive.files;
    final strip = _commonFolder(entries.map((entry) => entry.name));
    var files = 0;
    var size = 0;
    var eboot = false;
    var parameters = false;
    ArchiveFile? parameterFile;
    var parameterDepth = 99;
    final refused = <String>[];
    for (final entry in entries) {
      final parts = safeParts(entry.name, strip: strip);
      if (parts == null) {
        refused.add(entry.name);
        continue;
      }
      if (entry.isSymbolicLink || !entry.isFile || parts.isEmpty) continue;
      files++;
      size += entry.size;
      // A dump at the top, or in a folder or two below it.
      if (parts.length <= 3 && parts.last.toLowerCase() == 'eboot.bin') eboot = true;
      final last = parts.length;
      if (last >= 2 && last <= 4 && parts[last - 2] == 'sce_sys' && parts[last - 1] == 'param.json') {
        parameters = true;
        if (last < parameterDepth && entry.size < 1024 * 1024) {
          parameterFile = entry;
          parameterDepth = last;
        }
      }
    }
    final about = _parameters(parameterFile);
    return ArchivePlan(
      files: files,
      size: size,
      strip: strip,
      looksLikeGame: eboot && parameters,
      refused: List.unmodifiable(refused),
      titleId: about?['titleId'] is String ? about!['titleId'] as String : null,
      version: about?['contentVersion'] is String ? about!['contentVersion'] as String : null,
    );
  }

  static Map<String, dynamic>? _parameters(ArchiveFile? file) {
    if (file == null) return null;
    try {
      var bytes = file.readBytes() ?? Uint8List(0);
      if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) bytes = bytes.sublist(3);
      final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
      return decoded is Map<String, dynamic> ? decoded : null;
    } on Object {
      return null;
    }
  }

  /// Unpacks the zip at [path] into [into] (made fresh; it must not be there), the one folder
  /// every file is in left out. [progress] hears the bytes written and the whole, every few
  /// megabytes; [cancelled] is asked as often. Folders and files only: links are skipped, and an
  /// archive with a name that would land outside [into] is refused before anything is written.
  /// On any failure or a stop, [into] is removed again.
  static void unpackSync(
    String path,
    String into, {
    void Function(int done, int total)? progress,
    bool Function()? cancelled,
  }) {
    if (Ffpfsc.matches(path)) return Ffpfsc.unpackSync(path, into, progress: progress, cancelled: cancelled);
    final input = InputFileStream(path);
    try {
      final archive = ZipDecoder().decodeStream(input);
      final plan = _plan(archive);
      if (plan.files == 0) throw ArchiveException('The archive has no files');
      if (plan.refused.isNotEmpty) {
        throw ArchiveException('${plan.refused.length} names would land outside the folder: ${plan.refused.first}');
      }
      Directory(into).createSync(recursive: true);
      var done = 0;
      var reported = 0;
      void count(int bytes) {
        done += bytes;
        if (done - reported >= _reportEvery || done == plan.size) {
          reported = done;
          if (cancelled?.call() ?? false) throw const UnpackCancelled();
          progress?.call(done, plan.size);
        }
      }

      progress?.call(0, plan.size);
      for (final entry in archive.files) {
        if (cancelled?.call() ?? false) throw const UnpackCancelled();
        if (entry.isSymbolicLink) continue;
        final target = safePath(into, entry.name, strip: plan.strip);
        if (target == null) throw ArchiveException('${entry.name} would land outside the folder');
        if (!entry.isFile) {
          Directory(target).createSync(recursive: true);
          continue;
        }
        Directory(p.dirname(target)).createSync(recursive: true);
        final output = _CountingOutput(OutputFileStream(target), count);
        try {
          entry.writeContent(output);
        } finally {
          output.closeSync();
        }
        if (entry.size > 0 && File(target).lengthSync() != entry.size) {
          throw ArchiveException('${entry.name} came out at the wrong size');
        }
      }
      progress?.call(plan.size, plan.size);
    } on Object {
      input.closeSync();
      _remove(into);
      rethrow;
    }
    input.closeSync();
  }

  static const _reportEvery = 8 * 1024 * 1024;

  /// [unpackSync] in an isolate of its own, its progress sent to [sink] a few times a second. A
  /// function of its own, so the isolate's closure holds only these four.
  static Future<void> _unpackIsolated(String path, String into, SendPort sink, String? marker) => Isolate.run(() {
    var last = DateTime.fromMillisecondsSinceEpoch(0);
    unpackSync(
      path,
      into,
      progress: (done, total) {
        final now = DateTime.now();
        // Each one redraws the panel.
        if (done == total || now.difference(last) > const Duration(milliseconds: 200)) {
          last = now;
          sink.send((done, total));
        }
      },
      cancelled: marker == null ? null : () => File(marker).existsSync(),
    );
  });

  static void _remove(String folder) {
    try {
      if (Directory(folder).existsSync()) Directory(folder).deleteSync(recursive: true);
    } on FileSystemException {
      // Left for the next try, which clears it first.
    }
  }

  /// Unpacks [archive] in another isolate into a hidden folder beside [into] (the archive's
  /// [GameArchive.folder] when not given), then renames that to it. [progress] hears the bytes written and the whole. Throws
  /// [UnpackCancelled] after [cancel], the archive's or the disk's error otherwise; nothing is
  /// left behind either way.
  static Future<void> unpack(
    GameArchive archive, {
    String? into,
    void Function(int done, int total)? progress,
    UnpackCancel? cancel,
  }) async {
    final folder = into ?? archive.folder;
    final partial = into == null ? archive.partial : p.join(p.dirname(into), '.${p.basename(into)}.unpacking');
    _remove(partial);
    if (FileSystemEntity.typeSync(folder) != FileSystemEntityType.notFound) {
      throw FileSystemException('A folder of that name is there already', folder);
    }
    final port = ReceivePort();
    final marker = cancel?.marker;
    final listening = port.listen((message) {
      if (message case (final int done, final int total)) progress?.call(done, total);
    });
    try {
      await _unpackIsolated(archive.path, partial, port.sendPort, marker);
    } finally {
      await listening.cancel();
      port.close();
      if (marker != null) {
        try {
          if (File(marker).existsSync()) File(marker).deleteSync();
        } on FileSystemException {
          // Nothing reads it again.
        }
      }
    }
    // A virus scanner may still hold a file just written: a few tries.
    for (var attempt = 0; ; attempt++) {
      try {
        Directory(partial).renameSync(folder);
        return;
      } on FileSystemException {
        if (attempt >= 4) {
          _remove(partial);
          rethrow;
        }
        await Future<void>.delayed(Duration(milliseconds: 250 * (attempt + 1)));
      }
    }
  }
}

/// An output that counts what goes through it, for the progress of one large file.
class _CountingOutput extends OutputStream {
  _CountingOutput(this._inner, this._count) : super(byteOrder: ByteOrder.littleEndian);

  final OutputFileStream _inner;
  final void Function(int bytes) _count;

  @override
  int get length => _inner.length;

  @override
  void clear() => _inner.clear();

  @override
  void flush() => _inner.flush();

  @override
  void closeSync() => _inner.closeSync();

  @override
  Future<void> close() => _inner.close();

  @override
  void writeByte(int value) {
    _inner.writeByte(value);
    _count(1);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _inner.writeBytes(bytes, length: length);
    _count(length ?? bytes.length);
  }

  @override
  void writeStream(InputStream stream) {
    const chunk = 1024 * 1024;
    while (!stream.isEOS) {
      final bytes = stream.readBytes(chunk).toUint8List();
      if (bytes.isEmpty) break;
      writeBytes(bytes);
    }
  }

  @override
  Uint8List subset(int start, [int? end]) => _inner.subset(start, end);
}
