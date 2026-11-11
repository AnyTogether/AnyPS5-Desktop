import 'dart:io';

import 'package:anyps5_desktop/core/libmpv.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/launcher.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/ui_support.dart';

/// A clip in the gallery's viewer on Linux without libmpv, as it looks: its picture, what is
/// missing, the command for this system and the way to another player. In English and Turkish.
void main() {
  late Fixture fixture;
  final shell = find.byType(LauncherShell);

  tearDown(() {
    T.language = Language.english;
    fixture.dispose();
  });

  Future<void> viewer(WidgetTester tester, Language language, String golden) async {
    fixture = makeFixture(
      language: language,
      clipPlayback: () => throw const LibmpvMissing(['sudo apt install libmpv2']),
    );
    final model = fixture.model;
    final shot = p.join(fixture.temp.path, 'PPSA01001-20261026-115900.png');
    final clip = p.join(fixture.temp.path, 'PPSA01001-clip-20261026-120000.mp4');
    File(shot).writeAsBytesSync(png(16, 9, (x, y) => 0x3366FFFF));
    File(clip).writeAsBytesSync(List.filled(64, 1));
    model.selected = model.games.indexWhere((game) => game.titleId == 'PPSA01001');
    model.open(Layer.gallery);
    model.galleryShots = [shot, clip];
    model.galleryIndex = 1;
    model.galleryViewing = true;
    model.refresh();
    await pumpLauncher(tester, model);
    // The notice's rise into place.
    await tester.pump(const Duration(milliseconds: 400));
    await expectLater(shell, matchesGoldenFile(golden));
  }

  testWidgets(
    'gallery: a clip without libmpv',
    (tester) => viewer(tester, Language.english, 'goldens/clip_libmpv_missing.png'),
  );

  testWidgets(
    'gallery: a clip without libmpv, in Turkish',
    (tester) => viewer(tester, Language.byCode('tr'), 'goldens/clip_libmpv_missing_tr.png'),
  );
}
