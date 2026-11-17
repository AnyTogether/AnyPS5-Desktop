import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'glass.dart';
import 'strings.dart';
import 'theme.dart';

/// The interface is laid out for a 1600x900 window and scaled with it.
class LayoutScale extends InheritedWidget {
  const LayoutScale({super.key, required this.scale, required super.child});

  final double scale;

  static double of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<LayoutScale>()?.scale ?? 1;

  @override
  bool updateShouldNotify(LayoutScale oldWidget) => oldWidget.scale != scale;
}

/// AnimatedSwitcher's layout without two children of one key: a child switched back to while an
/// earlier copy of it still fades out (a game passed and come back to within the fade, a layer
/// closed and opened again, a toast said twice) takes that copy's place. AnimatedSwitcher keys
/// each child's transition by the child's own key, so the copies collided: an error on every
/// such frame, and elements tangled in a release build, when input came fast.
AnimatedSwitcherLayoutBuilder uniqueSwitcherLayout({AlignmentGeometry alignment = Alignment.center}) =>
    (current, previous) {
      final seen = <Key?>{?current?.key};
      final kept = [
        for (final child in previous.reversed)
          if (seen.add(child.key)) child,
      ];
      return Stack(alignment: alignment, children: [...kept.reversed, ?current]);
    };

/// A dark, frosted panel.
class Glass extends StatelessWidget {
  const Glass({
    super.key,
    required this.child,
    required this.radius,
    this.opacity = 0.38,
    this.padding,
    this.floating = false,
  });

  final Widget child;
  final double radius;
  final double opacity;
  final EdgeInsetsGeometry? padding;

  /// Floats over sharp content on a layer (a menu over the messages): it blurs what is behind it
  /// itself, where other panels on a layer rely on the layer's one blur.
  final bool floating;

