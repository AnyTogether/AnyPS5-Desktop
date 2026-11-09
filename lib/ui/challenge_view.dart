import 'dart:async';

import 'package:flutter/material.dart';

import '../core/together/challenges.dart';
import 'app_model.dart';
import 'components.dart';
import 'glass.dart';
import 'leaderboard_view.dart';
import 'panels.dart';
import 'strings.dart';
import 'theme.dart';
import 'together_model.dart';

/// The sign of what counts: a star for trophy points, a cup for trophies, a clock for play time.
IconData _metricIcon(ChallengeMetric metric) => switch (metric) {
  ChallengeMetric.points => Icons.star_rounded,
  ChallengeMetric.trophies => Icons.emoji_events_rounded,
  ChallengeMetric.time => Icons.schedule_rounded,
  ChallengeMetric.other => Icons.flag_rounded,
};

/// The state's colour: running green, coming the accent, over and called off grey.
Color _stateColor(Challenge challenge, Color accent) => switch (challenge.state) {
  ChallengeState.active => Palette.success,
  ChallengeState.upcoming => accent,
  _ => Colors.white.withValues(alpha: 0.45),
};

/// The window as a track: how much of it has gone, start to end.
class _WindowTrack extends StatelessWidget {
  const _WindowTrack({required this.challenge, required this.color, required this.height, this.back});

  final Challenge challenge;
  final Color color;
  final double height;
  final Color? back;

  @override
  Widget build(BuildContext context) {
    final progress = TogetherChallenges.progress(challenge);
    return ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: SizedBox(
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: back ?? Colors.white.withValues(alpha: 0.12)),
            FractionallySizedBox(
              alignment: AlignmentDirectional.centerStart,
              widthFactor: progress,
              child: ColoredBox(color: color),
            ),
          ],
        ),
      ),
    );
  }
}

/// The challenges over a leaderboard: a game's running and coming ones, or the user's own over
/// the overall board. Up from the board's first line reaches them, left and right move
/// through them, select opens one. Not drawn at all when there are none.
class ChallengeStrip extends StatelessWidget {
  const ChallengeStrip({super.key, required this.model});

  final AppModel model;

