import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/retro_host/retro_host_protocol.dart';

/// What a host built from AnyTogether/anyps5-retro-host main 1b57932 (#18, PS2 on LRPS2) sent for
/// PS2 games, recorded in test/fixtures/retro_host_ps2_recording.json: every message each way as
/// its exact text, by scenario. `lrps2-*` ran the real LRPS2 core (LRPS2_COMMIT c0d39a58e with the
/// host's patch) with no BIOS: no `pcsx2` folder, then a 4 MiB file of zeros in `pcsx2/bios`.
/// `fake-*` ran the host's fake core in its fake-ps2 mode. No BIOS of any kind was used. Paths
/// were made generic after recording (`/tmp/retro-host-test`, `/build/...`).
class Ps2HostRecording {
  Ps2HostRecording._(this._scenarios);

  /// The recording in this repository.
  factory Ps2HostRecording.load() {
    final file = jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;
    return Ps2HostRecording._({
      for (final MapEntry(:key, :value) in file.entries)
        key: [
          for (final message in (value! as List<Object?>).cast<Map<String, Object?>>())
            (from: message['from']! as String, message: jsonDecode(message['raw']! as String) as Map<String, Object?>),
        ],
    });
  }

  static const path = 'test/fixtures/retro_host_ps2_recording.json';

  final Map<String, List<({String from, Map<String, Object?> message})>> _scenarios;

  /// Every message of [scenario], in the order they went.
  List<({String from, Map<String, Object?> message})> messages(String scenario) =>
      _scenarios[scenario] ?? (throw ArgumentError.value(scenario, 'scenario', 'is not recorded'));

  /// The host's `welcome` in [scenario].
  Map<String, Object?> welcome(String scenario) =>
      messages(scenario).firstWhere((m) => m.from == 'host' && m.message['type'] == 'welcome').message;

  /// Each `call` of [method] the launcher sent in [scenario], with the host's reply to it.
  List<({Map<String, Object?> call, Map<String, Object?> reply})> calls(String scenario, String method) {
    final all = messages(scenario);
    return [
      for (final call in all)
        if (call.from == 'launcher' && call.message['type'] == 'call' && call.message['method'] == method)
          (
            call: call.message,
            reply: all
                .firstWhere(
                  (m) => m.from == 'host' && m.message['type'] == 'reply' && m.message['id'] == call.message['id'],
                )
                .message,
          ),
    ];
  }

  /// The results of the `status` calls of [scenario] that had a game, in order, as the host sent
  /// them.
  List<Map<String, Object?>> statusResults(String scenario) => [
    for (final exchange in calls(scenario, 'status'))
      if (exchange.reply['result'] case final Map<String, Object?> result) result,
  ];

  /// The last `status` of [scenario] that had a game, read as a host listing `ps2` ([ps2]) is read.
  RetroStatus lastStatus(String scenario, {bool ps2 = true}) =>
      RetroStatus.parse(statusResults(scenario).last, ps2: ps2);

  /// The first `status` of [scenario] whose game was [ready], read as a host listing `ps2` is read.
  RetroStatus readyStatus(String scenario) =>
      RetroStatus.parse(statusResults(scenario).firstWhere((result) => result['ready'] == true), ps2: true);
}