  @override
  Widget build(BuildContext context) {
    if (LookScope.isGlass(context)) {
      // A darker panel (a full panel, a toast floating over anything) keeps more of its navy.
      return IceSurface(
        radius: radius,
        padding: padding,
        opacity: math.min(GlassRecipe.floatingOpacity, GlassRecipe.baseOpacity + math.max(0, opacity - 0.38) * 1.15),
        blur: floating,
        child: child,
      );
    }
    final shape = BorderRadius.circular(radius);
    // On a full-screen layer, what is behind was blurred by the layer already; on the home
    // screen the panels share one backdrop (HomeView's BackdropGroup).
    return ClipRRect(
      borderRadius: shape,
      child: BackdropFilter.grouped(
        enabled: floating || !FrostedBehind.of(context),
        filter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: opacity),
            borderRadius: shape,
            border: Border.all(color: Colors.white.withValues(alpha: 0.09)),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// The ring and glow a focused element wears, in the console's style: a ring that is never fainter
/// than 90 % white with a soft halo around it. With [animated] (the home tiles only) the halo
/// breathes slowly and a brighter glint travels around the edge; everywhere else the same ring
/// stands still, so a ring never makes the blur behind it run again.
///
/// The glow is drawn around the ring only, so the element itself keeps its colors.
class FocusRing extends StatefulWidget {
  const FocusRing({
    super.key,
    required this.focused,
    required this.radius,
    required this.child,
    this.width = 3,
    this.animated = false,
  });

  /// Whether rings may move at all. main turns it on; tests leave it off (a loop that never ends
  /// keeps a frame scheduled, and pumpAndSettle would wait for it) and flip it where they test it.
  static bool enabled = false;

  final bool focused;
  final double radius;
  final double width;

  /// The ring moves while focused. Only the home tiles ask for it, and only when nothing else
  /// needs the computer (no game starting or running, no layer open, no reduced motion).
  final bool animated;
  final Widget child;

  @override
  State<FocusRing> createState() => _FocusRingState();
}

class _FocusRingState extends State<FocusRing> with SingleTickerProviderStateMixin {
  /// One full turn of the glint around the edge; the halo breathes twice per turn.
  static const _period = Duration(milliseconds: 4800);

  late final AnimationController _loop = AnimationController(vsync: this, duration: _period);

  bool _glass = false;

  bool _reduced(BuildContext context) => MediaQuery.disableAnimationsOf(context) || Motion.reduced;

  // Inherited widgets cannot be read in initState; this runs right after it, and when the look or
  // the system's animation setting changes.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _glass = LookScope.isGlass(context);
    _sync(_reduced(context));
  }

  @override
  void didUpdateWidget(FocusRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync(_reduced(context));
  }

  /// Starts or stops the loop. Also run from build: Motion.reduced is a plain flag (reduced
  /// motion in the settings, the low-power dimming), and a ring already moving must stop when it
  /// turns on, which no inherited widget tells it.
  void _sync(bool reduced) {
    final moves = widget.focused && widget.animated && FocusRing.enabled && !_glass && !reduced;
    if (moves) {
      if (!_loop.isAnimating) _loop.repeat();
    } else if (_loop.isAnimating) {
      _loop.stop();
    }
  }

  @override
  void dispose() {
    _loop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduced = _reduced(context);
    _sync(reduced);
    final width = widget.width;
    final reach = width * 1.6;
    // The settle: the ring starts this far outside and closes in, the same distance on every
    // side and for every size.
    final settle = width * 2;
    final moving = _loop.isAnimating;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        widget.child,
        PositionedDirectional(
          start: -(reach + settle),
          top: -(reach + settle),
          end: -(reach + settle),
          bottom: -(reach + settle),
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: widget.focused ? 1 : 0,
              duration: Motion.focus,
              curve: Motion.settle,
              child: TweenAnimationBuilder<double>(
                tween: Tween(end: widget.focused || reduced ? 0 : settle),
                duration: reduced ? Duration.zero : Motion.focus * 1.5,
                curve: Motion.settle,
                builder: (context, away, _) {
                  final ring = CustomPaint(
                    painter: _glass
                        ? _IceRingPainter(radius: widget.radius + reach, width: width, inset: settle - away)
                        : _RingPainter(
                            radius: widget.radius + reach,
                            width: width,
                            inset: settle - away,
                            phase: moving ? _loop : null,
                          ),
                  );
                  // A layer of its own only while the ring repaints every frame.
                  return moving ? RepaintBoundary(child: ring) : ring;
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.radius, required this.width, required this.inset, Animation<double>? phase})
    : _phase = phase,
      super(repaint: phase);
  final double radius;
  final double width;

  /// How far in from the painted area's edge the ring sits (the settle).
  final double inset;
  final Animation<double>? _phase;

  /// The ring at its dimmest, in white: it is the only way to see where you are, over any picture.
  static const _base = 0.92;

  @override
  void paint(Canvas canvas, Size size) {
    final t = _phase?.value ?? 0; // 0..1, one turn of the glint
    final rect = (Offset.zero & size).deflate(inset);
    final ring = RRect.fromRectAndRadius(rect.deflate(width / 2), Radius.circular(radius));

    // Breathing: only the halo's opacity swells and fades, twice per turn, never fully off.
    // The blur stays fixed, which keeps it cheap for the GPU.
    final breath = _phase == null ? 0.5 : 0.5 - 0.5 * math.cos(t * 2 * math.pi * 2);
    final haloAlpha = 0.24 + 0.14 * breath;

    // 1. Soft halo, outside the ring only.
    canvas.drawRRect(
      ring,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width * 2.5
        ..color = Colors.white.withValues(alpha: haloAlpha)
        ..maskFilter = const MaskFilter.blur(BlurStyle.outer, 9),
    );

    // 2. The ring at its full width: at least 92 % white, with the glint (full white) going around.
    final base = Colors.white.withValues(alpha: _base);
    final shader = _phase == null
        ? null
        : SweepGradient(
            transform: GradientRotation(t * 2 * math.pi),
            colors: [base, base, Colors.white, base, base],
            stops: const [0.0, 0.62, 0.8, 0.98, 1.0],
          ).createShader(rect);
    canvas.drawRRect(
      ring,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..color = base
        ..shader = shader,
    );

    // 3. The glint also lights the halo a little where it passes (only while it travels).
    if (_phase != null) {
      canvas.drawRRect(
        ring,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = width * 2
          ..shader = SweepGradient(
            transform: GradientRotation(t * 2 * math.pi),
            colors: [
              Colors.white.withValues(alpha: 0),
              Colors.white.withValues(alpha: 0),
              Colors.white.withValues(alpha: 0.38),
              Colors.white.withValues(alpha: 0),
              Colors.white.withValues(alpha: 0),
            ],
            stops: const [0.0, 0.62, 0.8, 0.98, 1.0],
          ).createShader(rect)
          ..maskFilter = const MaskFilter.blur(BlurStyle.outer, 6),
      );
    }
  }

  @override
  bool shouldRepaint(_RingPainter oldDelegate) =>
      oldDelegate.radius != radius ||
      oldDelegate.width != width ||
      oldDelegate.inset != inset ||
      // Stopped: one more paint, with the glint put away.
      oldDelegate._phase != _phase;
}

/// Glass's focus ring: a thinner ring of ice, white at the top and cyan below, in an icy glow.
class _IceRingPainter extends CustomPainter {
  _IceRingPainter({required this.radius, required this.width, this.inset = 0});
  final double radius;
  final double width;

  /// How far in from the painted area's edge the ring sits (the settle).
  final double inset;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(inset);
    final ring = RRect.fromRectAndRadius(rect.deflate(width / 2), Radius.circular(radius));
    canvas
      ..drawRRect(
        ring,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = width * 2.5
          ..color = GlassRecipe.cyan.withValues(alpha: GlassRecipe.glowOpacity)
          ..maskFilter = const MaskFilter.blur(BlurStyle.outer, GlassRecipe.glowBlur / 2),
      )
      ..drawRRect(
        ring,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = width * 0.8
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomRight,
            colors: [Colors.white, Colors.white.withValues(alpha: 0.85), GlassRecipe.cyan],
            stops: const [0, 0.5, 1],
          ).createShader(rect),
      );
  }

  @override
  bool shouldRepaint(_IceRingPainter oldDelegate) =>
      oldDelegate.radius != radius || oldDelegate.width != width || oldDelegate.inset != inset;
}

/// A console button: translucent until focused, then solid white.
class ConsoleButton extends StatefulWidget {
  const ConsoleButton({
    super.key,
    required this.title,
    required this.focused,
    required this.onPressed,
    this.icon,
    this.prominent = false,
    this.destructive = false,
    this.minWidth = 0,
    this.stop = false,
    this.progress,
    this.indeterminate = false,
    this.progressColor,
  });

  final String title;
  final IconData? icon;
  final bool focused;
  final bool prominent;
  final bool destructive;
  final double minWidth;
  final VoidCallback onPressed;

  /// Ends what runs (Stop on a game playing): a red button, in either look.
  final bool stop;

  /// The share done, as a line along the button's foot; null for none.
  final double? progress;

  /// The line moves without a share (under way for a while nobody can say).
  final bool indeterminate;
  final Color? progressColor;

  /// Stop's red, deep enough for white words on it.
  static const stopRed = Color.fromRGBO(214, 54, 61, 1);

  @override
  State<ConsoleButton> createState() => _ConsoleButtonState();
}

class _ConsoleButtonState extends State<ConsoleButton> {
  bool _hovering = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final focused = widget.focused;
    final glass = LookScope.isGlass(context);
    final foreground = focused ? LookScope.focusedInk(context) : (widget.destructive ? Palette.danger : Colors.white);
    final fill = focused
        ? Colors.white
        : Colors.white.withValues(alpha: widget.prominent ? 0.2 : (_hovering ? 0.16 : 0.1));
    final stop = widget.stop;
    final ink = stop ? Colors.white : foreground;
    final constraints = BoxConstraints(minWidth: widget.minWidth * scale, minHeight: 54 * scale);
    final padding = EdgeInsets.symmetric(horizontal: (widget.title.isEmpty ? 18 : 30) * scale);
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (widget.icon != null) Icon(widget.icon, size: 20 * scale, color: ink),
        if (widget.icon != null && widget.title.isNotEmpty) SizedBox(width: 10 * scale),
        if (widget.title.isNotEmpty)
          Text(
            widget.title,
            // A share counting up keeps the words where they are.
            style: widget.progress == null
                ? AppText.display(19 * scale, weight: FontWeight.w600, color: ink)
                : AppText.display(
                    19 * scale,
                    weight: FontWeight.w600,
                    color: ink,
                  ).copyWith(fontFeatures: const [ui.FontFeature.tabularFigures()]),
          ),
      ],
    );
    final share = widget.progress;
    final lineColor = widget.progressColor ?? (focused && !stop ? ink : Colors.white);
    final content = row;
    // The progress rides the button's foot, inside its rounded edge.
    Widget withProgress(Widget button) => share == null && !widget.indeterminate
        ? button
        : Stack(
            children: [
              button,
              PositionedDirectional(
                start: 18 * scale,
                end: 18 * scale,
                bottom: 7 * scale,
                child: widget.indeterminate
                    ? IndeterminateLine(color: lineColor, height: 3 * scale)
                    : ProgressLine(fraction: share!, color: lineColor, height: 3 * scale),
              ),
            ],
          );
    if (stop) {
      return _pressable(
        focused,
        glass,
        withProgress(
          AnimatedContainer(
            duration: Motion.focus,
            curve: Motion.settle,
            constraints: constraints,
            padding: padding,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: ConsoleButton.stopRed.withValues(alpha: focused ? 1 : (_hovering ? 0.92 : 0.82)),
              borderRadius: BorderRadius.circular(14 * scale),
              border: Border.all(
                color: Colors.white.withValues(alpha: focused ? 0.9 : 0.18),
                width: focused ? 2 : 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: ConsoleButton.stopRed.withValues(alpha: focused ? 0.55 : 0.25),
                  blurRadius: (focused ? 22 : 12) * scale,
                ),
              ],
            ),
            child: content,
          ),
        ),
      );
    }
    return _pressable(
      focused,
      glass,
      withProgress(
        glass
            // Glass: a pane of frosted ice that becomes a bright ice chip when focused.
            ? IceSurface(
                radius: 14 * scale,
                focused: focused,
                hover: _hovering || widget.prominent,
                sweep: true,
                constraints: constraints,
                padding: padding,
                child: content,
              )
            : AnimatedContainer(
                duration: Motion.focus,
                curve: Motion.settle,
                constraints: constraints,
                padding: padding,
                decoration: BoxDecoration(
                  color: fill,
                  borderRadius: BorderRadius.circular(14 * scale),
                  border: Border.all(color: Colors.white.withValues(alpha: focused ? 0 : 0.12)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.white.withValues(alpha: focused ? 0.28 : 0),
                      blurRadius: 18 * scale,
                    ),
                  ],
                ),
                child: content,
              ),
      ),
    );
  }

  Widget _pressable(bool focused, bool glass, Widget child) => MouseRegion(
    cursor: SystemMouseCursors.click,
    onEnter: (event) {
      setState(() => _hovering = true);
      HoverTicks.arrive(context, this, event);
    },
    onExit: (_) {
      setState(() => _hovering = false);
      HoverTicks.leave(context, this);
    },
    child: GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapCancel: () => setState(() => _pressed = false),
      onTapUp: (_) => setState(() => _pressed = false),
      onTap: widget.onPressed,
      child: AnimatedScale(
        scale: _pressed ? 0.97 : (focused ? (glass ? GlassRecipe.focusScale : 1.05) : 1),
        duration: _pressed ? const Duration(milliseconds: 90) : Motion.focus,
        curve: Motion.settle,
        child: child,
      ),
    ),
  );
}

