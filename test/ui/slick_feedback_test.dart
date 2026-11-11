import 'dart:ui' show PointerDeviceKind;

import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/profiles/profiles.dart';
import 'package:anyps5_desktop/core/remote/paired_devices.dart';
import 'package:anyps5_desktop/core/remote/remote_server.dart';
import 'package:anyps5_desktop/core/together/account.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/countries.dart';
import 'package:anyps5_desktop/ui/engine_git_model.dart';
import 'package:anyps5_desktop/ui/launcher.dart';
import 'package:anyps5_desktop/ui/profiles_view.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:anyps5_desktop/ui/together_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_commands.dart';
import '../support/ui_support.dart';

/// What Slick Daddy reported on 0.1.21: Update from Git names every missing tool at once and
/// offers the install command, Home's profile picture opens a list of the other profiles, the
/// country is picked by name from a list, errors from AnyTogether are in the launcher's
/// language, and a paired phone shows a sign for its kind.
void main() {
  Fixture? current;
  final shell = find.byType(LauncherShell);

  tearDown(() {
    T.language = Language.english;
    EngineGitModel.osReleaseOverride = null;
    current?.dispose();
    current = null;
  });

  Future<void> until(bool Function() condition) async {
    for (var tries = 0; tries < 2000 && !condition(); tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(condition(), isTrue);
  }

  PanelRow? rowOf(AppModel model, String id) {
    if (model.overlay != Layer.settings) model.open(Layer.settings);
    return model.panelCategories().expand((category) => category.rows).where((row) => row.id == id).firstOrNull;
  }

  /// Settings on [category], the focus on its row [id] so the screen shows it.
  void focusRow(AppModel model, String category, String id) {
    model.openSettingsCategory(category);
    final index = model.panelCategories()[model.panelCategory].rows.indexWhere((row) => row.id == id);
    expect(index, isNonNegative, reason: 'the row $id');
    model.panelRow = index;
    model.refresh();
  }

  group('Update from Git: every missing tool at once, with the command that installs it', () {
    const ubuntu = 'NAME="Ubuntu"\nID=ubuntu\nID_LIKE=debian\n';

    /// A launcher whose engine folder is a checkout without a build folder.
    (FakeCommands, AppModel) bare({Language language = Language.english, HostSystem system = HostSystem.linux}) {
      final commands = FakeCommands();
      commands.results['git rev-parse HEAD'] = const FakeResult(lines: ['aaaaaaaa11']);
      final fixture = current = makeFixture(commands: commands, language: language, system: system);
      fixture.model.useOwnFolder(makeFakeCheckout(p.join(fixture.temp.path, 'Bare'), configured: false));
      return (commands, fixture.model);
    }

    void missing(FakeCommands commands, List<String> tools) {
      for (final tool in tools) {
        commands.results['$tool --version'] = const FakeResult(missing: true);
      }
    }

    test('Linux: one answer names them all, the apt line is copied, Check again clears it', () async {
      EngineGitModel.osReleaseOverride = () => ubuntu;
      final (commands, model) = bare();
      missing(commands, ['git', 'ninja', 'g++']);
      (rowOf(model, 'engineGitUpdate')!.kind as ActionRow).run();
      await until(() => !model.engine.git.running);
      final names = 'Git, Ninja, ${T.text('engineToolCompiler')}';
      expect(
        model.toast,
        T.format('engineGitFailed', [
          T.format('engineGitMissing', [names]),
        ]),
      );
      expect(commands.lines.where((line) => line.startsWith('git pull')), isEmpty);
      final copy = rowOf(model, 'engineGitFixCopy0')!;
      expect(copy.title, T.format('engineGitFixCopyAdmin', ['Git, Ninja, GCC']));
      expect(copy.detail, 'sudo apt-get install -y git ninja-build gcc g++');
      expect(rowOf(model, 'engineGitFixRun0'), isNull, reason: 'sudo: never run by the launcher');
      (copy.kind as ActionRow).run();
      expect(current!.copied.single, 'sudo apt-get install -y git ninja-build gcc g++');
      expect(model.toast, T.text('engineGitFixCopied'));
      expect(rowOf(model, 'engineGitGuide'), isNotNull, reason: 'the build guide stays one row away');

      // Only Git was installed: said, and the command is the rest's.
      commands.results.remove('git --version');
      (rowOf(model, 'engineGitRecheck')!.kind as ActionRow).run();
      await until(() => !model.engine.git.rechecking);
      expect(model.toast, T.format('engineGitStillMissing', ['Ninja, ${T.text('engineToolCompiler')}']));
      expect(rowOf(model, 'engineGitFixCopy0')!.detail, 'sudo apt-get install -y ninja-build gcc g++');

      // The rest too: nothing is in the way any more, without a restart.
      commands.results
        ..remove('ninja --version')
        ..remove('g++ --version');
      (rowOf(model, 'engineGitRecheck')!.kind as ActionRow).run();
      await until(() => !model.engine.git.rechecking);
      expect(model.toast, T.text('engineGitToolsReady'));
      expect(model.engine.git.failure, isNull);
      expect(rowOf(model, 'engineGitRecheck'), isNull);
      expect(rowOf(model, 'engineGitFixCopy0'), isNull);
    });

    test('Windows: WinLibs installed from the launcher with winget, then looked for again', () async {
      final (commands, model) = bare(system: HostSystem.windows);
      missing(commands, ['git', 'ninja', 'g++']);
      commands.results['winget install -e --id BrechtSanders'] = FakeResult(
        lines: const ['Found WinLibs', 'Successfully installed'],
        effect: () => commands.results
          ..remove('ninja --version')
          ..remove('g++ --version'),
      );
      (rowOf(model, 'engineGitUpdate')!.kind as ActionRow).run();
      await until(() => !model.engine.git.running);
      // Git's installer asks for administrator rights: to copy only.
      expect(rowOf(model, 'engineGitFixCopy0')!.title, T.format('engineGitFixCopyAdmin', ['Git']));
      expect(rowOf(model, 'engineGitFixRun0'), isNull);
      expect(rowOf(model, 'engineGitFixCopy1')!.title, T.format('engineGitFixCopy', ['GCC, Ninja']));
      expect(
        rowOf(model, 'engineGitFixCopy1')!.detail,
        contains('--id BrechtSanders.WinLibs.POSIX.UCRT --version 15.2.0'),
      );
      final run = rowOf(model, 'engineGitFixRun1')!;
      expect(run.title, T.format('engineGitFixRun', ['GCC, Ninja']));
      expect(run.detail, T.text('engineGitFixRunDetail'));
      (run.kind as ActionRow).run();
      expect(model.engine.git.installing, isNotNull);
      expect(rowOf(model, 'engineGitFixRunning')!.title, T.format('engineGitFixRunning', ['GCC, Ninja']));
      await until(() => model.engine.git.installing == null && !model.engine.git.rechecking);
      expect(commands.lines, contains(startsWith('winget install -e --id BrechtSanders.WinLibs.POSIX.UCRT')));
      // Looked for again by itself: only Git is still missing.
      expect(model.toast, T.format('engineGitStillMissing', ['Git']));
      expect(rowOf(model, 'engineGitFixCopy0')!.detail, startsWith('winget install -e --id Git.Git'));
      expect(rowOf(model, 'engineGitFixCopy1'), isNull);
    });

    for (final language in ['en', 'tr']) {
      testWidgets('the missing tools and their command ($language)', (tester) async {
        EngineGitModel.osReleaseOverride = () => ubuntu;
        final (commands, model) = bare(language: Language.byCode(language));
        missing(commands, ['git', 'ninja', 'g++']);
        await tester.runAsync(() async {
          (rowOf(model, 'engineGitUpdate')!.kind as ActionRow).run();
          await until(() => !model.engine.git.running);
        });
        model.openSettingsCategory('engine');
        await pumpLauncher(tester, model);
        // On to the last row: the list scrolls down to the failure, its command and Check again
        // (and the row with the checkout's folder, a temporary one here, leaves the screen).
        focusRow(model, 'engine', 'engineGitBeforePlay');
        await settle(tester);
        expect(find.text('sudo apt-get install -y git ninja-build gcc g++'), findsOneWidget);
        expect(find.text(T.text('engineGitRecheck')), findsOneWidget);
        await expectLater(shell, matchesGoldenFile('goldens/engine_missing_tools_$language.png'));
      });
    }
  });

  group('Home: the profile picture opens the other profiles', () {
    AppModel withProfiles({Language language = Language.english}) {
      final model = (current = makeFixture(language: language)).model;
      model.profiles
        ..add(
          name: 'Mira',
          mode: ProfileMode.online,
          account: const ProfileAccount(userId: 'u7', handle: 'mira.k'),
        )
        ..add(name: 'Deniz', mode: ProfileMode.offline);
      return model;
    }

    void toPicture(AppModel model) {
      model.handle(Command.up);
      for (var presses = 0; presses < 10 && !model.focus.isSwitcher; presses++) {
        model.handle(Command.right);
      }
      expect(model.focus, const HomeFocus.switcher(0));
    }

    test('the keys: past the last button to the picture, down the list, Back closes', () {
      final model = withProfiles();
      expect(model.profileListOpen, isFalse);
      toPicture(model);
      expect(model.profileListOpen, isTrue);
      expect([for (final profile in model.switcherProfiles) profile.name], ['Mira', 'Deniz']);
      model.handle(Command.down);
      model.handle(Command.down);
      model.handle(Command.down);
      expect(model.focus, const HomeFocus.switcher(3), reason: 'Add profile, the last entry');
      model.handle(Command.down);
      expect(model.focus, const HomeFocus.switcher(3));
      model.handle(Command.up);
      expect(model.focus, const HomeFocus.switcher(2));
      model.handle(Command.back);
      expect((model.focus, model.profileListOpen, model.overlay), (HomeFocus.tiles, false, null));
      // Left from the picture is the last button again.
      toPicture(model);
      model.handle(Command.left);
      expect((model.focus.isTop, model.profileListOpen), (true, false));
    });

    test('choosing a profile plays as it, as the picker does, and Add profile opens its screen', () async {
      final model = withProfiles();
      toPicture(model);
      model.handle(Command.select);
      expect(model.focus, const HomeFocus.switcher(1), reason: 'Select on the picture goes into the list');
      model.handle(Command.down);
      model.handle(Command.select);
      await until(() => model.currentProfile?.name == 'Deniz');
      expect((model.focus, model.profileListOpen), (HomeFocus.tiles, false));
      expect(model.toast, T.format('profileWelcomeBack', ['Deniz']));
      expect([for (final profile in model.switcherProfiles) profile.name], isNot(contains('Deniz')));

      toPicture(model);
      model.handle(Command.up);
      model.chooseFromProfileList(model.switcherProfiles.length);
      expect(model.overlay, Layer.addProfile);
      expect(model.profileListOpen, isFalse);
    });

    test('opened with the pointer: Escape closes the list before it asks to quit', () {
      final model = withProfiles();
      model.showProfileList();
      expect(model.profileListOpen, isTrue);
      expect(model.askQuit(), isFalse);
      model.handle(Command.back);
      expect((model.profileListOpen, model.overlay), (false, null));
      expect(model.askQuit(), isTrue);
    });

    testWidgets('the pointer: over the picture it opens, away from both it closes, a click chooses', (tester) async {
      final model = withProfiles();
      await pumpLauncher(tester, model);
      expect(find.byType(ProfileSwitcherList), findsNothing);
      final picture = tester.getCenter(find.byKey(const ValueKey('home-avatar')));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(400, 600));
      addTearDown(mouse.removePointer);
      await mouse.moveTo(picture);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(ProfileSwitcherList), findsOneWidget);
      expect(find.byKey(const ValueKey('home-avatar-ring')), findsNothing, reason: 'the ring is the keys\' only');
      expect(find.text('Mira'), findsOneWidget);
      expect(find.text('Deniz'), findsOneWidget);
      expect(find.text(T.text('profileAdd')), findsOneWidget);
      expect(find.byKey(const ValueKey('together-badge')), findsOneWidget, reason: 'only Mira is linked');
      // Across the gap onto the list: it stays.
      await mouse.moveTo(tester.getCenter(find.text('Deniz')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(ProfileSwitcherList), findsOneWidget);
      // Away from both: gone a moment later.
      await mouse.moveTo(const Offset(400, 600));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(find.byType(ProfileSwitcherList), findsNothing);
      // A click on the picture opens it, a click elsewhere closes it.
      await mouse.moveTo(picture);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(ProfileSwitcherList), findsOneWidget);
      await tester.tapAt(const Offset(700, 56));
      await tester.pump(const Duration(milliseconds: 300));
      expect(model.profileListOpen, isFalse);
      // And a click on an entry chooses it.
      model.showProfileList();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const ValueKey('switcher-add')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(model.overlay, Layer.addProfile);
    });

    testWidgets('the list under the picture, the keys on the first profile', (tester) async {
      final model = withProfiles();
      toPicture(model);
      model.handle(Command.down);
      await pumpLauncher(tester, model);
      expect(find.byType(ProfileSwitcherList), findsOneWidget);
      await expectLater(shell, matchesGoldenFile('goldens/home_profile_list_en.png'));
    });

    testWidgets('the list under the picture, opened with the pointer, in Turkish', (tester) async {
      final model = withProfiles(language: Language.byCode('tr'));
      model.showProfileList();
      await pumpLauncher(tester, model);
      expect(find.text('Profil ekle'), findsOneWidget);
      await expectLater(shell, matchesGoldenFile('goldens/home_profile_list_tr.png'));
    });
  });

  group('the country: picked by name from a list', () {
    test('names in the launcher\'s language, found whatever the case and the accents', () {
      expect(Countries.all, hasLength(249));
      expect(Countries.name('tr'), 'Türkiye');
      expect(Countries.name('DE'), 'Germany');
      expect(Countries.name(null), isNull);
      expect(Countries.name(' '), isNull);
      expect(Countries.search('germ').map((entry) => entry.$1), ['DE']);
      expect(Countries.search('turk').first.$1, 'TR');
      // A code finds its country first.
      expect(Countries.search('se').first, ('SE', 'Sweden'));
      T.language = Language.byCode('tr');
      expect(Countries.name('DE'), 'Almanya');
      expect(Countries.search('alm').first, ('DE', 'Almanya'));
      // The code's country first, then the names that begin with what was typed.
      expect(Countries.search('al').take(3).map((entry) => entry.$2), ['Arnavutluk', 'Åland Adaları', 'Almanya']);
      expect(Countries.search('isvec').single, ('SE', 'İsveç'));
      expect(Countries.search('ISVEÇ').single.$1, 'SE');
      // The English name still finds it for someone who types that.
      expect(Countries.search('germany').single.$1, 'DE');
      expect(Countries.search('zzzz'), isEmpty);
      // In the language's own order: Åland among the A's, Türkiye before Ukrayna.
      final names = [for (final entry in Countries.all) entry.$2];
      expect(names.indexOf('Türkiye'), lessThan(names.indexOf('Ukrayna')));
    });

    test('the list: None first, a search narrows it, Back leaves the country as it was', () {
      final model = (current = makeFixture()).model;
      final together = model.together;
      model.open(Layer.settings);
      together.openCountryPicker();
      expect(model.overlay, Layer.countryPicker);
      List<String> ids() => [for (final row in together.countryRows()) row.id];
      expect(ids().take(3), [TogetherModel.countrySearchRow, TogetherModel.countryNoneRow, 'country-AF']);
      expect(ids(), hasLength(251));
      expect(model.panelRow, 1, reason: 'no country yet: on None');
      (together.countryRows().first.kind as TextRow).set('united');
      expect(ids(), [TogetherModel.countrySearchRow, 'country-AE', 'country-GB', 'country-US']);
      (together.countryRows().first.kind as TextRow).set('qqq');
      expect(together.countryRows().last.title, T.format('togetherCountryNoMatch', ['qqq']));
      model.handle(Command.back);
      expect(model.overlay, Layer.settings);
      expect(together.countryDraft, isNull);

      // Chosen (saved at once when signed in), and the list opens on it the next time.
      together.openCountryPicker();
      (together.countryRows().firstWhere((row) => row.id == 'country-TR').kind as ActionRow).run();
      expect((model.overlay, together.countryDraft), (Layer.settings, 'TR'));
      together.openCountryPicker();
      expect(together.countryRows()[model.panelRow].id, 'country-TR');
      // None clears it.
      (together.countryRows()[1].kind as ActionRow).run();
      expect(together.countryDraft, '');
    });

    test('what AnyTogether refuses is said in the launcher\'s language, never in the server\'s words', () {
      final model = (current = makeFixture(language: Language.byCode('tr'))).model;
      const refused = TogetherProblem(400, 'bad_request', 'country: a country code like TR or DE');
      expect(model.together.message(refused), 'Bu kabul edilmedi. Girdiğini denetleyip yeniden dene.');
      for (final code in [
        'unauthorized',
        'forbidden',
        'not_found',
        'conflict',
        'full',
        'payload_too_large',
        'internal',
      ]) {
        final said = model.together.message(TogetherProblem(400, code, 'Server words in English'));
        expect(said, isNot(contains('Server words')), reason: code);
        expect(said, isNot(contains(code)), reason: code);
      }
      // A code the launcher has no words for yet: still its own sentence, with the code.
      expect(
        model.together.message(const TogetherProblem(400, 'brand_new_code', 'Server words in English')),
        'AnyTogether bunu yapamadı (brand_new_code).',
      );
    });

    testWidgets('the list as it opens', (tester) async {
      final model = (current = makeFixture()).model;
      model.open(Layer.settings);
      model.together.openCountryPicker();
      await pumpLauncher(tester, model);
      expect(find.text('Search countries'), findsOneWidget);
      expect(find.text('None'), findsOneWidget);
      expect(find.text('Afghanistan'), findsOneWidget);
      await expectLater(shell, matchesGoldenFile('goldens/country_picker_en.png'));
    });

    testWidgets('a search, in Turkish', (tester) async {
      final model = (current = makeFixture(language: Language.byCode('tr'))).model;
      model.open(Layer.settings);
      model.together.openCountryPicker();
      (model.together.countryRows().first.kind as TextRow).set('al');
      await pumpLauncher(tester, model);
      expect(find.text('Ülke ara'), findsOneWidget);
      expect(find.text('Almanya'), findsOneWidget);
      await expectLater(shell, matchesGoldenFile('goldens/country_picker_tr.png'));
    });
  });

  group('Settings › Phones: a sign for each device\'s kind', () {
    /// A phone server that is not listening, with four devices paired: enough for the rows.
    AppModel withPhones({Language language = Language.english}) {
      final fixture = current = makeFixture(language: language);
      final devices = PairedDevices(p.join(fixture.temp.path, 'paired.json'))
        ..add('web-1', 'Android · Web')
        ..add('web-2', 'Phone · Web')
        ..add('phone-1', "Utku's iPhone")
        ..add('phone-2', 'Pixel 8');
      fixture.model.remote = RemoteServer(name: 'Desk', devices: devices);
      return fixture.model;
    }

    test('the kind and the name people read, from the name the device gave', () {
      expect(PhoneLabel.icon('Android · Web'), PanelIcon.android);
      expect(PhoneLabel.icon('iPhone · Web'), PanelIcon.iphone);
      expect(PhoneLabel.icon('iPad · Web'), PanelIcon.iphone);
      expect(PhoneLabel.icon('Phone · Web'), PanelIcon.browser);
      expect(PhoneLabel.icon("Utku's iPhone"), PanelIcon.iphone);
      expect(PhoneLabel.icon('Galaxy (Android)'), PanelIcon.android);
      expect(PhoneLabel.icon('Pixel 8'), PanelIcon.phone);
      expect(PhoneLabel.title('Android · Web'), 'Android browser');
      expect(PhoneLabel.title('Phone · Web'), 'Phone browser');
      expect(PhoneLabel.title('Pixel 8'), 'Pixel 8');
      T.language = Language.byCode('tr');
      expect(PhoneLabel.title('Android · Web'), 'Android tarayıcısı');
      expect(PhoneLabel.title('Phone · Web'), 'Telefon tarayıcısı');
    });

    test('the rows: the sign, a title without "·", Remove under it', () {
      final model = withPhones();
      model.openSettingsCategory('phone');
      final rows = [
        for (final row in model.panelCategories()[model.panelCategory].rows)
          if (row.id.startsWith('device-')) row,
      ];
      expect([for (final row in rows) row.title], ['Android browser', 'Phone browser', "Utku's iPhone", 'Pixel 8']);
      expect(
        [for (final row in rows) row.icon],
        [PanelIcon.android, PanelIcon.browser, PanelIcon.iphone, PanelIcon.phone],
      );
      expect(rows.every((row) => !row.title.contains('·')), isTrue);
      expect(rows.every((row) => row.detail == 'Remove'), isTrue);
    });

    for (final language in ['en', 'tr']) {
      testWidgets('the paired devices ($language)', (tester) async {
        final model = withPhones(language: Language.byCode(language));
        focusRow(model, 'phone', 'device-web-1');
        await pumpLauncher(tester, model);
        expect(find.byIcon(Icons.android_rounded), findsWidgets);
        expect(find.byIcon(Icons.language_rounded), findsWidgets);
        expect(find.text(PhoneLabel.title('Android · Web')), findsOneWidget);
        expect(find.textContaining('· Web'), findsNothing);
        await expectLater(shell, matchesGoldenFile('goldens/settings_phones_$language.png'));
      });
    }
  });
}
