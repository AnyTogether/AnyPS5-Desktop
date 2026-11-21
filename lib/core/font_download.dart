import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'free_space.dart';
import 'toolkit_download.dart';

/// One file taken out of a font archive: its name in the archive, the name it is kept under,
/// and what it must be.
class FontArchiveMember {
  const FontArchiveMember(this.name, {required this.size, required this.sha256, String? savedAs})
    : savedAs = savedAs ?? name;

  final String name;
  final String savedAs;
  final int size;
  final String sha256;
}

/// A zip of fonts to download once, checked as a whole and file by file.
class FontArchive {
  const FontArchive({required this.url, required this.size, required this.sha256, required this.members});

  final Uri url;
  final int size;
  final String sha256;
  final List<FontArchiveMember> members;

  String get fileName => p.posix.basename(url.path);

  /// What the kept files take on disk.
  int get installedSize => members.fold(0, (sum, member) => sum + member.size);

  /// Noto Sans CJK 2.004 as OpenType collections (SIL Open Font License 1.1): the four weights
  /// the engine opens for Japanese (face 0), Korean (face 1) and Simplified Chinese (face 2),
  /// and the licence.
  static final notoSansCjk = FontArchive(
    url: Uri.parse('https://github.com/notofonts/noto-cjk/releases/download/Sans2.004/03_NotoSansCJK-OTC.zip'),
    size: 104680673,
    sha256: '528f4e1b25ff3badb0321b38d015d954c4c0de926c7830ef50e4a1948f6a3eed',
    members: const [
      FontArchiveMember(
        'NotoSansCJK-Light.ttc',
        size: 18160344,
        sha256: '872def437cf8b9c41bf1736da891e34a8c25b764c0c4a51418d3745570660f42',
      ),
      FontArchiveMember(
        'NotoSansCJK-Regular.ttc',
        size: 19484784,
        sha256: 'b76b0433203017ca80401b2ee0dd69350349871c4b19d504c34dbdd80541690a',
      ),
      FontArchiveMember(
        'NotoSansCJK-Medium.ttc',
        size: 18354360,
        sha256: '197d5e1e019faca33a4d55931c7d68b8056f3b97cb862049f5cb8de9efdfb8ce',
      ),
      FontArchiveMember(
        'NotoSansCJK-Bold.ttc',
        size: 20050760,
        sha256: 'faa5f3656a78b2e2d450d27fe8382c778bc2b6bb5ea29c986664a6a435056ceb',
      ),
      FontArchiveMember(
        'LICENSE',
        savedAs: 'LICENSE-NotoSansCJK.txt',
        size: 4301,
        sha256: '6a73f9541c2de74158c0e7cf6b0a58ef774f5a780bf191f2d7ec9cc53efe2bf2',
      ),
    ],
  );
}

class FontInstallFailure implements Exception {
  FontInstallFailure(this.message, {this.cancelled = false});
  final String message;
  final bool cancelled;

  @override
  String toString() => message;
}

/// The downloaded fonts of one [archive], kept in [folder]: the zip is downloaded beside them
/// (carried on from where an earlier try stopped, a few tries when the connection drops),
/// checked, the members unpacked and checked one by one, and the zip deleted.
class FontInstaller {
  FontInstaller(
    this.folder, {
    required this.archive,
    this.client,
    int? Function(String path)? freeSpace,
    this.attempts = 4,
    this.retryDelay = const Duration(seconds: 2),
  }) : _freeSpace = freeSpace ?? FreeSpace.of;

  final String folder;
  final FontArchive archive;

  /// Makes the HTTP client (tests give one of their own); dart:io's by default.
  final HttpClient Function()? client;
  final int? Function(String path) _freeSpace;
  final int attempts;
  final Duration retryDelay;

  /// Room kept free beyond what the download and the fonts take.
  static const spare = 64 * 1024 * 1024;

  String get _downloads => p.join(folder, '.download');
  String get _zip => p.join(_downloads, archive.fileName);

  /// Whether every member is in place at its size (each was checked as it was unpacked).
  bool get installed => archive.members.every((member) {
    final file = File(p.join(folder, member.savedAs));
    return file.existsSync() && file.lengthSync() == member.size;
  });

  /// The bytes this install still needs on disk: the rest of the zip and the unpacked fonts.
  int get bytesNeeded {
    final part = File('$_zip.part');
    final have = part.existsSync() ? part.lengthSync() : (File(_zip).existsSync() ? archive.size : 0);
    return archive.size - have + archive.installedSize + spare;
  }

