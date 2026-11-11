import 'package:anyps5_desktop/core/now_playing.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/launcher.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_now_playing.dart';
import '../support/fake_process.dart';
import '../support/ui_support.dart';

/// The quick menu's Now playing card as it looks, in English and Turkish.
void main() {
  late Fixture fixture;
  final shell = find.byType(LauncherShell);

  tearDown(() {
    T.language = Language.english;
    fixture.dispose();
  });

  Future<void> card(
    WidgetTester tester,
    Language language,
    String golden, {
    required NowPlayingTrack track,
    required bool focused,
  }) async {
    final player = FakeNowPlaying();
    fixture = makeFixture(language: language, nowPlaying: () => player);
    final model = fixture.model;
    final game = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
    model.select(model.games.indexOf(game));
    model.running = (game, runningFor(FakeGameProcess()));
    model.open(Layer.quickMenu);
    // The watch the menu asked for starts.
    await tester.idle();
    player.play(track);
    final rows = model.panelCategories().single.rows;
    expect(rows.map((row) => row.id), contains('nowPlaying'));
    if (focused) model.panelRow = rows.indexWhere((row) => row.id == 'nowPlaying');
    await pumpLauncher(tester, model);
    await expectLater(shell, matchesGoldenFile(golden));
    model.running = null;
  }

  testWidgets(
    'the quick menu: a song playing, with its cover, the card focused',
    (tester) => card(
      tester,
      Language.english,
      'goldens/quick_menu_now_playing_en.png',
      track: NowPlayingTrack(
        title: 'Night Drive',
        artist: 'The Lanterns',
        player: 'Rhythmbox',
        artwork: iconArt(0x7A3DFF, 0x1B0B5C),
      ),
      focused: true,
    ),
  );

  testWidgets(
    'the quick menu, in Turkish: paused, a player that gives no cover',
    (tester) => card(
      tester,
      Language.byCode('tr'),
      'goldens/quick_menu_now_playing_tr.png',
      track: const NowPlayingTrack(
        title: 'Gece Yolculuğu',
        artist: 'Fenerler',
        player: 'VLC media player',
        playing: false,
      ),
      focused: false,
    ),
  );
}
