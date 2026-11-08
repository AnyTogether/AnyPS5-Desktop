import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../core/controllers/pad_info.dart';
import '../core/game_library.dart';
import '../core/game_process.dart';
import '../core/managed_retro.dart';
import '../core/gamepad/pad_navigation.dart';

import 'retro_game_tuning.dart';

export 'retro_game_tuning.dart' show EmbeddedOption, RetroTuningPersist;

class EmbeddedRetroGame extends RunningGame {
  EmbeddedRetroGame._(this.textureId, this._finished, this._onResolutionSelected, this._onGraphicsSelected)
    : super.embedded(_finished.future, DateTime.now());

  static const _channel = MethodChannel('anyps5/retro_core');
  static const ps3Resolution = 'rpcs3_resolution_scale';
  final int textureId;
  final Completer<int> _finished;
  final void Function(String) _onResolutionSelected;
  final void Function(String, String) _onGraphicsSelected;
  final _ready = Completer<bool>();
  late final Timer _watch;
  late final Timer _input;
  bool _reading = false;
  bool _playing = true;
  bool _acceptsInput = true;
  bool _closing = false;
  bool _awaitNeutral = true;
  String error = '';
  String resolutionError = '';
  bool hardwareRendering = false;
  bool presented = false;
  ({String label, int? percent})? progress;
  double aspect = 4 / 3;
  int filter = 0;
  int framing = 0;
  final options = <String, EmbeddedOption>{};
  final activeOptions = <String, String>{};
  late final RetroGameTuning tuning;
  final _keys = <PadButton>{};
  List<int> _lastInput = const [];

  Future<bool> get ready => _ready.future;
  double? get displayAspect => switch (framing) {
    0 => aspect,
    1 => 4 / 3,
    2 => 16 / 9,
    _ => null,
  };

