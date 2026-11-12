import 'dart:async';

import 'package:flutter/material.dart';

import '../core/family/family_rules.dart' show TitleVerdict;
import '../core/game_addons.dart';
import '../core/game_library.dart';
import '../core/update_notice.dart' show SelfApply;
import '../core/controllers/troubleshooter.dart';
import '../core/together/compat.dart' show CompatStatus, CompatSummary;
import 'app_model.dart';
import 'background.dart';
import 'components.dart';
import 'controller_test_view.dart' show PadStatusPill;
import 'drag_pan.dart';
import 'engine_git_model.dart';
import 'game_action.dart';
import 'glass.dart';
import 'level_badge.dart';
import 'padlock.dart';
import 'panels.dart' show StatusDot;
import 'profiles_view.dart' show ProfileSwitcherList, ProfileTile;
import 'retro_folder_tile.dart';
import 'strings.dart';
import 'theme.dart';
import 'together_model.dart';

/// The theme animation and the selected game's artwork over it.
class Backdrop extends StatelessWidget {
  const Backdrop({super.key, required this.model, this.time});

  final AppModel model;

  /// A fixed moment of the theme animation, for previews and tests.
  final double? time;

  @override
  Widget build(BuildContext context) {
    final game = model.homePreviewGame;
    final background = game?.background;
    final backgroundKey = ValueKey(game?.id);
    final artwork =
        model.preferences.onboarded &&
        model.preferences.gameArtwork &&
        model.overlay != Layer.settings &&
        // In the Theme Studio the theme itself is what is looked at.
        model.overlay != Layer.themeStudio &&
        background != null;
    // Under a layer the background is blurred and darkened: kept still, the blur is not worked
    // out again on every frame, which is what made opening and closing layers stutter.
    // The Theme Studio is the exception: its changes show behind it as they are made.
    final covered = (model.overlay != null && model.overlay != Layer.themeStudio) || model.starting != null;
    // Glass shows the picture frosted, from a small decode, and still; over the whole screen it
    // hides the background, which then rests.
    final glass = model.look == LookStyle.glass;
    // Glass's see-through window: the desktop is the background, the picture only when asked.
    final seeThrough = model.glassWindow.seeThrough;
    if (seeThrough && model.ownBackground == null) {
      final shown =
          model.preferences.onboarded &&
          model.preferences.glassArtwork &&
          model.overlay != Layer.settings &&
          background != null;
      return RepaintBoundary(
        child: AnimatedSwitcher(
          layoutBuilder: uniqueSwitcherLayout(),
          duration: Motion.fade,
          switchInCurve: Motion.settle,
          child: shown
              ? Opacity(
                  key: backgroundKey,
                  opacity: 0.72,
                  child: GameArtwork(path: background, animated: false),
                )
              : const SizedBox.expand(),
        ),
      );
    }
    if (artwork && time == null) {
      final index = model.selected;
      for (final near in [index - 1, index + 1]) {
        if (near >= 0 && near < model.games.length) {
          ArtworkImage.warm(
            context,
            model.games[near].background,
            cacheWidth: glass ? GlassRecipe.artworkWidth : GameArtwork.cacheWidth,
          );
        }
      }
    }
    // Still while a game runs (in front or not: the GPU is the game's), while the launcher is not
    // in front, under a layer and with reduced motion.
    final still =
        model.running != null || model.resting || model.preferences.reducedMotion || covered || (glass && artwork);
    final animation = ThemeBackground(style: model.look, palette: model.palette, paused: still, time: time);
    // The user's own picture or video (Appearance › Background, or the theme's), else the animation.
    final own = model.ownBackground;
    return Stack(
      fit: StackFit.expand,
      children: [
        AnimatedSwitcher(
          layoutBuilder: uniqueSwitcherLayout(),
          duration: Motion.fade,
          child: KeyedSubtree(
            key: ValueKey(own?.path),
            child: switch (own) {
              null => animation,
              (:final path, video: true) => LoopingVideoView(
                path: path,
                ffmpeg: model.replayFfmpeg,
                paused: still || time != null,
                fallback: animation,
              ),
              (:final path, video: false) => DriftingImage(path: path, animated: !still && time == null),
            },
          ),
        ),
        RepaintBoundary(
          child: AnimatedSwitcher(
            layoutBuilder: uniqueSwitcherLayout(),
            duration: Motion.fade,
            switchInCurve: Motion.settle,
            child: artwork
                ? GameArtwork(
                    key: backgroundKey,
                    path: background,
                    animated:
                        !model.preferences.reducedMotion &&
                        time == null &&
                        !covered &&
                        !glass &&
                        model.running == null &&
                        !model.resting,
                  )
                : const SizedBox.expand(),
          ),
        ),
      ],
    );
  }
}

class HomeView extends StatefulWidget {
  const HomeView({super.key, required this.model, this.now});

  final AppModel model;
  final DateTime? now;

  @override
  State<HomeView> createState() => _HomeViewState();
}

class _HomeViewState extends State<HomeView> {
  /// Ties the profile list to the picture in the top bar it drops from.
  final LayerLink _profileLink = LayerLink();

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    final now = widget.now;
    final scale = LayoutScale.of(context);
    final game = model.homePreviewGame;
    // Glass's panes on the home screen never overlap: they share one blur of the background.
    return BackdropGroup(
      child: Stack(
        fit: StackFit.expand,
        children: [
          _body(context, model, now, scale, game),
          if (model.profileListOpen) ...[
            // A click anywhere else closes the list, and still does what it was for.
            Positioned.fill(
              child: Listener(behavior: HitTestBehavior.translucent, onPointerDown: (_) => model.closeProfileList()),
            ),
            Positioned(
              left: 0,
              top: 0,
              child: CompositedTransformFollower(
                link: _profileLink,
                showWhenUnlinked: false,
                targetAnchor: Alignment.bottomCenter,
                followerAnchor: Alignment.topCenter,
                offset: Offset(0, 12 * scale),
                child: ProfileSwitcherList(model: model),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _body(BuildContext context, AppModel model, DateTime? now, double scale, Game? game) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(64 * scale, 34 * scale, 64 * scale, 0),
          child: TopBar(model: model, now: now, profileLink: _profileLink),
        ),
        if (model.games.isEmpty)
          Expanded(child: EmptyLibrary(model: model))
        else ...[
          SizedBox(height: 34 * scale),
          TileRow(model: model),
          if (model.homeFolderPlatform != null) ...[
            SizedBox(height: 24 * scale),
            TileRow(key: const ValueKey('retro-folder-games'), model: model, folderContents: true),
          ],
          const Spacer(),
          if (game != null)
            AnimatedSwitcher(
              layoutBuilder: uniqueSwitcherLayout(),
              duration: Motion.layout,
              switchInCurve: Motion.settle,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween(begin: const Offset(0, 0.04), end: Offset.zero).animate(animation),
                  child: child,
                ),
              ),
              child: Padding(
                key: ValueKey(game.id),
                padding: EdgeInsets.symmetric(horizontal: 72 * scale),
                child: HeroInfo(model: model, game: game),
              ),
            ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 64 * scale, vertical: 28 * scale),
            child: Align(
              alignment: AlignmentDirectional.centerEnd,
              child: Legible(softness: 14, child: HintBar(options: model.selectedHomeFolder == null)),
            ),
          ),
        ],
      ],
    );
  }
}

