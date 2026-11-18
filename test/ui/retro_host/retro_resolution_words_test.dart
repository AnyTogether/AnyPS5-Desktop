import 'package:anyps5_desktop/core/retro_host/retro_resolution.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter_test/flutter_test.dart';

/// The words of the in-game menu's internal resolution row: its values and the line under it.
void main() {
  test('the words of the internal resolution row', () {
    const four = RetroResolutionValue(value: '4', scale: 4, label: '4x');
    RetroResolutionChoice choice(RetroResolutionNote note) =>
        RetroResolutionChoice(key: 'k', values: const [four], selected: 0, active: four, note: note);
    expect(
      retroResolutionLabel(const RetroResolutionValue(value: '1x (Native)', scale: 1, label: '1x (Native)')),
      'Native',
    );
    expect(retroResolutionLabel(const RetroResolutionValue(value: '3', scale: 3, label: '3x (for 720p)')), '3x');
    expect(retroResolutionLabel(const RetroResolutionValue(value: '8', scale: null, label: '8x')), '8x');
    expect(retroResolutionDetail(choice(RetroResolutionNote.none)), T.text('retroResolutionDetail'));
    expect(retroResolutionDetail(choice(RetroResolutionNote.applying)), T.text('retroMenuOptionPendingDetail'));
    expect(retroResolutionDetail(choice(RetroResolutionNote.nextStart)), T.text('retroMenuOptionRestartDetail'));
    expect(
      retroResolutionDetail(choice(RetroResolutionNote.changesAtNextStart)),
      T.text('retroMenuOptionRestartOnlyDetail'),
    );
    expect(
      retroResolutionDetail(choice(RetroResolutionNote.refused)),
      "Your graphics card can't draw the resolution you saved, so the game uses 4x.",
    );
  });
}
