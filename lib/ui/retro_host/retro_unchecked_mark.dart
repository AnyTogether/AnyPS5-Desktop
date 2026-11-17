import 'package:flutter/material.dart';

import '../components.dart';
import '../strings.dart';
import '../theme.dart';

/// The small label in the window's bottom corner while a PS1 or PS2 game runs on a host that was not
/// checked: "Unchecked emulator (test build)", over the game, its loading and error screens
/// and every layer above them, so that no screenshot of the game passes for a release. Only a
/// debug or test build has it (`RetroHostPlaying.runsUnchecked`); a release is compiled without.
class RetroUncheckedMark extends StatelessWidget {
  const RetroUncheckedMark({super.key});

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return PositionedDirectional(
      start: 20 * scale,
      bottom: 20 * scale,
      child: IgnorePointer(
        child: DecoratedBox(
          key: const ValueKey('retro-unchecked-mark'),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(8 * scale),
            border: Border.all(color: Palette.warning.withValues(alpha: 0.45), width: scale),
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 10 * scale, vertical: 6 * scale),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.science_outlined, size: 14 * scale, color: Palette.warning),
                SizedBox(width: 6 * scale),
                Text(
                  T.text('retroHostUnchecked'),
                  style: AppText.display(
                    12 * scale,
                    weight: FontWeight.w500,
                    color: Colors.white.withValues(alpha: 0.85),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
