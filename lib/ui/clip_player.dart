import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../core/libmpv.dart';
import 'components.dart';
import 'strings.dart';
import 'theme.dart';

/// Where a clip in the launcher's player is: playing or paused, how far in, how long it is, and
/// whether it could not be opened.
@immutable
class ClipState {
  const ClipState({
    this.playing = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.failed = false,
  });

  final bool playing;
  final Duration position;
  final Duration duration;

  /// The file or link could not be opened: the system's player gets it instead.
  final bool failed;

  /// Its length is known: the first frame is on its way.
  bool get ready => duration > Duration.zero;

  /// How far in, from 0 to 1.
  double get progress => ready ? (position.inMicroseconds / duration.inMicroseconds).clamp(0.0, 1.0).toDouble() : 0;

  ClipState copyWith({bool? playing, Duration? position, Duration? duration, bool? failed}) => ClipState(
    playing: playing ?? this.playing,
    position: position ?? this.position,
    duration: duration ?? this.duration,
    failed: failed ?? this.failed,
  );

  /// 0:07, 1:30.
  static String clock(Duration time) {
    final seconds = time.inSeconds;
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }
}

/// The shape a picture or clip is drawn in: its own, within reason, or 16:9 when it is not known.
double mediaAspect(int? width, int? height) =>
    width == null || height == null || width <= 0 || height <= 0 ? 16 / 9 : (width / height).clamp(0.5, 2.4).toDouble();

/// A chat's picture or clip over the whole screen (the macOS launcher's MediaViewer): a clip by
/// its link or the file it was opened to, a picture by its link or its bytes opened in memory.
@immutable
class ViewedMedia {
  const ViewedMedia.clip(String this.clip, {this.poster, this.posterBytes, this.aspect = 16 / 9})
    : link = null,
      bytes = null;

  const ViewedMedia.picture({this.link, this.bytes, this.aspect = 16 / 9})
    : clip = null,
      poster = null,
      posterBytes = null;

  /// What the player opens: a link or a file's path.
  final String? clip;

  /// The clip's picture until it plays: a link, or bytes.
  final String? poster;
  final Future<Uint8List>? posterBytes;

  /// The picture: a link, or bytes.
  final String? link;
  final Future<Uint8List>? bytes;

  final double aspect;

  bool get isClip => clip != null;
}

/// A clip playing inside the launcher, from the start and over again with its sound, as the
/// macOS launcher's ClipPlayer (AVPlayerLooper) does. LauncherServices.clipPlayback makes one; a
/// fake in tests.
abstract class ClipPlayback {
  ValueListenable<ClipState> get state;

  /// Opens [source] (a file's path or a link) and plays it from the start, looping.
  Future<void> open(String source);

  Future<void> playOrPause();

  Future<void> seek(Duration position);

  /// The picture, fitted inside the space it is given.
  Widget view(BuildContext context);

  Future<void> dispose();
}

/// The clip player on Windows and Linux: libmpv through media_kit. Windows has libmpv-2.dll beside
/// the launcher (media_kit_libs_windows_video), Linux uses the system's (SystemLibmpv). Throws
/// LibmpvMissing when Linux has none, anything else when libmpv cannot be loaded.
class MediaKitClipPlayback implements ClipPlayback {
  MediaKitClipPlayback() {
    if (SystemLibmpv.missing) throw SystemLibmpv.missingError();
    MediaKit.ensureInitialized(libmpv: loadedLibmpv());
    _player = Player(configuration: const PlayerConfiguration(title: 'AnyPS5'));
    _video = VideoController(_player);
    final stream = _player.stream;
    _subscriptions.addAll([
      stream.playing.listen((playing) => _state.value = _state.value.copyWith(playing: playing)),
      stream.position.listen((position) => _state.value = _state.value.copyWith(position: position)),
      stream.duration.listen((duration) {
        _state.value = _state.value.copyWith(duration: duration);
        if (duration > Duration.zero) _grace?.cancel();
      }),
      stream.error.listen((_) => _complain()),
    ]);
  }

  /// The libmpv the process has loaded already, if any (Linux): media_kit has to open that same
  /// one, not another version the system also has. The plugin's libanyps5_mpv.so uses the one
  /// loaded first too (linux/mpv_shim).
  static String? loadedLibmpv({String maps = '/proc/self/maps'}) {
    if (!Platform.isLinux) return null;
    try {
      return libmpvIn(File(maps).readAsLinesSync());
    } on FileSystemException {
      return null;
    }
  }

