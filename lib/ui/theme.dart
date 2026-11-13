import 'dart:math' as math;

import 'package:flutter/animation.dart';
import 'package:flutter/painting.dart';

import 'strings.dart';

/// The built-in looks: an animated background (shaders/background.frag) with the colors the
/// interface draws over it. New looks go last: the index is what the preferences keep.
enum LookStyle {
  cosmic(Color.fromRGBO(3, 6, 23, 1), Color.fromRGBO(10, 38, 107, 1), Color.fromRGBO(107, 163, 255, 1), Accent.blue),
  aurora(Color.fromRGBO(2, 8, 11, 1), Color.fromRGBO(5, 77, 77, 1), Color.fromRGBO(143, 255, 199, 1), Accent.mint),
  sunset(Color.fromRGBO(15, 3, 10, 1), Color.fromRGBO(133, 28, 56, 1), Color.fromRGBO(255, 163, 84, 1), Accent.coral),

  /// Frosted ice: the surfaces are layered glass over a slow, cold background (glass.dart).
  glass(Color.fromRGBO(4, 16, 28, 1), Color.fromRGBO(28, 79, 115, 1), Color.fromRGBO(207, 239, 255, 1), Accent.ice);

  const LookStyle(this.deep, this.middle, this.bright, this.defaultAccent);

  /// Deep, middle and bright tones the shader blends.
  final Color deep;
  final Color middle;
  final Color bright;
  final Accent defaultAccent;

  String get title => T.text(switch (this) {
    LookStyle.cosmic => 'themeCosmic',
    LookStyle.aurora => 'themeAurora',
    LookStyle.sunset => 'themeSunset',
    LookStyle.glass => 'themeGlass',
  });

  /// The look kept as [index] in the preferences; anything unknown (a newer launcher's look,
  /// a hand-edited file) is Cosmic.
  static LookStyle fromIndex(Object? index) =>
      index is int && index >= 0 && index < values.length ? values[index] : LookStyle.cosmic;

  /// Deep, middle and bright together.
  ThemePalette get palette => (deep: deep, middle: middle, bright: bright);

  /// The theme's colors as #RRGGBB, for the phone to wear.
  static String hex(Color color) =>
      '#${[color.r, color.g, color.b].map((c) => (c * 255).round().toRadixString(16).padLeft(2, '0')).join().toUpperCase()}';
}

/// The background's deep, middle and bright tones (a built-in look's, or a custom theme's).
typedef ThemePalette = ({Color deep, Color middle, Color bright});

/// The accent in use: one of [Accent]'s, or a custom theme's own colour.
class AccentChoice {
  const AccentChoice(this.color, {this.index});
  final Color color;

  /// The built-in accent's place in [Accent.values]; null for a theme's own colour.
  final int? index;

  /// The ink for words and glyphs drawn on this accent.
  Color get ink => Contrast.inkOn(color);
}

enum Accent {
  blue(Color.fromRGBO(79, 148, 255, 1)),
  mint(Color.fromRGBO(92, 235, 189, 1)),
  coral(Color.fromRGBO(255, 128, 102, 1)),
  violet(Color.fromRGBO(168, 133, 255, 1)),
  gold(Color.fromRGBO(255, 204, 92, 1)),
  white(Color.fromRGBO(240, 240, 240, 1)),
  ice(Color.fromRGBO(138, 216, 255, 1));

  const Accent(this.color);
  final Color color;

  /// The colour's name in the launcher's language: accentBlue, accentMint, … in assets/l10n.
  String get title => T.text('accent${name[0].toUpperCase()}${name.substring(1)}');

  /// The ink for words and glyphs drawn on this accent: dark on the light ones.
  Color get ink => Contrast.inkOn(color);
}

/// Which ink reads on a fill, by the WCAG formulas.
abstract final class Contrast {
  /// The dark ink used on light fills: a deep navy rather than black, so it sits with the
  /// glass look's colors.
  static const darkInk = Color(0xFF071422);
  static const lightInk = Color(0xFFFFFFFF);

  /// Dark ink on a fill lighter than 0.4 relative luminance, white otherwise.
  static Color inkOn(Color fill) => luminance(fill) > 0.4 ? darkInk : lightInk;

  /// WCAG 2 relative luminance of an opaque color.
  static double luminance(Color color) {
    double channel(double c) => c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
    return 0.2126 * channel(color.r) + 0.7152 * channel(color.g) + 0.0722 * channel(color.b);
  }

  /// WCAG 2 contrast ratio between two opaque colors, 1 to 21.
  static double ratio(Color a, Color b) {
    final (la, lb) = (luminance(a), luminance(b));
    return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
  }
}

/// Timings used across the interface: quick to respond, no wobble on small moves. The springs
/// of the macOS launcher, as curves.
abstract final class Motion {
  static bool reduced = false;

  /// Nothing the user waits for takes longer than 200 ms: a layer that fades in slowly reads
  /// as lag between the screen before and the next.
  static Duration get focus => Duration(milliseconds: reduced ? 100 : 160);
  static Duration get layout => Duration(milliseconds: reduced ? 120 : 200);
  static Duration get fade => Duration(milliseconds: reduced ? 120 : 200);
  static Duration get overlay => Duration(milliseconds: reduced ? 120 : 180);

  /// A strong ease-out: starts fast, settles softly.
  static const Curve settle = Cubic(0.22, 1, 0.36, 1);
  static const Curve inOut = Cubic(0.65, 0, 0.35, 1);
}

/// The game right before the selected one stays on the home tile row, dimmed and partly past the
/// window's edge, as on the console. Both values tune that look: a shift of 0 keeps the selected
/// tile aligned with the hero title and shows a thinner strip of the previous tile.
const double tilePeekShift = 28;
const double tilePeekOpacity = 0.4;

/// Text styles: Figtree, white over the background.
abstract final class AppText {
  static const family = 'Figtree';

  static TextStyle display(double size, {FontWeight weight = FontWeight.w400, Color? color, double? height}) =>
      TextStyle(
        fontFamily: family,
        fontSize: size,
        fontWeight: weight,
        color: color ?? const Color(0xFFFFFFFF),
        height: height,
        letterSpacing: size >= 40 ? -0.02 * size : (size <= 13 ? 0.1 : 0),
        fontFeatures: const [FontFeature.tabularFigures()],
      );
}

/// Colors that mean something everywhere.
abstract final class Palette {
  static const warning = Color.fromRGBO(255, 209, 102, 1);
  static const danger = Color.fromRGBO(255, 153, 140, 1);
  static const success = Color.fromRGBO(77, 217, 115, 1);
  static const connecting = Color.fromRGBO(255, 158, 51, 1);
}

/// The PlayStation face buttons.
enum PadGlyph { cross, circle, square, triangle }