/// The launcher's own update, ready: a quiet line beside the top bar's buttons with Restart Now
/// (Show File where the user puts it in place) and Later; nothing blocks, nothing comes back
/// after Later. With a game running, Restart Now waits for it and the line says so.
class UpdateNoticeBar extends StatelessWidget {
  const UpdateNoticeBar({super.key, required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final updates = model.updates;
    final waiting = updates.restartAfterGame;
    final manual = updates.apply == SelfApply.manual;
    final version = updates.downloadedVersion ?? '';
    final accent = model.accentChoice.color;
    Widget pill(String title, int index, VoidCallback action) {
      final focused = model.focus == HomeFocus.notice(index) && model.overlay == null;
      return Pressable(
        key: ValueKey('update-notice-$index'),
        onTap: action,
        builder: (context, hovering) => AnimatedScale(
          scale: focused ? 1.05 : 1,
          duration: Motion.focus,
          curve: Motion.settle,
          child: AnimatedContainer(
            duration: Motion.focus,
            height: 34 * scale,
            padding: EdgeInsets.symmetric(horizontal: 14 * scale),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(17 * scale),
              color: focused
                  ? Colors.white
                  : Colors.white.withValues(alpha: (index == 0 ? 0.14 : 0.06) + (hovering ? 0.06 : 0)),
            ),
            child: Text(
              title,
              style: AppText.display(
                13 * scale,
                weight: FontWeight.w600,
                color: focused ? Colors.black : Colors.white.withValues(alpha: index == 0 ? 0.95 : 0.7),
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      height: 44 * scale,
      padding: EdgeInsetsDirectional.only(start: 16 * scale, end: 5 * scale),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.32),
        borderRadius: BorderRadius.circular(22 * scale),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            waiting ? Icons.hourglass_top_rounded : Icons.download_for_offline_rounded,
            size: 18 * scale,
            color: accent,
          ),
          SizedBox(width: 10 * scale),
          Text(
            waiting
                ? T.text('desktopRestartWaiting')
                : T.format(manual ? 'desktopNoticeDownloaded' : 'desktopNoticeReady', [version]),
            style: AppText.display(15 * scale, weight: FontWeight.w500, color: Colors.white.withValues(alpha: 0.92)),
          ),
          SizedBox(width: 12 * scale),
          pill(
            T.text(waiting ? 'desktopCancelRestart' : (manual ? 'desktopShowFile' : 'desktopRestartNow')),
            0,
            () => waiting ? updates.cancelRestart() : unawaited(updates.restartNow()),
          ),
          if (!waiting) ...[SizedBox(width: 6 * scale), pill(T.text('desktopLater'), 1, updates.later)],
        ],
      ),
    );
  }
}

/// Home's line for the engine's own work (Update from Git): the step, and a click to its
/// settings. The games waiting on it say so on their own buttons.
class EngineJobPill extends StatelessWidget {
  const EngineJobPill({super.key, required this.model, required this.job});