/// A thin capsule progress bar.
class ProgressLine extends StatelessWidget {
  const ProgressLine({super.key, required this.fraction, required this.color, this.height = 4});

  final double fraction;
  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = math.max(height, constraints.maxWidth * fraction.clamp(0, 1));
          return Stack(
            children: [
              Container(
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(height),
                ),
              ),
              AnimatedContainer(
                duration: const Duration(milliseconds: 350),
                curve: Curves.easeOut,
                width: width,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(height),
                  boxShadow: [BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 6)],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// An endless sweep for steps whose length is not known (the relinker's run).
class IndeterminateLine extends StatefulWidget {
  const IndeterminateLine({super.key, required this.color, this.height = 4});

  final Color color;
  final double height;

  @override
  State<IndeterminateLine> createState() => _IndeterminateLineState();
}

class _IndeterminateLineState extends State<IndeterminateLine> with SingleTickerProviderStateMixin {
  // With reduced motion the line rests in the middle instead of sweeping.
  late final AnimationController _controller = Motion.reduced
      ? AnimationController(vsync: this, value: 0.5)
      : (AnimationController(vsync: this, duration: const Duration(milliseconds: 1300))..repeat());

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(widget.height),
        child: LayoutBuilder(
          builder: (context, constraints) => AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              final phase = -0.4 + 1.45 * Motion.inOut.transform(_controller.value);
              return Stack(
                children: [
                  Container(color: Colors.white.withValues(alpha: 0.16)),
                  PositionedDirectional(
                    start: constraints.maxWidth * phase,
                    width: constraints.maxWidth * 0.35,
                    top: 0,
                    bottom: 0,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [widget.color.withValues(alpha: 0), widget.color, widget.color.withValues(alpha: 0)],
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// The time, updated every minute.
class Clock extends StatefulWidget {
  const Clock({super.key, this.now});

  /// A fixed time, for previews and tests.
  final DateTime? now;

  @override
  State<Clock> createState() => _ClockState();
}

class _ClockState extends State<Clock> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (widget.now == null) {
      _timer = Timer.periodic(const Duration(seconds: 15), (_) => setState(() {}));
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final now = widget.now ?? DateTime.now();
    final text = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    return Text(
      text,
      style: AppText.display(20 * scale, weight: FontWeight.w500, color: Colors.white.withValues(alpha: 0.92)),
    );
  }
}

/// One of the PlayStation face buttons, drawn (the font has no glyphs for them).
class PadGlyphIcon extends StatelessWidget {
  const PadGlyphIcon(this.glyph, {super.key, required this.size, required this.color});

  final PadGlyph glyph;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => CustomPaint(size: Size.square(size), painter: _GlyphPainter(glyph, color));
}

class _GlyphPainter extends CustomPainter {
  _GlyphPainter(this.glyph, this.color);
  final PadGlyph glyph;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.13
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final inset = size.width * 0.18;
    final box = Rect.fromLTWH(inset, inset, size.width - inset * 2, size.height - inset * 2);
    switch (glyph) {
      case PadGlyph.cross:
        canvas
          ..drawLine(box.topLeft, box.bottomRight, paint)
          ..drawLine(box.topRight, box.bottomLeft, paint);
      case PadGlyph.circle:
        canvas.drawCircle(box.center, box.width / 2, paint);
      case PadGlyph.square:
        canvas.drawRRect(RRect.fromRectAndRadius(box, Radius.circular(size.width * 0.05)), paint);
      case PadGlyph.triangle:
        final path = Path()
          ..moveTo(box.center.dx, box.top)
          ..lineTo(box.right, box.bottom - box.height * 0.08)
          ..lineTo(box.left, box.bottom - box.height * 0.08)
          ..close();
        canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter oldDelegate) => oldDelegate.glyph != glyph || oldDelegate.color != color;
}

/// What the user moved the launcher with last: the hints and controls follow it.
enum InputMode { keyboardMouse, pad }

/// The input in use and the section keys and buttons, for the hints: with a controller they show
/// its buttons only, with the keys and the mouse the keys only.
class InputScope extends InheritedWidget {
  const InputScope({
    super.key,
    required this.mode,
    this.previousKey,
    this.nextKey,
    this.previousPad,
    this.nextPad,
    required super.child,
  });

  final InputMode mode;
  final String? previousKey;
  final String? nextKey;
  final String? previousPad;
  final String? nextPad;

  static InputScope? of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<InputScope>();

  /// Whether the controller was used last (the keyboard and the mouse when there is no scope).
  static bool pad(BuildContext context) => of(context)?.mode == InputMode.pad;

  @override
  bool updateShouldNotify(InputScope oldWidget) =>
      oldWidget.mode != mode ||
      oldWidget.previousKey != previousKey ||
      oldWidget.nextKey != nextKey ||
      oldWidget.previousPad != previousPad ||
      oldWidget.nextPad != nextPad;
}

/// What a hint pill does when it is clicked: the same as its key.
enum HintAction { previousGame, nextGame, select, back, options }

/// Runs a hint pill's action, given by the launcher's shell; without one the pills only show.
class HintScope extends InheritedWidget {
  const HintScope({super.key, required this.onAction, required super.child});

  final void Function(HintAction action) onAction;

  static void Function(HintAction)? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HintScope>()?.onAction;

  @override
  bool updateShouldNotify(HintScope oldWidget) => oldWidget.onAction != onAction;
}

/// Where the hover tick goes: the soft navigation sound when the pointer arrives on a control,
/// tile, row or card (the launcher's shell gives it; nothing without one).
class HoverTicks extends InheritedWidget {
  const HoverTicks({super.key, required this.onArrive, required this.onLeave, required super.child});

  final void Function(Object id, PointerEvent event) onArrive;
  final void Function(Object id) onLeave;

  static void arrive(BuildContext context, Object id, PointerEvent event) =>
      context.getInheritedWidgetOfExactType<HoverTicks>()?.onArrive(id, event);

  static void leave(BuildContext context, Object id) =>
      context.getInheritedWidgetOfExactType<HoverTicks>()?.onLeave(id);

  @override
  bool updateShouldNotify(HoverTicks oldWidget) => false;
}

/// A child that reacts to the pointer: the click cursor, a hover state for [builder], a press
/// that shrinks it a little, and [onTap]. [onHover] runs when the pointer moves over it (not
/// when a list scrolls it under a still pointer), so a hover can move the keyboard's focus
/// without fighting the keys.
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.builder,
    this.onTap,
    this.onDoubleTap,
    this.onHover,
    this.pressScale = 0.97,
  });

  final Widget Function(BuildContext context, bool hovering) builder;
  final VoidCallback? onTap;

  /// A second click on it soon after the first; the first click still runs [onTap] at once.
  final VoidCallback? onDoubleTap;
  final VoidCallback? onHover;
  final double pressScale;

  /// How close two clicks must be to count as a double click.
  static const doubleClick = Duration(milliseconds: 400);

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _hovering = false;
  bool _pressed = false;

  /// When the pointer went down for this click and for the one before (the events' own times).
  Duration? _down;
  Duration? _lastTap;

  void _tap() {
    final now = _down;
    final last = _lastTap;
    if (widget.onDoubleTap != null && now != null && last != null && now - last <= Pressable.doubleClick) {
      _lastTap = null;
      widget.onDoubleTap!();
      return;
    }
    _lastTap = now;
    widget.onTap?.call();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null || widget.onDoubleTap != null;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (event) {
        setState(() => _hovering = true);
        if (enabled || widget.onHover != null) HoverTicks.arrive(context, this, event);
      },
      onExit: (_) {
        setState(() => _hovering = false);
        HoverTicks.leave(context, this);
      },
      onHover: widget.onHover == null ? null : (_) => widget.onHover!(),
      child: Listener(
        onPointerDown: (event) => _down = event.timeStamp,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
          onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
          onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
          onTap: enabled ? _tap : null,
          child: AnimatedScale(
            scale: _pressed ? widget.pressScale : 1,
            duration: const Duration(milliseconds: 90),
            curve: Motion.settle,
            child: widget.builder(context, _hovering && enabled),
          ),
        ),
      ),
    );
  }
}

/// A key or button with what it does; clicked, it does the same as the key.
class Hint extends StatelessWidget {
  const Hint({super.key, required this.keys, required this.label, this.glyph, this.pad, this.action});

