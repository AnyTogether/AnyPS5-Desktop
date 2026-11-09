import 'package:anyps5_desktop/core/gamepad/pad_navigation.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/launcher.dart';
import 'package:anyps5_desktop/ui/panels.dart' show SettingsSearchField;
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show EditableText, Semantics, ValueKey;
import 'package:flutter_test/flutter_test.dart';

import '../support/ui_support.dart';
import 'desktop_features_test.dart' show FakePads;

/// Settings' search: a field over the sections that keeps the settings whose title or
/// description has the words typed, in the language shown, from the keys, a click or the pad.
void main() {
  late Fixture fixture;
  late AppModel model;
  late FakePads pads;

  setUp(() {
    pads = FakePads();
    fixture = makeFixture(pads: () => pads);
    model = fixture.model..startPads();
    model.open(Layer.settings);
  });

  tearDown(() {
    model.dispose();
    T.language = Language.english;
    fixture.dispose();
  });

  List<PanelRow> rows() => model.panelCategories()[model.panelCategory].rows;
  List<String> ids() => rows().map((row) => row.id).toList();

  test('the words typed keep the settings that have them, in Turkish too, from every section', () {
    T.language = Language.byCode('tr');
    final sections = model.panelCategories().length;
    expect(sections, greaterThan(5));
    model.selectCategory(3);
    model.setSettingsQuery('SES');
    expect(model.panelCategories(), hasLength(1), reason: 'one list instead of the sections');
    expect(ids(), containsAll(['launcherVolume', 'sounds']));
    final volume = rows().firstWhere((row) => row.id == 'launcherVolume');
    expect(volume.title, 'Başlatıcı ses düzeyi');
    expect(volume.detail, startsWith('Davranış · '), reason: 'where it lives');
    // Every word, anywhere in the title or the description; dotted and dotless i alike.
    model.setSettingsQuery('başlatıcı düzeyi');
    expect(ids(), ['launcherVolume']);
    model.setSettingsQuery('BASLATICI');
    expect(ids(), isNot(contains('launcherVolume')), reason: 'ş is not s');
    model.setSettingsQuery('başlatici');
    expect(ids(), contains('launcherVolume'));
    model.setSettingsQuery('zzqx');
    expect(ids(), ['search-none']);
    expect(rows().single.title, '“zzqx” ile eşleşen ayar yok');
    model.clearSettingsSearch();
    expect(model.panelCategories(), hasLength(sections));
    expect(model.panelCategory, 3, reason: 'back on the section it was on');
  });

  test('the keys: ↑ from the first row is the field, Enter types, Enter again goes to the rows', () {
    expect(model.settingsSearchFocused, isFalse);
    model.command(Command.up);
    expect(model.settingsSearchFocused, isTrue);
    model.command(Command.select);
    expect(model.editingRow, 'settings-search');
    final field = model.settingsSearchField.kind as TextRow;
    field.set('launcher volume');
    expect(ids(), ['launcherVolume']);
    field.submit!();
    model.stopEditing();
    expect(model.settingsSearchFocused, isFalse);
    expect(rows()[model.panelRow].id, 'launcherVolume');
    model.command(Command.left);
    expect(model.preferences.launcherVolume, 95, reason: 'the row found works as in its section');
    // ↑ onto the field again, Esc empties it, Esc again closes Settings.
    model.command(Command.up);
    expect(model.settingsSearchFocused, isTrue);
    model.command(Command.back);
    expect(model.searchingSettings, isFalse);
    expect(model.overlay, Layer.settings);
    model.command(Command.back);
    expect(model.overlay, isNull);
    model.open(Layer.settings);
    expect(model.settingsQuery, isEmpty, reason: 'Settings open with every section');
  });

  test('the pad: ↑ on the first section is the field, ↓ goes back, ○ empties it', () {
    pads.press(PadButton.dpadLeft);
    expect(model.panelSections, isTrue);
    pads.press(PadButton.dpadUp);
    expect(model.settingsSearchFocused, isTrue);
    expect(model.panelSections, isFalse);
    pads.press(PadButton.south);
    expect(model.editingRow, 'settings-search');
    model.setSettingsQuery('volume');
    // Typing: ↓ (or ○) on the pad lets go of the field.
    pads.press(PadButton.dpadDown);
    expect(model.editingRow, isNull);
    expect(model.settingsSearchFocused, isFalse);
    expect(rows()[model.panelRow].id, 'launcherVolume');
    pads.press(PadButton.dpadUp);
    expect(model.settingsSearchFocused, isTrue);
    pads.press(PadButton.east);
    expect(model.searchingSettings, isFalse);
    pads.press(PadButton.dpadDown);
    expect(model.settingsSearchFocused, isFalse);
    expect(model.panelCategories().length, greaterThan(5));
  });

  testWidgets('the search field has a screen-reader label', (tester) async {
    await pumpLauncher(tester, model);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Semantics && widget.properties.label == T.text('settingsSearchPrompt'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('Ctrl+F puts the cursor in the field; typing filters; × empties it', (tester) async {
    await pumpLauncher(tester, model);
    expect(find.byType(SettingsSearchField), findsOneWidget);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);
    expect(model.editingRow, 'settings-search');
    await tester.enterText(find.byType(EditableText), 'volume');
    await settle(tester);
    expect(ids(), contains('launcherVolume'));
    expect(find.text('Launcher volume'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('settings-search-clear')));
    await settle(tester);
    expect(model.searchingSettings, isFalse);
    expect(find.byType(LauncherShell), findsOneWidget);
  });

  testWidgets('golden: Settings searched, in Turkish', (tester) async {
    T.language = Language.byCode('tr');
    model.setSettingsQuery('ses');
    await pumpLauncher(tester, model);
    await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/settings_search_tr.png'));
  });
}