  final AppModel model;
  final EngineJob job;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final accent = model.accentChoice.color;
    final text = switch (job.step) {
      null => T.text('engineGitChecking'),
      final step => T.format('homeEngineBuild', [EngineGitModel.stepName(step)]),
    };
    return Pressable(
      onTap: model.openEngineSettings,
      builder: (context, hovering) => AnimatedContainer(
        duration: Motion.focus,
        height: 34 * scale,
        padding: EdgeInsets.symmetric(horizontal: 14 * scale),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: hovering ? 0.42 : 0.32),
          borderRadius: BorderRadius.circular(17 * scale),
          border: Border.all(color: accent.withValues(alpha: 0.45)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.construction_rounded, size: 16 * scale, color: accent),
            SizedBox(width: 10 * scale),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: 360 * scale),
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.display(
                  14 * scale,
                  weight: FontWeight.w500,
                  color: Colors.white.withValues(alpha: 0.92),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class TopBar extends StatelessWidget {
  const TopBar({super.key, required this.model, this.now, this.profileLink});

  final AppModel model;
  final DateTime? now;

  /// What Home's profile list follows: the picture at the end of the bar.
  final LayerLink? profileLink;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final accent = model.accentChoice.color;
    final together = model.together;
    final name = together.user?.displayName ?? model.preferences.profileName;
    final level = together.signedIn ? together.hub.self.level : null;
    // The status the user chose, when it is not plain online: its dot and its word.
    final ownDot = together.signedIn ? TogetherModel.ownDot(together.myStatus) : null;
    final glass = LookScope.isGlass(context);
    // The keys are on the profile picture (its list is open under it).
    final pictureFocused = model.focus == const HomeFocus.switcher(0) && model.overlay == null;
    Widget linked(Widget picture) =>
        profileLink == null ? picture : CompositedTransformTarget(link: profileLink!, child: picture);
    Widget iconButton(IconData icon, int index, VoidCallback action, {int badge = 0, bool dot = false}) {
      final focused = model.focus == HomeFocus.top(index) && model.overlay == null;
      return Pressable(
        onTap: action,
        builder: (context, hovering) => AnimatedScale(
          scale: focused ? (glass ? 1.08 : 1.1) : (hovering ? 1.05 : 1),
          duration: Motion.focus,
          curve: Motion.settle,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              if (glass)
                IceSurface(
                  radius: 22 * scale,
                  width: 44 * scale,
                  height: 44 * scale,
                  focused: focused,
                  hover: hovering,
                  sweep: true,
                  child: Icon(icon, size: 20 * scale, color: focused ? GlassRecipe.ink : Colors.white),
                )
              else
                AnimatedContainer(
                  duration: Motion.focus,
                  width: 44 * scale,
                  height: 44 * scale,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: focused ? Colors.white : Colors.white.withValues(alpha: hovering ? 0.2 : 0.1),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.white.withValues(alpha: focused ? 0.4 : 0),
                        blurRadius: 10 * scale,
                      ),
                    ],
                  ),
                  child: Icon(
                    icon,
                    size: 20 * scale,
                    color: focused ? Colors.black : Colors.white.withValues(alpha: 0.9),
                  ),
                ),
              // Something unread that is not worth a number (the party chat), as on the Mac.
              if (dot && badge == 0)
                PositionedDirectional(
                  end: 0,
                  top: 0,
                  child: Container(
                    key: ValueKey('home-dot-$index'),
                    width: 12 * scale,
                    height: 12 * scale,
                    decoration: BoxDecoration(
                      color: accent,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.black.withValues(alpha: 0.5), width: 1.5 * scale),
                    ),
                  ),
                ),
              if (badge > 0)
                PositionedDirectional(
                  end: -4 * scale,
                  top: -4 * scale,
                  child: Container(
                    constraints: BoxConstraints(minWidth: 20 * scale),
                    height: 20 * scale,
                    padding: EdgeInsets.symmetric(horizontal: 5 * scale),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: accent,
                      borderRadius: BorderRadius.circular(10 * scale),
                      border: Border.all(color: Colors.black.withValues(alpha: 0.5), width: 1.5 * scale),
                    ),
                    child: Text(
                      badge > 9 ? '9+' : '$badge',
                      style: AppText.display(
                        11 * scale,
                        weight: FontWeight.w700,
                        color: LookScope.inkOnAccent(context, accent, Colors.black),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    }

    return Row(
      children: [
        Legible(
          softness: 14,
          child: Text(T.text('games'), style: AppText.display(24 * scale, weight: FontWeight.w600)),
        ),
        if (model.scanning) ...[
          SizedBox(width: 16 * scale),
          SizedBox(
            width: 16 * scale,
            height: 16 * scale,
            child: const CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
          ),
        ],
        // The engine being checked or built shows wherever the player is, not only in Settings.
        AnimatedSwitcher(
          layoutBuilder: uniqueSwitcherLayout(),
          duration: Motion.focus,
          child: switch (model.engine.git.job) {
            final EngineJob job => Padding(
              key: const ValueKey('engine-job'),
              padding: EdgeInsetsDirectional.only(start: 20 * scale),
              child: EngineJobPill(model: model, job: job),
            ),
            null => const SizedBox.shrink(),
          },
        ),
        const Spacer(),
        AnimatedSwitcher(
          layoutBuilder: uniqueSwitcherLayout(),
          duration: Motion.focus,
          child: model.updates.showsNotice
              ? Padding(
                  key: const ValueKey('update-notice'),
                  padding: EdgeInsetsDirectional.only(end: 22 * scale),
                  child: UpdateNoticeBar(model: model),
                )
              : const SizedBox.shrink(),
        ),
        iconButton(Icons.grid_view_rounded, 0, () => model.open(Layer.library)),
        SizedBox(width: 22 * scale),
        iconButton(Icons.settings_rounded, 1, () => model.open(Layer.settings)),
        SizedBox(width: 22 * scale),
        iconButton(Icons.people_alt_rounded, 2, () => model.open(Layer.friends), badge: together.hub.badge),
        SizedBox(width: 22 * scale),
        iconButton(Icons.chat_bubble_rounded, 3, () => unawaited(together.openMessages()), badge: together.unread),
        SizedBox(width: 22 * scale),
        iconButton(
          together.hub.voice.active
              ? (together.hub.voice.sending ? Icons.mic_rounded : Icons.mic_off_rounded)
              : (together.hub.parties.party == null ? Icons.groups_outlined : Icons.groups_rounded),
          4,
          () => model.open(Layer.party),
          badge: together.partyBadge,
          dot: together.partyChatUnread > 0,
        ),
        SizedBox(width: 22 * scale),
        // AnyTogether's notifications, while signed in: the bell with the unread count.
        if (together.signedIn) ...[
          iconButton(
            together.hub.social.notices.unread > 0 ? Icons.notifications_active_rounded : Icons.notifications_rounded,
            5,
            together.openNotifications,
            badge: together.hub.social.notices.unread,
          ),
          SizedBox(width: 22 * scale),
        ],
        // A controller running out of battery says so here (and in Settings › Controllers).
        if (PadTroubleshooter.statusPad(model.controllers.pads) case final pad?) ...[
          PadStatusPill(pad: pad),
          SizedBox(width: 12 * scale),
        ],
        // The phone controller's pill only while a phone is connected or connecting: a launcher
        // used without one keeps the bar clear.
        if (PhoneIndicator.shows(model)) ...[PhoneIndicator(model: model), SizedBox(width: 22 * scale)],
        // The picture opens the profile list under it: the pointer on it, a click, or the keys
        // past the last button.
        linked(
          MouseRegion(
            onEnter: (_) => model.showProfileList(),
            onExit: (_) => model.leaveProfileList(),
            child: Pressable(
              onTap: model.showProfileList,
              builder: (context, hovering) => AnimatedScale(
                scale: pictureFocused ? 1.1 : (hovering ? 1.05 : 1),
                duration: Motion.focus,
                curve: Motion.settle,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    // The keys' focus only: a white ring a little off the picture.
                    if (pictureFocused)
                      Positioned(
                        key: const ValueKey('home-avatar-ring'),
                        left: -5 * scale,
                        top: -5 * scale,
                        right: -5 * scale,
                        bottom: -5 * scale,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 2.5 * scale),
                            boxShadow: [BoxShadow(color: Colors.white.withValues(alpha: 0.35), blurRadius: 10 * scale)],
                          ),
                        ),
                      ),
                    // The profile playing: its picture, or its initial on its own colour (Settings ›
                    // Profiles), so a change there shows here at once.
                    ProfileTile(
                      key: const ValueKey('home-avatar'),
                      profile: model.currentProfile,
                      picture: model.profiles.pictureOf(model.currentProfile),
                      size: 36 * scale,
                    ),
                    // Idle, do not disturb or invisible: the dot on the picture, as friends see it.
                    if (ownDot != null)
                      PositionedDirectional(
                        end: -2 * scale,
                        bottom: -2 * scale,
                        child: StatusDot(status: ownDot, size: 14 * scale, ring: Colors.black, ringWidth: 2.2 * scale),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        SizedBox(width: 10 * scale),
        // The name, the level and the clock share one plate.
        Legible(
          softness: 12,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: AppText.display(
                      16 * scale,
                      weight: FontWeight.w500,
                      color: Colors.white.withValues(alpha: 0.9),
                    ),
                  ),
                  if (ownDot != null)
                    Text(
                      TogetherModel.ownStatusText(together.myStatus),
                      style: AppText.display(
                        12 * scale,
                        weight: FontWeight.w500,
                        color: Colors.white.withValues(alpha: 0.55),
                      ),
                    ),
                ],
              ),
              if (level != null) ...[SizedBox(width: 10 * scale), LevelBadgeView(level: level, size: 30 * scale)],
              SizedBox(width: 22 * scale),
              Clock(now: now),
            ],
          ),
        ),
      ],
    );
  }
}

