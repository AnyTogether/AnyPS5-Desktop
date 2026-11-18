import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/retro_host/retro_host_protocol.dart';
import 'package:anyps5_desktop/core/retro_host/retro_graphics.dart';
import 'package:anyps5_desktop/core/retro_host/retro_resolution.dart';
import 'package:flutter_test/flutter_test.dart';

/// The internal resolution the in-game menu offers, read from statuses the real host sent: PS1 from
/// SwanStation drawing on the GPU (test/fixtures/retro-host-swanstation-status.json), PS2 from LRPS2
/// on a host with `ps2ResolutionLimits` (test/fixtures/retro-host-ps2-resolution-status.json,
/// anyps5-retro-host fixtures/v1/messages/call-status-ps2-resolution.json).
void main() {
  Map<String, Object?> ps1Status() =>
      ((jsonDecode(File('test/fixtures/retro-host-swanstation-status.json').readAsStringSync()) as Map)['status']
              as Map)
          .cast<String, Object?>();

  Map<String, Object?> ps2Status() =>
      ((jsonDecode(File('test/fixtures/retro-host-ps2-resolution-status.json').readAsStringSync()) as Map)['reply']
              as Map)['result']
          as Map<String, Object?>;

  RetroStatus edited(
    Map<String, Object?> status,
    String key, {
    int? selected,
    String? activeValue,
    Map<String, Object?> fields = const {},
  }) {
    final options = (status['options']! as Map).cast<String, Object?>();
    final option = (options[key]! as Map).cast<String, Object?>();
    if (selected != null) option['selected'] = selected;
    if (activeValue != null) option['activeValue'] = activeValue;
    options[key] = option;
    return RetroStatus.parse({...status, 'options': options, ...fields}, ps2: status.containsKey('console'));
  }

  List<String> valuesOf(RetroResolutionChoice choice) => [for (final value in choice.values) value.value];

  group('PS1', () {
    test("SwanStation's eight scales: the menu offers Native to 4x, 6x and 8x", () {
      final status = RetroStatus.parse(ps1Status());
      expect(status.options[retroResolutionKeyPs1]!.values, ['1', '2', '3', '4', '5', '6', '7', '8']);
      final choice = RetroResolutionChoice.of(status, limitsPs2: false)!;
      expect(choice.key, retroResolutionKeyPs1);
      expect(valuesOf(choice), ['1', '2', '3', '4', '6', '8']);
      expect([for (final value in choice.values) value.scale], [1, 2, 3, 4, 6, 8]);
      expect(choice.values[2].label, '3x (for 720p)', reason: "the host's label, kept for the log");
      expect((choice.selected, choice.active.value, choice.note), (0, '1', RetroGraphicsNote.none));
    });

    test('only values the host lists are offered', () {
      final status = ps1Status();
      final options = (status['options']! as Map).cast<String, Object?>();
      options[retroResolutionKeyPs1] = {
        'title': 'Internal Resolution Scale',
        'values': ['1', '2', '4'],
        'labels': ['1x', '2x', '4x'],
        'selected': 1,
        'activeValue': '2',
        'restart': false,
      };
      final choice = RetroResolutionChoice.of(RetroStatus.parse({...status, 'options': options}), limitsPs2: false)!;
      expect(valuesOf(choice), ['1', '2', '4']);
      expect(choice.selected, 1);
    });

    test('a value chosen that the launcher does not offer is still shown, with its own label', () {
      final choice = RetroResolutionChoice.of(
        edited(ps1Status(), retroResolutionKeyPs1, selected: 6, activeValue: '7'),
        limitsPs2: false,
      )!;
      expect(valuesOf(choice), ['1', '2', '3', '4', '6', '7', '8']);
      expect(choice.selected, 5);
      expect(choice.values[5], const RetroResolutionValue(value: '7', scale: null, label: '7x'));
    });

    test('a change applies in a moment: chosen but not active, or graphicsPending', () {
      expect(
        RetroResolutionChoice.of(edited(ps1Status(), retroResolutionKeyPs1, selected: 3), limitsPs2: false)!.note,
        RetroGraphicsNote.applying,
      );
      expect(
        RetroResolutionChoice.of(
          edited(ps1Status(), retroResolutionKeyPs1, fields: {'graphicsPending': true}),
          limitsPs2: false,
        )!.note,
        RetroGraphicsNote.applying,
      );
    });

    test('a refused saved value: the note names the value the game draws at', () {
      final choice = RetroResolutionChoice.of(
        edited(
          ps1Status(),
          retroResolutionKeyPs1,
          selected: 3,
          activeValue: '4',
          fields: {'resolutionError': '16x would make the picture too large, so the game uses 4x.'},
        ),
        limitsPs2: false,
      )!;
      expect(choice.note, RetroGraphicsNote.refused);
      expect((choice.active.value, choice.active.scale), ('4', 4));
    });

    test('nothing to offer: no status, drawing without the GPU, or no such option', () {
      expect(RetroResolutionChoice.of(null, limitsPs2: true), isNull);
      expect(RetroResolutionChoice.of(RetroStatus.parse({...ps1Status(), 'hardware': false}), limitsPs2: true), isNull);
      final options = (ps1Status()['options']! as Map).cast<String, Object?>()..remove(retroResolutionKeyPs1);
      expect(
        RetroResolutionChoice.of(RetroStatus.parse({...ps1Status(), 'options': options}), limitsPs2: true),
        isNull,
      );
    });
  });

  group('PS2', () {
    test('the real LRPS2 status: 8x in stereo refused, 1x to 4x listed, 4x in use', () {
      final status = RetroStatus.parse(ps2Status(), ps2: true);
      expect(status.console, RetroConsole.ps2);
      final choice = RetroResolutionChoice.of(status, limitsPs2: true)!;
      expect(choice.key, retroResolutionKeyPs2);
      expect(valuesOf(choice), ['1x (Native)', '2x', '4x']);
      expect([for (final value in choice.values) value.scale], [1, 2, 4]);
      expect(choice.selected, 2);
      expect((choice.active.value, choice.active.scale), ('4x', 4));
      expect(choice.note, RetroGraphicsNote.refused);
    });

    test('a host without ps2ResolutionLimits is offered nothing', () {
      expect(RetroResolutionChoice.of(RetroStatus.parse(ps2Status(), ps2: true), limitsPs2: false), isNull);
    });

    test('a PS2 change takes effect at the next start', () {
      final started = edited(ps2Status(), retroResolutionKeyPs2, fields: {'resolutionError': ''});
      expect(RetroResolutionChoice.of(started, limitsPs2: true)!.note, RetroGraphicsNote.changesAtNextStart);
      final chosen = edited(ps2Status(), retroResolutionKeyPs2, selected: 1, fields: {'resolutionError': ''});
      final choice = RetroResolutionChoice.of(chosen, limitsPs2: true)!;
      expect((choice.selected, choice.active.value, choice.note), (1, '4x', RetroGraphicsNote.nextStart));
    });

    test('a PS1 option in a PS2 status is not the PS2 resolution', () {
      final status = ps2Status();
      final options = (status['options']! as Map).cast<String, Object?>()..remove(retroResolutionKeyPs2);
      options[retroResolutionKeyPs1] = {
        'title': 'Internal Resolution Scale',
        'values': ['1', '2'],
        'labels': ['1x', '2x'],
        'selected': 0,
        'activeValue': '1',
        'restart': false,
      };
      expect(
        RetroResolutionChoice.of(RetroStatus.parse({...status, 'options': options}, ps2: true), limitsPs2: true),
        isNull,
      );
    });
  });
}
