import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show kPrimaryMouseButton;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/controls.dart';
import '../core/gamepad/feel.dart' show HoldRepeater;
import '../core/replay_buffer.dart';
import '../core/screenshots.dart';
import '../core/trophies.dart';
import 'app_model.dart';
import 'clip_player.dart';
import 'components.dart';
import 'glass.dart';
import 'level_badge.dart';
import 'messages_view.dart';
import 'profile_picture.dart';
import 'home.dart';
import 'strings.dart';
import 'theme.dart';
import 'together_model.dart';

/// Every game as a grid, opened from the library button.
class LibraryGrid extends StatelessWidget {
  const LibraryGrid({super.key, required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final size = 196 * scale;
    return _Scrim(
      opacity: 0.74,
      child: WithBackPill(
        onBack: () => model.handle(Command.back),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 80 * scale, vertical: 60 * scale),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(T.text('library'), style: AppText.display(40 * scale, weight: FontWeight.w300)),
                  SizedBox(width: 14 * scale),
                  Padding(
                    padding: EdgeInsets.only(bottom: 6 * scale),
                    child: Text(
                      '${model.games.length}',
                      style: AppText.display(
                        22 * scale,
                        weight: FontWeight.w500,
                        color: Colors.white.withValues(alpha: 0.5),
                      ),
                    ),
                  ),
                  const Spacer(),
                  const HintBar(options: false, games: false),
                ],
              ),
              SizedBox(height: 26 * scale),
              Expanded(
                child: SingleChildScrollView(
                  padding: EdgeInsets.all(14 * scale),
                  child: Wrap(
                    spacing: 26 * scale,
                    runSpacing: 30 * scale,
                    children: [
                      for (var index = 0; index < model.games.length; index++)
                        KeepVisible(
                          active: index == model.libraryIndex,
                          child: Pressable(
                            onHover: () => model.hoverLibrary(index),
                            onTap: () {
                              model.select(index);
                              model.closeOverlay();
                            },
                            onDoubleTap: () {
                              final game = model.games[index];
                              model.select(index);
                              if (model.overlay != null) model.closeOverlay();
                              model.primaryAction(game);
                            },
                            builder: (context, _) => SizedBox(
                              width: size,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SizedBox.square(
                                    dimension: size,
                                    child: GameTile(
                                      model: model,
                                      game: model.games[index],
                                      size: size,
                                      focused: index == model.libraryIndex,
                                    ),
                                  ),
                                  SizedBox(height: 10 * scale),
                                  Text(
                                    model.games[index].nameFor([T.language.code]),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: AppText.display(
                                      15 * scale,
                                      weight: index == model.libraryIndex ? FontWeight.w600 : FontWeight.w400,
                                      color: Colors.white.withValues(alpha: index == model.libraryIndex ? 1 : 0.75),
                                    ),
                                  ),
                                  SizedBox(height: 4 * scale),
                                  StateLabel(model: model, state: model.stateOf(model.games[index]), size: 12),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
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

/// A darkened, blurred layer over the home screen.
class _Scrim extends StatelessWidget {
  const _Scrim({required this.child, this.opacity = 0.65, this.onTapOutside});

  final Widget child;
  final double opacity;

  /// A click on the darkened area around what the layer shows (not on it).
  final VoidCallback? onTapOutside;

  @override
  Widget build(BuildContext context) {
    return LayerScrim(
      opacity: opacity,
      child: onTapOutside == null
          ? child
          : Stack(
              fit: StackFit.expand,
              children: [
                GestureDetector(
                  key: const ValueKey('scrim-outside'),
                  behavior: HitTestBehavior.opaque,
                  onTap: onTapOutside,
                ),
                child,
              ],
            ),
    );
  }
}

/// The settings, a game's settings, its controls and the confirmations: categories on the left
/// (when there are several), the rows of the chosen one on the right.
class PanelView extends StatelessWidget {
  const PanelView({super.key, required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final categories = model.panelCategories();
    if (categories.isEmpty) return const SizedBox.shrink();
    final category = categories[model.panelCategory.clamp(0, categories.length - 1)];
    final compact = const {
      Layer.confirmUninstall,
      Layer.updateChoice,
      Layer.updateRequired,
      Layer.joinBlocked,
      Layer.joinOrHost,
      Layer.phoneEngine,
      Layer.friendOptions,
      Layer.copyWarning,
      Layer.gameFiles,
      Layer.quickMenu,
      Layer.retroMenu,
      Layer.homeMenu,
      Layer.launcherReport,
      Layer.profileMenu,
      Layer.signIn,
      Layer.cloudQuestion,
    }.contains(model.overlay);
    // PS's menus: a heading that may be long (the game's name), and only as tall as their rows.
    final psMenu = const {
      Layer.quickMenu,
      Layer.retroMenu,
      Layer.homeMenu,
      Layer.launcherReport,
      Layer.profileMenu,
      Layer.cloudQuestion,
    }.contains(model.overlay);
    // The quick menu is about the game playing: its icon by the heading (Close Game? is a
    // ConfirmCard, with the icon too).
    final gameIcon = switch (model.overlay) {
      Layer.quickMenu => model.running?.$1.icon,
      Layer.retroMenu => model.retroPlay?.game.icon,
      _ => null,
    };
    // The copy warning explains itself before its four choices.
    // A join held back says both builds whole and what to do.
    final tall = model.overlay == Layer.copyWarning || model.overlay == Layer.joinBlocked;
    // The party with its chat beside the rows: wider.
    final partyChat = model.overlay == Layer.party && model.together.partyChatShown;
    final heading = switch (model.overlay) {
      Layer.settings => T.text('settings'),
      Layer.friends => T.text('friendsTitle'),
      Layer.party => T.text('partyTitle'),
      Layer.notifications => T.text('socialNotifTitle'),
      Layer.compat => model.together.compatTitle,
      Layer.findPlayers || Layer.lfgPost => T.text('discoverFindPlayers'),
      Layer.gameHub => T.format('discoverHubOf', [model.together.findState.hubName]),
      Layer.controls => T.text('controls'),
      Layer.advanced => T.text('advanced'),
      Layer.gameSettings => T.text('gameSettings'),
      Layer.cloudStorage => T.text('cloudStorageTitle'),
      // Appearance › Themes.
      Layer.themes => T.text('appearance'),
      // The user's own profile: the count pinned, and the Hub the themes come from, beside it.
      Layer.showcaseEdit => T.text('showcaseEdit'),
      Layer.profileTheme => T.text('profileTheme'),
      Layer.countryPicker => T.text('togetherCountry'),
      _ => category.title,
    };
    return _Scrim(
      opacity: 0.55,
      onTapOutside: () => model.handle(Command.back),
      child: Center(
        child: SizedBox(
          width: (compact ? 760 : (partyChat ? 1400 : 1180)) * scale,
          height:
              (psMenu
                  // The Options menu's rows say what each does: a line more each.
                  ? 168 +
                        (model.overlay == Layer.retroMenu
                            ? _gameMenuRowsHeight(category.rows)
                            : switch (model.overlay) {
                                    Layer.profileMenu => 74,
                                    // Send Report says what it sends: two lines more.
                                    Layer.launcherReport => 98,
                                    // The question's line is a sentence or two.
                                    Layer.cloudQuestion => 72,
                                    _ => 62,
                                  } *
                                  category.rows.length) +
                        // Now playing's card is taller than a row: its cover and three lines.
                        (category.rows.any((row) => row.kind is MediaRow) ? 40 : 0)
                  : compact
                  ? (tall ? 560 : 420)
                  : 720) *
              scale,
          child: Glass(
            radius: 28 * scale,
            opacity: 0.5,
            padding: EdgeInsets.all(36 * scale),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (gameIcon != null) ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12 * scale),
                        child: SizedBox.square(
                          dimension: 52 * scale,
                          child: ArtworkImage(path: gameIcon, cacheWidth: 160),
                        ),
                      ),
                      SizedBox(width: 16 * scale),
                    ],
                    if (psMenu)
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Over the game: whether it was paused for the menu, or still runs.
                            if (model.overlay == Layer.profileMenu)
                              Text(
                                T.upper(T.text('profileMenuTitle')),
                                style: AppText.display(
                                  12 * scale,
                                  weight: FontWeight.w700,
                                  color: model.accentChoice.color,
                                ).copyWith(letterSpacing: 1.4 * scale),
                              ),
                            if (model.overlay == Layer.launcherReport)
                              Text(
                                T.upper(T.text('launcherReportWhen')),
                                style: AppText.display(
                                  12 * scale,
                                  weight: FontWeight.w700,
                                  color: model.accentChoice.color,
                                ).copyWith(letterSpacing: 1.4 * scale),
                              ),
                            if (model.overlay == Layer.quickMenu || model.overlay == Layer.retroMenu)
                              Text(
                                T.upper(
                                  T.text(
                                    model.quickMenuPaused || model.overlay == Layer.retroMenu
                                        ? 'quickPaused'
                                        : 'quickRunning',
                                  ),
                                ),
                                style: AppText.display(
                                  12 * scale,
                                  weight: FontWeight.w700,
                                  color: model.accentChoice.color,
                                ).copyWith(letterSpacing: 1.4 * scale),
                              ),
                            Text(
                              heading,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppText.display(34 * scale, weight: FontWeight.w300, height: 1.1),
                            ),
                          ],
                        ),
                      )
                    else
                      Text(heading, style: AppText.display(34 * scale, weight: FontWeight.w300)),
                    if (!const {
                          Layer.settings,
                          Layer.friends,
                          Layer.party,
                          Layer.findPlayers,
                          Layer.gameHub,
                        }.contains(model.overlay) &&
                        !compact) ...[
                      SizedBox(width: 14 * scale),
                      Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(bottom: 5 * scale),
                          child: Text(
                            category.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.display(18 * scale, color: Colors.white.withValues(alpha: 0.55)),
                          ),
                        ),
                      ),
                    ] else if (model.overlay == Layer.settings) ...[
                      SizedBox(width: 24 * scale),
                      Expanded(
                        child: Align(
                          alignment: AlignmentDirectional.centerEnd,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(maxWidth: 400 * scale),
                            child: SettingsSearchField(model: model),
                          ),
                        ),
                      ),
                    ] else if (model.overlay == Layer.findPlayers && model.together.onlineNowText != null) ...[
                      // How many are online now, by the heading, as on the Mac and the website.
                      SizedBox(width: 22 * scale),
                      Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(bottom: 9 * scale),
                          child: Align(
                            alignment: AlignmentDirectional.centerStart,
                            child: OnlineNowLine(text: model.together.onlineNowText!),
                          ),
                        ),
                      ),
                    ] else if (!psMenu)
                      const Spacer(),
                    SizedBox(width: 14 * scale),
                    BackPill(
                      onTap: () => model.handle(Command.back),
                      // Over a game the way out is back to it, not a close (Close Game is a row).
                      close: !const {
                        Layer.controls,
                        Layer.advanced,
                        Layer.friendOptions,
                        Layer.quickMenu,
                        Layer.retroMenu,
                      }.contains(model.overlay),
                    ),
                  ],
                ),
                SizedBox(height: 24 * scale),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (categories.length > 1) ...[
                        SizedBox(
                          width: 262 * scale,
                          child: _CategoryList(model: model, categories: categories),
                        ),
                        SizedBox(width: 22 * scale),
                      ],
                      Expanded(
                        child: PanelRows(
                          model: model,
                          rows: category.rows,
                          idle: partyChat && model.together.partyChatKeys.focused,
                        ),
                      ),
                      if (partyChat) ...[
                        SizedBox(width: 28 * scale),
                        SizedBox(
                          width: 560 * scale,
                          child: PartyChatPane(model: model),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// How tall the rows of a PS1 game's menu are, with the gap under each: its pages mix actions,
/// choices, a slider and a switch, some with a line under the title, so each counts its own.
double _gameMenuRowsHeight(List<PanelRow> rows) =>
    rows.fold(0, (height, row) => height + (row.detail != null ? 81 : (row.kind is ActionRow ? 58 : 65)));

/// The sections' column: as large as the rows, scrolling with a scrollbar that shows whenever
/// there are more than fit (Settings in a short window), the selected one kept in view.
class _CategoryList extends StatefulWidget {
  const _CategoryList({required this.model, required this.categories});

  final AppModel model;
  final List<PanelCategory> categories;

  @override
  State<_CategoryList> createState() => _CategoryListState();
}

class _CategoryListState extends State<_CategoryList> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final model = widget.model;
    final categories = widget.categories;
    return RawScrollbar(
      controller: _scroll,
      thumbVisibility: true,
      interactive: true,
      thickness: 5 * scale,
      radius: Radius.circular(3 * scale),
      thumbColor: Colors.white.withValues(alpha: 0.32),
      trackVisibility: true,
      trackColor: Colors.white.withValues(alpha: 0.06),
      trackRadius: Radius.circular(3 * scale),
      trackBorderColor: Colors.transparent,
      crossAxisMargin: 0,
      child: ScrollConfiguration(
        // This one bar only, not the platform's thin one over it.
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: SingleChildScrollView(
          controller: _scroll,
          // Room for the bar beside the tabs and their focus ring.
          padding: EdgeInsetsDirectional.fromSTEB(3 * scale, 3 * scale, 14 * scale, 3 * scale),
          child: Column(
            children: [
              for (var index = 0; index < categories.length; index++)
                KeepVisible(
                  active: index == model.panelCategory,
                  atStart: true,
                  child: _CategoryTab(
                    key: ValueKey('section-${categories[index].id}'),
                    title: categories[index].title,
                    selected: index == model.panelCategory,
                    // A controller's focus on the sections' column.
                    focused: model.panelSections && index == model.panelCategory,
                    onTap: () => model.selectCategory(index),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CategoryTab extends StatelessWidget {
  const _CategoryTab({
    super.key,
    required this.title,
    required this.selected,
    required this.onTap,
    this.focused = false,
  });

  final String title;
  final bool selected;

  /// The controller's focus is here (the sections' column): the ring around it.
  final bool focused;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: 6 * scale),
      child: FocusRing(focused: focused, radius: 12 * scale, width: 2.5 * scale, child: _tab(context, scale)),
    );
  }

  Widget _tab(BuildContext context, double scale) {
    if (LookScope.isGlass(context)) {
      // Glass: the chosen category is a pane of ice set into the panel; the others are words.
      return Pressable(
        onTap: onTap,
        pressScale: 0.985,
        builder: (context, hovering) => IceSurface(
          radius: 12 * scale,
          shadow: false,
          hover: hovering,
          opacity: selected ? 0.3 : 0,
          rim: selected ? 0.8 : (hovering ? 0.3 : 0),
          sheen: selected || hovering,
          width: double.infinity,
          padding: EdgeInsets.symmetric(horizontal: 18 * scale, vertical: 13 * scale),
          child: Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppText.display(
              18 * scale,
              weight: selected ? FontWeight.w600 : FontWeight.w400,
              color: Colors.white.withValues(alpha: selected ? 1 : (hovering ? 0.9 : 0.72)),
            ),
          ),
        ),
      );
    }
    return Pressable(
      onTap: onTap,
      pressScale: 0.985,
      builder: (context, hovering) => AnimatedContainer(
        duration: Motion.focus,
        curve: Motion.settle,
        width: double.infinity,
        padding: EdgeInsets.symmetric(horizontal: 18 * scale, vertical: 13 * scale),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: selected ? 0.14 : (hovering ? 0.07 : 0)),
          borderRadius: BorderRadius.circular(12 * scale),
        ),
        child: Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: AppText.display(
            18 * scale,
            weight: selected ? FontWeight.w600 : FontWeight.w400,
            color: Colors.white.withValues(alpha: selected ? 1 : (hovering ? 0.85 : 0.6)),
          ),
        ),
      ),
    );
  }
}

/// A panel's rows, the focused one kept in view.
class PanelRows extends StatelessWidget {
  const PanelRows({super.key, required this.model, required this.rows, this.idle = false});

  final AppModel model;
  final List<PanelRow> rows;

  /// The keys are elsewhere on the screen (the party's chat): no row has the focus.
  final bool idle;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return SingleChildScrollView(
      padding: EdgeInsets.symmetric(horizontal: 6 * scale, vertical: 6 * scale),
      child: Column(
        children: [
          for (var index = 0; index < rows.length; index++)
            KeepVisible(
              active: index == model.panelRow,
              child: _RowView(
                key: ValueKey('row-${rows[index].id}'),
                model: model,
                row: rows[index],
                // While a controller is on the sections' column, no row has the focus.
                focused: index == model.panelRow && !model.panelSections && !idle,
                onTap: () => model.activateRow(index),
                onStep: (delta, {repeat = false}) => model.stepRow(index, delta, repeat: repeat),
                onSet: (value) => model.setRowValue(index, value),
                onHover: () => model.hoverRow(index),
              ),
            ),
        ],
      ),
    );
  }
}

class _RowView extends StatelessWidget {
  // The menus over the game, Home and the screens of rows that go with people (Party, Play Together,
  // Find Players, a friend's options), read by their rows' names and details, as on the Mac.
  static const _labelledMenus = {
    Layer.quickMenu,
    Layer.retroMenu,
    Layer.homeMenu,
    Layer.launcherReport,
    Layer.profileMenu,
    Layer.party,
    Layer.friends,
    Layer.friendOptions,
    Layer.findPlayers,
    Layer.lfgPost,
    Layer.gameHub,
  };

  const _RowView({
    super.key,
    required this.model,
    required this.row,
    required this.focused,
    required this.onTap,
    required this.onStep,
    required this.onSet,
    required this.onHover,
  });

  final AppModel model;
  final PanelRow row;
  final bool focused;
  final VoidCallback onTap;

  /// One step back (-1) or on (1), from a click on ‹ › or − +; [repeat] while − + is held.
  final void Function(int delta, {bool repeat}) onStep;

  /// A slider's value from a click or a drag along its bar.
  final void Function(int value) onSet;
  final VoidCallback onHover;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final kind = row.kind;
    final destructive = kind is ActionRow && kind.destructive;
    final glass = LookScope.isGlass(context);
    final ink = LookScope.focusedInk(context);
    final idleTitle = destructive ? Palette.danger : Colors.white;
    final idleDetail = Colors.white.withValues(alpha: glass ? 0.72 : 0.55);
    final focusedDetail = ink.withValues(alpha: glass ? 0.68 : 0.6);
    // The words follow the focus fill as it comes and goes, frame by frame (set below, where the
    // fill is drawn): dark words wait for the light fill. Switched at once while the fill still
    // faded in, a row read dark on dark whenever the fill's animation stood still (the launcher
    // resting behind another window while the pointer passed over the rows).
    var titleColor = focused ? ink : idleTitle;
    var detailColor = focused ? focusedDetail : idleDetail;
    final accent = model.accentChoice.color;
    // With a controller the ‹ › and − + (mouse targets) show only in edit mode (✕ on the row),
    // where ← and → change the value.
    final viaPad = InputScope.pad(context);
    final editing = focused && model.editingValue == row.id;
    final arrows = !viaPad || editing;
    final arrowSize = viaPad ? 28.0 : 32.0;
    // The keys and the mouse see the row as before; a controller sees the frame of edit mode.
    Widget editable(Widget child) => !viaPad
        ? child
        : _EditFrame(
            key: ValueKey('${row.id}-edit'),
            editing: editing,
            hint: focused && !editing,
            accent: accent,
            ink: titleColor,
            child: child,
          );
    Widget value() {
      final style = AppText.display(16 * scale, weight: FontWeight.w600, color: titleColor);
      switch (kind) {
        case ChoiceRow(:final options, :final selected):
          final current = selected.clamp(0, options.length - 1);
          return editable(
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (arrows)
                  _StepArrow(
                    key: ValueKey('${row.id}-previous'),
                    size: arrowSize,
                    icon: Icons.chevron_left_rounded,
                    enabled: current > 0,
                    focused: focused,
                    onTap: () => onStep(-1),
                  ),
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: 280 * scale),
                  child: Text(options[current], style: style, overflow: TextOverflow.ellipsis),
                ),
                if (arrows)
                  _StepArrow(
                    key: ValueKey('${row.id}-next'),
                    size: arrowSize,
                    icon: Icons.chevron_right_rounded,
                    enabled: current < options.length - 1,
                    focused: focused,
                    onTap: () => onStep(1),
                  ),
              ],
            ),
          );
        case ToggleRow(:final value):
          return AnimatedContainer(
            duration: Motion.focus,
            curve: Motion.settle,
            width: 46 * scale,
            height: 26 * scale,
            padding: EdgeInsets.all(3 * scale),
            alignment: value ? AlignmentDirectional.centerEnd : AlignmentDirectional.centerStart,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20 * scale),
              color: value ? accent : (focused ? ink.withValues(alpha: 0.18) : Colors.white.withValues(alpha: 0.18)),
            ),
            child: Container(
              width: 20 * scale,
              height: 20 * scale,
              decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.white),
            ),
          );
        case final StepperRow stepper:
          final StepperRow(:value, :min, :max, :format, :wraps, :slider) = stepper;
          return editable(
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (slider) ...[
                  _Slider(
                    key: ValueKey('${row.id}-slider'),
                    row: stepper,
                    focused: focused,
                    accent: accent,
                    ink: titleColor,
                    onSet: onSet,
                  ),
                  SizedBox(width: 10 * scale),
                ],
                if (arrows) ...[
                  _StepArrow(
                    key: ValueKey('${row.id}-previous'),
                    size: arrowSize,
                    icon: Icons.remove_rounded,
                    enabled: wraps || value > min,
                    focused: focused,
                    onTap: () => onStep(-1),
                    onRepeat: () => onStep(-1, repeat: true),
                  ),
                  SizedBox(width: 4 * scale),
                ],
                if (slider)
                  // As wide as its widest value: the bar does not move as the number changes.
                  ConstrainedBox(
                    constraints: BoxConstraints(minWidth: 52 * scale),
                    child: Text(
                      format(value),
                      textAlign: TextAlign.end,
                      style: style.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                    ),
                  )
                else
                  Text(format(value), style: style),
                if (arrows) ...[
                  SizedBox(width: 4 * scale),
                  _StepArrow(
                    key: ValueKey('${row.id}-next'),
                    size: arrowSize,
                    icon: Icons.add_rounded,
                    enabled: wraps || value < max,
                    focused: focused,
                    onTap: () => onStep(1),
                    onRepeat: () => onStep(1, repeat: true),
                  ),
                ],
              ],
            ),
          );
        case ShortcutRow(:final key, :final pad, :final capturing):
          if (capturing) {
            return _Listening(color: focused ? ink : accent, text: T.text('shortcutPress'));
          }
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _BindingChip(icon: Icons.keyboard_rounded, text: key, focused: focused, ink: titleColor),
              SizedBox(width: 8 * scale),
              _BindingChip(icon: Icons.sports_esports_rounded, text: pad, focused: focused, ink: titleColor),
            ],
          );
        case KeysRow(:final sources, :final capturing):
          if (capturing) {
            return Text(T.text('pressKey'), style: style.copyWith(color: focused ? ink : accent));
          }
          return Wrap(
            spacing: 6 * scale,
            children: [
              if (sources.isEmpty) Text(T.text('noKey'), style: style.copyWith(color: detailColor)),
              for (final source in sources)
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 9 * scale, vertical: 4 * scale),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(7 * scale),
                    color: focused ? ink.withValues(alpha: 0.1) : Colors.white.withValues(alpha: 0.12),
                  ),
                  child: Text(
                    Controls.label(source, T.format),
                    style: AppText.display(13 * scale, weight: FontWeight.w600, color: titleColor),
                  ),
                ),
            ],
          );
        case ActionRow():
          return Icon(Icons.chevron_right_rounded, size: 22 * scale, color: detailColor);
        case InfoRow():
          return const SizedBox.shrink();
        // Drawn whole by NowPlayingCard below, its buttons included.
        case MediaRow():
          return const SizedBox.shrink();
        case TextRow():
          return SizedBox(
            width: 420 * scale,
            child: RowTextField(model: model, row: row, kind: kind, focused: focused),
          );
      }
    }

    final info = kind is InfoRow && kind.text.isNotEmpty ? kind.text : null;
    Widget content() => kind is MediaRow
        ? NowPlayingCard(
            row: row,
            kind: kind,
            ink: titleColor,
            soft: detailColor,
            accent: accent,
            focused: focused,
            // The buttons do what the keys do, the focus going to the card: ← → and Enter.
            onPrevious: () => onStep(-1),
            onPlayPause: onTap,
            onNext: () => onStep(1),
          )
        : Row(
            children: [
              if (row.picture != null) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(8 * scale),
                  child: Image.memory(
                    row.picture!,
                    width: 44 * scale,
                    height: 44 * scale,
                    fit: BoxFit.cover,
                    cacheWidth: 132,
                    errorBuilder: (_, _, _) => SizedBox(width: 44 * scale, height: 44 * scale),
                  ),
                ),
                SizedBox(width: 16 * scale),
              ] else if (row.person != null) ...[
                PersonAvatar(person: row.person!, size: 44 * scale, focused: focused),
                SizedBox(width: 16 * scale),
              ] else if (row.icon != null) ...[
                Container(
                  width: 44 * scale,
                  height: 44 * scale,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: model.accentChoice.color.withValues(alpha: focused ? 0.16 : 0.22),
                  ),
                  child: Icon(
                    switch (row.icon!) {
                      PanelIcon.flag => Icons.flag_rounded,
                      PanelIcon.trophy => Icons.emoji_events_rounded,
                      // Material Icons, which Flutter ships (Apache 2.0): no logo files of ours.
                      PanelIcon.android => Icons.android_rounded,
                      PanelIcon.iphone => Icons.phone_iphone_rounded,
                      PanelIcon.browser => Icons.language_rounded,
                      PanelIcon.phone => Icons.smartphone_rounded,
                    },
                    size: 22 * scale,
                    color: focused ? model.accentChoice.color : Colors.white,
                  ),
                ),
                SizedBox(width: 16 * scale),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        // A title longer than the row (every missing tool by name) goes on to a
                        // second line; one that fits is drawn as before.
                        Flexible(
                          child: Text(
                            row.title,
                            style: AppText.display(17 * scale, weight: FontWeight.w500, color: titleColor),
                          ),
                        ),
                        if (row.glyph != null) ...[
                          SizedBox(width: 8 * scale),
                          PadGlyphIcon(row.glyph!, size: 15 * scale, color: titleColor),
                        ],
                        if (row.level != null) ...[
                          SizedBox(width: 10 * scale),
                          LevelBadgeView(level: row.level!, size: 24 * scale),
                        ],
                      ],
                    ),
                    if (row.detail != null || info != null) ...[
                      SizedBox(height: 4 * scale),
                      Text(
                        info ?? row.detail!,
                        maxLines: row.wraps ? null : 3,
                        overflow: row.wraps ? TextOverflow.clip : TextOverflow.ellipsis,
                        style: AppText.display(13 * scale, color: detailColor),
                      ),
                    ],
                    if (row.meter case final PanelMeter meter) ...[
                      SizedBox(height: 10 * scale),
                      _MeterBar(meter: meter, color: model.accentChoice.color, scale: scale),
                    ],
                  ],
                ),
              ),
              SizedBox(width: 18 * scale),
              value(),
            ],
          );

    final view = Pressable(
      onTap: row.focusable ? onTap : null,
      onHover: row.focusable ? onHover : null,
      pressScale: 0.99,
      builder: (context, hovering) => TweenAnimationBuilder<double>(
        // The same pace as the Glass chip's own (IceSurface): the words and the fill move as one.
        tween: Tween(end: focused ? 1 : 0),
        duration: Motion.focus,
        curve: Motion.settle,
        builder: (context, t, _) {
          titleColor = Color.lerp(idleTitle, ink, t)!;
          detailColor = Color.lerp(idleDetail, focusedDetail, t)!;
          if (glass) {
            // Glass: rows are thin panes inside the panel's ice (no blur of their own); the
            // focused one is the bright chip. Wide rows do not grow: the chip and its glow say it.
            return Padding(
              padding: EdgeInsets.only(bottom: 6 * scale),
              child: IceSurface(
                radius: 14 * scale,
                focused: focused,
                shadow: false,
                sweep: true,
                hover: hovering && row.focusable,
                opacity: row.focusable ? 0.16 : 0,
                rim: row.focusable ? 0.45 : 0,
                sheen: row.focusable,
                padding: EdgeInsets.symmetric(horizontal: 20 * scale, vertical: 14 * scale),
                child: content(),
              ),
            );
          }
          final idleFill = Colors.white.withValues(alpha: row.focusable ? (hovering ? 0.12 : 0.06) : 0);
          return Container(
            margin: EdgeInsets.only(bottom: 6 * scale),
            padding: EdgeInsets.symmetric(horizontal: 20 * scale, vertical: 14 * scale),
            decoration: BoxDecoration(
              color: Color.lerp(idleFill, Colors.white, t),
              borderRadius: BorderRadius.circular(14 * scale),
              boxShadow: [
                BoxShadow(
                  color: Colors.white.withValues(alpha: 0.22 * t),
                  blurRadius: 16 * scale,
                ),
              ],
            ),
            child: content(),
          );
        },
      ),
    );
    // The menus over the game and Home are read by their rows' names, as on the Mac.
    if (!_labelledMenus.contains(model.overlay) || !(kind is ActionRow || kind is ToggleRow || kind is InfoRow)) {
      return view;
    }
    return Semantics(
      button: kind is ActionRow,
      toggled: kind is ToggleRow ? kind.value : null,
      enabled: row.focusable,
      label: row.title,
      hint: row.detail,
      excludeSemantics: true,
      onTap: row.focusable ? onTap : null,
      child: view,
    );
  }
}

