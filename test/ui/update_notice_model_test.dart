import 'dart:io';

import 'package:anyps5_desktop/core/app_update.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/package_install.dart';
import 'package:anyps5_desktop/core/together/account.dart';
import 'package:anyps5_desktop/core/update_notice.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:anyps5_desktop/ui/together_model.dart' show launcherVersion;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_github.dart';
import '../support/fixtures.dart';
import '../support/signing.dart';
import '../support/ui_support.dart';

/// The launcher's own update as the player meets it: found and downloaded quietly, the notice
/// with Restart now and Later, Later for the next launch, About's states. (The screens are in
/// update_notice_screens_test.dart: a file with widget tests gets no real HTTP.)
void main() {
  // Always newer than the launcher, whatever version it is (and the same in the goldens).
  const newer = '9.0.0';
  final key = TestReleaseKey('desktop release');
  late FakeGitHub github;
  Fixture? fixture;
  final started = <(String, List<String>)>[];
  final quits = <int>[];

  FakeRelease release(String version) => FakeRelease('v$version', {
    'AnyPS5-Desktop-Setup-$version-x64.exe': [0x4D, 0x5A, ...filler('setup$version')],
    'AnyPS5-Desktop-$version-x86_64.AppImage': filler('appimage$version'),
    'AnyPS5-Desktop-linux-x64.tar.gz': filler('tar$version'),
  });

  setUp(() async {
    github = await FakeGitHub.start(repository: LauncherUpdates.repository);
    github.releases.add(signed(release(newer), [key]));
    started.clear();
    quits.clear();
  });

  tearDown(() async {
    fixture?.model.dispose();
    fixture?.dispose();
    fixture = null;
    T.language = Language.english;
    await github.close();
  });

  AppModel launcher({
    HostSystem system = HostSystem.windows,
    Map<String, String> environment = const {},
    PackageManager? packageManager,
  }) {
    fixture = makeFixture(
      system: system,
      environment: environment,
      packageManager: packageManager,
      launcherReleases: LauncherUpdates.source(api: github.api, keys: [key.key]),
      startDetached: (executable, arguments) async => started.add((executable, arguments)),
      quit: quits.add,
    );
    return fixture!.model;
  }

  group('model', () {
    test('a newer release is downloaded quietly, then the notice offers Restart now', () async {
      final model = launcher();
      await model.updates.startupCheck();
      expect(model.updates.state, const UpdateReady(newer));
      expect(model.updates.showsNotice, isTrue);
      expect(model.toast, isNull, reason: 'no toast, no progress: the notice says it once it is ready');
      await model.updates.restartNow();
      expect(started.single.$1, endsWith('AnyPS5-Desktop-Setup-$newer-x64.exe'));
      expect(started.single.$2, SelfApply.installerArguments);
      expect(quits, [0]);
    });

    test('Later: no nagging, and the installer runs at the next launch, once', () async {
      final model = launcher();
      await model.updates.startupCheck();
      model.updates.later();
      expect(model.updates.showsNotice, isFalse);
      await model.updates.periodicCheck();
      expect(model.updates.showsNotice, isFalse, reason: 'the next check does not bring it back');
      expect(started, isEmpty);
      expect(await model.updates.applyPendingAtLaunch(), isTrue);
      expect(started.single.$1, endsWith('AnyPS5-Desktop-Setup-$newer-x64.exe'));
      expect(await model.updates.applyPendingAtLaunch(), isFalse, reason: 'once');
    });

    test('an installer changed after it was checked is never run', () async {
      final model = launcher();
      await model.updates.startupCheck();
      model.updates.later();
      File(model.updates.downloaded!).writeAsBytesSync([1, 2, 3]);
      expect(await model.updates.applyPendingAtLaunch(), isFalse);
      expect(started, isEmpty);
    });

    test('on Nightly the newest signed build is offered, not one CI has just published unsigned', () async {
      final model = launcher();
      model.preferences.updateChannel = 'nightly';
      const offered = '9.0.1-nightly.20261109.1', waiting = '9.0.1-nightly.20261110.1';
      github.releases
        ..clear()
        ..add(FakeRelease('v$waiting', release(waiting).files, prerelease: true))
        ..add(signed(FakeRelease('v$offered', release(offered).files, prerelease: true), [key]))
        ..add(signed(release(newer), [key]));
      await model.updates.check(quiet: true);
      expect(model.updates.latest!.version, offered);
      expect(model.updates.available, isTrue);
      expect(model.updates.asset!.name, 'AnyPS5-Desktop-Setup-$offered-x64.exe');
      await model.updates.download(quiet: true);
      expect(model.updates.state, const UpdateReady(offered));
      expect(github.downloads.where((path) => path.contains(waiting)), isEmpty);
    });

    test('Restart now with a game starting waits for it', () async {
      final model = launcher();
      await model.updates.startupCheck();
      model.starting = model.games.first;
      await model.updates.restartNow();
      expect(model.updates.restartAfterGame, isTrue);
      expect(started, isEmpty);
      expect(model.updates.showsNotice, isTrue, reason: 'the notice says it restarts when the game closes');
      model.updates.cancelRestart();
      expect(model.updates.restartAfterGame, isFalse);
      model.starting = null;
    });

    test('an AppImage is swapped for the new one: now for Restart now, kept for the next start on Later', () async {
      final temp = temporaryFolder('appimage');
      addTearDown(() => temp.deleteSync(recursive: true));
      final appImage = p.join(temp.path, 'AnyPS5-Desktop.AppImage');
      File(appImage).writeAsBytesSync([0]);
      final model = launcher(system: HostSystem.linux, environment: {'APPIMAGE': appImage});
      await model.updates.startupCheck();
      expect(model.updates.apply, SelfApply.appImage);
      model.updates.later();
      expect(File(appImage).readAsBytesSync(), filler('appimage$newer'));
      expect(started, isEmpty, reason: 'Later starts nothing');
    }, skip: Platform.isWindows ? 'chmod' : false);

    test('an archive is the user\'s to put in place: Show file', () async {
      final model = launcher(system: HostSystem.linux);
      await model.updates.startupCheck();
      expect(model.updates.apply, SelfApply.manual);
      await model.updates.restartNow();
      expect(started, isEmpty);
      expect(quits, isEmpty);
    });

    test('a Scoop copy is told the command, never sent the installer (a second copy)', () async {
      final model = launcher(packageManager: PackageManager.scoop);
      await model.updates.startupCheck();
      expect(model.updates.state, const UpdateAvailable(newer), reason: 'still checked');
      expect(model.updates.asset, isNull);
      expect(github.downloads, isEmpty, reason: 'nothing downloaded');
      expect(model.toast, 'AnyPS5 Desktop $newer is out. Update it with scoop update anyps5-desktop');
      expect(model.updates.showsNotice, isFalse);
      await model.updates.download();
      await model.updates.restartNow();
      model.updates.later();
      expect(started, isEmpty);
      expect(quits, isEmpty);
      expect(github.downloads, isEmpty);

      final row = model.updates.aboutRows().first;
      expect(row.title, 'AnyPS5 Desktop $newer is out');
      expect(
        row.detail,
        'Installed with Scoop: run scoop update anyps5-desktop to update. Select to copy the command.',
      );
      (row.kind as ActionRow).run();
      expect(fixture!.copied.last, 'scoop update anyps5-desktop');
      expect(model.toast, 'Command copied: paste it into a terminal');

      await model.updates.check();
      expect(model.toast, 'AnyPS5 Desktop $newer is out. Update it with scoop update anyps5-desktop');
    });

    test('a Scoop copy never runs an installer left for the next launch', () async {
      final model = launcher(packageManager: PackageManager.scoop);
      final installer = p.join(model.updates.folder, 'AnyPS5-Desktop-Setup-$newer-x64.exe');
      File(installer)
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync([0x4D, 0x5A]);
      LauncherUpdates.writePending(model.updates.folder, newer, installer);
      expect(await model.updates.applyPendingAtLaunch(), isFalse);
      expect(started, isEmpty);
    });

    test('an Arch package is told to update with the package manager', () async {
      final model = launcher(system: HostSystem.linux, packageManager: PackageManager.pacman);
      await model.updates.startupCheck();
      expect(model.updates.state, const UpdateAvailable(newer));
      expect(github.downloads, isEmpty, reason: 'not the archive either');
      expect(model.toast, 'AnyPS5 Desktop $newer is out. Update it with your package manager.');
      final row = model.updates.aboutRows().first;
      expect(row.title, 'AnyPS5 Desktop $newer is out');
      expect(row.detail, 'Installed by your package manager, which keeps it up to date.');
      expect(row.kind, isA<InfoRow>());
    });

    test('a package manager\'s copy follows Stable, with no Update Channel row', () async {
      final model = launcher(packageManager: PackageManager.scoop);
      model.preferences.updateChannel = 'nightly';
      github.releases.add(
        signed(FakeRelease('v9.0.1-nightly.20261109.1', release('9.0.1-nightly.20261109.1').files, prerelease: true), [
          key,
        ]),
      );
      await model.updates.check(quiet: true);
      expect(model.updates.latest!.version, newer, reason: 'the release Scoop gets');
      expect(model.updates.channelRow(), isNull);
    });

    test('Update Required on a Scoop copy shows the command instead of a download', () async {
      final model = launcher(packageManager: PackageManager.scoop);
      await model.updates.check(quiet: true);
      final rows = model.updates.requiredRows(const ClientTooOld(minimum: '9.0.0', current: '0.1.0'));
      expect(rows.map((row) => row.id), ['required-why', 'required-update', 'required-later']);
      expect(rows[1].detail, contains('scoop update anyps5-desktop'));
    });

    test('back in front after half an hour it asks again; sooner it does not', () async {
      final model = launcher();
      await model.updates.startupCheck();
      final asked = github.requests.length;
      model.updates.activated();
      expect(model.updates.checking, isFalse);
      model.updates.lastCheck = DateTime.now().subtract(const Duration(minutes: 31));
      model.updates.activated();
      expect(model.updates.checking, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(github.requests.length, greaterThan(asked));
    });

    test('Check for updates off (Settings › Behaviour): no automatic look, Check now still asks', () async {
      final model = launcher()..open(Layer.settings);
      final row = model
          .panelCategories()
          .firstWhere((category) => category.id == 'general')
          .rows
          .firstWhere((row) => row.id == 'checkUpdates');
      expect((row.kind as ToggleRow).value, isTrue, reason: 'on by default, as on the Mac');
      (row.kind as ToggleRow).set(false);
      expect(model.preferences.checkUpdates, isFalse);
      expect(Preferences.fromJson(model.preferences.toJson()).checkUpdates, isFalse, reason: 'kept');
      await model.updates.startupCheck();
      model.updates.lastCheck = DateTime.now().subtract(const Duration(hours: 1));
      model.updates.activated();
      expect(github.requests, isEmpty, reason: 'nothing asked on its own');
      expect(model.updates.latest, isNull);
      await model.updates.check();
      expect(model.updates.latest?.version, newer, reason: 'Check for Updates Now still asks');
    });

    test('About shows where it stands', () async {
      final model = launcher();
      expect(model.updates.aboutRows().map((row) => row.detail), [
        T.format('desktopVersion', [launcherVersion]),
      ]);
      await model.updates.startupCheck();
      final rows = model.updates.aboutRows();
      expect(rows.first.title, 'AnyPS5 Desktop $newer is ready · Restart now');
      expect(rows.first.detail, 'Restart now, or it goes in at the next launch.');
    });

    test('About: What\'s new opens the release, and the same links as on the Mac', () async {
      final model = launcher();
      expect(model.updates.aboutRows().map((row) => row.id), isNot(contains('whatsNew')), reason: 'nothing on offer');
      await model.updates.startupCheck();
      final whatsNew = model.updates.aboutRows().firstWhere((row) => row.id == 'whatsNew');
      expect(whatsNew.title, "What's new");
      expect(whatsNew.detail, 'github.com/AnyTogether/AnyPS5-Desktop/releases/tag/v$newer');
      (whatsNew.kind as ActionRow).run();
      expect(fixture!.opened.last, Uri.parse('https://github.com/AnyTogether/AnyPS5-Desktop/releases/tag/v$newer'));

      model.open(Layer.settings);
      final about = model.panelCategories().firstWhere((category) => category.id == 'about').rows;
      PanelRow aboutRow(String id) => about.firstWhere((row) => row.id == id);
      expect(aboutRow('author').title, 'Made by');
      expect((aboutRow('author').kind as InfoRow).text, 'Utku Halis');
      expect(aboutRow('github').detail, 'github.com/AnyTogether/AnyPS5-Desktop');
      (aboutRow('github').kind as ActionRow).run();
      expect(fixture!.opened.last, Uri.parse('https://github.com/AnyTogether/AnyPS5-Desktop'));
      expect(aboutRow('upstream').title, 'Built on AnyPS5');
      expect(aboutRow('upstream').detail, 'github.com/boykopovar/AnyPS5');
      (aboutRow('upstream').kind as ActionRow).run();
      expect(fixture!.opened.last, Uri.parse('https://github.com/boykopovar/AnyPS5'));
    });
  });
}
