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
import 'profile_view.dart';
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
                  // The reactions, as the items show them.
                  Row(
                    children: [
                      for (final reaction in Reaction.values) ...[
                        Text(reaction.emoji, style: AppText.display(22 * scale)),
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
    final name = TogetherModel.shown(item.actor).name;
    // Hidden ones are shown too, labelled so.
    final trophies = item.trophies.take(3).toList();
    final more = (item.trophyCount ?? item.trophies.length) - trophies.length;
    final highlight = switch (item.highlight) {
      'platinum' => (T.text('gradePlatinum'), TrophyView.gradeColor(TrophyGrade.platinum)),
      'rare' => (T.text('socialFeedRare'), const Color(0xFFB79CFF)),
      _ => null,
    };
    // The card is read by its words; the reactions are their own buttons inside it.
    return Semantics(
      container: true,
      button: true,
      onTap: onTap,
      child: Pressable(
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
                          style: AppText.display(
                            13 * scale,
                            weight: FontWeight.w500,
                            color: ink.withValues(alpha: 0.55),
                          ),
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
                          for (final trophy in trophies) _TrophyChip(trophy: trophy, ink: ink, focused: focused),
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
                    // As tall on every item, so moving the focus moves nothing.
                    SizedBox(
                      height: 32 * scale,
                      child: Row(
                        children: [
                          // All four on the focused item; elsewhere only the ones someone chose.
                          for (final choice in Reaction.values)
                            if (focused || item.reactions.count(choice) > 0) ...[
                              _ReactionPill(
                                reaction: choice,
                                count: item.reactions.count(choice),
                                mine: item.reactions.mine == choice,
                                // The keys' choice shows on the focused item only.
                                chosen: focused && reaction == choice.index,
                                focused: focused,
                                accent: model.accentChoice.color,
                                onTap: () => unawaited(together.react(item, choice)),
                              ),
                              SizedBox(width: 8 * scale),
                            ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(width: 16 * scale),
              ActivityPicture(model: model, item: item, size: 64 * scale),
            ],
          ),
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
  const _TrophyChip({required this.trophy, required this.ink, required this.focused});

  final ActivityTrophy trophy;
  final Color ink;
  final bool focused;

  /// A share of players as the rarer trophies' colours show it: "3.1%", or "%3,1" in Turkish.
  static String _percent(double share) => T.percent(T.decimal(share * 100, 1));

  /// The colour of a rarity, darkened on the white focused card.
  static Color _rarityColor(String label, Color ink, bool focused) {
    final color = switch (label) {
      'ultra_rare' => const Color(0xFFFF9EE6),
      'very_rare' => const Color(0xFFAD99FF),
      'rare' => const Color(0xFF7AC7FF),
      _ => ink.withValues(alpha: 0.7),
    };
    return focused ? Color.lerp(color, Colors.black, 0.45)! : color;
  }

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final grade = TrophyGrade.values.where((grade) => grade.name == trophy.grade).firstOrNull ?? TrophyGrade.bronze;
    final name = trophy.name(T.language.code) ?? T.text('trophyHidden');
    final share = trophy.rarityLabel != 'common' ? trophy.rarity : null;
    return Semantics(
      label: [TrophyView.gradeName(grade), name, if (share != null) _percent(share)].join(', '),
      excludeSemantics: true,
      child: Container(
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
                trophy.name(T.language.code) ?? T.text('trophyHidden'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.display(13 * scale, weight: FontWeight.w500, color: ink.withValues(alpha: 0.85)),
              ),
            ),
            // Its share of players, on all but the common ones, as the Mac has it.
            if (trophy.rarityLabel case final label? when label != 'common')
              if (trophy.rarity case final share?) ...[
                SizedBox(width: 6 * scale),
                Text(
                  _percent(share),
                  style: AppText.display(13 * scale, weight: FontWeight.w600, color: _rarityColor(label, ink, focused)),
                ),
              ],
          ],
        ),
      ),
    );
  }
}

/// One of the four reactions under an item: its emoji, how many gave it, the user's own filled
/// in the accent, the keys' choice ringed, as the Mac draws them.
class _ReactionPill extends StatelessWidget {
  const _ReactionPill({
    required this.reaction,
    required this.count,
    required this.mine,
    required this.chosen,
    required this.focused,
    required this.accent,
    required this.onTap,
  });

  final Reaction reaction;
  final int count;
  final bool mine;
  final bool chosen;
  final bool focused;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final ink = focused ? LookScope.focusedInk(context) : Colors.white;
    final name = T.text(switch (reaction) {
      Reaction.fire => 'reactionFire',
      Reaction.clap => 'reactionClap',
      Reaction.wow => 'reactionWow',
      Reaction.heart => 'reactionLove',
    });
    return Semantics(
      container: true,
      button: true,
      selected: mine,
      label: count > 0 ? '$name, ${T.number(count)}' : name,
      onTap: onTap,
      excludeSemantics: true,
      child: Pressable(
        onTap: onTap,
        builder: (context, hovering) => AnimatedContainer(
          duration: Motion.focus,
          curve: Motion.settle,
          height: 32 * scale,
          padding: EdgeInsets.symmetric(horizontal: 11 * scale),
          decoration: BoxDecoration(
            color: mine
                ? accent.withValues(alpha: focused ? 0.55 : 0.45)
                : ink.withValues(alpha: hovering ? 0.14 : (focused ? 0.06 : 0.08)),
            borderRadius: BorderRadius.circular(16 * scale),
            border: Border.all(color: chosen ? ink : Colors.transparent, width: chosen ? 2 * scale : 1 * scale),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(reaction.emoji, style: AppText.display(17 * scale, color: ink)),
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
      ),
    );
  }
}

/// What an activity item is about, as the Mac shows it: the game's icon (this library's own, else
/// the server's picture, else a sign), the new friend's picture, or the milestone's sign.
class ActivityPicture extends StatelessWidget {
  const ActivityPicture({super.key, required this.model, required this.item, required this.size});

  final AppModel model;
  final Activity item;
  final double size;

  IconData get _milestoneIcon => switch (item.milestoneKind) {
    'platinums' => Icons.military_tech_rounded,
    'games' => Icons.sports_esports_rounded,
    'hours' => Icons.schedule_rounded,
    _ => Icons.emoji_events_rounded,
  };

  Widget _sign(IconData icon, Color color) => DecoratedBox(
    decoration: BoxDecoration(color: color.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(size * 0.2)),
    child: Center(
      child: Icon(icon, size: size * 0.38, color: color),
    ),
  );

  Widget _gameIcon(SocialGame game) {
    final local = model.games.where((known) => known.titleId == game.titleId).firstOrNull?.icon;
    final platinum = item.kind == ActivityKind.platinum;
    final sign = ColoredBox(
      color: Colors.white.withValues(alpha: 0.07),
      child: Center(
        child: Icon(
          platinum ? Icons.emoji_events_rounded : Icons.sports_esports_rounded,
          size: size * 0.34,
          color: platinum ? TrophyView.gradeColor(TrophyGrade.platinum) : Colors.white.withValues(alpha: 0.4),
        ),
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.2),
      child: local != null
          ? ArtworkImage(path: local, cacheWidth: (size * 3).round())
          : game.iconUrl != null
          ? Image(
              image: ProfileView.pictureFor(game.iconUrl!),
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => sign,
            )
          : sign,
    );
  }

  @override
  Widget build(BuildContext context) {
    final accent = model.accentChoice.color;
    final friend = item.friend;
    return SizedBox.square(
      dimension: size,
      child: switch (item.kind) {
        ActivityKind.friendship when friend != null => PersonAvatar(person: TogetherModel.card(friend), size: size),
        ActivityKind.milestone => _sign(_milestoneIcon, accent),
        _ when item.game != null => _gameIcon(item.game!),
        _ => _sign(Icons.auto_awesome_rounded, accent),
      },
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
    final reactions = [
      for (final reaction in Reaction.values)
        if (item.reactions.count(reaction) > 0) '${reaction.emoji} ${T.number(item.reactions.count(reaction))}',
    ].join('  ');
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
                    if (reactions.isNotEmpty) ...[
                      SizedBox(width: 12 * scale),
                      Text(
                        reactions,
                        style: AppText.display(12 * scale, weight: FontWeight.w600, color: ink.withValues(alpha: 0.7)),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          SizedBox(width: 14 * scale),
          ActivityPicture(model: model, item: item, size: 48 * scale),
        ],
      ),
    );
  }
}