/// The quick menu's Now playing card: the cover, "Now playing in Rhythmbox" over the title and
/// the artist, and previous, play or pause and next. Drawn inside the row's own focus fill, in
/// the row's colours ([ink] for the words, [soft] for the lesser ones).
class NowPlayingCard extends StatelessWidget {
  const NowPlayingCard({
    super.key,
    required this.row,
    required this.kind,
    required this.ink,
    required this.soft,
    required this.accent,
    required this.focused,
    required this.onPrevious,
    required this.onPlayPause,
    required this.onNext,
  });

  final PanelRow row;
  final MediaRow kind;
  final Color ink;
  final Color soft;
  final Color accent;
  final bool focused;
  final VoidCallback onPrevious;
  final VoidCallback onPlayPause;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final side = 64 * scale;
    // No cover from the player: a note on the accent colour, the size a cover would be.
    Widget noCover() => Container(
      width: side,
      height: side,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [accent.withValues(alpha: 0.85), accent.withValues(alpha: 0.35)],
        ),
      ),
      child: Icon(Icons.music_note_rounded, size: 30 * scale, color: Colors.white),
    );
    final artist = row.detail;
    return Semantics(
      container: true,
      label: [kind.label, row.title, ?artist].join(', '),
      child: Row(
        children: [
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10 * scale),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 10 * scale,
                  offset: Offset(0, 4 * scale),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10 * scale),
              child: row.picture == null
                  ? noCover()
                  : Image.memory(
                      row.picture!,
                      key: const ValueKey('nowPlaying-cover'),
                      width: side,
                      height: side,
                      fit: BoxFit.cover,
                      cacheWidth: 192,
                      gaplessPlayback: true,
                      errorBuilder: (_, _, _) => noCover(),
                    ),
            ),
          ),
          SizedBox(width: 16 * scale),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _Equaliser(playing: kind.playing, color: focused ? ink : accent),
                    SizedBox(width: 8 * scale),
                    Flexible(
                      child: Text(
                        T.upper(kind.label),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.display(
                          11.5 * scale,
                          weight: FontWeight.w700,
                          color: soft,
                        ).copyWith(letterSpacing: 1.2 * scale),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 5 * scale),
                Text(
                  row.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.display(
                    19 * scale,
                    weight: FontWeight.w700,
                    color: ink,
                    height: 1.15,
                  ).copyWith(letterSpacing: -0.2 * scale),
                ),
                if (artist != null) ...[
                  SizedBox(height: 2 * scale),
                  Text(
                    artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.display(14 * scale, color: soft),
                  ),
                ],
              ],
            ),
          ),
          SizedBox(width: 16 * scale),
          _TransportButton(
            key: const ValueKey('nowPlaying-previous'),
            icon: Icons.skip_previous_rounded,
            label: T.text('nowPlayingPrevious'),
            ink: ink,
            onTap: onPrevious,
          ),
          SizedBox(width: 8 * scale),
          _TransportButton(
            key: const ValueKey('nowPlaying-playPause'),
            icon: kind.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            label: T.text('nowPlayingPlayPause'),
            ink: ink,
            filled: true,
            onTap: onPlayPause,
          ),
          SizedBox(width: 8 * scale),
          _TransportButton(
            key: const ValueKey('nowPlaying-next'),
            icon: Icons.skip_next_rounded,
            label: T.text('nowPlayingNext'),
            ink: ink,
            onTap: onNext,
          ),
        ],
      ),
    );
  }
}

