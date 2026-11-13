import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/launcher.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/ui_support.dart';

/// Game Settings › Remove installation, as it asks: what goes, and that the saves and trophies
/// are kept. In Turkish, the longer of the two texts the launcher is written in.
void main() {
  late Fixture fixture;
  final shell = find.byType(LauncherShell);

  tearDown(() {
    T.language = Language.english;
    fixture.dispose();
  });

  testWidgets('Remove installation says the saves and trophies are kept, in Turkish', (tester) async {
    fixture = makeFixture(language: Language.byCode('tr'));
    final model = fixture.model;
    model.select(model.games.indexWhere((game) => game.titleId == 'PPSA01001'));
    model.open(Layer.confirmUninstall);
    await pumpLauncher(tester, model);
    expect(find.textContaining(T.text('uninstallKeeps')), findsOneWidget);
    await expectLater(shell, matchesGoldenFile('goldens/uninstall_confirm_tr.png'));
  });
}
