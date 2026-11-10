import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' show PlatformDispatcher;

import 'package:path/path.dart' as p;

import '../core/power_profiles.dart';
import '../core/windows_heat.dart';
import 'app_model.dart';
import 'engine_model.dart';
import 'strings.dart';
import 'theme.dart';

/// Settings › Battery & Heat at work: the power read every few seconds, the policy
/// (core/power_profiles.dart) fed with it, and what it decides handed on: the running game hears
/// of it through EngineControl's file, the launcher dims its effects, and a note shows over the
/// game when it runs hot. The macOS launcher's PowerWatch. On Windows the heat also needs the
/// reader with administrator rights where nothing else gives the processor's (windows_heat.dart):
/// started when the user turns it on (or turns on the heat profile without it), and with each
/// launch after that until it is turned off or Windows' prompt is turned down.
class PowerModel {
  PowerModel(this.app);

  final AppModel app;

  /// Between readings: the policy's settle and cool-down count in these.
  static const interval = Duration(seconds: 5);

  // What tests replace.

  late PowerReading Function() read = () => PowerReader.current(gaming: app.running != null);

  /// The heat on Windows beyond the reading: null elsewhere.
  late WindowsHeatSource? windowsHeat = Platform.isWindows ? WindowsHeat.instance : null;

  /// The fastest display's refresh rate in hertz, null when the system does not say.
  late int? Function() displayHertz = _displayHertz;

  static int? _displayHertz() {
    try {
      final rates = [for (final display in PlatformDispatcher.instance.displays) display.refreshRate.round()];
      final best = rates.where((rate) => rate > 0).fold<int>(0, (best, rate) => rate > best ? rate : best);
      return best > 0 ? best : null;
    } on Object {
      return null;
    }
  }

  late DateTime Function() now = DateTime.now;

  PowerReading reading = const PowerReading(hasBattery: false, onBattery: false);
  final PowerPolicy policy = PowerPolicy();
  final BatteryEstimate _estimate = BatteryEstimate();
  Timer? _timer;
  List<Object?> _shown = const [];

  /// The file the running game reads its frame cap and frame generation pause from.
  String get controlFile => p.join(p.dirname(app.paths.toolkits), 'Power', 'control.txt');

  /// The file that tells the reader with administrator rights to end.
  String get readerStopFile => p.join(p.dirname(controlFile), 'heat-reader.stop');

  PowerProfiles get profiles => PowerProfiles.fromJson(app.preferences.powerProfiles);

  PowerAdjustment get adjustment => policy.adjustment;
  PowerMode get mode => policy.mode;
  bool get canUndo => policy.canUndo;

  /// The launcher's heavy effects (Glass blur, animations) turned down.
  bool get dimmed => adjustment.dimEffects;

  /// Minutes of battery left, null plugged in or while there is no estimate yet.
  int? get minutesLeft => reading.onBattery ? _estimate.minutesLeft(system: reading.minutesToEmpty) : null;

