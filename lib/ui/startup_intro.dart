import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'components.dart' show LayoutScale;
import 'theme.dart';

/// The start animation, as on the console: a dark screen with a spotlight and four dots, the
/// tiles popping in one after the other, then the top bar and the selected game's details.
///
/// It plays once per run, the first time the home screen shows with nothing over it (not under
/// the launch profile picker, which is over it before the first frame). [enabled] is off until
/// `main` turns it on, so previews and tests (which build the home screen directly) never wait
/// for it. Reduced motion (the profile's setting and the system's) and a game starting or
/// running at that moment skip it for the run.
abstract final class StartupIntro {
  static bool enabled = false;
  static bool played = false;

  static const duration = Duration(milliseconds: 2600);

  /// The moment, as a fraction of [duration], each part starts and ends.
  static const curtainFade = (0.18, 0.55);
  static const topBar = (0.50, 0.75);
  static const hero = (0.62, 0.90);
  static const hints = (0.75, 0.95);

  /// A tile's own span: the tiles start 3% of the animation apart, from 30%.
  static (double, double) tile(int index) {
    final from = 0.30 + math.min(index, 9) * 0.03;
    return (from, from + 0.22);
  }

  /// The intro is still to be decided: on, and not played or skipped yet.
  static bool get pending => enabled && !played;
}

/// A part of the home screen coming in: it fades, slides and grows into place between [span]'s
/// two moments of [animation]. The same widgets are built before, during and after, so nothing
/// below it is rebuilt from scratch when the animation ends. The transitions animate on the
/// render objects with no rebuild per frame.
class IntroReveal extends StatelessWidget {
  const IntroReveal({
    super.key,
    required this.animation,
    required this.span,
    required this.child,
    this.slide = Offset.zero,
    this.scaleFrom = 1,
  });

  final Animation<double> animation;
  final (double, double) span;
  final Widget child;

  /// Where it starts, as a fraction of its own size.
  final Offset slide;
  final double scaleFrom;

  @override
  Widget build(BuildContext context) {
    final eased = animation.drive(CurveTween(curve: Interval(span.$1, span.$2, curve: Motion.settle)));
    var result = child;
    if (scaleFrom != 1) {
      result = ScaleTransition(scale: eased.drive(Tween(begin: scaleFrom, end: 1.0)), child: result);
    }
    if (slide != Offset.zero) {
      result = SlideTransition(position: eased.drive(Tween(begin: slide, end: Offset.zero)), child: result);
    }
    return FadeTransition(opacity: eased, child: result);
  }
}

/// Over the home screen at the start: the look's deep color with a spotlight from the top left
/// and four dots breathing, then fading away to show the background and the tiles.
class IntroCurtain extends StatelessWidget {
  const IntroCurtain({super.key, required this.animation, required this.deep});

  final Animation<double> animation;
  final Color deep;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final fade = Interval(StartupIntro.curtainFade.$1, StartupIntro.curtainFade.$2, curve: Curves.easeInOut);
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final v = animation.value;
        final gone = fade.transform(v);
        if (gone >= 1) return const SizedBox.shrink();
        return IgnorePointer(
          child: Opacity(
            opacity: 1 - gone,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(color: deep),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: Alignment(-0.55, -1.15),
                      radius: 1.25,
                      colors: [Color(0x26FFFFFF), Color(0x00FFFFFF)],
                    ),
                  ),
                ),
                Align(
                  alignment: const Alignment(0, -0.5),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var i = 0; i < 4; i++)
                        Container(
                          width: 8 * scale,
                          height: 8 * scale,
                          margin: EdgeInsets.symmetric(horizontal: 11 * scale),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white.withValues(alpha: 0.3 + 0.7 * (0.5 + 0.5 * math.sin(v * 22 - i * 1.1))),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