/// One of the card's three round buttons; play or pause is the filled, larger one.
class _TransportButton extends StatelessWidget {
  const _TransportButton({
    super.key,
    required this.icon,
    required this.label,
    required this.ink,
    required this.onTap,
    this.filled = false,
  });

  final IconData icon;
  final String label;
  final Color ink;
  final VoidCallback onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final size = (filled ? 46 : 38) * scale;
    // On the filled button the sign is cut out of it: dark on light ink, light on dark.
    final cut = ink.computeLuminance() > 0.5 ? const Color(0xFF111318) : Colors.white;
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: Pressable(
        onTap: onTap,
        pressScale: 0.9,
        builder: (context, hovering) => AnimatedContainer(
          duration: Motion.focus,
          curve: Motion.settle,
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: filled ? ink.withValues(alpha: hovering ? 1 : 0.92) : ink.withValues(alpha: hovering ? 0.2 : 0.1),
          ),
          child: Icon(icon, size: (filled ? 26 : 22) * scale, color: filled ? cut : ink),
        ),
      ),
    );
  }
}

/// Four small bars beside the card's label: they move while something plays, lie low while
/// paused, and stand still where motion is reduced.
class _Equaliser extends StatefulWidget {
  const _Equaliser({required this.playing, required this.color});

  final bool playing;
  final Color color;

