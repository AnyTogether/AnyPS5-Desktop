import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/services.dart';

import '../core/audio/tones.dart';
import '../core/capture/broadcast.dart';
import '../core/capture/game_sound.dart';
import '../core/capture/remote_play.dart';
import '../core/capture/video_encoders.dart';
import '../core/capture/wayland_capture.dart';
import '../core/desktop/desktop.dart';
import '../core/host.dart';
import '../core/remote/remote_protocol.dart';
import '../core/replay_buffer.dart' show ProcessRunner, ProcessStarter;
import 'app_model.dart';
import 'live_badge.dart';
import 'strings.dart';

/// What sends the game's picture and sound somewhere: Remote Play to the phones that ask, and
/// broadcasting to Twitch, YouTube or an RTMP server (Settings › Broadcasting, the quick menu
/// and the phone's Go Live). Both record with ffmpeg, as the replay buffer does.
class MediaModel {
  MediaModel(this.app);

  final AppModel app;

  Map<String, String> get _environment => app.services.environment ?? Platform.environment;

  /// ffmpeg beside the launcher or on the PATH (the replay buffer's), or a test's.
  String? get ffmpeg => ffmpegOverride ?? app.replayFfmpeg;

  /// Tests: a stand-in ffmpeg, encoder choice, game area and sound, and process starts.
  String? ffmpegOverride;
  EncoderChoice? encodersOverride;
  ScreenArea? Function(int pid)? areaOverride;
  GameSound Function(int pid)? soundOverride;
  ProcessStarter? startOverride;
  ProcessRunner? runOverride;

  /// Tests: whether the LIVE badge shows, whatever the desktop: true as where it is left out of
  /// every picture (Windows), false as where there is none.
  bool? badgeOverride;

  /// Under Wayland, what records through the desktop's portal; null elsewhere.
  WaylandCapture? get wayland => app.waylandCapture;

  /// Whether this desktop can be recorded at all (Windows, X11, Wayland through its portal).
  bool get screenRecordable =>
      ScreenGrab.supported(app.system, _environment) || wayland != null || areaOverride != null;

  /// Why nothing can be recorded here, or null when it can.
  String? get unavailable {
    if (!screenRecordable) return T.text('replayNoScreen');
    return ffmpeg == null ? T.text('replayNoFfmpeg') : null;
  }

  EncoderChoice? _encoders;
  EncoderChoice? get encoders {
    if (encodersOverride != null) return encodersOverride;
    final tool = ffmpeg;
    if (tool == null) return null;
    // Asked again for another ffmpeg: one just downloaded works where the old one did not.
    if (_encoders?.ffmpeg != tool) _encoders = null;
    return _encoders ??= EncoderChoice(
      ffmpeg: tool,
      system: app.system,
      run: (executable, arguments) => Process.run(executable, arguments),
      onNone: () => app.ffmpegTool.noteNoEncoder(tool),
    );
  }

  ScreenArea? areaOf(int pid) {
    if (areaOverride != null) return areaOverride!(pid);
    // Wayland reveals no window's position: the shared window's size is what there is.
    if (wayland case final capture?) return capture.area;
    final desktop = app.desktop;
    return desktop is GameAreas ? (desktop as GameAreas).gameArea(pid) : null;
  }

  GameSound soundOf(int pid) =>
      soundOverride?.call(pid) ?? GameSound.forGame(pid, system: app.system, environment: _environment, ffmpeg: ffmpeg);

  void _log(String line) => app.addRecentLine('${DateTime.now().toIso8601String()} $line');

  // Remote Play.

  RemotePlayStream? _remotePlay;
  Timer? _remoteRetry;
  bool _toldNoTool = false;

  /// Whether the game is going to a phone now.
  bool get remotePlaying => _remotePlay?.running ?? false;

