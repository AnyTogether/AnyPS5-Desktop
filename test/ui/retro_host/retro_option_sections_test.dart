import 'package:anyps5_desktop/ui/retro_host/retro_option_sections.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/ps1_launcher.dart';

void main() {
  test('the fifty options of the real host fall into their sections, ten not shown', () {
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
      'Main_ApplyGameSettings',
      'Main_RunaheadFrameCount',
      'Hacks_OldMDECRoutines',
    ]);
    expect(inSection(RetroOptionSection.graphics), [
      'GPU_ResolutionScale',
      'GPU_UseSoftwareRendererForReadbacks',
      'GPU_MSAA',
      'GPU_TrueColor',
      'GPU_ScaledDithering',
      'GPU_DisableInterlacing',
      'GPU_ForceNTSCTimings',
      'Display_Force4_3For24Bit',
      'GPU_ChromaSmoothing24Bit',
      'GPU_TextureFilter',
      'GPU_WidescreenHack',
      'GPU_PGXPEnable',
      'Display_AspectRatio',
      'Display_CropMode',
      'GPU_DownsampleMode',
      'GPU_ShaderPrecompile',
    ]);
    expect(inSection(null), [
      'Display_ShowOSDMessages',
      'Display_ActiveStartOffset',
      'Display_ActiveEndOffset',
      'Display_LineStartOffset',
      'Display_LineEndOffset',
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
    expect(retroOptionSection('swanstation_Audio_Something'), RetroOptionSection.audio);
    expect(retroOptionSection('swanstation_Controller_ShowCrosshair'), isNull);
    expect(retroOptionSection('swanstation_TextureReplacements_Other'), isNull);
    expect(retroOptionSection('swanstation_NewGroup_NewOption'), RetroOptionSection.advanced);
    expect(retroOptionSection('swanstation_Lonely'), RetroOptionSection.advanced);
    expect(retroOptionSection('other_core_option'), RetroOptionSection.advanced);
    expect(retroOptionShown('swanstation_Console_Enable8MBRAM'), isFalse);
    expect(retroOptionShown('swanstation_Console_Region'), isTrue);
  });

  test('SwanStation\'s own (Restart) leaves the title, since the menu says it under each such option', () {
    expect(retroOptionTitle('NTSC-U BIOS (Restart)'), 'NTSC-U BIOS');
    expect(retroOptionTitle('Use Per-Frame Audio Batching (Restart) '), 'Use Per-Frame Audio Batching');
    expect(retroOptionTitle('Console Region'), 'Console Region');
    expect(retroOptionTitle('(Restart)'), '(Restart)');
    expect(retroOptionTitle('Restart Count'), 'Restart Count');
  });
}
