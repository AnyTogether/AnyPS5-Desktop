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
      'options': {'pcsx2_fastboot': 'disabled', 'pcsx2_bios': 'scph-mine.bin', 'pcsx2_anisotropic_filtering': '16x'},
    }, reason: 'sharper textures start on');
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
      'options': {
        'swanstation_Console_Region': 'NTSC-J',
        'swanstation_GPU_TextureFilter': 'Nearest',
        'swanstation_GPU_PGXPEnable': 'true',
        'swanstation_GPU_TrueColor': 'true',
      },
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
      expect(first, isNot(contains('section-graphics')), reason: 'a host without ps2ResolutionLimits');
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
      expect(first, containsAllInOrder(['section-audio', 'section-graphics']));
      expect(
        first,
        isNot(contains('section-advanced')),
        reason: "LRPS2's VR, the recording's other option, is not shown",
      );
      expect(
        launcher.row('section-graphics').detail,
        T.format('retroResolutionRefusedDetail', ['4x']),
        reason: 'the refusal shows before Graphics is opened',
      );
      (launcher.row('section-graphics').kind as ActionRow).run();
      expect([for (final row in model.panelCategories().single.rows) row.id], ['resolution']);
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
      expect(launcher.session.startArgs!['options'], {
        retroResolutionKeyPs2: '4x',
        'pcsx2_fastboot': 'disabled',
        'pcsx2_anisotropic_filtering': '16x',
      });
    });

    test('a host without ps2ResolutionLimits is neither offered nor sent a PS2 resolution', () async {
      launcher = Ps1Launcher(ps2: true);
      final model = launcher.model..setRetroHostPs2(true);
      model.preferences.retroHostOptions.addAll({retroResolutionKeyPs2: '4x', 'pcsx2_fastboot': 'disabled'});
      await startPs2(recorded());
      expect(launcher.session.startArgs!['options'], {
        'pcsx2_fastboot': 'disabled',
        'pcsx2_anisotropic_filtering': '16x',
      });
      model.openRetroMenu();
      await pumpEventQueue();
      expect(
        [for (final row in model.panelCategories().single.rows) row.id],
        isNot(contains('section-graphics')),
        reason: 'the recording lists no other graphics option',
      );
    });
  });

  group('the signed release', () {
    test('one without LRPS2 shows no PS2 rows, and is checked for SwanStation alone', () async {
      launcher = await Ps1Launcher.withRelease(ps2: false);
      final model = launcher.model..setRetroHostPs2(true);
      expect(model.retroHostInstall!.ps2Core, isNull);
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

    group('downloaded', () {
      late FakeGitHub github;
      setUp(() async {
        HttpOverrides.global = null;
        github = await FakeGitHub.start(repository: RetroHostStore.repository);
      });
      tearDown(() async => github.close());

      test('one that adds LRPS2 lists PS2 cue sheets, and a newer one without it hides them again', () async {
        github.releases.add(retroHostFixtureRelease(ps2: true));
        launcher = Ps1Launcher(hostFound: false, retroHostApi: github.api)..addPs2CueSheet('Cue Racer');
        final model = launcher.model..setRetroHostPs2(true);
        expect(model.playsInHost(RetroPlatform.ps2), isFalse, reason: 'no host yet');
        expect(launcher.lists('Cue Racer'), isFalse, reason: 'it would start in PCSX2');

        await model.retroHostDownload.download();
        expect(model.toast, T.format('retroHostReady', ['1.0.0']));
        expect(model.retroHostInstall!.ps2Core, isNotNull);
        expect(model.playsInHost(RetroPlatform.ps2), isTrue);
        expect(launcher.lists('Cue Racer'), isTrue, reason: 'scanned again once the host gained LRPS2');
        expect(model.games.singleWhere((game) => game.name == 'Cue Racer').retro!.platform, RetroPlatform.ps2);

        github.releases.insert(0, retroHostFixtureRelease(tag: 'v1.0.1'));
        await model.retroHostDownload.download();
        expect(model.toast, T.format('retroHostReady', ['1.0.1']));
        expect(model.retroHostInstall!.ps2Core, isNull);
        expect(model.preferences.retroHostPs2, isTrue, reason: 'the setting is kept for a later host');
        expect(model.playsInHost(RetroPlatform.ps2), isFalse);
        expect(launcher.lists('Cue Racer'), isFalse, reason: 'scanned again once the host lost LRPS2');
      });
    });
  });
}
