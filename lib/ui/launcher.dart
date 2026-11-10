import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../core/gamepad/feel.dart';
import '../core/gamepad/shortcuts.dart';
import '../core/together/levels.dart';
import 'app_model.dart';
import 'theme_studio_view.dart';
import 'browser_play.dart';
import 'calls_view.dart';
import 'captures_view.dart';
import 'challenge_view.dart';
import 'compare_view.dart';
import 'components.dart';
import 'confirm_card.dart';
import 'controller_test_view.dart';
import 'crash_report_view.dart';
import 'drag_pan.dart';
import 'feed_view.dart';
import 'frame_log.dart';
import 'glass.dart';
import 'home.dart';
import 'leaderboard_view.dart';
import 'share_watch_view.dart';
import 'level_badge.dart';
import 'messages_view.dart';
import 'picture_crop_view.dart';
import 'profile_view.dart';
import 'onboarding.dart';
import 'embedded_retro_view.dart';
import 'panels.dart';
import 'profiles_view.dart';
import 'strings.dart';
import 'theme.dart';
import 'together_model.dart';
import 'window_buttons.dart';

/// The launcher's whole screen: the backdrop, the home screen or the first-start steps, and the
/// layers over them. Keys move through it as a pad would.
class LauncherShell extends StatefulWidget {
  const LauncherShell({super.key, required this.model, this.time, this.now});

  final AppModel model;

  /// A fixed moment of the background animation and clock, for previews and golden tests.
  final double? time;
  final DateTime? now;

  @override
  State<LauncherShell> createState() => _LauncherShellState();
}

class _LauncherShellState extends State<LauncherShell> {
  final FocusNode _focus = FocusNode(debugLabel: 'launcher');

  /// A held arrow key repeats on the same pace as a held direction on a controller (the
  /// system's own key repeats are dropped).
  late final HoldRepeater<Command> _keys = HoldRepeater<Command>((command) {
    final model = widget.model;
    // Keys reach only the window in front; a held arrow's repeat stops as soon as the launcher
    // is not (its key-up went to the window that took over).
    if (model.editingRow != null || model.capturing != null || !model.launcherInFront) return _keys.stop();
    model.command(command, repeat: true);
  });

  /// The window in front or behind another: the theme song plays only in front.
  late final AppLifecycleListener _lifecycle;

  /// Glass's blur given up when the GPU cannot keep up with it.
  late final RasterWatch _raster = RasterWatch(onSlow: () => widget.model.glassTooSlow());

  /// Whether the launcher is in front, looked at a few times a second (AppModel.checkFront).
  late final Timer _frontWatch;

  /// ANYPS5_FRAME_LOG: the frames drawn each second and how long they took.
  late final FrameLog? _frameLog = FrameLog.forPath(
    (widget.model.services.environment ?? Platform.environment)['ANYPS5_FRAME_LOG'],
    describe: _onScreen,
  );

  /// The same lines kept in memory (the newest 30): what a report of the launcher's own crash or
  /// stall says of its last seconds.
  late final FrameLog _recent = FrameLog(widget.model.addRecentLine, describe: _onScreen);

  String _onScreen() {
    final model = widget.model;
    return 'look ${model.look.name}${model.solidGlass ? ' solid' : ''}'
        '${model.glassWindow.seeThrough ? ' see-through' : ''} layer ${model.overlay?.name ?? 'home'}'
        '${model.running != null ? ' game running' : ''} ${model.active ? 'in front' : 'behind'}'
        '${model.windowFullscreen ? ' full screen' : ''} ${ProcessInfo.currentRss >> 20} MB';
  }

