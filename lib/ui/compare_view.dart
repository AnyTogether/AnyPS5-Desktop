import 'dart:async';

import 'package:flutter/material.dart';

import '../core/together/levels.dart';
import '../core/together/people.dart';
import '../core/together/profiles.dart';
import '../core/trophies.dart';
import 'app_model.dart';
import 'components.dart';
import 'glass.dart';
import 'level_badge.dart';
import 'panels.dart';
import 'strings.dart';
import 'theme.dart';
import 'together_model.dart';

/// Comparing trophies with someone, laid out as their profile is: on the left who is compared
/// (or the game and the score), on the right the games either has trophies in, both-play first,
/// or one game's trophies with when each earned them.
class CompareView extends StatelessWidget {
  const CompareView({super.key, required this.model});

  final AppModel model;

  /// Their side's bar: a cool silver beside the accent of the user's.
  static const theirColor = Color(0xFFB9C6DE);

  /// 2026-10-21, as the profile's dates.
  static String day(DateTime time) {
    final local = time.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final together = model.together;
    final inGame = together.compareTitleId != null;
    return LayerScrim(
      opacity: 0.64,
      child: Padding(
        padding: EdgeInsets.fromLTRB(90 * scale, 64 * scale, 90 * scale, 50 * scale),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 380 * scale,
              child: inGame ? _GameSide(model: model) : _PeopleSide(model: model),
            ),
            SizedBox(width: 60 * scale),
            Expanded(
              child: inGame ? _TrophyList(model: model) : _GameList(model: model),
            ),
          ],
        ),
      ),
    );
  }
}

/// A note in place of a list: loading, private, failed or empty.
class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return Padding(
      padding: EdgeInsets.only(top: 6 * scale),
      child: Text(text, style: AppText.display(16 * scale, color: Colors.white.withValues(alpha: 0.55))),
    );
  }
}

String? _closed<V>(Section<V>? section, Person? them, {required bool empty, required String emptyText}) =>
    switch (section) {
      null => T.text('profileLoading'),
      SectionPrivate() => T.format('comparePrivate', [them?.displayName ?? '']),
      SectionFailed() => T.text('profileFailed'),
      SectionShown() => empty ? emptyText : null,
    };

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return Text(text, style: AppText.display(18 * scale, color: Colors.white.withValues(alpha: 0.6)));
  }
}

