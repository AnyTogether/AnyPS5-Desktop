import 'package:flutter/material.dart';

import '../core/themes/theme_design.dart';
import 'app_model.dart';
import 'components.dart';
import 'panels.dart';
import 'strings.dart';
import 'theme.dart';

/// The Theme Studio: the knobs in a pane on the right, the launcher itself left in view so each
/// change shows on the real home screen at once (no blur, no scrim over it). Above the knobs, the
/// theme's name set large and its four colours as paint chips with their codes, the way a colour
/// card is read.
class ThemeStudioView extends StatelessWidget {
  const ThemeStudioView({super.key, required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final design = model.activeDesign;
    final rows = model.studioRows();
    if (design == null) return const SizedBox.shrink();
    final accent = model.accentChoice.color;
    return Stack(
      fit: StackFit.expand,
      children: [
        // Only the pane's side darkens, so the text there reads over any picture.
        const IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [Color(0x00000000), Color(0x00000000), Color(0x8C000000)],
                stops: [0, 0.45, 1],
              ),
            ),
          ),
        ),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: Padding(
            padding: EdgeInsetsDirectional.fromSTEB(0, 40 * scale, 40 * scale, 40 * scale),
            child: SizedBox(
              width: 760 * scale,
              child: Glass(
                radius: 28 * scale,
                opacity: 0.55,
                padding: EdgeInsets.fromLTRB(36 * scale, 30 * scale, 36 * scale, 28 * scale),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            T.upper(T.text('themeStudio')),
                            style: AppText.display(
                              12 * scale,
                              weight: FontWeight.w700,
                              color: accent,
                            ).copyWith(letterSpacing: 1.6 * scale),
                          ),
                        ),
                        BackPill(onTap: () => model.handle(Command.back)),
                      ],
                    ),
                    SizedBox(height: 6 * scale),
                    Text(
                      design.name.isEmpty ? T.text('newThemeName') : design.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.display(52 * scale, weight: FontWeight.w600, height: 1.02),
                    ),
                    SizedBox(height: 6 * scale),
                    Text(
                      T.text('themeStudioSubtitle'),
                      style: AppText.display(15 * scale, color: Colors.white.withValues(alpha: 0.66)),
                    ),
                    SizedBox(height: 20 * scale),
                    _Chips(design: design),
                    SizedBox(height: 22 * scale),
                    Expanded(
                      child: PanelRows(model: model, rows: rows),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Appearance › Themes: the list in a pane on the right, as the Studio's (and the Mac's), the
/// launcher left in view beside it, so a theme chosen shows on the real home screen at once.
/// The rows keep the width a name and a line need, not the whole window's.
class ThemesView extends StatelessWidget {
  const ThemesView({super.key, required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final accent = model.accentChoice.color;
    return Stack(
      fit: StackFit.expand,
      children: [
        // Only the pane's side darkens, so the text there reads over any picture; a click on the
        // home screen beside it goes back.
        GestureDetector(
          key: const ValueKey('themes-outside'),
          behavior: HitTestBehavior.opaque,
          onTap: () => model.handle(Command.back),
          child: const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [Color(0x00000000), Color(0x00000000), Color(0x8C000000)],
                stops: [0, 0.45, 1],
              ),
            ),
          ),
        ),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: Padding(
            padding: EdgeInsetsDirectional.fromSTEB(0, 40 * scale, 40 * scale, 40 * scale),
            child: SizedBox(
              key: const ValueKey('themes-pane'),
              width: 620 * scale,
              child: Glass(
                radius: 28 * scale,
                opacity: 0.55,
                padding: EdgeInsets.fromLTRB(36 * scale, 30 * scale, 36 * scale, 28 * scale),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            T.upper(T.text('appearance')),
                            style: AppText.display(
                              12 * scale,
                              weight: FontWeight.w700,
                              color: accent,
                            ).copyWith(letterSpacing: 1.6 * scale),
                          ),
                        ),
                        BackPill(onTap: () => model.handle(Command.back)),
                      ],
                    ),
                    SizedBox(height: 6 * scale),
                    Text(T.text('themes'), style: AppText.display(52 * scale, weight: FontWeight.w600, height: 1.02)),
                    SizedBox(height: 6 * scale),
                    Text(
                      T.text('themesDetail'),
                      style: AppText.display(15 * scale, color: Colors.white.withValues(alpha: 0.66)),
                    ),
                    SizedBox(height: 22 * scale),
                    Expanded(
                      child: PanelRows(model: model, rows: model.themeRows()),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The theme's deep, middle and bright tones and its accent as paint chips: the colour on top,
/// its code under it in figures of one width, the chip changing as the knobs turn.
class _Chips extends StatelessWidget {
  const _Chips({required this.design});

  final ThemeDesign design;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    Color color(Rgb rgb) => Color.fromRGBO((rgb.r * 255).round(), (rgb.g * 255).round(), (rgb.b * 255).round(), 1);
    final chips = [
      (design.deep, color(design.deepRgb)),
      (design.middle, color(design.middleRgb)),
      (design.bright, color(design.brightRgb)),
      (design.accent, color(design.accentRgb)),
    ];
    return Row(
      children: [
        for (final (index, (code, fill)) in chips.indexed) ...[
          if (index > 0) SizedBox(width: 10 * scale),
          Expanded(
            child: Container(
              height: 74 * scale,
              decoration: BoxDecoration(
                color: const Color(0x1FFFFFFF),
                borderRadius: BorderRadius.circular(12 * scale),
                border: Border.all(color: const Color(0x24FFFFFF), width: 1),
              ),
              padding: EdgeInsets.all(5 * scale),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: AnimatedContainer(
                      duration: Motion.fade,
                      curve: Motion.settle,
                      decoration: BoxDecoration(
                        color: fill,
                        borderRadius: BorderRadius.circular(8 * scale),
                        // The accent chip is the one the buttons wear: its ring says so.
                        border: index == 3 ? Border.all(color: const Color(0xCCFFFFFF), width: 1.5 * scale) : null,
                      ),
                    ),
                  ),
                  SizedBox(height: 5 * scale),
                  Text(
                    code.toUpperCase(),
                    textAlign: TextAlign.center,
                    style: AppText.display(
                      11.5 * scale,
                      weight: FontWeight.w600,
                      color: Colors.white.withValues(alpha: 0.78),
                    ).copyWith(letterSpacing: 0.6 * scale),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}
