import 'dart:convert';
import 'dart:io';

/// What a host built from the save states branch (B-Howell/anyps5-retro-host-upstream
/// `save-states` 3576e38, capability `saveStates`) sent, recorded in
/// test/fixtures/retro_host_save_states_recording.json: every message each way as its exact text,
/// by scenario, frames left out, and the files its states folder held after each scenario. It ran
/// on Windows (MSVC Release) with the host repository's fake core, whose state file is small; the
/// launcher's side was a script that sent what this launcher sends, with the volume at 0 and
/// muted. `other-core` ran a second host whose fake core gave another build identity
/// (`FAKE_CORE_VERSION=2`). No BIOS, disc or state of a real game was used. Paths were made generic
/// after recording (`C:\retro-host-test`, `C:\build`).
class SaveStatesHostRecording {
  SaveStatesHostRecording._(this._scenarios, this._files);

  /// The recording in this repository.
  factory SaveStatesHostRecording.load() {
    final file = jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;
    final scenarios = file['scenarios']! as Map<String, Object?>;
    final files = file['files']! as Map<String, Object?>;
    return SaveStatesHostRecording._(
      {
        for (final MapEntry(:key, :value) in scenarios.entries)
          key: [
            for (final message in (value! as List<Object?>).cast<Map<String, Object?>>())
              (
                from: message['from']! as String,
                message: jsonDecode(message['raw']! as String) as Map<String, Object?>,
              ),
          ],
      },
      {for (final MapEntry(:key, :value) in files.entries) key: (value! as List<Object?>).cast<String>()},
    );
  }

  static const path = 'test/fixtures/retro_host_save_states_recording.json';

  final Map<String, List<({String from, Map<String, Object?> message})>> _scenarios;
  final Map<String, List<String>> _files;

  /// Every message of [scenario], in the order they went.
  List<({String from, Map<String, Object?> message})> messages(String scenario) =>
      _scenarios[scenario] ?? (throw ArgumentError.value(scenario, 'scenario', 'is not recorded'));

  /// The names in the states folder once [scenario] was over.
  List<String> files(String scenario) =>
      _files[scenario] ?? (throw ArgumentError.value(scenario, 'scenario', 'has no folder recorded'));

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

  /// Every `saveState` and `loadState` of every scenario with its reply: scenario by scenario, its
  /// saves and then its loads.
  List<({String scenario, Map<String, Object?> call, Map<String, Object?> reply})> stateCalls() => [
    for (final scenario in _scenarios.keys)
      for (final method in const ['saveState', 'loadState'])
        for (final exchange in calls(scenario, method))
          (scenario: scenario, call: exchange.call, reply: exchange.reply),
  ];
}
