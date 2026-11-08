import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/components.dart';
import 'package:anyps5_desktop/ui/retro_menu_window.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_process.dart';
import '../support/ui_support.dart';
import 'desktop_features_test.dart' show FakeDesktop;

void main() {
  testWidgets('fullscreen retro Quick Menu clips the launcher and clears the clip when dismissed', (tester) async {
    final fixture = makeFixture();
    final calls = <(int?, Rect?)>[];
    final app = AppModel(
      paths: fixture.model.paths,
      persist: false,
      preferences: Preferences()..onboarded = true,
      services: LauncherServices(
        desktop: FakeDesktop(),
        retroMenuRegion: (pid, region) async {
          calls.add((pid, region));
          return true;
        },
      ),
    );
    final process = FakeGameProcess();
    addTearDown(() {
      process.quit();
      app.dispose();
      fixture.model.dispose();
      fixture.dispose();
    });
    final game = Game(
      folder: fixture.temp.path,
      titleId: 'PS2-TEST',
      name: 'Test game',
      names: const {},
      defaultLanguage: 'en-US',
      version: '',
      executable: ExecutableKind.disc,
      retro: (platform: RetroPlatform.ps2, path: 'test.iso'),
    );
    app.running = (game, runningFor(process));
    app.windowFullscreen = true;
    app.overlay = Layer.quickMenu;
    await tester.pumpWidget(
      LayoutScale(
        scale: 0.5,
        child: ListenableBuilder(
          listenable: app,
          builder: (_, _) => RetroMenuWindow(model: app),
        ),
      ),
    );
    final region = calls.single.$2!;
    expect(calls.single.$1, process.pid);
    expect(region.center, tester.view.physicalSize.center(Offset.zero));
    expect(region.width, 380 * tester.view.devicePixelRatio);

    app.resumeGame();
    await tester.pump();
    expect(calls.last, (null, null));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
