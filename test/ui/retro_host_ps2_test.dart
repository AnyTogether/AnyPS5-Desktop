import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_install.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_protocol.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_release.dart';
import 'package:anyps5_desktop/core/retro_host/retro_resolution.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_store.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/retro_host/retro_host_game.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_github.dart';
import '../support/ps1_launcher.dart';
import '../support/ps2_host_recording.dart';
import '../support/retro_host_release_fixture.dart';
import 'retro_host/real_host_support.dart' show until;

/// PS2 discs in the emulator host (anyps5-retro-host docs/ps2.md): Settings › Emulators' PS2 rows,
/// a PS2 game started with `start.console` `ps2` on LRPS2, its missing BIOS, its menu, and the
/// signed release's LRPS2, checked like SwanStation. The statuses are the ones a host built from
/// anyps5-retro-host main sent ([Ps2HostRecording]).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final recording = Ps2HostRecording.load();
  late Ps1Launcher launcher;
  tearDown(() => launcher.dispose());

  PanelRow? row(String id) => launcher.emulatorSettings().rows.where((row) => row.id == id).firstOrNull;

  Future<void> startPs2(RetroStatus status) async {
    final playing = launcher.model.play(launcher.ps2Game);
    await until(() => launcher.opened.isNotEmpty, const Duration(seconds: 10));
    launcher.session.nextStatus = status;
    launcher.session.readyCompleter.complete();
    await playing;
    await pumpEventQueue();
  }

  test('a host with no LRPS2 beside it shows no PS2 rows and plays no PS2 disc, whatever the setting', () {
    launcher = Ps1Launcher(ps2: false);
    final model = launcher.model..setRetroHostPs2(true);
    expect(model.retroHostInstall!.ps2Core, isNull);
    final ids = launcher.emulatorSettings().rows.map((row) => row.id).toList();
    expect(ids, contains('retro-host-ps1'));
    expect(ids.where((id) => id.startsWith('retro-host-ps2')), isEmpty);
    expect(model.playsInHost(RetroPlatform.ps2), isFalse);
  });

  test('a PS2 cue sheet, which PCSX2 does not boot, is in the library only while PS2 discs play in the host', () {
    launcher = Ps1Launcher(ps2: true)..addPs2CueSheet('Cue Racer');
    final model = launcher.model;
    bool listed() => launcher.lists('Cue Racer');
    model.rescan();
    expect(listed(), isFalse, reason: 'it would start in PCSX2');
    model.setRetroHostPs2(true);
    expect(listed(), isTrue);
    expect(model.games.singleWhere((game) => game.name == 'Cue Racer').retro!.platform, RetroPlatform.ps2);
    model.setRetroHostPs2(false);
    expect(listed(), isFalse);
  });

  test('with LRPS2 beside the host: off until turned on, then the PS2 BIOS folder, opened where LRPS2 looks', () {
    launcher = Ps1Launcher(ps2: true);
    final model = launcher.model;
    expect(
      model.retroHostInstall!.ps2Core,
      p.join(p.dirname(launcher.host), RetroHostInstall.ps2CoreName(HostSystem.current)),
    );
    expect(model.preferences.retroHostPs2, isFalse);
    expect(model.playsInHost(RetroPlatform.ps2), isFalse);
    final ids = launcher.emulatorSettings().rows.map((row) => row.id).toList();
    expect(ids, containsAllInOrder(['retro-host-ps1', 'retro-host-ps2']));
    expect(ids, isNot(contains('retro-host-ps2-bios')));
    expect(row('retro-host-ps2')!.kind, isA<ToggleRow>());

    model.setRetroHostPs2(true);
    expect(model.playsInHost(RetroPlatform.ps2), isTrue);
    expect(model.playsInHost(RetroPlatform.ps1), isFalse, reason: 'each console has its own setting');
    expect(model.preferences.toJson()['retroHostPs2'], isTrue);
    expect(Preferences.fromJson(model.preferences.toJson()).retroHostPs2, isTrue);
    final bios = row('retro-host-ps2-bios')!;
    expect((bios.title, bios.detail), (T.text('retroHostPs2BiosFolder'), T.text('retroHostPs2BiosFolderDetail')));
    (bios.kind as ActionRow).run();
    final folder = p.join(model.paths.retroSystem, 'pcsx2', 'bios');
    expect(model.paths.retroPs2Bios, folder);
    expect(launcher.fixture.folders, [folder]);
    expect(Directory(folder).existsSync(), isTrue, reason: 'made for the player to put the BIOS in');
  });

  test("a PS2 disc starts on LRPS2 with console ps2, its own memory cards and LRPS2's options only", () async {
    launcher = Ps1Launcher(ps2: true);
    final model = launcher.model..setRetroHostPs2(true);
    model.preferences.retroHostOptions.addAll({
      'swanstation_Console_Region': 'NTSC-J',
      'pcsx2_fastboot': 'disabled',
      'pcsx2_bios': 'scph-mine.bin',
    });
    expect(model.stateOf(launcher.ps2Game), isA<Installed>(), reason: 'no PCSX2 needed');
    await startPs2(recording.lastStatus('lrps2-no-bios-folder'));
    final ps2Core = launcher.opened.single.$1.ps2Core!;
    expect(launcher.play.core, ps2Core);
    expect(launcher.play.unchecked, isTrue, reason: "a debug or test build's host is marked as unchecked");
    expect(launcher.session.startArgs, {
      'console': RetroConsole.ps2,
      'core': ps2Core,
      'disc': p.normalize(launcher.ps2Disc!),
      'system': p.normalize(model.paths.retroSystem),
      'saves': p.normalize(model.paths.retroPs2Saves),
      'options': {'pcsx2_fastboot': 'disabled', 'pcsx2_bios': 'scph-mine.bin'},
    });
  });

  test("the real LRPS2's missing BIOS: the PS2 words, and the options key opens the PS2 BIOS folder", () async {
    launcher = Ps1Launcher(ps2: true);
    final model = launcher.model..setRetroHostPs2(true);
    await startPs2(recording.lastStatus('lrps2-not-a-bios'));
    expect(launcher.play.host.phase, RetroHostGamePhase.ended);
    expect(launcher.play.problem, retroHostPs2BiosProblem);
    expect(T.text(launcher.play.problem!), contains(T.text('retroHostPs2BiosFolder')));
    model.handle(Command.options);
    expect(launcher.fixture.folders, [model.paths.retroPs2Bios]);
    expect(model.retroPlay, isNotNull, reason: 'the error screen stays');
  });

  test('a PS1 disc on the same host still starts as before, with no PS2 option', () async {
    launcher = Ps1Launcher(ps2: true);
    final model = launcher.model
      ..setRetroHostPs1(true)
      ..setRetroHostPs2(true)
      ..preferences.retroHostOptions.addAll({'pcsx2_fastboot': 'disabled', 'swanstation_Console_Region': 'NTSC-J'});
    await launcher.start();
    expect(launcher.session.startArgs, {
      'core': launcher.core,
      'disc': p.normalize(launcher.disc),
      'system': p.normalize(model.paths.retroSystem),
      'saves': p.normalize(model.paths.retroSaves),
      'options': {'swanstation_Console_Region': 'NTSC-J'},
    });
  });

  test('a PS2 game on a host without ps2 is never sent, and says the host needs updating', () async {
    launcher = Ps1Launcher(ps2: true);
    launcher.model.setRetroHostPs2(true);
    launcher.session.canPlayPs2 = false;
    await startPs2(recording.lastStatus('lrps2-no-bios-folder'));
    expect(launcher.session.startArgs, isNull);
    expect(launcher.play.host.consoleRefused, isTrue);
    expect(launcher.play.problem, retroHostNoPs2Problem);
  });

  test(
    "a running PS2 game's menu: the core's options under Advanced, its BIOS taking effect at the next start",
    () async {
      launcher = Ps1Launcher(ps2: true);
      final model = launcher.model..setRetroHostPs2(true);
      final ready = recording.readyStatus('fake-ps2-ready');
      await startPs2(ready);
      expect(launcher.play.host.phase, RetroHostGamePhase.playing);
      model.openRetroMenu();
      await pumpEventQueue();
      expect(model.overlay, Layer.retroMenu);
      expect(model.panelCategories().single.title, 'Sky Racer');
      final first = [for (final row in model.panelCategories().single.rows) row.id];
      expect(first, containsAllInOrder(['resume', 'section-audio', 'section-advanced', 'closeGame']));
      expect(first, isNot(contains('resolution')), reason: 'a host without ps2ResolutionLimits');
      (launcher.row('section-advanced').kind as ActionRow).run();
      final bios = launcher.row('option-pcsx2_bios');
      expect(bios.detail, T.text('retroMenuOptionRestartOnlyDetail'), reason: 'LRPS2 reads it only at a start');
      final choice = bios.kind as ChoiceRow;
      expect(choice.options, ready.options['pcsx2_bios']!.labels);
      model.handle(Command.back);
      model.handle(Command.home);
      expect(model.overlay, isNull, reason: 'back to the game');
    },
  );

  group('the internal resolution, from the real LRPS2 on a host with ps2ResolutionLimits', () {
    RetroStatus recorded() => RetroStatus.parse(
      ((jsonDecode(File('test/fixtures/retro-host-ps2-resolution-status.json').readAsStringSync()) as Map)['reply']
              as Map)['result']
          as Map<String, Object?>,
      ps2: true,
    );

    test('a saved 8x in stereo: the game uses 4x, the row offers Native, 2x and 4x and says why', () async {
      launcher = Ps1Launcher(ps2: true);
      final model = launcher.model..setRetroHostPs2(true);
      model.preferences.retroHostOptions[retroResolutionKeyPs2] = '8x';
      launcher.session.limitsPs2Resolution = true;
      await startPs2(recorded());
      expect(
        (launcher.session.startArgs!['options']! as Map)[retroResolutionKeyPs2],
        '8x',
        reason: 'the host judges it',
      );
      model.openRetroMenu();
      await pumpEventQueue();
      final first = [for (final row in model.panelCategories().single.rows) row.id];
      expect(first, containsAllInOrder(['section-audio', 'resolution']));
      expect(
        first,
        isNot(contains('section-advanced')),
        reason: "LRPS2's VR, the recording's other option, is not shown",
      );
      final row = launcher.row('resolution');
      expect(row.detail, T.format('retroResolutionRefusedDetail', ['4x']));
      final choice = row.kind as ChoiceRow;
      expect(choice.options, ['Native', '2x', '4x']);
      expect(choice.selected, 2);

      launcher.session.callResults['option'] = true;
      final chosen = recorded().toJson();
      ((chosen['options']! as Map)[retroResolutionKeyPs2] as Map)['selected'] = 1;
      launcher.session.nextStatus = RetroStatus.parse({...chosen, 'resolutionError': ''}, ps2: true);
      choice.set(1);
      await pumpEventQueue();
      expect(launcher.session.calls.last.$1, 'option');
      expect(launcher.session.calls.last.$2, {'key': retroResolutionKeyPs2, 'value': '2x'});
      expect(model.preferences.retroHostOptions[retroResolutionKeyPs2], '2x');
      expect(
        launcher.row('resolution').detail,
        T.text('retroMenuOptionRestartDetail'),
        reason: 'LRPS2 reads it at a start',
      );
    });

    test("LRPS2's VR kept from before is not sent: AnyPS5 has no VR, and the host would judge stereo", () async {
      launcher = Ps1Launcher(ps2: true);
      final model = launcher.model..setRetroHostPs2(true);
      model.preferences.retroHostOptions.addAll({
        retroResolutionKeyPs2: '4x',
        'pcsx2_vr_mode': 'stereoscopic',
        'pcsx2_vr_depth': '75%',
        'pcsx2_fastboot': 'disabled',
      });
      launcher.session.limitsPs2Resolution = true;
      await startPs2(recorded());
      expect(launcher.session.startArgs!['options'], {retroResolutionKeyPs2: '4x', 'pcsx2_fastboot': 'disabled'});
    });

    test('a host without ps2ResolutionLimits is neither offered nor sent a PS2 resolution', () async {
      launcher = Ps1Launcher(ps2: true);
      final model = launcher.model..setRetroHostPs2(true);
      model.preferences.retroHostOptions.addAll({retroResolutionKeyPs2: '4x', 'pcsx2_fastboot': 'disabled'});
      await startPs2(recorded());
      expect(launcher.session.startArgs!['options'], {'pcsx2_fastboot': 'disabled'});
      model.openRetroMenu();
      await pumpEventQueue();
      expect([for (final row in model.panelCategories().single.rows) row.id], isNot(contains('resolution')));
    });
  });

  group('the signed release', () {
    test('1.0.0, without an LRPS2 package, shows no PS2 rows, and is checked for SwanStation alone', () async {
      launcher = await Ps1Launcher.withRelease(ps2: false);
      final model = launcher.model..setRetroHostPs2(true);
      expect(model.retroHostInstall!.ps2Core, isNull);
      expect(row('retro-host-ps2-download'), isNull, reason: 'its release has no PS2 emulator to add');
      expect(row('retro-host-ps2'), isNull);
      expect(row('retro-host-ps2-bios'), isNull);
      final checked = await model.retroHostDownload.store.check();
      addTearDown(checked.release);
      expect(checked.ps2Core, isNull);
    });

    test('one with LRPS2 plays a PS2 disc on its checked LRPS2, held beside the host', () async {
      launcher = await Ps1Launcher.withRelease(ps2: true);
      final model = launcher.model..setRetroHostPs2(true);
      final install = model.retroHostInstall!;
      expect(install.checked, isTrue);
      expect(install.ps2Core, p.join(p.dirname(install.host), RetroHostSystem.current!.ps2Core));
      expect(row('retro-host-ps2')!.kind, isA<ToggleRow>());
      expect(row('retro-host-ps2-download')!.title, T.format('retroHostPs2Installed', ['1.1.0']));
      expect(row('retro-host-ps2-remove')!.kind, isA<ActionRow>());
      model.closeOverlay();
      await startPs2(recording.lastStatus('lrps2-no-bios-folder'));
      final checked = launcher.checked.single!;
      expect(checked.held, isTrue);
      expect((checked.core, checked.ps2Core), (install.core, install.ps2Core));
      expect(launcher.session.startArgs?['core'], install.ps2Core);
      expect(launcher.session.startArgs?['console'], RetroConsole.ps2);
      expect(launcher.play.core, install.ps2Core);
      expect(launcher.play.unchecked, isFalse);
    });

    test('one whose LRPS2 was changed fails its check, for a PS1 game too, since one host plays both', () async {
      launcher = await Ps1Launcher.withRelease(ps2: true);
      final model = launcher.model
        ..setRetroHostPs1(true)
        ..setRetroHostPs2(true);
      File(model.retroHostInstall!.ps2Core!).writeAsStringSync('changed');
      await expectLater(model.retroHostDownload.store.check(), throwsA(isA<RetroHostReleaseFailure>()));
      await model.play(launcher.game);
      expect(launcher.opened, isEmpty);
      expect(model.toast, T.text('retroHostCheckFailed'));
    });

    test('one whose LRPS2 package is not added offers it beside the host, and shows no other PS2 row', () async {
      launcher = await Ps1Launcher.withRelease(ps2: true, addPs2: false);
      final model = launcher.model..setRetroHostPs2(true);
      expect(model.retroHostInstall!.ps2Core, isNull);
      final ids = launcher.emulatorSettings().rows.map((row) => row.id).toList();
      expect(ids.indexOf('retro-host-ps2-download'), ids.indexOf('retro-host-download') + 1);
      final offer = row('retro-host-ps2-download')!;
      expect((offer.title, offer.detail), (T.text('retroHostPs2Download'), T.text('retroHostPs2DownloadDetail')));
      expect(offer.kind, isA<ActionRow>());
      for (final id in ['retro-host-ps2', 'retro-host-ps2-bios', 'retro-host-ps2-remove']) {
        expect(row(id), isNull, reason: id);
      }
      expect(model.playsInHost(RetroPlatform.ps2), isFalse);
    });

    group('downloaded', () {
      late FakeGitHub github;
      setUp(() async {
        HttpOverrides.global = null;
        github = await FakeGitHub.start(repository: RetroHostStore.repository);
      });
      tearDown(() async => github.close());

      List<String> fetchedSince(int seen) => github.downloads.skip(seen).map(p.posix.basename).toList();
      final system = RetroHostSystem.current!.name;

      test('the PS2 emulator is added on its own, moves with the host, and goes with a release without it', () async {
        github.releases.add(retroHostFixtureRelease(ps2: true));
        launcher = Ps1Launcher(hostFound: false, retroHostApi: github.api)..addPs2CueSheet('Cue Racer');
        final model = launcher.model;
        expect(row('retro-host-ps2-download'), isNull, reason: 'no host yet');

        await model.retroHostDownload.download();
        expect(model.toast, T.format('retroHostReady', ['1.1.0']));
        expect(fetchedSince(0).where((name) => name.contains('lrps2')), isEmpty, reason: 'never downloaded unasked');
        expect(model.retroHostInstall!.ps2Core, isNull);
        expect(launcher.lists('Cue Racer'), isFalse);

        var seen = github.downloads.length;
        await model.retroHostDownload.ps2.add();
        expect(model.toast, T.format('retroHostPs2Ready', ['1.1.0']));
        expect(fetchedSince(seen).where((name) => name.startsWith('anyps5-')), [
          'anyps5-retro-host-1.1.0-$system-lrps2.files',
          'anyps5-retro-host-1.1.0-$system-lrps2.zip',
        ]);
        expect(model.preferences.retroHostPs2, isTrue, reason: 'the first PS2 emulator turns its games on');
        expect(model.playsInHost(RetroPlatform.ps2), isTrue);
        expect(launcher.lists('Cue Racer'), isTrue, reason: 'scanned again once the host gained LRPS2');
        expect(row('retro-host-ps2-download')!.detail, T.text('retroHostPs2InstalledDetail'));
        for (final id in ['retro-host-ps2', 'retro-host-ps2-bios', 'retro-host-ps2-remove']) {
          expect(row(id), isNotNull, reason: id);
        }

        github.releases.insert(0, retroHostFixtureRelease(tag: 'v1.1.1', ps2: true));
        seen = github.downloads.length;
        await model.retroHostDownload.download();
        expect(model.toast, T.format('retroHostReady', ['1.1.1']));
        expect(fetchedSince(seen), contains('anyps5-retro-host-1.1.1-$system-lrps2.zip'));
        expect(model.retroHostDownload.installedCores, {RetroHostCorePackage.lrps2});
        expect(row('retro-host-ps2-download')!.title, T.format('retroHostPs2Installed', ['1.1.1']));
        (await model.retroHostDownload.store.check()).release();

        github.releases.insert(0, retroHostFixtureRelease(tag: 'v1.2.0'));
        await model.retroHostDownload.download();
        expect(model.toast, T.format('retroHostReady', ['1.2.0']));
        expect(model.retroHostInstall!.ps2Core, isNull);
        expect(row('retro-host-ps2-download'), isNull, reason: 'the new release has no PS2 emulator');
        expect(model.preferences.retroHostPs2, isTrue, reason: 'the setting is kept for a later host');
        expect(launcher.lists('Cue Racer'), isFalse, reason: 'scanned again once the host lost LRPS2');
      });

      test('the PS2 emulator is removed again, and PS1 games still play', () async {
        github.releases.add(retroHostFixtureRelease(ps2: true));
        launcher = Ps1Launcher(hostFound: false, retroHostApi: github.api)..addPs2CueSheet('Cue Racer');
        final model = launcher.model;
        await model.retroHostDownload.download();
        await model.retroHostDownload.ps2.add();
        final ps2Core = model.retroHostInstall!.ps2Core!;

        (row('retro-host-ps2-remove')!.kind as ActionRow).run();
        await until(() => model.toast == T.text('retroHostPs2Removed'), const Duration(seconds: 10));
        expect(File(ps2Core).existsSync(), isFalse);
        expect(model.retroHostInstall!.ps2Core, isNull);
        expect(launcher.lists('Cue Racer'), isFalse);
        for (final id in ['retro-host-ps2', 'retro-host-ps2-bios', 'retro-host-ps2-remove']) {
          expect(row(id), isNull, reason: id);
        }
        expect(row('retro-host-ps2-download')!.title, T.text('retroHostPs2Download'), reason: 'offered again');

        model.closeOverlay();
        final playing = model.play(launcher.game);
        await until(() => launcher.opened.isNotEmpty, const Duration(seconds: 10));
        expect(launcher.checked.single?.ps2Core, isNull);
        launcher.session.readyCompleter.complete();
        await playing;
      });

      test('the PS2 emulator is neither added nor removed while a game plays', () async {
        github.releases.add(retroHostFixtureRelease(ps2: true));
        launcher = Ps1Launcher(hostFound: false, retroHostApi: github.api);
        final model = launcher.model;
        await model.retroHostDownload.download();
        model.closeOverlay();
        await launcher.start();
        final seen = github.downloads.length;
        await model.retroHostDownload.ps2.add();
        expect(model.toast, T.text('retroHostPs2CloseGame'));
        expect(github.downloads, hasLength(seen));
        expect(model.retroHostInstall!.ps2Core, isNull);
      });

      test('the PS2 emulator is not removed while a game plays, nor a host started while it is', () async {
        github.releases.add(retroHostFixtureRelease(ps2: true));
        launcher = Ps1Launcher(hostFound: false, retroHostApi: github.api);
        final model = launcher.model;
        await model.retroHostDownload.download();
        await model.retroHostDownload.ps2.add();
        final ps2Core = model.retroHostInstall!.ps2Core!;
        model.closeOverlay();
        await launcher.start();
        await model.retroHostDownload.ps2.remove();
        expect(model.toast, T.text('retroHostPs2CloseGame'));
        expect(File(ps2Core).existsSync(), isTrue);
        await model.closeRetroGame();

        model.retroHostDownload.installing = true;
        await model.play(launcher.game);
        expect(model.toast, T.text('retroHostUpdating'), reason: 'no start while the PS2 emulator changes');
        model.retroHostDownload.installing = false;
      });

      test('without the release of its host on GitHub, the PS2 emulator is not available', () async {
        launcher = await Ps1Launcher.withRelease(ps2: true, addPs2: false, retroHostApi: github.api);
        final model = launcher.model;
        github.releases.add(retroHostFixtureRelease(tag: 'v1.1.1', ps2: true));
        await model.retroHostDownload.ps2.add();
        expect(model.toast, T.text('retroHostPs2NotYet'));
        expect(row('retro-host-ps2-download')!.detail, T.text('retroHostPs2NotYet'));
        expect(model.retroHostInstall!.ps2Core, isNull);
      });
    });
  });
}
