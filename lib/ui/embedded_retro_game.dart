import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../core/controllers/pad_info.dart';
import '../core/game_library.dart';
import '../core/game_process.dart';
import '../core/managed_retro.dart';
import '../core/gamepad/pad_navigation.dart';

import 'strings.dart';

typedef EmbeddedOption = ({List<String> values, List<String> labels, String title, bool restart, int selected});

typedef EmbeddedDiscs = ({List<String> labels, int? inserted, bool busy, bool failed});

enum _DiscRequest { sending, queued }

class EmbeddedRetroGame extends RunningGame {
  EmbeddedRetroGame._(this.textureId, this._finished, this._onResolutionSelected, this._onGraphicsSelected)
    : super.embedded(_finished.future, DateTime.now());

  static const _channel = MethodChannel('anyps5/retro_core');
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
  bool presented = false;
  EmbeddedDiscs? _discs;
  EmbeddedDiscs? get discs => _discs;
  _DiscRequest? _discRequest;
  String? _lastPlayedDisc;
  bool get changingDisc => _discRequest != null || _discs?.busy == true;
  double aspect = 4 / 3;
  final options = <String, EmbeddedOption>{};
  final _keys = <PadButton>{};
  List<int> _lastInput = const [];

  Future<bool> get ready => _ready.future;
  static Future<EmbeddedRetroGame> start(
    ManagedRetro managed,
    RetroDisc disc, {
    required String? internalResolution,
    required void Function(String) onResolutionSelected,
    required Map<String, String> graphics,
    required void Function(String, String) onGraphicsSelected,
    required PadState Function() readPad,
    required void Function() changed,
    ({int index, String path})? initialDisc,
    void Function(String)? onDiscPlayed,
  }) async {
    final core = managed.libraryPath(disc.platform);
    if (!File(core).existsSync()) throw FileSystemException(T.text('retroEmbeddedCoreMissing'), core);
    final saveRoot = Directory(p.join(managed.root, 'saves', disc.platform.name))..createSync(recursive: true);
    final id = await _channel.invokeMethod<int>('start', {
      'core': core,
      'disc': disc.path,
      if (initialDisc != null) 'initialDiscIndex': initialDisc.index,
      if (initialDisc != null) 'initialDiscPath': initialDisc.path,
      'system': managed.systemPath,
      'saves': saveRoot.path,
      'internalResolution': ?internalResolution,
      if (graphics.isNotEmpty) 'graphics': graphics,
    });
    if (id == null || id < 0) throw StateError(T.text('retroEmbeddedSurfaceFailed'));
    final session = EmbeddedRetroGame._(id, Completer<int>(), onResolutionSelected, onGraphicsSelected);
    session._watch = Timer.periodic(
      const Duration(milliseconds: 125),
      (_) => unawaited(session._poll(changed, onDiscPlayed)),
    );
    session._input = Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (session._acceptsInput && !session._closing) session._sendInput(readPad());
    });
    return session;
  }

  Future<void> _poll(void Function() changed, void Function(String)? onDiscPlayed) async {
    if (_reading) return;
    _reading = true;
    // A poll already in flight may describe the tray before the request.
    final acknowledgeDiscRequest = _discRequest == _DiscRequest.queued;
    try {
      final status = await _channel.invokeMapMethod<String, Object?>('status');
      final discStatus = status?['discs'];
      final played = discStatus is Map ? discStatus['playedDiscPath'] : null;
      if ((presented || status?['presented'] == true) &&
          played is String &&
          played.isNotEmpty &&
          played != _lastPlayedDisc) {
        _lastPlayedDisc = played;
        onDiscPlayed?.call(played);
      }
      if (status == null || status['ended'] == true) {
        final nativeError = status?['error'] as String?;
        if (nativeError != null && nativeError.isNotEmpty) error = nativeError;
        await _channel.invokeMethod<void>('release');
        _watch.cancel();
        _input.cancel();
        if (!_ready.isCompleted) _ready.complete(false);
        _finished.complete(error.isEmpty ? 0 : 1);
        return;
      }
      final updatedAspect = status['aspect'];
      if (acknowledgeDiscRequest) _discRequest = null;
      var updated = acknowledgeDiscRequest;
      if (!presented && status['presented'] == true) {
        presented = true;
        _ready.complete(true);
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
      final newDiscs = _readDiscs(discStatus);
      if (!listEquals(_discs?.labels, newDiscs?.labels) ||
          _discs?.inserted != newDiscs?.inserted ||
          _discs?.busy != newDiscs?.busy ||
          _discs?.failed != newDiscs?.failed) {
        _discs = newDiscs;
        updated = true;
      }
      final values = status['options'];
      if (values is Map) {
        final removed = options.keys.where((key) => !values.containsKey(key)).toList();
        for (final key in removed) {
          options.remove(key);
        }
        updated = updated || removed.isNotEmpty;
        for (final entry in values.entries) {
          final option = entry.value;
          if (entry.key is String && option is Map && option['values'] is List && option['selected'] is int) {
            final key = entry.key as String;
            final selected = option['selected'] as int;
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

  static EmbeddedDiscs? _readDiscs(Object? value) {
    if (value is! Map || value['labels'] is! List) return null;
    final labels = value['labels'] as List;
    if (labels.length < 2 || labels.any((label) => label is! String)) return null;
    final index = value['inserted'];
    return (
      labels: List<String>.unmodifiable(labels),
      inserted: index is int && index >= 0 && index < labels.length ? index : null,
      busy: value['busy'] == true,
      failed: value['failed'] == true,
    );
  }

  Future<bool> changeDisc(int index) async {
    final current = discs;
    if (_closing ||
        current == null ||
        changingDisc ||
        index == current.inserted ||
        index < 0 ||
        index >= current.labels.length) {
      return false;
    }
    _discRequest = _DiscRequest.sending;
    var accepted = false;
    try {
      accepted = await _channel.invokeMethod<bool>('changeDisc', index) == true;
      return accepted;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    } finally {
      _discRequest = accepted ? _DiscRequest.queued : null;
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
    }
  }

  Future<void> setOption(String key, String value) async {
    if (_closing) return;
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