  @override
  State<_Equaliser> createState() => _EqualiserState();
}

class _EqualiserState extends State<_Equaliser> with SingleTickerProviderStateMixin {
  late final AnimationController _beat = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));

  /// How many times each bar rises in one turn, and where in its rise it starts.
  static const _turns = [2, 3, 1, 2];
  static const _starts = [0.0, 0.35, 0.6, 0.15];
  static const _still = [0.55, 1.0, 0.7, 0.4];

  bool get _moving => widget.playing && !Motion.reduced;

  @override
  void initState() {
    super.initState();
    _follow();
  }

  @override
  void didUpdateWidget(_Equaliser old) {
    super.didUpdateWidget(old);
    _follow();
  }

  void _follow() {
    if (_moving) {
      if (!_beat.isAnimating) _beat.repeat();
    } else {
      _beat.stop();
    }
  }

  @override
  void dispose() {
    _beat.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final tall = 12 * scale;
    final still = !_moving || MediaQuery.disableAnimationsOf(context);
    return SizedBox(
      height: tall,
      child: AnimatedBuilder(
        animation: _beat,
        builder: (context, _) => Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (var bar = 0; bar < 4; bar++)
              Container(
                width: 3 * scale,
                height:
                    tall *
                    (!widget.playing
                        ? 0.25
                        : still
                        ? _still[bar]
                        : 0.3 + 0.7 * (0.5 + 0.5 * math.sin(2 * math.pi * (_beat.value * _turns[bar] + _starts[bar])))),
                margin: EdgeInsetsDirectional.only(end: bar == 3 ? 0 : 2 * scale),
                decoration: BoxDecoration(color: widget.color, borderRadius: BorderRadius.circular(1.5 * scale)),
              ),
          ],
        ),
      ),
    );
  }
}

/// A choice or stepper row's value: in edit mode (a controller's ✕) an accent ring round it,
/// and with a controller on the row before that a small ✕ that says how to get there.
class _EditFrame extends StatelessWidget {
  const _EditFrame({
    super.key,
    required this.editing,
    required this.hint,
    required this.accent,
    required this.ink,
    required this.child,
  });