  /// A card's width, so three sit side by side over the board.
  static const cardWidth = 340.0;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final together = model.together;
    final screens = together.screens;
    final list = screens.boardChallenges;
    final accent = model.accentChoice.color;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.flag_rounded, size: 15 * scale, color: accent),
            SizedBox(width: 6 * scale),
            Text(
              T.upper(T.text('challengeTitle')),
              style: AppText.display(
                12 * scale,
                weight: FontWeight.w700,
                color: accent,
              ).copyWith(letterSpacing: 1.4 * scale),
            ),
            SizedBox(width: 8 * scale),
            Text(
              '${list.length}',
              style: AppText.display(12 * scale, weight: FontWeight.w700, color: Colors.white.withValues(alpha: 0.45)),
            ),
          ],
        ),
        SizedBox(height: 10 * scale),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          clipBehavior: Clip.none,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var index = 0; index < list.length; index++) ...[
                if (index > 0) SizedBox(width: 12 * scale),
                KeepVisible(
                  active: screens.boardOnChallenges && screens.boardChallenge == index,
                  child: _ChallengeCard(
                    key: ValueKey('challenge-${list[index].id}'),
                    model: model,
                    challenge: list[index],
                    focused: screens.boardOnChallenges && screens.boardChallenge == index,
                    onTap: () => together.tapBoardChallenge(index),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _ChallengeCard extends StatelessWidget {
  const _ChallengeCard({
    super.key,
    required this.model,
    required this.challenge,
    required this.focused,
    required this.onTap,
  });

  final AppModel model;
  final Challenge challenge;
  final bool focused;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final together = model.together;
    final accent = model.accentChoice.color;
    final ink = focused ? LookScope.focusedInk(context) : Colors.white;
    final leader = challenge.leader;
    final place = challenge.joined ? challenge.myStanding : null;
    final dot = _stateColor(challenge, accent);
    final leaderLine = leader == null
        ? T.text(challenge.state == ChallengeState.upcoming ? 'challengeNotStarted' : 'challengeNoLeader')
        : '${T.text(challenge.state == ChallengeState.ended ? 'challengeWinner' : 'challengeLeading')}: '
              '${TogetherChallenges.standingName(leader)} · '
              '${TogetherChallenges.value(leader.value, challenge.metric)}';
    return Semantics(
      container: true,
      button: true,
      selected: focused,
      label: [
        challenge.title,
        together.challengeGame(challenge.game),
        TogetherChallenges.metricName(challenge.metric),
        TogetherChallenges.when(challenge),
        leaderLine,
        if (place != null) '${T.text('challengeYourPlace')} ${place.rank}',
      ].join(', '),
      onTap: onTap,
      excludeSemantics: true,
      child: Pressable(
        onTap: onTap,
        pressScale: 0.98,
        builder: (context, hovering) => AnimatedContainer(
          duration: Motion.focus,
          curve: Motion.settle,
          width: ChallengeStrip.cardWidth * scale,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: focused ? Colors.white : Colors.white.withValues(alpha: hovering ? 0.11 : 0.06),
            borderRadius: BorderRadius.circular(18 * scale),
            border: Border.all(
              color: challenge.joined && !focused ? accent.withValues(alpha: 0.45) : Colors.transparent,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(16 * scale, 13 * scale, 16 * scale, 11 * scale),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(_metricIcon(challenge.metric), size: 17 * scale, color: accent),
                        SizedBox(width: 8 * scale),
                        Expanded(
                          child: Text(
                            challenge.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.display(17 * scale, weight: FontWeight.w600, color: ink),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 3 * scale),
                    Text(
                      '${together.challengeGame(challenge.game)} · ${TogetherChallenges.metricName(challenge.metric)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.display(13 * scale, color: ink.withValues(alpha: 0.6)),
                    ),
                    SizedBox(height: 9 * scale),
                    Row(
                      children: [
                        Container(
                          width: 7 * scale,
                          height: 7 * scale,
                          decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
                        ),
                        SizedBox(width: 7 * scale),
                        Flexible(
                          child: Text(
                            TogetherChallenges.when(challenge),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.display(
                              13 * scale,
                              weight: FontWeight.w600,
                              color: ink.withValues(alpha: 0.85),
                            ),
                          ),
                        ),
                        SizedBox(width: 10 * scale),
                        Icon(Icons.group_rounded, size: 14 * scale, color: ink.withValues(alpha: 0.5)),
                        SizedBox(width: 4 * scale),
                        Text(
                          T.number(challenge.entrants),
                          style: AppText.display(
                            13 * scale,
                            weight: FontWeight.w600,
                            color: ink.withValues(alpha: 0.6),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 6 * scale),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            leaderLine,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.display(13 * scale, color: ink.withValues(alpha: 0.7)),
                          ),
                        ),
                        if (place != null) ...[
                          SizedBox(width: 8 * scale),
                          Container(
                            padding: EdgeInsets.symmetric(horizontal: 8 * scale, vertical: 2 * scale),
                            decoration: BoxDecoration(
                              color: accent.withValues(alpha: focused ? 0.2 : 0.3),
                              borderRadius: BorderRadius.circular(8 * scale),
                            ),
                            child: Text(
                              '${T.text('challengeYourPlace')} #${place.rank}',
                              style: AppText.display(11 * scale, weight: FontWeight.w700, color: ink),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              _WindowTrack(
                challenge: challenge,
                color: dot,
                height: 3 * scale,
                back: (focused ? Colors.black : Colors.white).withValues(alpha: 0.08),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One challenge: what counts and for whom, the window as a track, the standings with the
/// user's row lit, Join or Leave, and the website, where challenges are made.
class ChallengeDetailView extends StatelessWidget {
  const ChallengeDetailView({super.key, required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final together = model.together;
    final screens = together.screens;
    final accent = model.accentChoice.color;
    final detail = screens.challenge;
    final challenge = detail?.challenge;
    final local = challenge == null
        ? null
        : model.games.where((game) => game.titleId == challenge.game.titleId).firstOrNull;
    final eyebrow = challenge == null
        ? T.text('challengeOne')
        : '${T.text('challengeOne')} · ${together.challengeGame(challenge.game)}';
    return LayerScrim(
      opacity: 0.7,
      child: Padding(
        padding: EdgeInsets.fromLTRB(90 * scale, 56 * scale, 90 * scale, 44 * scale),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(22 * scale),
                  child: SizedBox.square(
                    dimension: 96 * scale,
                    child: local?.icon != null
                        ? ArtworkImage(path: local!.icon!, cacheWidth: 288)
                        : DecoratedBox(
                            decoration: BoxDecoration(color: accent.withValues(alpha: 0.16)),
                            child: Icon(
                              challenge == null ? Icons.flag_rounded : _metricIcon(challenge.metric),
                              size: 40 * scale,
                              color: accent,
                            ),
                          ),
                  ),
                ),
                SizedBox(width: 26 * scale),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        T.upper(eyebrow),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.display(
                          12 * scale,
                          weight: FontWeight.w700,
                          color: accent,
                        ).copyWith(letterSpacing: 1.4 * scale),
                      ),
                      SizedBox(height: 6 * scale),
                      Text(
                        challenge?.title ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.display(40 * scale, weight: FontWeight.w300, height: 1.1),
                      ),
                      if (challenge != null) ...[
                        SizedBox(height: 8 * scale),
                        Text(
                          [
                            TogetherChallenges.metricName(challenge.metric),
                            TogetherChallenges.audience(challenge),
                            if (challenge.creator case final creator?)
                              T.format('challengeMadeBy', [TogetherModel.shown(creator).name]),
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.display(16 * scale, color: Colors.white.withValues(alpha: 0.65)),
                        ),
                      ],
                    ],
                  ),
                ),
                // Room for the Back pill in the corner.
                SizedBox(width: 120 * scale),
              ],
            ),
            if (challenge?.description case final description? when description.isNotEmpty) ...[
              SizedBox(height: 16 * scale),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: 900 * scale),
                child: Text(
                  description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.display(15 * scale, color: Colors.white.withValues(alpha: 0.75), height: 1.4),
                ),
              ),
            ],
            SizedBox(height: 28 * scale),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: _Standings(model: model)),
                  SizedBox(width: 36 * scale),
                  SizedBox(
                    width: 330 * scale,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (challenge != null) _WindowCard(model: model, challenge: challenge),
                        if (challenge != null) ...[SizedBox(height: 16 * scale), _Actions(model: model)],
                        const Spacer(),
                        Wrap(
                          spacing: 10 * scale,
                          runSpacing: 8 * scale,
                          children: [
                            Hint(keys: '↑ ↓', label: T.text('hintMove')),
                            Hint(keys: '← →', label: T.text('challengeHintSides')),
                            if (together.challengeActions.length > 1)
                              Hint(
                                keys: 'O',
                                glyph: PadGlyph.triangle,
                                label: T.text(
                                  together.challengeActions.first == ChallengeAction.leave
                                      ? 'challengeLeave'
                                      : 'challengeJoin',
                                ),
                                action: HintAction.options,
                              ),
                            Hint(
                              keys: 'Esc',
                              glyph: PadGlyph.circle,
                              label: T.text('hintBack'),
                              action: HintAction.back,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The places: rank, picture, name, value; the user's row in the accent, a hidden player
/// without a name.
class _Standings extends StatelessWidget {
  const _Standings({required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final together = model.together;
    final screens = together.screens;
    final detail = screens.challenge;
    final challenge = detail?.challenge;
    final lines = together.challengeLines;
    final note = detail == null
        ? T.text(
            screens.challengeGone
                ? 'challengeGone'
                : screens.challengeFailed
                ? 'challengeFailed'
                : 'challengeLoading',
          )
        : lines.isEmpty
        ? T.text(challenge!.state == ChallengeState.upcoming ? 'challengeNotStarted' : 'challengeNoLeader')
        : null;
    final over = challenge != null && challenge.state == ChallengeState.ended;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          T.upper(T.text(over && challenge.isFinal ? 'challengeFinalStandings' : 'challengeStandings')),
          style: AppText.display(
            12 * scale,
            weight: FontWeight.w700,
            color: Colors.white.withValues(alpha: 0.6),
          ).copyWith(letterSpacing: 1.2 * scale),
        ),
        SizedBox(height: 14 * scale),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (note != null)
                  Text(
                    note,
                    style: AppText.display(17 * scale, color: Colors.white.withValues(alpha: 0.6), height: 1.4),
                  ),
                for (var index = 0; index < lines.length; index++)
                  KeepVisible(
                    active: screens.challengeIndex == index && !screens.challengeOnActions,
                    child: switch (lines[index]) {
                      final standing? => _StandingRow(
                        model: model,
                        standing: standing,
                        metric: challenge!.metric,
                        focused: screens.challengeIndex == index && !screens.challengeOnActions,
                        onTap: () {
                          screens
                            ..challengeIndex = index
                            ..challengeOnActions = false;
                          if (standing.user case final user?) {
                            unawaited(together.openProfile(user.handle, card: user));
                          } else {
                            model.refresh();
                          }
                        },
                      ),
                      null => Padding(
                        padding: EdgeInsets.symmetric(vertical: 4 * scale),
                        child: Center(
                          child: Icon(
                            Icons.more_horiz_rounded,
                            size: 22 * scale,
                            color: Colors.white.withValues(alpha: 0.4),
                          ),
                        ),
                      ),
                    },
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _StandingRow extends StatelessWidget {
  const _StandingRow({
    required this.model,
    required this.standing,
    required this.metric,
    required this.focused,
    required this.onTap,
  });

  final AppModel model;
  final ChallengeStanding standing;
  final ChallengeMetric metric;
  final bool focused;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final ink = focused ? LookScope.focusedInk(context) : Colors.white;
    final accent = model.accentChoice.color;
    final medal = LeaderboardView.medal(standing.rank);
    final user = standing.user;
    return Semantics(
      container: true,
      button: true,
      selected: focused,
      label: [
        '${standing.rank}',
        TogetherChallenges.standingName(standing),
        if (standing.me) T.text('socialBoardYou'),
        TogetherChallenges.value(standing.value, metric),
      ].join(', '),
      onTap: onTap,
      excludeSemantics: true,
      child: Pressable(
        onTap: onTap,
        pressScale: 0.99,
        builder: (context, hovering) => AnimatedContainer(
          duration: Motion.focus,
          curve: Motion.settle,
          margin: EdgeInsets.only(bottom: 6 * scale),
          padding: EdgeInsets.symmetric(horizontal: 14 * scale, vertical: 10 * scale),
          decoration: BoxDecoration(
            color: focused
                ? Colors.white
                : standing.me
                ? accent.withValues(alpha: hovering ? 0.3 : 0.2)
                : Colors.white.withValues(alpha: hovering ? 0.1 : 0.05),
            borderRadius: BorderRadius.circular(14 * scale),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 58 * scale,
                child: Text(
                  '${standing.rank}',
                  style: AppText.display(
                    22 * scale,
                    weight: FontWeight.w700,
                    color: medal == null || focused ? ink.withValues(alpha: medal == null ? 0.55 : 1) : medal,
                  ),
                ),
              ),
              if (user == null)
                Container(
                  width: 40 * scale,
                  height: 40 * scale,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: ink.withValues(alpha: 0.1)),
                  child: Icon(Icons.visibility_off_rounded, size: 18 * scale, color: ink.withValues(alpha: 0.5)),
                )
              else
                PersonAvatar(person: TogetherModel.card(user), size: 40 * scale),
              SizedBox(width: 14 * scale),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            TogetherChallenges.standingName(standing),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.display(
                              17 * scale,
                              weight: FontWeight.w600,
                              color: user == null ? ink.withValues(alpha: 0.6) : ink,
                            ),
                          ),
                        ),
                        if (standing.me) ...[
                          SizedBox(width: 8 * scale),
                          Container(
                            padding: EdgeInsets.symmetric(horizontal: 7 * scale, vertical: 2 * scale),
                            decoration: BoxDecoration(
                              color: focused ? accent.withValues(alpha: 0.25) : Colors.white.withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(6 * scale),
                            ),
                            child: Text(
                              T.upper(T.text('socialBoardYou')),
                              style: AppText.display(10 * scale, weight: FontWeight.w700, color: ink),
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (user != null)
                      Text('@${user.handle}', style: AppText.display(13 * scale, color: ink.withValues(alpha: 0.55))),
                  ],
                ),
              ),
              Text(
                TogetherChallenges.value(standing.value, metric),
                style: AppText.display(17 * scale, weight: FontWeight.w600, color: ink),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The window: its state, the time left, a track of how far through it is, how many are in it,
/// the user's place, and once over and final, the winner.
class _WindowCard extends StatelessWidget {
  const _WindowCard({required this.model, required this.challenge});

  final AppModel model;
  final Challenge challenge;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final accent = model.accentChoice.color;
    final color = _stateColor(challenge, accent);
    final place = challenge.joined ? challenge.myStanding : null;
    // Who is ahead while it runs, the winner once over and final.
    final decided = challenge.state == ChallengeState.ended && challenge.isFinal;
    final leader = challenge.leader;
    final leaderColor = decided ? LeaderboardView.medal(1) : null;
    final label = AppText.display(
      12 * scale,
      weight: FontWeight.w700,
      color: Colors.white.withValues(alpha: 0.7),
    ).copyWith(letterSpacing: 1.2 * scale);
    final now = TogetherChallenges.clock();
    final started = challenge.startsAt.isBefore(now);
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(22 * scale),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [accent.withValues(alpha: 0.28), accent.withValues(alpha: 0.08)],
        ),
        borderRadius: BorderRadius.circular(20 * scale),
        border: Border.all(color: accent.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8 * scale,
                height: 8 * scale,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              SizedBox(width: 8 * scale),
              Text(T.upper(TogetherChallenges.stateName(challenge)), style: label),
              const Spacer(),
              Icon(Icons.group_rounded, size: 15 * scale, color: Colors.white.withValues(alpha: 0.6)),
              SizedBox(width: 5 * scale),
              Text(
                T.format('challengeEntrants', [T.number(challenge.entrants)]),
                style: AppText.display(
                  13 * scale,
                  weight: FontWeight.w600,
                  color: Colors.white.withValues(alpha: 0.75),
                ),
              ),
            ],
          ),
          SizedBox(height: 12 * scale),
          Text(
            TogetherChallenges.when(challenge),
            style: AppText.display(26 * scale, weight: FontWeight.w300, height: 1.15),
          ),
          SizedBox(height: 14 * scale),
          _WindowTrack(challenge: challenge, color: color, height: 6 * scale),
          SizedBox(height: 7 * scale),
          Row(
            children: [
              Expanded(
                child: Text(
                  started
                      ? T.format('challengeStartedAgo', [TogetherSocial.ago(challenge.startsAt, now: now)])
                      : T.format('challengeStartsIn', [TogetherChallenges.span(challenge.startsAt.difference(now))]),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.display(12 * scale, color: Colors.white.withValues(alpha: 0.55)),
                ),
              ),
              Text(
                T.format('challengeLength', [TogetherChallenges.span(challenge.endsAt.difference(challenge.startsAt))]),
                style: AppText.display(12 * scale, color: Colors.white.withValues(alpha: 0.55)),
              ),
            ],
          ),
          SizedBox(height: 18 * scale),
          Text(
            T.upper(T.text(decided ? 'challengeWinner' : 'challengeLeading')),
            style: leaderColor == null ? label : label.copyWith(color: leaderColor),
          ),
          SizedBox(height: 8 * scale),
          if (leader == null)
            Text(
              T.text('challengeNoLeader'),
              style: AppText.display(14 * scale, color: Colors.white.withValues(alpha: 0.6)),
            )
          else
            Row(
              children: [
                if (leader.user case final user?)
                  PersonAvatar(person: TogetherModel.card(user), size: 34 * scale)
                else
                  Icon(Icons.emoji_events_rounded, size: 30 * scale, color: LeaderboardView.medal(1)),
                SizedBox(width: 10 * scale),
                Expanded(
                  child: Text(
                    TogetherChallenges.standingName(leader),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.display(18 * scale, weight: FontWeight.w600),
                  ),
                ),
                Text(
                  TogetherChallenges.value(leader.value, challenge.metric),
                  style: AppText.display(16 * scale, weight: FontWeight.w600, color: leaderColor ?? Colors.white),
                ),
              ],
            ),
          if (place != null) ...[
            SizedBox(height: 18 * scale),
            Text(T.upper(T.text('challengeYourPlace')), style: label),
            SizedBox(height: 6 * scale),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  '#${place.rank}',
                  style: AppText.display(
                    40 * scale,
                    weight: FontWeight.w300,
                    color: LeaderboardView.medal(place.rank) ?? Colors.white,
                    height: 1,
                  ),
                ),
                SizedBox(width: 12 * scale),
                Text(
                  TogetherChallenges.value(place.value, challenge.metric),
                  style: AppText.display(17 * scale, weight: FontWeight.w600),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Join or Leave, with what joining shows; and the website, where challenges are made.
class _Actions extends StatelessWidget {
  const _Actions({required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final together = model.together;
    final screens = together.screens;
    final challenge = screens.challenge?.challenge;
    final actions = together.challengeActions;
    bool focused(ChallengeAction action) =>
        screens.challengeOnActions && actions.elementAtOrNull(screens.challengeAction) == action;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final action in actions) ...[
          _ActionButton(
            model: model,
            action: action,
            focused: focused(action),
            busy: screens.challengeBusy && action != ChallengeAction.website,
            onTap: () => together.tapChallengeAction(action),
          ),
          if (action == ChallengeAction.join) ...[
            SizedBox(height: 8 * scale),
            Text(
              T.text('challengeJoinNote'),
              style: AppText.display(13 * scale, color: Colors.white.withValues(alpha: 0.6), height: 1.35),
            ),
          ],
          SizedBox(height: 10 * scale),
        ],
        if (challenge != null && challenge.mine && challenge.state.open)
          Text(
            T.text('challengeYoursNote'),
            style: AppText.display(13 * scale, color: Colors.white.withValues(alpha: 0.6), height: 1.35),
          ),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.model,
    required this.action,
    required this.focused,
    required this.busy,
    required this.onTap,
  });

  final AppModel model;
  final ChallengeAction action;
  final bool focused;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final accent = model.accentChoice.color;
    final primary = action == ChallengeAction.join;
    final website = action == ChallengeAction.website;
    final ink = focused ? LookScope.focusedInk(context) : Colors.white;
    final (text, icon) = switch (action) {
      ChallengeAction.join => (T.text('challengeJoin'), Icons.add_rounded),
      ChallengeAction.leave => (T.text('challengeLeave'), Icons.logout_rounded),
      ChallengeAction.website => (T.text('challengeMakeOnWeb'), Icons.open_in_new_rounded),
    };
    return Semantics(
      container: true,
      button: true,
      enabled: !busy,
      label: text,
      onTap: busy ? null : onTap,
      excludeSemantics: true,
      child: Pressable(
        onTap: busy ? null : onTap,
        builder: (context, hovering) => AnimatedContainer(
          duration: Motion.focus,
          curve: Motion.settle,
          padding: EdgeInsets.symmetric(horizontal: 18 * scale, vertical: website ? 10 * scale : 13 * scale),
          decoration: BoxDecoration(
            color: focused
                ? Colors.white
                : primary
                ? accent.withValues(alpha: hovering ? 1 : 0.9)
                : Colors.white.withValues(alpha: website ? (hovering ? 0.08 : 0) : (hovering ? 0.16 : 0.1)),
            borderRadius: BorderRadius.circular(24 * scale),
            border: Border.all(color: website && !focused ? Colors.white.withValues(alpha: 0.18) : Colors.transparent),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: (website ? 16 : 19) * scale,
                color: ink.withValues(alpha: busy ? 0.4 : 1),
              ),
              SizedBox(width: 8 * scale),
              Flexible(
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.display(
                    (website ? 14 : 16) * scale,
                    weight: FontWeight.w600,
                    color: ink.withValues(alpha: busy ? 0.4 : 1),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
