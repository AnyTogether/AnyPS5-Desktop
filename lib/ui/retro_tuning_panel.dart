import 'dart:async';

import 'app_model.dart';
import 'embedded_retro_game.dart';

PanelCategory retroTuningPanel(
  EmbeddedRetroGame session, {
  required void Function() resume,
  required void Function() openRestartTrials,
}) {
  final tuning = session.tuning;
  Future<void> record(Future<bool> Function() start) async {
    if (await start()) resume();
  }

  return PanelCategory(
    id: 'emulator-tune-game',
    title: 'Tune This Game',
    rows: [
      PanelRow(
        id: 'tuning-restart-trials',
        title: 'Restart Trials',
        detail: 'Compare graphics, CPU, renderer or I/O settings that need a restart.',
        kind: ActionRow(openRestartTrials),
      ),
      PanelRow(id: 'tuning-status', title: 'Gameplay test', kind: InfoRow(tuning.status)),
      if (tuning.canStartBaseline)
        PanelRow(
          id: 'tuning-baseline',
          title: 'Record baseline',
          detail: 'Resume and play a repeatable segment for about 10 seconds.',
          kind: ActionRow(() => unawaited(record(tuning.startBaseline))),
        ),
      if (tuning.baseline case final baseline?)
        PanelRow(id: 'tuning-baseline-result', title: 'Baseline', kind: InfoRow(baseline.summary)),
      if (tuning.changes.isNotEmpty)
        for (final (index, change) in tuning.changes.indexed)
          PanelRow(id: 'tuning-change-$index', title: change, kind: const InfoRow('')),
      if (tuning.canStartCandidate)
        PanelRow(
          id: 'tuning-candidate',
          title: 'Test candidate settings',
          detail: 'Repeat the baseline segment. Candidate settings are temporary.',
          kind: ActionRow(() => unawaited(record(tuning.startCandidate))),
        ),
      if (tuning.candidate case final candidate?)
        PanelRow(id: 'tuning-candidate-result', title: 'Candidate', kind: InfoRow(candidate.summary)),
      if (tuning.canApply)
        PanelRow(id: 'tuning-apply', title: 'Apply to this game', kind: ActionRow(() => unawaited(tuning.apply()))),
      if (tuning.canUndo)
        PanelRow(id: 'tuning-undo', title: 'Undo tuning', kind: ActionRow(() => unawaited(tuning.undo()))),
      if (tuning.canCancel)
        PanelRow(id: 'tuning-cancel', title: 'Cancel test', kind: ActionRow(() => unawaited(tuning.cancel()))),
    ],
  );
}