  /// Settings › Controllers › Confirm Button is Circle: the hints show ○ to select and ✕ to go
  /// back (AppModel sets it).
  static bool circleConfirms = false;

  PadGlyph? get _shownGlyph => !circleConfirms
      ? glyph
      : switch (glyph) {
          PadGlyph.cross => PadGlyph.circle,
          PadGlyph.circle => PadGlyph.cross,
          final other => other,
        };

  /// The keyboard's key or keys ("Enter", "Q").
  final String keys;

  /// The controller's face button, drawn.
  final PadGlyph? glyph;

  /// The controller's button in words where it has no glyph ("L1"); the keys stand for both
  /// when neither is given (the arrows).
  final String? pad;
  final String label;
  final HintAction? action;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final run = action == null ? null : HintScope.of(context);
    final viaPad = InputScope.pad(context);
    // With a controller only its button; with the keys only the key.
    final shownGlyph = viaPad ? _shownGlyph : null;
    final shownText = viaPad ? (glyph != null ? null : pad ?? keys) : keys;
    Widget pill(bool hovering) {
      final color = Colors.white.withValues(alpha: hovering ? 1 : 0.72);
      return AnimatedContainer(
        duration: Motion.focus,
        curve: Motion.settle,
        padding: EdgeInsets.symmetric(horizontal: 6 * scale, vertical: 4 * scale),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: hovering ? 0.12 : 0),
          borderRadius: BorderRadius.circular(8 * scale),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: EdgeInsets.symmetric(horizontal: 7 * scale, vertical: 3 * scale),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: hovering ? 0.26 : 0.16),
                borderRadius: BorderRadius.circular(5 * scale),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (shownText != null)
                    Text(
                      shownText,
                      style: AppText.display(12 * scale, weight: FontWeight.w700, color: color),
                    ),
                  if (shownGlyph != null) PadGlyphIcon(shownGlyph, size: 13 * scale, color: color),
                ],
              ),
            ),
            SizedBox(width: 8 * scale),
            Text(
              label,
              style: AppText.display(13 * scale, weight: FontWeight.w500, color: color),
            ),
          ],
        ),
      );
    }

    if (run == null) return pill(false);
    return Pressable(onTap: () => run(action!), builder: (context, hovering) => pill(hovering));
  }
}