  /// Sends the running game to the phones that ask for it, at the largest size one asked for up
  /// to 720p; stops when none asks or no game plays. Called when a phone asks or stops asking
  /// and when a game starts or ends.
  Future<void> updateRemotePlay() async {
    _remoteRetry?.cancel();
    final remote = app.remote;
    if (remote == null) return;
    final wishes = remote.streamWishes;
    if (wishes.isEmpty) return _stopRemotePlay();
    void tell(String state) {
      for (final (device, _, _) in wishes) {
        remote.tell(RemoteStreaming(state), device);
      }
    }

    final playing = app.running;
    final tool = ffmpeg;
    final choice = encoders;
    if (playing == null || tool == null || choice == null || !screenRecordable) {
      await _stopRemotePlay();
      tell('noGame');
      // A game plays but nothing can record it: said once, so the empty phone has a reason.
      if (playing != null && !_toldNoTool) {
        _toldNoTool = true;
        if (screenRecordable && app.ffmpegTool.offered) {
          app.show(T.text('remotePlayGetFfmpeg'), onTap: () => app.openSettingsCategory('captures'));
        } else {
          app.show(T.text(screenRecordable ? 'remotePlayNoFfmpeg' : 'remotePlayNoScreen'));
        }
      }
      return;
    }
    if (wayland case final capture?) {
      if (await choice.encoder == null) return _refuseRemotePlay(tell, T.text('waylandNoEncoder'));
      // The desktop's dialog, when it has not been answered for this game.
      if (await capture.share() == null) {
        return _refuseRemotePlay(tell, T.text((capture.problem ?? WaylandProblem.failed).textKey));
      }
    }
    // The phone's long side across: the size it asked for, no more than 1280 x 720.
    final height = min(720, wishes.map((wish) => min(wish.$2, wish.$3)).reduce(max));
    final width = min(1280, wishes.map((wish) => max(wish.$2, wish.$3)).reduce(max));
    // On X11 Remote Play records the screen: the LIVE badge goes first.
    await _updateBadge();
    final stream = _remotePlay ??= RemotePlayStream(
      ffmpeg: tool,
      system: app.system,
      environment: _environment,
      encoders: choice,
      areaOf: areaOf,
      soundOf: soundOf,
      wayland: wayland,
      start: startOverride,
      log: _log,
    );
    final result = await stream.start(pid: playing.$2.pid, width: width, height: height, send: remote.sendStream);
    tell(result == RemotePlayStart.on ? 'on' : 'noGame');
    // The game's window is not open yet: looked for again while the game runs.
    if (result == RemotePlayStart.noGame && app.running != null) {
      _remoteRetry = Timer(const Duration(seconds: 2), () => unawaited(updateRemotePlay()));
    }
  }

  Future<void> _refuseRemotePlay(void Function(String state) tell, String reason) async {
    await _stopRemotePlay();
    tell('noGame');
    if (_toldNoTool) return;
    _toldNoTool = true;
    app.show(reason);
  }

  /// The phone lost part of the picture.
  void wantKey() => _remotePlay?.wantKey();

  Future<void> _stopRemotePlay() async {
    _remoteRetry?.cancel();
    await _remotePlay?.stop();
  }

  // Broadcasting.

  late final BroadcastSettings settings = BroadcastSettings.load(Broadcaster.settingsFile(app.paths.config));
  late final BroadcastKeys keys = BroadcastKeys(Broadcaster.keysFile(app.paths.config), system: app.system);
  Broadcaster? _broadcaster;
  BroadcastPhase _toldPhase = const BroadcastOff();

  BroadcastPhase get phase => _broadcaster?.phase ?? const BroadcastOff();

  String get key => keys.keyFor(settings.service);

  String get serviceName =>
      settings.service == BroadcastService.custom ? T.text('broadcastServiceCustom') : settings.service.brand;

  void _saveSettings() {
    settings.save(Broadcaster.settingsFile(app.paths.config));
    app.refresh();
  }

  void setKey(String value) {
    if (value.trim().isEmpty) return;
    keys.setKey(settings.service, value);
    app.refresh();
  }

  /// Where the broadcast goes, or the problem with what was set up.
  (RtmpEndpoint?, EndpointProblem?) endpoint() {
    try {
      return (RtmpEndpoint.parse(settings.serverUrl, key), null);
    } on EndpointProblem catch (problem) {
      return (null, problem);
    }
  }

  static String problemText(EndpointProblem problem) => T.text(switch (problem) {
    EndpointProblem.notRtmp => 'broadcastProblemNotRtmp',
    EndpointProblem.noHost => 'broadcastProblemNoHost',
    EndpointProblem.noApplication => 'broadcastProblemNoApplication',
    EndpointProblem.noKey => 'broadcastProblemNoKey',
  });