  /// Readings start with the launcher.
  void start() {
    if (_timer != null) return;
    policy.profiles = profiles;
    take();
    _timer = Timer.periodic(interval, (_) => take());
    // Turned on before: Windows asks again, once, as the launcher starts.
    if (app.preferences.heatReader && readerOffered) unawaited(_startReader());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// A reading taken now, or the one given.
  void take([PowerReading? given]) {
    final before = policy.adjustment;
    final at = now();
    try {
      reading = given ?? read();
    } on Object {
      // The last reading stays.
    }
    if (reading.batteryPercent case final int percent) {
      _estimate.add(percent: percent, onBattery: reading.onBattery, at: at);
    }
    policy.update(reading, at);
    _report(before, becameHot: policy.becameHot);
  }

  void undo() {
    if (!policy.canUndo) return;
    final before = policy.adjustment;
    policy.undo();
    _report(before, becameHot: false);
    app.show(T.text('powerUndone'));
  }

  void setProfiles(PowerProfiles next) {
    // On Windows, turning the heat profile on asks for the processor's temperature too.
    final askReader = !profiles.hot.on && next.hot.on && !app.preferences.heatReader && readerOffered;
    app.preferences.powerProfiles = next.isDefault ? null : next.toJson();
    app.savePreferences();
    final before = policy.adjustment;
    policy.profiles = next;
    _report(before, becameHot: false);
    app.refresh();
    if (askReader) unawaited(setReader(true));
  }

  /// Whether Settings offers the reader with administrator rights: on Windows, where no thermal
  /// zone is read without them (or the reader is already on).
  bool get readerOffered {
    final heat = windowsHeat;
    if (heat == null) return false;
    return !heat.zonesWithoutAdmin || heat.readerState != HeatReaderState.off;
  }

  HeatReaderState get readerState => windowsHeat?.readerState ?? HeatReaderState.off;

  /// The reader turned on (Windows asks for administrator rights) or off.
  Future<void> setReader(bool on) async {
    app.preferences.heatReader = on;
    app.savePreferences();
    if (on) {
      await _startReader();
    } else {
      windowsHeat?.stopReader(stopFile: readerStopFile);
      take();
    }
  }

  Future<void> _startReader() async {
    final heat = windowsHeat;
    if (heat == null) return;
    final started = heat.startReader(stopFile: readerStopFile);
    app.refresh();
    if (!await started && heat.readerState == HeatReaderState.declined) {
      // Turned down: not asked again until the user turns it on again.
      app.preferences.heatReader = false;
      app.savePreferences();
    }
    take();
    app.refresh();
  }

  void _report(PowerAdjustment before, {required bool becameHot}) {
    final now = policy.adjustment;
    if (now != before) {
      _writeControl();
      Motion.reduced = app.preferences.reducedMotion || now.dimEffects;
    }
    if (becameHot && app.running != null && policy.mode == PowerMode.hot && !now.isNone) {
      app.show(T.format('powerHotDetail', [T.text(now.frameCap > 0 ? 'powerHotLowered' : 'powerHotEased')]));
    }
    final shown = [
      reading.hasBattery,
      reading.onBattery,
      reading.batteryPercent,
      minutesLeft,
      reading.thermal,
      reading.lowPowerMode,
      readerState,
      windowsHeat?.graphicsFound,
      policy.mode,
      policy.canUndo,
      now,
    ];
    if (!_listEquals(shown, _shown)) {
      _shown = shown;
      app.refresh();
    }
  }

  static bool _listEquals(List<Object?> a, List<Object?> b) {
    if (a.length != b.length) return false;
    for (var index = 0; index < a.length; index++) {
      if (a[index] != b[index]) return false;
    }
    return true;
  }

  void _writeControl() {
    if (!app.persist) return;
    try {
      EngineControl.write(adjustment, controlFile);
    } on Object {
      // The game keeps what it read last.
    }
  }

  /// What a game starts with: the cap and the control file it reads while it runs.
  Map<String, String> environment() {
    _writeControl();
    return EngineControl.environment(controlFile, adjustment);
  }

  // Words.

  static String duration(int minutes) => minutes >= 60
      ? T.format('powerHoursMinutes', [minutes ~/ 60, minutes % 60])
      : T.format('powerMinutes', [minutes]);

  /// "On battery, 64%, about 2 h 5 min left", "Plugged in", or a desktop's line.
  String get sourceLine {
    if (!reading.hasBattery) return T.text('powerNoBattery');
    if (!reading.onBattery) return T.text('powerPluggedIn');
    final level = reading.batteryPercent == null
        ? T.text('powerOnBattery')
        : T.format('powerOnBatteryPercent', [T.percent(reading.batteryPercent!)]);
    final left = minutesLeft;
    return T.format('powerSourceAndTime', [
      level,
      left == null ? T.text('powerEstimating') : T.format('powerTimeLeft', [duration(left)]),
    ]);
  }

  /// Whether the heat profile can hold here: the heat is read, or on a Windows laptop the
  /// graphics card's is, while a game runs.
  bool get heatKnown => reading.readsHeat || (windowsHeat?.graphicsFound ?? false);

  String get thermalLine => switch (reading.thermal) {
    null when heatKnown => T.text('powerThermalInGames'),
    null => T.text('powerNoHeat'),
    ThermalLevel.nominal => T.text('powerThermalNominal'),
    ThermalLevel.fair => T.text('powerThermalFair'),
    ThermalLevel.serious => T.text('powerThermalSerious'),
    ThermalLevel.critical => T.text('powerThermalCritical'),
  };

  /// The profile in force by name, with its cap: "Battery profile with a 40 FPS cap".
  String get profileLine {
    final name = switch (policy.mode) {
      PowerMode.hot => T.text('powerProfileHot'),
      PowerMode.battery when !adjustment.isNone => T.text('powerProfileBattery'),
      PowerMode.battery =>
        policy.batteryUndone && profiles.battery.on
            ? T.format('powerProfileUndone', [T.text('powerProfileBattery')])
            : T.text('powerProfileNone'),
      PowerMode.pluggedIn =>
        policy.hot && policy.hotUndoneAt != null
            ? T.format('powerProfileUndone', [T.text('powerProfileHot')])
            : T.text('powerProfileNone'),
    };
    return adjustment.frameCap > 0 ? T.format('powerProfileWithCap', [name, adjustment.frameCap]) : name;
  }

  /// The profile Undo would lift: the heat's first.
  String get undoTitle => T.text(policy.mode == PowerMode.hot ? 'powerQuickUndoHot' : 'powerQuickUndoBattery');

  // Settings › Battery & Heat.

  List<PanelRow> rows() {
    final current = profiles;
    final upstream = !EngineModel.isArm(app.toolkitVersion);
    return [
      PanelRow(
        id: 'powerIntro',
        title: T.text('powerIntroTitle'),
        detail: T.text('powerIntro'),
        kind: const InfoRow(''),
      ),
      PanelRow(
        id: 'powerStatus',
        title: sourceLine,
        detail: [
          if (adjustment.isNone) T.text('powerInForceNothing') else T.format('powerInForce', [profileLine]),
          thermalLine,
          if (reading.lowPowerMode) T.text('powerLowPowerMode'),
        ].join('\n'),
        kind: const InfoRow(''),
      ),
      // Upstream's engine reads no cap and no control file: the launcher's own part still works.
      if (upstream)
        PanelRow(
          id: 'powerUpstream',
          title: T.text('powerUpstream'),
          detail: T.text('powerUpstreamDetail'),
          kind: const InfoRow(''),
        ),
      if (canUndo)
        PanelRow(id: 'powerUndo', title: undoTitle, detail: T.text('powerUndoDetail'), kind: ActionRow(undo)),
      PanelRow(id: 'batterySection', title: T.text('powerSectionBattery'), kind: const InfoRow('')),
      ..._profileRows(
        'battery',
        current.battery,
        title: 'powerBatteryProfile',
        detail: 'powerBatteryProfileDetail',
        set: (profile) => setProfiles(current.copyWith(battery: profile)),
      ),
      PanelRow(id: 'hotSection', title: T.text('powerSectionHot'), kind: const InfoRow('')),
      // Where the heat cannot be read, the heat profile would never hold: said instead.
      if (!heatKnown)
        PanelRow(
          id: 'hotUnavailable',
          title: T.text('powerHeatUnavailable'),
          detail: T.text(windowsHeat == null ? 'powerHeatUnavailableDetail' : 'powerHeatUnavailableWindowsDetail'),
          kind: const InfoRow(''),
        )
      else
        ..._profileRows(
          'hot',
          current.hot,
          title: 'powerHotProfile',
          detail: windowsHeat == null ? 'powerHotProfileDetail' : 'powerHotProfileWindowsDetail',
          set: (profile) => setProfiles(current.copyWith(hot: profile)),
        ),
      if (readerOffered)
        PanelRow(
          id: 'hotReader',
          title: T.text('powerHeatReader'),
          detail: [T.text('powerHeatReaderDetail'), if (readerLine case final String line) line].join('\n'),
          kind: ToggleRow(
            app.preferences.heatReader || readerState == HeatReaderState.asking,
            (value) => unawaited(setReader(value)),
          ),
        ),
    ];
  }

  /// Where the reader is, null while it is off.
  String? get readerLine => switch (readerState) {
    HeatReaderState.off => null,
    HeatReaderState.asking => T.text('powerHeatReaderAsking'),
    HeatReaderState.running => T.text('powerHeatReaderRunning'),
    HeatReaderState.empty => T.text('powerHeatReaderEmpty'),
    HeatReaderState.declined => T.text('powerHeatReaderDeclined'),
    HeatReaderState.stopped => T.text('powerHeatReaderStopped'),
  };

  List<PanelRow> _profileRows(
    String id,
    PowerProfile profile, {
    required String title,
    required String detail,
    required void Function(PowerProfile) set,
  }) {
    // Up to the display's own rate: a fast laptop on battery is the user's call.
    final hertz = displayHertz();
    final caps = PowerProfile.frameCapsFor(hertz, kept: profile.frameCap);
    String label(int cap) =>
        cap == 0 ? T.text('off') : (cap == hertz ? T.format('powerFpsDisplay', [cap]) : T.format('powerFps', [cap]));
    return [
      PanelRow(
        id: '${id}On',
        title: T.text(title),
        detail: T.text(detail),
        kind: ToggleRow(profile.on, (value) => set(profile.copyWith(on: value))),
      ),
      if (profile.on) ...[
        PanelRow(
          id: '${id}Cap',
          title: T.text('powerFrameCap'),
          detail: T.text('powerFrameCapDetail'),
          kind: ChoiceRow(
            [for (final cap in caps) label(cap)],
            caps.contains(profile.frameCap) ? caps.indexOf(profile.frameCap) : 0,
            (index) => set(profile.copyWith(frameCap: caps[index])),
          ),
        ),
        PanelRow(
          id: '${id}Resolution',
          title: T.text('powerLowerResolution'),
          detail: T.text('powerLowerResolutionDetail'),
          kind: ToggleRow(profile.lowerResolution, (value) => set(profile.copyWith(lowerResolution: value))),
        ),
        PanelRow(
          id: '${id}FrameGeneration',
          title: T.text('powerPauseFrameGeneration'),
          detail: T.text('powerPauseFrameGenerationDetail'),
          kind: ToggleRow(profile.pauseFrameGeneration, (value) => set(profile.copyWith(pauseFrameGeneration: value))),
        ),
        PanelRow(
          id: '${id}Effects',
          title: T.text('powerDimEffects'),
          detail: T.text('powerDimEffectsDetail'),
          kind: ToggleRow(profile.dimEffects, (value) => set(profile.copyWith(dimEffects: value))),
        ),
      ],
    ];
  }
}
