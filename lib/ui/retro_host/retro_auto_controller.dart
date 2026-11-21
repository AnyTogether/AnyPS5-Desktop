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

  /// The largest scale worth choosing for the display the game is shown on
  /// ([retroAutoDisplayNeed]).
  final int need;

  /// Called after [memories] changed, so they are saved.
  final void Function() saved;

  /// Where each change and its reason are written, for the launcher's log.
  final void Function(String line)? log;

  /// How often the game's last status is judged.
  final Duration every;

  final Stopwatch _clock;
  Timer? _timer;
  RetroAutoResolution? _auto;
  bool _changing = false;

  /// The optimizer judging the game now, once a status allowed one.
  RetroAutoResolution? get optimizer => _auto;

  /// Starts judging, from now.
  void start() => _timer ??= Timer.periodic(every, (_) => unawaited(tick()));

  /// Judges the game's last status once: a change the optimizer chooses is asked of the host, and
  /// is the scale the game draws at once the host took it.
  Future<void> tick() async {
    final status = menu.game.status;
    final choice = menu.resolution;
    if (_changing || status == null || choice == null || menu.isOpen || !menu.game.reportsPerformance) return;
    final scales = {for (final value in choice.values) ?value.scale: value.value};
    final current = choice.active.scale;
    if (current == null) return;
    final auto = _optimizerFor(status, scales.keys.toList(), current);
    final change = auto.observe(_clock.elapsed, status);
    if (change == null) return;
    final value = scales[change];
    if (value == null) return;
    _changing = true;
    try {
      if (!await menu.chooseResolution(value)) return;
      final reading = status.performance;
      log?.call(
        'auto resolution: ${current}x to ${change}x for $titleId '
        '(speed ${reading?.speed}, work ${reading?.work})',
      );
      auto.changed(_clock.elapsed, change);
      saved();
    } finally {
      _changing = false;
    }
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
    final fresh = RetroAutoResolution(scales: scales, need: need, memory: memory, scale: current);
    if (auto != null) fresh.changed(_clock.elapsed, current);
    return _auto = fresh;
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