  Broadcaster? _makeBroadcaster() {
    final tool = ffmpeg;
    final choice = encoders;
    if (tool == null || choice == null) return null;
    return Broadcaster(
      ffmpeg: tool,
      system: app.system,
      environment: _environment,
      encoders: choice,
      areaOf: areaOf,
      soundOf: soundOf,
      wayland: wayland,
      changed: _broadcastChanged,
      start: startOverride,
      run: runOverride,
      microphoneLevel: () => settings.microphone ? settings.microphoneLevel : 0,
      microphoneDevice: () => settings.microphoneDevice,
      noMicrophone: () => unawaited(
        app.notice(
          T.text('broadcastMicrophone'),
          detail: T.text('broadcastNoMicrophone'),
          symbol: Icons.mic_off_rounded,
        ),
      ),
      log: _log,
    );
  }

  /// Go live with the game playing, or end the broadcast.
  void toggleBroadcast() {
    final broadcaster = _broadcaster;
    if (broadcaster != null && broadcaster.phase.active) return broadcaster.stop();
    final playing = app.running;
    if (playing == null) return app.show(T.text('broadcastGoLiveNoGame'));
    final reason = unavailable;
    if (reason != null) {
      return app.show(reason, onTap: app.ffmpegTool.offered ? () => app.openSettingsCategory('broadcast') : null);
    }
    final (target, problem) = endpoint();
    if (target == null) {
      unawaited(
        app.notice(
          T.text('broadcastSetUpFirst'),
          detail: problem == null ? null : problemText(problem),
          symbol: Icons.podcasts_rounded,
        ),
      );
      return;
    }
    final made = _broadcaster ??= _makeBroadcaster();
    if (made == null) return;
    app.sounds.play(Cue.select);
    unawaited(made.start(pid: playing.$2.pid, endpoint: target, quality: settings.quality));
  }

  /// The game ended: so does its broadcast.
  void gameEnded() {
    // Under Wayland each game is asked for its own window, so each may have its own reason.
    if (wayland != null) _toldNoTool = false;
    _broadcaster?.stop();
    unawaited(updateRemotePlay());
  }

  void _broadcastChanged() {
    final now = phase;
    if (now.runtimeType != _toldPhase.runtimeType) {
      final before = _toldPhase;
      _toldPhase = now;
      switch (now) {
        case BroadcastLive() when before is! BroadcastLive:
          unawaited(app.notice(T.format('broadcastStartedNotice', [serviceName]), symbol: Icons.podcasts_rounded));
        case BroadcastReconnecting():
          unawaited(app.notice(T.text('broadcastReconnectingNotice'), symbol: Icons.podcasts_rounded));
        case BroadcastFailed(:final reason):
          unawaited(
            app.notice(T.format('broadcastFailedNotice', [failureText(reason)]), symbol: Icons.podcasts_rounded),
          );
        case BroadcastOff() when before.active:
          unawaited(app.notice(T.text('broadcastEndedNotice'), symbol: Icons.podcasts_rounded));
        default:
          break;
      }
      if (now.active != before.active) app.remote?.publish(RemoteBroadcast(now.active));
    }
    unawaited(_updateBadge());
    app.refresh();
  }

  // The LIVE badge over the game, kept out of what viewers see: Windows leaves its window out of
  // every capture, as the Mac does, and under Wayland the portal shares the game's window alone
  // (the badge is a layer-shell surface over it). On X11 the broadcast records the game's window by itself, which
  // leaves it out under a compositing manager (LinuxDesktop shows it only then); a recording of the
  // screen would take it, so it stays hidden while the replay buffer or Remote Play records.

  BadgeReach get _badgeReach => switch (badgeOverride) {
    null => app.desktop.badgeReach,
    true => BadgeReach.excluded,
    false => BadgeReach.none,
  };

  /// Whether the LIVE badge can be over the game now without being in anything recorded.
  static bool badgeKeptOut(BadgeReach reach, {required bool windowOnly, required bool screenRecorded}) =>
      switch (reach) {
        BadgeReach.none => false,
        BadgeReach.excluded => true,
        BadgeReach.windowRecordingOnly => windowOnly && !screenRecorded,
      };

