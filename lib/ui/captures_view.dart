import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/screenshots.dart';
import '../core/together/posts.dart';
import 'app_model.dart';
import 'clip_player.dart';
import 'components.dart';
import 'glass.dart';
import 'panels.dart';
import 'strings.dart';
import 'theme.dart';
import 'together_model.dart';

/// Captures on AnyTogether, as on the Mac: what the screen is on the left with its keys, the
/// posts on the right newest first, each with Like, Comments, View (and Delete on one's own); a
/// post's comments in a sheet; a picture over the whole screen.
class CapturesView extends StatelessWidget {
  const CapturesView({super.key, required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final together = model.together;
    final captures = together.captures;
    final accent = model.accentChoice.color;
    final muted = Colors.white.withValues(alpha: 0.6);
    return Stack(
      children: [
        LayerScrim(
          opacity: 0.64,
          child: Padding(
            padding: EdgeInsets.fromLTRB(90 * scale, 64 * scale, 90 * scale, 50 * scale),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 360 * scale,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(T.text('friendsTitle'), style: AppText.display(18 * scale, color: muted)),
                      SizedBox(height: 22 * scale),
                      CustomPaint(
                        foregroundPainter: CaptureCorners(color: accent, length: 18 * scale, width: 3 * scale),
                        child: Container(
                          width: 88 * scale,
                          height: 88 * scale,
                          margin: EdgeInsets.all(6 * scale),
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(18 * scale),
                          ),
                          child: Icon(Icons.photo_library_rounded, size: 38 * scale, color: accent),
                        ),
                      ),
                      SizedBox(height: 20 * scale),
                      Text(T.text('capturesTitle'), style: AppText.display(38 * scale, weight: FontWeight.w300)),
                      SizedBox(height: 10 * scale),
                      Text(
                        T.text('capturesSubtitle'),
                        style: AppText.display(15 * scale, color: Colors.white.withValues(alpha: 0.7), height: 1.4),
                      ),
                      const Spacer(),
                      Wrap(
                        spacing: 10 * scale,
                        runSpacing: 8 * scale,
                        children: [
                          Hint(keys: '↑ ↓ ← →', label: T.text('hintMove')),
                          Hint(
                            keys: 'Enter',
                            glyph: PadGlyph.cross,
                            label: T.text('capturesHintAction'),
                            action: HintAction.select,
                          ),
                          Hint(
                            keys: 'O',
                            glyph: PadGlyph.triangle,
                            label: T.text('capturesHintAuthor'),
                            action: HintAction.options,
                          ),
                          Hint(keys: 'Esc', glyph: PadGlyph.circle, label: T.text('hintBack'), action: HintAction.back),
                        ],
                      ),
                    ],
                  ),
                ),
                SizedBox(width: 60 * scale),
                Expanded(child: _PostList(model: model)),
              ],
            ),
          ),
        ),
        if (captures.thread != null)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: together.closeComments,
              child: ColoredBox(
                color: Colors.black.withValues(alpha: 0.4),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: GestureDetector(
                    onTap: () {},
                    child: _CommentsSheet(model: model),
                  ),
                ),
              ),
            ),
          ),
        if (captures.viewing case final viewing?)
          Positioned.fill(
            child: CaptureViewer(model: model, media: viewing),
          ),
      ],
    );
  }
}

class _PostList extends StatelessWidget {
  const _PostList({required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final together = model.together;
    final captures = together.captures;
    final feed = captures.feed;
    final note = !feed.loaded
        ? T.text(
            !captures.failed
                ? 'capturesLoading'
                : model.saveSync.info?.enabled == false
                ? 'capturesRefusedStorage'
                : 'capturesFailed',
          )
        : feed.items.isEmpty
        ? T.text('capturesEmpty')
        : null;
    return SingleChildScrollView(
      padding: EdgeInsets.only(top: 40 * scale, bottom: 12 * scale, left: 6 * scale, right: 6 * scale),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (note != null)
            Text(note, style: AppText.display(17 * scale, color: Colors.white.withValues(alpha: 0.6), height: 1.4)),
          for (var index = 0; index < feed.items.length; index++)
            KeepVisible(
              active: captures.index == index,
              child: _PostCard(
                key: ValueKey('post-${feed.items[index].id}'),
                model: model,
                index: index,
                post: feed.items[index],
                focused: captures.index == index && captures.thread == null,
              ),
            ),
          if (feed.loaded && feed.next != null)
            Text(
              T.text('capturesMore'),
              style: AppText.display(14 * scale, color: Colors.white.withValues(alpha: 0.45)),
            ),
        ],
      ),
    );
  }
}

