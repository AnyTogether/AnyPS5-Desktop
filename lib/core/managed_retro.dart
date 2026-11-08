import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'game_library.dart';
import 'toolkit_download.dart';

enum EmbeddedCoreHost {
  windowsX64,
  linuxX64;

  static EmbeddedCoreHost? get current => switch (Abi.current()) {
    Abi.windowsX64 => windowsX64,
    Abi.linuxX64 => linuxX64,
    _ => null,
  };

  bool supports(RetroPlatform platform) => platform != RetroPlatform.ps3 || this == windowsX64;

  String libraryName(RetroPlatform platform) {
    if (!supports(platform)) throw ArgumentError.value(platform);
    final name = switch (platform) {
      RetroPlatform.ps1 => 'swanstation_libretro',
      RetroPlatform.ps2 => 'pcsx2_libretro',
      RetroPlatform.ps3 => 'rpcs3_libretro',
    };
    return '$name.${this == windowsX64 ? 'dll' : 'so'}';
  }
}

class ManagedRetro {
  ManagedRetro(this.root, this.host, {this.ps3CoreDigests});

  final String root;
  final EmbeddedCoreHost host;
  final String? ps3CoreDigests;
  static const _patchedPs3Archive = '7bc267dc0a9cffdd21087340ab643c52ed91136606e6d33ae05c477adc7db3a4';
  static const _patchedPs3Library = '7ac7504de83acfa2d977345f8c9b48e92f5e71c576abbf026406e667fe7a1370';

  String libraryPath(RetroPlatform platform) => p.join(root, host.libraryName(platform));

  bool isInstalled(RetroPlatform platform) => host.supports(platform) && File(libraryPath(platform)).existsSync();

  (String, String) _digests(RetroPlatform platform) => switch ((host, platform)) {
    // SwanStation 1.0.0 631f0fb and ParaLLEl PS2 v2.0.0-da5b07e.
    (EmbeddedCoreHost.windowsX64, RetroPlatform.ps1) => (
      'b640a70f660fd0b5ca4adecad5c90281f481a46802a752b9f66e2aa2791474dc',
      '1aaa621dab9f53b130ac29d17e9a12ea4c0df975d4b02b53faec3b52c717fd12',
    ),
    (EmbeddedCoreHost.windowsX64, RetroPlatform.ps2) => (
      '1193159038bd8b77bbe099f1b1f46ff3add61ce6b44d6ec5a66611f0cbfe8c10',
      '47ffaedbaa0d488039feda57d9c8e57ffd3fb97626e67af4780f9219e2bd901c',
    ),
    (EmbeddedCoreHost.linuxX64, RetroPlatform.ps1) => (
      '0f1e33e74ca1de338e0adf9d8aa589ca87c9ee8ba5984f849476b0a8508c31d3',
      'fc65bb2d662c3ad762b611a62ac578f78efd260431d3b8c090f0eb40887a77ea',
    ),
    (EmbeddedCoreHost.linuxX64, RetroPlatform.ps2) => (
      'ec087ee7f6452e9f74b4abf4b51243281366ca57b8b43e82b0c223eac5cc4fa8',
      'd7c98fb581f86f3d36b810ebed896bbe46f090f49d2b7d2bfe2eaceee87f1eb0',
    ),
    (EmbeddedCoreHost.windowsX64, RetroPlatform.ps3) => _ps3Digests(),
    (_, RetroPlatform.ps3) => throw ArgumentError.value(platform),
  };

  (String, String) _ps3Digests() {
    final configured = ps3CoreDigests;
    if (configured == null) return (_patchedPs3Archive, _patchedPs3Library);
    if (!RegExp(r'^[a-fA-F0-9]{64}:[a-fA-F0-9]{64}$').hasMatch(configured) || configured.length != 129) {
      throw const FormatException('Set PS3 core digests to the package and DLL SHA-256 values separated by a colon.');
    }
    return (configured.substring(0, 64).toLowerCase(), configured.substring(65).toLowerCase());
  }

  Future<bool> verifiesInstalled(RetroPlatform platform) async {
    return isInstalled(platform) && await AssetDownload.sha256Of(libraryPath(platform)) == _digests(platform).$2;
  }

  Future<void> install(RetroPlatform platform, String archive) async {
    final (archiveDigest, libraryDigest) = _digests(platform);
    final name = host.libraryName(platform);
    final directory = await Directory(root).create(recursive: true);
    final stage = await directory.createTemp('install-');
    try {
      final package = await File(archive).copy(p.join(stage.path, 'core.zip'));
      if (await AssetDownload.sha256Of(package.path) != archiveDigest) {
        throw const FormatException('Core archive SHA-256 mismatch');
      }
      final extracted = p.join(stage.path, 'core');
      await SafeUnpack.unpack(package.path, extracted);
      final candidate = File(p.join(extracted, name));
      if (await AssetDownload.sha256Of(candidate.path) != libraryDigest) {
        throw const FormatException('Core library SHA-256 mismatch');
      }
      await candidate.rename(libraryPath(platform));
    } finally {
      await stage.delete(recursive: true);
    }
  }

  String get systemPath => p.join(root, 'system');

  bool get hasPs3Firmware =>
      File(p.join(systemPath, 'rpcs3', 'dev_flash', 'sys', 'external', 'liblv2.sprx')).existsSync();

  String get ps3FirmwarePackage => p.join(systemPath, 'PS3UPDAT.PUP');

  bool get hasPs3FirmwarePackage => File(ps3FirmwarePackage).existsSync();

  /// Stage a user-supplied PUP. RPCS3 validates and installs it on first boot.
  Future<void> importPs3Firmware(String path) async {
    final folder = await Directory(systemPath).create(recursive: true);
    final stage = await folder.createTemp('firmware-');
    try {
      final candidate = await File(path).copy(p.join(stage.path, 'PS3UPDAT.PUP'));
      final file = await candidate.open();
      try {
        final header = await file.read(48);
        if (header.length != 48 || ascii.decode(header.take(8).toList(), allowInvalid: true) != 'SCEUF\x00\x00\x00') {
          throw const FormatException('Invalid PS3 update header');
        }
        final fields = ByteData.sublistView(header);
        final entryCount = fields.getUint64(24);
        final headerSize = fields.getUint64(32);
        final dataSize = fields.getUint64(40);
        final length = await file.length();
        if (entryCount <= 0 ||
            headerSize < 48 ||
            headerSize > length ||
            entryCount > (headerSize - 48) ~/ 64 ||
            dataSize <= 0 ||
            dataSize > length - headerSize) {
          throw const FormatException('Incomplete PS3 update package');
        }
      } finally {
        await file.close();
      }
      await candidate.rename(ps3FirmwarePackage);
    } finally {
      await stage.delete(recursive: true);
    }
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
      throw const FormatException('Incorrect BIOS size');
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
}
