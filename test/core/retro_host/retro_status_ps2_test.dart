import 'package:anyps5_desktop/core/retro_host/retro_host_protocol.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_session.dart';
import 'package:anyps5_desktop/ui/app_model.dart' show retroBiosFolderOf, retroHostErrorKey;
import 'package:anyps5_desktop/ui/retro_host/retro_option_sections.dart';
import 'package:test/test.dart';

import '../../support/ps2_host_recording.dart';

/// A PS2 game's messages (capability `ps2`, anyps5-retro-host docs/protocol.md "start" and "status")
/// as a host built from anyps5-retro-host main sent them, with the real LRPS2 and no BIOS and with
/// its fake core ([Ps2HostRecording]).
void main() {
  final recording = Ps2HostRecording.load();

  test('both hosts list ps2 after the capabilities this launcher already knew', () {
    for (final scenario in ['lrps2-welcome', 'fake-welcome']) {
      final capabilities = recording.welcome(scenario)['capabilities']! as List<Object?>;
      expect(capabilities.first, retroCapabilityPs1, reason: scenario);
      expect(capabilities, contains(retroCapabilityPs2), reason: scenario);
    }
  });

  test('LRPS2 with no BIOS ends the game with bios before a first frame, and says it is a PS2 game', () {
    for (final scenario in ['lrps2-no-bios-folder', 'lrps2-not-a-bios']) {
      final ended = recording.lastStatus(scenario);
      expect((ended.ended, ended.ready, ended.hardware), (true, false, false), reason: scenario);
      expect(ended.errorCode, RetroErrorCode.bios, reason: scenario);
      expect(ended.error, 'No PS2 BIOS was found.', reason: scenario);
      expect(ended.console, RetroConsole.ps2, reason: scenario);
      expect(retroHostErrorKey(ended.errorCode, ps2: true), 'retroHostPs2BiosDetail', reason: scenario);
      expect(retroHostErrorKey(ended.errorCode), 'retroHostBiosDetail', reason: "a PS1 game's words stay");
      expect(retroBiosFolderOf(retroHostErrorKey(ended.errorCode, ps2: true)), 'retroHostPs2BiosFolder');
    }
  });

  test("the launcher's PS2 start is the one the host took, and a PS2 game's playlist is refused", () {
    final start = recording.calls('lrps2-no-bios-folder', 'start').single;
    final args = start.call['args']! as Map<String, Object?>;
    final ours = RetroHostStartRequest(
      console: RetroConsole.ps2,
      core: args['core']! as String,
      disc: args['disc']! as String,
      system: args['system']! as String,
      saves: args['saves']! as String,
    ).toArgs();
    expect(ours, args);
    expect((start.reply['result']! as Map)['epoch'], isA<int>());

    final refused = recording.calls('fake-ps2-initial-disc-refused', 'start').single.reply;
    expect((refused['error']! as Map)['code'], RetroCallError.argument);
  });

  test("LRPS2's options are listed with no BIOS: each goes to PS2 games only, the curated graphics and Advanced", () {
    final options = recording.lastStatus('lrps2-no-bios-folder').options;
    expect(options, isNotEmpty);
    expect(options.keys.every((key) => key.startsWith('pcsx2_')), isTrue);
    expect(options.keys, isNot(contains('pcsx2_bios')), reason: 'LRPS2 lists it only once it found a BIOS');
    expect(
      options.keys.toSet().intersection(const {
        'pcsx2_shared_memory_cards',
        'pcsx2_renderer',
        'pcsx2_multitap',
        'pcsx2_usb_camera',
        'pcsx2_dev9_eth',
        'pcsx2_dev9_hdd',
        'pcsx2_dev9_hdd_size',
      }),
      isEmpty,
      reason: 'the host fixes those itself',
    );
    expect(options, contains('pcsx2_upscale_multiplier'));
    List<String> inSection(RetroOptionSection? section) => [
      for (final key in options.keys)
        if (retroOptionSection(key) == section) key.substring('pcsx2_'.length),
    ];
    expect(inSection(RetroOptionSection.graphics), [
      'upscale_multiplier',
      'widescreen_hint',
      'anisotropic_filtering',
    ], reason: 'the internal resolution and the options the Graphics rows set');
    expect(inSection(RetroOptionSection.advanced), [
      'fastboot',
      'fastcdvd',
      'hint_language_unlock',
      'enable_cheats',
      'use_external_gameindex',
      for (final port in [1, 2]) ...[
        'axis_deadzone$port',
        'button_deadzone$port',
        'axis_scale$port',
        'invert_left_stick$port',
        'invert_right_stick$port',
        'analog_mode$port',
        'enable_rumble$port',
      ],
    ], reason: 'the system, disc speed and controller options');
    final hidden = inSection(null);
    expect(hidden, containsAll(['vr_mode', 'vr_depth']), reason: 'AnyPS5 has no VR');
    expect(hidden, containsAll(['enable_hw_hacks', 'cpu_sprite_size', 'force_sprite_position']), reason: 'HW Hacks');
    expect(hidden, containsAll(['blending_accuracy', 'ee_cycle_rate', 'mtvu', 'uncapped_framerate_hint']));
    expect(hidden, hasLength(options.length - 22), reason: 'every other video, emulation and HW Hacks option');
    for (final key in options.keys) {
      final section = retroOptionSection(key);
      expect(retroOptionSent(key), isFalse, reason: '$key is no PS1 option');
      expect(
        retroOptionSent(key, ps2: true),
        section == RetroOptionSection.advanced || section == RetroOptionSection.graphics,
        reason: '$key: a kept value goes only to an option the menu shows',
      );
    }
    expect(
      retroOptionSent('pcsx2_upscale_multiplier', ps2: true),
      isTrue,
      reason: 'the menu offers it; RetroHostGame keeps it from a host without ps2ResolutionLimits',
    );
    expect(retroOptionSent('pcsx2_upscale_multiplier'), isFalse, reason: 'no PS1 option');
    expect(retroOptionSent('swanstation_Console_Region', ps2: true), isFalse);
    expect(retroOptionSent('swanstation_Console_Region'), isTrue);
  });

  test("the fake core's PS2 games: bios, a running game whose BIOS takes effect at the next start, then PS1", () {
    final noBios = recording.lastStatus('fake-ps2-no-bios');
    expect((noBios.errorCode, noBios.console), (RetroErrorCode.bios, RetroConsole.ps2));

    final ready = recording.readyStatus('fake-ps2-ready');
    expect((ready.ready, ready.ended, ready.console), (true, false, RetroConsole.ps2));
    final bios = ready.options['pcsx2_bios']!;
    expect(bios.restart, isTrue, reason: 'LRPS2 reads it only when it loads a game');
    expect(retroOptionSection(bios.key), RetroOptionSection.advanced);
    final stopped = recording.lastStatus('fake-ps2-ready');
    expect((stopped.ended, stopped.errorCode, stopped.console), (true, RetroErrorCode.none, RetroConsole.ps2));

    expect(recording.readyStatus('fake-ps1-after-ps2').console, RetroConsole.ps1);
  });

  test('a host that lists ps2 must send console as ps1 or ps2; any other host is not read for it', () {
    final ended = recording.statusResults('lrps2-no-bios-folder').last;
    for (final value in <Object?>['ps3', 2, null, '']) {
      expect(
        () => RetroStatus.parse({...ended, 'console': value}, ps2: true),
        throwsA(isA<RetroProtocolError>()),
        reason: '$value',
      );
    }
    expect(() => RetroStatus.parse({...ended}..remove('console'), ps2: true), throwsA(isA<RetroProtocolError>()));
    expect(RetroStatus.parse({...ended, 'console': 'ps3'}).console, isNull);
    expect(recording.lastStatus('lrps2-no-bios-folder').toJson()['console'], RetroConsole.ps2);
  });
}