/// The phone controller's light: green with a phone, orange while one connects. Hidden with none
/// (Settings › Phones says how to connect one).
class PhoneIndicator extends StatelessWidget {
  const PhoneIndicator({super.key, required this.model});

  final AppModel model;

  /// Whether the top bar shows it: a phone connected or one connecting.
  static bool shows(AppModel model) =>
      (model.remote?.connectedDevices.isNotEmpty ?? false) || model.phoneConnecting != null;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final phones = model.remote?.connectedDevices ?? const [];
    final color = phones.isNotEmpty ? Palette.success : (model.phoneConnecting != null ? Palette.connecting : null);
    final glass = LookScope.isGlass(context);
    final padding = EdgeInsets.symmetric(horizontal: 14 * scale, vertical: 8 * scale);
    final content = _content(scale, phones, color, glass);
    if (glass) return IceSurface(radius: 20 * scale, padding: padding, child: content);
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(40 * scale),
      ),
      child: content,
    );
  }

  Widget _content(double scale, List<Object?> phones, Color? color, bool glass) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 9 * scale,
        height: 9 * scale,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          border: color == null ? Border.all(color: Colors.white.withValues(alpha: 0.45), width: 1.5 * scale) : null,
          boxShadow: color == null ? null : [BoxShadow(color: color, blurRadius: 4 * scale)],
        ),
      ),
      SizedBox(width: 8 * scale),
      Text(
        phones.length > 1 ? T.format('phoneControllers', [phones.length]) : T.text('phoneServer'),
        style: AppText.display(
          14 * scale,
          weight: FontWeight.w600,
          color: Colors.white.withValues(alpha: color == null ? (glass ? 0.9 : 0.55) : 0.9),
        ),
      ),
      if (phones.isNotEmpty && model.phoneLatency != null) ...[
        SizedBox(width: 8 * scale),
        latency(model.phoneLatency!, scale, glass),
      ],
    ],
  );

  /// The round trip in ms, in figures of one width and as wide as 999 ms always: the pill does
  /// not jump as the number goes from one digit to three.
  static Widget latency(double milliseconds, double scale, bool glass) {
    final style = AppText.display(
      14 * scale,
      weight: FontWeight.w600,
      color: Colors.white.withValues(alpha: glass ? 0.9 : 0.6),
    ).copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
    final shown = milliseconds.round().clamp(0, 999);
    return Stack(
      alignment: AlignmentDirectional.centerEnd,
      children: [
        // The widest it gets, unseen: it sets the width.
        Visibility(
          visible: false,
          maintainSize: true,
          maintainAnimation: true,
          maintainState: true,
          child: Text('999 ms', style: style),
        ),
        Text('$shown ms', key: const ValueKey('phone-latency'), style: style),
      ],
    );
  }
}

/// The row of game tiles: the selected one is larger, sits at the row's start and carries the
/// game's name beside it, as on the console.
class TileRow extends StatelessWidget {
  const TileRow({super.key, required this.model, this.folderContents = false});

  final AppModel model;
  final bool folderContents;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final rowFocused = folderContents == (model.activeHomeRetroFolder != null);
    final preview = folderContents && !rowFocused;
    final small = (folderContents ? 112 : 118) * scale;
    final large = (folderContents ? 148 : 176) * scale;
    final gap = 16 * scale;
    final label = 300 * scale;
    final leading = 64 * scale;
    final tiles = folderContents ? model.homeFolderTiles : model.homeTiles;
    final at = preview ? 0 : model.homeTileIndex(tiles, folderContents: folderContents);
    return _TileDrag(
      model: model,
      folderContents: folderContents,
      step: small + gap,
      child: SizedBox(
        height: large + 10 * scale,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            for (final (index, tile) in tiles.indexed)
              ...() {
                final game = model.games[tile.gameIndex];
                final folder = tile.folder;
                final console = folder;
                final id = folder == null ? game.id : 'folder-${folder.name}';
                final selected = index == at;
                final offset = index - at;
                final x = preview
                    ? leading + index * (small + gap)
                    : offset < 0
                    ? leading + offset * (small + gap)
                    : offset == 0
                    ? leading
                    : leading + large + gap + label + (offset - 1) * (small + gap);
                final size = selected && !preview ? large : small;
                return [
                  AnimatedPositionedDirectional(
                    key: ValueKey('tile-$id'),
                    duration: Motion.layout,
                    curve: Motion.settle,
                    start: x,
                    top: selected || preview ? 0 : (large - small) * 0.18,
                    width: size,
                    height: size,
                    child: AnimatedOpacity(
                      duration: Motion.layout,
                      opacity: offset < 0 ? 0 : 1,
                      // A click selects at once (a GestureDetector with a double tap would wait to
                      // see whether a second click comes); a second click plays.
                      child: Pressable(
                        key: ValueKey('tile-press-$id'),
                        onHover: console != null && !selected && offset >= 0
                            ? () {
                                if (!model.panning && model.overlay == null) {
                                  model.selectHomeTile(index, folderContents: folderContents);
                                }
                              }
                            : null,
                        onTap: () {
                          model.selectHomeTile(index, folderContents: folderContents);
                          if (console != null) model.openSelectedHomeFolder();
                        },
                        onDoubleTap: console == null
                            ? () {
                                model.selectHomeTile(index, folderContents: folderContents);
                                model.primaryAction(game);
                              }
                            : null,
                        builder: (context, _) {
                          final focused = selected && rowFocused && model.focus.isTiles && model.overlay == null;
                          if (console != null) {
                            return RetroFolderTile(
                              console: console,
                              size: size,
                              focused: focused,
                              accent: model.accentChoice.color,
                            );
                          }
                          return GameTile(model: model, game: game, size: size, focused: focused);
                        },
                      ),
                    ),
                  ),
                  if (selected && !preview)
                    PositionedDirectional(
                      key: ValueKey('label-$id'),
                      start: leading + large + gap * 1.4,
                      top: large * 0.32,
                      width: label - gap,
                      child: Legible(
                        softness: 12,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              console == null
                                  ? game.nameFor([T.language.code])
                                  : T.format('retroGames', [console.name.toUpperCase()]),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: AppText.display(22 * scale, weight: FontWeight.w600),
                            ),
                            SizedBox(height: 6 * scale),
                            if (folder == null) StateLabel(model: model, state: model.stateOf(game)),
                          ],
                        ),
                      ),
                    ),
                ];
              }(),
          ],
        ),
      ),
    );
  }
}

