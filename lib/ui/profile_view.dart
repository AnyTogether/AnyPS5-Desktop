import 'package:flutter/material.dart';

import '../core/together/levels.dart';
import '../core/together/posts.dart' show MediaItem;
import '../core/together/profile_look.dart';
import '../core/together/profiles.dart';
import '../core/trophies.dart';
import 'app_model.dart';
import 'captures_view.dart' show CaptureViewer, RemotePicture;
import 'components.dart';
import 'feed_view.dart';
import 'glass.dart';
import 'level_badge.dart';
import 'panels.dart';
import 'strings.dart';
import 'theme.dart';
import 'together_model.dart';

/// Someone's AnyTogether profile: who they are and their totals on the left; what they pinned,
/// their games with play time and trophy progress, then their recent trophies with how rare they
/// are, on the right. The profile's look is drawn as every AnyTogether client draws it: its cover
/// (or its theme's still) behind the header, tinted from the theme's deep colour into its middle
/// one, and its accent on its highlights. The user's own has Edit showcase and Profile theme.
class ProfileView extends StatelessWidget {
  const ProfileView({super.key, required this.model});

  final AppModel model;

  /// For the tests: how a cover or a theme's still is read.
  static ImageProvider Function(String url) pictureFor = NetworkImage.new;

  /// "#rrggbb" as a colour; null for none.
  static Color? colour(String? hex) => hex == null ? null : Color(0xFF000000 | int.parse(hex.substring(1), radix: 16));

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final together = model.together;
    final page = together.profile;
    final card = together.profileCard;
    // A friend's friends-only name and picture (the user's own too), the handle under it.
    final shownCard = page?.profile.card ?? card;
    final identity = shownCard == null ? null : TogetherModel.shown(shownCard);
    final name = identity?.name ?? '';
    final handle = page?.profile.handle ?? card?.handle ?? '';
    final muted = Colors.white.withValues(alpha: 0.6);
    final totals = page?.totals;
    final level = page?.profile.trophyLevel;
    // The user's own page: the status they chose, when it is not plain online.
    final ownDot = page?.profile.isMe == true && together.signedIn ? TogetherModel.ownDot(together.myStatus) : null;
    final look = page?.profile.look ?? const ProfileLook();
    final accent = together.profileAccent ?? model.accentChoice.color;
    final actions = together.profileActions;
    bool focusedOn(ProfileAction action) => actions.indexOf(action) == together.profileIndex;
    return LayerScrim(
      opacity: 0.64,
      child: Stack(
        children: [
          PositionedDirectional(top: 0, start: 0, end: 0, child: _HeaderLook(look: look)),
          Padding(
            padding: EdgeInsets.fromLTRB(90 * scale, 64 * scale, 90 * scale, 50 * scale),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 380 * scale,
                  // A long bio or a theme worn on a short window: the column scrolls, never cuts.
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(T.text('profileTitle'), style: AppText.display(18 * scale, color: muted)),
                        SizedBox(height: 22 * scale),
                        PersonAvatar(
                          person: PanelPerson(name: name, avatar: identity?.avatar, status: ownDot),
                          size: 112 * scale,
                        ),
                        SizedBox(height: 20 * scale),
                        Text(name, style: AppText.display(38 * scale, weight: FontWeight.w300)),
                        SizedBox(height: 6 * scale),
                        Row(
                          children: [
                            Text(
                              '@$handle',
                              style: AppText.display(16 * scale, weight: FontWeight.w500, color: muted),
                            ),
                            if (identity != null && identity.isPrivate) ...[
                              SizedBox(width: 10 * scale),
                              Icon(Icons.lock_rounded, size: 13 * scale, color: muted),
                              SizedBox(width: 4 * scale),
                              Flexible(
                                child: Text(
                                  identity.publicName == identity.name
                                      ? T.text('privateBadge')
                                      : '${identity.publicName} · ${T.text('privateBadge')}',
                                  overflow: TextOverflow.ellipsis,
                                  style: AppText.display(12 * scale, weight: FontWeight.w600, color: muted),
                                ),
                              ),
                            ],
                            if (page != null && (page.profile.isMe || page.profile.friendship == 'friends')) ...[
                              SizedBox(width: 10 * scale),
                              _Tag(
                                text: page.profile.isMe ? T.text('profileYou') : T.text('profileFriend'),
                                color: accent,
                              ),
                            ],
                            if (page?.profile.country case final String country) ...[
                              SizedBox(width: 10 * scale),
                              _Tag(text: country, color: Colors.white),
                            ],
                          ],
                        ),
                        if (look.theme case final ProfileTheme theme) ...[
                          SizedBox(height: 12 * scale),
                          _ThemeChip(
                            theme: theme,
                            focused: focusedOn(ProfileAction.theme),
                            onTap: together.openWornThemeInHub,
                          ),
                        ],
                        if (ownDot != null) ...[
                          SizedBox(height: 10 * scale),
                          _Tag(
                            text: TogetherModel.ownStatusText(together.myStatus),
                            color: PersonAvatar.statusColor(ownDot),
                          ),
                        ],
                        if (page?.profile.bio case final String bio) ...[
                          SizedBox(height: 16 * scale),
                          Text(
                            bio,
                            maxLines: 4,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.display(15 * scale, color: Colors.white.withValues(alpha: 0.8), height: 1.4),
                          ),
                        ],
                        if (page?.detailsPrivate == true) ...[
                          SizedBox(height: 14 * scale),
                          Text(T.text('profileDetailsPrivate'), style: AppText.display(14 * scale, color: muted)),
                        ],
                        if (level != null) ...[
                          SizedBox(height: 22 * scale),
                          SizedBox(
                            width: 368 * scale,
                            child: LevelCard(level: level, accent: accent),
                          ),
                        ],
                        SizedBox(height: level != null ? 14 * scale : 30 * scale),
                        if (totals != null)
                          Wrap(
                            spacing: 12 * scale,
                            runSpacing: 12 * scale,
                            children: [
                              _Total(label: T.text('profileGames'), value: '${totals.games}'),
                              _Total(label: T.text('profileHours'), value: '${totals.seconds ~/ 3600}'),
                              _Total(label: T.text('profileTrophies'), value: '${totals.trophies}'),
                              _Total(label: T.text('profilePoints'), value: '${totals.points}'),
                            ],
                          ),
                        if (together.canCompare) ...[
                          SizedBox(height: 18 * scale),
                          _ProfileButton(
                            icon: Icons.compare_arrows_rounded,
                            label: T.text('compareTrophies'),
                            focused: focusedOn(ProfileAction.compare),
                            onTap: together.compareProfile,
                          ),
                        ],
                        if (together.canEditProfile) ...[
                          SizedBox(height: 14 * scale),
                          _ProfileButton(
                            icon: Icons.push_pin_rounded,
                            label: T.text('showcaseEdit'),
                            focused: focusedOn(ProfileAction.editShowcase),
                            onTap: together.openShowcaseEditor,
                          ),
                          SizedBox(height: 8 * scale),
                          _ProfileButton(
                            icon: Icons.palette_rounded,
                            label: T.text('profileTheme'),
                            focused: focusedOn(ProfileAction.profileTheme),
                            onTap: together.openThemeChooser,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                SizedBox(width: 60 * scale),
                Expanded(
                  child: page == null
                      ? Center(
                          child: Text(
                            together.profileFailed ? T.text('profileFailed') : T.text('profileLoading'),
                            style: AppText.display(18 * scale, color: muted),
                          ),
                        )
                      : _Sections(model: model, page: page, accent: accent),
                ),
              ],
            ),
          ),
          if (together.captures.viewing case final viewing?)
            Positioned.fill(
              child: CaptureViewer(model: model, media: viewing),
            ),
        ],
      ),
    );
  }
}