class HintBar extends StatelessWidget {
  const HintBar({super.key, this.options = true, this.games = true});

  final bool options;

  /// Whether Q and E (L1 and R1) move between games here.
  final bool games;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final input = InputScope.of(context);
    final previousKey = input == null ? 'Q' : input.previousKey;
    final nextKey = input == null ? 'E' : input.nextKey;
    final previousPad = input == null ? 'L1' : input.previousPad;
    final nextPad = input == null ? 'R1' : input.nextPad;
    final viaPad = input?.mode == InputMode.pad;
    return Wrap(
      spacing: 10 * scale,
      runSpacing: 8 * scale,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Hint(keys: '← → ↑ ↓', label: T.text('hintMove')),
        if (games) ...[
          // A section shortcut cleared for the input in use: its hint goes.
          if ((viaPad ? previousPad : previousKey) case final String shown)
            Hint(
              keys: previousKey ?? shown,
              pad: shown,
              label: T.text('hintPreviousGame'),
              action: HintAction.previousGame,
            ),
          if ((viaPad ? nextPad : nextKey) case final String shown)
            Hint(keys: nextKey ?? shown, pad: shown, label: T.text('hintNextGame'), action: HintAction.nextGame),
        ],
        Hint(keys: 'Enter', glyph: PadGlyph.cross, label: T.text('hintSelect'), action: HintAction.select),
        Hint(keys: 'Esc', glyph: PadGlyph.circle, label: T.text('hintBack'), action: HintAction.back),
        if (options)
          Hint(keys: 'O', glyph: PadGlyph.triangle, label: T.text('hintOptions'), action: HintAction.options),
      ],
    );
  }
}