  void _timings(List<FrameTiming> timings) {
    final model = widget.model;
    for (final timing in timings) {
      _frameLog?.add(timing.buildDuration, timing.rasterDuration);
      _recent.add(timing.buildDuration, timing.rasterDuration);
    }
    // Only Glass's own frames count: not while a game shares the GPU, nor once it is solid.
    if (model.look != LookStyle.glass || model.solidGlass || model.running != null || model.resting) {
      _raster.reset();
      return;
    }
    _raster.add([for (final timing in timings) timing.rasterDuration]);
  }

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_timings);
    _frameLog?.start();
    _recent.start();
    _frontWatch = Timer.periodic(const Duration(milliseconds: 400), (_) => widget.model.checkFront());
    widget.model.addListener(_modelChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.model.applyBackdrop());
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        // A key let go in another window never says so here.
        if (state != AppLifecycleState.resumed) _keys.stop();
        widget.model.setActive(state == AppLifecycleState.resumed);
      },
    );
  }

  @override
  void didUpdateWidget(LauncherShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.model != widget.model) {
      oldWidget.model.removeListener(_modelChanged);
      widget.model.addListener(_modelChanged);
    }
  }

  /// The language the screen was last drawn in.
  String _drawnLanguage = T.language.code;

  /// Out of a text field: the keys come back to the launcher. Glass's window follows the look.
  /// Another language redraws every widget.
  void _modelChanged() {
    if (T.language.code != _drawnLanguage) {
      _drawnLanguage = T.language.code;
      _redrawAll();
    }
    widget.model.applyBackdrop();
    if (widget.model.editingRow == null && !_focus.hasPrimaryFocus && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.model.editingRow == null && !_focus.hasPrimaryFocus) _focus.requestFocus();
      });
    }
  }

  /// Builds every widget below again. A const widget (the hint bar, a title) is skipped when its
  /// parent rebuilds, so its texts would stay in the old language until the next start.
  void _redrawAll() {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _redrawAll());
      return;
    }
    void mark(Element element) {
      element.markNeedsBuild();
      element.visitChildren(mark);
    }

    (context as Element).visitChildren(mark);
  }

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_timings);
    _frameLog?.stop();
    _recent.stop();
    _frontWatch.cancel();
    widget.model.removeListener(_modelChanged);
    _keys.stop();
    _lifecycle.dispose();
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    final model = widget.model;
    final game = model.embeddedGame;
    if (game != null && model.overlay == null) {
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        if (event is KeyDownEvent) unawaited(model.openQuickMenu());
        return KeyEventResult.handled;
      }
      final button = embeddedRetroKeys[event.logicalKey];
      if (button != null) {
        if (event is KeyDownEvent || event is KeyUpEvent) game.key(button, event is KeyDownEvent);
        return KeyEventResult.handled;
      }
      if (event.logicalKey != LogicalKeyboardKey.f11) return KeyEventResult.ignored;
    }
    // A keyboard's Back and Forward keys (and mouse drivers that send them for the side
    // buttons) are the mouse's side buttons.
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.browserBack) {
      model.mouseBack();
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.browserForward) {
      model.mouseForward();
      return KeyEventResult.handled;
    }
    // Typing in a field: the keys are the field's, Esc gives them back.
    if (model.editingRow != null) {
      if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
        model.stopEditing();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    final together = model.together;
    // The talk key, where the desktop cannot be read: only while the launcher has the keyboard.
    if (event is! KeyRepeatEvent &&
        together.talkKeyInWindow(event.physicalKey.usbHidUsage, down: event is KeyDownEvent)) {
      return KeyEventResult.handled;
    }
    if (event is KeyUpEvent) {
      if (_keys.heldBy == event.logicalKey) _keys.stop();
      return KeyEventResult.ignored;
    }
    if (together.capturingTalkKey && event is KeyDownEvent) {
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        together.capturingTalkKey = false;
        model.refresh();
      } else {
        together.chooseTalkKey(event.physicalKey.usbHidUsage);
      }
      return KeyEventResult.handled;
    }
    // Settings › Shortcuts waits for a key: the next one (with its modifiers) is the binding.
    if (model.shortcutCapture != null) {
      if (event is KeyDownEvent && !_modifiers.contains(event.logicalKey)) {
        model.captureShortcutKey(_combo(event.logicalKey));
      }
      return KeyEventResult.handled;
    }
    if (model.capturing != null && event is KeyDownEvent) {
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        model.handle(Command.back);
        return KeyEventResult.handled;
      }
      return model.captureKey(event.physicalKey.usbHidUsage) ? KeyEventResult.handled : KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final repeat = event is KeyRepeatEvent;
    // The shortcuts the user can change (F11, Q and E by default) come before the fixed keys.
    if (event is KeyDownEvent && !_modifiers.contains(key)) {
      if (model.shortcutForKey(_combo(key)) case final LauncherAction action) {
        model.runKeyShortcut(action);
        return KeyEventResult.handled;
      }
      // △'s key on a shortcut row clears it; Delete does too.
      if (key == LogicalKeyboardKey.delete && model.focusedShortcut != null) {
        model.usedKeyboard();
        model.clearShortcut(model.focusedShortcut!);
        return KeyEventResult.handled;
      }
    }
    // Ctrl+F: Settings' search, from Settings or the home screen.
    if (event is KeyDownEvent &&
        key == LogicalKeyboardKey.keyF &&
        HardwareKeyboard.instance.isControlPressed &&
        (model.overlay == Layer.settings || model.overlay == null)) {
      model.usedKeyboard();
      model.startSettingsSearch();
      return KeyEventResult.handled;
    }
    Command? command;
    if (key == LogicalKeyboardKey.arrowLeft) command = Command.left;
    if (key == LogicalKeyboardKey.arrowRight) command = Command.right;
    if (key == LogicalKeyboardKey.arrowUp) command = Command.up;
    if (key == LogicalKeyboardKey.arrowDown) command = Command.down;
    if (command != null) {
      // The launcher's own repeat paces a held arrow.
      if (repeat) return KeyEventResult.handled;
      model.usedKeyboard();
      model.command(command);
      _keys.holdQuietly(command, by: key);
      return KeyEventResult.handled;
    }
    // Escape on the home screen asks Quit AnyPS5? rather than doing nothing.
    if (!repeat && key == LogicalKeyboardKey.escape && model.askQuit()) {
      model.usedKeyboard();
      return KeyEventResult.handled;
    }
    if (!repeat) {
      if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter || key == LogicalKeyboardKey.space) {
        command = Command.select;
      }
      if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.backspace) command = Command.back;
      if (key == LogicalKeyboardKey.keyO) command = Command.options;
    }
    if (command == null) return KeyEventResult.ignored;
    model.usedKeyboard();
    model.command(command);
    return KeyEventResult.handled;
  }

  static final Set<LogicalKeyboardKey> _modifiers = {
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.altLeft,
    LogicalKeyboardKey.altRight,
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.shiftRight,
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.metaRight,
    LogicalKeyboardKey.control,
    LogicalKeyboardKey.alt,
    LogicalKeyboardKey.shift,
    LogicalKeyboardKey.meta,
  };

  /// [key] with the modifiers held now.
  static KeyCombo _combo(LogicalKeyboardKey key) {
    final keyboard = HardwareKeyboard.instance;
    return KeyCombo(
      key.keyId,
      control: keyboard.isControlPressed,
      alt: keyboard.isAltPressed,
      shift: keyboard.isShiftPressed,
    );
  }

  /// A hint pill clicked: what its key does.
  void _hint(HintAction action) {
    final model = widget.model;
    if (action == HintAction.previousGame || action == HintAction.nextGame) {
      final delta = action == HintAction.nextGame ? 1 : -1;
      if (model.overlay == Layer.settings) return model.moveCategory(delta);
    }
    model.handle(switch (action) {
      HintAction.previousGame => Command.previousGame,
      HintAction.nextGame => Command.nextGame,
      HintAction.select => Command.select,
      HintAction.back => Command.back,
      HintAction.options => Command.options,
    });
  }

  double _wheel = 0;

  /// The right button is Back everywhere (as Esc is); on the home screen the wheel moves
  /// between games, in lists it scrolls them. The side buttons are Back (Circle) and Forward.
  void _pointerDown(PointerDownEvent event) {
    final model = widget.model;
    model.usedKeyboard();
    if (event.kind == PointerDeviceKind.mouse && event.buttons & kBackMouseButton != 0) return model.mouseBack();
    if (event.kind == PointerDeviceKind.mouse && event.buttons & kForwardMouseButton != 0) return model.mouseForward();
    if (event.kind != PointerDeviceKind.mouse || event.buttons & kSecondaryMouseButton == 0) return;
    if (model.editingRow != null || model.capturing != null) return;
    // On Home the right button opens the Options menu (Switch Profile, online or offline).
    if (model.homeRightClick()) return;
    if (model.overlay == null && model.focus.isTiles && model.pairing == null) return;
    model.handle(Command.back);
  }

  void _pointerSignal(PointerSignalEvent event) {
    final model = widget.model;
    if (event is! PointerScrollEvent || model.overlay != null || !model.preferences.onboarded) return;
    final delta = event.scrollDelta.dy.abs() > event.scrollDelta.dx.abs() ? event.scrollDelta.dy : event.scrollDelta.dx;
    _wheel += delta;
    if (_wheel.abs() < 40) return;
    model.handle(_wheel > 0 ? Command.nextGame : Command.previousGame);
    _wheel = 0;
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _key,
      child: Listener(
        onPointerDown: _pointerDown,
        // The mouse moving is the mouse in use: the keys' hints come back.
        onPointerHover: (event) {
          if (event.kind == PointerDeviceKind.mouse) widget.model.usedPointer();
        },
        onPointerSignal: _pointerSignal,
        // Lists pan with a mouse drag (and the wheel, as before); while one is dragged or
        // gliding, the rows passing under the pointer make no hover tick.
        child: ScrollConfiguration(
          behavior: const LauncherScrollBehavior(),
          child: PanScope(
            onPanning: (panning) => model.panning = panning,
            child: HoverTicks(
              onArrive: (id, event) =>
                  model.hoverArrived(id, x: event.position.dx, y: event.position.dy, buttonsDown: event.buttons != 0),
              onLeave: model.hoverLeft,
              child: HintScope(
                onAction: _hint,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final scale = math.min(constraints.maxWidth / 1600, constraints.maxHeight / 900);
                    return LayoutScale(
                      scale: scale,
                      child: ListenableBuilder(
                        listenable: model,
                        // Behind a game or any other window the launcher rests: every animation
                        // stops and no frame is drawn, the GPU left to what is in front.
                        // Arabic and Urdu: every screen mirrored, as on the Mac.
                        builder: (context, _) => Directionality(
                          textDirection: T.language.isRightToLeft ? TextDirection.rtl : TextDirection.ltr,
                          child: InputScope(
                            mode: model.inputMode,
                            previousKey: AppModel.keyLabel(
                              model.preferences.shortcuts[LauncherAction.previousSection].key,
                            ),
                            nextKey: AppModel.keyLabel(model.preferences.shortcuts[LauncherAction.nextSection].key),
                            previousPad: AppModel.padLabel(
                              model.preferences.shortcuts[LauncherAction.previousSection].pad,
                            ),
                            nextPad: AppModel.padLabel(model.preferences.shortcuts[LauncherAction.nextSection].pad),
                            child: TickerMode(
                              enabled: !model.resting,
                              child: PointerFocus(
                                value: model.pointerFocus,
                                child: LookScope(
                                  glass: model.look == LookStyle.glass,
                                  solid: model.solidGlass,
                                  seeThrough: model.glassWindow.seeThrough,
                                  child: _WindowBase(
                                    window: model.glassWindow,
                                    deep: model.palette.deep,
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        if (model.embeddedGame case final game?)
                                          EmbeddedRetroView(game: game)
                                        else ...[
                                          Backdrop(model: model, time: widget.time),
                                          RepaintBoundary(
                                            // Glass's see-through window: under a layer the home screen
                                            // fades out, the layer a pane over the desktop (LayerScrim).
                                            child: AnimatedOpacity(
                                              opacity: model.glassWindow.seeThrough && model.overlay != null ? 0 : 1,
                                              duration: Motion.overlay,
                                              curve: Motion.settle,
                                              child: AnimatedSwitcher(
                                                layoutBuilder: uniqueSwitcherLayout(),
                                                duration: Motion.fade,
                                                switchInCurve: Motion.settle,
                                                child: model.preferences.onboarded
                                                    ? HomeView(
                                                        key: const ValueKey('home'),
                                                        model: model,
                                                        now: widget.now,
                                                      )
                                                    : OnboardingView(
                                                        key: const ValueKey('onboarding'),
                                                        model: model,
                                                        time: widget.time,
                                                      ),
                                              ),
                                            ),
                                          ),
                                        ],
                                        if (model.starting?.retro != null && model.overlay == null)
                                          _StartingCard(model: model),
                                        RepaintBoundary(
                                          child: AnimatedSwitcher(
                                            layoutBuilder: uniqueSwitcherLayout(),
                                            duration: Motion.overlay,
                                            reverseDuration: Motion.overlay,
                                            switchInCurve: Motion.settle,
                                            switchOutCurve: Curves.easeIn,
                                            transitionBuilder: (child, animation) => FadeTransition(
                                              opacity: animation,
                                              child: ScaleTransition(
                                                scale: Tween(begin: 0.985, end: 1.0).animate(animation),
                                                child: child,
                                              ),
                                            ),
                                            child: KeyedSubtree(
                                              key: ValueKey(model.overlay),
                                              child: switch (model.overlay) {
                                                Layer.library => LibraryGrid(model: model),
                                                Layer.log => LogView(model: model),
                                                Layer.crashReport => CrashReportView(model: model),
                                                Layer.controllerTest => ControllerTestView(model: model),
                                                Layer.browserPlay => BrowserPlayView(model: model),
                                                Layer.cropPicture => PictureCropView(model: model),
                                                Layer.trophies => TrophyView(model: model),
                                                Layer.gallery => GalleryWithShare(model: model),
                                                Layer.profilePicker => ProfilePickerView(model: model),
                                                Layer.addProfile => AddProfileView(model: model),
                                                Layer.themeStudio => ThemeStudioView(model: model),
                                                Layer.themes => ThemesView(model: model),
                                                Layer.messages => WithBackPill(
                                                  onBack: () => model.handle(Command.back),
                                                  titleLine: (side: 80, top: 60),
                                                  child: MessagesView(model: model),
                                                ),
                                                Layer.profile => WithBackPill(
                                                  onBack: () => model.handle(Command.back),
                                                  child: ProfileView(model: model),
                                                ),
                                                Layer.compare => WithBackPill(
                                                  onBack: () => model.handle(Command.back),
                                                  child: CompareView(model: model),
                                                ),
                                                Layer.captures => WithBackPill(
                                                  onBack: () => model.handle(Command.back),
                                                  child: CapturesView(model: model),
                                                ),
                                                Layer.feed => WithBackPill(
                                                  onBack: () => model.handle(Command.back),
                                                  child: FeedView(model: model),
                                                ),
                                                Layer.shareWatch => ShareWatchView(model: model),
                                                Layer.leaderboard => WithBackPill(
                                                  onBack: () => model.handle(Command.back),
                                                  child: LeaderboardView(model: model),
                                                ),
                                                // A plain yes or no: Quit AnyPS5?, Close the game?
                                                Layer.confirmQuit || Layer.closeGame => ConfirmCard(model: model),
                                                Layer.challenge => WithBackPill(
                                                  onBack: () => model.handle(Command.back),
                                                  child: ChallengeDetailView(model: model),
                                                ),
                                                null => const SizedBox.shrink(),
                                                _ => PanelView(model: model),
                                              },
                                            ),
                                          ),
                                        ),

                                        if (model.starting != null && model.starting!.retro == null)
                                          _StartingCard(model: model),
                                        if (model.together.ringing != null && model.pairing == null)
                                          RingingCard(model: model),
                                        if (model.pairing != null) PairingCard(model: model),
                                        _Toast(
                                          message: model.toast,
                                          level: model.toastLevel,
                                          icon: model.toastIcon,
                                          onTap: model.toastTap,
                                        ),
                                        if (model.showsWindowButtons)
                                          WindowButtons(
                                            accent: model.accentChoice.color,
                                            onMinimize: model.minimizeLauncher,
                                            onWindowed: () => unawaited(model.setLauncherFullscreen(false)),
                                            onQuit: model.quitLauncher,
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Under everything: the look's deep color, or in Glass's see-through window the tint over the
/// desktop the system shows behind it.
class _WindowBase extends StatelessWidget {
  const _WindowBase({required this.window, required this.deep, required this.child});

  final GlassWindow window;
  final Color deep;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!window.seeThrough) return ColoredBox(color: deep, child: child);
    return CustomPaint(painter: GlassTintPainter(window.tint), child: child);
  }
}

class _StartingCard extends StatelessWidget {
  const _StartingCard({required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final game = model.starting!;
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.6),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (game.icon != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(24 * scale),
                child: SizedBox.square(
                  dimension: 160 * scale,
                  child: ArtworkImage(path: game.icon!, cacheWidth: 400),
                ),
              ),
            SizedBox(height: 28 * scale),
            Text(game.name, style: AppText.display(36 * scale, weight: FontWeight.w300)),
            SizedBox(height: 12 * scale),
            SizedBox(
              width: 520 * scale,
              child: Text(
                T.text('startingText'),
                textAlign: TextAlign.center,
                style: AppText.display(16 * scale, color: Colors.white.withValues(alpha: 0.65), height: 1.4),
              ),
            ),
            SizedBox(height: 24 * scale),
            SizedBox(
              width: 260 * scale,
              child: IndeterminateLine(color: model.accentChoice.color),
            ),
          ],
        ),
      ),
    );
  }
}

class _Toast extends StatelessWidget {
  const _Toast({required this.message, this.level, this.icon, this.onTap});

  final String? message;

  /// A toast that goes somewhere (a message: its conversation) takes a click; others let the
  /// pointer through.
  final VoidCallback? onTap;

  /// A game's icon before the words (a new game).
  final String? icon;

  /// A trophy level reached: its badge before the words, the toast a little larger.
  final LevelBadge? level;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return PositionedDirectional(
      start: 0,
      end: 0,
      bottom: 92 * scale,
      child: IgnorePointer(
        ignoring: onTap == null,
        child: Center(
          child: _tappable(
            AnimatedSwitcher(
              layoutBuilder: uniqueSwitcherLayout(),
              duration: Motion.overlay,
              switchInCurve: Motion.settle,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween(begin: const Offset(0, 0.3), end: Offset.zero).animate(animation),
                  child: child,
                ),
              ),
              child: message == null
                  ? const SizedBox.shrink()
                  : level != null
                  ? Glass(
                      key: ValueKey(message),
                      radius: 34 * scale,
                      opacity: 0.66,
                      padding: EdgeInsetsDirectional.fromSTEB(12 * scale, 10 * scale, 28 * scale, 10 * scale),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          LevelBadgeView(level: level!, size: 44 * scale),
                          SizedBox(width: 14 * scale),
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                T.upper(LevelColors.tierName(level!.tier)),
                                style: AppText.display(
                                  11 * scale,
                                  weight: FontWeight.w700,
                                  color: LevelColors.bright(level!.tier),
                                ).copyWith(letterSpacing: 1.1 * scale),
                              ),
                              SizedBox(height: 2 * scale),
                              Text(message!, style: AppText.display(18 * scale, weight: FontWeight.w600)),
                            ],
                          ),
                        ],
                      ),
                    )
                  : icon != null
                  ? Glass(
                      key: ValueKey(message),
                      radius: 30 * scale,
                      opacity: 0.6,
                      padding: EdgeInsetsDirectional.fromSTEB(10 * scale, 10 * scale, 26 * scale, 10 * scale),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(9 * scale),
                            child: SizedBox(
                              width: 36 * scale,
                              height: 36 * scale,
                              child: ArtworkImage(path: icon!, cacheWidth: 96),
                            ),
                          ),
                          SizedBox(width: 14 * scale),
                          Text(message!, style: AppText.display(16 * scale, weight: FontWeight.w500)),
                        ],
                      ),
                    )
                  : Glass(
                      key: ValueKey(message),
                      radius: 30 * scale,
                      opacity: 0.6,
                      padding: EdgeInsets.symmetric(horizontal: 26 * scale, vertical: 14 * scale),
                      child: Text(message!, style: AppText.display(16 * scale, weight: FontWeight.w500)),
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _tappable(Widget child) {
    final tap = onTap;
    if (tap == null) return child;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(key: const ValueKey('toast-tap'), onTap: tap, child: child),
    );
  }
}
