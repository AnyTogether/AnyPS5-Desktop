import 'package:anyps5_desktop/core/installer.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/launcher.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:anyps5_desktop/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/ui_support.dart';

/// Pause, Resume and Cancel on an unlock, as drawn: the hero with Pause and the small Cancel,
/// the paused hero, the cancel question and the quit question, in English and in Turkish.
void main() {
  late Fixture fixture;

  tearDown(() {
    T.language = Language.english;
    Motion.reduced = false;
    fixture.dispose();
  });

  final shell = find.byType(LauncherShell);

  for (final (code, suffix) in [('en', ''), ('tr', '_tr')]) {
    group('golden ($code)', () {
      /// Neon Alley unlocking on its own (no update, not to play after), its buttons in focus.
      AppModel unlocking() {
        fixture = makeFixture(language: Language.byCode(code));
        final model = fixture.model;
        final game = model.games.firstWhere((game) => game.titleId == 'PPSA02002');
        model.select(model.games.indexOf(game));
        model.progress[game.id] = (InstallStep.copy, 0.45);
        model.handle(Command.down);
        Motion.reduced = true;
        return model;
      }

      testWidgets('home, an unlock under way: Pause, with the small Cancel beside it', (tester) async {
        final model = unlocking();
        expect(model.cancelShown, isTrue);
        await pumpLauncher(tester, model);
        expect(find.text(T.text('unlockPause')), findsOneWidget);
        await expectLater(shell, matchesGoldenFile('goldens/home_unlock_pause$suffix.png'));
        model.progress.clear();
      });

      testWidgets('home, an unlock paused by hand: Resume, and the hero says Paused', (tester) async {
        final model = unlocking();
        model.showPausedForTest(model.selectedGame!);
        await pumpLauncher(tester, model);
        expect(find.text(T.text('unlockResume')), findsOneWidget);
        await expectLater(shell, matchesGoldenFile('goldens/home_unlock_paused$suffix.png'));
        model.progress.clear();
      });

      testWidgets('the small Cancel asks first: Keep going or Cancel unlock', (tester) async {
        final model = unlocking();
        model.askCancelUnlock(model.selectedGame!);
        expect(model.overlay, Layer.confirmCancelUnlock);
        await pumpLauncher(tester, model);
        await expectLater(shell, matchesGoldenFile('goldens/unlock_cancel_confirm$suffix.png'));
        model.progress.clear();
      });

      testWidgets('quitting with an unlock under way and one waiting asks: Go back or Cancel and quit', (tester) async {
        final model = unlocking();
        model.queue.add(model.games.firstWhere((game) => game.titleId == 'PPSA03003').id);
        expect(model.hasManualUnlock, isTrue);
        model.requestQuit();
        expect(model.overlay, Layer.confirmQuitUnlocks);
        await pumpLauncher(tester, model);
        await expectLater(shell, matchesGoldenFile('goldens/quit_unlocks_confirm$suffix.png'));
        model.queue.clear();
        model.progress.clear();
      });
    });
  }
}