/// The tile row dragged with the mouse: every tile's width dragged moves the selection one game
/// (left for the next, as a finger drags), the row leaning a little after the pointer meanwhile;
/// let go fast, it carries on a few games, as a list glides.
class _TileDrag extends StatefulWidget {
  const _TileDrag({required this.model, required this.step, required this.child, required this.folderContents});

  final AppModel model;

  /// The pixels one game takes in the row.
  final double step;
  final bool folderContents;
  final Widget child;

  @override
  State<_TileDrag> createState() => _TileDragState();
}

class _TileDragState extends State<_TileDrag> {
  /// Dragged since the selection last moved.
  double _pending = 0;
  bool _dragging = false;

  /// How far a fast release carries on: the distance a quarter of a second at that speed covers.
  static const _glide = 0.25;
  static const _maxGlide = 8;

  /// Mirrored (Arabic, Urdu), the next games are on the left: a drag to the right moves on.
  double get _sign => Directionality.of(context) == TextDirection.rtl ? -1 : 1;

  void _update(DragUpdateDetails details) {
    final step = widget.step;
    var pending = _pending + (details.primaryDelta ?? details.delta.dx) * _sign;
    while (pending <= -step) {
      pending += step;
      widget.model.moveHomeSelection(1, folderContents: widget.folderContents);
    }
    while (pending >= step) {
      pending -= step;
      widget.model.moveHomeSelection(-1, folderContents: widget.folderContents);
    }
    setState(() => _pending = pending);
  }

  void _end(DragEndDetails details) {
    final velocity = (details.primaryVelocity ?? 0) * _sign;
    final games = (-velocity * _glide / widget.step).round().clamp(-_maxGlide, _maxGlide);
    if (games != 0) widget.model.moveHomeSelection(games, folderContents: widget.folderContents);
    _settle();
  }

  void _settle() => setState(() {
    _dragging = false;
    _pending = 0;
  });

  @override
  Widget build(BuildContext context) {
    return DragPanRegion(
      axis: Axis.horizontal,
      canPan: () => widget.folderContents
          ? widget.model.activeHomeRetroFolder != null && widget.model.homeFolderTiles.length > 1
          : widget.model.homeTiles.length > 1,
      onStart: (_) => setState(() => _dragging = true),
      onUpdate: _update,
      onEnd: _end,
      onCancel: _settle,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: _dragging ? _pending * 0.4 : 0),
        duration: _dragging ? Duration.zero : Motion.layout,
        curve: Motion.settle,
        builder: (context, lean, child) => Transform.translate(offset: Offset(lean * _sign, 0), child: child),
        child: widget.child,
      ),
    );
  }
}

class GameTile extends StatelessWidget {
  const GameTile({super.key, required this.model, required this.game, required this.size, required this.focused});

  final AppModel model;
  final Game game;
  final double size;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final state = model.stateOf(game);
    final radius = size * 0.12;
    final accent = model.accentChoice.color;
    return FocusRing(
      focused: focused,
      radius: radius,
      child: AnimatedContainer(
        duration: Motion.focus,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          color: Colors.white.withValues(alpha: 0.08),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.45),
              blurRadius: (focused ? 22 : 10) * scale,
              offset: Offset(0, 8 * scale),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (game.icon != null)
                ArtworkImage(path: game.icon!, cacheWidth: 400)
              else
                Icon(Icons.sports_esports_rounded, size: size * 0.32, color: Colors.white.withValues(alpha: 0.5)),
              ..._overlay(state, accent),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _overlay(GameState state, Color accent) {
    Widget badge(IconData icon, {AlignmentGeometry alignment = AlignmentDirectional.bottomEnd}) => Align(
      alignment: alignment,
      child: Container(
        margin: EdgeInsets.all(size * 0.045),
        padding: EdgeInsets.all(size * 0.04),
        decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.black.withValues(alpha: 0.55)),
        child: Icon(icon, size: size * 0.13, color: Colors.white),
      ),
    );
    final dim = ColoredBox(color: Colors.black.withValues(alpha: 0.42));
    // Locked: a padlock that reads as one at a tile's size; the focused tile says it in words too.
    final lock = Align(
      alignment: AlignmentDirectional.bottomEnd,
      child: Container(
        margin: EdgeInsets.all(size * 0.045),
        padding: EdgeInsets.symmetric(horizontal: size * (focused ? 0.05 : 0.04), vertical: size * 0.04),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(size),
          color: Colors.black.withValues(alpha: 0.62),
          border: Border.all(color: Colors.white.withValues(alpha: 0.16), width: 1),
        ),
        child: AnimatedSize(
          duration: Motion.focus,
          curve: Motion.settle,
          alignment: AlignmentDirectional.centerEnd,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padlock(size: size * 0.13, color: Colors.white),
              if (focused) ...[
                SizedBox(width: size * 0.03),
                // A long word ("Заблокировано") fades at the tile's edge instead of overflowing it.
                Flexible(
                  child: Text(
                    T.text('locked'),
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.fade,
                    style: AppText.display(size * 0.07, weight: FontWeight.w600).copyWith(height: 1),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
    return switch (state) {
      Locked() => [dim, lock],
      FamilyLocked() => [dim, badge(Icons.family_restroom_rounded)],
      Unreadable() => [dim, badge(Icons.block_rounded)],
      Failed() => [dim, badge(Icons.warning_rounded)],
      NeedsEmulator() => [dim, badge(Icons.settings_rounded)],
      Installing(:final overall, :final updating) => [
        ColoredBox(color: Colors.black.withValues(alpha: 0.3)),
        // An installed game being updated says so in its corner, as a locked one does.
        if (updating) badge(Icons.sync_rounded, alignment: AlignmentDirectional.topEnd),
        Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: EdgeInsets.all(size * 0.07),
            child: ProgressLine(fraction: overall, color: accent, height: (size * 0.03).clamp(3, 8)),
          ),
        ),
      ],
      Queued(:final waitingForEngine) => [
        dim,
        Center(
          child: Icon(
            waitingForEngine ? Icons.hourglass_top_rounded : Icons.schedule_rounded,
            size: size * 0.18,
            color: Colors.white.withValues(alpha: 0.85),
          ),
        ),
      ],
      // The engine is being built: the game that asked for it shows the work going on, the
      // others wait with an hourglass in their corner.
      WaitingForEngine(forThisGame: true) => [
        ColoredBox(color: Colors.black.withValues(alpha: 0.3)),
        badge(Icons.construction_rounded, alignment: AlignmentDirectional.topEnd),
        Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: EdgeInsets.all(size * 0.07),
            child: IndeterminateLine(color: accent, height: (size * 0.03).clamp(3, 8)),
          ),
        ),
      ],
      WaitingForEngine() => [badge(Icons.hourglass_top_rounded)],
      Stopping() => [
        dim,
        Center(
          child: SizedBox.square(
            dimension: size * 0.16,
            child: CircularProgressIndicator(strokeWidth: 2.5, color: ConsoleButton.stopRed.withValues(alpha: 0.95)),
          ),
        ),
      ],
      Starting() => [
        dim,
        Center(
          child: SizedBox.square(
            dimension: size * 0.16,
            child: const CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
          ),
        ),
      ],
      Running() => [
        Align(
          alignment: AlignmentDirectional.topEnd,
          child: Container(
            margin: EdgeInsets.all(size * 0.07),
            width: size * 0.09,
            height: size * 0.09,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: accent,
              boxShadow: [BoxShadow(color: accent, blurRadius: 6)],
            ),
          ),
        ),
      ],
      Installed() => const [],
    };
  }
}

