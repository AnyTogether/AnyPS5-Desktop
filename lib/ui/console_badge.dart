import 'package:flutter/material.dart';

import '../core/game_library.dart';
import 'components.dart';

enum PlayStationConsole {
  ps1('PlayStation'),
  ps2('PlayStation 2'),
  ps3('PlayStation 3'),
  ps4('PlayStation 4'),
  ps5('PlayStation 5');

  const PlayStationConsole(this.label);

  final String label;

  static PlayStationConsole forRetro(RetroPlatform platform) => switch (platform) {
    RetroPlatform.ps1 => ps1,
    RetroPlatform.ps2 => ps2,
    RetroPlatform.ps3 => ps3,
  };

  static PlayStationConsole? forGame(Game game) => switch (game.retro?.platform) {
    final platform? => forRetro(platform),
    null when game.titleId.startsWith('CUSA') => ps4,
    null when game.titleId.startsWith('PPSA') => ps5,
    null => null,
  };
}

class ConsoleBadge extends StatelessWidget {
  const ConsoleBadge({super.key, required this.console});

  final PlayStationConsole console;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final compact = console == PlayStationConsole.ps1;
    return SizedBox(
      width: 128 * scale,
      height: 76 * scale,
      child: Glass(
        radius: 14 * scale,
        child: Center(
          child: ConsoleLogo(
            console: console,
            width: (compact ? 54 : 100) * scale,
            height: (compact ? 42 : 28) * scale,
          ),
        ),
      ),
    );
  }
}

class ConsoleLogo extends StatelessWidget {
  const ConsoleLogo({super.key, required this.console, required this.width, required this.height});

  final PlayStationConsole console;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    height: height,
    child: FittedBox(
      fit: BoxFit.scaleDown,
      child: Text(
        console.name.toUpperCase(),
        semanticsLabel: console.label,
        style: const TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.w700),
      ),
    ),
  );
}
