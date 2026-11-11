import 'package:flutter/material.dart';

import 'app_model.dart';
import 'components.dart';
import 'game_delete_model.dart';
import 'glass.dart';
import 'profiles_view.dart';
import 'strings.dart';
import 'theme.dart';

/// A plain yes or no (Quit AnyPS5?, Close the game?, Delete the game?): a small card, the
/// question, a line when there is more to know (for a game to delete: where it is, how much it
/// takes, what goes and what stays), and the two answers side by side as pills. The way back on the left,
/// the one that cannot be undone on the right in red. ← and → move between them, Esc and Circle
/// are the way back, as on the Mac.
class ConfirmCard extends StatelessWidget {
  const ConfirmCard({super.key, required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final categories = model.panelCategories();
    if (categories.isEmpty) return const SizedBox.shrink();
    final category = categories.first;
    final rows = category.rows;
    // The answers in reading order: the way back first, the destructive one after it.
    final order = [
      for (var index = 0; index < rows.length; index++)
        if (!_destructive(rows[index])) index,
      for (var index = 0; index < rows.length; index++)
        if (_destructive(rows[index])) index,
    ];
    final destructive = rows.where(_destructive).firstOrNull;
    final detail = destructive?.detail;
    final quitting = model.overlay == Layer.confirmQuit;
    final deleting = model.overlay == Layer.confirmDeleteGame ? model.deletion.ask : null;
    final icon = model.overlay == Layer.closeGame ? model.running?.$1.icon : deleting?.game.icon;
    final profile = model.currentProfile;
    return LayerScrim(
      opacity: 0.55,
      child: Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
            key: const ValueKey('scrim-outside'),
            behavior: HitTestBehavior.opaque,
            onTap: () => model.handle(Command.back),
          ),
          Center(
            child: SizedBox(
              width: (deleting == null ? 500 : 580) * scale,
              child: Glass(
                radius: 26 * scale,
                opacity: 0.55,
                padding: EdgeInsets.fromLTRB(30 * scale, 28 * scale, 30 * scale, 26 * scale),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        // Who quits, or which game closes: the question is about them.
                        if (quitting && profile != null) ...[
                          ProfileTile(profile: profile, picture: model.profiles.pictureOf(profile), size: 48 * scale),
                          SizedBox(width: 16 * scale),
                        ] else if (icon != null) ...[
                          ClipRRect(
                            borderRadius: BorderRadius.circular(12 * scale),
                            child: SizedBox.square(
                              dimension: 48 * scale,
                              child: ArtworkImage(path: icon, cacheWidth: 160),
                            ),
                          ),
                          SizedBox(width: 16 * scale),
                        ],
                        Expanded(
                          child: Text(
                            category.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.display(28 * scale, weight: FontWeight.w400, height: 1.12),
                          ),
                        ),
                      ],
                    ),
                    if (deleting != null) ...[
                      SizedBox(height: 18 * scale),
                      _DeleteBody(ask: deleting, model: model),
                    ] else if (detail != null) ...[
                      SizedBox(height: 10 * scale),
                      Text(
                        detail,
                        style: AppText.display(14 * scale, color: Colors.white.withValues(alpha: 0.66), height: 1.35),
                      ),
                    ],
                    SizedBox(height: 24 * scale),
                    Row(
                      children: [
                        for (final (position, index) in order.indexed) ...[
                          if (position > 0) SizedBox(width: 12 * scale),
                          Expanded(
                            child: _Answer(
                              key: ValueKey('answer-${rows[index].id}'),
                              row: rows[index],
                              focused: index == model.panelRow,
                              back: !_destructive(rows[index]),
                              symbol: quitting
                                  ? Icons.power_settings_new_rounded
                                  : deleting == null
                                  ? Icons.close_rounded
                                  : deleting.permanent
                                  ? Icons.delete_forever_rounded
                                  : Icons.delete_outline_rounded,
                              onTap: () => model.activateRow(index),
                              onHover: () => model.hoverRow(index),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static bool _destructive(PanelRow row) => switch (row.kind) {
    ActionRow(:final destructive) => destructive,
    _ => false,
  };
}

/// What the Delete game card says before its answers: the game's folder as a file strip (its
/// path, what it takes on the disk, what goes with it), then what goes and what stays.
class _DeleteBody extends StatelessWidget {
  const _DeleteBody({required this.ask, required this.model});

  final DeleteAsk ask;
  final AppModel model;

  static const _amber = Color(0xFFFFB45C);
  static const _green = Color(0xFF6FD99A);

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final trash = model.deletion.trashName;
    final extras = model.deletion.extraNames;
    final faint = Colors.white.withValues(alpha: 0.6);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          key: const ValueKey('delete-files'),
          padding: EdgeInsets.fromLTRB(14 * scale, 12 * scale, 12 * scale, 12 * scale),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(16 * scale),
            border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: EdgeInsets.only(top: 1 * scale),
                child: Icon(Icons.folder_rounded, size: 20 * scale, color: Colors.white.withValues(alpha: 0.8)),
              ),
              SizedBox(width: 12 * scale),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // A path reads left to right in every language.
                    Directionality(
                      textDirection: TextDirection.ltr,
                      child: Text(
                        ask.plan.folder,
                        key: const ValueKey('delete-path'),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.display(13.5 * scale, weight: FontWeight.w500, height: 1.3),
                      ),
                    ),
                    if (extras.isNotEmpty) ...[
                      SizedBox(height: 6 * scale),
                      Text(
                        T.format('deleteGameWith', [extras.join(', ')]),
                        key: const ValueKey('delete-extras'),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.display(12.5 * scale, color: faint, height: 1.3),
                      ),
                    ],
                  ],
                ),
              ),
              SizedBox(width: 12 * scale),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 10 * scale, vertical: 4 * scale),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  byteText(ask.size),
                  key: const ValueKey('delete-size'),
                  style: AppText.display(13 * scale, weight: FontWeight.w700),
                ),
              ),
            ],
          ),
        ),
        SizedBox(height: 16 * scale),
        if (ask.permanent) ...[
          _line(scale, Icons.warning_amber_rounded, _amber, T.format('deleteGameNoTrash', [trash])),
          SizedBox(height: 10 * scale),
        ],
        _line(
          scale,
          ask.permanent ? Icons.delete_forever_rounded : Icons.delete_outline_rounded,
          Palette.danger,
          ask.permanent ? T.text('deleteGameGoesForever') : T.format('deleteGameGoes', [trash]),
        ),
        SizedBox(height: 10 * scale),
        _line(scale, Icons.verified_user_outlined, _green, T.text('deleteGameStays')),
      ],
    );
  }

  Widget _line(double scale, IconData symbol, Color tint, String text) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: EdgeInsets.only(top: 1 * scale),
        child: Icon(symbol, size: 18 * scale, color: tint),
      ),
      SizedBox(width: 12 * scale),
      Expanded(
        child: Text(
          text,
          style: AppText.display(13.5 * scale, color: Colors.white.withValues(alpha: 0.72), height: 1.38),
        ),
      ),
    ],
  );
}