class StateLabel extends StatelessWidget {
  const StateLabel({super.key, required this.model, required this.state, this.size = 14, this.compact = false});

  final AppModel model;
  final GameState state;
  final double size;

  /// One short line (the Status card): the step is under the main button already.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final accent = model.accentChoice.color;
    final dim = Colors.white.withValues(alpha: 0.75);
    final (icon, text, tint) = switch (state) {
      Locked(waitingToPrepare: true) => (Icons.schedule_rounded, T.text('waitingToPrepare'), dim),
      Locked() => (null, T.text('locked'), dim),
      FamilyLocked(:final verdict) => (
        Icons.family_restroom_rounded,
        T.text(verdict == TitleVerdict.unknown ? 'familyNotRated' : 'familyAgeLocked'),
        Palette.warning,
      ),
      Unreadable() => (Icons.block_rounded, T.text('unreadableDump'), Palette.danger),
      Queued(waitingForEngine: true) => (
        Icons.hourglass_top_rounded,
        T.text(compact ? 'stateWaitingEngineShort' : 'waitingForEngine'),
        dim,
      ),
      Queued() => (Icons.schedule_rounded, T.text('queued'), dim),
      Installing(preparing: true, paused: true) => (Icons.pause_circle_rounded, T.text('preparingPaused'), dim),
      Installing(preparing: true) => (Icons.downloading_rounded, T.text('preparing'), accent),
      // One string: the step is beside the game's buttons already.
      Installing(updating: true) => (Icons.sync_rounded, T.text('stateUpdatingShort'), accent),
      Installing(:final step) => (Icons.downloading_rounded, InstallSpan.title(step), accent),
      WaitingForEngine(:final job, forThisGame: true) => (
        Icons.construction_rounded,
        switch (job.step) {
          _ when compact => T.text('stateEngineShort'),
          null => T.text('engineGitChecking'),
          final step => T.format('stateUpdatingEngine', [EngineGitModel.stepName(step)]),
        },
        accent,
      ),
      WaitingForEngine() => (
        Icons.hourglass_top_rounded,
        T.text(compact ? 'stateWaitingEngineShort' : 'waitingForEngine'),
        dim,
      ),
      Stopping() => (Icons.stop_circle_outlined, T.text('stateStopping'), Palette.danger),
      Failed() => (Icons.warning_rounded, T.text('failed'), Palette.danger),
      NeedsEmulator() => (Icons.settings_rounded, T.text('retroEmulatorNeeded'), dim),
      Installed(outdated: true) => (Icons.sync_rounded, T.text('updateAvailable'), Palette.warning),
      Installed() => (Icons.check_circle_rounded, T.text('ready'), dim),
      Starting() => (Icons.hourglass_top_rounded, T.text('starting'), accent),
      Running() => (Icons.play_circle_rounded, T.text('running'), accent),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon == null)
          Padlock(size: (size + 2) * scale, color: tint)
        else
          Icon(icon, size: (size + 2) * scale, color: tint),
        SizedBox(width: 6 * scale),
        Flexible(
          child: Text(
            text,
            maxLines: compact ? 1 : 2,
            overflow: TextOverflow.ellipsis,
            style: AppText.display(size * scale, weight: FontWeight.w500, color: tint).copyWith(height: 1.15),
          ),
        ),
      ],
    );
  }
}

/// The selected game's title, its main button and the facts about it.
class HeroInfo extends StatelessWidget {
  const HeroInfo({super.key, required this.model, required this.game});