  /// The path of the libmpv in /proc/self/maps' [lines], or null.
  static String? libmpvIn(Iterable<String> lines) {
    for (final line in lines) {
      final at = line.indexOf('/');
      if (at < 0) continue;
      final path = line.substring(at).trim();
      final name = path.split('/').last;
      if (name.startsWith('libmpv.so')) return path;
    }
    return null;
  }

  late final Player _player;
  late final VideoController _video;
  final _state = ValueNotifier(const ClipState());
  final List<StreamSubscription<Object?>> _subscriptions = [];
  Timer? _grace;

  /// An error before the clip's length is known: a decoder that gave up for another one says
  /// so too, so it fails only when the clip has not started a moment later.
  void _complain() {
    if (_state.value.ready || _grace != null) return;
    _grace = Timer(const Duration(seconds: 2), () {
      if (!_state.value.ready) _state.value = _state.value.copyWith(failed: true);
    });
  }

  @override
  ValueListenable<ClipState> get state => _state;

  @override
  Future<void> open(String source) async {
    _grace?.cancel();
    _grace = null;
    _state.value = const ClipState();
    try {
      await _player.setPlaylistMode(PlaylistMode.single);
      await _player.open(Media(source));
    } on Object {
      _state.value = _state.value.copyWith(failed: true);
    }
  }

  @override
  Future<void> playOrPause() => _player.playOrPause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Widget view(BuildContext context) => Video(controller: _video, controls: null, fill: Colors.transparent);

  @override
  Future<void> dispose() async {
    _grace?.cancel();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _player.dispose();
    _state.dispose();
  }
}

/// A clip playing in the launcher: [poster] until its first moment, then the clip, looping, with
/// a bar to pause it and move through it when the pointer is over it (the macOS launcher's
/// floating controls). Without a player ([create] null) the poster stays; when the clip cannot be
/// opened, [onFailed] gets it once (the system's player then). On Linux without libmpv the
/// poster stays under LibmpvNotice, which says how to install it and hands the clip to
/// [onFailed] only when asked.
class ClipPlayerView extends StatefulWidget {
  const ClipPlayerView({
    super.key,
    required this.source,
    required this.create,
    required this.onFailed,
    required this.accent,
    this.poster,
  });

  final String source;
  final ClipPlayback Function()? create;
  final void Function(String source) onFailed;
  final Color accent;
  final Widget? poster;

  @override
  State<ClipPlayerView> createState() => _ClipPlayerViewState();
}

class _ClipPlayerViewState extends State<ClipPlayerView> {
  ClipPlayback? _playback;
  LibmpvMissing? _missing;
  String? _failed;
  bool _hovering = false;
  Timer? _idle;

  @override
  void initState() {
    super.initState();
    final create = widget.create;
    if (create == null) return;
    try {
      _playback = create()..state.addListener(_changed);
    } on LibmpvMissing catch (missing) {
      _missing = missing;
      return;
    } on Object {
      _fail();
      return;
    }
    // After this frame: a player that says where it is at once does not rebuild during it.
    scheduleMicrotask(() {
      if (mounted) unawaited(_playback?.open(widget.source));
    });
  }

  @override
  void didUpdateWidget(ClipPlayerView old) {
    super.didUpdateWidget(old);
    if (old.source != widget.source && _playback != null) {
      _failed = null;
      unawaited(_playback!.open(widget.source));
    }
  }

  void _changed() {
    if (!mounted) return;
    if (_playback?.state.value.failed == true) _fail();
    setState(() {});
  }

