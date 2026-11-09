import 'package:flutter/material.dart';

import '../core/installer.dart' show InstallStep;
import 'app_model.dart';
import 'strings.dart';

/// How a game's main button reads: the usual press, something under way, or one that ends what
/// runs.
enum ActionTone { normal, busy, danger }

/// A game's main button, worked out from its state alone ([GameState]): its words, its icon, its
/// tone and the progress it carries. The press itself is [AppModel.primaryAction], which follows
/// the same state.
class GameAction {
  const GameAction(this.title, this.icon, {this.tone = ActionTone.normal, this.progress, this.indeterminate = false});

  final String title;
  final IconData icon;
  final ActionTone tone;

  /// The share done, drawn along the button; null for none.
  final double? progress;

  /// Under way for a while nobody can say (the engine's build, a start, a stop).
  final bool indeterminate;

  static GameAction of(GameState state) => switch (state) {
    Installed() => GameAction(T.text('play'), Icons.play_arrow_rounded),
    Locked() || Unreadable() => GameAction(T.text('unlock'), Icons.lock_open_rounded),
    Failed() => GameAction(T.text('retry'), Icons.refresh_rounded),
    Installing(preparing: true) => GameAction(T.text('playWhenReady'), Icons.play_arrow_rounded),
    // Updating (or unlocking to play): the button says so and carries the progress; the press
    // does not give it up (Game Settings › Cancel Update does).
    Installing(:final overall, :final step, :final fraction, :final updating, :final playsAfter)
        when updating || playsAfter =>
      GameAction(
        T.format(updating ? 'actionUpdating' : 'actionUnlocking', [T.percent((overall * 100).round())]),
        Icons.sync_rounded,
        tone: ActionTone.busy,
        progress: overall,
        // The relinker says nothing at first: under way rather than stuck at a share.
        indeterminate: step == InstallStep.relink && fraction == 0,
      ),
    Queued(waitingForEngine: true, updating: true) => GameAction(
      T.text('actionWaitingEngine'),
      Icons.hourglass_top_rounded,
      tone: ActionTone.busy,
      indeterminate: true,
    ),
    Queued(updating: true) => GameAction(
      T.text('actionWaitingUpdate'),
      Icons.hourglass_top_rounded,
      tone: ActionTone.busy,
    ),
    Installing() || Queued() => GameAction(T.text('cancel'), Icons.close_rounded),
    WaitingForEngine(forThisGame: true) => GameAction(
      T.text('actionUpdatingEngine'),
      Icons.construction_rounded,
      tone: ActionTone.busy,
      indeterminate: true,
    ),
    WaitingForEngine() => GameAction(T.text('actionWaitingEngine'), Icons.hourglass_top_rounded, tone: ActionTone.busy),
    Starting() => GameAction(
      T.text('starting'),
      Icons.hourglass_top_rounded,
      tone: ActionTone.busy,
      indeterminate: true,
    ),
    Running() => GameAction(T.text('running'), Icons.play_circle_outline_rounded),
    Stopping() => GameAction(
      T.text('actionStopping'),
      Icons.stop_circle_outlined,
      tone: ActionTone.danger,
      indeterminate: true,
    ),
    FamilyLocked() => GameAction(T.text('familyAskParent'), Icons.family_restroom_rounded),
  };
}