  final AppModel model;
  final Game game;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final state = model.stateOf(game);
    final accent = model.accentChoice.color;
    // The button's words, icon, colour and progress follow the game's state alone.
    final action = GameAction.of(state);
    final primaryFocused = model.focus == const HomeFocus.actions(0) && model.overlay == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Legible(
          softness: 26,
          child: Text(
            game.nameFor([T.language.code]),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppText.display(
              58 * scale,
              weight: FontWeight.w300,
              height: 1.08,
            ).copyWith(shadows: [Shadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 12)]),
          ),
        ),
        SizedBox(height: 22 * scale),
        Row(
          children: [
            ConsoleButton(
              key: const ValueKey('primary-action'),
              title: action.title,
              icon: action.icon,
              focused: primaryFocused,
              prominent: true,
              stop: action.tone == ActionTone.danger,
              // Installing has its own line beside the buttons: one progress bar, not two.
              progress: state is Installing ? null : action.progress,
              indeterminate: state is! Installing && action.indeterminate,
              progressColor: action.tone == ActionTone.busy && !primaryFocused ? accent : null,
              // Busy words count up: room enough that the button does not grow as they do.
              minWidth: action.tone == ActionTone.busy ? 270 : 210,
              onPressed: () {
                model.focus = const HomeFocus.actions(0);
                model.primaryAction(game);
              },
            ),
            if (model.trophies[game.id] case final set?) ...[
              SizedBox(width: 16 * scale),
              ConsoleButton(
                title: '${set.unlockedCount}/${set.trophies.length}',
                icon: Icons.emoji_events_rounded,
                focused: model.focus == const HomeFocus.actions(1) && model.overlay == null,
                onPressed: () {
                  model.focus = const HomeFocus.actions(1);
                  model.open(Layer.trophies);
                },
              ),
            ],
            SizedBox(width: 16 * scale),
            ConsoleButton(
              title: '',
              icon: Icons.more_horiz_rounded,
              focused: model.focus == HomeFocus.actions(model.settingsAction) && model.overlay == null,
              onPressed: () {
                model.focus = HomeFocus.actions(model.settingsAction);
                model.open(Layer.gameSettings);
              },
            ),
            SizedBox(width: 26 * scale),
            if (state is Installing)
              Legible(
                softness: 12,
                child: SizedBox(
                  width: 340 * scale,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            state.preparing
                                ? (state.paused
                                      ? T.text('preparingPaused')
                                      : T.format('preparingStep', [InstallSpan.title(state.step)]))
                                : InstallSpan.title(state.step),
                            style: AppText.display(
                              15 * scale,
                              weight: FontWeight.w500,
                              color: Colors.white.withValues(alpha: 0.85),
                            ),
                          ),
                          const Spacer(),
                          Text(
                            T.percent((state.overall * 100).round()),
                            style: AppText.display(
                              15 * scale,
                              weight: FontWeight.w600,
                              color: Colors.white.withValues(alpha: 0.85),
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 8 * scale),
                      if (state.step.name == 'relink' && state.fraction == 0)
                        IndeterminateLine(color: accent)
                      else
                        ProgressLine(fraction: state.overall, color: accent),
                    ],
                  ),
                ),
              )
            else if (state case WaitingForEngine(:final job))
              Legible(
                softness: 12,
                child: SizedBox(
                  width: 340 * scale,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        model.engine.git.progressText(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.display(
                          15 * scale,
                          weight: FontWeight.w500,
                          color: Colors.white.withValues(alpha: 0.85),
                        ),
                      ),
                      SizedBox(height: 8 * scale),
                      IndeterminateLine(color: accent),
                      // The build's last line, so it is seen to move.
                      if (job.lines.isNotEmpty) ...[
                        SizedBox(height: 6 * scale),
                        Text(
                          job.lines.last.trim(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.display(12 * scale, color: Colors.white.withValues(alpha: 0.55)),
                        ),
                      ],
                    ],
                  ),
                ),
              )
            else if (state is Failed)
              Flexible(
                child: _FailureText(model: model, game: game, message: state.message),
              ),
          ],
        ),
        SizedBox(height: 22 * scale),
        Wrap(
          spacing: 14 * scale,
          runSpacing: 14 * scale,
          children: [
            InfoCard(
              title: T.text('status'),
              icon: Icons.donut_large_rounded,
              child: StateLabel(model: model, state: state, size: 15, compact: true),
            ),
            InfoCard(
              title: T.text('size'),
              icon: Icons.storage_rounded,
              child: Text(
                byteText(model.sizes[game.id]),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.display(16 * scale, weight: FontWeight.w600),
              ),
            ),
            InfoCard(
              title: T.text('titleID'),
              icon: Icons.tag_rounded,
              // The ID as the game has it: never cased by the language.
              child: Text(
                game.titleId,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.display(16 * scale, weight: FontWeight.w600).copyWith(letterSpacing: 0.4),
              ),
            ),
            if (game.retro == null)
              InfoCard(
                title: T.text('version'),
                icon: Icons.sell_rounded,
                child: _VersionText(model: model, game: game),
              ),
            if (game.retro == null)
              if (model.together.screens.compat[game.titleId] case final summary?) _CommunityCard(summary: summary),
            if (game.addons.isNotEmpty) _AddonsCard(addons: game.addons),
          ],
        ),
        if (game.retro == null) _CompatWatch(model: model, titleId: game.titleId),
      ],
    );
  }
}

/// A failed unlock's error beside the buttons: wrapped over a few lines (a relinker's reason and
/// the file it names), and Copy Error, which puts the whole of it, the relinker's output with
/// it, on the clipboard (the game's settings have it as a row too, for the controller).
class _FailureText extends StatelessWidget {
  const _FailureText({required this.model, required this.game, required this.message});

