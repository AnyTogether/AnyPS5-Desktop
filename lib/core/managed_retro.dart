import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' show getCrc32;
import 'package:path/path.dart' as p;

import 'game_library.dart';
import 'toolkit_download.dart';

class ManagedRetro {
  ManagedRetro(this.root, {this.packageDirectory, this.ps3CoreDigests});

  final String root;
  final String? packageDirectory;
  final String? ps3CoreDigests;
  static const _patchedPs3Archive = '7bc267dc0a9cffdd21087340ab643c52ed91136606e6d33ae05c477adc7db3a4';
  static const _patchedPs3Library = '7ac7504de83acfa2d977345f8c9b48e92f5e71c576abbf026406e667fe7a1370';

  static String libraryName(RetroPlatform platform) => switch (platform) {
    RetroPlatform.ps1 => 'swanstation_libretro.dll',
    RetroPlatform.ps2 => 'pcsx2_libretro.dll',
    RetroPlatform.ps3 => 'rpcs3_libretro.dll',
  };

  static String platformName(RetroPlatform platform) => switch (platform) {
    RetroPlatform.ps1 => 'PS1',
    RetroPlatform.ps2 => 'PS2',
    RetroPlatform.ps3 => 'PS3',
  };

  bool isInstalled(RetroPlatform platform) => _windowsX64Library(File(p.join(root, libraryName(platform))));

  Future<void> install(RetroPlatform platform, {void Function(int, int)? progress}) async {
    final name = libraryName(platform);
    final installed = isInstalled(platform);
    if (platform == RetroPlatform.ps3) {
      final (archiveDigest, libraryDigest) = _ps3Digests();
      if (installed && await AssetDownload.sha256Of(p.join(root, name)) == libraryDigest) return;
      final directory = packageDirectory;
      if (directory == null) {
        throw const FormatException('The PS3 preview requires a verified RPCS3 package.');
      }
      final archive = File(p.join(directory, '$name.zip'));
      if (!p.isAbsolute(directory) || !archive.existsSync()) {
        throw const FormatException('The configured PS3 emulator package is missing.');
      }
      if (await AssetDownload.sha256Of(archive.path) != archiveDigest) {
        throw const FormatException('The configured PS3 emulator package did not pass verification.');
      }
      final size = await archive.length();
      await _publishCore(
        name,
        archive.path,
        verify: (file) async {
          if (await AssetDownload.sha256Of(file.path) != libraryDigest) {
            throw const FormatException('The installed PS3 emulator did not pass verification.');
          }
        },
      );
      progress?.call(size, size);
      return;
    }
    if (installed) return;
    final url = Uri.https('buildbot.libretro.com', '/nightly/windows/x86_64/latest/$name.zip');
    final (size, revision) = await _buildbotPackage(url);
    final digest = switch (revision) {
      0x356fa26d => 'b640a70f660fd0b5ca4adecad5c90281f481a46802a752b9f66e2aa2791474dc',
      0xa7025679 => '1193159038bd8b77bbe099f1b1f46ff3add61ce6b44d6ec5a66611f0cbfe8c10',
      _ => null,
    };
    final zip = p.join(root, 'Downloads', '${revision.toRadixString(16)}-$name.zip');
    await AssetDownload.fetch(
      url,
      zip,
      size: size,
      sha256: digest,
      httpsOnly: true,
      onProgress: (bytes) => progress?.call(bytes, size),
    );
    await _publishCore(
      name,
      zip,
      verify: (candidate) async {
        var checksum = 0;
        await for (final bytes in candidate.openRead()) {
          checksum = getCrc32(bytes, checksum);
        }
        if (checksum != revision) {
          await File(zip).delete();
          throw const FormatException('The core did not match Libretro’s download index. Try again.');
        }
      },
    );
  }

  (String, String) _ps3Digests() {
    final configured = ps3CoreDigests;
    if (configured == null) return (_patchedPs3Archive, _patchedPs3Library);
    if (!RegExp(r'^[a-fA-F0-9]{64}:[a-fA-F0-9]{64}$').hasMatch(configured) || configured.length != 129) {
      throw const FormatException('Set PS3 core digests to the package and DLL SHA-256 values separated by a colon.');
    }
    return (configured.substring(0, 64).toLowerCase(), configured.substring(65).toLowerCase());
  }

  Future<void> _publishCore(String name, String archive, {required Future<void> Function(File) verify}) async {
    final directory = await Directory(root).create(recursive: true);
    final stage = await directory.createTemp('install-');
    try {
      await SafeUnpack.unpack(archive, stage.path);
      final candidate = File(p.join(stage.path, name));
      if (!_windowsX64Library(candidate)) throw const FormatException('The download contains no Windows x64 core.');
      await verify(candidate);
      await candidate.rename(p.join(root, name));
    } finally {
      await stage.delete(recursive: true);
    }
  }