  final bool editing;
  final bool hint;
  final Color accent;
  final Color ink;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // As tall as the arrows: going in and out of edit mode moves no row.
        AnimatedContainer(
          duration: Motion.focus,
          curve: Motion.settle,
          height: 32 * scale,
          alignment: Alignment.center,
          padding: EdgeInsets.symmetric(horizontal: editing ? 2 * scale : 0),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18 * scale),
            border: Border.all(color: editing ? accent : accent.withValues(alpha: 0), width: 2 * scale),
            color: editing ? accent.withValues(alpha: 0.14) : accent.withValues(alpha: 0),
          ),
          child: child,
        ),
        // The way into edit mode, drawn as the controller's button cap.
        if (hint) ...[
          SizedBox(width: 10 * scale),
          Container(
            width: 22 * scale,
            height: 22 * scale,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: ink.withValues(alpha: 0.35), width: 1.5 * scale),
            ),
            child: PadGlyphIcon(
              Hint.circleConfirms ? PadGlyph.circle : PadGlyph.cross,
              size: 11 * scale,
              color: ink.withValues(alpha: 0.6),
            ),
          ),
        ],
      ],
    );
  }
}

/// One input of a shortcut: the keyboard's or the controller's, "—" for none.
class _BindingChip extends StatelessWidget {
  const _BindingChip({required this.icon, required this.text, required this.focused, required this.ink});

  final IconData icon;
  final String? text;
  final bool focused;
  final Color ink;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final none = text == null;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 10 * scale, vertical: 5 * scale),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8 * scale),
        color: ink.withValues(alpha: focused ? 0.1 : 0.12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15 * scale, color: ink.withValues(alpha: 0.6)),
          SizedBox(width: 7 * scale),
          Text(
            text ?? '—',
            style: AppText.display(
              13 * scale,
              weight: FontWeight.w600,
              color: ink.withValues(alpha: none ? 0.4 : 1),
            ),
          ),
        ],
      ),
    );
  }
}

/// Waiting for a key or buttons: the words, breathing (still with reduced motion).
class _Listening extends StatefulWidget {
  const _Listening({required this.color, required this.text});

  final Color color;
  final String text;

  @override
  State<_Listening> createState() => _ListeningState();
}

class _ListeningState extends State<_Listening> with SingleTickerProviderStateMixin {
  late final AnimationController _breath = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void initState() {
    super.initState();
    if (!Motion.reduced) _breath.repeat(reverse: true);
  }

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return FadeTransition(
      opacity: Motion.reduced ? const AlwaysStoppedAnimation(1) : Tween(begin: 0.45, end: 1.0).animate(_breath),
      child: Text(
        widget.text,
        style: AppText.display(15 * scale, weight: FontWeight.w600, color: widget.color),
      ),
    );
  }
}

/// A row's ‹ › or − + : its own click target, dimmed at the end of the choices.
/// A volume's bar: filled up to the value, a knob at its end; a click or a drag along it sets the
/// value (on a step), the keys and the pad move it with ← → as a stepper.
class _Slider extends StatefulWidget {
  const _Slider({
    super.key,
    required this.row,
    required this.focused,
    required this.accent,
    required this.ink,
    required this.onSet,
  });

  final StepperRow row;
  final bool focused;
  final Color accent;
  final Color ink;
  final void Function(int value) onSet;

  @override
  State<_Slider> createState() => _SliderState();
}

class _SliderState extends State<_Slider> {
  bool _dragging = false;

  void _setAt(double dx, double width) {
    if (width <= 0) return;
    // Mirrored (Arabic, Urdu): the bar fills from the right.
    final along = Directionality.of(context) == TextDirection.rtl ? width - dx : dx;
    final value = widget.row.valueAt(along / width);
    if (value != widget.row.value) widget.onSet(value);
  }

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final row = widget.row;
    final span = row.max - row.min;
    final fraction = span <= 0 ? 0.0 : ((row.value - row.min) / span).clamp(0.0, 1.0);
    final width = 200 * scale;
    final knob = 16 * scale;
    final track = 6 * scale;
    // Focused, the row is light: the bar takes the row's ink; otherwise the accent.
    final fill = widget.focused ? widget.ink : widget.accent;
    final empty = widget.focused ? widget.ink.withValues(alpha: 0.18) : Colors.white.withValues(alpha: 0.16);
    final duration = _dragging ? Duration.zero : Motion.focus;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (details) => _setAt(details.localPosition.dx - knob / 2, width - knob),
        onHorizontalDragStart: (details) {
          setState(() => _dragging = true);
          _setAt(details.localPosition.dx - knob / 2, width - knob);
        },
        onHorizontalDragUpdate: (details) => _setAt(details.localPosition.dx - knob / 2, width - knob),
        onHorizontalDragEnd: (_) => setState(() => _dragging = false),
        onHorizontalDragCancel: () => setState(() => _dragging = false),
        child: SizedBox(
          width: width,
          height: 28 * scale,
          child: Stack(
            alignment: AlignmentDirectional.centerStart,
            children: [
              PositionedDirectional(
                start: knob / 2,
                end: knob / 2,
                child: Container(
                  height: track,
                  decoration: BoxDecoration(color: empty, borderRadius: BorderRadius.circular(track)),
                ),
              ),
              PositionedDirectional(
                start: knob / 2,
                child: AnimatedContainer(
                  duration: duration,
                  curve: Motion.settle,
                  width: (width - knob) * fraction,
                  height: track,
                  decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(track)),
                ),
              ),
              AnimatedPositionedDirectional(
                duration: duration,
                curve: Motion.settle,
                start: (width - knob) * fraction,
                child: Container(
                  width: knob,
                  height: knob,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white,
                    border: Border.all(color: fill, width: 2 * scale),
                    boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.25), blurRadius: 4 * scale)],
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

class _StepArrow extends StatefulWidget {
  const _StepArrow({
    super.key,
    required this.icon,
    required this.enabled,
    required this.focused,
    required this.onTap,
    this.onRepeat,
    this.size = 32,
  });

  /// Its width and height before the layout's scale (smaller inside edit mode's frame).
  final double size;
  final IconData icon;
  final bool enabled;
  final bool focused;
  final VoidCallback onTap;

  /// Held down: the step again on a held key's pace, speeding up (a stepper's − +).
  final VoidCallback? onRepeat;

  @override
  State<_StepArrow> createState() => _StepArrowState();
}

class _StepArrowState extends State<_StepArrow> {
  late final HoldRepeater<int> _hold = HoldRepeater<int>((_) {
    _repeated = true;
    widget.onRepeat?.call();
  });

  /// The hold has repeated: letting go is not one more click.
  bool _repeated = false;

  @override
  void dispose() {
    _hold.stop();
    super.dispose();
  }

  void _down(PointerDownEvent event) {
    _repeated = false;
    if (widget.onRepeat == null || !widget.enabled || event.buttons != kPrimaryMouseButton) return;
    _hold.holdQuietly(0);
  }

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final ink = widget.focused ? LookScope.focusedInk(context) : Colors.white;
    return Listener(
      onPointerDown: _down,
      onPointerUp: (_) => _hold.stop(),
      onPointerCancel: (_) => _hold.stop(),
      child: Pressable(
        onTap: widget.enabled
            ? () {
                if (!_repeated) widget.onTap();
                _repeated = false;
              }
            : null,
        pressScale: 0.88,
        builder: (context, hovering) => AnimatedContainer(
          duration: Motion.focus,
          curve: Motion.settle,
          width: widget.size * scale,
          height: widget.size * scale,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: ink.withValues(alpha: hovering ? 0.14 : 0),
          ),
          child: Icon(
            widget.icon,
            size: 20 * scale,
            color: ink.withValues(alpha: widget.enabled ? (hovering ? 1 : 0.6) : 0.2),
          ),
        ),
      ),
    );
  }
}