  final AppModel model;
  final Game game;
  final String message;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: 560 * scale),
      child: Legible(
        softness: 12,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: AppText.display(14 * scale, color: Palette.danger, height: 1.3),
            ),
            SizedBox(height: 6 * scale),
            Pressable(
              onTap: () => model.copyFailure(game),
              builder: (context, hovering) => AnimatedOpacity(
                opacity: hovering ? 1 : 0.72,
                duration: const Duration(milliseconds: 120),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.content_copy_rounded, size: 14 * scale, color: Colors.white),
                    SizedBox(width: 6 * scale),
                    Text(
                      T.text('copyError'),
                      style: AppText.display(13 * scale, weight: FontWeight.w600, color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The game's version; with an update dumped beside it, the update's and whether it is applied.
class _VersionText extends StatelessWidget {
  const _VersionText({required this.model, required this.game});

  final AppModel model;
  final Game game;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final update = game.update;
    final style = AppText.display(16 * scale, weight: FontWeight.w600);
    if (update == null) return Text(game.version, maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
    // Two lines in the card's room: tight line heights.
    final version = Text(update.version, style: style.copyWith(height: 1.0));
    final applied = model.records[game.id]?.update == update.version;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        version,
        SizedBox(height: 2 * scale),
        Text(
          T.format(applied ? 'updateApplied' : 'updateToApply', [update.shortVersion]),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppText.display(
            12 * scale,
            weight: FontWeight.w500,
            color: applied ? Colors.white.withValues(alpha: 0.5) : model.accentChoice.color,
          ).copyWith(height: 1.0),
        ),
      ],
    );
  }
}

/// The game's card for how the community says it runs on this platform, as on the Mac.
class _CommunityCard extends StatelessWidget {
  const _CommunityCard({required this.summary});

  final CompatSummary summary;

  static Color _dot(CompatStatus? status) => switch (status) {
    CompatStatus.nothing => const Color.fromRGBO(255, 115, 115, 1),
    CompatStatus.boots => const Color.fromRGBO(255, 158, 89, 1),
    CompatStatus.menus => const Color.fromRGBO(255, 214, 102, 1),
    CompatStatus.ingame => const Color.fromRGBO(122, 199, 255, 1),
    CompatStatus.playable => const Color.fromRGBO(115, 230, 153, 1),
    null => Colors.white.withValues(alpha: 0.6),
  };

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final status = summary.status;
    return InfoCard(
      title: T.text('socialCompatCommunity'),
      icon: Icons.groups_rounded,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 9 * scale,
            height: 9 * scale,
            decoration: BoxDecoration(color: _dot(status), shape: BoxShape.circle),
          ),
          SizedBox(width: 8 * scale),
          Flexible(
            child: Text(
              status == null ? summary.statusName : TogetherSocial.compatName(status),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.display(16 * scale, weight: FontWeight.w600),
            ),
          ),
          SizedBox(width: 8 * scale),
          Flexible(
            child: Text(
              summary.version,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.display(13 * scale, weight: FontWeight.w500, color: Colors.white.withValues(alpha: 0.5)),
            ),
          ),
        ],
      ),
    );
  }
}

/// Asks for the community's verdict once the selection rests on the game (as the Mac does), not
/// for every game a held direction passes.
class _CompatWatch extends StatefulWidget {
  const _CompatWatch({required this.model, required this.titleId});

  final AppModel model;
  final String titleId;

  @override
  State<_CompatWatch> createState() => _CompatWatchState();
}

class _CompatWatchState extends State<_CompatWatch> {
  static const _settle = Duration(milliseconds: 180);
  Timer? _timer;

  void _ask() {
    _timer?.cancel();
    if (!widget.model.together.signedIn) return;
    _timer = Timer(_settle, () => unawaited(widget.model.together.loadCompat(widget.titleId)));
  }

  @override
  void initState() {
    super.initState();
    _ask();
  }

  @override
  void didUpdateWidget(_CompatWatch old) {
    super.didUpdateWidget(old);
    if (old.titleId != widget.titleId) _ask();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// The add-ons dumped beside the game: the engine mounts each one the game asks for.
class _AddonsCard extends StatelessWidget {
  const _AddonsCard({required this.addons});

  final List<GameAddon> addons;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final shown = addons.length > 2 ? 1 : 2;
    return InfoCard(
      title: T.format('addons', [addons.length]),
      icon: Icons.inventory_2_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final addon in addons.take(shown))
            Text(
              addon.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.display(14 * scale, weight: FontWeight.w600).copyWith(height: 1.0),
            ),
          if (addons.length > 2)
            Text(
              T.format('addonsMore', [addons.length - 1]),
              style: AppText.display(
                12 * scale,
                weight: FontWeight.w500,
                color: Colors.white.withValues(alpha: 0.5),
              ).copyWith(height: 1.0),
            ),
        ],
      ),
    );
  }
}

class InfoCard extends StatelessWidget {
  const InfoCard({super.key, required this.title, required this.icon, required this.child});

  final String title;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    // On Glass the labels are a little brighter: they keep AA contrast over any frosted picture.
    final label = Colors.white.withValues(alpha: LookScope.isGlass(context) ? 0.72 : 0.55);
    // As wide as the words need, between a short value's and the room a long translation
    // gets; a longer one goes to an ellipsis. One height for all, so the row stays even.
    return ConstrainedBox(
      constraints: BoxConstraints(minWidth: 128 * scale, maxWidth: 236 * scale),
      child: IntrinsicWidth(
        child: SizedBox(
          height: 76 * scale,
          child: Glass(
            radius: 14 * scale,
            padding: EdgeInsets.fromLTRB(14 * scale, 13 * scale, 14 * scale, 10 * scale),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(icon, size: 13 * scale, color: label),
                    SizedBox(width: 5 * scale),
                    Flexible(
                      child: Text(
                        T.upper(title),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.display(
                          11 * scale,
                          weight: FontWeight.w600,
                          color: label,
                        ).copyWith(letterSpacing: 0.6, height: 1.1),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 6 * scale),
                child,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class EmptyLibrary extends StatelessWidget {
  const EmptyLibrary({super.key, required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final folders = model.preferences.gamesFolders;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            model.scanning ? Icons.search_rounded : Icons.layers_clear_outlined,
            size: 54 * scale,
            color: Colors.white.withValues(alpha: 0.8),
          ),
          SizedBox(height: 18 * scale),
          Legible(
            softness: 16,
            child: Text(
              T.text(model.scanning ? 'scanning' : 'emptyLibraryTitle'),
              style: AppText.display(34 * scale, weight: FontWeight.w300),
            ),
          ),
          SizedBox(height: 12 * scale),
          Legible(
            softness: 12,
            child: Text(
              T.text('emptyLibraryText'),
              style: AppText.display(
                17 * scale,
                color: Colors.white.withValues(alpha: LookScope.isSeeThrough(context) ? 0.75 : 0.65),
              ),
            ),
          ),
          if (folders.isNotEmpty) ...[
            SizedBox(height: 12 * scale),
            Legible(
              softness: 10,
              child: Text(
                folders.join('\n'),
                textAlign: TextAlign.center,
                style: AppText.display(
                  13 * scale,
                  color: Colors.white.withValues(alpha: LookScope.isSeeThrough(context) ? 0.7 : 0.45),
                ),
              ),
            ),
          ],
          SizedBox(height: 28 * scale),
          ConsoleButton(
            title: T.text(folders.isEmpty ? 'pickFolder' : 'addFolder'),
            icon: folders.isEmpty ? Icons.folder_rounded : Icons.create_new_folder_rounded,
            focused: true,
            onPressed: model.addGamesFolder,
          ),
        ],
      ),
    );
  }
}