  static Future<(int, int)> _buildbotPackage(Uri url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final listing = await client.getUrl(url.resolve('.index-extended'));
      listing.followRedirects = false;
      final index = await listing.close().timeout(const Duration(seconds: 20));
      if (index.statusCode != HttpStatus.ok) throw const FormatException('Libretro’s download index is unavailable.');
      final text = await utf8.decoder.bind(index).join().timeout(const Duration(seconds: 20));
      final name = url.pathSegments.last;
      for (final line in const LineSplitter().convert(text)) {
        final parts = line.trim().split(RegExp(r'\s+'));
        if (parts.length != 3 || parts.last != name) continue;
        final revision = int.tryParse(parts[1], radix: 16);
        if (revision == null) break;
        final head = await client.headUrl(url);
        head.followRedirects = false;
        final info = await head.close().timeout(const Duration(seconds: 20));
        final size = info.contentLength;
        await info.drain<void>();
        if (info.statusCode == HttpStatus.ok && size > 0 && size <= 128 * 1024 * 1024) return (size, revision);
        break;
      }
      throw FormatException('Libretro’s download index has no usable package for $name.');
    } finally {
      client.close(force: true);
    }
  }

  String get systemPath => p.join(root, 'system');

  bool get hasPs3Firmware => File(p.join(systemPath, 'rpcs3', 'dev_flash', 'vsh', 'module', 'vsh.self')).existsSync();

  String get _ps3FirmwarePackage => p.join(systemPath, 'PS3UPDAT.PUP');

  bool get hasPs3FirmwarePackage => File(_ps3FirmwarePackage).existsSync();

  Future<void> installPs3Firmware({void Function(int, int)? progress}) async {
    if (hasPs3Firmware) return;
    const size = 206197916;
    await AssetDownload.fetch(
      Uri.http(
        'dus01.ps3.update.playstation.net',
        '/update/ps3/image/us/2026_0318_a2b60b6ac1d2e49e230144345616927c/PS3UPDAT.PUP',
      ),
      _ps3FirmwarePackage,
      size: size,
      sha256: '158471fd834f8ea8036136b6aab43cd86c7ba73d79ca30e0af3c0fe0001cf365',
      onProgress: (bytes) => progress?.call(bytes, size),
    );
  }

  Directory _biosFolder(RetroPlatform platform) =>
      Directory(platform == RetroPlatform.ps1 ? p.join(root, 'system') : p.join(root, 'system', 'pcsx2', 'bios'));

  int _biosSize(RetroPlatform platform) => platform == RetroPlatform.ps1 ? 512 * 1024 : 4 * 1024 * 1024;

  bool hasBios(RetroPlatform platform) => biosPath(platform) != null;

  String? biosPath(RetroPlatform platform) {
    final folder = _biosFolder(platform);
    if (!folder.existsSync()) return null;
    final files = folder.listSync(followLinks: false).whereType<File>();
    final matching = files.where(
      (file) => p.extension(file.path).toLowerCase() == '.bin' && file.lengthSync() == _biosSize(platform),
    );
    return matching.where((file) => p.basename(file.path) == 'anyps5-imported.bin').firstOrNull?.path ??
        matching.firstOrNull?.path;
  }

  Future<void> importBios(RetroPlatform platform, String path) async {
    final file = File(path);
    final size = _biosSize(platform);
    if (await file.length() != size) {
      throw FormatException('Select an extracted ${platformName(platform)} BIOS file of ${size ~/ 1024} KiB.');
    }
    final bytes = await file.readAsBytes();
    if (bytes.length != size || bytes.every((byte) => byte == bytes.first)) {
      throw const FormatException('The selected BIOS file is incomplete.');
    }
    final folder = await _biosFolder(platform).create(recursive: true);
    final target = File(p.join(folder.path, 'anyps5-imported.bin'));
    final staged = await File('${target.path}.part').writeAsBytes(bytes, flush: true);
    await staged.rename(target.path);
  }

  static bool _windowsX64Library(File file) {
    try {
      final source = file.openSync();
      try {
        final dos = source.readSync(64);
        if (dos.length != 64 || dos[0] != 0x4d || dos[1] != 0x5a) return false;
        final offset = ByteData.sublistView(dos).getUint32(60, Endian.little);
        if (offset < dos.length || offset + 24 > source.lengthSync()) return false;
        source.setPositionSync(offset);
        final header = source.readSync(24);
        if (header.length != 24) return false;
        final pe = ByteData.sublistView(header);
        return pe.getUint32(0, Endian.little) == 0x4550 &&
            pe.getUint16(4, Endian.little) == 0x8664 &&
            pe.getUint16(22, Endian.little) & 0x2000 != 0;
      } finally {
        source.closeSync();
      }
    } on FileSystemException {
      return false;
    }
  }
}
