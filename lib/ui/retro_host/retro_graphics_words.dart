/// The words of the in-game menu's Graphics rows: each setting's title, the line under its row,
/// and its values' labels.
library;

import '../../core/retro_host/retro_graphics.dart';
import '../strings.dart';

/// The words under a Graphics row for [note]: what the setting does ([about], the key of its own
/// words) while its value is in effect, otherwise when the value chosen takes effect.
String retroGraphicsNoteDetail(RetroGraphicsNote note, {required String about}) => switch (note) {
  RetroGraphicsNote.applying => T.text('retroMenuOptionPendingDetail'),
  RetroGraphicsNote.nextStart => T.text('retroMenuOptionRestartDetail'),
  RetroGraphicsNote.changesAtNextStart => T.text('retroMenuOptionRestartOnlyDetail'),
  RetroGraphicsNote.none || RetroGraphicsNote.refused => T.text(about),
};

/// The words of a Graphics setting's title.
String retroGraphicsTitle(RetroGraphicsSetting setting) => T.text(switch (setting.kind) {
  RetroGraphicsKind.smoothTextures => 'retroSmoothTextures',
  RetroGraphicsKind.fixWobbly3d => 'retroFixWobbly3d',
  RetroGraphicsKind.widescreen => 'retroWidescreen',
  RetroGraphicsKind.sharperTextures => 'retroSharperTextures',
});

/// The words under a Graphics setting's row ([retroGraphicsNoteDetail]); widescreen says what it
/// does on each console.
String retroGraphicsDetail(RetroGraphicsChoice choice) => retroGraphicsNoteDetail(
  choice.note,
  about: switch (choice.setting.kind) {
    RetroGraphicsKind.smoothTextures => 'retroSmoothTexturesDetail',
    RetroGraphicsKind.fixWobbly3d => 'retroFixWobbly3dDetail',
    RetroGraphicsKind.widescreen => choice.setting.ps2 ? 'retroWidescreenPs2Detail' : 'retroWidescreenPs1Detail',
    RetroGraphicsKind.sharperTextures => 'retroSharperTexturesDetail',
  },
);

/// The words of a Graphics value: Off and On, Smooth and Extra smooth, or the host's own label for
/// a value the launcher does not offer.
String retroGraphicsLabel(RetroGraphicsValue value) => switch (value.offer?.level) {
  null => value.label,
  RetroGraphicsLevel.off => T.text('retroGraphicsValueOff'),
  RetroGraphicsLevel.on => T.text('retroGraphicsValueOn'),
  RetroGraphicsLevel.smooth => T.text('retroGraphicsValueSmooth'),
  RetroGraphicsLevel.extraSmooth => T.text('retroGraphicsValueExtraSmooth'),
};
