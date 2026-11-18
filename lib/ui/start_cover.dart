import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../core/desktop/desktop.dart';
import '../core/game_library.dart';
import 'app_model.dart';
import 'components.dart';
import 'strings.dart';
import 'theme.dart';

/// The cover of a game starting, as the console shows it: the game's artwork over the whole
/// window, its name and the accent's moving line. It stays from the game starting until its
/// window has settled (see [AppModel.coverGame]); on Windows its picture is then what fades away
/// over the game ([DesktopWindows.fadeCover]), elsewhere the cover itself fades.
class StartCoverLayer extends StatelessWidget {
  const StartCoverLayer({super.key, required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final game = model.starting ?? model.coverGame;
    final reduced = MediaQuery.disableAnimationsOf(context) || Motion.reduced;
    // The picture over the game already took the cover's place: it goes at once then.
    final leaves = model.coverHandedOver ? Duration.zero : (reduced ? Motion.fade : const Duration(milliseconds: 450));
    return Positioned.fill(
      // The snapshot the fade over the game starts from is this boundary's picture.
      child: RepaintBoundary(
        key: model.coverBoundary,
        child: AnimatedSwitcher(
          duration: leaves,
          switchOutCurve: Curves.easeIn,
          layoutBuilder: uniqueSwitcherLayout(),
          child: game == null
              ? const SizedBox.shrink(key: ValueKey('no cover'))
              : _CoverBody(key: ValueKey(game.id), game: game, accent: model.accentChoice.color),
        ),
      ),
    );
  }
}

class _CoverBody extends StatelessWidget {
  const _CoverBody({super.key, required this.game, required this.accent});

  final Game game;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final reduced = MediaQuery.disableAnimationsOf(context) || Motion.reduced;
    final background = game.background ?? game.icon;
    return SizedBox.expand(
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Under the entrance: what a snapshot of the cover shows is never see-through.
          const ColoredBox(color: Colors.black),
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: reduced ? Motion.fade : const Duration(milliseconds: 450),
            curve: Motion.settle,
            builder: (context, t, child) => Opacity(
              opacity: t,
              // A slight zoom out as it comes in; reduced motion only fades.
              child: Transform.scale(scale: reduced ? 1 : 1.04 - 0.04 * t, child: child),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (background != null)
                  game.background != null
                      ? ArtworkImage(path: background, cacheWidth: 1920)
                      // No wide artwork: the icon, enlarged and blurred.
                      : ImageFiltered(
                          imageFilter: ui.ImageFilter.blur(sigmaX: 36, sigmaY: 36, tileMode: TileMode.clamp),
                          child: Transform.scale(scale: 1.6, child: ArtworkImage(path: background, cacheWidth: 400)),
                        ),
                // Darker towards the bottom, where the name is.
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.30),
                        Colors.black.withValues(alpha: 0.35),
                        Colors.black.withValues(alpha: 0.85),
                      ],
                      stops: const [0, 0.5, 1],
                    ),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.fromLTRB(72 * scale, 48 * scale, 72 * scale, 64 * scale),
                  child: Align(
                    alignment: AlignmentDirectional.bottomStart,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        if (game.icon != null) ...[
                          ClipRRect(
                            borderRadius: BorderRadius.circular(18 * scale),
                            child: SizedBox.square(
                              dimension: 120 * scale,
                              child: ArtworkImage(path: game.icon!, cacheWidth: 400),
                            ),
                          ),
                          SizedBox(width: 28 * scale),
                        ],
                        Flexible(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                game.name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: AppText.display(44 * scale, weight: FontWeight.w300),
                              ),
                              SizedBox(height: 10 * scale),
                              ConstrainedBox(
                                constraints: BoxConstraints(maxWidth: 560 * scale),
                                child: Text(
                                  T.text('startingText'),
                                  style: AppText.display(
                                    16 * scale,
                                    color: Colors.white.withValues(alpha: 0.7),
                                    height: 1.4,
                                  ),
                                ),
                              ),
                              SizedBox(height: 22 * scale),
                              SizedBox(
                                width: 320 * scale,
                                child: IndeterminateLine(color: accent),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