/// The way out of a panel or a screen over the home screen, for the mouse: Esc / ○ Back.
class BackPill extends StatelessWidget {
  const BackPill({super.key, required this.onTap, this.close = false});

  final VoidCallback onTap;

  /// Shown as a close button (×) instead of Back.
  final bool close;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final viaPad = InputScope.pad(context);
    return Semantics(
      button: true,
      label: T.text(close ? 'close' : 'back'),
      child: Pressable(
        onTap: onTap,
        builder: (context, hovering) => LookScope.isGlass(context)
            ? IceSurface(
                key: const ValueKey('back-pill'),
                radius: 30 * scale,
                hover: hovering,
                shadow: false,
                padding: EdgeInsets.symmetric(horizontal: 14 * scale, vertical: 9 * scale),
                child: _backContent(scale, hovering, viaPad),
              )
            : AnimatedContainer(
                key: const ValueKey('back-pill'),
                duration: Motion.focus,
                curve: Motion.settle,
                padding: EdgeInsets.symmetric(horizontal: 14 * scale, vertical: 9 * scale),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: hovering ? 0.22 : 0.1),
                  borderRadius: BorderRadius.circular(30 * scale),
                  border: Border.all(color: Colors.white.withValues(alpha: hovering ? 0.3 : 0.12)),
                ),
                child: _backContent(scale, hovering, viaPad),
              ),
      ),
    );
  }

  Widget _backContent(double scale, bool hovering, bool viaPad) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(
        close ? Icons.close_rounded : Icons.arrow_back_rounded,
        size: 17 * scale,
        color: Colors.white.withValues(alpha: hovering ? 1 : 0.85),
      ),
      SizedBox(width: 8 * scale),
      Text(
        T.text(close ? 'close' : 'back'),
        style: AppText.display(15 * scale, weight: FontWeight.w600, color: Colors.white),
      ),
      SizedBox(width: 10 * scale),
      // With a controller the way back is Circle (Cross when Circle confirms), not Esc.
      if (viaPad)
        PadGlyphIcon(
          Hint.circleConfirms ? PadGlyph.cross : PadGlyph.circle,
          size: 13 * scale,
          color: Colors.white.withValues(alpha: 0.6),
        )
      else
        Text(
          'Esc',
          style: AppText.display(12 * scale, weight: FontWeight.w700, color: Colors.white.withValues(alpha: 0.5)),
        ),
    ],
  );
}