  /// Whether something records the whole screen, or is about to: the replay buffer, Remote Play.
  bool get _screenRecorded =>
      app.replayStarted || remotePlaying || ((app.remote?.streamWishes.isNotEmpty ?? false) && app.running != null);

  bool get _badgeShown =>
      settings.liveBadge &&
      (phase is BroadcastLive || phase is BroadcastReconnecting) &&
      badgeKeptOut(_badgeReach, windowOnly: _broadcaster?.recordsWindowOnly ?? false, screenRecorded: _screenRecorded);

  /// The badge as things are now, before something starts recording the screen.
  Future<void> badgeCheck() => _updateBadge();

  String? _badgeState;
  Future<void>? _badgeRun;
  bool _badgeAgain = false;

  /// Keeps the badge's window as the broadcast now is, one drawing at a time; completes once it
  /// is.
  Future<void> _updateBadge() {
    _badgeAgain = true;
    return _badgeRun ??= () async {
      try {
        while (_badgeAgain) {
          _badgeAgain = false;
          await _drawBadge();
        }
      } finally {
        _badgeRun = null;
      }
    }();
  }

  Future<void> _drawBadge() async {
    final running = _broadcaster?.pid;
    if (!_badgeShown || running == null) {
      if (_badgeState != null) {
        _badgeState = null;
        await app.desktop.showBadge(null);
      }
      return;
    }
    final live = phase is BroadcastLive;
    final time = clock(_broadcaster?.stats.duration ?? Duration.zero);
    final state = '$live $time';
    if (state == _badgeState) return;
    final render = app.services.renderLiveBadge ?? LiveBadge.render;
    final image = await render(live, time, app.desktop.cardScale(running));
    if (!_badgeShown) return _drawBadge();
    _badgeState = state;
    await app.desktop.showBadge(image, pid: running);
  }

  static String failureText(String reason) {
    if (reason == Broadcaster.noEncoder) return T.text('broadcastNoEncoder');
    return WaylandProblem.values.any((problem) => problem.textKey == reason) ? T.text(reason) : reason;
  }

  /// The phone's Go Live and End Broadcast: what it asks for, then what the launcher does now,
  /// in case it showed the wrong one.
  void phoneBroadcast(bool start) {
    if (start != phase.active) toggleBroadcast();
    app.remote?.publish(RemoteBroadcast(phase.active));
  }

