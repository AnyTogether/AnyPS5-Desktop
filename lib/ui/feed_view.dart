import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../core/together/social.dart';
import '../core/trophies.dart';
import 'app_model.dart';
import 'components.dart';
import 'glass.dart';
import 'level_badge.dart';
import 'panels.dart';
import 'strings.dart';
import 'theme.dart';
import 'together_model.dart';

/// Friends' activity on AnyTogether, laid out as a profile is: what the screen is on the left,
/// with its keys; the items on the right, newest first, each with the four reactions. Up and
/// down move through the items, left and right through the reactions, Enter reacts and △ opens
/// the person's profile.
class FeedView extends StatelessWidget {
  const FeedView({super.key, required this.model});

  final AppModel model;

  /// The reactions as the launcher draws them (the server's 🔥 👏 😮 ❤️), with their colours.
  static IconData icon(Reaction reaction) => switch (reaction) {
    Reaction.fire => Icons.local_fire_department_rounded,
    Reaction.clap => Icons.celebration_rounded,
    Reaction.wow => Icons.auto_awesome_rounded,
    Reaction.heart => Icons.favorite_rounded,
  };

  static Color color(Reaction reaction) => switch (reaction) {
    Reaction.fire => const Color(0xFFFF8A4C),
    Reaction.clap => const Color(0xFFF2C14E),
    Reaction.wow => const Color(0xFFB79CFF),
    Reaction.heart => const Color(0xFFFF5C8A),
  };

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final muted = Colors.white.withValues(alpha: 0.6);
    final accent = model.accentChoice.color;
    return LayerScrim(
      opacity: 0.64,
      child: Padding(
        padding: EdgeInsets.fromLTRB(90 * scale, 64 * scale, 90 * scale, 50 * scale),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 380 * scale,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(T.text('friendsTitle'), style: AppText.display(18 * scale, color: muted)),
                  SizedBox(height: 22 * scale),
                  Container(
                    width: 88 * scale,
                    height: 88 * scale,
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(24 * scale),
                      border: Border.all(color: accent.withValues(alpha: 0.35)),
                    ),
                    child: Icon(Icons.auto_awesome_rounded, size: 40 * scale, color: accent),
                  ),
                  SizedBox(height: 20 * scale),
                  Text(T.text('socialFeedTitle'), style: AppText.display(38 * scale, weight: FontWeight.w300)),
                  SizedBox(height: 10 * scale),
                  Text(
                    T.text('socialFeedSubtitle'),
                    style: AppText.display(15 * scale, color: Colors.white.withValues(alpha: 0.7), height: 1.4),
                  ),
                  SizedBox(height: 26 * scale),
                  // The reactions, each with what it stands for.
                  Row(
                    children: [
                      for (final reaction in Reaction.values) ...[
                        Icon(icon(reaction), size: 22 * scale, color: color(reaction)),
                        SizedBox(width: 14 * scale),
                      ],
                    ],
                  ),
                  const Spacer(),
                  Wrap(
                    spacing: 10 * scale,
                    runSpacing: 8 * scale,
                    children: [
                      Hint(keys: '↑ ↓', label: T.text('hintMove')),
                      Hint(
                        keys: 'Enter',
                        glyph: PadGlyph.cross,
                        label: T.text('socialHintReact'),
                        action: HintAction.select,
                      ),
                      Hint(
                        keys: 'O',
                        glyph: PadGlyph.triangle,
                        label: T.text('socialHintProfile'),
                        action: HintAction.options,
                      ),
                      Hint(keys: 'Esc', glyph: PadGlyph.circle, label: T.text('hintBack'), action: HintAction.back),
                    ],
                  ),
                ],
              ),
            ),
            SizedBox(width: 60 * scale),
            Expanded(child: _FeedList(model: model)),
          ],
        ),
      ),
    );
  }
}

