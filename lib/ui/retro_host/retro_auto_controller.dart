import 'dart:async';

import '../../core/retro_host/retro_auto_resolution.dart';
import '../../core/retro_host/retro_graphics.dart';
import '../../core/retro_host/retro_host_protocol.dart';
import 'retro_game_menu.dart';

/// The Auto Optimizer of a PS1 game while it plays with its internal resolution on Auto: every
/// [RetroAutoRules.window] it hands the game's last status to a [RetroAutoResolution] and asks
/// the host for the scale that one chooses, as the menu's Internal resolution row would. What it
/// learns is kept in [memories] under the game's [titleId], and [saved] is called after each
/// change to it.
class RetroAutoController {
  RetroAutoController({
    required this.menu,
    required this.titleId,
    required this.memories,
    required this.need,
    required this.saved,
    this.log,
    this.every = RetroAutoRules.window,
    Stopwatch? clock,
  }) : _clock = clock ?? (Stopwatch()..start());

  final RetroGameMenu menu;

  /// The game's title ID, as its save states are kept under.
  final String titleId;

  /// What the optimizer learned of each game, by title ID: the launcher's preferences.
  final Map<String, RetroAutoMemory> memories;

  /// The largest scale worth choosing for the view the game is shown in now
  /// ([retroAutoDisplayNeed]), asked at every judgement, as the window may be resized or moved.
  final int Function() need;

  /// Called after [memories] changed, so they are saved.
  final void Function() saved;

  /// Where each change and its reason are written, for the launcher's log.
  final void Function(String line)? log;

  /// How often the game's last status is judged.
  final Duration every;

  final Stopwatch _clock;
  Timer? _timer;
  RetroAutoResolution? _auto;
  Future<void>? _change;
  bool _stopped = false;

  /// The optimizer judging the game now, once a status allowed one.
  RetroAutoResolution? get optimizer => _auto;

  /// Starts judging, from now.
  void start() {
    if (_stopped) return;
    _timer ??= Timer.periodic(every, (_) => unawaited(tick()));
  }

  /// Judges the game's last status once: a change the optimizer chooses is asked of the host, and
  /// is the scale the game draws at once the host took it. While the menu is open the game is
  /// paused, and the readings before it do not count with those after it.
  Future<void> tick() async {
    if (_stopped || _change != null || !menu.game.reportsPerformance) return;
    if (menu.isOpen) {
      _auto?.interrupted();
      return;
    }
    final status = menu.game.status;
    final choice = menu.resolution;
    if (status == null || choice == null) return;
    final scales = {for (final value in choice.values) ?value.scale: value.value};
    final current = choice.active.scale;
    if (current == null) return;
    final auto = _optimizerFor(status, scales.keys.toList(), current)..need = need();
    final change = auto.observe(_clock.elapsed, status);
    final value = scales[change];
    if (change == null || value == null) return;
    final asked = _apply(auto, status, current, change, value);
    _change = asked;
    try {
      await asked;
    } finally {
      _change = null;
    }
  }

  Future<void> _apply(RetroAutoResolution auto, RetroStatus status, int current, int change, String value) async {
    if (!await menu.chooseResolution(value) || _stopped) return;
    final reading = status.performance;
    log?.call(
      'auto resolution: ${current}x to ${change}x for $titleId '
      '(speed ${reading?.speed}, work ${reading?.work})',
    );
    auto.changed(_clock.elapsed, change);
    saved();
  }

  /// The optimizer for what the game is measured with now: the one in use, or a new one when the
  /// game's GPU, host or other graphics settings are not those its memory was measured with, so
  /// what was learned with others is not used. The first judges from the game's start; one that
  /// replaces it settles from now, as after a change.
  RetroAutoResolution _optimizerFor(RetroStatus status, List<int> scales, int current) {
    final gpu = status.gpu?.renderer ?? '';
    final host = menu.game.hostVersion;
    final config = retroAutoConfig(status, retroGraphicsKeys);
    final auto = _auto;
    if (auto != null && auto.memory.gpu == gpu && auto.memory.host == host && auto.memory.config == config) {
      return auto;
    }
    final kept = memories[titleId];
    final memory = RetroAutoMemory(
      gpu: gpu,
      host: host,
      config: config,
      scale: current,
      slow: kept != null && kept.measuredWith(gpu: gpu, host: host, config: config) ? {...kept.slow} : null,
    );
    memories[titleId] = memory;
    saved();
    final fresh = RetroAutoResolution(scales: scales, need: need(), memory: memory, scale: current);
    if (auto != null) fresh.changed(_clock.elapsed, current);
    return _auto = fresh;
  }

  /// Stops judging, and waits for a change already asked of the host, so a value the player
  /// chooses next is chosen over the game's real scale and nothing the optimizer asked comes
  /// after it.
  Future<void> stop() async {
    dispose();
    await _change;
  }

  /// Stops judging; a change already asked is not counted when its reply comes.
  void dispose() {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
  }
}
