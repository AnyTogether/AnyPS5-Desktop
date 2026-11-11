import 'dart:io';

import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/game_settings.dart';
import 'package:anyps5_desktop/core/shared_settings.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/sharing_model.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_process.dart';
import '../support/fake_toolkit.dart';
import '../support/self_builder.dart';
import '../support/ui_support.dart';

/// A game's Advanced page: Custom relinker options under Rebuild options and Launch options in
/// their own Launch section, as on the Mac. Each keystroke is checked: a valid text is saved at
/// once, one that fails is kept unsaved and the row says why.
void main() {
  late Fixture fixture;
  late AppModel model;
  String? savedTo;
  String? picked;

  setUp(() {
    savedTo = null;
    picked = null;
    fixture = makeFixture(
      saveFileAs: (name, label, extensions) async => savedTo == null ? null : p.join(savedTo!, name),
      pickFile: (label, extensions) async => picked,
    );
    model = fixture.model;
  });

  tearDown(() {
    T.language = Language.english;
    model.dispose();
    fixture.dispose();
  });

  Game titled(String titleId) => model.games.firstWhere((game) => game.titleId == titleId);
  Game orbit() => titled('PPSA01001');
  PanelRow row(String id) => model
      .panelCategories()
      .expand((category) => category.rows)
      .firstWhere((row) => row.id == id, orElse: () => throw StateError('no row $id'));

  void openAdvanced(Game game) {
    if (model.overlay != null) model.closeOverlay();
    model.select(model.games.indexOf(game));
    model.open(Layer.gameSettings);
    (row('advanced').kind as ActionRow).run();
    expect(model.overlay, Layer.advanced);
  }

  Future<void> until(bool Function() condition) async {
    for (var tries = 0; tries < 2000 && !condition(); tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(condition(), isTrue);
  }

  void type(String id, String text) => (row(id).kind as TextRow).set(text);

  group('the rows', () {
    test('Custom relinker options after the trace switch, then Launch with Launch options, before Sharing', () {
      openAdvanced(orbit());
      final ids = model.panelCategories().single.rows.map((row) => row.id).toList();
      final rebuild = ids.indexOf('relinkerSection');
      expect(ids.sublist(rebuild, rebuild + 6), [
        'relinkerSection',
        'relinker---trace-imports',
        'relinkerCustomOptions',
        'launchSection',
        'launchOptions',
        'shareSection',
      ]);
      expect(row('launchSection').title, 'Launch');
      final custom = row('relinkerCustomOptions');
      expect(custom.title, 'Custom relinker options');
      expect(custom.detail, '${T.text('relinkerCustomOptionsDetail')}\n${T.text('customOptionsWarning')}');
      expect((custom.kind as TextRow).value, '');
      final launch = row('launchOptions');
      expect(launch.title, 'Launch options');
      expect(launch.detail, '${T.text('launchOptionsDetail')}\n${T.text('customOptionsWarning')}');
    });

    test('in Turkish too', () {
      T.language = Language.byCode('tr');
      openAdvanced(orbit());
      expect(row('relinkerCustomOptions').title, 'Özel relinker seçenekleri');
      expect(row('launchSection').title, 'Başlatma');
      expect(row('launchOptions').title, 'Başlatma seçenekleri');
      type('relinkerCustomOptions', '--windows');
      expect(row('relinkerCustomOptions').detail, '--windows başlatıcıya bırakılır. Kaydedilmedi.');
    });
  });

  group('typing', () {
    test('a valid text is saved at each keystroke, as typed; nothing left is none', () {
      openAdvanced(orbit());
      type('relinkerCustomOptions', '--lazy');
      expect(model.currentSettings(orbit()).customRelinkerOptions, isNull, reason: 'not an option yet');
      type('relinkerCustomOptions', '--lazy-binding');
      expect(model.currentSettings(orbit()).customRelinkerOptions, '--lazy-binding');
      type('relinkerCustomOptions', '--lazy-binding  --exclude-sce-module "lib a.sprx"');
      expect(model.currentSettings(orbit()).customRelinkerOptions, '--lazy-binding  --exclude-sce-module "lib a.sprx"');
      expect(model.currentSettings(orbit()).customRelinkerWords, [
        '--lazy-binding',
        '--exclude-sce-module',
        'lib a.sprx',
      ]);
      expect(row('relinkerCustomOptions').detail, endsWith(T.text('customOptionsWarning')));
      type('relinkerCustomOptions', '   ');
      expect(model.currentSettings(orbit()).customRelinkerOptions, isNull);

      type('launchOptions', 'APS5_REPORT=0 --aps5-report=off');
      expect(model.currentSettings(orbit()).launchOptions, 'APS5_REPORT=0 --aps5-report=off');
    });

    test('a text that fails is kept as typed, not saved, and the row says why', () {
      openAdvanced(orbit());
      type('relinkerCustomOptions', '--registry');
      final cases = {
        '--registry --windows': T.format('relinkerOptionLauncher', ['--windows']),
        '--dry-run': T.format('relinkerOptionBreaks', ['--dry-run']),
        '--trace-imports': T.format('relinkerOptionSwitch', ['--trace-imports']),
        '--fast': T.format('relinkerOptionUnknown', ['--fast']),
        '--exclude-sce-module': T.format('relinkerOptionValue', ['--exclude-sce-module']),
        'eboot.bin': T.format('relinkerOptionPositional', ['eboot.bin']),
        '""': T.format('relinkerOptionPositional', ['""']),
        "--registry 'open": T.text('optionsQuoteOpen'),
      };
      for (final MapEntry(key: text, value: message) in cases.entries) {
        type('relinkerCustomOptions', text);
        final options = row('relinkerCustomOptions');
        expect(options.detail, T.format('optionsNotSaved', [message]), reason: text);
        expect((options.kind as TextRow).value, text, reason: 'the field keeps what was typed');
        expect(model.currentSettings(orbit()).customRelinkerOptions, '--registry', reason: text);
      }
      expect(row('relinkerCustomOptions').detail, 'A quote is not closed. Not saved.');

      // Launch options only stop at a quote left open; the other row keeps its own text.
      type('launchOptions', 'A="b');
      expect(row('launchOptions').detail, 'A quote is not closed. Not saved.');
      expect(model.currentSettings(orbit()).launchOptions, isNull);
      type('launchOptions', 'A="b c"');
      expect(model.currentSettings(orbit()).launchOptions, 'A="b c"');
      expect(row('launchOptions').detail, endsWith(T.text('customOptionsWarning')));
      expect((row('relinkerCustomOptions').kind as TextRow).value, "--registry 'open");

      // Fixed, it is saved and the draft goes.
      type('relinkerCustomOptions', "--registry '--lazy-binding'");
      expect(model.currentSettings(orbit()).customRelinkerOptions, "--registry '--lazy-binding'");
      expect(row('relinkerCustomOptions').detail, endsWith(T.text('customOptionsWarning')));
    });

    test('a draft belongs to its game', () {
      openAdvanced(orbit());
      type('relinkerCustomOptions', '--windows');
      openAdvanced(titled('PPSA02002'));
      expect((row('relinkerCustomOptions').kind as TextRow).value, '');
      expect(row('relinkerCustomOptions').detail, endsWith(T.text('customOptionsWarning')));
      openAdvanced(orbit());
      expect((row('relinkerCustomOptions').kind as TextRow).value, '--windows');
    });

    test('Reset clears both, and what was typed and not saved', () {
      openAdvanced(orbit());
      type('relinkerCustomOptions', '--lazy-binding');
      type('launchOptions', 'A=1');
      type('launchOptions', 'A="');
      (row('resetAdvanced').kind as ActionRow).run();
      final settings = model.currentSettings(orbit());
      expect(settings.customRelinkerOptions, isNull);
      expect(settings.launchOptions, isNull);
      expect((row('launchOptions').kind as TextRow).value, '');
      expect(row('launchOptions').detail, endsWith(T.text('customOptionsWarning')));
    });
  });

  group('settings files', () {
    test('Export and Import carry both', () async {
      final folder = Directory(p.join(fixture.temp.path, 'out'))..createSync();
      savedTo = folder.path;
      model.saveSettings(
        orbit(),
        const GameSettings(customRelinkerOptions: '--frame-red-zone', launchOptions: 'APS5_REPORT=0 --x'),
      );
      await model.exportSettings(orbit());
      final file = File(p.join(folder.path, GameSharing.settingsFileName(orbit())));
      final shared = SharedSettings.decode(file.readAsStringSync());
      expect(shared.settings.customRelinkerOptions, '--frame-red-zone');
      expect(shared.settings.launchOptions, 'APS5_REPORT=0 --x');

      final neon = titled('PPSA02002');
      openAdvanced(neon);
      type('launchOptions', 'B="');
      picked = file.path;
      await model.importSettings(neon);
      expect(model.currentSettings(neon).customRelinkerOptions, '--frame-red-zone');
      expect(model.currentSettings(neon).launchOptions, 'APS5_REPORT=0 --x');
      expect((row('launchOptions').kind as TextRow).value, 'APS5_REPORT=0 --x', reason: "the file's, not the draft");
    });

    test('a file with an invalid one imports without it', () async {
      final file = File(p.join(fixture.temp.path, 'shared.json'))
        ..writeAsStringSync(
          '{"format":"anyps5-settings","version":1,"titleID":"PPSA01001","game":"Orbit Runner",'
          '"settings":{"customRelinkerOptions":"--rpath /tmp","launchOptions":"A=\\"open","frameGeneration":true}}',
        );
      picked = file.path;
      await model.importSettings(orbit());
      final settings = model.currentSettings(orbit());
      expect(settings.frameGeneration, isTrue);
      expect(settings.customRelinkerOptions, isNull);
      expect(settings.launchOptions, isNull);
    });
  });

  group('a start', () {
    test("gets the variables under the launcher's own, the arguments, and says so in its notes", () async {
      final starts = FakeGameStarts();
      model.startGame = starts.call;
      model.saveSettings(
        orbit(),
        const GameSettings(launchOptions: 'MY_VAR="a b" ANYPS5_LANGUAGE=99 APS5_REPORT=0 --aps5-report=off LATE=1'),
      );
      final playing = model.play(orbit());
      await until(() => model.running != null);
      final environment = starts.environments.single;
      expect(environment['MY_VAR'], 'a b');
      expect(environment['APS5_REPORT'], '0');
      expect(environment['ANYPS5_LANGUAGE'], isNot('99'), reason: 'the launcher sets it, its value wins');
      expect(environment.containsKey('LATE'), isFalse);
      expect(starts.arguments.single, ['--aps5-report=off', 'LATE=1']);
      expect(
        starts.notes.single,
        containsAllInOrder([
          '[anyps5-launcher] launch options: MY_VAR="a b" ANYPS5_LANGUAGE=99 APS5_REPORT=0 --aps5-report=off LATE=1',
          "[anyps5-launcher] launch options: the launcher's own value is used for ANYPS5_LANGUAGE",
        ]),
      );
      starts.last.quit();
      await playing;
    });

    test('without launch options: no arguments, no notes about them', () async {
      final starts = FakeGameStarts();
      model.startGame = starts.call;
      final playing = model.play(orbit());
      await until(() => model.running != null);
      expect(starts.arguments.single, isEmpty);
      expect(starts.notes.single.where((note) => note.contains('launch options')), isEmpty);
      starts.last.quit();
      await playing;
    });
  });

  test('the rebuild gets the custom relinker options and records them', () async {
    makeFakeToolkit(fixture.toolkit);
    final game = titled('PPSA02002');
    File(p.join(game.folder, 'eboot.bin')).writeAsBytesSync(typicalSelf());
    model.saveSettings(game, const GameSettings(customRelinkerOptions: '--exclude-sce-module "lib a.sprx"'));
    model.primaryAction(game);
    await until(() => model.stateOf(game) is Installed);
    final arguments = fakeRelinkerArguments(fixture.toolkit);
    expect(arguments.sublist(arguments.length - 4, arguments.length - 2), ['--exclude-sce-module', 'lib a.sprx']);
    expect(model.records[game.id]!.customRelinkerOptions, ['--exclude-sce-module', 'lib a.sprx']);
  });
}