  /// Downloads and unpacks the fonts; [onProgress] goes from 0 to 1.
  Future<void> install({void Function(double fraction)? onProgress, DownloadCancel? cancel}) async {
    if (installed) {
      onProgress?.call(1);
      return;
    }
    Directory(_downloads).createSync(recursive: true);
    final needed = bytesNeeded;
    final free = _freeSpace(folder);
    if (free != null && free < needed) throw FontInstallFailure('not enough free space: ${byteText(needed)} needed');
    const downloadShare = 0.9;
    for (var attempt = 1; ; attempt++) {
      try {
        await AssetDownload.fetch(
          archive.url,
          _zip,
          size: archive.size,
          sha256: archive.sha256,
          onProgress: (received) => onProgress?.call(downloadShare * received / archive.size),
          cancel: cancel,
          client: client,
          // The installer tries again itself, [attempts] times.
          attempts: 1,
        );
        break;
      } on ToolkitFailure catch (failure) {
        if (failure.kind == ToolkitFailureKind.cancelled) throw FontInstallFailure(failure.message, cancelled: true);
        final retry = failure.kind == ToolkitFailureKind.network && attempt < attempts;
        if (!retry) throw FontInstallFailure(failure.message);
        await Future<void>.delayed(retryDelay * attempt);
        if (cancel?.cancelled ?? false) throw FontInstallFailure('the download was stopped', cancelled: true);
      }
    }
    final error = await _extractAway(_zip, folder, archive.members);
    if (error != null) throw FontInstallFailure(error);
    _quietly(() => Directory(_downloads).deleteSync(recursive: true));
    onProgress?.call(1);
  }

  /// [extract] in an isolate of its own; the closure holds nothing but the arguments.
  static Future<String?> _extractAway(String zip, String folder, List<FontArchiveMember> members) =>
      Isolate.run(() => extract(zip, folder, members));

  /// Takes [members] out of [zip] into [folder], each written beside its place, checked
  /// against its size and SHA-256 and only then given its name. The zip is read from disk as it
  /// goes, not all at once. Returns why it failed, null when every member is in place.
  static String? extract(String zip, String folder, List<FontArchiveMember> members) {
    final input = InputFileStream(zip);
    try {
      final archive = ZipDecoder().decodeStream(input);
      for (final member in members) {
        final entry = archive.files
            .where((file) => file.isFile && p.posix.basename(file.name) == member.name)
            .firstOrNull;
        if (entry == null) return 'the archive has no ${member.name}';
        final part = p.join(folder, '${member.savedAs}.part');
        final output = OutputFileStream(part);
        try {
          entry.writeContent(output);
        } finally {
          output.closeSync();
        }
        final length = File(part).lengthSync();
        if (length != member.size || sha256Of(part) != member.sha256) {
          File(part).deleteSync();
          return '${member.name} is not the expected file';
        }
        final destination = File(p.join(folder, member.savedAs));
        if (destination.existsSync()) destination.deleteSync();
        File(part).renameSync(destination.path);
      }
      return null;
    } on Object catch (error) {
      return 'the fonts could not be unpacked: $error';
    } finally {
      input.closeSync();
    }
  }

  /// The SHA-256 of a file, read a piece at a time.
  static String sha256Of(String path) {
    final sink = _DigestSink();
    final hashing = sha256.startChunkedConversion(sink);
    final file = File(path).openSync();
    try {
      while (true) {
        final chunk = file.readSync(1 << 20);
        if (chunk.isEmpty) break;
        hashing.add(chunk);
      }
    } finally {
      file.closeSync();
    }
    hashing.close();
    return sink.value.toString();
  }

  /// Deletes the fonts and anything a stopped download left.
  void remove() {
    for (final member in archive.members) {
      final file = File(p.join(folder, member.savedAs));
      if (file.existsSync()) file.deleteSync();
    }
    _quietly(() {
      if (Directory(_downloads).existsSync()) Directory(_downloads).deleteSync(recursive: true);
    });
  }

  static void _quietly(void Function() action) {
    try {
      action();
    } on FileSystemException {
      // Left behind; the next install or removal tries again.
    }
  }

  /// Sizes for people, as the rest of the launcher shows them.
  static String byteText(int bytes) => '${(bytes / (1024 * 1024)).ceil()} MB';
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