/// One answer: a pill. Focused, the way back turns white and the destructive one red; the
/// fill and the words change together, so they never stand dark on dark mid-way.
class _Answer extends StatelessWidget {
  const _Answer({
    super.key,
    required this.row,
    required this.focused,
    required this.back,
    required this.symbol,
    required this.onTap,
    required this.onHover,
  });

  final PanelRow row;
  final bool focused;

  /// The way back: it wears the back key (Esc, or Circle with a controller).
  final bool back;

  /// The destructive answer's sign: the power sign to quit, a cross to close a game.
  final IconData symbol;
  final VoidCallback onTap;
  final VoidCallback onHover;

  static const _red = Color(0xFFDB403D);

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final viaPad = InputScope.pad(context);
    final ink = LookScope.focusedInk(context);
    return Semantics(
      button: true,
      label: row.title,
      child: Pressable(
        onTap: onTap,
        onHover: onHover,
        builder: (context, hovering) => TweenAnimationBuilder<double>(
          tween: Tween(end: focused ? 1 : 0),
          duration: Motion.focus,
          curve: Motion.settle,
          builder: (context, t, _) {
            final idleFill = Colors.white.withValues(alpha: hovering ? 0.14 : 0.08);
            final fill = Color.lerp(idleFill, back ? Colors.white : _red, t)!;
            final idleInk = back ? Colors.white : Palette.danger;
            final text = Color.lerp(idleInk, back ? ink : Colors.white, t)!;
            final glow = (back ? Colors.white : _red).withValues(alpha: 0.28 * t);
            return Container(
              height: 52 * scale,
              padding: EdgeInsets.symmetric(horizontal: 18 * scale),
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(26 * scale),
                border: Border.all(color: Colors.white.withValues(alpha: 0.1 * (1 - t))),
                boxShadow: [BoxShadow(color: glow, blurRadius: 18 * scale)],
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (!back) ...[Icon(symbol, size: 18 * scale, color: text), SizedBox(width: 8 * scale)],
                  Flexible(
                    child: Text(
                      row.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.display(16 * scale, weight: FontWeight.w600, color: text),
                    ),
                  ),
                  if (back) ...[
                    SizedBox(width: 10 * scale),
                    if (viaPad)
                      PadGlyphIcon(
                        Hint.circleConfirms ? PadGlyph.cross : PadGlyph.circle,
                        size: 13 * scale,
                        color: text.withValues(alpha: 0.55),
                      )
                    else
                      Text(
                        'Esc',
                        style: AppText.display(12 * scale, weight: FontWeight.w700, color: text.withValues(alpha: 0.5)),
                      ),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