/// A full-screen layer with its way out for the mouse in the top right corner.
class WithBackPill extends StatelessWidget {
  const WithBackPill({super.key, required this.onBack, required this.child, this.titleLine});

  final VoidCallback onBack;
  final Widget child;

  /// For a layer with a big title: the content's side and top padding. The pill then sits on the
  /// title's line at the content's right edge, level with the title, instead of in the corner.
  final ({double side, double top})? titleLine;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final line = titleLine;
    // The pill is centred on the line of the layers' 40 pt display title, measured in its font.
    final lineHeight = line == null
        ? 0.0
        : (TextPainter(
            text: TextSpan(
              text: 'Ag',
              style: DefaultTextStyle.of(context).style.merge(AppText.display(40 * scale, weight: FontWeight.w300)),
            ),
            textDirection: TextDirection.ltr,
            textScaler: MediaQuery.textScalerOf(context),
          )..layout()).height;
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        if (line == null)
          PositionedDirectional(
            top: 18 * scale,
            end: 24 * scale,
            child: BackPill(onTap: onBack),
          )
        else
          PositionedDirectional(
            top: line.top * scale,
            end: line.side * scale,
            height: lineHeight,
            child: Center(child: BackPill(onTap: onBack)),
          ),
      ],
    );
  }
}