  /// Once for each clip, after this frame: the system's player gets it.
  void _fail() {
    final source = widget.source;
    if (_failed == source) return;
    _failed = source;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.source == source) widget.onFailed(source);
    });
  }

  /// The pointer moved: the bar shows, and goes again after a moment of stillness.
  void _woke() {
    _idle?.cancel();
    if (!_hovering) setState(() => _hovering = true);
    _idle = Timer(const Duration(milliseconds: 2200), () {
      if (mounted) setState(() => _hovering = false);
    });
  }

  @override
  void dispose() {
    _idle?.cancel();
    final playback = _playback;
    if (playback != null) {
      playback.state.removeListener(_changed);
      unawaited(playback.dispose());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final playback = _playback;
    final state = playback?.state.value ?? const ClipState();
    final reduced = MediaQuery.disableAnimationsOf(context) || Motion.reduced;
    final showBar = playback != null && state.ready && !state.failed && (_hovering || !state.playing);
    final poster = widget.poster;
    final missing = _missing;
    if (missing != null) {
      return Stack(
        fit: StackFit.expand,
        children: [
          ?poster,
          LibmpvNotice(missing: missing, accent: widget.accent, onElsewhere: () => widget.onFailed(widget.source)),
        ],
      );
    }
    return MouseRegion(
      onHover: (_) => _woke(),
      onExit: (_) {
        _idle?.cancel();
        setState(() => _hovering = false);
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (poster != null && (playback == null || !state.ready || state.failed)) poster,
          if (playback != null && !state.failed) playback.view(context),
          // How far in, a thin line along the bottom while the bar is away.
          if (playback != null && state.ready && !state.failed)
            PositionedDirectional(
              start: 0,
              end: 0,
              bottom: 0,
              child: AnimatedOpacity(
                opacity: showBar ? 0 : 1,
                duration: reduced ? Duration.zero : Motion.fade,
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: FractionallySizedBox(
                    widthFactor: state.progress,
                    child: Container(height: 3 * scale, color: widget.accent),
                  ),
                ),
              ),
            ),
          if (playback != null)
            PositionedDirectional(
              start: 18 * scale,
              end: 18 * scale,
              bottom: 16 * scale,
              child: IgnorePointer(
                ignoring: !showBar,
                child: AnimatedOpacity(
                  opacity: showBar ? 1 : 0,
                  duration: reduced ? Duration.zero : Motion.fade,
                  curve: Motion.settle,
                  child: AnimatedSlide(
                    offset: showBar || reduced ? Offset.zero : const Offset(0, 0.25),
                    duration: reduced ? Duration.zero : Motion.overlay,
                    curve: Motion.settle,
                    child: _ClipBar(playback: playback, state: state, accent: widget.accent),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Over a clip's picture when Linux has no libmpv: what is missing, the command that installs it
/// on this distribution (one per family when it is not known), to copy, and the clip in another
/// player. It rises into place as the launcher's cards do, and only fades with reduced motion.
class LibmpvNotice extends StatelessWidget {
  const LibmpvNotice({super.key, required this.missing, required this.accent, required this.onElsewhere});

  final LibmpvMissing missing;
  final Color accent;
  final VoidCallback onElsewhere;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final reduced = MediaQuery.disableAnimationsOf(context) || Motion.reduced;
    final card = ConstrainedBox(
      constraints: BoxConstraints(maxWidth: 560 * scale),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(T.text('libmpvMissingTitle'), style: AppText.display(30 * scale, weight: FontWeight.w700, height: 1.08)),
          SizedBox(height: 10 * scale),
          Text(
            T.text('libmpvMissingText'),
            style: AppText.display(15 * scale, color: Colors.white.withValues(alpha: 0.78), height: 1.45),
          ),
          SizedBox(height: 18 * scale),
          for (final command in missing.commands) ...[
            _CommandLine(command: command, accent: accent),
            SizedBox(height: 8 * scale),
          ],
          SizedBox(height: 10 * scale),
          Pressable(
            key: const ValueKey('libmpv-elsewhere'),
            onTap: onElsewhere,
            builder: (context, hovering) => AnimatedContainer(
              duration: Motion.focus,
              curve: Motion.settle,
              padding: EdgeInsets.symmetric(horizontal: 22 * scale, vertical: 12 * scale),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: hovering ? 1 : 0.92),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.open_in_new_rounded, size: 18 * scale, color: Colors.black),
                  SizedBox(width: 8 * scale),
                  Text(
                    T.text('libmpvOpenElsewhere'),
                    style: AppText.display(15 * scale, weight: FontWeight.w600, color: Colors.black),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
    return DecoratedBox(
      key: const ValueKey('libmpv-missing'),
      // The picture stays readable at the top, the words sit on the dark below it.
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black.withValues(alpha: 0.45), Colors.black.withValues(alpha: 0.82)],
        ),
      ),
      child: Padding(
        padding: EdgeInsets.all(28 * scale),
        child: Align(
          alignment: AlignmentDirectional.bottomStart,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.bottomStart,
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: Motion.overlay,
              curve: Motion.settle,
              builder: (context, shown, child) => Opacity(
                opacity: shown,
                child: Transform.translate(offset: Offset(0, reduced ? 0 : (1 - shown) * 14 * scale), child: child),
              ),
              child: card,
            ),
          ),
        ),
      ),
    );
  }
}

/// One install command as a terminal prints it, with a button that copies it.
class _CommandLine extends StatefulWidget {
  const _CommandLine({required this.command, required this.accent});

  final String command;
  final Color accent;

  @override
  State<_CommandLine> createState() => _CommandLineState();
}

class _CommandLineState extends State<_CommandLine> {
  bool _copied = false;
  Timer? _reset;

  void _copy() {
    unawaited(Clipboard.setData(ClipboardData(text: widget.command)).catchError((Object _) {}));
    _reset?.cancel();
    setState(() => _copied = true);
    _reset = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final mono = TextStyle(
      fontFamily: 'NotoSansMono',
      fontFamilyFallback: const ['monospace'],
      fontSize: 15 * scale,
      height: 1.3,
      color: Colors.white,
    );
    return Container(
      padding: EdgeInsets.fromLTRB(16 * scale, 6 * scale, 6 * scale, 6 * scale),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12 * scale),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      // A command reads left to right in every language, as a terminal prints it.
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              r'$ ',
              style: mono.copyWith(color: widget.accent, fontWeight: FontWeight.w700),
            ),
            // A command reads left to right in every language.
            Text(widget.command, style: mono),
            SizedBox(width: 14 * scale),
            Semantics(
              button: true,
              label: T.text('libmpvCopy'),
              child: Pressable(
                key: ValueKey('libmpv-copy-${widget.command}'),
                onTap: _copy,
                builder: (context, hovering) => AnimatedContainer(
                  duration: Motion.focus,
                  curve: Motion.settle,
                  width: 34 * scale,
                  height: 34 * scale,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: hovering ? 0.18 : 0.08),
                  ),
                  child: Icon(
                    _copied ? Icons.check_rounded : Icons.content_copy_rounded,
                    size: 16 * scale,
                    color: _copied ? widget.accent : Colors.white.withValues(alpha: 0.85),
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

/// The bar over a clip: play or pause, a track to click or drag through, and the time.
class _ClipBar extends StatelessWidget {
  const _ClipBar({required this.playback, required this.state, required this.accent});

  final ClipPlayback playback;
  final ClipState state;
  final Color accent;

  void _seekTo(double localX, double width) {
    if (width <= 0 || !state.ready) return;
    final fraction = (localX / width).clamp(0.0, 1.0);
    unawaited(playback.seek(state.duration * fraction));
  }

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return Container(
      key: const ValueKey('clip-bar'),
      padding: EdgeInsetsDirectional.fromSTEB(8 * scale, 8 * scale, 18 * scale, 8 * scale),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Row(
        children: [
          Semantics(
            button: true,
            label: T.text(state.playing ? 'clipPause' : 'clipPlay'),
            child: Pressable(
              key: const ValueKey('clip-play'),
              onTap: () => unawaited(playback.playOrPause()),
              builder: (context, hovering) => AnimatedContainer(
                duration: Motion.focus,
                curve: Motion.settle,
                width: 38 * scale,
                height: 38 * scale,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withValues(alpha: hovering ? 1 : 0.92),
                ),
                child: Icon(
                  state.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  size: 24 * scale,
                  color: Colors.black,
                ),
              ),
            ),
          ),
          SizedBox(width: 14 * scale),
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) {
                double along(Offset local) => rtl ? box.maxWidth - local.dx : local.dx;
                return MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    key: const ValueKey('clip-track'),
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (details) => _seekTo(along(details.localPosition), box.maxWidth),
                    onHorizontalDragUpdate: (details) => _seekTo(along(details.localPosition), box.maxWidth),
                    child: SizedBox(
                      height: 24 * scale,
                      child: Stack(
                        alignment: AlignmentDirectional.centerStart,
                        children: [
                          Container(
                            height: 4 * scale,
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.22),
                              borderRadius: BorderRadius.circular(2 * scale),
                            ),
                          ),
                          FractionallySizedBox(
                            widthFactor: state.progress,
                            child: Container(
                              height: 4 * scale,
                              decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(2 * scale)),
                            ),
                          ),
                          PositionedDirectional(
                            start: (box.maxWidth * state.progress - 6 * scale)
                                .clamp(0.0, (box.maxWidth - 12 * scale).clamp(0.0, double.infinity))
                                .toDouble(),
                            child: Container(
                              width: 12 * scale,
                              height: 12 * scale,
                              decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.white),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          SizedBox(width: 14 * scale),
          Text(
            '${ClipState.clock(state.position)} / ${ClipState.clock(state.duration)}',
            style: AppText.display(13 * scale, weight: FontWeight.w600, color: Colors.white.withValues(alpha: 0.85)),
          ),
        ],
      ),
    );
  }
}