class _FeedList extends StatelessWidget {
  const _FeedList({required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final together = model.together;
    final feed = together.hub.social.feed;
    final screens = together.screens;
    final note = !feed.loaded
        ? T.text(screens.feedFailed ? 'socialFeedFailed' : 'socialFeedLoading')
        : feed.items.isEmpty
        ? T.text('socialFeedEmpty')
        : null;
    return SingleChildScrollView(
      padding: EdgeInsets.only(top: 40 * scale, bottom: 12 * scale),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (note != null)
            Text(note, style: AppText.display(17 * scale, color: Colors.white.withValues(alpha: 0.6), height: 1.4)),
          for (var index = 0; index < feed.items.length; index++)
            KeepVisible(
              active: screens.feedIndex == index,
              child: _ActivityCard(
                key: ValueKey('activity-${feed.items[index].id}'),
                model: model,
                item: feed.items[index],
                focused: screens.feedIndex == index,
                reaction: screens.feedReaction,
                onTap: () => together.focusFeedItem(index),
              ),
            ),
          if (feed.loaded && feed.next != null)
            Padding(
              padding: EdgeInsets.only(top: 8 * scale),
              child: Text(
                T.text('socialFeedMore'),
                style: AppText.display(14 * scale, color: Colors.white.withValues(alpha: 0.45)),
              ),
            ),
        ],
      ),
    );
  }
}

/// One item: who, what, when, the trophies it holds, and the reactions.
class _ActivityCard extends StatelessWidget {
  const _ActivityCard({
    super.key,
    required this.model,
    required this.item,
    required this.focused,
    required this.reaction,
    required this.onTap,
  });

  final AppModel model;
  final Activity item;
  final bool focused;

  /// The reaction the keys are on, on the focused item.
  final int reaction;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final together = model.together;
    final ink = focused ? LookScope.focusedInk(context) : Colors.white;
    final local = item.game == null
        ? null
        : model.games.where((game) => game.titleId == item.game!.titleId).firstOrNull;
    final name = TogetherModel.shown(item.actor).name;
    final trophies = item.trophies.where((trophy) => trophy.name(T.language.code) != null).take(3).toList();
    final more = (item.trophyCount ?? item.trophies.length) - trophies.length;
    final highlight = switch (item.highlight) {
      'platinum' => (T.text('gradePlatinum'), TrophyView.gradeColor(TrophyGrade.platinum)),
      'rare' => (T.text('socialFeedRare'), const Color(0xFFB79CFF)),
      _ => null,
    };
    return Pressable(
      onTap: onTap,
      pressScale: 0.99,
      builder: (context, hovering) => AnimatedContainer(
        duration: Motion.focus,
        curve: Motion.settle,
        margin: EdgeInsets.only(bottom: 10 * scale),
        padding: EdgeInsets.fromLTRB(16 * scale, 16 * scale, 16 * scale, 14 * scale),
        decoration: BoxDecoration(
          color: focused ? Colors.white : Colors.white.withValues(alpha: hovering ? 0.1 : 0.06),
          borderRadius: BorderRadius.circular(16 * scale),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox.square(
              dimension: 52 * scale,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  PersonAvatar(person: TogetherModel.card(item.actor), size: 48 * scale),
                  if (item.kind == ActivityKind.levelUp && item.level != null)
                    PositionedDirectional(
                      end: -4 * scale,
                      bottom: -4 * scale,
                      child: LevelBadgeView(level: item.level!, size: 24 * scale),
                    ),
                ],
              ),
            ),
            SizedBox(width: 16 * scale),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ActivityLine(model: model, item: item, name: name, size: 17 * scale, ink: ink),
                  SizedBox(height: 6 * scale),
                  Row(
                    children: [
                      Text(
                        TogetherSocial.ago(item.createdAt),
                        style: AppText.display(13 * scale, weight: FontWeight.w500, color: ink.withValues(alpha: 0.55)),
                      ),
                      if (highlight != null) ...[
                        SizedBox(width: 10 * scale),
                        _Chip(text: highlight.$1, color: highlight.$2, focused: focused),
                      ],
                    ],
                  ),
                  if (trophies.isNotEmpty) ...[
                    SizedBox(height: 10 * scale),
                    Wrap(
                      spacing: 8 * scale,
                      runSpacing: 6 * scale,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        for (final trophy in trophies) _TrophyChip(trophy: trophy, ink: ink),
                        if (more > 0)
                          Text(
                            T.format('socialFeedAndMore', [more]),
                            style: AppText.display(
                              13 * scale,
                              weight: FontWeight.w500,
                              color: ink.withValues(alpha: 0.55),
                            ),
                          ),
                      ],
                    ),
                  ],
                  SizedBox(height: 12 * scale),
                  Row(
                    children: [
                      for (final choice in Reaction.values) ...[
                        _ReactionPill(
                          reaction: choice,
                          count: item.reactions.count(choice),
                          mine: item.reactions.mine == choice,
                          // The keys' choice shows on the focused item only.
                          chosen: focused && reaction == choice.index,
                          focused: focused,
                          onTap: () => unawaited(together.react(item, choice)),
                        ),
                        SizedBox(width: 8 * scale),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            if (local?.icon != null) ...[
              SizedBox(width: 16 * scale),
              ClipRRect(
                borderRadius: BorderRadius.circular(12 * scale),
                child: SizedBox.square(
                  dimension: 64 * scale,
                  child: ArtworkImage(path: local!.icon!, cacheWidth: 192),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.text, required this.color, required this.focused});

  final String text;
  final Color color;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    // On the white focused card the colour darkens to stay readable.
    final shown = focused ? Color.lerp(color, Colors.black, 0.45)! : color;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8 * scale, vertical: 2 * scale),
      decoration: BoxDecoration(
        color: color.withValues(alpha: focused ? 0.28 : 0.16),
        borderRadius: BorderRadius.circular(6 * scale),
      ),
      child: Text(
        T.upper(text),
        style: AppText.display(11 * scale, weight: FontWeight.w700, color: shown).copyWith(letterSpacing: 0.6 * scale),
      ),
    );
  }
}

class _TrophyChip extends StatelessWidget {
  const _TrophyChip({required this.trophy, required this.ink});

