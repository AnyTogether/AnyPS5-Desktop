import 'package:anyps5_desktop/core/retro_host/retro_host_build.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_protocol.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/retro_host/retro_unchecked_mark.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/ps1_launcher.dart';
import '../support/ui_support.dart';
import 'retro_host/fake_retro_host_session.dart';

/// A PS1 game on a host that was not checked is marked as such wherever it shows, every time, and
/// a game on the signed release's host never is.
void main() {
  late Ps1Launcher launcher;
  var launched = false;
  final mark = find.byType(RetroUncheckedMark);

  tearDown(() {
    if (launched) launcher.dispose();
    launched = false;
  });

  /// The screens of a game that show the mark: loading, playing, its menu, Settings over it, and
  /// stopped on an error.
  Future<List<String>> markedScreens(WidgetTester tester, {required bool unchecked}) async {
    final marked = <String>[];
    void look(String screen) {
      if (mark.evaluate().isNotEmpty) marked.add(screen);
    }

    launcher = unchecked ? Ps1Launcher() : (await tester.runAsync(Ps1Launcher.withRelease))!;
    launched = true;
    final model = launcher.model..setRetroHostPs1(true);
    await tester.runAsync(
      () => launcher.start(
        status: const RetroStatus(ready: false, ended: false, error: '', errorCode: '', progressPercent: 10),
      ),
    );
    await pumpLauncher(tester, model);
    look('loading');
    launcher.session.nextStatus = fakeStatus();
    await tester.runAsync(launcher.play.host.refresh);
    await settle(tester);
    look('playing');
    model.openRetroMenu();
    await settle(tester);
    look('menu');
    model.open(Layer.settings);
    await settle(tester);
    look('settings over the game');
    model.closeOverlay();
    launcher.session.nextStatus = fakeStatus(ready: false, ended: true, errorCode: RetroErrorCode.bios);
    await tester.runAsync(launcher.play.host.refresh);
    await settle(tester);
    expect(launcher.play.problem, isNotNull);
    look('stopped on an error');
    return marked;
  }

  testWidgets('a game on an unchecked host is marked on every screen', (tester) async {
    expect(await markedScreens(tester, unchecked: true), [
      'loading',
      'playing',
      'menu',
      'settings over the game',
      'stopped on an error',
    ]);
    expect(launcher.play.unchecked, isTrue);
  });

  testWidgets('a game on the signed release is never marked', (tester) async {
    expect(await markedScreens(tester, unchecked: false), isEmpty);
    expect(launcher.play.unchecked, isFalse);
  });

  test('only a debug or test build has the mark and the unchecked host, decided when it is compiled', () {
    expect(RetroHostPlaying.retroHostBuild, RetroHostBuild.of(debug: kDebugMode));
    expect(RetroHostPlaying.runsUnchecked, kDebugMode || RetroHostBuild.testDefined);
  });
}
