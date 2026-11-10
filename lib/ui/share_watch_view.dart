import 'package:flutter/material.dart';

import 'app_model.dart';
import 'components.dart';
import 'glass.dart';
import 'panels.dart';
import 'strings.dart';
import 'theme.dart';
import 'together_model.dart';

/// A friend's share play over everything, as the Mac's ShareWatchView: their game full screen
/// (letterboxed to 16:9), who and how it goes in a corner chip with a live dot, the seat the
/// host gave as a pad badge, and how to leave under it. Until the picture comes, the host's
/// picture over an indeterminate line.
class ShareWatchView extends StatelessWidget {
  const ShareWatchView({super.key, required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final share = model.sharePlay;
    final watching = share.watching;
    final host = watching?.host;
    final connected = share.watchConnected;
    final accent = model.accentChoice.color;
    final slot = share.watchSlot;
    final video = share.watchVideo();
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (video != null)
            AnimatedOpacity(
              duration: Motion.fade,
              opacity: connected ? 1 : 0,
              child: Center(
                child: AspectRatio(aspectRatio: 16 / 9, child: video),
              ),
            ),
          if (!connected)
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (host != null)
                    PersonAvatar(
                      person: PanelPerson(name: TogetherModel.shown(host).name, avatar: host.avatar),
                      size: 96 * scale,
                    ),
                  SizedBox(height: 22 * scale),
                  Text(
                    T.text('sharePlayConnecting'),
                    style: AppText.display(
                      20 * scale,
                      weight: FontWeight.w500,
                      color: Colors.white.withValues(alpha: 0.78),
                    ),
                  ),
                  SizedBox(height: 16 * scale),
                  SizedBox(
                    width: 180 * scale,
                    child: IndeterminateLine(color: accent, height: 3 * scale),
                  ),
                ],
              ),
            ),
          PositionedDirectional(
            start: 28 * scale,
            top: 28 * scale,
            child: _Chip(model: model, accent: accent),
          ),
          if (slot != null)
            PositionedDirectional(
              end: 28 * scale,
              top: 28 * scale,
              child: _SeatBadge(slot: slot, accent: accent),
            ),
          PositionedDirectional(
            start: 0,
            end: 0,
            bottom: 28 * scale,
            child: Center(
              child: Opacity(
                opacity: 0.72,
                child: Hint(
                  keys: slot == null ? 'Esc' : 'PS',
                  pad: slot == null ? 'PS' : null,
                  glyph: slot == null ? PadGlyph.circle : null,
                  label: T.text('sharePlayLeave'),
                  action: slot == null ? HintAction.back : null,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Who shares what, and how the link is: "Player 2 · 31 ms · 720p60".
class _Chip extends StatelessWidget {
  const _Chip({required this.model, required this.accent});

  final AppModel model;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final share = model.sharePlay;
    final watching = share.watching;
    final host = watching?.host;
    final name = host == null ? '' : TogetherModel.shown(host).name;
    final game = watching == null
        ? ''
        : model.games.where((game) => game.titleId == watching.titleId).firstOrNull?.name ??
              watching.title ??
              watching.titleId;
    final stats = share.watchStats;
    final parts = [
      if (share.watchSlot case final slot?) T.format('sharePlayPlayer', [slot]) else T.text('sharePlayOnlyWatches'),
      if (share.watchViaServer) T.text('mediaViaServer'),
      if (stats?.roundTripMs case final roundTrip?) T.format('sharePlayRoundTrip', [roundTrip.round()]),
      if ((stats?.framesPerSecond, stats?.height) case (final fps?, final height?)) '${height}p${fps.round()}',
    ];
    return Semantics(
      container: true,
      liveRegion: true,
      label: [game.isEmpty ? name : '$name, $game', ...parts].join(', '),
      excludeSemantics: true,
      child: IceSurface(
        radius: 22 * scale,
        opacity: 0.5,
        padding: EdgeInsetsDirectional.fromSTEB(10 * scale, 10 * scale, 18 * scale, 10 * scale),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            PersonAvatar(
              person: PanelPerson(name: name, avatar: host?.avatar, status: PersonStatus.playing),
              size: 36 * scale,
            ),
            SizedBox(width: 12 * scale),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _LiveDot(color: share.watchConnected ? const Color(0xFFFF4D5E) : Colors.white38, size: 8 * scale),
                    SizedBox(width: 8 * scale),
                    ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: 420 * scale),
                      child: Text(
                        game.isEmpty ? name : '$name · $game',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.display(15 * scale, weight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 3 * scale),
                Text(
                  parts.join(' · '),
                  style: AppText.display(13 * scale, color: Colors.white.withValues(alpha: 0.72)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The pad the host handed over, as a controller's player light would show it.
class _SeatBadge extends StatelessWidget {
  const _SeatBadge({required this.slot, required this.accent});

  final int slot;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return Semantics(
      container: true,
      label: T.format('sharePlayPlayer', [slot]),
      excludeSemantics: true,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 16 * scale, vertical: 10 * scale),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.22),
          borderRadius: BorderRadius.circular(22 * scale),
          border: Border.all(color: accent.withValues(alpha: 0.6), width: 1.5 * scale),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.sports_esports_rounded, size: 18 * scale, color: Colors.white),
            SizedBox(width: 10 * scale),
            // The player lights: the host's seat first, this one lit.
            for (var pad = 1; pad <= 4; pad++) ...[
              Container(
                width: 6 * scale,
                height: 14 * scale,
                decoration: BoxDecoration(
                  color: pad == slot ? Colors.white : Colors.white.withValues(alpha: 0.22),
                  borderRadius: BorderRadius.circular(3 * scale),
                ),
              ),
              SizedBox(width: 4 * scale),
            ],
            SizedBox(width: 6 * scale),
            Text(T.format('sharePlayPlayer', [slot]), style: AppText.display(14 * scale, weight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}

/// The live dot: it breathes while the picture comes, still with reduced motion.
class _LiveDot extends StatefulWidget {
  const _LiveDot({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  State<_LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<_LiveDot> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
    value: 1,
  );

  @override
  void initState() {
    super.initState();
    if (!Motion.reduced) _controller.repeat(reverse: true, min: 0.45, max: 1);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _controller,
    child: Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
    ),
  );
}
