import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_model.dart';
import 'background.dart';
import 'components.dart';
import 'engine_model.dart';
import 'home.dart';
import 'profiles_view.dart';
import 'strings.dart';
import 'theme.dart';

/// First start: language, one of the three themes, the games folder, the toolkit, then offline or
/// online (the first profile; online signs in or makes the account).
class OnboardingView extends StatelessWidget {
  const OnboardingView({super.key, required this.model, this.time});

  final AppModel model;

  /// A fixed moment for the theme cards' animation (previews, tests).
  final double? time;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final step = model.onboardingStep;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [Colors.black.withValues(alpha: 0.55), Colors.black.withValues(alpha: 0.1)]),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 110 * scale, vertical: 80 * scale),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                for (var index = 0; index < AppModel.onboardingSteps; index++)
                  AnimatedContainer(
                    duration: Motion.layout,
                    curve: Motion.settle,
                    margin: EdgeInsetsDirectional.only(end: 10 * scale),
                    width: (index == step ? 46 : 18) * scale,
                    height: 5 * scale,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(5 * scale),
                      color: Colors.white.withValues(alpha: index <= step ? 0.95 : 0.22),
                    ),
                  ),
              ],
            ),
            SizedBox(height: 54 * scale),
            Expanded(
              child: AnimatedSwitcher(
                duration: Motion.layout,
                switchInCurve: Motion.settle,
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween(begin: const Offset(0.03, 0), end: Offset.zero).animate(animation),
                    child: child,
                  ),
                ),
                layoutBuilder: uniqueSwitcherLayout(alignment: AlignmentDirectional.topStart),
                child: KeyedSubtree(
                  key: ValueKey(step),
                  child: switch (step) {
                    0 => _LanguageStep(model: model),
                    1 => _ThemeStep(model: model, time: time),
                    2 => _FolderStep(model: model),
                    3 => _ToolkitStep(model: model),
                    _ => _ModeStep(model: model),
                  },
                ),
              ),
            ),
            Row(
              children: [
                if (step > 0)
                  ConsoleButton(
                    title: T.text('back'),
                    icon: Icons.chevron_left_rounded,
                    focused: false,
                    onPressed: model.onboardingBack,
                  ),
                const Spacer(),
                const HintBar(options: false),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StepTitle extends StatelessWidget {
  const _StepTitle({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: AppText.display(54 * scale, weight: FontWeight.w300)),
        SizedBox(height: 14 * scale),
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 720 * scale),
          child: Text(
            subtitle,
            style: AppText.display(19 * scale, color: Colors.white.withValues(alpha: 0.7), height: 1.4),
          ),
        ),
      ],
    );
  }
}

/// A card that turns white when chosen.
class _ChoiceCard extends StatelessWidget {
  const _ChoiceCard({
    required this.focused,
    required this.onTap,
    required this.child,
    this.width,
    this.height,
    this.padding = 26,
  });