  static Future<EmbeddedRetroGame> start(
    String folder,
    RetroDisc disc, {
    required String? internalResolution,
    required void Function(String) onResolutionSelected,
    required Map<String, String> graphics,
    required void Function(String, String) onGraphicsSelected,
    RetroTuningPersist? onTuningApplied,
    required PadState Function() readPad,
    required void Function() changed,
  }) async {
    final core = p.join(folder, ManagedRetro.libraryName(disc.platform));
    if (!File(core).existsSync()) throw FileSystemException('The embedded emulator core is missing', core);
    final saveRoot = Directory(p.join(folder, 'saves', disc.platform.name))..createSync(recursive: true);
    final id = await _channel.invokeMethod<int>('start', {
      'core': core,
      'disc': disc.path,
      'system': p.join(folder, 'system'),
      'saves': saveRoot.path,
      'internalResolution': ?internalResolution,
      if (graphics.isNotEmpty) 'graphics': graphics,
    });
    if (id == null || id < 0) throw StateError('The game surface could not start.');
    final session = EmbeddedRetroGame._(id, Completer<int>(), onResolutionSelected, onGraphicsSelected);
    session.tuning = RetroGameTuning(
      platform: disc.platform,
      options: session.options,
      ready: () => session.presented && session.hardwareRendering && !session._closing,
      writeOptions: (expected, values) async {
        if (session._closing) return false;
        final accepted = await _channel.invokeMethod<bool>('tuningOptions', {'expected': expected, 'values': values});
        return accepted == true &&
            (!values.keys.any(_usesGraphicsCheckpoint) || await session._waitForGraphics(values));
      },
      persist:
          onTuningApplied ??
          (previous, values, {required undo}) {
            for (final entry in values.entries) {
              if (entry.key == 'swanstation_GPU_ResolutionScale' || entry.key == 'pcsx2_upscale_multiplier') {
                onResolutionSelected(entry.value);
              } else {
                onGraphicsSelected(entry.key, entry.value);
              }
            }
          },
      changed: changed,
    );
    session._watch = Timer.periodic(const Duration(milliseconds: 125), (_) => unawaited(session._poll(changed)));
    session._input = Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (session._acceptsInput && !session._closing) session._sendInput(readPad());
    });
    return session;
  }

  Future<void> _poll(void Function() changed) async {
    if (_reading) return;
    _reading = true;
    try {
      final status = await _channel.invokeMapMethod<String, Object?>('status');
      if (status == null || status['ended'] == true) {
        final nativeError = status?['error'] as String?;
        if (nativeError != null && nativeError.isNotEmpty) error = nativeError;
        await _channel.invokeMethod<void>('release');
        _watch.cancel();
        _input.cancel();
        tuning.endSession();
        if (!_ready.isCompleted) _ready.complete(false);
        _finished.complete(error.isEmpty ? 0 : 1);
        return;
      }
      final updatedAspect = status['aspect'];
      var updated = false;
      if (!presented && status['presented'] == true) {
        presented = true;
        _ready.complete(true);
        updated = true;
      }
      final label = status['progressLabel'];
      final currentProgress = label is String && label.isNotEmpty
          ? (label: label, percent: status['progressPercent'] as int?)
          : null;
      if (progress != currentProgress) {
        progress = currentProgress;
        updated = true;
      }
      final updatedHardware = status['hardware'] == true;
      if (hardwareRendering != updatedHardware) {
        hardwareRendering = updatedHardware;
        updated = true;
      }
      final updatedResolutionError = status['resolutionError'] as String? ?? '';
      if (resolutionError != updatedResolutionError) {
        resolutionError = updatedResolutionError;
        updated = true;
      }
      if (updatedAspect is double && updatedAspect != aspect) {
        aspect = updatedAspect;
        updated = true;
      }
      final values = status['options'];
      if (values is Map) {
        final removed = options.keys.where((key) => !values.containsKey(key)).toList();
        for (final key in removed) {
          options.remove(key);
          activeOptions.remove(key);
        }
        updated = updated || removed.isNotEmpty;
        for (final entry in values.entries) {
          final option = entry.value;
          if (entry.key is String && option is Map && option['values'] is List && option['selected'] is int) {
            final key = entry.key as String;
            final selected = option['selected'] as int;
            final active = option['activeValue'];
            if (active is String && activeOptions[key] != active) {
              activeOptions[key] = active;
              updated = true;
            }
            if (options[key]?.selected != selected) {
              options[key] = (
                values: List<String>.from(option['values'] as List),
                labels: List<String>.from(option['labels'] as List? ?? const []),
                title: option['title'] as String? ?? '',
                restart: option['restart'] == true,
                selected: selected,
              );
              updated = true;
            }
          }
        }
      }
      final telemetry = status['tuningTelemetry'];
      if (telemetry is Map) {
        await tuning.observe(telemetry, playing: _playing && _acceptsInput && progress == null && presented);
      }
      if (updated) changed();
    } on PlatformException catch (failure) {
      error = failure.message ?? failure.code;
      try {
        await close();
      } on PlatformException {
        // Keep polling until the native session can be drained.
      }
    } finally {
      _reading = false;
    }
  }

  void playback({required bool playing, required bool focused}) {
    if (_closing) return;
    if (_playing != playing) {
      _playing = playing;
      unawaited(_channel.invokeMethod<void>('pause', !playing));
    }
    final acceptsInput = playing && focused;
    if (_acceptsInput == acceptsInput) return;
    _acceptsInput = acceptsInput;
    _keys.clear();
    _lastInput = const [];
    _awaitNeutral = true;
    if (!acceptsInput) {
      unawaited(_channel.invokeMethod<void>('input', const [0, 0, 0, 0, 0]));
      unawaited(tuning.interrupt());
    }
  }

  Future<void> setOption(String key, String value) async {
    if (_closing || tuning.updating) return;
    if (tuning.canCancel) await tuning.cancel();
    if (_closing || tuning.updating) return;
    final accepted = await _channel.invokeMethod<bool>('option', {'key': key, 'value': value});
    if (accepted == true && _usesGraphicsCheckpoint(key) && !await _waitForGraphics({key: value})) {
      return;
    }
    if (accepted == true && (key == 'swanstation_GPU_ResolutionScale' || key == 'pcsx2_upscale_multiplier')) {
      _onResolutionSelected(value);
      return;
    }
    if (accepted == true &&
        (options[key]?.restart == true ||
            const {
              ps3Resolution,
              'rpcs3_anisotropic_filter',
              'swanstation_GPU_TextureFilter',
              'pcsx2_anisotropic_filtering',
              'pcsx2_trilinear_filtering',
            }.contains(key))) {
      _onGraphicsSelected(key, value);
    }
  }

  static bool _usesGraphicsCheckpoint(String key) => const {
    'swanstation_GPU_ResolutionScale',
    'swanstation_GPU_TextureFilter',
    'pcsx2_upscale_multiplier',
  }.contains(key);

  Future<bool> _waitForGraphics(Map<String, String> requested) async {
    final deadline = Stopwatch()..start();
    while (!_closing && deadline.elapsed < const Duration(seconds: 20)) {
      final status = await _channel.invokeMapMethod<String, Object?>('status');
      if (status == null || status['ended'] == true || _closing) return false;
      if (status['graphicsPending'] != true) {
        final active = status['options'] as Map?;
        return requested.entries.every((entry) => (active?[entry.key] as Map?)?['activeValue'] == entry.value);
      }
      await Future<void>.delayed(const Duration(milliseconds: 75));
    }
    return false;
  }

  void key(PadButton button, bool down) {
    if (!_acceptsInput) return;
    if (down) {
      _keys.add(button);
    } else {
      _keys.remove(button);
    }
  }

  void _sendInput(PadState pad) {
    final held = pad.pressed.where((button) => _buttonCodes.containsKey(button)).toSet();
    if (_awaitNeutral) {
      if (held.isNotEmpty || [pad.leftX, pad.leftY, pad.rightX, pad.rightY].any((axis) => axis.abs() > 0.2)) return;
      _awaitNeutral = false;
    }
    var mask = 0;
    for (final button in {...held, ..._keys}) {
      final bit = _buttonCodes[button];
      if (bit != null) mask |= 1 << bit;
    }
    final input = [
      mask,
      for (final axis in [pad.leftX, pad.leftY, pad.rightX, pad.rightY]) (axis.clamp(-1, 1) * 32767).round(),
    ];
    if (_lastInput.length == input.length &&
        List.generate(input.length, (i) => _lastInput[i] == input[i]).every((e) => e)) {
      return;
    }
    _lastInput = input;
    unawaited(_channel.invokeMethod<void>('input', input));
  }

  static const _buttonCodes = {
    PadButton.south: 0,
    PadButton.west: 1,
    PadButton.select: 2,
    PadButton.start: 3,
    PadButton.dpadUp: 4,
    PadButton.dpadDown: 5,
    PadButton.dpadLeft: 6,
    PadButton.dpadRight: 7,
    PadButton.east: 8,
    PadButton.north: 9,
    PadButton.l1: 10,
    PadButton.r1: 11,
    PadButton.l2: 12,
    PadButton.r2: 13,
    PadButton.l3: 14,
    PadButton.r3: 15,
  };

  @override
  Future<void> close() async {
    if (_closing || _finished.isCompleted) return;
    _closing = true;
    try {
      await _channel.invokeMethod<void>('stop');
    } on PlatformException {
      _closing = false;
      rethrow;
    }
  }

  @override
  bool stop() {
    unawaited(close());
    return true;
  }

  @override
  bool kill() => stop();
}