/// A game's picture from its file, decoded at about the size it is shown. The file is read and
/// decoded away from the interface (FileImage), and the decoded picture stays in the image cache,
/// so going back to a game shows it at once, without a disk read in the middle of a frame.
class ArtworkImage extends StatelessWidget {
  const ArtworkImage({super.key, required this.path, this.fit = BoxFit.cover, this.cacheWidth});

  final String path;
  final BoxFit fit;
  final int? cacheWidth;

  /// Tests read the file on the spot: their fake clock never lets a file read in the
  /// background finish while a frame waits for it.
  @visibleForTesting
  static bool readSynchronously = false;

  static final Map<String, MemoryImage?> _read = {};

  static ImageProvider provider(String path, int? cacheWidth) {
    final ImageProvider image;
    if (readSynchronously) {
      final memory = _read.putIfAbsent(path, () {
        try {
          return MemoryImage(File(path).readAsBytesSync());
        } on FileSystemException {
          return null;
        }
      });
      image = memory ?? FileImage(File(path));
    } else {
      image = FileImage(File(path));
    }
    return cacheWidth == null ? image : ResizeImage(image, width: cacheWidth, policy: ResizeImagePolicy.fit);
  }

  /// Decodes [path] ahead of time (the games beside the selected one), so its picture is ready
  /// when the selection gets there.
  static void warm(BuildContext context, String? path, {int? cacheWidth}) {
    if (path == null) return;
    unawaited(precacheImage(provider(path, cacheWidth), context, onError: (_, _) {}));
  }

  @override
  Widget build(BuildContext context) {
    return Image(
      image: provider(path, cacheWidth),
      fit: fit,
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
      errorBuilder: (context, error, stack) => const SizedBox.shrink(),
    );
  }
}

/// Bytes as a size people read: 12.3 GB.
String byteText(int? bytes) {
  if (bytes == null || bytes < 0) return '…';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  return unit == 0 ? '$bytes B' : '${T.decimal(value, value >= 100 ? 0 : 1)} ${units[unit]}';
}

/// Whether the focus was last moved by the pointer (a hover or a click), which [KeepVisible]
/// leaves where it is; the launcher's shell gives it.
class PointerFocus extends InheritedWidget {
  const PointerFocus({super.key, required this.value, required super.child});

  final bool value;

  static bool of(BuildContext context) => context.getInheritedWidgetOfExactType<PointerFocus>()?.value ?? false;

  @override
  bool updateShouldNotify(PointerFocus oldWidget) => false;
}

/// Scrolls its child into view whenever [active] turns true, so a keyboard focus that moves
/// down a long list stays on screen. A focus the pointer moved ([PointerFocus]) never scrolls:
/// the row under the mouse is already in view, and a list that scrolled to it would slide
/// another row under the mouse, which would take the focus and scroll again (the list chased
/// the pointer).
class KeepVisible extends StatefulWidget {
  const KeepVisible({super.key, required this.active, required this.child, this.atStart = false});

  final bool active;
  final Widget child;

  /// Brought into view when first built active too (without moving), not only when it becomes so.
  final bool atStart;

  @override
  State<KeepVisible> createState() => _KeepVisibleState();
}

class _KeepVisibleState extends State<KeepVisible> {
  @override
  void initState() {
    super.initState();
    if (widget.atStart && widget.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Scrollable.ensureVisible(context, alignment: 0.5);
      });
    }
  }

  @override
  void didUpdateWidget(KeepVisible oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active && !PointerFocus.of(context)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Scrollable.ensureVisible(
          context,
          alignment: 0.5,
          duration: Motion.focus,
          curve: Motion.settle,
          alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