  final bool focused;
  final VoidCallback onTap;
  final Widget child;
  final double? width;
  final double? height;
  final double padding;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedScale(
        scale: focused ? 1.04 : 1,
        duration: Motion.focus,
        curve: Motion.settle,
        child: AnimatedContainer(
          duration: Motion.focus,
          curve: Motion.settle,
          width: width,
          height: height,
          padding: EdgeInsets.all(padding * scale),
          decoration: BoxDecoration(
            color: focused ? Colors.white : Colors.white.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(20 * scale),
            border: Border.all(color: Colors.white.withValues(alpha: focused ? 0 : 0.14)),
            boxShadow: [
              BoxShadow(
                color: Colors.white.withValues(alpha: focused ? 0.3 : 0),
                blurRadius: 20 * scale,
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}

class _LanguageStep extends StatelessWidget {
  const _LanguageStep({required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _StepTitle(title: T.text('welcome'), subtitle: T.text('welcomeSubtitle')),
        SizedBox(height: 46 * scale),
        Text(
          T.upper(T.text('chooseLanguage')),
          style: AppText.display(
            14 * scale,
            weight: FontWeight.w600,
            color: Colors.white.withValues(alpha: 0.55),
          ).copyWith(letterSpacing: 0.8),
        ),
        SizedBox(height: 16 * scale),
        // Rows of cards, AppModel.languageColumns to a row: the step's arrows move along them. The
        // cards share the space the step has: as wide and tall as they fit, up to 200 by 96.
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              const columns = AppModel.languageColumns;
              final rows = (T.languages.length / columns).ceil();
              final spacing = 20 * scale;
              final runSpacing = 18 * scale;
              final width = math.min(200 * scale, (constraints.maxWidth - spacing * (columns - 1)) / columns);
              // Room under the last row, so it does not run into the hint bar.
              final room = constraints.maxHeight - 28 * scale;
              final height = math.min(96 * scale, (room - runSpacing * (rows - 1)) / rows);
              // A short card leaves the code out: the name is what a person looks for.
              final withCode = height >= 80 * scale;
              return Wrap(
                spacing: spacing,
                runSpacing: runSpacing,
                children: [
                  for (final (index, language) in T.languages.indexed)
                    _ChoiceCard(
                      focused: model.onboardingChoice == index,
                      width: width,
                      height: height,
                      padding: height >= 96 * scale ? 18 : 12,
                      onTap: () {
                        model.onboardingChoice = index;
                        model.onboardingConfirm();
                      },
                      child: Builder(
                        builder: (context) {
                          final color = model.onboardingChoice == index ? Colors.black : Colors.white;
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              if (withCode) ...[
                                Text(
                                  language.code.toUpperCase(),
                                  style: AppText.display(
                                    13 * scale,
                                    weight: FontWeight.w700,
                                    color: color.withValues(alpha: 0.6),
                                  ),
                                ),
                                SizedBox(height: 6 * scale),
                              ],
                              // A long name (Bahasa Indonesia) is drawn smaller, never cut off.
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: AlignmentDirectional.centerStart,
                                child: Text(
                                  language.displayName,
                                  maxLines: 1,
                                  style: AppText.display(22 * scale, weight: FontWeight.w500, color: color),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ThemeStep extends StatelessWidget {
  const _ThemeStep({required this.model, this.time});

  final AppModel model;
  final double? time;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _StepTitle(title: T.text('chooseTheme'), subtitle: T.text('chooseThemeSubtitle')),
        SizedBox(height: 46 * scale),
        LayoutBuilder(
          builder: (context, constraints) {
            // The looks share the row: each card as wide as it can be, up to 330.
            final count = LookStyle.values.length;
            final card = math.min(330 * scale, (constraints.maxWidth - 26 * scale * (count - 1)) / count);
            return Row(
              children: [
                for (final style in LookStyle.values) ...[
                  GestureDetector(
                    onTap: () => model.previewTheme(style.index),
                    child: AnimatedScale(
                      scale: model.onboardingChoice == style.index ? 1.04 : 0.97,
                      duration: Motion.focus,
                      curve: Motion.settle,
                      child: AnimatedOpacity(
                        opacity: model.onboardingChoice == style.index ? 1 : 0.72,
                        duration: Motion.focus,
                        child: SizedBox(
                          width: card,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              FocusRing(
                                focused: model.onboardingChoice == style.index,
                                radius: 18 * scale,
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(18 * scale),
                                  child: SizedBox(
                                    width: card,
                                    height: card * 186 / 330,
                                    child: ThemeBackground(
                                      style: style,
                                      paused: model.onboardingChoice != style.index,
                                      time: time,
                                    ),
                                  ),
                                ),
                              ),
                              SizedBox(height: 14 * scale),
                              Row(
                                children: [
                                  Text(
                                    style.title,
                                    style: AppText.display(
                                      22 * scale,
                                      weight: model.onboardingChoice == style.index ? FontWeight.w600 : FontWeight.w400,
                                    ),
                                  ),
                                  const Spacer(),
                                  Container(
                                    width: 12 * scale,
                                    height: 12 * scale,
                                    decoration: BoxDecoration(shape: BoxShape.circle, color: style.defaultAccent.color),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (style != LookStyle.values.last) SizedBox(width: 26 * scale),
                ],
              ],
            );
          },
        ),
      ],
    );
  }
}

class _FolderStep extends StatelessWidget {
  const _FolderStep({required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final folder = model.preferences.gamesFolders.firstOrNull;
    final accent = model.accentChoice.color;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _StepTitle(title: T.text('chooseFolder'), subtitle: T.text('chooseFolderSubtitle')),
        SizedBox(height: 46 * scale),
        Row(
          children: [
            ConsoleButton(
              title: T.text(folder == null ? 'pickFolder' : 'changeFolder'),
              icon: Icons.folder_rounded,
              focused: model.onboardingChoice == 0,
              minWidth: 220,
              onPressed: () {
                model.onboardingChoice = 0;
                model.onboardingConfirm();
              },
            ),
            if (folder != null) ...[
              SizedBox(width: 18 * scale),
              ConsoleButton(
                title: T.text('continueAction'),
                icon: Icons.arrow_forward_rounded,
                focused: model.onboardingChoice == 1,
                prominent: true,
                minWidth: 180,
                onPressed: () {
                  model.onboardingChoice = 1;
                  model.onboardingConfirm();
                },
              ),
            ],
          ],
        ),
        if (folder != null) ...[
          SizedBox(height: 22 * scale),
          SizedBox(
            width: 640 * scale,
            child: Glass(
              radius: 16 * scale,
              padding: EdgeInsets.all(20 * scale),
              child: Row(
                children: [
                  Icon(
                    model.games.isEmpty ? Icons.folder_off_rounded : Icons.check_circle_rounded,
                    size: 24 * scale,
                    color: model.games.isEmpty ? Colors.white.withValues(alpha: 0.7) : accent,
                  ),
                  SizedBox(width: 14 * scale),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          model.games.isEmpty ? T.text('noGamesFound') : T.format('gamesFound', [model.games.length]),
                          style: AppText.display(18 * scale, weight: FontWeight.w500),
                        ),
                        SizedBox(height: 4 * scale),
                        Text(
                          folder,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.display(13 * scale, color: Colors.white.withValues(alpha: 0.5)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (model.games.isNotEmpty) ...[
            SizedBox(height: 22 * scale),
            Row(
              children: [
                for (final game in model.games.take(8)) ...[
                  SizedBox.square(
                    dimension: 84 * scale,
                    child: GameTile(model: model, game: game, size: 84 * scale, focused: false),
                  ),
                  SizedBox(width: 12 * scale),
                ],
              ],
            ),
          ],
        ],
      ],
    );
  }
}

class _ToolkitStep extends StatelessWidget {
  const _ToolkitStep({required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final toolkit = model.toolkit;
    final accent = model.accentChoice.color;
    final engine = model.engine;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _StepTitle(title: T.text('chooseToolkit'), subtitle: T.text('chooseToolkitSubtitle')),
        SizedBox(height: 40 * scale),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _ChoiceCard(
              focused: model.onboardingChoice == 0,
              width: 470 * scale,
              height: 196 * scale,
              onTap: () {
                model.onboardingChoice = 0;
                model.onboardingConfirm();
              },
              child: Builder(
                builder: (context) {
                  final focused = model.onboardingChoice == 0;
                  final color = focused ? Colors.black : Colors.white;
                  final downloading = engine.downloading;
                  final newest = engine.offered;
                  final String detail;
                  if (downloading != null) {
                    detail = engine.progressText();
                  } else if (engine.unverified != null) {
                    detail = T.text('engineUnverified');
                  } else if (newest != null) {
                    detail = T.format('engineDownloadDetail', [EngineModel.offeredName(newest), byteText(newest.size)]);
                  } else if (engine.looking) {
                    detail = T.text('engineLooking');
                  } else if (engine.lookError != null) {
                    detail = T.text('engineOffline');
                  } else {
                    detail = T.text(engine.armSelected ? 'engineArmSource' : 'engineSource');
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.download_rounded, size: 26 * scale, color: color),
                          const Spacer(),
                          Container(
                            padding: EdgeInsets.symmetric(horizontal: 10 * scale, vertical: 4 * scale),
                            decoration: BoxDecoration(
                              color: focused ? Colors.black : accent.withValues(alpha: 0.22),
                              borderRadius: BorderRadius.circular(20 * scale),
                            ),
                            child: Text(
                              T.upper(T.text('engineRecommended')),
                              style: AppText.display(
                                11 * scale,
                                weight: FontWeight.w700,
                                color: focused ? Colors.white : accent,
                              ).copyWith(letterSpacing: 0.8),
                            ),
                          ),
                        ],
                      ),
                      const Spacer(),
                      Text(
                        T.text('engineDownload'),
                        style: AppText.display(26 * scale, weight: FontWeight.w500, color: color),
                      ),
                      SizedBox(height: 8 * scale),
                      Text(
                        detail,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.display(15 * scale, color: color.withValues(alpha: 0.65), height: 1.35),
                      ),
                      if (downloading != null) ...[
                        SizedBox(height: 12 * scale),
                        ProgressLine(
                          fraction: engine.progress?.fraction ?? 0,
                          color: focused ? Colors.black : accent,
                          height: 5 * scale,
                        ),
                      ],
                    ],
                  );
                },
              ),
            ),
            SizedBox(width: 20 * scale),
            _ChoiceCard(
              focused: model.onboardingChoice == 1,
              width: 320 * scale,
              height: 196 * scale,
              onTap: () {
                model.onboardingChoice = 1;
                model.onboardingConfirm();
              },
              child: Builder(
                builder: (context) {
                  final color = model.onboardingChoice == 1 ? Colors.black : Colors.white;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.folder_open_rounded, size: 26 * scale, color: color),
                      const Spacer(),
                      Text(
                        T.text('engineOwnFolder'),
                        style: AppText.display(26 * scale, weight: FontWeight.w500, color: color),
                      ),
                      SizedBox(height: 8 * scale),
                      Text(
                        T.text('engineOwnFolderDetail'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.display(15 * scale, color: color.withValues(alpha: 0.65), height: 1.35),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
        SizedBox(height: 26 * scale),
        Row(
          children: [
            ConsoleButton(
              title: T.text(toolkit == null ? 'skip' : 'start'),
              icon: Icons.arrow_forward_rounded,
              focused: model.onboardingChoice == 2,
              prominent: toolkit != null,
              minWidth: 180,
              onPressed: () {
                model.onboardingChoice = 2;
                model.onboardingConfirm();
              },
            ),
            SizedBox(width: 22 * scale),
            Icon(
              toolkit == null ? Icons.help_outline_rounded : Icons.check_circle_rounded,
              size: 22 * scale,
              color: toolkit == null ? Colors.white.withValues(alpha: 0.6) : accent,
            ),
            SizedBox(width: 10 * scale),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: 560 * scale),
              child: Text(
                toolkit == null
                    ? T.text('toolkitMissing')
                    : '${T.text('engine')} ${EngineModel.label(toolkit)} · ${toolkit.root}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.display(15 * scale, color: Colors.white.withValues(alpha: toolkit == null ? 0.55 : 0.8)),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// The first start's last step: offline or online; online's sign-in comes up over it.
class _ModeStep extends StatelessWidget {
  const _ModeStep({required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _StepTitle(title: T.text('profileHowToPlay'), subtitle: T.text('profileHowToPlaySubtitle')),
        SizedBox(height: 40 * scale),
        ProfileModeCards(model: model),
      ],
    );
  }
}
