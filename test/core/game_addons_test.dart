import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/game_addons.dart';
import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/installer.dart';
import 'package:anyps5_desktop/core/toolkit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_toolkit.dart';
import '../support/fixtures.dart';
import '../support/self_builder.dart';

void main() {
  late Directory temp;
  late String root;

  setUp(() {
    temp = temporaryFolder('addons');
    root = p.join(temp.path, 'Games');
    Directory(root).createSync(recursive: true);
  });
  tearDown(() => temp.deleteSync(recursive: true));

  void write(String relative, String text) {
    final file = File(p.join(root, p.joinAll(relative.split('/'))));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(text);
  }

  void makeAddon(String relative, {String? name, String? contentId}) {
    write('$relative/sce_sys/param.json', jsonEncode({
      'contentId': ?contentId,
      if (name != null)
        'localizedParameters': {
          'defaultLanguage': 'en-US',
          'en-US': {'titleName': name},
        },
    }));
    write('$relative/data.pak', 'data');
  }

  group('finding them', () {
    test('the update and add-ons beside a game are found, and are not games of their own', () {
      makeDump(root, 'PPSA01234', titleId: 'PPSA01234');
      // The update is a whole patch dump: it would scan as a game of its own.
      makeDump(root, 'PPSA01234-UPDATE', titleId: 'PPSA01234', version: '01.004.000');
      makeAddon('PPSA01234-DLC/EXPANSION0000001', name: 'The Island');
      makeAddon('PPSA01234-DLC/UP0000-PPSA01234_00-COSTUMEPACK00002');
      makeAddon('UP0000-PPSA01234_00-SOUNDTRACK000003', name: 'Soundtrack');
      write('PPSA01234-DLC/not a label/sce_sys/param.json', '{}');
      makeDump(root, 'PPSA05678', titleId: 'PPSA05678');

      final survey = GameLibrary.survey(root);
      expect(survey.games.map((game) => game.folder).map(p.basename), ['PPSA01234', 'PPSA05678']);
      final game = survey.games.first;
      expect(game.update?.version, '01.004.000');
      expect(game.update?.shortVersion, '01.004');
      expect(p.basename(game.update!.folder), 'PPSA01234-UPDATE');
      expect(game.addons.map((addon) => addon.label), ['EXPANSION0000001', 'COSTUMEPACK00002', 'SOUNDTRACK000003']);
      expect(game.addons.map((addon) => addon.name), ['The Island', 'COSTUMEPACK00002', 'Soundtrack']);
      expect(survey.incomplete, isEmpty, reason: 'the add-on folders are not half-copied games');
      expect(survey.games[1].update, isNull);
      expect(survey.games[1].addons, isEmpty, reason: "another game's add-ons are not this one's");
    });

    test("the game's folder name or its title ID name them, in any case, and -patch too", () {
      makeDump(root, 'Astro Bot', titleId: 'PPSA01234');
      makeDump(root, 'astro bot-patch', titleId: 'PPSA01234', version: '01.010.000');
      makeAddon('ppsa01234-dlc/EXPANSION0000001');
      final games = GameLibrary.scan(root);
      expect(games, hasLength(1));
      expect(games.single.update?.version, '01.010.000');
      expect(games.single.addons.map((addon) => addon.label), ['EXPANSION0000001']);
    });

    test('an update folder without its param.json is not taken for one', () {
      final folder = makeDump(root, 'PPSA01234', titleId: 'PPSA01234');
      write('PPSA01234-UPDATE/eboot.bin', 'still copying');
      final game = GameLibrary.inspect(folder)!;
      expect(game.update, isNull);
      expect(game.addons, isEmpty);
    });

    test('a content ID folder of another game, or one with an eboot, is not an add-on', () {
      final folder = makeDump(root, 'PPSA01234', titleId: 'PPSA01234');
      makeAddon('UP0000-PPSA09999_00-EXPANSION0000001');
      makeDump(root, 'UP0000-PPSA01234_00-FULLGAME00000000', titleId: 'PPSA01234');
      expect(GameLibrary.inspect(folder)!.addons, isEmpty);
    });

    test('labels come from the content ID or a folder named by the label', () {
      expect(GameAddons.labelOfContentId('UP0000-PPSA01234_00-EXPANSION0000001'), 'EXPANSION0000001');
      expect(GameAddons.labelOfContentId('UP0000-PPSA01234-00-EXPANSION0000001'), isNull);
      expect(GameAddons.labelOfContentId('UP0000-PPSA01234_00-EXPANSION00000!1'), isNull);
      expect(GameAddons.labelOfFolderNamed('SEASONPASS'), 'SEASONPASS');
      expect(GameAddons.labelOfFolderNamed('Season Pass'), isNull);
      expect(GameAddons.labelOfFolderNamed('SEASONPASS0000000'), isNull, reason: 'seventeen characters is too long');
      expect(GameAddons.shortVersion('01.004.000'), '01.004');
      expect(GameAddons.shortVersion('01.04'), '01.04');
    });
  });

  group('passing them on', () {
    test('the engine gets the update and the add-on folders, separated like PATH', () {
      final folder = makeDump(root, 'PPSA01234', titleId: 'PPSA01234');
      makeDump(root, 'PPSA01234-UPDATE', titleId: 'PPSA01234', version: '01.004.000');
      makeAddon('PPSA01234-DLC/COSTUMEPACK00002');
      makeAddon('PPSA01234-DLC/EXPANSION0000001');
      final game = GameLibrary.inspect(folder)!;
      expect(game.addonEnvironment['ANYPS5_UPDATE_DIR'], p.join(root, 'PPSA01234-UPDATE'));
      final dlc = p.join(root, 'PPSA01234-DLC');
      expect(GameAddons.environment(update: game.update, addons: game.addons, windows: false)['ANYPS5_ADDCONT_DIRS'],
          '${p.join(dlc, 'COSTUMEPACK00002')}:${p.join(dlc, 'EXPANSION0000001')}');
      expect(GameAddons.environment(addons: game.addons, windows: true)['ANYPS5_ADDCONT_DIRS'],
          '${p.join(dlc, 'COSTUMEPACK00002')};${p.join(dlc, 'EXPANSION0000001')}');
      expect(GameLibrary.inspect(makeDump(root, 'Plain', titleId: 'PPSA00002'))!.addonEnvironment, isEmpty,
          reason: 'a game without them starts as before');
    });

    test("the update's executable and modules are the ones relinked", () async {
      final folder = makeDump(root, 'PPSA01234', titleId: 'PPSA01234', eboot: const [0]);
      File(p.join(folder, 'eboot.bin')).writeAsBytesSync(typicalSelf());
      write('PPSA01234/sce_module/libshared.prx', 'base shared');
      write('PPSA01234/sce_module/libbase.prx', 'base only');
      makeDump(root, 'PPSA01234-UPDATE', titleId: 'PPSA01234', version: '01.004.000');
      write('PPSA01234-UPDATE/sce_module/libshared.prx', 'updated shared');
      write('PPSA01234-UPDATE/sce_module/libnew.prx', 'update only');
      final game = GameLibrary.inspect(folder)!;
      expect(Installer.modulesOf(game, HostSystem.linux), ['sce_module/libbase.prx', 'sce_module/libnew.prx', 'sce_module/libshared.prx']);
      expect(Installer.source(game, 'eboot.bin'), p.join(root, 'PPSA01234-UPDATE', 'eboot.bin'));
      expect(Installer.source(game, 'sce_module/libshared.prx'), p.join(root, 'PPSA01234-UPDATE', 'sce_module', 'libshared.prx'));
      expect(Installer.source(game, 'sce_module/libbase.prx'), p.join(folder, 'sce_module', 'libbase.prx'));

      // Unlocked, the update's ELF is relinked, not the game's SELF, and the record says which update.
      final toolkit = Toolkit(makeFakeToolkit(p.join(temp.path, 'toolkit')));
      final lines = <String>[];
      final plain = {'sce_module/libshared.prx', 'sce_module/libbase.prx', 'sce_module/libnew.prx'};
      for (final module in plain) {
        File(Installer.source(game, module)).writeAsBytesSync([...elfHead, 1]);
      }
      final installed = await Installer(game: game, toolkit: toolkit, root: root, onLog: lines.add).run();
      expect(lines.where((line) => line.startsWith('eboot.bin: unwrapped')), isEmpty);
      expect(Installer.record(installed, system: HostSystem.linux)!.update, '01.004.000');
    });

    test('an update changes the relink key, so a kept relink is not reused', () {
      final folder = makeDump(root, 'PPSA01234', titleId: 'PPSA01234');
      final toolkit = Toolkit(makeFakeToolkit(p.join(temp.path, 'toolkit')));
      final before = GameLibrary.inspect(folder)!;
      final key = Installer.relinkKey(before, toolkit, Installer.modulesOf(before, toolkit.system), null);
      makeDump(root, 'PPSA01234-UPDATE', titleId: 'PPSA01234', version: '01.004.000');
      final after = GameLibrary.inspect(folder)!;
      expect(Installer.relinkKey(after, toolkit, Installer.modulesOf(after, toolkit.system), null), isNot(key));
    });

    test('old install records have no update', () {
      final record = InstallRecord.fromJson({
        'source': '/games/A',
        'titleID': 'PPSA01234',
        'toolkit': '1',
        'date': '2026-10-01T00:00:00Z',
      });
      expect(record.update, isNull);
      expect(record.toJson().containsKey('update'), isFalse);
    });
  });
}
