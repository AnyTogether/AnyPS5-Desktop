import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/retro_host/retro_graphics.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/ps2_host_recording.dart';

/// The Graphics rows besides the internal resolution, read from statuses the real host sent: PS1
/// from SwanStation drawing on the GPU (test/fixtures/retro-host-swanstation-status.json), PS2 from
/// the real LRPS2's options (test/fixtures/retro_host_ps2_recording.json, `lrps2-no-bios-folder`,
/// which ended before it drew, so `hardware` is set for the settings that need the GPU).
void main() {
  Map<String, Object?> ps1Status() =>
      ((jsonDecode(File('test/fixtures/retro-host-swanstation-status.json').readAsStringSync()) as Map)['status']
              as Map)
          .cast<String, Object?>();

  Map<String, Object?> ps2Status() => {
    ...Ps2HostRecording.load().lastStatus('lrps2-no-bios-folder').toJson(),
    'hardware': true,
  };

  RetroStatus edited(Map<String, Object?> status, Map<String, Map<String, Object?>> changes, {bool? hardware}) {
    final options = (status['options']! as Map).cast<String, Object?>();
    for (final MapEntry(:key, :value) in changes.entries) {
      options[key] = {...(options[key]! as Map).cast<String, Object?>(), ...value};
    }
    return RetroStatus.parse({
      ...status,
      'options': options,
      'hardware': ?hardware,
    }, ps2: status['console'] == RetroConsole.ps2);
  }

  RetroStatus ps1([Map<String, Map<String, Object?>> changes = const {}, bool? hardware]) =>
      edited(ps1Status(), changes, hardware: hardware);
  RetroStatus ps2([Map<String, Map<String, Object?>> changes = const {}]) => edited(ps2Status(), changes);

  List<String?> levels(RetroGraphicsChoice choice) => [
    for (final value in choice.values) value.offer?.level.name ?? value.label,
  ];

  test('PS1: smooth textures, fix wobbly 3D and widescreen from the real SwanStation, none of PS2', () {
    final status = ps1();
    final smooth = RetroGraphicsChoice.of(status, retroSmoothTextures)!;
    expect(levels(smooth), ['off', 'smooth', 'extraSmooth']);
    expect([for (final value in smooth.values) value.label], ['Nearest-Neighbor', 'Bilinear', 'xBR']);
    expect(smooth.selected, 0);
    expect(smooth.note, RetroGraphicsNote.none);
    final wobbly = RetroGraphicsChoice.of(status, retroFixWobbly3d)!;
    expect(levels(wobbly), ['off', 'on']);
    expect(wobbly.selected, 0);
    final widescreen = RetroGraphicsChoice.of(status, retroWidescreenPs1)!;
    expect(levels(widescreen), ['off', 'on']);
    expect(widescreen.selected, 0);
    expect(RetroGraphicsChoice.of(status, retroSharperTextures), isNull);
    expect(RetroGraphicsChoice.of(status, retroWidescreenPs2), isNull);
    expect(RetroGraphicsChoice.of(null, retroSmoothTextures), isNull);
  });

  test('without the GPU only widescreen is offered, and an option the host does not list has no row', () {
    final software = ps1(const {}, false);
    expect(RetroGraphicsChoice.of(software, retroSmoothTextures), isNull);
    expect(RetroGraphicsChoice.of(software, retroFixWobbly3d), isNull);
    expect(RetroGraphicsChoice.of(software, retroWidescreenPs1), isNotNull);
    final status = ps1Status();
    (status['options']! as Map).remove('swanstation_GPU_PGXPEnable');
    expect(RetroGraphicsChoice.of(RetroStatus.parse(status), retroFixWobbly3d), isNull);
  });

  test("only values the host lists are offered, and a chosen value no offer has shows with the host's label", () {
    final fewer = ps1({
      'swanstation_GPU_TextureFilter': {
        'values': ['Nearest', 'Bilinear'],
        'labels': ['Nearest-Neighbor', 'Bilinear'],
        'selected': 1,
        'activeValue': 'Bilinear',
      },
    });
    final choice = RetroGraphicsChoice.of(fewer, retroSmoothTextures)!;
    expect(levels(choice), ['off', 'smooth'], reason: 'the host lists no xBR');
    expect(choice.selected, 1);

    final jinc = ps1({
      'swanstation_GPU_TextureFilter': {'selected': 3, 'activeValue': 'JINC2'},
    });
    final other = RetroGraphicsChoice.of(jinc, retroSmoothTextures)!;
    expect(levels(other), ['off', 'smooth', 'extraSmooth', 'JINC2']);
    expect(other.selected, 3);
    expect(other.changesFor(jinc, 1), {'swanstation_GPU_TextureFilter': 'Bilinear'});
    expect(other.changesFor(jinc, 3), isEmpty, reason: 'already chosen');
  });

  test('widescreen sets the hack and the 16:9 aspect ratio together; its row follows the hack', () {
    final status = ps1();
    final off = RetroGraphicsChoice.of(status, retroWidescreenPs1)!;
    expect(off.changesFor(status, 1), {
      'swanstation_GPU_WidescreenHack': 'true',
      'swanstation_Display_AspectRatio': '16:9',
    });
    expect(off.changesFor(status, 0), isEmpty);
    final halfway = ps1({
      'swanstation_GPU_WidescreenHack': {'selected': 0, 'activeValue': 'true'},
    });
    final half = RetroGraphicsChoice.of(halfway, retroWidescreenPs1)!;
    expect(levels(half), ['off', 'on', 'Enabled'], reason: 'the hack is on at 4:3: neither Off nor On');
    expect(half.selected, 2);
    expect(half.changesFor(halfway, 0), {'swanstation_GPU_WidescreenHack': 'false'}, reason: '4:3 already');
    expect(half.changesFor(halfway, 1), {'swanstation_Display_AspectRatio': '16:9'}, reason: 'On, set whole');
  });

  test('the note: in a moment while a chosen value is not in effect yet', () {
    final pending = ps1({
      'swanstation_GPU_PGXPEnable': {'selected': 0},
    });
    final choice = RetroGraphicsChoice.of(pending, retroFixWobbly3d)!;
    expect(choice.selected, 1);
    expect(choice.note, RetroGraphicsNote.applying);
    final aspect = ps1({
      'swanstation_GPU_WidescreenHack': {'selected': 0, 'activeValue': 'true'},
      'swanstation_Display_AspectRatio': {'selected': 1},
    });
    expect(
      RetroGraphicsChoice.of(aspect, retroWidescreenPs1)!.note,
      RetroGraphicsNote.applying,
      reason: 'the aspect ratio is not in effect yet',
    );
  });

  test("PS2: sharper textures and widescreen from the real LRPS2's options, the patch at the next start", () {
    final status = ps2();
    expect(RetroGraphicsChoice.of(status, retroSmoothTextures), isNull);
    expect(RetroGraphicsChoice.of(status, retroWidescreenPs1), isNull);
    final sharper = RetroGraphicsChoice.of(status, retroSharperTextures)!;
    expect(levels(sharper), ['off', 'on']);
    expect(sharper.selected, 0);
    expect(sharper.note, RetroGraphicsNote.none, reason: 'LRPS2 applies it while the game runs');
    expect(sharper.changesFor(status, 1), {'pcsx2_anisotropic_filtering': '16x'});
    final widescreen = RetroGraphicsChoice.of(status, retroWidescreenPs2)!;
    expect(levels(widescreen), ['off', 'on'], reason: '16:10, 21:9 and 32:9 are not offered');
    expect(widescreen.note, RetroGraphicsNote.changesAtNextStart, reason: 'LRPS2 patches the game at boot');
    final chosen = ps2({
      'pcsx2_widescreen_hint': {'selected': 1},
    });
    final next = RetroGraphicsChoice.of(chosen, retroWidescreenPs2)!;
    expect(next.selected, 1);
    expect(next.note, RetroGraphicsNote.nextStart);
    expect(
      RetroGraphicsChoice.of(RetroStatus.parse({...ps2Status(), 'hardware': false}, ps2: true), retroSharperTextures),
      isNull,
    );
  });

  test('the defaults of the settings not chosen: by resolution for PS1, sharper textures for PS2', () {
    expect(retroGraphicsDefaults({}, ps2: false), {
      'swanstation_GPU_TextureFilter': 'Nearest',
      'swanstation_GPU_PGXPEnable': 'true',
      'swanstation_GPU_TrueColor': 'true',
    });
    expect(retroGraphicsDefaults({'swanstation_GPU_ResolutionScale': '2'}, ps2: false), {
      'swanstation_GPU_TextureFilter': 'Bilinear',
      'swanstation_GPU_PGXPEnable': 'true',
      'swanstation_GPU_TrueColor': 'true',
    });
    expect(
      retroGraphicsDefaults({
        'swanstation_GPU_TextureFilter': 'xBR',
        'swanstation_GPU_PGXPEnable': 'false',
      }, ps2: false),
      {'swanstation_GPU_TrueColor': 'true'},
    );
    expect(retroGraphicsDefaults({}, ps2: true), {'pcsx2_anisotropic_filtering': '16x'});
    expect(retroGraphicsDefaults({'pcsx2_anisotropic_filtering': 'disabled'}, ps2: true), isEmpty);
    for (final ps2 in [false, true]) {
      final widescreen = ps2 ? retroWidescreenPs2 : retroWidescreenPs1;
      expect(
        retroGraphicsDefaults({}, ps2: ps2).keys.toSet().intersection(widescreen.keys),
        isEmpty,
        reason: 'widescreen is never chosen for the player',
      );
    }
  });
}
