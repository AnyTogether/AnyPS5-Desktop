import 'dart:async';
import 'dart:io';

import 'package:anyps5_desktop/ui/countries.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The goldens in test/ui/goldens are made on macOS. Linux and Windows draw text and blur a
/// little differently (from about 1 % of the pixels on Windows to about 12 % on Linux), so CI
/// compares them on macOS only and runs the whole suite on Linux with ANYPS5_SKIP_GOLDENS=1:
/// the screens are still built and pumped, only the pixel comparison is left out.
///
/// The texts are read from assets/l10n first, as the launcher does before its first frame:
/// straight from the folder, since asking the asset bundle needs the test binding, whose
/// HttpClient answers every request with a 400 in the files that talk to fake servers.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  await T.load(bundle: _NoAssets(), tryOut: Directory('assets/l10n'));
  await Countries.load(file: File(Countries.asset));
  if (!autoUpdateGoldenFiles) {
    final comparator = goldenFileComparator;
    if (Platform.environment['ANYPS5_SKIP_GOLDENS'] == '1') {
      goldenFileComparator = _SkippedGoldens();
    } else if (comparator is LocalFileComparator) {
      goldenFileComparator = _KeptNewGoldens(comparator);
    }
  }
  await testMain();
}

/// Compares as usual. A golden with no file yet has nothing to compare with, so flutter_test
/// fails it without an image: this leaves the new picture where a mismatch leaves its own
/// (`failures/<name>_testImage.png`), for CI's golden-failures-macos artifact.
class _KeptNewGoldens extends GoldenFileComparator {
  _KeptNewGoldens(this._comparator);

  final LocalFileComparator _comparator;

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final goldenFile = File.fromUri(_comparator.basedir.resolveUri(golden));
    if (!goldenFile.existsSync()) {
      final name = golden.pathSegments.last.replaceAll(RegExp(r'\.png$'), '');
      final made = File.fromUri(_comparator.basedir.resolve('failures/${name}_testImage.png'));
      made.parent.createSync(recursive: true);
      made.writeAsBytesSync(imageBytes);
    }
    return _comparator.compare(imageBytes, golden);
  }

  @override
  Future<void> update(Uri golden, Uint8List imageBytes) => _comparator.update(golden, imageBytes);
}

class _SkippedGoldens extends GoldenFileComparator {
  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async => true;

  @override
  Future<void> update(Uri golden, Uint8List imageBytes) async {}
}

class _NoAssets extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async => const StandardMessageCodec().encodeMessage(<String, Object>{})!;
}
