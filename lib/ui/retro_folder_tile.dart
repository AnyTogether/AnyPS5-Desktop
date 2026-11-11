import 'package:flutter/material.dart';

import 'components.dart';
import '../core/game_library.dart';

class RetroFolderTile extends StatelessWidget {
  const RetroFolderTile({super.key, required this.console, required this.size, required this.focused});

  final RetroPlatform console;
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
              child: Text(
                console.name.toUpperCase(),
                style: TextStyle(color: Colors.white, fontSize: size * 0.22, fontWeight: FontWeight.w600),
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