/// The user and the one compared, with their levels.
class _PeopleSide extends StatelessWidget {
  const _PeopleSide({required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final together = model.together;
    final them = together.compareWith;
    final me = together.user;
    final friend = them == null ? null : together.hub.friends.byId(them.id);
    final theirLevel = friend?.level ?? together.profile?.profile.trophyLevel;
    final games = together.compareGames?.value;
    Widget person(String name, String? avatar, LevelBadge? level) => SizedBox(
      width: 104 * scale,
      height: 104 * scale,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          PersonAvatar(
            person: PanelPerson(name: name, avatar: avatar),
            size: 96 * scale,
          ),
          if (level != null)
            PositionedDirectional(
              end: 0,
              bottom: 0,
              child: LevelBadgeView(level: level, size: 38 * scale),
            ),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Label(T.text('compareTrophies')),
        SizedBox(height: 22 * scale),
        Row(
          children: [
            person(me?.displayName ?? '', me?.avatar, together.hub.self.level),
            SizedBox(width: 14 * scale),
            Text(
              'VS',
              style: AppText.display(
                15 * scale,
                weight: FontWeight.w700,
                color: Colors.white.withValues(alpha: 0.45),
              ).copyWith(letterSpacing: 1.5 * scale),
            ),
            SizedBox(width: 14 * scale),
            person(them?.displayName ?? '', them?.avatar, theirLevel),
          ],
        ),
        SizedBox(height: 22 * scale),
        Text(
          T.format('compareTitle', [them?.displayName ?? '']),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: AppText.display(38 * scale, weight: FontWeight.w300),
        ),
        SizedBox(height: 10 * scale),
        Text(
          T.text('compareLead'),
          style: AppText.display(15 * scale, color: Colors.white.withValues(alpha: 0.7), height: 1.4),
        ),
        if (games != null && games.isNotEmpty) ...[
          SizedBox(height: 26 * scale),
          Row(
            children: [
              _Score(
                label: T.text('profileYou'),
                value: '${games.fold(0, (sum, game) => sum + (game.mine?.earned ?? 0))}',
                color: model.accentChoice.color,
              ),
              SizedBox(width: 12 * scale),
              _Score(
                label: them?.displayName ?? '',
                value: '${games.fold(0, (sum, game) => sum + (game.theirs?.earned ?? 0))}',
                color: CompareView.theirColor,
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// Trophies earned on one side, as the profile's totals look.
class _Score extends StatelessWidget {
  const _Score({required this.label, required this.value, required this.color});

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return Container(
      width: 178 * scale,
      padding: EdgeInsets.symmetric(horizontal: 18 * scale, vertical: 14 * scale),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(14 * scale),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: AppText.display(30 * scale, weight: FontWeight.w300)),
          SizedBox(height: 4 * scale),
          Row(
            children: [
              Container(
                width: 8 * scale,
                height: 8 * scale,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              SizedBox(width: 7 * scale),
              Expanded(
                child: Text(
                  T.upper(label),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.display(
                    11 * scale,
                    weight: FontWeight.w700,
                    color: Colors.white.withValues(alpha: 0.55),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text, {this.count});

  final String text;
  final int? count;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: 12 * scale, top: 6 * scale),
      child: Row(
        children: [
          Text(text, style: AppText.display(22 * scale, weight: FontWeight.w500)),
          if (count != null) ...[
            SizedBox(width: 10 * scale),
            Text(
              '$count',
              style: AppText.display(18 * scale, weight: FontWeight.w500, color: Colors.white.withValues(alpha: 0.45)),
            ),
          ],
        ],
      ),
    );
  }
}

/// The games either has trophies in.
class _GameList extends StatelessWidget {
  const _GameList({required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final together = model.together;
    final games = together.compareGames?.value ?? const <ComparedGame>[];
    final note = _closed(
      together.compareGames,
      together.compareWith,
      empty: games.isEmpty,
      emptyText: T.text('compareNoGames'),
    );
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Heading(T.text('profileGamesTitle'), count: games.isEmpty ? null : games.length),
          if (note != null) _Note(note),
          for (var index = 0; index < games.length; index++)
            KeepVisible(
              active: together.compareIndex == index,
              child: _ComparedGameRow(
                model: model,
                game: games[index],
                focused: together.compareIndex == index,
                onTap: () {
                  together.compareIndex = index;
                  model.refresh();
                  unawaited(together.openComparedGame(games[index]));
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _ComparedGameRow extends StatelessWidget {
  const _ComparedGameRow({required this.model, required this.game, required this.focused, required this.onTap});

  final AppModel model;
  final ComparedGame game;
  final bool focused;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final local = model.games.where((known) => known.titleId == game.titleId).firstOrNull;
    final ink = focused ? LookScope.focusedInk(context) : Colors.white;
    final them = model.together.compareWith?.displayName ?? '';
    Widget side(String label, CompareSide? side, Color color) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            side == null ? '$label · ${T.text('compareNotPlayed')}' : '$label · ${side.earned}/${side.total ?? '?'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.display(
              13 * scale,
              weight: FontWeight.w500,
              color: ink.withValues(alpha: side == null ? 0.45 : 0.75),
            ),
          ),
          SizedBox(height: 6 * scale),
          ProgressLine(fraction: (side?.progress ?? 0) / 100, color: color, height: 4 * scale),
        ],
      ),
    );
    String spoken(String label, CompareSide? side) =>
        side == null ? '$label, ${T.text('compareNotPlayed')}' : '$label, ${side.earned}/${side.total}';
    return Semantics(
      container: true,
      button: true,
      selected: focused,
      label: [
        local?.nameFor([T.language.code]) ?? game.name(T.language.code),
        spoken(T.text('profileYou'), game.mine),
        spoken(them, game.theirs),
      ].join(', '),
      onTap: onTap,
      excludeSemantics: true,
      child: Pressable(
        onTap: onTap,
        pressScale: 0.99,
        builder: (context, hovering) => AnimatedContainer(
          duration: Motion.focus,
          curve: Motion.settle,
          margin: EdgeInsets.only(bottom: 8 * scale),
          padding: EdgeInsets.all(12 * scale),
          decoration: BoxDecoration(
            color: focused ? Colors.white : Colors.white.withValues(alpha: hovering ? 0.1 : 0.06),
            borderRadius: BorderRadius.circular(14 * scale),
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10 * scale),
                child: SizedBox.square(
                  dimension: 56 * scale,
                  child: local?.icon != null
                      ? ArtworkImage(path: local!.icon!, cacheWidth: 160)
                      : ColoredBox(
                          color: Colors.white.withValues(alpha: 0.08),
                          child: Icon(
                            Icons.sports_esports_rounded,
                            size: 26 * scale,
                            color: ink.withValues(alpha: 0.5),
                          ),
                        ),
                ),
              ),
              SizedBox(width: 16 * scale),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      local?.nameFor([T.language.code]) ?? game.name(T.language.code),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.display(17 * scale, weight: FontWeight.w600, color: ink),
                    ),
                    SizedBox(height: 8 * scale),
                    Row(
                      children: [
                        side(T.text('profileYou'), game.mine, model.accentChoice.color),
                        SizedBox(width: 22 * scale),
                        side(them, game.theirs, focused ? const Color(0xFF59647A) : CompareView.theirColor),
                      ],
                    ),
                  ],
                ),
              ),
              SizedBox(width: 12 * scale),
              Icon(Icons.chevron_right_rounded, size: 24 * scale, color: ink.withValues(alpha: 0.5)),
            ],
          ),
        ),
      ),
    );
  }
}

/// The game compared, and the score.
class _GameSide extends StatelessWidget {
  const _GameSide({required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final together = model.together;
    final titleId = together.compareTitleId!;
    final view = together.comparison?.value;
    final listed = together.compareGames?.value?.where((game) => game.titleId == titleId).firstOrNull;
    final local = model.games.where((known) => known.titleId == titleId).firstOrNull;
    final name =
        local?.nameFor([T.language.code]) ??
        view?.gameName(T.language.code) ??
        listed?.name(T.language.code) ??
        titleId;
    Widget side(ComparedPerson person, String label, int score, int total, Color color) => Padding(
      padding: EdgeInsets.symmetric(vertical: 8 * scale),
      child: Row(
        children: [
          PersonAvatar(
            person: PanelPerson(name: person.person.displayName, avatar: person.person.avatar),
            size: 44 * scale,
          ),
          SizedBox(width: 12 * scale),
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.display(16 * scale, weight: FontWeight.w600),
                  ),
                ),
                if (person.level != null) ...[
                  SizedBox(width: 8 * scale),
                  LevelBadgeView(level: person.level!, size: 24 * scale),
                ],
              ],
            ),
          ),
          Container(
            width: 8 * scale,
            height: 8 * scale,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          SizedBox(width: 8 * scale),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(text: '$score'),
                TextSpan(
                  text: '/$total',
                  style: AppText.display(15 * scale, color: Colors.white.withValues(alpha: 0.5)),
                ),
              ],
            ),
            style: AppText.display(24 * scale, weight: FontWeight.w300),
          ),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Label(T.text('compareTrophies')),
        SizedBox(height: 22 * scale),
        ClipRRect(
          borderRadius: BorderRadius.circular(20 * scale),
          child: SizedBox.square(
            dimension: 104 * scale,
            child: local?.icon != null
                ? ArtworkImage(path: local!.icon!, cacheWidth: 240)
                : ColoredBox(
                    color: Colors.white.withValues(alpha: 0.08),
                    child: Icon(
                      Icons.sports_esports_rounded,
                      size: 40 * scale,
                      color: Colors.white.withValues(alpha: 0.45),
                    ),
                  ),
          ),
        ),
        SizedBox(height: 20 * scale),
        Text(
          name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: AppText.display(36 * scale, weight: FontWeight.w300, height: 1.15),
        ),
        SizedBox(height: 10 * scale),
        Text(T.text('compareGameLead'), style: AppText.display(15 * scale, color: Colors.white.withValues(alpha: 0.7))),
        if (view != null) ...[
          SizedBox(height: 24 * scale),
          Container(
            padding: EdgeInsetsDirectional.fromSTEB(16 * scale, 8 * scale, 18 * scale, 12 * scale),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(16 * scale),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: Column(
              children: [
                side(view.me, T.text('profileYou'), view.mine, view.total, model.accentChoice.color),
                Divider(height: 1, color: Colors.white.withValues(alpha: 0.08)),
                side(view.them, view.them.person.displayName, view.theirs, view.total, CompareView.theirColor),
                Divider(height: 1, color: Colors.white.withValues(alpha: 0.08)),
                SizedBox(height: 10 * scale),
                Text(
                  T.format('compareBoth', [view.both]),
                  style: AppText.display(13.5 * scale, color: Colors.white.withValues(alpha: 0.6)),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// One game's trophies: who earned each, and when.
class _TrophyList extends StatelessWidget {
  const _TrophyList({required this.model});

  final AppModel model;

  static double column(double scale) => 128 * scale;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final together = model.together;
    final view = together.comparison?.value;
    final trophies = view?.trophies ?? const <ComparedTrophy>[];
    final note = _closed(
      together.comparison,
      together.compareWith,
      empty: trophies.isEmpty,
      emptyText: T.text('compareNoTrophies'),
    );
    final header = AppText.display(
      12 * scale,
      weight: FontWeight.w700,
      color: Colors.white.withValues(alpha: 0.55),
    ).copyWith(letterSpacing: 1.1 * scale);
    final them = view?.them.person.displayName ?? together.compareWith?.displayName ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(child: _Heading(T.text('profileTrophies'), count: trophies.isEmpty ? null : trophies.length)),
            if (trophies.isNotEmpty) ...[
              SizedBox(
                width: column(scale),
                child: Padding(
                  padding: EdgeInsets.only(bottom: 16 * scale),
                  child: Text(T.upper(T.text('profileYou')), style: header, textAlign: TextAlign.center),
                ),
              ),
              SizedBox(
                width: column(scale) + 16 * scale,
                child: Padding(
                  padding: EdgeInsetsDirectional.only(bottom: 16 * scale, end: 16 * scale),
                  child: Text(
                    T.upper(them.split(' ').first),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: header,
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ],
          ],
        ),
        if (note != null) _Note(note),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var index = 0; index < trophies.length; index++)
                  KeepVisible(
                    active: together.comparisonIndex == index,
                    child: _ComparedTrophyRow(
                      trophy: trophies[index],
                      focused: together.comparisonIndex == index,
                      accent: model.accentChoice.color,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ComparedTrophyRow extends StatelessWidget {
  const _ComparedTrophyRow({required this.trophy, required this.focused, required this.accent});

  final ComparedTrophy trophy;
  final bool focused;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final ink = focused ? LookScope.focusedInk(context) : Colors.white;
    final grade = TrophyGrade.values.where((value) => value.name == trophy.grade).firstOrNull ?? TrophyGrade.bronze;
    final rarity = TogetherProfiles.rarity(trophy.rarityLabel);
    final percent = trophy.rarity == null
        ? null
        : T.percent(T.decimal(trophy.rarity! * 100, trophy.rarity! < 0.1 ? 1 : 0));
    final meta = [
      TrophyView.gradeName(grade),
      if (rarity.isNotEmpty) percent == null ? rarity : '$rarity · $percent',
    ].join(' · ');
    Widget when(DateTime? earned, Color color) => SizedBox(
      width: _TrophyList.column(scale),
      child: earned == null
          ? Text(
              T.text('compareNotYet'),
              textAlign: TextAlign.center,
              style: AppText.display(13 * scale, color: ink.withValues(alpha: 0.38)),
            )
          : Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.check_circle_rounded, size: 15 * scale, color: focused ? Colors.black87 : color),
                SizedBox(width: 6 * scale),
                Text(
                  CompareView.day(earned),
                  style: AppText.display(13 * scale, weight: FontWeight.w600, color: ink),
                ),
              ],
            ),
    );
    return PaneRow(
      focused: focused,
      radius: 14 * scale,
      margin: EdgeInsets.only(bottom: 8 * scale),
      padding: EdgeInsets.fromLTRB(16 * scale, 12 * scale, 16 * scale, 12 * scale),
      child: Row(
        children: [
          Icon(Icons.emoji_events_rounded, size: 28 * scale, color: TrophyView.gradeColor(grade)),
          SizedBox(width: 16 * scale),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  trophy.name(T.language.code) ?? T.text('trophyHidden'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.display(16 * scale, weight: FontWeight.w600, color: ink),
                ),
                SizedBox(height: 3 * scale),
                Text(
                  meta,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.display(13 * scale, color: ink.withValues(alpha: 0.6)),
                ),
              ],
            ),
          ),
          when(trophy.mine, accent),
          when(trophy.theirs, CompareView.theirColor),
        ],
      ),
    );
  }
}