  final ActivityTrophy trophy;
  final Color ink;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final grade = TrophyGrade.values.where((grade) => grade.name == trophy.grade).firstOrNull ?? TrophyGrade.bronze;
    return Container(
      padding: EdgeInsetsDirectional.fromSTEB(7 * scale, 4 * scale, 10 * scale, 4 * scale),
      decoration: BoxDecoration(color: ink.withValues(alpha: 0.07), borderRadius: BorderRadius.circular(8 * scale)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.emoji_events_rounded, size: 15 * scale, color: TrophyView.gradeColor(grade)),
          SizedBox(width: 5 * scale),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 240 * scale),
            child: Text(
              trophy.name(T.language.code) ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.display(13 * scale, weight: FontWeight.w500, color: ink.withValues(alpha: 0.85)),
            ),
          ),
        ],
      ),
    );
  }
}

/// One of the four reactions under an item: its mark, how many gave it, the user's own filled,
/// the keys' choice ringed.
class _ReactionPill extends StatelessWidget {
  const _ReactionPill({
    required this.reaction,
    required this.count,
    required this.mine,
    required this.chosen,
    required this.focused,
    required this.onTap,
  });

  final Reaction reaction;
  final int count;
  final bool mine;
  final bool chosen;
  final bool focused;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final color = FeedView.color(reaction);
    final ink = focused ? LookScope.focusedInk(context) : Colors.white;
    return Pressable(
      onTap: onTap,
      builder: (context, hovering) => AnimatedContainer(
        duration: Motion.focus,
        curve: Motion.settle,
        height: 32 * scale,
        padding: EdgeInsets.symmetric(horizontal: 11 * scale),
        decoration: BoxDecoration(
          color: mine
              ? color.withValues(alpha: focused ? 0.32 : 0.22)
              : ink.withValues(alpha: hovering ? 0.14 : (focused ? 0.06 : 0.08)),
          borderRadius: BorderRadius.circular(16 * scale),
          border: Border.all(
            color: chosen ? ink : (mine ? color.withValues(alpha: 0.7) : Colors.transparent),
            width: chosen ? 2 * scale : 1 * scale,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              FeedView.icon(reaction),
              size: 17 * scale,
              color: focused && !mine ? Color.lerp(color, Colors.black, 0.2) : color,
            ),
            if (count > 0) ...[
              SizedBox(width: 6 * scale),
              Text(
                T.number(count),
                style: AppText.display(13 * scale, weight: FontWeight.w600, color: ink.withValues(alpha: 0.85)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Who did what, on up to two lines: the name, then what they did. The game's name in it opens the
/// game's hub when clicked, as the website links it to the game's page, and is underlined while
/// the pointer is on it. It looks the same as the rest of the line until then.
class ActivityLine extends StatefulWidget {
  const ActivityLine({
    super.key,
    required this.model,
    required this.item,
    required this.name,
    required this.size,
    required this.ink,
  });

  final AppModel model;
  final Activity item;
  final String name;
  final double size;
  final Color ink;

  @override
  State<ActivityLine> createState() => _ActivityLineState();
}

class _ActivityLineState extends State<ActivityLine> {
  late final TapGestureRecognizer _open = TapGestureRecognizer()
    ..onTap = () => widget.model.together.openActivityGame(widget.item);
  bool _hovering = false;

  @override
  void dispose() {
    _open.dispose();
    super.dispose();
  }

  void _hover(bool on) {
    if (_hovering != on) setState(() => _hovering = on);
  }

  @override
  Widget build(BuildContext context) {
    final together = widget.model.together;
    final text = together.activityText(widget.item);
    final game = together.activityGameName(widget.item);
    final at = game == null || game.isEmpty ? -1 : text.indexOf(game);
    final plain = AppText.display(widget.size, color: widget.ink.withValues(alpha: 0.82));
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: widget.name,
            style: AppText.display(widget.size, weight: FontWeight.w600, color: widget.ink),
          ),
          if (at < 0)
            TextSpan(text: ' $text', style: plain)
          else ...[
            TextSpan(text: ' ${text.substring(0, at)}', style: plain),
            TextSpan(
              text: game,
              style: plain.copyWith(
                decoration: _hovering ? TextDecoration.underline : TextDecoration.none,
                decorationColor: widget.ink.withValues(alpha: 0.45),
              ),
              recognizer: _open,
              mouseCursor: SystemMouseCursors.click,
              onEnter: (_) => _hover(true),
              onExit: (_) => _hover(false),
            ),
            TextSpan(text: text.substring(at + game!.length), style: plain),
          ],
        ],
      ),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// One item of someone's recent activity on their profile, as the Mac's profile column has it:
/// who and what on two lines, when, and the reactions it got as counts; reacting stays in the
/// feed.
class ProfileActivityRow extends StatelessWidget {
  const ProfileActivityRow({super.key, required this.model, required this.item, required this.focused});

  final AppModel model;
  final Activity item;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final ink = focused ? LookScope.focusedInk(context) : Colors.white;
    final local = item.game == null
        ? null
        : model.games.where((game) => game.titleId == item.game!.titleId).firstOrNull;
    final reactions = [for (final reaction in Reaction.values) if (item.reactions.count(reaction) > 0) reaction];
    return PaneRow(
      focused: focused,
      radius: 14 * scale,
      margin: EdgeInsets.only(bottom: 8 * scale),
      padding: EdgeInsets.all(12 * scale),
      child: Row(
        children: [
          PersonAvatar(person: TogetherModel.card(item.actor), size: 40 * scale),
          SizedBox(width: 14 * scale),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ActivityLine(
                  model: model,
                  item: item,
                  name: TogetherModel.shown(item.actor).name,
                  size: 15 * scale,
                  ink: ink,
                ),
                SizedBox(height: 5 * scale),
                Row(
                  children: [
                    Text(
                      TogetherSocial.ago(item.createdAt),
                      style: AppText.display(12 * scale, weight: FontWeight.w500, color: ink.withValues(alpha: 0.55)),
                    ),
                    for (final reaction in reactions) ...[
                      SizedBox(width: 12 * scale),
                      Icon(FeedView.icon(reaction), size: 14 * scale, color: FeedView.color(reaction)),
                      SizedBox(width: 4 * scale),
                      Text(
                        T.number(item.reactions.count(reaction)),
                        style: AppText.display(12 * scale, weight: FontWeight.w600, color: ink.withValues(alpha: 0.7)),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          if (local?.icon != null) ...[
            SizedBox(width: 14 * scale),
            ClipRRect(
              borderRadius: BorderRadius.circular(10 * scale),
              child: SizedBox.square(dimension: 48 * scale, child: ArtworkImage(path: local!.icon!, cacheWidth: 144)),
            ),
          ],
        ],
      ),
    );
  }
}