/// One post: who and when, the game, the picture or the clip's poster, the caption, and the
/// actions with their counts.
class _PostCard extends StatelessWidget {
  const _PostCard({super.key, required this.model, required this.index, required this.post, required this.focused});

  final AppModel model;
  final int index;
  final Post post;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final together = model.together;
    final captures = together.captures;
    final actions = together.captureActions(post);
    final shown = post.shown;
    final still = shown.firstOrNull;
    final name = TogetherModel.shown(post.author).name;
    final muted = Colors.white.withValues(alpha: 0.6);
    return Padding(
      padding: EdgeInsets.only(bottom: 22 * scale),
      child: FocusRing(
        focused: focused,
        radius: 22 * scale,
        child: AnimatedContainer(
          duration: Motion.focus,
          curve: Motion.settle,
          padding: EdgeInsets.all(18 * scale),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: focused ? 0.1 : 0.05),
            borderRadius: BorderRadius.circular(22 * scale),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  PersonAvatar(person: TogetherModel.card(post.author), size: 40 * scale),
                  SizedBox(width: 12 * scale),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.display(16 * scale, weight: FontWeight.w600),
                        ),
                        Text(
                          [
                            '@${post.author.handle}',
                            TogetherSocial.ago(post.createdAt),
                            T.text(
                              post.visibility == PostVisibility.public ? 'capturesEveryone' : 'capturesFriendsOnly',
                            ),
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.display(13 * scale, color: muted),
                        ),
                      ],
                    ),
                  ),
                  if (post.game case final game?)
                    Container(
                      constraints: BoxConstraints(maxWidth: 240 * scale),
                      padding: EdgeInsets.symmetric(horizontal: 10 * scale, vertical: 5 * scale),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(20 * scale),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.sports_esports_rounded, size: 14 * scale, color: muted),
                          SizedBox(width: 6 * scale),
                          Flexible(
                            child: Text(
                              game.name(T.language.code),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppText.display(12 * scale, weight: FontWeight.w600, color: muted),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
              SizedBox(height: 14 * scale),
              if (still != null)
                GestureDetector(
                  onTap: () => together.tapCaptureAction(index, CaptureAction.view),
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(14 * scale),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          RemotePicture(model: model, link: still.still, fit: BoxFit.cover),
                          if (post.clip != null)
                            Center(
                              child: Container(
                                padding: EdgeInsets.all(12 * scale),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Colors.black.withValues(alpha: 0.5),
                                ),
                                child: Icon(Icons.play_arrow_rounded, size: 34 * scale, color: Colors.white),
                              ),
                            ),
                          if (post.clip?.durationMs case final ms?)
                            Positioned(
                              right: 10 * scale,
                              bottom: 10 * scale,
                              child: _Badge(text: TogetherCaptures.clock(ms)),
                            ),
                          if (shown.length > 1)
                            Positioned(
                              right: 10 * scale,
                              top: 10 * scale,
                              child: _Badge(text: '1 / ${shown.length}'),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              if (post.caption case final caption? when caption.isNotEmpty) ...[
                SizedBox(height: 12 * scale),
                Text(caption, style: AppText.display(15 * scale, height: 1.35)),
              ],
              SizedBox(height: 14 * scale),
              Wrap(
                spacing: 10 * scale,
                runSpacing: 8 * scale,
                children: [
                  for (var at = 0; at < actions.length; at++)
                    _ActionPill(
                      model: model,
                      post: post,
                      action: actions[at],
                      focused: focused && captures.action == at,
                      armed: captures.armedPost == post.id,
                      onTap: () => together.tapCaptureAction(index, actions[at]),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8 * scale, vertical: 3 * scale),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(10 * scale),
      ),
      child: Text(text, style: AppText.display(12 * scale, weight: FontWeight.w600)),
    );
  }
}

class _ActionPill extends StatelessWidget {
  const _ActionPill({
    required this.model,
    required this.post,
    required this.action,
    required this.focused,
    required this.armed,
    required this.onTap,
  });

  final AppModel model;
  final Post post;
  final CaptureAction action;
  final bool focused;
  final bool armed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    const heart = Color(0xFFFF5C8A);
    final (IconData icon, String label, Color? tint) = switch (action) {
      CaptureAction.like => (
        post.liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
        '${T.text(post.liked ? 'capturesLiked' : 'capturesLike')} · ${post.likes}',
        post.liked ? heart : null,
      ),
      CaptureAction.comments => (
        Icons.chat_bubble_outline_rounded,
        post.commentsOff ? T.text('capturesCommentsOff') : '${T.text('capturesComments')} · ${post.comments}',
        null,
      ),
      CaptureAction.view => (
        post.clip != null ? Icons.play_circle_outline_rounded : Icons.open_in_full_rounded,
        T.text('capturesView'),
        null,
      ),
      CaptureAction.delete => (
        Icons.delete_outline_rounded,
        T.text(armed ? 'capturesDeleteAgain' : 'capturesDelete'),
        armed ? const Color(0xFFFF6B6B) : null,
      ),
    };
    final ink = focused ? Colors.black : (tint ?? Colors.white);
    return Semantics(
      button: true,
      label: label,
      child: Pressable(
        onTap: onTap,
        builder: (context, hovering) => AnimatedContainer(
          duration: Motion.focus,
          curve: Motion.settle,
          padding: EdgeInsets.symmetric(horizontal: 14 * scale, vertical: 8 * scale),
          decoration: BoxDecoration(
            color: focused ? Colors.white : Colors.white.withValues(alpha: hovering ? 0.14 : 0.07),
            borderRadius: BorderRadius.circular(20 * scale),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16 * scale, color: focused && tint != null ? tint : ink),
              SizedBox(width: 7 * scale),
              Text(
                label,
                style: AppText.display(13 * scale, weight: FontWeight.w600, color: ink),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A post's comments: the composer first (quick comments and the field), then each comment with
/// its replies under it.
class _CommentsSheet extends StatelessWidget {
  const _CommentsSheet({required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final together = model.together;
    final captures = together.captures;
    final thread = captures.thread!;
    final lines = thread.lines;
    final post = together.commentsPost;
    final open = post?.commentsOff != true;
    final muted = Colors.white.withValues(alpha: 0.6);
    final note = captures.commentsFailed
        ? T.text('capturesCommentsFailed')
        : !thread.loaded
        ? T.text('capturesCommentsLoading')
        : lines.isEmpty
        ? T.text('capturesCommentsEmpty')
        : null;
    return SizedBox(
      width: 560 * scale,
      height: double.infinity,
      child: Glass(
        radius: 0,
        opacity: 0.8,
        padding: EdgeInsets.fromLTRB(32 * scale, 48 * scale, 32 * scale, 28 * scale),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(T.text('capturesCommentsTitle'), style: AppText.display(28 * scale, weight: FontWeight.w300)),
            if (post != null) ...[
              SizedBox(height: 6 * scale),
              Text(
                [TogetherModel.shown(post.author).name, if (post.caption != null) post.caption!].join(' · '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppText.display(14 * scale, color: muted),
              ),
            ],
            SizedBox(height: 20 * scale),
            if (open) ...[
              if (captures.replyTo case final reply?)
                Padding(
                  padding: EdgeInsets.only(bottom: 8 * scale),
                  child: Text(
                    T.format('capturesReplyingTo', [TogetherModel.shown(reply.author).name]),
                    style: AppText.display(13 * scale, weight: FontWeight.w600, color: model.accentChoice.color),
                  ),
                ),
              Wrap(
                spacing: 8 * scale,
                runSpacing: 8 * scale,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (var at = 0; at < TogetherCaptures.quickComments.length; at++)
                    _QuickComment(
                      label: TogetherCaptures.quickComments[at],
                      focused: captures.line == 0 && captures.composer == at,
                      onTap: () => unawaited(together.sendComment(TogetherCaptures.quickComments[at])),
                    ),
                ],
              ),
              SizedBox(height: 10 * scale),
              FocusRing(
                focused:
                    captures.line == 0 &&
                    captures.composer == TogetherCaptures.quickComments.length &&
                    model.editingRow == null,
                radius: 12 * scale,
                child: RowTextField(
                  model: model,
                  row: together.commentField,
                  kind: together.commentField.kind as TextRow,
                  focused: false,
                ),
              ),
            ] else
              Text(T.text('capturesRefusedCommentsOff'), style: AppText.display(14 * scale, color: muted)),
            SizedBox(height: 18 * scale),
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.all(4 * scale),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (note != null) Text(note, style: AppText.display(15 * scale, color: muted)),
                    for (var at = 0; at < lines.length; at++)
                      KeepVisible(
                        active: captures.line == at + 1,
                        child: _CommentRow(
                          line: lines[at],
                          focused: captures.line == at + 1,
                          armed: captures.armedComment == lines[at].comment.id,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            SizedBox(height: 12 * scale),
            Wrap(
              spacing: 10 * scale,
              runSpacing: 8 * scale,
              children: [
                Hint(
                  keys: 'Enter',
                  glyph: PadGlyph.cross,
                  label: T.text('capturesHintReply'),
                  action: HintAction.select,
                ),
                Hint(
                  keys: 'O',
                  glyph: PadGlyph.triangle,
                  label: T.text('capturesHintDelete'),
                  action: HintAction.options,
                ),
                Hint(keys: 'Esc', glyph: PadGlyph.circle, label: T.text('hintBack'), action: HintAction.back),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickComment extends StatelessWidget {
  const _QuickComment({required this.label, required this.focused, required this.onTap});

  final String label;
  final bool focused;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return Pressable(
      onTap: onTap,
      builder: (context, hovering) => AnimatedContainer(
        duration: Motion.focus,
        padding: EdgeInsets.symmetric(horizontal: 14 * scale, vertical: 8 * scale),
        decoration: BoxDecoration(
          color: focused ? Colors.white : Colors.white.withValues(alpha: hovering ? 0.16 : 0.08),
          borderRadius: BorderRadius.circular(18 * scale),
        ),
        child: Text(
          label,
          style: AppText.display(14 * scale, weight: FontWeight.w600, color: focused ? Colors.black : Colors.white),
        ),
      ),
    );
  }
}

class _CommentRow extends StatelessWidget {
  const _CommentRow({required this.line, required this.focused, required this.armed});

  final CommentLine line;
  final bool focused;
  final bool armed;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final comment = line.comment;
    final ink = focused ? Colors.black : Colors.white;
    return Padding(
      padding: EdgeInsets.only(left: line.isReply ? 44 * scale : 0, bottom: 6 * scale),
      child: AnimatedContainer(
        duration: Motion.focus,
        curve: Motion.settle,
        padding: EdgeInsets.all(12 * scale),
        decoration: BoxDecoration(
          color: focused ? Colors.white : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(14 * scale),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PersonAvatar(
              person: TogetherModel.card(comment.author),
              size: (line.isReply ? 28 : 34) * scale,
              focused: focused,
            ),
            SizedBox(width: 10 * scale),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${TogetherModel.shown(comment.author).name} · ${TogetherSocial.ago(comment.createdAt)}',
                    style: AppText.display(12 * scale, weight: FontWeight.w600, color: ink.withValues(alpha: 0.6)),
                  ),
                  SizedBox(height: 2 * scale),
                  Text(comment.text, style: AppText.display(15 * scale, color: ink, height: 1.3)),
                  if (armed)
                    Padding(
                      padding: EdgeInsets.only(top: 4 * scale),
                      child: Text(
                        T.text('capturesCommentDeleteAgain'),
                        style: AppText.display(12 * scale, weight: FontWeight.w600, color: const Color(0xFFFF6B6B)),
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

/// A post's picture or clip over the whole screen: a click on the picture, or around the clip,
/// closes it; a clip plays in the launcher.
class CaptureViewer extends StatelessWidget {
  const CaptureViewer({super.key, required this.model, required this.media});

  final AppModel model;
  final MediaItem media;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final poster = media.poster ?? media.thumb;
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.94),
      child: WithBackPill(
        onBack: model.together.closeViewer,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: model.together.closeViewer,
          child: Padding(
            padding: EdgeInsets.fromLTRB(70 * scale, 80 * scale, 70 * scale, 40 * scale),
            child: media.clip
                ? Center(
                    child: AspectRatio(
                      aspectRatio: mediaAspect(media.width, media.height),
                      child: GestureDetector(
                        onTap: () {},
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(14 * scale),
                          child: ClipPlayerView(
                            source: media.url,
                            create: model.services.clipPlayback,
                            onFailed: model.playClipOutside,
                            accent: model.accentChoice.color,
                            poster: poster == null
                                ? null
                                : RemotePicture(model: model, link: poster, fit: BoxFit.contain),
                          ),
                        ),
                      ),
                    ),
                  )
                : RemotePicture(model: model, link: media.url, fit: BoxFit.contain),
          ),
        ),
      ),
    );
  }
}

/// A picture behind an AnyTogether signed link, read once and kept while the screen needs it.
class RemotePicture extends StatelessWidget {
  const RemotePicture({super.key, required this.model, required this.link, this.fit = BoxFit.cover});

  final AppModel model;
  final String link;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List>(
    future: model.together.picture(link),
    builder: (context, snapshot) {
      final bytes = snapshot.data;
      if (bytes == null) {
        return ColoredBox(
          color: Colors.white.withValues(alpha: 0.06),
          child: snapshot.hasError
              ? Icon(Icons.broken_image_outlined, color: Colors.white.withValues(alpha: 0.4))
              : null,
        );
      }
      return Image.memory(bytes, fit: fit, gaplessPlayback: true, filterQuality: FilterQuality.medium);
    },
  );
}

/// A camera's framing marks at the corners of what it is drawn over.
class CaptureCorners extends CustomPainter {
  const CaptureCorners({required this.color, required this.length, required this.width});

  final Color color;
  final double length;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = width
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final l = [length, size.width / 3, size.height / 3].reduce((a, b) => a < b ? a : b);
    for (final (x, y, dx, dy) in [
      (0.0, 0.0, 1.0, 1.0),
      (size.width, 0.0, -1.0, 1.0),
      (0.0, size.height, 1.0, -1.0),
      (size.width, size.height, -1.0, -1.0),
    ]) {
      canvas.drawPath(
        Path()
          ..moveTo(x + dx * l, y)
          ..lineTo(x, y)
          ..lineTo(x, y + dy * l),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(CaptureCorners oldDelegate) =>
      oldDelegate.color != color || oldDelegate.length != length || oldDelegate.width != width;
}

/// The gallery with what goes over it, as on the Mac: the Share menu (a post, a chat, the
/// AnyTogether gallery, the file's folder) and the post being written.
class GalleryWithShare extends StatelessWidget {
  const GalleryWithShare({super.key, required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final together = model.together;
    final captures = together.captures;
    return Stack(
      children: [
        GalleryView(model: model),
        if (model.galleryShots.isNotEmpty && !captures.sharing && captures.draft == null)
          Positioned(
            right: 80 * scale,
            bottom: 28 * scale,
            child: Hint(
              keys: 'O',
              glyph: PadGlyph.triangle,
              label: T.text('cloudHintShare'),
              action: HintAction.options,
            ),
          ),
        if (captures.sharing)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: together.closeShareMenu,
              child: ColoredBox(
                color: Colors.black.withValues(alpha: 0.4),
                child: Center(
                  child: GestureDetector(
                    onTap: () {},
                    child: _ShareMenu(model: model),
                  ),
                ),
              ),
            ),
          ),
        if (captures.draft != null)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: together.closePostDraft,
              child: ColoredBox(
                color: Colors.black.withValues(alpha: 0.35),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: GestureDetector(
                    onTap: () {},
                    child: _PostComposer(model: model),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _ShareMenu extends StatelessWidget {
  const _ShareMenu({required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final together = model.together;
    final targets = together.shareTargets;
    final me = together.user?.id;
    return SizedBox(
      width: 520 * scale,
      child: Glass(
        radius: 26 * scale,
        opacity: 0.75,
        padding: EdgeInsets.all(26 * scale),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(T.text('cloudShare'), style: AppText.display(26 * scale, weight: FontWeight.w300)),
            SizedBox(height: 16 * scale),
            for (var at = 0; at < targets.length; at++)
              _ShareRow(
                focused: together.captures.shareIndex == at,
                onTap: () {
                  together.captures.shareIndex = at;
                  unawaited(together.share(targets[at]));
                },
                target: targets[at],
                title: switch (targets[at]) {
                  PostShare() => T.text('capturesShareToTogether'),
                  ChatShare(:final conversation) => T.format('cloudSendToChat', [conversation.name(me)]),
                  GalleryShare() => T.text('cloudShareToGallery'),
                  FolderShare() => T.text('cloudShowInFolder'),
                },
                detail: switch (targets[at]) {
                  PostShare() => T.text('capturesShareToTogetherDetail'),
                  ChatShare() || GalleryShare() || FolderShare() => null,
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _ShareRow extends StatelessWidget {
  const _ShareRow({required this.focused, required this.onTap, required this.target, required this.title, this.detail});

  final bool focused;
  final VoidCallback onTap;
  final ShareTarget target;
  final String title;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final ink = focused ? Colors.black : Colors.white;
    final icon = switch (target) {
      PostShare() => Icons.photo_library_rounded,
      ChatShare(:final conversation) => conversation.group ? Icons.groups_rounded : Icons.chat_bubble_rounded,
      GalleryShare() => Icons.collections_rounded,
      FolderShare() => Icons.folder_open_rounded,
    };
    return Padding(
      padding: EdgeInsets.only(bottom: 6 * scale),
      child: Pressable(
        onTap: onTap,
        builder: (context, hovering) => AnimatedContainer(
          duration: Motion.focus,
          curve: Motion.settle,
          padding: EdgeInsets.symmetric(horizontal: 16 * scale, vertical: 11 * scale),
          decoration: BoxDecoration(
            color: focused ? Colors.white : Colors.white.withValues(alpha: hovering ? 0.12 : 0.05),
            borderRadius: BorderRadius.circular(14 * scale),
          ),
          child: Row(
            children: [
              Icon(icon, size: 20 * scale, color: ink),
              SizedBox(width: 14 * scale),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.display(16 * scale, weight: FontWeight.w600, color: ink),
                    ),
                    if (detail != null)
                      Text(detail!, style: AppText.display(13 * scale, color: ink.withValues(alpha: 0.6))),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Over the gallery: the capture in viewfinder corners, its caption, Friends or Public, and Post.
class _PostComposer extends StatelessWidget {
  const _PostComposer({required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final together = model.together;
    final captures = together.captures;
    final draft = captures.draft!;
    final file = captures.draftFile;
    final accent = model.accentChoice.color;
    final muted = Colors.white.withValues(alpha: 0.55);
    final busy = captures.stage != PostStage.idle;
    final check = captures.clipCheck;
    Widget label(String text) => Text(
      T.upper(text),
      style: AppText.display(12 * scale, weight: FontWeight.w600, color: Colors.white.withValues(alpha: 0.5)),
    );
    return SizedBox(
      width: 520 * scale,
      height: double.infinity,
      child: Glass(
        radius: 0,
        opacity: 0.85,
        padding: EdgeInsets.all(30 * scale),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(T.text('capturesPostTitle'), style: AppText.display(28 * scale, weight: FontWeight.w300)),
            SizedBox(height: 6 * scale),
            Text(
              [
                if (model.selectedGame case final game?) game.nameFor([T.language.code]),
                T.text('capturesPostSubtitle'),
              ].join(' · '),
              maxLines: 2,
              style: AppText.display(14 * scale, color: Colors.white.withValues(alpha: 0.6)),
            ),
            SizedBox(height: 18 * scale),
            if (file != null)
              CustomPaint(
                foregroundPainter: CaptureCorners(
                  color: Colors.white.withValues(alpha: 0.7),
                  length: 18 * scale,
                  width: 2 * scale,
                ),
                child: Padding(
                  padding: EdgeInsets.all(10 * scale),
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10 * scale),
                      child: Screenshots.isClip(file)
                          ? Stack(
                              fit: StackFit.expand,
                              children: [
                                ColoredBox(color: Colors.white.withValues(alpha: 0.06)),
                                Icon(Icons.movie_rounded, size: 44 * scale, color: Colors.white.withValues(alpha: 0.6)),
                                if (captures.clipMs case final ms?)
                                  Positioned(
                                    right: 8 * scale,
                                    bottom: 8 * scale,
                                    child: _Badge(text: TogetherCaptures.clock(ms)),
                                  ),
                              ],
                            )
                          : ArtworkImage(path: file, cacheWidth: 960),
                    ),
                  ),
                ),
              ),
            if (check != null && check is! ClipFits) ...[
              SizedBox(height: 12 * scale),
              Container(
                padding: EdgeInsets.all(14 * scale),
                decoration: BoxDecoration(
                  color: (check.blocks ? const Color(0xFFFF9E80) : Colors.white).withValues(
                    alpha: check.blocks ? 0.12 : 0.06,
                  ),
                  borderRadius: BorderRadius.circular(14 * scale),
                ),
                child: Text(
                  switch (check) {
                    ClipTooLong() => '${together.clipTooLongText}. ${T.text('capturesClipTooLongDetail')}',
                    ClipTooBig(:final bytes) => T.format('capturesClipTooBig', [
                      _size(bytes),
                      _size(together.storage?.media.clip ?? PostLimits.clipBytes),
                    ]),
                    ClipFits() => '',
                  },
                  style: AppText.display(
                    14 * scale,
                    color: check.blocks ? const Color(0xFFFF9E80) : Colors.white.withValues(alpha: 0.85),
                    height: 1.35,
                  ),
                ),
              ),
            ],
            SizedBox(height: 18 * scale),
            Row(
              children: [
                Expanded(child: label(T.text('capturesCaption'))),
                if (draft.caption.isNotEmpty)
                  Text(
                    T.format('capturesCaptionCount', [draft.caption.runes.length, PostLimits.caption]),
                    style: AppText.display(12 * scale, color: muted),
                  ),
              ],
            ),
            SizedBox(height: 8 * scale),
            GestureDetector(
              onTap: () {
                captures.draftRow = DraftRow.caption;
                model.startEditing(TogetherCaptures.captionRow);
              },
              child: FocusRing(
                focused: captures.draftRow == DraftRow.caption && model.editingRow == null,
                radius: 12 * scale,
                child: RowTextField(
                  model: model,
                  row: together.captionField,
                  kind: together.captionField.kind as TextRow,
                  focused: false,
                ),
              ),
            ),
            SizedBox(height: 18 * scale),
            label(T.text('capturesVisibility')),
            SizedBox(height: 8 * scale),
            FocusRing(
              focused: captures.draftRow == DraftRow.visibility,
              radius: 28 * scale,
              child: Container(
                padding: EdgeInsets.all(5 * scale),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(28 * scale),
                ),
                child: Row(
                  children: [
                    for (final (visibility, icon, title) in [
                      (PostVisibility.friends, Icons.people_rounded, 'capturesVisibilityFriends'),
                      (PostVisibility.public, Icons.public_rounded, 'capturesVisibilityPublic'),
                    ])
                      Expanded(
                        child: Pressable(
                          onTap: () {
                            captures.draftRow = DraftRow.visibility;
                            together.setDraftVisibility(visibility);
                          },
                          builder: (context, _) => AnimatedContainer(
                            duration: Motion.focus,
                            curve: Motion.settle,
                            height: 42 * scale,
                            decoration: BoxDecoration(
                              color: draft.visibility == visibility ? Colors.white : Colors.transparent,
                              borderRadius: BorderRadius.circular(22 * scale),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  icon,
                                  size: 16 * scale,
                                  color: draft.visibility == visibility ? Colors.black : Colors.white70,
                                ),
                                SizedBox(width: 8 * scale),
                                Text(
                                  T.text(title),
                                  style: AppText.display(
                                    15 * scale,
                                    weight: FontWeight.w600,
                                    color: draft.visibility == visibility ? Colors.black : Colors.white70,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            SizedBox(height: 8 * scale),
            Text(
              T.text(
                draft.visibility == PostVisibility.public
                    ? 'capturesVisibilityPublicDetail'
                    : 'capturesVisibilityFriendsDetail',
              ),
              style: AppText.display(13 * scale, color: muted),
            ),
            SizedBox(height: 22 * scale),
            Opacity(
              opacity: together.canPostDraft || busy ? 1 : 0.45,
              child: ConsoleButton(
                title: T.text(switch (captures.stage) {
                  PostStage.uploading => 'capturesUploading',
                  PostStage.posting => 'capturesPosting',
                  PostStage.idle => 'capturesPost',
                }),
                icon: busy ? Icons.cloud_upload_rounded : Icons.send_rounded,
                focused: captures.draftRow == DraftRow.post,
                prominent: true,
                minWidth: 460 * scale,
                indeterminate: busy,
                progressColor: accent,
                onPressed: () {
                  captures.draftRow = DraftRow.post;
                  unawaited(together.postCapture());
                },
              ),
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
                  label: T.text(captures.draftRow == DraftRow.caption ? 'capturesHintType' : 'hintSelect'),
                  action: HintAction.select,
                ),
                Hint(keys: 'Esc', glyph: PadGlyph.circle, label: T.text('hintBack'), action: HintAction.back),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _size(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
