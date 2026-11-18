import 'package:anyps5_desktop/ui/retro_host/retro_option_sections.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/ps1_launcher.dart';

void main() {
  test('the fifty options of the real host fall into their sections, eighteen not shown', () {
    final keys = recordedStatus().options.keys.toList();
    expect(keys, hasLength(50));
    List<String> inSection(RetroOptionSection? section) => [
      for (final key in keys)
        if (retroOptionSection(key) == section) key.substring('swanstation_'.length),
    ];
    expect(inSection(RetroOptionSection.audio), ['CDROM_MuteCDAudio', 'Audio_FastHook']);
    expect(inSection(RetroOptionSection.controller), [
      'Controller_AnalogCombo',
      'Controller_EnableRumble',
      'Controller1_ForceAnalog',
      'Controller1_AnalogDPadInDigitalMode',
      'Controller1_AxisScale',
      'Controller1_VibrationBias',
    ]);
    expect(inSection(RetroOptionSection.console), [
      'Console_Region',
      'BIOS_PathNTSCU',
      'BIOS_PatchFastBoot',
      'CDROM_RegionCheck',
      'CDROM_ReadSpeedup',
      'CDROM_SeekSpeedup',
      'CPU_Overclock',
    ]);
    expect(inSection(RetroOptionSection.advanced), [
      'CDROM_ReadThread',
      'CDROM_LoadImagePatches',
      'CDROM_LoadImageToRAM',
      'CDROM_PreCacheCHD',
      'CPU_ExecutionMode',
      'CDROM_ReadaheadSectors',
      'Main_RunaheadFrameCount',
      'Hacks_OldMDECRoutines',
    ]);
    expect(inSection(RetroOptionSection.graphics), [
      'GPU_ResolutionScale',
      'GPU_TrueColor',
      'GPU_ScaledDithering',
      'GPU_ChromaSmoothing24Bit',
      'GPU_TextureFilter',
      'GPU_WidescreenHack',
      'GPU_PGXPEnable',
      'Display_AspectRatio',
      'GPU_ShaderPrecompile',
    ]);
    expect(inSection(null), [
      'GPU_UseSoftwareRendererForReadbacks',
      'GPU_MSAA',
      'GPU_DisableInterlacing',
      'GPU_ForceNTSCTimings',
      'Display_Force4_3For24Bit',
      'Display_CropMode',
      'GPU_DownsampleMode',
      'Display_ShowOSDMessages',
      'Display_ActiveStartOffset',
      'Display_ActiveEndOffset',
      'Display_LineStartOffset',
      'Display_LineEndOffset',
      'Main_ApplyGameSettings',
      'CPU_RecompilerICache',
      'CPU_RecompilerBlockLinking',
      'CPU_FastmemMode',
      'TextureReplacements_EnableVRAMWriteReplacements',
      'Console_Enable8MBRAM',
    ]);
  });

  test('options the recording does not have go by their group, and unknown ones to Advanced', () {
    expect(retroOptionSection('swanstation_Controller2_ForceAnalog'), RetroOptionSection.controller);
    expect(retroOptionSection('swanstation_ControllerPorts_MultitapMode'), RetroOptionSection.controller);
    expect(retroOptionSection('swanstation_BIOS_PathPAL'), RetroOptionSection.console);
    expect(retroOptionSection('swanstation_GPU_PGXPCulling'), RetroOptionSection.graphics);
    for (final key in ['swanstation_GPU_PGXPVertexCache', 'swanstation_GPU_PGXPCPU', 'swanstation_GPU_MSAA']) {
      expect(retroOptionSection(key), isNull, reason: key);
      expect(retroOptionSent(key), isFalse, reason: key);
    }
    expect(retroOptionSection('swanstation_Audio_Something'), RetroOptionSection.audio);
    expect(retroOptionSection('swanstation_Controller_ShowCrosshair'), isNull);
    expect(retroOptionSection('swanstation_TextureReplacements_Other'), isNull);
    expect(retroOptionSection('swanstation_NewGroup_NewOption'), RetroOptionSection.advanced);
    expect(retroOptionSection('swanstation_Lonely'), RetroOptionSection.advanced);
    expect(retroOptionSection('other_core_option'), RetroOptionSection.advanced);
    for (final key in ['pcsx2_vr_mode', 'pcsx2_vr_depth', 'pcsx2_vr_other']) {
      expect(retroOptionSection(key), isNull, reason: '$key: AnyPS5 has no VR');
      expect(retroOptionSent(key, ps2: true), isFalse, reason: key);
    }
    for (final key in ['pcsx2_vu0_softfloat', 'pcsx2_enable_hw_hacks', 'pcsx2_pgs_ssaa', 'pcsx2_pgs_other']) {
      expect(retroOptionSection(key), isNull, reason: key);
      expect(retroOptionSent(key, ps2: true), isFalse, reason: '$key is not sent though an older launcher kept it');
    }
    expect(retroOptionSection('pcsx2_bios'), RetroOptionSection.advanced);
    expect(retroOptionSection('pcsx2_new_option'), RetroOptionSection.advanced);
    expect(retroOptionShown('swanstation_Console_Enable8MBRAM'), isFalse);
    expect(retroOptionShown('swanstation_Console_Region'), isTrue);
    expect(retroOptionSent('swanstation_Console_Region'), isTrue);
    expect(retroOptionSent('swanstation_Console_Enable8MBRAM'), isFalse);
    expect(retroOptionSent('swanstation_GPU_ResolutionScale'), isTrue, reason: 'the menu offers the resolution');
    expect(retroOptionSent('swanstation_GPU_ResolutionScale', ps2: true), isFalse, reason: 'no PS2 option');
    for (final key in [
      'swanstation_GPU_TextureFilter',
      'swanstation_GPU_PGXPEnable',
      'swanstation_GPU_WidescreenHack',
      'swanstation_Display_AspectRatio',
    ]) {
      expect(retroOptionSection(key), RetroOptionSection.graphics, reason: key);
      expect(retroOptionSent(key), isTrue, reason: '$key: a Graphics row sets it');
      expect(retroOptionSent(key, ps2: true), isFalse, reason: key);
    }
    for (final key in ['pcsx2_anisotropic_filtering', 'pcsx2_widescreen_hint']) {
      expect(retroOptionSection(key), RetroOptionSection.graphics, reason: key);
      expect(retroOptionSent(key, ps2: true), isTrue, reason: '$key: a Graphics row sets it');
    }
    for (final key in ['swanstation_GPU_TrueColor', 'swanstation_GPU_ChromaSmoothing24Bit']) {
      expect(retroOptionSection(key), RetroOptionSection.graphics, reason: key);
      expect(retroOptionSent(key), isFalse, reason: '$key: no row sets it, so a kept value is not sent');
    }
  });

  test('a start sends the kept values the menu shows over the Graphics defaults', () {
    expect(retroStartOptions({}, ps2: false), {
      'swanstation_GPU_TextureFilter': 'Nearest',
      'swanstation_GPU_PGXPEnable': 'true',
      'swanstation_GPU_TrueColor': 'true',
    }, reason: 'Native: no smoothing; fix wobbly 3D and true colour on; no widescreen');
    expect(
      retroStartOptions({'swanstation_GPU_ResolutionScale': '3', 'swanstation_CDROM_ReadSpeedup': '2'}, ps2: false),
      {
        'swanstation_GPU_TextureFilter': 'Bilinear',
        'swanstation_GPU_PGXPEnable': 'true',
        'swanstation_GPU_TrueColor': 'true',
        'swanstation_GPU_ResolutionScale': '3',
        'swanstation_CDROM_ReadSpeedup': '2',
      },
      reason: 'smooth from 2x up',
    );
    expect(
      retroStartOptions({
        'swanstation_GPU_TextureFilter': 'xBR',
        'swanstation_GPU_PGXPEnable': 'false',
        'swanstation_GPU_TrueColor': 'false',
        'swanstation_GPU_WidescreenHack': 'true',
        'swanstation_Display_AspectRatio': '16:9',
        'swanstation_GPU_MSAA': '4',
        'pcsx2_anisotropic_filtering': 'disabled',
      }, ps2: false),
      {
        'swanstation_GPU_TrueColor': 'true',
        'swanstation_GPU_TextureFilter': 'xBR',
        'swanstation_GPU_PGXPEnable': 'false',
        'swanstation_GPU_WidescreenHack': 'true',
        'swanstation_Display_AspectRatio': '16:9',
      },
      reason: 'the values the player chose win; true colour has no row; MSAA and PS2 options are not sent',
    );
    expect(retroStartOptions({}, ps2: true), {'pcsx2_anisotropic_filtering': '16x'});
    expect(
      retroStartOptions({
        'pcsx2_anisotropic_filtering': 'disabled',
        'pcsx2_widescreen_hint': 'enabled (16:9)',
        'pcsx2_vr_mode': 'stereoscopic',
        'pcsx2_enable_hw_hacks': 'enabled',
        'pcsx2_fastboot': 'disabled',
        'swanstation_GPU_PGXPEnable': 'false',
      }, ps2: true),
      {
        'pcsx2_anisotropic_filtering': 'disabled',
        'pcsx2_widescreen_hint': 'enabled (16:9)',
        'pcsx2_fastboot': 'disabled',
      },
      reason: 'stereo and a hardware fix kept by an older launcher are dropped',
    );
  });

  test('SwanStation\'s own (Restart) leaves the title, since the menu says it under each such option', () {
    expect(retroOptionTitle('NTSC-U BIOS (Restart)'), 'NTSC-U BIOS');
    expect(retroOptionTitle('Use Per-Frame Audio Batching (Restart) '), 'Use Per-Frame Audio Batching');
    expect(retroOptionTitle('Console Region'), 'Console Region');
    expect(retroOptionTitle('(Restart)'), '(Restart)');
    expect(retroOptionTitle('Restart Count'), 'Restart Count');
  });
}
