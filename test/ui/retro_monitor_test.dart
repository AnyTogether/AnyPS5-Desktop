import 'dart:io';

import 'package:anyps5_desktop/core/desktop/launcher_window.dart';
import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_process.dart';
import '../support/ui_support.dart';

void main() {
  test('selected display is restored on startup and used for the emulator window', () async {
    final fixture = makeFixture();
    final prefs = Preferences()..displayDevice = 'secondary';
    final moves = <(String, int?)>[];
    final app = AppModel(
      paths: fixture.model.paths,
      persist: false,
      preferences: prefs,
      system: HostSystem.windows,
      services: LauncherServices(
        displays: () async => const [
          LauncherDisplay(id: 'secondary', width: 3440, height: 1440, primary: false),
          LauncherDisplay(id: 'primary', width: 5120, height: 1440, primary: true),
        ],
        moveToDisplay: (id, {pid}) async {
          moves.add((id, pid));
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
    await app.refreshDisplays(restoreLauncher: true);
    expect(app.displays.map((display) => display.id), ['primary', 'secondary']);
    expect(moves, [('secondary', null)]);

    final program = File(p.join(fixture.temp.path, 'emulator.exe'))..createSync();
    final disc = File(p.join(fixture.temp.path, 'game.iso'))..createSync();
    prefs.retroEmulators['ps2'] = program.path;
    final game = Game(
      folder: fixture.temp.path,
      titleId: 'PS2-TEST',
      name: 'Test game',
      names: const {},
      defaultLanguage: 'en-US',
      version: '',
      executable: ExecutableKind.disc,
      retro: (platform: RetroPlatform.ps2, path: disc.path),
    );
    app.startRetroGame = ({required installed, required program, required arguments, required logFile}) async =>
        runningFor(process);
    final launched = app.play(game);
    await pumpEventQueue();
    expect(app.stateOf(game), isA<Running>());
    expect(moves, [('secondary', null), ('secondary', process.pid)]);
    process.quit();
    await launched;

    await app.setDisplayDevice(null);
    expect(app.preferences.displayDevice, isNull);
    expect(moves, hasLength(2));
  });
}