/// Behind the header: the profile's cover or its theme's still, tinted from the theme's deep
/// colour into its middle one, fading into the layer below. Nothing for a profile with no look.
class _HeaderLook extends StatelessWidget {
  const _HeaderLook({required this.look});

  final ProfileLook look;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final picture = look.picture;
    final theme = look.theme;
    final deep = ProfileView.colour(theme?.deep);
    final middle = ProfileView.colour(theme?.middle) ?? deep;
    if (picture == null && deep == null) return const SizedBox.shrink();
    return IgnorePointer(
      child: SizedBox(
        height: 460 * scale,
        child: ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (rect) => const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.white, Color(0xD9FFFFFF), Color(0x00FFFFFF)],
            stops: [0, 0.45, 1],
          ).createShader(rect),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (deep != null) DecoratedBox(decoration: BoxDecoration(gradient: _tint(deep, middle!, 1))),
              if (picture != null)
                Image(
                  image: ProfileView.pictureFor(picture),
                  fit: BoxFit.cover,
                  opacity: AlwaysStoppedAnimation(deep == null ? 0.72 : 0.6),
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  frameBuilder: (context, child, frame, synchronous) => synchronous
                      ? child
                      : AnimatedOpacity(
                          opacity: frame == null ? 0 : 1,
                          duration: Motion.fade,
                          curve: Motion.settle,
                          child: child,
                        ),
                ),
              // The theme's tint over its still: deep where the name sits, its middle colour beyond.
              if (deep != null) DecoratedBox(decoration: BoxDecoration(gradient: _tint(deep, middle!, 0.62))),
              // The name and handle stay easy to read over any picture.
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Colors.black.withValues(alpha: 0.42), Colors.black.withValues(alpha: 0)],
                    stops: const [0, 0.55],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static LinearGradient _tint(Color deep, Color middle, double alpha) => LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      deep.withValues(alpha: alpha),
      middle.withValues(alpha: alpha * 0.7),
    ],
  );
}