  Future<void> pasteKey() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) return app.show(T.text('broadcastKeyClipboardEmpty'));
    setKey(text);
    app.show(T.text('broadcastKeyPasted'));
  }

  /// 0:42, 12:05 or 1:02:09.
  static String clock(Duration duration) {
    final total = duration.inSeconds;
    final hours = total ~/ 3600;
    final minutes = (total ~/ 60 % 60).toString().padLeft(hours > 0 ? 2 : 1, '0');
    final seconds = (total % 60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  /// 4.5 Mbit/s, or 850 kbit/s below one.
  static String rate(int bits) =>
      bits >= 1000000 ? '${(bits / 1000000).toStringAsFixed(1)} Mbit/s' : '${bits ~/ 1000} kbit/s';

  String _numbers() {
    final stats = _broadcaster?.stats ?? BroadcastStats();
    return T.format('broadcastStateLine', [
      serviceName,
      rate(stats.bitRate),
      '${stats.dropped}',
      '${stats.droppedPercent.toStringAsFixed(1)}%',
    ]);
  }

  /// On the game playing: Go Live, or how the broadcast goes and Stop. Where nothing can be
  /// recorded there are none: Settings › Broadcasting says why.
  List<PanelRow> gameRows() {
    if (app.running == null && !phase.active) return const [];
    final rows = <PanelRow>[];
    switch (phase) {
      case BroadcastOff() || BroadcastFailed():
        final (target, _) = endpoint();
        final reason = unavailable;
        if (reason != null) {
          return const [];
        } else if (target != null) {
          final failed = phase is BroadcastFailed ? failureText((phase as BroadcastFailed).reason) : null;
          rows.add(
            PanelRow(
              id: 'broadcast-go',
              title: T.format('broadcastGoLive', [app.running?.$1.name ?? '']),
              detail: failed ?? T.format('broadcastGoLiveDetail', [serviceName, settings.quality.title]),
              kind: ActionRow(toggleBroadcast),
            ),
          );
        } else {
          rows.add(
            PanelRow(
              id: 'broadcast-setup',
              title: T.text('broadcastSetUpFirst'),
              detail: T.text('broadcastSetUpFirstDetail'),
              kind: ActionRow(() => app.openSettingsCategory('broadcast')),
            ),
          );
        }
        return rows;
      case BroadcastStarting():
        rows.add(
          PanelRow(id: 'broadcast-state', title: T.format('broadcastStarting', [serviceName]), kind: const InfoRow('')),
        );
      case BroadcastReconnecting(:final delay):
        rows.add(
          PanelRow(
            id: 'broadcast-state',
            title: T.format('broadcastReconnecting', [delay.inSeconds]),
            kind: InfoRow(_numbers()),
          ),
        );
      case BroadcastLive():
        rows.add(
          PanelRow(
            id: 'broadcast-state',
            title: T.format('broadcastLiveStats', [clock(_broadcaster?.stats.duration ?? Duration.zero)]),
            kind: InfoRow(_numbers()),
          ),
        );
    }
    final link = settings.viewerUri;
    if (link != null) {
      rows.add(
        PanelRow(
          id: 'broadcast-copy',
          title: T.text('broadcastCopyLink'),
          detail: link.toString().replaceFirst('https://', ''),
          kind: ActionRow(() {
            app.services.copyText?.call(link.toString());
            app.show(T.text('broadcastLinkCopied'));
          }),
        ),
      );
    }
    rows.add(
      PanelRow(
        id: 'broadcast-live-mic',
        title: T.text('broadcastMicrophone'),
        detail: T.text('broadcastMicrophoneDetail'),
        kind: ToggleRow(settings.microphone, _setMicrophone),
      ),
    );
    rows.add(
      PanelRow(
        id: 'broadcast-stop',
        title: T.text('broadcastStop'),
        kind: ActionRow(toggleBroadcast, destructive: true),
      ),
    );
    return rows;
  }

  /// Tests: the devices the picker lists, standing in for asking ffmpeg.
  List<String>? micDevicesOverride;

  /// What ffmpeg lists once it has been asked this session (Windows); null until then.
  List<String>? _micDevices;
  bool _askingMicDevices = false;

  /// Which DirectShow device is the microphone (Windows): Automatic, or one ffmpeg lists. The
  /// Mac always takes macOS's default input, and Linux PulseAudio's, which has no such row.
  PanelRow? _micDeviceRow() {
    final tool = ffmpeg;
    final devices = micDevicesOverride ?? _micDevices;
    if (devices == null) {
      if (tool != null && !_askingMicDevices) {
        _askingMicDevices = true;
        unawaited(
          BroadcastMicrophone.devices(
            ffmpeg: tool,
            run: runOverride ?? ((executable, arguments) => Process.run(executable, arguments)),
          ).then((found) {
            _micDevices = found;
            _askingMicDevices = false;
            app.refresh();
          }),
        );
      }
      return null;
    }
    if (devices.isEmpty) return null;
    final picked = settings.microphoneDevice;
    return PanelRow(
      id: 'broadcast-mic-device',
      title: T.text('broadcastMicrophoneDevice'),
      kind: ChoiceRow(
        [T.text('broadcastMicrophoneAuto'), ...devices],
        picked == null ? 0 : devices.indexOf(picked) + 1,
        (index) {
          settings.microphoneDevice = index == 0 ? null : devices[index - 1];
          _saveSettings();
          _broadcaster?.microphoneDeviceChanged();
          app.refresh();
        },
      ),
    );
  }

  void _setMicrophone(bool on) {
    settings.microphone = on;
    _saveSettings();
    _broadcaster?.microphoneChanged();
    app.refresh();
  }

  /// Settings › Broadcasting.
  List<PanelRow> settingsRows() {
    final services = BroadcastService.values;
    final qualities = BroadcastQuality.values;
    final current = key;
    return [
      if (unavailable case final reason?)
        PanelRow(id: 'broadcast-unavailable', title: T.text('broadcastTitle'), kind: InfoRow(reason))
      else
        // The microphone has its own row below.
        ...gameRows().where((row) => row.id != 'broadcast-live-mic'),
      ...app.ffmpegTool.rows(),
      PanelRow(
        id: 'broadcast-service',
        title: T.text('broadcastService'),
        kind: ChoiceRow(
          [
            for (final service in services)
              service == BroadcastService.custom ? T.text('broadcastServiceCustom') : service.brand,
          ],
          services.indexOf(settings.service),
          (index) {
            settings.service = services[index];
            _saveSettings();
          },
        ),
      ),
      if (settings.service == BroadcastService.custom)
        PanelRow(
          id: 'broadcast-server',
          title: T.text('broadcastServer'),
          detail: T.text('broadcastServerDetail'),
          kind: TextRow(settings.customUrl, (text) {
            settings.customUrl = text.trim();
            _saveSettings();
          }, hint: 'rtmp://'),
        ),
      PanelRow(
        id: 'broadcast-key',
        title: T.text('broadcastKey'),
        detail: T.text('broadcastKeyDetail'),
        kind: TextRow(
          '',
          setKey,
          hint: current.isEmpty ? T.text('broadcastKeyNone') : BroadcastKeys.masked(current),
          obscure: true,
        ),
      ),
      PanelRow(id: 'broadcast-paste', title: T.text('broadcastKeyPaste'), kind: ActionRow(() => unawaited(pasteKey()))),
      if (settings.service.keyPage case final page?)
        PanelRow(
          id: 'broadcast-page',
          title: T.text('broadcastKeyPage'),
          detail: T.format('broadcastKeyPageDetail', [page.host]),
          kind: ActionRow(() => app.services.openUrl?.call(page)),
        ),
      PanelRow(
        id: 'broadcast-quality',
        title: T.text('broadcastQuality'),
        detail: T.text('broadcastQualityDetail'),
        kind: ChoiceRow([for (final quality in qualities) quality.title], qualities.indexOf(settings.quality), (index) {
          settings.quality = qualities[index];
          _saveSettings();
        }),
      ),
      PanelRow(
        id: 'broadcast-mic',
        title: T.text('broadcastMicrophone'),
        detail: T.text('broadcastMicrophoneDetail'),
        kind: ToggleRow(settings.microphone, _setMicrophone),
      ),
      if (settings.microphone)
        PanelRow(
          id: 'broadcast-mic-level',
          title: T.text('broadcastMicrophoneLevel'),
          kind: StepperRow(
            value: settings.microphoneLevel,
            min: 10,
            max: 100,
            step: 10,
            format: T.percent,
            set: (value) {
              settings.microphoneLevel = value;
              _saveSettings();
              _broadcaster?.microphoneChanged();
              app.refresh();
            },
          ),
        ),
      if (settings.microphone && (micDevicesOverride != null || app.system == HostSystem.windows)) ?_micDeviceRow(),
      if (_badgeReach != BadgeReach.none)
        PanelRow(
          id: 'broadcast-badge',
          title: T.text('broadcastBadge'),
          detail: T.text(
            _badgeReach == BadgeReach.windowRecordingOnly ? 'broadcastBadgeDetailX11' : 'broadcastBadgeDetail',
          ),
          kind: ToggleRow(settings.liveBadge, (on) {
            settings.liveBadge = on;
            _saveSettings();
            unawaited(_updateBadge());
            app.refresh();
          }),
        )
      else
        PanelRow(
          id: 'broadcast-badge',
          title: T.text('broadcastBadge'),
          kind: InfoRow(T.text('broadcastBadgeNoOverlay')),
        ),
      PanelRow(
        id: 'broadcast-link',
        title: T.text('broadcastViewerLink'),
        detail: T.text('broadcastViewerLinkDetail'),
        kind: TextRow(settings.viewerLink, (text) {
          settings.viewerLink = text.trim();
          _saveSettings();
        }, hint: 'twitch.tv/…'),
      ),
      PanelRow(
        id: 'broadcast-private',
        title: T.text('broadcastKeysTitle'),
        kind: InfoRow(T.text('broadcastKeptPrivately')),
      ),
    ];
  }

  /// Every stream key, for a report to take out wherever one appears.
  List<String> get secrets => keys.secrets;

  void dispose() {
    _broadcaster?.stop();
    unawaited(_stopRemotePlay());
  }
}
