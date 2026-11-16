import 'package:flutter/widgets.dart';

import 'retro_frame_view.dart';
import 'retro_host_focus.dart';
import 'retro_host_game.dart';

/// The picture of a [RetroHostGame], at the aspect ratio its status reports, pausing the game while
/// the launcher's window has no input focus.
class RetroHostGameView extends StatelessWidget {
  const RetroHostGameView({super.key, required this.game});

  final RetroHostGame game;

  @override
  Widget build(BuildContext context) {
    return RetroHostFocus(
      onFocusChanged: game.setFocused,
      child: ListenableBuilder(
        listenable: game,
        builder: (context, _) => RetroFrameView(image: game.picture, aspect: game.aspect),
      ),
    );
  }
}