/// Theme: name under the handle, with the theme's four colours side by side; chosen, it opens
/// the theme in the Hub.
class _ThemeChip extends StatelessWidget {
  const _ThemeChip({required this.theme, required this.focused, required this.onTap});

  final ProfileTheme theme;
  final bool focused;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final colours = [
      for (final hex in [theme.deep, theme.middle, theme.bright, theme.accent]) ?ProfileView.colour(hex),
    ];
    return KeepVisible(
      active: focused,
      child: Semantics(
        container: true,
        button: true,
        label: theme.name,
        onTap: onTap,
        excludeSemantics: true,
        child: Pressable(
          onTap: onTap,
          pressScale: 0.97,
          builder: (context, hovering) {
            final ink = focused ? Colors.black : Colors.white;
            return AnimatedContainer(
              duration: Motion.focus,
              curve: Motion.settle,
              padding: EdgeInsetsDirectional.fromSTEB(8 * scale, 6 * scale, 12 * scale, 6 * scale),
              decoration: BoxDecoration(
                color: focused ? Colors.white : Colors.white.withValues(alpha: hovering ? 0.16 : 0.09),
                borderRadius: BorderRadius.circular(40 * scale),
                border: Border.all(color: Colors.white.withValues(alpha: focused ? 0 : 0.12)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.white.withValues(alpha: focused ? 0.22 : 0),
                    blurRadius: 16 * scale,
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // The theme's palette: deep, middle, bright and accent, overlapping like swatches.
                  SizedBox(
                    width: (14 + 9 * (colours.length - 1).clamp(0, 3)) * scale,
                    height: 14 * scale,
                    child: Stack(
                      children: [
                        for (var index = 0; index < colours.length; index++)
                          PositionedDirectional(
                            start: 9 * index * scale,
                            child: Container(
                              width: 14 * scale,
                              height: 14 * scale,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: colours[index],
                                border: Border.all(
                                  color: (focused ? Colors.white : Colors.black).withValues(alpha: 0.7),
                                  width: 1.5 * scale,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (colours.isNotEmpty) SizedBox(width: 8 * scale),
                  Flexible(
                    child: Text(
                      T.format('themeWorn', [theme.name]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.display(13 * scale, weight: FontWeight.w600, color: ink),
                    ),
                  ),
                  SizedBox(width: 2 * scale),
                  Icon(Icons.chevron_right_rounded, size: 16 * scale, color: ink.withValues(alpha: 0.6)),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _Sections extends StatelessWidget {
  const _Sections({required this.model, required this.page, required this.accent});

  final AppModel model;
  final ProfilePage page;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final together = model.together;
    final language = T.language.code;
    final games = page.library.value ?? const <PlayedGame>[];
    final trophies = page.trophies.value ?? const <EarnedTrophy>[];
    final activity = page.activity.value ?? const [];
    String closed(Section<Object?> section, String empty) => switch (section) {
      SectionPrivate() =>
        page.profile.friendship == 'friends'
            ? T.format('profilePrivate', [page.profile.displayName])
            : T.format('profileFriendsOnly', [page.profile.displayName]),
      SectionFailed() => T.text('profileFailed'),
      SectionShown() => empty,
    };
    Widget heading(String text) => Padding(
      padding: EdgeInsets.only(bottom: 12 * scale, top: 6 * scale),
      child: Text(text, style: AppText.display(22 * scale, weight: FontWeight.w500)),
    );
    Widget note(String text) => Padding(
      padding: EdgeInsets.only(bottom: 22 * scale),
      child: Text(text, style: AppText.display(15 * scale, color: Colors.white.withValues(alpha: 0.55))),
    );
    final from = together.profileGamesFrom;
    final gallery = together.profileGallery;
    final galleryItems = gallery?.value;
    final showcase = page.showcase;
    // Six pins at most, trophies first, as the server shows them (one saved before the shared
    // limit may hold more).
    final shown = showcase.value;
    final shownTrophies = shown?.trophies?.take(ShowcasePins.max).toList();
    final pinned = shown == null
        ? null
        : Showcase(
            trophies: shownTrophies,
            games: shown.games?.take(ShowcasePins.max - (shownTrophies?.length ?? 0)).toList(),
          );
    final private = T.format('profilePrivate', [page.profile.displayName]);
    Widget subheading(String text) => Padding(
      padding: EdgeInsets.only(bottom: 10 * scale),
      child: Text(
        T.upper(text),
        style: AppText.display(
          12 * scale,
          weight: FontWeight.w700,
          color: Colors.white.withValues(alpha: 0.55),
        ).copyWith(letterSpacing: 1.2 * scale),
      ),
    );
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // What they pinned: nothing on a server without showcases, or with nothing pinned.
          if (showcase is SectionPrivate<Showcase> || (pinned != null && pinned.private)) ...[
            heading(T.text('showcaseTitle')),
            note(private),
          ] else if (pinned != null && !pinned.empty) ...[
            heading(T.text('showcaseTitle')),
            if (pinned.trophies case final List<EarnedTrophy> list when list.isNotEmpty) ...[
              subheading(T.text('showcaseTrophies')),
              Wrap(
                spacing: 10 * scale,
                runSpacing: 10 * scale,
                children: [for (final trophy in list) _PinnedTrophy(trophy: trophy, language: language)],
              ),
              SizedBox(height: 18 * scale),
            ] else if (pinned.trophies == null) ...[
              subheading(T.text('showcaseTrophies')),
              note(private),
            ],
            if (pinned.games case final List<PlayedGame> list when list.isNotEmpty) ...[
              subheading(T.text('showcaseGames')),
              Wrap(
                spacing: 14 * scale,
                runSpacing: 14 * scale,
                children: [for (final game in list) _PinnedGame(model: model, game: game, accent: accent)],
              ),
              SizedBox(height: 18 * scale),
            ] else if (pinned.games == null) ...[
              subheading(T.text('showcaseGames')),
              note(private),
            ],
            SizedBox(height: 10 * scale),
          ] else if (page.profile.isMe && together.signedIn) ...[
            // The user's own, nothing pinned yet: where Edit showcase will put them.
            heading(T.text('showcaseTitle')),
            note(T.text('showcaseEmpty')),
          ],
          // The pinned gallery, under the showcase, as the owner's setting shows it.
          if (gallery is SectionPrivate<List<MediaItem>>) ...[
            heading(T.text('cloudProfileGallery')),
            note(T.text('cloudProfileGalleryPrivate')),
          ] else if (galleryItems != null && galleryItems.isNotEmpty) ...[
            heading(T.text('cloudProfileGallery')),
            Wrap(
              spacing: 12 * scale,
              runSpacing: 12 * scale,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final media in galleryItems.take(8)) _GalleryTile(model: model, media: media),
                if (galleryItems.length > 8)
                  Text(
                    '+${galleryItems.length - 8}',
                    style: AppText.display(
                      17 * scale,
                      weight: FontWeight.w600,
                      color: Colors.white.withValues(alpha: 0.7),
                    ),
                  ),
              ],
            ),
            SizedBox(height: 18 * scale),
          ] else if (galleryItems != null && page.profile.isMe) ...[
            heading(T.text('cloudProfileGallery')),
            note(T.text('cloudProfileGalleryEmpty')),
          ],
          heading(T.text('profileGamesTitle')),
          if (games.isEmpty) note(closed(page.library, T.text('profileNoGames'))),
          for (var index = 0; index < games.length; index++)
            KeepVisible(
              active: together.profileIndex == from + index,
              child: _GameRow(
                model: model,
                game: games[index],
                focused: together.profileIndex == from + index,
                accent: accent,
              ),
            ),
          SizedBox(height: 18 * scale),
          heading(T.text('profileRecentTrophies')),
          if (trophies.isEmpty) note(closed(page.trophies, T.text('profileNoTrophies'))),
          for (var index = 0; index < trophies.length; index++)
            KeepVisible(
              active: together.profileIndex == from + games.length + index,
              child: _TrophyRow(
                trophy: trophies[index],
                language: language,
                focused: together.profileIndex == from + games.length + index,
              ),
            ),
          // Their recent activity, as the Mac's profile has it: nothing on a server without it.
          if (page.activity is! SectionFailed) ...[
            SizedBox(height: 18 * scale),
            heading(T.text('profileRecentActivity')),
            if (activity.isEmpty) note(closed(page.activity, T.text('profileNoActivity'))),
            for (var index = 0; index < activity.length; index++)
              KeepVisible(
                active: together.profileIndex == from + games.length + trophies.length + index,
                child: ProfileActivityRow(
                  key: ValueKey('profile-activity-${activity[index].id}'),
                  model: model,
                  item: activity[index],
                  focused: together.profileIndex == from + games.length + trophies.length + index,
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// One pinned photo or clip; pressed, over the whole screen.
class _GalleryTile extends StatelessWidget {
  const _GalleryTile({required this.model, required this.media});

  final AppModel model;
  final MediaItem media;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return Semantics(
      container: true,
      button: true,
      label: T.text(media.clip ? 'clip' : 'messagesPhoto'),
      onTap: () => model.together.viewProfileMedia(media),
      excludeSemantics: true,
      child: Pressable(
        onTap: () => model.together.viewProfileMedia(media),
        builder: (context, hovering) => ClipRRect(
          borderRadius: BorderRadius.circular(10 * scale),
          child: SizedBox(
            width: 150 * scale,
            height: 84 * scale,
            child: Stack(
              fit: StackFit.expand,
              children: [
                RemotePicture(model: model, link: media.still),
                if (media.clip)
                  Center(
                    child: Container(
                      padding: EdgeInsets.all(8 * scale),
                      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.5), shape: BoxShape.circle),
                      child: Icon(Icons.play_arrow_rounded, size: 18 * scale, color: Colors.white),
                    ),
                  ),
                if (hovering) ColoredBox(color: Colors.white.withValues(alpha: 0.08)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _GameRow extends StatelessWidget {
  const _GameRow({required this.model, required this.game, required this.focused, required this.accent});

  final AppModel model;
  final PlayedGame game;
  final bool focused;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final local = model.games.where((known) => known.titleId == game.titleId).firstOrNull;
    final color = focused ? LookScope.focusedInk(context) : Colors.white;
    final last = game.lastPlayedAt?.toLocal();
    final detail = [
      TogetherProfiles.playTime(game.secondsPlayed),
      if (last != null)
        T.format('profileLastPlayed', [
          '${last.year}-${last.month.toString().padLeft(2, '0')}-${last.day.toString().padLeft(2, '0')}',
        ]),
    ].join(' · ');
    return PaneRow(
      focused: focused,
      radius: 14 * scale,
      margin: EdgeInsets.only(bottom: 8 * scale),
      padding: EdgeInsets.all(12 * scale),
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
                      child: Icon(Icons.sports_esports_rounded, size: 26 * scale, color: color.withValues(alpha: 0.5)),
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
                  style: AppText.display(17 * scale, weight: FontWeight.w600, color: color),
                ),
                SizedBox(height: 4 * scale),
                Text(detail, style: AppText.display(13 * scale, color: color.withValues(alpha: 0.6))),
                if (game.progress != null) ...[
                  SizedBox(height: 8 * scale),
                  SizedBox(
                    width: 260 * scale,
                    child: ProgressLine(fraction: game.progress! / 100, color: accent, height: 4 * scale),
                  ),
                ],
              ],
            ),
          ),
          if (game.trophiesEarned != null) ...[
            SizedBox(width: 16 * scale),
            Icon(Icons.emoji_events_rounded, size: 20 * scale, color: color.withValues(alpha: 0.7)),
            SizedBox(width: 6 * scale),
            Text(
              game.trophiesTotal == null ? '${game.trophiesEarned}' : '${game.trophiesEarned}/${game.trophiesTotal}',
              style: AppText.display(15 * scale, weight: FontWeight.w600, color: color),
            ),
          ],
        ],
      ),
    );
  }
}

class _TrophyRow extends StatelessWidget {
  const _TrophyRow({required this.trophy, required this.language, required this.focused});

  final EarnedTrophy trophy;
  final String language;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final color = focused ? LookScope.focusedInk(context) : Colors.white;
    final grade = TrophyGrade.values.where((value) => value.name == trophy.grade).firstOrNull ?? TrophyGrade.bronze;
    final rarity = TogetherProfiles.rarity(trophy.rarityLabel);
    final percent = trophy.rarity == null
        ? null
        : T.percent(T.decimal(trophy.rarity! * 100, trophy.rarity! < 0.1 ? 1 : 0));
    return PaneRow(
      focused: focused,
      radius: 14 * scale,
      margin: EdgeInsets.only(bottom: 8 * scale),
      padding: EdgeInsets.symmetric(horizontal: 16 * scale, vertical: 12 * scale),
      child: Row(
        children: [
          Icon(Icons.emoji_events_rounded, size: 28 * scale, color: TrophyView.gradeColor(grade)),
          SizedBox(width: 16 * scale),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  trophy.name(language) ?? T.text('trophyHidden'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.display(16 * scale, weight: FontWeight.w600, color: color),
                ),
                SizedBox(height: 3 * scale),
                Text(
                  trophy.gameName(language),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.display(13 * scale, color: color.withValues(alpha: 0.6)),
                ),
              ],
            ),
          ),
          if (rarity.isNotEmpty)
            Text(
              percent == null ? rarity : '$rarity · $percent',
              style: AppText.display(13 * scale, weight: FontWeight.w600, color: color.withValues(alpha: 0.7)),
            ),
        ],
      ),
    );
  }
}

class _Total extends StatelessWidget {
  const _Total({required this.label, required this.value});

  final String label;
  final String value;

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
          SizedBox(height: 2 * scale),
          Text(
            T.upper(label),
            style: AppText.display(11 * scale, weight: FontWeight.w700, color: Colors.white.withValues(alpha: 0.55)),
          ),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8 * scale, vertical: 3 * scale),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(6 * scale)),
      child: Text(
        text,
        style: AppText.display(12 * scale, weight: FontWeight.w700, color: color),
      ),
    );
  }
}

/// Under a profile's totals: Compare trophies on someone else's (focused first when the profile
/// opens), Edit showcase and Profile theme on the user's own.
class _ProfileButton extends StatelessWidget {
  const _ProfileButton({required this.icon, required this.label, required this.focused, required this.onTap});

  final IconData icon;
  final String label;
  final bool focused;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    // The column scrolls on a short window: the keys bring the focused button into view.
    return KeepVisible(
      active: focused,
      child: Semantics(
        container: true,
        button: true,
        label: label,
        onTap: onTap,
        excludeSemantics: true,
        child: Pressable(
          onTap: onTap,
          pressScale: 0.98,
          builder: (context, hovering) {
            final ink = focused ? Colors.black : Colors.white;
            return AnimatedContainer(
              duration: Motion.focus,
              curve: Motion.settle,
              width: 368 * scale,
              padding: EdgeInsets.symmetric(horizontal: 18 * scale, vertical: 14 * scale),
              decoration: BoxDecoration(
                color: focused ? Colors.white : Colors.white.withValues(alpha: hovering ? 0.12 : 0.06),
                borderRadius: BorderRadius.circular(14 * scale),
                border: Border.all(color: Colors.white.withValues(alpha: focused ? 0 : 0.08)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.white.withValues(alpha: focused ? 0.22 : 0),
                    blurRadius: 16 * scale,
                  ),
                ],
              ),
              child: Row(
                children: [
                  Icon(icon, size: 22 * scale, color: ink),
                  SizedBox(width: 12 * scale),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.display(16 * scale, weight: FontWeight.w600, color: ink),
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded, size: 22 * scale, color: ink.withValues(alpha: 0.6)),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// A pinned trophy: its grade's cup, its name and its game.
class _PinnedTrophy extends StatelessWidget {
  const _PinnedTrophy({required this.trophy, required this.language});

  final EarnedTrophy trophy;
  final String language;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final grade = TrophyGrade.values.where((value) => value.name == trophy.grade).firstOrNull ?? TrophyGrade.bronze;
    final color = TrophyView.gradeColor(grade);
    return Container(
      width: 300 * scale,
      padding: EdgeInsets.symmetric(horizontal: 14 * scale, vertical: 12 * scale),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14 * scale),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [color.withValues(alpha: 0.16), Colors.white.withValues(alpha: 0.04)],
        ),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Row(
        children: [
          Icon(Icons.emoji_events_rounded, size: 26 * scale, color: color),
          SizedBox(width: 12 * scale),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  trophy.name(language) ?? T.text('trophyHidden'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.display(15 * scale, weight: FontWeight.w600),
                ),
                SizedBox(height: 2 * scale),
                Text(
                  trophy.gameName(language),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.display(12.5 * scale, color: Colors.white.withValues(alpha: 0.6)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A favourite game: its icon (from this library when it is here), its name, its progress.
class _PinnedGame extends StatelessWidget {
  const _PinnedGame({required this.model, required this.game, required this.accent});

  final AppModel model;
  final PlayedGame game;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final local = model.games.where((known) => known.titleId == game.titleId).firstOrNull;
    return SizedBox(
      width: 112 * scale,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(16 * scale),
            child: SizedBox.square(
              dimension: 112 * scale,
              child: local?.icon != null
                  ? ArtworkImage(path: local!.icon!, cacheWidth: 240)
                  : ColoredBox(
                      color: Colors.white.withValues(alpha: 0.08),
                      child: Icon(
                        Icons.sports_esports_rounded,
                        size: 36 * scale,
                        color: Colors.white.withValues(alpha: 0.4),
                      ),
                    ),
            ),
          ),
          SizedBox(height: 8 * scale),
          Text(
            local?.nameFor([T.language.code]) ?? game.name(T.language.code),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.display(13.5 * scale, weight: FontWeight.w600),
          ),
          if (game.progress != null) ...[
            SizedBox(height: 6 * scale),
            ProgressLine(fraction: game.progress! / 100, color: accent, height: 3 * scale),
          ],
        ],
      ),
    );
  }
}
