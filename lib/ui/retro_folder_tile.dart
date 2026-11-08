import 'package:flutter/material.dart';

import 'components.dart';
import 'console_badge.dart';

class RetroFolderTile extends StatelessWidget {
  const RetroFolderTile({super.key, required this.console, required this.size, required this.focused});

  final PlayStationConsole console;
  final double size;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    final radius = size * 0.12;
    return FocusRing(
      focused: focused,
      radius: radius,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          color: const Color(0xff20263a),
          border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Align(
              alignment: const Alignment(0, -0.1),
              child: ConsoleLogo(
                console: console,
                width: size * (console == PlayStationConsole.ps1 ? 0.54 : 0.72),
                height: size * 0.43,
              ),
            ),
            Align(
              alignment: const Alignment(0, 0.86),
              child: Icon(Icons.keyboard_arrow_down_rounded, size: size * 0.20, color: Colors.white70),
            ),
          ],
        ),
      ),
    );
  }
}
