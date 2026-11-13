import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/game_library.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fixtures.dart';

void main() {
  test('disc discovery lists separate CUE games and groups a multi-disc playlist', () {
    final root = temporaryFolder('bare-retro-library');
    addTearDown(() => root.deleteSync(recursive: true));
    for (final stem in ['Game A', 'Game B Disc 1', 'Game B Disc 2']) {
      File(p.join(root.path, '$stem.bin')).createSync();
      File(p.join(root.path, '$stem.cue')).writeAsStringSync('FILE "$stem.bin" BINARY\n  TRACK 01 MODE2/2352\n');
    }
    File(p.join(root.path, 'Game B.m3u')).writeAsStringSync('Game B Disc 1.cue\nGame B Disc 2.cue\n');
    File(p.join(root.path, 'Missing.cue')).writeAsStringSync('FILE "Missing.bin" BINARY\n  TRACK 01 MODE2/2352\n');
    final games = GameLibrary.scan(root.path, includeRetro: true);
    expect(games.map((game) => game.name), ['Game A', 'Game B']);
    expect(games.map((game) => game.id).toSet(), hasLength(2));
    expect(games.map((game) => game.titleId).toSet(), hasLength(2));
    expect(games.every((game) => game.retro?.platform == RetroPlatform.ps1), isTrue);
  });

  test('one library presents PS5 and configured PS1 and PS2 discs with local media', () {
    final root = temporaryFolder('retro-library');
    addTearDown(() => root.deleteSync(recursive: true));
    makeDump(root.path, 'PS5', titleId: 'PPSA01234', names: {'en-US': 'Astro'});
    for (final (platform, id, title, disc) in [
      ('ps1', 'SCUS94426', 'Crash Team Racing', 'disc.cue'),
      ('ps2', 'SLUS20552', 'Vice City', 'disc.iso'),
    ]) {
      final folder = Directory(p.join(root.path, platform))..createSync();
      for (final file in [disc, 'cover.png', 'background.png', 'theme.wav']) {
        File(p.join(folder.path, file)).createSync();
      }
      File(p.join(folder.path, 'retro.json')).writeAsStringSync(
        jsonEncode({
          'platform': platform,
          'titleId': id,
          'name': title,
          'disc': disc,
          'icon': 'cover.png',
          'background': 'background.png',
          'music': 'theme.wav',
        }),
      );
    }

    final games = GameLibrary.scan(root.path, includeRetro: true);
    expect(games.map((game) => game.name), ['Astro', 'Crash Team Racing', 'Vice City']);
    expect(GameLibrary.scan(root.path).map((game) => game.name), ['Astro']);
    expect(games.skip(1).map((game) => p.basename(game.music!)), ['theme.wav', 'theme.wav']);
    expect(games.skip(1).map((game) => p.basename(game.background!)), ['background.png', 'background.png']);

    final descriptor = File(p.join(root.path, 'ps2', 'retro.json'));
    descriptor.writeAsStringSync(descriptor.readAsStringSync().replaceFirst('disc.iso', '../ps1/disc.cue'));
    expect(GameLibrary.scan(root.path, includeRetro: true).map((game) => game.name), ['Astro', 'Crash Team Racing']);
  });

  test('a disc keeps its identifier when its games folder moves, and lists only its own files', () {
    final first = temporaryFolder('retro-drive-e');
    final second = temporaryFolder('retro-drive-f');
    addTearDown(() {
      first.deleteSync(recursive: true);
      second.deleteSync(recursive: true);
    });
    List<Game> discs(Directory root) {
      final shelf = Directory(p.join(root.path, 'PS1'))..createSync();
      for (final stem in ['Game B Disc 1', 'Game B Disc 2', 'Solo']) {
        File(p.join(shelf.path, '$stem.bin')).createSync();
        File(p.join(shelf.path, '$stem.cue')).writeAsStringSync('FILE "$stem.bin" BINARY\n  TRACK 01 MODE2/2352\n');
      }
      File(p.join(shelf.path, 'Game B.m3u')).writeAsStringSync('Game B Disc 1.cue\nGame B Disc 2.cue\n');
      return GameLibrary.scan(root.path, includeRetro: true, cache: RetroScanCache());
    }

    final before = discs(first), after = discs(second);
    expect(before.map((game) => game.id), [
      matches(r'^retro:ps1:\d+:PS1/Game B\.m3u$'),
      matches(r'^retro:ps1:\d+:PS1/Solo\.cue$'),
    ]);
    expect(after.map((game) => game.id), before.map((game) => game.id));
    expect(after.map((game) => game.titleId), before.map((game) => game.titleId));
    final shelf = p.join(first.path, 'PS1');
    expect(before.first.files, [
      for (final name in ['Game B.m3u', 'Game B Disc 1.cue', 'Game B Disc 1.bin', 'Game B Disc 2.cue', 'Game B Disc 2.bin'])
        p.join(shelf, name),
    ]);
    expect(before.last.files, [p.join(shelf, 'Solo.cue'), p.join(shelf, 'Solo.bin')]);
  });

  test('two games folders with a different disc at the same path both show it', () {
    final roots = [temporaryFolder('retro-same-path-1'), temporaryFolder('retro-same-path-2')];
    addTearDown(() {
      for (final root in roots) {
        root.deleteSync(recursive: true);
      }
    });
    for (final (index, root) in roots.indexed) {
      File(p.join(root.path, 'Game.bin')).writeAsBytesSync(List.filled(100 * (index + 1), 0));
      File(p.join(root.path, 'Game.cue')).writeAsStringSync('FILE "Game.bin" BINARY\n  TRACK 01 MODE2/2352\n');
    }
    final games = GameLibrary.surveyAll([for (final root in roots) root.path], includeRetro: true, cache: RetroScanCache()).games;
    expect(games, hasLength(2));
    expect(games.map((game) => game.id).toSet(), hasLength(2));
  });

  test('a rescan reads a disc file again only when its size or modification time changed', () {
    final root = temporaryFolder('retro-cache');
    addTearDown(() => root.deleteSync(recursive: true));
    final cache = RetroScanCache();
    File(p.join(root.path, 'Game.bin')).createSync();
    final cue = File(p.join(root.path, 'Game.cue'))..writeAsStringSync('FILE "Game.bin" BINARY\n  TRACK 01 MODE2/2352\n');
    final modified = DateTime(2026, 11, 1, 12);
    cue.setLastModifiedSync(modified);
    List<String> names() => [for (final game in GameLibrary.surveyAll([root.path], includeRetro: true, cache: cache).games) game.name];
    expect(names(), ['Game']);
    expect(cache.length, 1);

    // The same size and time: what was read is used, the contents are not read again.
    cue.writeAsStringSync('FILE "Game.bin" BINARY\n  TRACK 01 AUDIO/2352\n'.padRight(cue.lengthSync()));
    cue.setLastModifiedSync(modified);
    expect(names(), ['Game']);

    cue.setLastModifiedSync(modified.add(const Duration(minutes: 1)));
    expect(names(), isEmpty);
    expect(GameLibrary.surveyAll([root.path], cache: cache).games, isEmpty, reason: 'a PS5 scan reads no disc');

    cue.deleteSync();
    GameLibrary.surveyAll([root.path], includeRetro: true, cache: cache);
    expect(cache.length, 0, reason: 'a file gone from the library is let go');
  });
}
