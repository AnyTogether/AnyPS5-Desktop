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
    final games = GameLibrary.scan(root.path);
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

    final games = GameLibrary.scan(root.path);
    expect(games.map((game) => game.name), ['Astro', 'Crash Team Racing', 'Vice City']);
    expect(games.skip(1).map((game) => p.basename(game.music!)), ['theme.wav', 'theme.wav']);
    expect(games.skip(1).map((game) => p.basename(game.background!)), ['background.png', 'background.png']);

    final descriptor = File(p.join(root.path, 'ps2', 'retro.json'));
    descriptor.writeAsStringSync(descriptor.readAsStringSync().replaceFirst('disc.iso', '../ps1/disc.cue'));
    expect(GameLibrary.scan(root.path).map((game) => game.name), ['Astro', 'Crash Team Racing']);
  });
}
