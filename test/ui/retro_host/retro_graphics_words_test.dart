import 'package:anyps5_desktop/core/retro_host/retro_graphics.dart';
import 'package:anyps5_desktop/ui/retro_host/retro_graphics_words.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter_test/flutter_test.dart';

/// The words of the in-game menu's Graphics rows: their titles, values and the line under each.
void main() {
  RetroGraphicsChoice choice(RetroGraphicsSetting setting, [RetroGraphicsNote note = RetroGraphicsNote.none]) =>
      RetroGraphicsChoice(
        setting: setting,
        values: [for (final offer in setting.offers) RetroGraphicsValue(offer: offer, label: offer.level.name)],
        selected: 0,
        note: note,
      );

  test('each setting has its own title and line, and widescreen one per console', () {
    expect(
      [for (final setting in retroGraphicsSettings) retroGraphicsTitle(setting)],
      ['Smooth textures', 'Fix wobbly 3D', 'Widescreen', 'Sharper textures', 'Widescreen'],
    );
    expect(retroGraphicsDetail(choice(retroSmoothTextures)), T.text('retroSmoothTexturesDetail'));
    expect(retroGraphicsDetail(choice(retroFixWobbly3d)), T.text('retroFixWobbly3dDetail'));
    expect(retroGraphicsDetail(choice(retroSharperTextures)), T.text('retroSharperTexturesDetail'));
    expect(retroGraphicsDetail(choice(retroWidescreenPs1)), T.text('retroWidescreenPs1Detail'));
    expect(retroGraphicsDetail(choice(retroWidescreenPs2)), T.text('retroWidescreenPs2Detail'));
  });

  test('the line says when a chosen value takes effect', () {
    expect(
      retroGraphicsDetail(choice(retroFixWobbly3d, RetroGraphicsNote.applying)),
      T.text('retroMenuOptionPendingDetail'),
    );
    expect(
      retroGraphicsDetail(choice(retroWidescreenPs2, RetroGraphicsNote.nextStart)),
      T.text('retroMenuOptionRestartDetail'),
    );
    expect(
      retroGraphicsDetail(choice(retroWidescreenPs2, RetroGraphicsNote.changesAtNextStart)),
      T.text('retroMenuOptionRestartOnlyDetail'),
    );
  });

  test("the values: the launcher's words, or the host's label for one it does not offer", () {
    expect(
      [for (final value in choice(retroSmoothTextures).values) retroGraphicsLabel(value)],
      ['Off', 'Smooth', 'Extra smooth'],
    );
    expect([for (final value in choice(retroWidescreenPs1).values) retroGraphicsLabel(value)], ['Off', 'On']);
    expect(retroGraphicsLabel(const RetroGraphicsValue(offer: null, label: 'JINC2')), 'JINC2');
  });
}
