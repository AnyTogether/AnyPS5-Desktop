import 'dart:io';

import 'package:anyps5_desktop/core/game_library.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fixtures.dart';

void main() {
  late Directory root;

  setUp(() => root = temporaryFolder('library'));
  tearDown(() => root.deleteSync(recursive: true));

  test('reads a dump: title ID, names, version, pictures and executable kind', () {
    final folder = makeDump(
      root.path,
      'Game',
      titleId: 'PPSA01234',
      version: '01.002.000',
      names: {'en-US': 'Astro', 'tr-TR': 'Astro TR', 'fr-FR': 'Astro FR'},
      pictures: ['icon0.png', 'pic0.png', 'snd0.at9'],
    );
    final game = GameLibrary.inspect(folder)!;
    expect(game.titleId, 'PPSA01234');
    expect(game.name, 'Astro');
    expect(game.names, {'en-US': 'Astro', 'tr-TR': 'Astro TR', 'fr-FR': 'Astro FR'});
    expect(game.version, '01.002.000');
    expect(game.executable, ExecutableKind.elf);
    expect(game.icon, p.join(folder, 'sce_sys', 'icon0.png'));
    expect(game.background, p.join(folder, 'sce_sys', 'pic0.png'));
    expect(game.music, p.join(folder, 'sce_sys', 'snd0.at9'));
    expect(game.slug, 'ppsa01234');
  });

  test('an ignore marker excludes a runtime copy from scans without changing direct inspection', () {
    final dump = makeDump(root.path, 'Dump', titleId: 'PPSA01234');
    final runtime = makeDump(p.join(root.path, 'Retest', 'runtime'), 'app0', titleId: 'PPSA01234');
    expect(GameLibrary.scan(root.path), hasLength(2));

    File(p.join(runtime, '.anyps5-ignore')).createSync();
    expect(GameLibrary.scan(root.path).single.folder, dump);
    expect(GameLibrary.inspect(runtime)?.titleId, 'PPSA01234');
  });

  test('the age ratings of param.json, when it has them', () {
    final rated = makeDump(root.path, 'Rated', ageLevel: {'default': 16, 'US': 13, 'DE': 12, 'bad': 'x'});
    expect(GameLibrary.inspect(rated)!.ageLevels, {'default': 16, 'US': 13, 'DE': 12});
    expect(GameLibrary.inspect(makeDump(root.path, 'Plain'))!.ageLevels, isNull);
  });

  test('a dump laid out as Silksong\'s (PPSA12544-app0): its theme song is found; a game without one has none', () {
    // sce_sys as the real dump has it: .dds beside the .png pictures, pic1/pic2, trophy2, snd0.at9.
    final silksong = makeDump(
      root.path,
      'PPSA12544-app0',
      titleId: 'PPSA12544',
      names: {'en-US': 'Hollow Knight: Silksong'},
      pictures: ['icon0.png', 'icon0.dds', 'pic0.png', 'pic0.dds', 'pic1.png', 'pic1.dds', 'pic2.png', 'snd0.at9'],
      files: {'sce_sys/trophy2/trophy00.ucp': 'x', 'Media/data.bin': 'x', 'sce_module/libc.prx': 'x'},
    );
    final game = GameLibrary.scan(root.path).single;
    expect(game.folder, silksong);
    expect(game.music, p.join(silksong, 'sce_sys', 'snd0.at9'));
    expect(game.background, p.join(silksong, 'sce_sys', 'pic0.png'));
    final quiet = makeDump(root.path, 'Quiet', titleId: 'PPSA00002', pictures: ['icon0.png', 'pic0.png']);
    expect(GameLibrary.inspect(quiet)!.music, isNull, reason: 'no snd0.at9: silence, not an error');
  });

  test('the default language picks the name, inside localizedParameters or at the top', () {
    final inside = makeDump(root.path, 'A', names: {'en-US': 'English', 'ja-JP': 'Japanese'}, defaultLanguage: 'ja-JP');
    final top = makeDump(
      root.path,
      'B',
      names: {'en-US': 'English', 'de-DE': 'German'},
      defaultLanguage: 'de-DE',
      defaultLanguageAtTop: true,
    );
    final missing = makeDump(root.path, 'C', names: {'en-US': 'English'}, defaultLanguage: 'ko-KR');
    expect(GameLibrary.inspect(inside)!.name, 'Japanese');
    expect(GameLibrary.inspect(top)!.name, 'German');
    expect(GameLibrary.inspect(missing)!.name, 'English');
  });

  test('nameFor follows the launcher language, by tag or by language prefix', () {
    final game = GameLibrary.inspect(makeDump(root.path, 'G', names: {'en-US': 'Hello', 'tr-TR': 'Merhaba'}))!;
    expect(game.nameFor(['tr-TR']), 'Merhaba');
    expect(game.nameFor(['tr']), 'Merhaba');
    expect(game.nameFor(['de-DE', 'tr-TR']), 'Merhaba');
    expect(game.nameFor(['de-DE']), 'Hello');
  });

  test('missing fields fall back: folder name as title ID, title ID as name, version 1.0', () {
    final folder = p.join(root.path, 'CUSA99999');
    Directory(p.join(folder, 'sce_sys')).createSync(recursive: true);
    File(p.join(folder, 'sce_sys', 'param.json')).writeAsStringSync('{}');
    File(p.join(folder, 'eboot.bin')).writeAsBytesSync(elfHead);
    final game = GameLibrary.inspect(folder)!;
    expect(game.titleId, 'CUSA99999');
    expect(game.name, 'CUSA99999');
    expect(game.version, '1.0');
    expect(game.icon, isNull);
  });

  test('a param.json with a byte order mark is read', () {
    final folder = makeDump(root.path, 'Bom', names: {'en-US': 'With BOM'}, bom: true);
    expect(GameLibrary.inspect(folder)!.name, 'With BOM');
  });

  test('executable kinds: SELF container, re-signed with .esbak, unreadable', () {
    final container = makeDump(root.path, 'Self', eboot: selfHead);
    final resigned = makeDump(root.path, 'Resigned', eboot: [1, 2, 3, 4]);
    File(p.join(resigned, 'eboot.bin.esbak')).writeAsBytesSync(elfHead);
    final encrypted = makeDump(root.path, 'Encrypted', eboot: [9, 9, 9, 9]);
    expect(GameLibrary.inspect(container)!.executable, ExecutableKind.container);
    expect(GameLibrary.inspect(resigned)!.executable, ExecutableKind.container);
    expect(GameLibrary.inspect(encrypted)!.executable, ExecutableKind.unreadable);
  });

  test('not a dump: no eboot.bin, no param.json, or param.json that is not an object', () {
    final noEboot = Directory(p.join(root.path, 'NoEboot', 'sce_sys'))..createSync(recursive: true);
    File(p.join(noEboot.path, 'param.json')).writeAsStringSync('{"titleId":"X"}');
    final noParam = Directory(p.join(root.path, 'NoParam'))..createSync();
    File(p.join(noParam.path, 'eboot.bin')).writeAsBytesSync(elfHead);
    final broken = makeDump(root.path, 'Broken');
    File(p.join(broken, 'sce_sys', 'param.json')).writeAsStringSync('[1, 2]');
    expect(GameLibrary.inspect(p.join(root.path, 'NoEboot')), isNull);
    expect(GameLibrary.inspect(noParam.path), isNull);
    expect(GameLibrary.inspect(broken), isNull);
  });

  test('scan finds dumps three levels down, sorted by name, skipping the store and hidden folders', () {
    makeDump(root.path, 'zeta', names: {'en-US': 'Zeta'});
    makeDump(p.join(root.path, 'one'), 'alpha', names: {'en-US': 'alpha'});
    makeDump(p.join(root.path, 'one', 'two'), 'Beta', names: {'en-US': 'Beta'});
    makeDump(p.join(root.path, 'a', 'b', 'c', 'd'), 'TooDeep', names: {'en-US': 'Too deep'});
    makeDump(p.join(root.path, GameLibrary.storeName), 'Stored', names: {'en-US': 'Stored'});
    makeDump(p.join(root.path, '.hidden'), 'Hidden', names: {'en-US': 'Hidden'});
    makeDump(p.join(root.path, 'sce_module'), 'Module', names: {'en-US': 'Module'});
    // A dump inside a dump is part of it, not another game.
    makeDump(p.join(root.path, 'zeta'), 'inner', names: {'en-US': 'Inner'});
    final games = GameLibrary.scan(root.path);
    expect(games.map((game) => game.name), ['alpha', 'Beta', 'Zeta']);
  });

  test('scan of a folder that does not exist finds nothing', () {
    expect(GameLibrary.scan(p.join(root.path, 'missing')), isEmpty);
  });

  group('several games folders', () {
    late String first;
    late String second;

    setUp(() {
      first = p.join(root.path, 'first');
      second = p.join(root.path, 'second');
    });

    test('the library is every folder\'s games, sorted by name, with each folder\'s count', () {
      makeDump(first, 'zeta', titleId: 'PPSA00026', names: {'en-US': 'Zeta'});
      makeDump(second, 'alpha', titleId: 'PPSA00001', names: {'en-US': 'Alpha'});
      makeDump(p.join(second, 'more'), 'mid', titleId: 'PPSA00013', names: {'en-US': 'Mid'});
      final survey = GameLibrary.surveyAll([first, second]);
      expect(survey.games.map((game) => game.name), ['Alpha', 'Mid', 'Zeta']);
      expect(survey.folders, {first: 1, second: 2});
      expect(survey.roots[survey.games.first.id], second);
      expect(survey.roots[survey.games.last.id], first);
    });

    test('a title in two folders shows once, from the folder that comes first; two dumps in one folder both show', () {
      final kept = makeDump(second, 'copy', titleId: 'PPSA00042', names: {'en-US': 'Shared'});
      makeDump(first, 'copy', titleId: 'PPSA00042', names: {'en-US': 'Shared'});
      makeDump(second, 'copy2', titleId: 'PPSA00042', names: {'en-US': 'Shared'});
      makeDump(first, 'other', titleId: 'PPSA00043', names: {'en-US': 'Other'});
      final survey = GameLibrary.surveyAll([second, first]);
      expect(survey.games.where((game) => game.titleId == 'PPSA00042').map((game) => game.folder), [
        kept,
        p.join(second, 'copy2'),
      ], reason: 'both of the first folder\'s dumps, none of the later one\'s');
      expect(survey.games.map((game) => game.titleId), contains('PPSA00043'));
      expect(survey.folders, {second: 2, first: 2}, reason: 'the counts are what each folder holds');
    });

    test('a folder inside another adds nothing twice', () {
      makeDump(p.join(first, 'inner'), 'one', titleId: 'PPSA00051', names: {'en-US': 'One'});
      final survey = GameLibrary.surveyAll([first, p.join(first, 'inner')]);
      expect(survey.games.map((game) => game.titleId), ['PPSA00051']);
    });

    test('a folder that is not there (its drive unplugged) is not connected; its games come back with it', () {
      makeDump(first, 'here', titleId: 'PPSA00061', names: {'en-US': 'Here'});
      var survey = GameLibrary.surveyAll([first, second]);
      expect(survey.games.map((game) => game.titleId), ['PPSA00061']);
      expect(survey.folders, {first: 1, second: null});
      makeDump(second, 'back', titleId: 'PPSA00062', names: {'en-US': 'Back'});
      survey = GameLibrary.surveyAll([first, second]);
      expect(survey.games.map((game) => game.titleId), ['PPSA00062', 'PPSA00061']);
      expect(survey.folders, {first: 1, second: 1});
    });

    test('dumps still being copied are listed from every folder', () {
      Directory(p.join(first, 'half', 'sce_sys')).createSync(recursive: true);
      Directory(p.join(second, 'part', 'sce_sys')).createSync(recursive: true);
      expect(GameLibrary.surveyAll([first, second]).incomplete, [p.join(first, 'half'), p.join(second, 'part')]);
    });
  });

  test('size adds up the files', () {
    final folder = makeDump(root.path, 'Sized', files: {'data/a.bin': '12345', 'b.bin': '123'});
    expect(GameLibrary.size(folder), greaterThanOrEqualTo(8));
  });
}
