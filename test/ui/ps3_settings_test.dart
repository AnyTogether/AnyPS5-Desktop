import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/ps3_settings_model.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/ui_support.dart';

void main() {
  test('PS3 exposes validated graphics, CPU, I/O and audio options before first Play', () {
    final fixture = makeFixture(system: HostSystem.windows);
    final model = fixture.model;
    addTearDown(() {
      model.dispose();
      fixture.dispose();
    });

    final panels = model.retroSettings.categories(RetroPlatform.ps3);
    expect(
      panels.map((panel) => panel.id),
      containsAll(['retro-ps3', 'retro-ps3-graphics', 'retro-ps3-cpu', 'retro-ps3-io', 'retro-ps3-audio']),
    );
    final rows = panels.expand((panel) => panel.rows).toList();
    expect(rows.singleWhere((row) => row.title == 'Renderer').kind, isA<InfoRow>());
    final decoder = rows.singleWhere((row) => row.title == 'SPU Decoder');
    expect(decoder.detail, contains('next launch'));
    expect((decoder.kind as ChoiceRow).options, contains('Recompiler (LLVM)'));
    final diskCache = rows.singleWhere((row) => row.title == 'Disk Cache Size').kind as ChoiceRow;
    expect(diskCache.options, isNot(contains('Wipe on Exit')));

    model.openSettingsCategory('emulators');
    model.panelRow = 2;
    model.panelCommand(Command.select);
    expect(
      model.panelCategories().single.rows.map((row) => row.title),
      containsAll(['Setup', 'Graphics', 'Performance & Compatibility', 'I/O', 'Audio', 'Advanced']),
    );
  });

  test('PS3 game settings inherit shared defaults and isolate overrides by title', () {
    final fixture = makeFixture(system: HostSystem.windows);
    final model = fixture.model;
    addTearDown(() {
      model.dispose();
      fixture.dispose();
    });

    Game game(String titleId) => Game(
      folder: titleId,
      titleId: titleId,
      name: titleId,
      names: const {},
      defaultLanguage: 'en',
      version: '',
      executable: ExecutableKind.disc,
      retro: (platform: RetroPlatform.ps3, path: '$titleId/PS3_DISC.SFB'),
    );

    ChoiceRow decoder({Game? game}) {
      final panels = model.retroSettings.categories(RetroPlatform.ps3, game: game);
      return panels.expand((panel) => panel.rows).singleWhere((row) => row.id == 'rpcs3_spu_decoder').kind as ChoiceRow;
    }

    final first = game('PS3-TEST00001');
    final second = game('PS3-TEST00002');
    final shared = decoder();
    shared.set(shared.options.indexOf('Recompiler (ASMJIT)'));
    expect(model.preferences.retroPs3Defaults['rpcs3_spu_decoder'], 'asmjit');
    final gameChoice = decoder(game: first);
    expect(gameChoice.options[gameChoice.selected], 'Use shared default (Recompiler (ASMJIT))');
    gameChoice.set(gameChoice.options.indexOf('Recompiler (LLVM)'));
    expect(decoder(game: first).selected, greaterThan(0));
    expect(decoder(game: second).selected, 0);
    expect(model.preferences.retroPs3Graphics[first.titleId], {'rpcs3_spu_decoder': 'llvm'});
    final reloaded = Preferences.fromJson(model.preferences.toJson());
    expect(reloaded.retroPs3Defaults['rpcs3_spu_decoder'], 'asmjit');
    expect(reloaded.retroPs3Graphics[first.titleId], {'rpcs3_spu_decoder': 'llvm'});
    decoder(game: first).set(0);
    expect(model.preferences.retroPs3Graphics.containsKey(first.titleId), isFalse);
    expect(decoder(game: first).selected, 0);
  });

  test('only GPU choices are listed as in-game graphics keys', () {
    expect(Ps3SettingsModel.graphicsKeys, contains('rpcs3_resolution_scale'));
    expect(Ps3SettingsModel.graphicsKeys, isNot(contains('rpcs3_renderer')));
    expect(Ps3SettingsModel.graphicsKeys, isNot(contains('rpcs3_spu_decoder')));
    expect(Ps3SettingsModel.graphicsKeys, isNot(contains('rpcs3_disk_cache_size')));
  });
}
