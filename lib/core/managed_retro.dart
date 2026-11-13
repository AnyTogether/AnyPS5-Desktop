import 'dart:ffi' show Abi;
import 'dart:io';

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

  String libraryName(RetroPlatform platform) {
    final name = switch (platform) {
      RetroPlatform.ps1 => 'swanstation_libretro',
      RetroPlatform.ps2 => 'pcsx2_libretro',
      RetroPlatform.ps3 => throw ArgumentError.value(platform),
    };
    return '$name.${this == windowsX64 ? 'dll' : 'so'}';
  }
}

class ManagedRetro {
  ManagedRetro(this.root, this.host);

  final String root;
  final EmbeddedCoreHost host;

  String libraryPath(RetroPlatform platform) => p.join(root, host.libraryName(platform));

  bool isInstalled(RetroPlatform platform) => platform != RetroPlatform.ps3 && File(libraryPath(platform)).existsSync();

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
    (_, RetroPlatform.ps3) => throw ArgumentError.value(platform),
  };

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
