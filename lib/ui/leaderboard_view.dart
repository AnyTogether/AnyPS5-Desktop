import 'dart:async';

import 'package:flutter/material.dart';

import '../core/together/social.dart';
import 'app_model.dart';
import 'challenge_view.dart';
import 'components.dart';
import 'glass.dart';
import 'level_badge.dart';
import 'panels.dart';
import 'strings.dart';
import 'theme.dart';
import 'together_model.dart';

/// A leaderboard on AnyTogether: a game's by points, play time or completion, or overall trophy
/// points, among friends or everyone. The board and its lines on the left, the user's own place
/// on the right. Up and down move through the people, left and right through a game's boards,
/// △ switches between friends and everyone, Enter opens a profile.
class LeaderboardView extends StatelessWidget {
  const LeaderboardView({super.key, required this.model});

  final AppModel model;

  /// The first three places' colours, as the trophies' grades.
  static Color? medal(int rank) => switch (rank) {
    1 => const Color(0xFFF2C14E),
    2 => const Color(0xFFC0C6CF),
    3 => const Color(0xFFC98A5B),
    _ => null,
  };

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final together = model.together;
    final screens = together.screens;
    final accent = model.accentChoice.color;
    final titleId = screens.boardTitleId;
    final local = titleId == null ? null : model.games.where((game) => game.titleId == titleId).firstOrNull;
    final title = titleId == null
        ? T.text('socialBoardOverall')
        : (screens.boardName.isEmpty ? together.gameName(titleId) : screens.boardName);
    final board = screens.board;
    final onChallenges = screens.boardOnChallenges && screens.boardChallenges.isNotEmpty;
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
                              titleId == null ? Icons.star_rounded : Icons.leaderboard_rounded,
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
                        T.upper(T.text('socialBoardTitle')),
                        style: AppText.display(
                          12 * scale,
                          weight: FontWeight.w700,
                          color: accent,
                        ).copyWith(letterSpacing: 1.4 * scale),
                      ),
                      SizedBox(height: 6 * scale),
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.display(40 * scale, weight: FontWeight.w300, height: 1.1),
                      ),
                    ],
                  ),
                ),
                // Room for the Back pill in the corner.
                SizedBox(width: 120 * scale),
              ],
            ),
            SizedBox(height: 28 * scale),
            // The challenges on this board; nothing at all when there are none.
            AnimatedSize(
              duration: Motion.layout,
              curve: Motion.settle,
              alignment: AlignmentDirectional.topStart,
              child: screens.boardChallenges.isEmpty
                  ? const SizedBox(width: double.infinity)
                  : Padding(
                      padding: EdgeInsets.only(bottom: 24 * scale),
                      child: ChallengeStrip(model: model),
                    ),
            ),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            if (titleId != null)
                              for (final kind in GameBoard.values) ...[
                                _Tab(
                                  text: TogetherSocial.boardName(kind),
                                  selected: screens.boardKind == kind,
                                  onTap: () => together.setBoardKind(kind),
                                ),
                                SizedBox(width: 8 * scale),
                              ],
                            const Spacer(),
                            _ScopeSwitch(model: model),
                            if (board != null && board.total > 0) ...[
                              SizedBox(width: 14 * scale),
                              Text(
                                T.format(board.total == 1 ? 'socialBoardPlayersOne' : 'socialBoardPlayers', [
                                  board.total,
                                ]),
                                style: AppText.display(
                                  14 * scale,
                                  weight: FontWeight.w500,
                                  color: Colors.white.withValues(alpha: 0.5),
                                ),
                              ),
                            ],
                          ],
                        ),
                        SizedBox(height: 18 * scale),
                        Expanded(child: _Lines(model: model)),
                      ],
                    ),
                  ),
                  SizedBox(width: 36 * scale),
                  SizedBox(
                    width: 330 * scale,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (board != null) _RankCard(model: model, board: board),
                        const Spacer(),
                        Wrap(
                          spacing: 10 * scale,
                          runSpacing: 8 * scale,
                          children: [
                            Hint(keys: '↑ ↓', label: T.text('hintMove')),
                            if (onChallenges)
                              Hint(keys: '← →', label: T.text('challengeHintMove'))
                            else if (titleId != null)
                              Hint(keys: '← →', label: T.text('socialHintBoard')),
                            Hint(
                              keys: 'O',
                              glyph: PadGlyph.triangle,
                              label: T.text('socialHintScope'),
                              action: HintAction.options,
                            ),
                            Hint(
                              keys: 'Enter',
                              glyph: PadGlyph.cross,
                              label: T.text(onChallenges ? 'challengeHintOpen' : 'socialHintProfile'),
                              action: HintAction.select,
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

/// A game's board to read: points, play time or completion.
class _Tab extends StatelessWidget {
  const _Tab({required this.text, required this.selected, required this.onTap});

  final String text;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return Semantics(
      container: true,
      button: true,
      selected: selected,
      label: text,
      onTap: onTap,
      excludeSemantics: true,
      child: Pressable(
        onTap: onTap,
        builder: (context, hovering) => AnimatedContainer(
          duration: Motion.focus,
          curve: Motion.settle,
          padding: EdgeInsets.symmetric(horizontal: 16 * scale, vertical: 8 * scale),
          decoration: BoxDecoration(
            color: selected ? Colors.white : Colors.white.withValues(alpha: hovering ? 0.16 : 0.08),
            borderRadius: BorderRadius.circular(20 * scale),
          ),
          child: Text(
            text,
            style: AppText.display(
              15 * scale,
              weight: FontWeight.w600,
              color: selected ? LookScope.focusedInk(context) : Colors.white.withValues(alpha: 0.85),
            ),
          ),
        ),
      ),
    );
  }
}

/// Friends or everyone, side by side; the one shown is filled.
class _ScopeSwitch extends StatelessWidget {
  const _ScopeSwitch({required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final together = model.together;
    final current = together.screens.boardScope;
    Widget side(BoardScope scope, String text) {
      final selected = current == scope;
      return Semantics(
        container: true,
        button: true,
        selected: selected,
        label: text,
        onTap: () => together.setBoardScope(scope),
        excludeSemantics: true,
        child: Pressable(
          onTap: () => together.setBoardScope(scope),
          builder: (context, hovering) => AnimatedContainer(
            duration: Motion.focus,
            curve: Motion.settle,
            padding: EdgeInsets.symmetric(horizontal: 14 * scale, vertical: 6 * scale),
            decoration: BoxDecoration(
              color: selected
                  ? model.accentChoice.color.withValues(alpha: 0.9)
                  : Colors.white.withValues(alpha: hovering ? 0.12 : 0),
              borderRadius: BorderRadius.circular(16 * scale),
            ),
            child: Text(
              text,
              style: AppText.display(
                14 * scale,
                weight: FontWeight.w600,
                color: Colors.white.withValues(alpha: selected ? 1 : 0.7),
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: EdgeInsets.all(3 * scale),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(19 * scale),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          side(BoardScope.friends, T.text('socialScopeFriends')),
          side(BoardScope.global, T.text('socialScopeGlobal')),
        ],
      ),
    );
  }
}

class _Lines extends StatelessWidget {
  const _Lines({required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final together = model.together;
    final screens = together.screens;
    final board = screens.board;
    final lines = together.boardLines;
    // While the keys are on the challenges, no line is lit.
    final at = screens.boardOnChallenges && screens.boardChallenges.isNotEmpty ? -1 : screens.boardIndex;
    final note = board == null
        ? T.text(
            screens.boardMissing
                ? 'socialBoardNoGame'
                : screens.boardFailed
                ? 'socialBoardFailed'
                : 'socialBoardLoading',
          )
        : board.entries.isEmpty && board.around.isEmpty
        ? (board.listed ? T.text('socialBoardEmpty') : null)
        : null;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (note != null)
            Text(note, style: AppText.display(17 * scale, color: Colors.white.withValues(alpha: 0.6), height: 1.4)),
          if (board != null)
            for (var index = 0; index < lines.length; index++)
              KeepVisible(
                active: at == index,
                child: switch (lines[index]) {
                  BoardPerson(:final entry, :final me) => _EntryRow(
                    key: ValueKey('board-${entry.user.id}'),
                    model: model,
                    entry: entry,
                    me: me,
                    board: board.board,
                    focused: at == index,
                    onTap: () => unawaited(together.openProfile(entry.user.handle, card: entry.user)),
                  ),
                  BoardGap() => Padding(
                    padding: EdgeInsets.symmetric(vertical: 4 * scale),
                    child: Center(
                      child: Icon(
                        Icons.more_horiz_rounded,
                        size: 22 * scale,
                        color: Colors.white.withValues(alpha: 0.4),
                      ),
                    ),
                  ),
                  BoardUnlisted(:final rank, :final value) => _UnlistedRow(
                    model: model,
                    rank: rank,
                    value: value,
                    board: board.board,
                    focused: at == index,
                  ),
                },
              ),
        ],
      ),
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({
    super.key,
    required this.model,
    required this.entry,
    required this.me,
    required this.board,
    required this.focused,
    required this.onTap,
  });

  final AppModel model;
  final BoardEntry entry;
  final bool me;
  final String board;
  final bool focused;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final ink = focused ? LookScope.focusedInk(context) : Colors.white;
    final accent = model.accentChoice.color;
    final medal = LeaderboardView.medal(entry.rank);
    final identity = TogetherModel.shown(entry.user);
    return Semantics(
      container: true,
      button: true,
      selected: focused,
      label: [
        '${entry.rank}',
        identity.name,
        if (me) T.text('socialBoardYou'),
        TogetherSocial.boardValue(entry.value, board),
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
                : me
                ? accent.withValues(alpha: hovering ? 0.3 : 0.2)
                : Colors.white.withValues(alpha: hovering ? 0.1 : 0.05),
            borderRadius: BorderRadius.circular(14 * scale),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 58 * scale,
                child: Text(
                  '${entry.rank}',
                  style: AppText.display(
                    22 * scale,
                    weight: FontWeight.w700,
                    color: medal == null || focused ? ink.withValues(alpha: medal == null ? 0.55 : 1) : medal,
                  ),
                ),
              ),
              PersonAvatar(person: TogetherModel.card(entry.user), size: 40 * scale),
              SizedBox(width: 14 * scale),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            identity.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.display(17 * scale, weight: FontWeight.w600, color: ink),
                          ),
                        ),
                        if (entry.level case final level?) ...[
                          SizedBox(width: 8 * scale),
                          LevelBadgeView(level: level, size: 22 * scale),
                        ],
                        if (me) ...[
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
                    Text(
                      '@${entry.user.handle}',
                      style: AppText.display(13 * scale, color: ink.withValues(alpha: 0.55)),
                    ),
                  ],
                ),
              ),
              Text(
                TogetherSocial.boardValue(entry.value, board),
                style: AppText.display(17 * scale, weight: FontWeight.w600, color: ink),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The user, left off the board: where they would be, or that they have nothing to rank yet.
class _UnlistedRow extends StatelessWidget {
  const _UnlistedRow({
    required this.model,
    required this.rank,
    required this.value,
    required this.board,
    required this.focused,
  });

  final AppModel model;
  final int? rank;
  final int value;
  final String board;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final ink = focused ? LookScope.focusedInk(context) : Colors.white;
    final together = model.together;
    return AnimatedContainer(
      duration: Motion.focus,
      curve: Motion.settle,
      margin: EdgeInsets.only(top: 6 * scale),
      padding: EdgeInsets.symmetric(horizontal: 14 * scale, vertical: 12 * scale),
      decoration: BoxDecoration(
        color: focused ? Colors.white : Colors.transparent,
        borderRadius: BorderRadius.circular(14 * scale),
        border: Border.all(color: Colors.white.withValues(alpha: focused ? 0 : 0.18)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 58 * scale,
            child: Text(
              rank == null ? '–' : '${rank!}',
              style: AppText.display(22 * scale, weight: FontWeight.w700, color: ink.withValues(alpha: 0.4)),
            ),
          ),
          PersonAvatar(person: together.myCard, size: 40 * scale),
          SizedBox(width: 14 * scale),
          Expanded(
            child: Text(
              rank == null ? T.text('socialBoardNothing') : T.text('socialBoardUnlisted'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppText.display(14 * scale, color: ink.withValues(alpha: 0.75), height: 1.3),
            ),
          ),
          if (rank != null) ...[
            SizedBox(width: 12 * scale),
            Text(
              TogetherSocial.boardValue(value, board),
              style: AppText.display(17 * scale, weight: FontWeight.w600, color: ink.withValues(alpha: 0.6)),
            ),
          ],
        ],
      ),
    );
  }
}

/// The user's place: the rank in large, out of how many, and their value.
class _RankCard extends StatelessWidget {
  const _RankCard({required this.model, required this.board});

  final AppModel model;
  final Leaderboard board;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final accent = model.accentChoice.color;
    final rank = board.myRank;
    final medal = rank == null || !board.listed ? null : LeaderboardView.medal(rank);
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
          Text(
            T.upper(T.text('socialBoardYourRank')),
            style: AppText.display(
              12 * scale,
              weight: FontWeight.w700,
              color: Colors.white.withValues(alpha: 0.7),
            ).copyWith(letterSpacing: 1.2 * scale),
          ),
          SizedBox(height: 8 * scale),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                rank == null ? '–' : (board.listed ? '#$rank' : T.format('socialBoardWouldBe', [rank])),
                style: AppText.display(
                  board.listed ? 56 * scale : 30 * scale,
                  weight: FontWeight.w300,
                  color: medal ?? Colors.white,
                  height: 1,
                ),
              ),
              if (board.listed && board.total > 0) ...[
                SizedBox(width: 10 * scale),
                Text(
                  T.format('socialBoardOf', [board.total]),
                  style: AppText.display(
                    16 * scale,
                    weight: FontWeight.w500,
                    color: Colors.white.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ],
          ),
          SizedBox(height: 12 * scale),
          Text(
            TogetherSocial.boardValue(board.myValue, board.board),
            style: AppText.display(20 * scale, weight: FontWeight.w600),
          ),
          if (!board.listed) ...[
            SizedBox(height: 10 * scale),
            Text(
              T.text('socialBoardUnlisted'),
              style: AppText.display(13 * scale, color: Colors.white.withValues(alpha: 0.65), height: 1.35),
            ),
          ],
        ],
      ),
    );
  }
}