/// The game's log, newest at the bottom.
class LogView extends StatelessWidget {
  const LogView({super.key, required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final game = model.selectedGame;
    final text = model.shownLog;
    return _Scrim(
      opacity: 0.65,
      child: Padding(
        padding: EdgeInsets.all(70 * scale),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '${T.text('logTitle')}${game == null ? '' : ' · ${game.name}'}',
                  style: AppText.display(30 * scale, weight: FontWeight.w300),
                ),
                const Spacer(),
                ConsoleButton(
                  title: T.text('close'),
                  icon: Icons.close_rounded,
                  focused: true,
                  onPressed: model.closeOverlay,
                ),
              ],
            ),
            SizedBox(height: 18 * scale),
            Expanded(
              child: Glass(
                radius: 14 * scale,
                opacity: 0.55,
                child: SingleChildScrollView(
                  reverse: true,
                  padding: EdgeInsets.all(18 * scale),
                  child: SelectableText(
                    text.isEmpty ? '—' : text,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12 * scale,
                      color: Colors.white.withValues(alpha: 0.85),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A phone asking to pair: its name and the code both screens show.
class PairingCard extends StatelessWidget {
  const PairingCard({super.key, required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final request = model.pairing;
    if (request == null) return const SizedBox.shrink();
    return _Scrim(
      opacity: 0.5,
      child: Center(
        child: SizedBox(
          width: 620 * scale,
          child: Glass(
            radius: 28 * scale,
            opacity: 0.55,
            padding: EdgeInsets.all(40 * scale),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.phone_iphone_rounded, size: 44 * scale, color: Colors.white),
                SizedBox(height: 16 * scale),
                Text(T.text('phonePairingTitle'), style: AppText.display(28 * scale, weight: FontWeight.w300)),
                SizedBox(height: 10 * scale),
                Text(PhoneLabel.title(request.deviceName), style: AppText.display(18 * scale, weight: FontWeight.w600)),
                SizedBox(height: 6 * scale),
                Text(
                  T.text('phonePairingText'),
                  textAlign: TextAlign.center,
                  style: AppText.display(16 * scale, color: Colors.white.withValues(alpha: 0.7)),
                ),
                SizedBox(height: 26 * scale),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final digit in request.code.split(''))
                      Container(
                        width: 64 * scale,
                        height: 82 * scale,
                        margin: EdgeInsets.symmetric(horizontal: 6 * scale),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(14 * scale),
                          border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
                        ),
                        child: Text(digit, style: AppText.display(44 * scale, weight: FontWeight.w300)),
                      ),
                  ],
                ),
                SizedBox(height: 30 * scale),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ConsoleButton(
                      title: T.text('phoneAllow'),
                      icon: Icons.check_rounded,
                      focused: true,
                      onPressed: () => model.answerPairing(true),
                    ),
                    SizedBox(width: 16 * scale),
                    ConsoleButton(
                      title: T.text('phoneDeny'),
                      focused: false,
                      onPressed: () => model.answerPairing(false),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A game's trophies: the counts by grade, then every trophy, earned ones first in their order.
class TrophyView extends StatelessWidget {
  const TrophyView({super.key, required this.model});

  final AppModel model;

  static Color gradeColor(TrophyGrade grade) => switch (grade) {
    TrophyGrade.platinum => const Color(0xFFD9E4F2),
    TrophyGrade.gold => const Color(0xFFF2C14E),
    TrophyGrade.silver => const Color(0xFFC0C6CF),
    TrophyGrade.bronze => const Color(0xFFC98A5B),
  };

  static String gradeName(TrophyGrade grade) => T.text(switch (grade) {
    TrophyGrade.platinum => 'gradePlatinum',
    TrophyGrade.gold => 'gradeGold',
    TrophyGrade.silver => 'gradeSilver',
    TrophyGrade.bronze => 'gradeBronze',
  });

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final game = model.selectedGame;
    final set = game == null ? null : model.trophies[game.id];
    if (set == null) return const SizedBox.shrink();
    final accent = model.accentChoice.color;
    return _Scrim(
      opacity: 0.6,
      child: WithBackPill(
        onBack: () => model.handle(Command.back),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 90 * scale, vertical: 64 * scale),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 360 * scale,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(T.text('trophies'), style: AppText.display(40 * scale, weight: FontWeight.w300)),
                    SizedBox(height: 8 * scale),
                    Text(
                      set.title.isEmpty ? game!.name : set.title,
                      style: AppText.display(18 * scale, color: Colors.white.withValues(alpha: 0.6)),
                    ),
                    SizedBox(height: 34 * scale),
                    Text(T.percent(set.percent), style: AppText.display(64 * scale, weight: FontWeight.w200)),
                    SizedBox(height: 10 * scale),
                    ProgressLine(fraction: set.percent / 100, color: accent, height: 6 * scale),
                    SizedBox(height: 28 * scale),
                    for (final grade in TrophyGrade.values)
                      if (set.count(grade).$2 > 0)
                        Padding(
                          padding: EdgeInsets.only(bottom: 12 * scale),
                          child: Row(
                            children: [
                              Icon(Icons.emoji_events_rounded, size: 22 * scale, color: gradeColor(grade)),
                              SizedBox(width: 12 * scale),
                              Text(gradeName(grade), style: AppText.display(17 * scale)),
                              const Spacer(),
                              Text(
                                '${set.count(grade).$1} / ${set.count(grade).$2}',
                                style: AppText.display(17 * scale, weight: FontWeight.w600),
                              ),
                            ],
                          ),
                        ),
                    // The moment the focused trophy was earned, when the launcher caught it.
                    if (model.trophyShots[set.trophies.elementAtOrNull(model.trophyIndex)?.id]
                        case final String shot) ...[
                      SizedBox(height: 18 * scale),
                      Pressable(
                        key: const ValueKey('trophy-shot'),
                        onTap: () => model.openGallery(shot: shot),
                        builder: (context, hovering) => Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(12 * scale),
                              child: SizedBox(
                                width: 360 * scale,
                                height: 360 * scale * 9 / 16,
                                child: ArtworkImage(path: shot, cacheWidth: 720),
                              ),
                            ),
                            SizedBox(height: 8 * scale),
                            Row(
                              children: [
                                Icon(Icons.photo_camera_rounded, size: 15 * scale, color: Colors.white70),
                                SizedBox(width: 6 * scale),
                                Text(
                                  T.text('trophyShot'),
                                  style: AppText.display(
                                    13 * scale,
                                    color: Colors.white.withValues(alpha: hovering ? 1 : 0.65),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                    // △ shows the focused hidden trophy, and hides it again.
                    if (model.focusedTrophy case final Trophy trophy when model.canReveal(trophy)) ...[
                      SizedBox(height: 22 * scale),
                      Hint(
                        keys: 'O',
                        glyph: PadGlyph.triangle,
                        label: T.text(model.isSecret(trophy) ? 'trophyShow' : 'trophyHide'),
                        action: HintAction.options,
                      ),
                    ],
                    // The game's leaderboard from here, as on the Mac: click it, or Enter where the
                    // focused trophy has no picture.
                    if (model.together.signedIn) ...[
                      SizedBox(height: 22 * scale),
                      _BoardChip(
                        key: const ValueKey('trophy-leaderboard'),
                        keys: model.trophyShots[model.focusedTrophy?.id] == null,
                        onTap: () => model.together.openLeaderboard(model.selectedGame),
                      ),
                    ],
                  ],
                ),
              ),
              SizedBox(width: 60 * scale),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      for (var index = 0; index < set.trophies.length; index++)
                        KeepVisible(
                          active: index == model.trophyIndex,
                          child: MouseRegion(
                            onEnter: (event) => HoverTicks.arrive(context, 'trophy-$index', event),
                            onExit: (_) => HoverTicks.leave(context, 'trophy-$index'),
                            onHover: (_) => model.hoverTrophy(index),
                            child: Builder(
                              builder: (context) {
                                final trophy = set.trophies[index];
                                final focused = index == model.trophyIndex;
                                final earned = trophy.unlocked != null;
                                final secret = model.isSecret(trophy);
                                final revealable = model.canReveal(trophy);
                                final color = focused ? LookScope.focusedInk(context) : Colors.white;
                                return PaneRow(
                                  focused: focused,
                                  radius: 14 * scale,
                                  margin: EdgeInsets.only(bottom: 8 * scale),
                                  padding: EdgeInsets.all(14 * scale),
                                  child: Row(
                                    children: [
                                      Container(
                                        width: 56 * scale,
                                        height: 56 * scale,
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(10 * scale),
                                          color: Colors.black.withValues(alpha: 0.3),
                                        ),
                                        clipBehavior: Clip.antiAlias,
                                        child: trophy.icon != null && !secret
                                            ? Opacity(
                                                opacity: earned ? 1 : 0.35,
                                                child: Image.memory(
                                                  trophy.icon!,
                                                  fit: BoxFit.cover,
                                                  errorBuilder: (_, _, _) => const SizedBox(),
                                                ),
                                              )
                                            : Icon(
                                                secret
                                                    ? Icons.lock_rounded
                                                    : (earned
                                                          ? Icons.emoji_events_rounded
                                                          : Icons.emoji_events_outlined),
                                                size: 26 * scale,
                                                color: earned
                                                    ? gradeColor(trophy.grade)
                                                    : Colors.white.withValues(alpha: 0.5),
                                              ),
                                      ),
                                      SizedBox(width: 16 * scale),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              secret ? T.text('trophyHidden') : trophy.name,
                                              style: AppText.display(17 * scale, weight: FontWeight.w600, color: color),
                                            ),
                                            SizedBox(height: 4 * scale),
                                            Text(
                                              secret ? T.text('trophyHiddenDetail') : trophy.detail,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: AppText.display(13 * scale, color: color.withValues(alpha: 0.6)),
                                            ),
                                            if (trophy.progress case (final value, final target)) ...[
                                              SizedBox(height: 8 * scale),
                                              SizedBox(
                                                width: 240 * scale,
                                                child: ProgressLine(
                                                  fraction: value / target,
                                                  color: accent,
                                                  height: 4 * scale,
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                      SizedBox(width: 16 * scale),
                                      if (revealable) ...[
                                        _RevealChip(
                                          key: ValueKey('trophy-reveal-$index'),
                                          shown: !secret,
                                          focused: focused,
                                          onTap: () => model.toggleReveal(index),
                                        ),
                                        SizedBox(width: 14 * scale),
                                      ],
                                      Column(
                                        crossAxisAlignment: CrossAxisAlignment.end,
                                        children: [
                                          Icon(
                                            Icons.emoji_events_rounded,
                                            size: 22 * scale,
                                            color: gradeColor(trophy.grade),
                                          ),
                                          SizedBox(height: 6 * scale),
                                          Text(
                                            earned
                                                ? '${trophy.unlocked!.toLocal().year}-${trophy.unlocked!.toLocal().month.toString().padLeft(2, '0')}-${trophy.unlocked!.toLocal().day.toString().padLeft(2, '0')}'
                                                : T.text('trophyLocked'),
                                            style: AppText.display(12 * scale, color: color.withValues(alpha: 0.6)),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                    ],
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

/// The game's leaderboard, from its trophies: for the pointer, and with the key when Enter
/// reaches it too.
class _BoardChip extends StatelessWidget {
  const _BoardChip({super.key, required this.keys, required this.onTap});

  final bool keys;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return Pressable(
      onTap: onTap,
      pressScale: 0.96,
      builder: (context, hovering) => AnimatedContainer(
        duration: Motion.focus,
        curve: Motion.settle,
        padding: EdgeInsets.symmetric(horizontal: 14 * scale, vertical: 8 * scale),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: hovering ? 0.14 : 0.08),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.leaderboard_rounded, size: 17 * scale, color: Colors.white),
            SizedBox(width: 8 * scale),
            if (keys)
              Hint(keys: 'Enter', glyph: PadGlyph.cross, label: T.text('socialBoardTitle'))
            else
              Text(T.text('socialBoardTitle'), style: AppText.display(15 * scale, weight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}

/// A hidden trophy's Show (or, once shown, Hide), for the pointer: the same as △ on it.
class _RevealChip extends StatelessWidget {
  const _RevealChip({super.key, required this.shown, required this.focused, required this.onTap});

  final bool shown;
  final bool focused;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final ink = focused ? LookScope.focusedInk(context) : Colors.white;
    return Semantics(
      button: true,
      child: Pressable(
        onTap: onTap,
        pressScale: 0.94,
        builder: (context, hovering) => AnimatedContainer(
          duration: Motion.focus,
          curve: Motion.settle,
          padding: EdgeInsets.symmetric(horizontal: 10 * scale, vertical: 6 * scale),
          decoration: BoxDecoration(
            color: ink.withValues(alpha: hovering ? 0.16 : 0.08),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              PadGlyphIcon(PadGlyph.triangle, size: 11 * scale, color: ink.withValues(alpha: 0.7)),
              SizedBox(width: 6 * scale),
              Text(
                T.text(shown ? 'trophyHide' : 'trophyShow'),
                style: AppText.display(12.5 * scale, weight: FontWeight.w600, color: ink.withValues(alpha: 0.85)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A text row's field: the cursor goes in when the row is chosen (or clicked), Enter sends it,
/// Esc gives the keys back to the launcher.
/// Settings' search: a field in the heading's line, its ring while the keys or the pad are on
/// it, a × to empty it.
class SettingsSearchField extends StatelessWidget {
  const SettingsSearchField({super.key, required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final row = model.settingsSearchField;
    final typing = model.editingRow == SettingsSearch.searchRow;
    final color = Colors.white.withValues(alpha: typing || model.searchingSettings ? 0.9 : 0.55);
    return Semantics(
      container: true,
      label: T.text('settingsSearchPrompt'),
      child: FocusRing(
        key: const ValueKey('settings-search'),
        focused: model.settingsSearchFocused && !typing,
        radius: 12 * scale,
        child: RowTextField(
          model: model,
          row: row,
          kind: row.kind as TextRow,
          focused: false,
          leading: Icon(Icons.search_rounded, size: 20 * scale, color: color),
          trailing: model.searchingSettings
              ? MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    key: const ValueKey('settings-search-clear'),
                    onTap: model.clearSettingsSearch,
                    child: Icon(Icons.close_rounded, size: 18 * scale, color: color),
                  ),
                )
              : null,
        ),
      ),
    );
  }
}

class RowTextField extends StatefulWidget {
  const RowTextField({
    super.key,
    required this.model,
    required this.row,
    required this.kind,
    required this.focused,
    this.leading,
    this.trailing,
  });

  final AppModel model;
  final PanelRow row;
  final TextRow kind;
  final bool focused;

  /// Drawn inside the field before and after the text (a search's magnifier and its ×).
  final Widget? leading;
  final Widget? trailing;

  @override
  State<RowTextField> createState() => _RowTextFieldState();
}

class _RowTextFieldState extends State<RowTextField> {
  late final TextEditingController _controller = TextEditingController(text: widget.kind.value);
  final FocusNode _node = FocusNode(debugLabel: 'row text');

  @override
  void initState() {
    super.initState();
    _node.addListener(_focusChanged);
    _follow();
  }

  @override
  void didUpdateWidget(RowTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_node.hasFocus && _controller.text != widget.kind.value) _controller.text = widget.kind.value;
    _follow();
  }

  /// The model says where the cursor is.
  void _follow() {
    final editing = widget.model.editingRow == widget.row.id;
    if (editing && !_node.hasFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.model.editingRow == widget.row.id) _node.requestFocus();
      });
    } else if (!editing && _node.hasFocus) {
      _node.unfocus();
    }
  }

  void _focusChanged() {
    if (_node.hasFocus) {
      if (widget.model.editingRow != widget.row.id) widget.model.startEditing(widget.row.id);
    } else if (widget.model.editingRow == widget.row.id) {
      widget.model.stopEditing();
    }
  }

  @override
  void dispose() {
    _node.removeListener(_focusChanged);
    _node.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final color = widget.focused ? LookScope.focusedInk(context) : Colors.white;
    final editing = widget.model.editingRow == widget.row.id;
    return AnimatedContainer(
      duration: Motion.focus,
      curve: Motion.settle,
      padding: EdgeInsets.symmetric(horizontal: 14 * scale, vertical: 8 * scale),
      decoration: BoxDecoration(
        color: color.withValues(alpha: editing ? 0.12 : 0.07),
        borderRadius: BorderRadius.circular(10 * scale),
        border: Border.all(
          color: editing ? widget.model.accentChoice.color : color.withValues(alpha: 0.14),
          width: 1.5 * scale,
        ),
      ),
      child: _framed(
        scale,
        TextField(
          controller: _controller,
          focusNode: _node,
          obscureText: widget.kind.obscure,
          onChanged: widget.kind.set,
          onSubmitted: (_) {
            widget.kind.submit?.call();
            widget.model.stopEditing();
          },
          cursorColor: widget.focused ? LookScope.focusedInk(context) : widget.model.accentChoice.color,
          style: AppText.display(16 * scale, weight: FontWeight.w500, color: color),
          decoration: InputDecoration.collapsed(
            hintText: widget.kind.hint,
            hintStyle: AppText.display(16 * scale, color: color.withValues(alpha: 0.35)),
          ),
        ),
      ),
    );
  }

  Widget _framed(double scale, Widget field) {
    if (widget.leading == null && widget.trailing == null) return field;
    return Row(
      children: [
        if (widget.leading != null) ...[widget.leading!, SizedBox(width: 10 * scale)],
        Expanded(child: field),
        if (widget.trailing != null) ...[SizedBox(width: 8 * scale), widget.trailing!],
      ],
    );
  }
}

/// Someone's picture, or their initials on the accent, with a dot for what they do and a ring
/// while they speak.
class PersonAvatar extends StatelessWidget {
  const PersonAvatar({super.key, required this.person, required this.size, this.focused = false});

  final PanelPerson person;
  final double size;
  final bool focused;

  static Color statusColor(PersonStatus status) => switch (status) {
    PersonStatus.playing => const Color(0xFF6FA8FF),
    PersonStatus.online => Palette.success,
    PersonStatus.away || PersonStatus.idle => Palette.warning,
    PersonStatus.dnd => const Color(0xFFF2545B),
    PersonStatus.offline => const Color(0xFF8A8F98),
  };

  @override
  Widget build(BuildContext context) {
    final initials = Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: person.tint == null
              ? [const Color(0xFF5B6B8C), const Color(0xFF2B3346).withValues(alpha: 0.9)]
              : [person.tint!, Color.lerp(person.tint, Colors.black, 0.45)!],
        ),
      ),
      child: Text(person.initials, style: AppText.display(size * 0.38, weight: FontWeight.w700)),
    );
    final avatar = person.avatar;
    final picture = person.picture;
    return SizedBox.square(
      dimension: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          AnimatedContainer(
            duration: Motion.focus,
            curve: Motion.settle,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Palette.success.withValues(alpha: person.speaking ? 0.9 : 0),
                  spreadRadius: size * 0.06,
                ),
              ],
            ),
            child: ClipOval(
              child: picture != null
                  ? Image(
                      image: ArtworkImage.provider(picture, ProfilePicture.size),
                      width: size,
                      height: size,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => initials,
                    )
                  : avatar == null
                  ? initials
                  : Image.network(
                      avatar,
                      width: size,
                      height: size,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => initials,
                    ),
            ),
          ),
          if (person.status != null)
            PositionedDirectional(
              end: -size * 0.02,
              bottom: -size * 0.02,
              child: StatusDot(
                status: person.status!,
                size: size * 0.3,
                ring: focused ? Colors.white : Colors.black,
                ringWidth: size * 0.06,
              ),
            ),
        ],
      ),
    );
  }
}

/// "12 players online now" by Find players' heading: the online colour's dot and the count, with
/// who is left out (invisible accounts) as its tooltip. A number only, never who.
class OnlineNowLine extends StatelessWidget {
  const OnlineNowLine({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final hint = T.text('discoverOnlineNowHint');
    return Tooltip(
      message: hint,
      child: Semantics(
        label: '$text. $hint',
        excludeSemantics: true,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 9 * scale,
              height: 9 * scale,
              decoration: BoxDecoration(
                color: PersonAvatar.statusColor(PersonStatus.online),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: PersonAvatar.statusColor(PersonStatus.online).withValues(alpha: 0.55),
                    blurRadius: 10 * scale,
                  ),
                ],
              ),
            ),
            SizedBox(width: 10 * scale),
            Flexible(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.display(
                  17 * scale,
                  weight: FontWeight.w500,
                  color: Colors.white.withValues(alpha: 0.62),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A person's status dot in a ring: a plain dot, a crescent moon for idle, a dot with a bar
/// across for do not disturb, as friends know them from chat apps.
class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.status, required this.size, required this.ring, required this.ringWidth});

  final PersonStatus status;

  /// Its width with the ring.
  final double size;
  final Color ring;
  final double ringWidth;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size.square(size),
    painter: _StatusDotPainter(status: status, ring: ring, ringWidth: ringWidth),
  );
}

class _StatusDotPainter extends CustomPainter {
  const _StatusDotPainter({required this.status, required this.ring, required this.ringWidth});

  final PersonStatus status;
  final Color ring;
  final double ringWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final outer = size.shortestSide / 2;
    final inner = (outer - ringWidth).clamp(1.0, outer);
    canvas.drawCircle(center, outer, Paint()..color = ring);
    final fill = Paint()..color = PersonAvatar.statusColor(status);
    switch (status) {
      case PersonStatus.idle:
        // The moon: the dot with a circle of the ring's colour bitten out of its top left.
        final dot = Path()..addOval(Rect.fromCircle(center: center, radius: inner));
        final bite = Path()
          ..addOval(Rect.fromCircle(center: center + Offset(-inner * 0.5, -inner * 0.5), radius: inner * 0.62));
        canvas.drawPath(Path.combine(PathOperation.difference, dot, bite), fill);
      case PersonStatus.dnd:
        canvas.drawCircle(center, inner, fill);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(center: center, width: inner * 1.25, height: inner * 0.42),
            Radius.circular(inner * 0.21),
          ),
          Paint()..color = ring,
        );
      default:
        canvas.drawCircle(center, inner, fill);
    }
  }

  @override
  bool shouldRepaint(_StatusDotPainter old) => old.status != status || old.ring != ring || old.ringWidth != ringWidth;
}

/// The selected game's pictures: a grid, or one over the whole screen.
class GalleryView extends StatelessWidget {
  const GalleryView({super.key, required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final game = model.selectedGame;
    final shots = model.galleryShots;
    final muted = Colors.white.withValues(alpha: 0.6);
    if (model.galleryViewing && shots.isNotEmpty) {
      final index = model.galleryIndex.clamp(0, shots.length - 1);
      // The ‹ › are for the mouse: with a controller ← and → do it.
      final arrows = !InputScope.pad(context);
      return ColoredBox(
        color: Colors.black.withValues(alpha: 0.94),
        child: WithBackPill(
          onBack: () => model.handle(Command.back),
          child: Padding(
            padding: EdgeInsets.fromLTRB(70 * scale, 80 * scale, 70 * scale, 40 * scale),
            child: Column(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      if (arrows)
                        _StepArrow(
                          key: const ValueKey('shot-previous'),
                          icon: Icons.chevron_left_rounded,
                          enabled: index > 0,
                          focused: false,
                          onTap: () => model.handle(Command.left),
                        )
                      else
                        SizedBox(width: 32 * scale),
                      SizedBox(width: 16 * scale),
                      Expanded(
                        child: Screenshots.isClip(shots[index])
                            // A clip plays from the start, over and over, as on the Mac; a click on
                            // it does not close it (its bar is under the pointer).
                            ? Center(
                                child: AspectRatio(
                                  aspectRatio: 16 / 9,
                                  child: ClipRRect(
                                    key: const ValueKey('shot-large'),
                                    borderRadius: BorderRadius.circular(12 * scale),
                                    child: ClipPlayerView(
                                      source: shots[index],
                                      create: model.services.clipPlayback,
                                      onFailed: model.playClipOutside,
                                      accent: model.accentChoice.color,
                                      poster: _ClipTile(path: shots[index], accent: model.accentChoice.color),
                                    ),
                                  ),
                                ),
                              )
                            : Pressable(
                                key: const ValueKey('shot-large'),
                                pressScale: 1,
                                onTap: () => model.handle(Command.back),
                                builder: (context, _) => ClipRRect(
                                  borderRadius: BorderRadius.circular(12 * scale),
                                  child: ArtworkImage(path: shots[index], fit: BoxFit.contain, cacheWidth: 1920),
                                ),
                              ),
                      ),
                      SizedBox(width: 16 * scale),
                      if (arrows)
                        _StepArrow(
                          key: const ValueKey('shot-next'),
                          icon: Icons.chevron_right_rounded,
                          enabled: index < shots.length - 1,
                          focused: false,
                          onTap: () => model.handle(Command.right),
                        )
                      else
                        SizedBox(width: 32 * scale),
                    ],
                  ),
                ),
                SizedBox(height: 16 * scale),
                Text(
                  '${index + 1} / ${shots.length} · ${p.basename(shots[index])}',
                  style: AppText.display(14 * scale, color: muted),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final size = 330 * scale;
    return _Scrim(
      opacity: 0.74,
      child: WithBackPill(
        onBack: () => model.handle(Command.back),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 80 * scale, vertical: 60 * scale),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(T.text('screenshotsTitle'), style: AppText.display(40 * scale, weight: FontWeight.w300)),
                  SizedBox(width: 14 * scale),
                  if (game != null)
                    Flexible(
                      child: Padding(
                        padding: EdgeInsets.only(bottom: 6 * scale),
                        child: Text(
                          game.nameFor([T.language.code]),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.display(20 * scale, color: muted),
                        ),
                      ),
                    ),
                ],
              ),
              SizedBox(height: 26 * scale),
              Expanded(
                child: shots.isEmpty
                    ? Text(T.text('screenshotsNone'), style: AppText.display(17 * scale, color: muted))
                    : SingleChildScrollView(
                        padding: EdgeInsets.all(14 * scale),
                        child: Wrap(
                          spacing: 22 * scale,
                          runSpacing: 22 * scale,
                          children: [
                            for (var index = 0; index < shots.length; index++)
                              KeepVisible(
                                active: index == model.galleryIndex,
                                child: Pressable(
                                  key: ValueKey('shot-$index'),
                                  onTap: () => model.tapShot(index),
                                  builder: (context, hovering) => SizedBox(
                                    width: size,
                                    height: size * 9 / 16,
                                    child: FocusRing(
                                      focused: index == model.galleryIndex,
                                      radius: 12 * scale,
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(12 * scale),
                                        child: ColoredBox(
                                          color: Colors.white.withValues(alpha: hovering ? 0.14 : 0.06),
                                          child: Screenshots.isClip(shots[index])
                                              ? _ClipTile(path: shots[index], accent: model.accentChoice.color)
                                              : ArtworkImage(path: shots[index], cacheWidth: 480),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
              ),
              SizedBox(height: 14 * scale),
              const Align(alignment: AlignmentDirectional.centerEnd, child: HintBar(options: false, games: false)),
            ],
          ),
        ),
      ),
    );
  }
}

/// A clip in the gallery: the picture of its last moment (when ffmpeg made one) under a play
/// badge and its length's mark; ✕ or a click plays it over the whole screen.
class _ClipTile extends StatelessWidget {
  const _ClipTile({required this.path, required this.accent});

  final String path;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final thumbnail = ReplayBuffer.thumbnailOf(path);
    final hasThumbnail = File(thumbnail).existsSync();
    return Stack(
      fit: StackFit.expand,
      children: [
        if (hasThumbnail)
          ArtworkImage(path: thumbnail, cacheWidth: 480)
        else
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [accent.withValues(alpha: 0.35), Colors.black.withValues(alpha: 0.6)],
              ),
            ),
          ),
        Center(
          child: Container(
            key: const ValueKey('clip-badge'),
            width: 56 * scale,
            height: 56 * scale,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.black.withValues(alpha: 0.45),
              border: Border.all(color: Colors.white.withValues(alpha: 0.85), width: 2 * scale),
            ),
            child: Icon(Icons.play_arrow_rounded, size: 34 * scale, color: Colors.white),
          ),
        ),
        PositionedDirectional(
          start: 12 * scale,
          bottom: 10 * scale,
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 8 * scale, vertical: 3 * scale),
            decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(6 * scale)),
            child: Text(
              T.upper(T.text('clip')),
              style: AppText.display(11 * scale, weight: FontWeight.w700).copyWith(letterSpacing: 1.2 * scale),
            ),
          ),
        ),
      ],
    );
  }
}

/// The thin bar a row can carry: two parts of the width, the second fainter, over a dim track.
class _MeterBar extends StatelessWidget {
  const _MeterBar({required this.meter, required this.color, required this.scale});

  final PanelMeter meter;
  final Color color;
  final double scale;

  @override
  Widget build(BuildContext context) {
    final height = 6 * scale;
    final radius = BorderRadius.circular(height);
    return ClipRRect(
      borderRadius: radius,
      child: SizedBox(
        height: height,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            Widget part(double fraction, Color tint) => SizedBox(
              width: (fraction.clamp(0.0, 1.0)) * width,
              child: ColoredBox(color: tint),
            );
            return ColoredBox(
              color: Colors.white.withValues(alpha: 0.1),
              child: Row(children: [part(meter.first, color), part(meter.second, color.withValues(alpha: 0.45))]),
            );
          },
        ),
      ),
    );
  }
}
