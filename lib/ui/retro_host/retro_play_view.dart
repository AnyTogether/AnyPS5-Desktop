import 'package:flutter/material.dart';

import '../app_model.dart';
import '../components.dart';
import '../strings.dart';
import '../theme.dart';
import 'retro_host_game_view.dart';

/// A PS1 game playing in the launcher's window through the emulator host: its picture over the
/// whole window, the loading screen while it starts, and its error screen when it stopped on one.
class RetroPlayView extends StatelessWidget {
  const RetroPlayView({super.key, required this.model, required this.play});

  final AppModel model;
  final RetroPlay play;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: play.host,
      builder: (context, _) {
        final host = play.host;
        final status = host.status;
        final problem = play.problem;
        return Stack(
          fit: StackFit.expand,
          children: [
            RetroHostGameView(game: host),
            if (problem != null)
              RetroGameNotice(
                key: const ValueKey('retro-error'),
                name: T.format('retroHostStopped', [play.game.name]),
                icon: play.game.icon,
                text: T.text(problem),
                accent: model.accentChoice.color,
                action: T.text('retroHostBack'),
              )
            else if (play.loading && !play.closing)
              RetroGameNotice(
                key: const ValueKey('retro-loading'),
                name: play.game.name,
                icon: play.game.icon,
                text: status?.progressLabel ?? T.text('retroHostLoading'),
                accent: model.accentChoice.color,
                progress: status?.progressPercent == null ? null : status!.progressPercent! / 100,
                working: true,
              ),
          ],
        );
      },
    );
  }
}

/// A game's name and icon over a dimmed screen with a line of words: what it is loading, with a
/// progress line ([working]: an endless one while [progress] is not known), or why it stopped,
/// with the key that goes on ([action]).
class RetroGameNotice extends StatelessWidget {
  const RetroGameNotice({
    super.key,
    required this.name,
    required this.text,
    required this.accent,
    this.icon,
    this.progress,
    this.working = false,
    this.action,
  });

  final String name;
  final String? icon;
  final String text;
  final Color accent;

  /// How far it is, 0 to 1, when known.
  final double? progress;

  /// Something is going on: a progress line shows.
  final bool working;

  /// The words of the hint that goes on (Enter, Cross).
  final String? action;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final shown = progress;
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.6),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(24 * scale),
                child: SizedBox.square(
                  dimension: 160 * scale,
                  child: ArtworkImage(path: icon!, cacheWidth: 400),
                ),
              ),
            if (icon != null) SizedBox(height: 28 * scale),
            Text(
              name,
              textAlign: TextAlign.center,
              style: AppText.display(36 * scale, weight: FontWeight.w300),
            ),
            SizedBox(height: 12 * scale),
            SizedBox(
              width: 560 * scale,
              child: Text(
                text,
                textAlign: TextAlign.center,
                style: AppText.display(16 * scale, color: Colors.white.withValues(alpha: 0.65), height: 1.4),
              ),
            ),
            if (working) ...[
              SizedBox(height: 24 * scale),
              SizedBox(
                width: 260 * scale,
                child: shown == null ? IndeterminateLine(color: accent) : ProgressLine(fraction: shown, color: accent),
              ),
            ],
            if (action != null) ...[
              SizedBox(height: 28 * scale),
              Hint(keys: 'Enter', glyph: PadGlyph.cross, label: action!, action: HintAction.select),
            ],
          ],
        ),
      ),
    );
  }
}
