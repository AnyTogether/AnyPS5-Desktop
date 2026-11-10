import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import 'windows_heat.dart';

// Battery and heat profiles (Settings › Battery & Heat): what a laptop on battery, or a computer
// running hot, does to the game playing. On battery the game can be held to 30 fps or more, up to
// the display's refresh rate, its frame generation paused and the launcher's heavy effects dimmed; running hot the same, with a
// note that can be undone from the quick menu. Plugged in and cool nothing changes. The macOS
// launcher's PowerProfiles.swift, rule for rule and with its settings keys; the readings come
// from GetSystemPowerStatus on Windows and /sys on Linux. The heat on Windows comes from the
// graphics card's library and the thermal zones (windows_heat.dart), the processor's zones through
// a reader with administrator rights where Windows gives them no other way. Where the heat cannot
// be read, only the battery profile works.

/// How warm the computer is, comparable.
enum ThermalLevel { nominal, fair, serious, critical }

/// One reading of the computer's power: where it draws from, the battery, the heat, the
/// system's battery saver.
class PowerReading {
  const PowerReading({
    required this.hasBattery,
    required this.onBattery,
    this.batteryPercent,
    this.minutesToEmpty,
    this.thermal,
    this.lowPowerMode = false,
  });

  /// A desktop computer, cool, plugged in.
  static const pluggedIn = PowerReading(hasBattery: false, onBattery: false, thermal: ThermalLevel.nominal);

  /// Whether the computer has a battery at all (a desktop has none).
  final bool hasBattery;
  final bool onBattery;
  final int? batteryPercent;

  /// The system's estimate of the minutes left, null while it has none.
  final int? minutesToEmpty;

  /// How warm the computer is; null where it cannot be read.
  final ThermalLevel? thermal;

  /// Battery saver (Windows) or the low-power platform profile (Linux).
  final bool lowPowerMode;

  /// Battery or battery saver: the user wants power saved.
  bool get savingPower => onBattery || lowPowerMode;
  bool get hot => thermal != null && thermal!.index >= ThermalLevel.serious.index;

  /// Whether the heat can be read here.
  bool get readsHeat => thermal != null;

  @override
  bool operator ==(Object other) =>
      other is PowerReading &&
      other.hasBattery == hasBattery &&
      other.onBattery == onBattery &&
      other.batteryPercent == batteryPercent &&
      other.minutesToEmpty == minutesToEmpty &&
      other.thermal == thermal &&
      other.lowPowerMode == lowPowerMode;

  @override
  int get hashCode => Object.hash(hasBattery, onBattery, batteryPercent, minutesToEmpty, thermal, lowPowerMode);

  @override
  String toString() =>
      'PowerReading(battery: $hasBattery, on: $onBattery, $batteryPercent%, ${minutesToEmpty}min, $thermal, low: $lowPowerMode)';
}

/// What one profile does while it holds.
class PowerProfile {
  const PowerProfile({
    required this.on,
    required this.frameCap,
    required this.lowerResolution,
    required this.pauseFrameGeneration,
    required this.dimEffects,
  });

  /// The frame caps offered on any display; 0 is none.
  static const frameCaps = [0, 30, 40, 45];

  /// The higher caps, offered up to the display's own refresh rate.
  static const higherCaps = [60, 90, 120, 144, 165, 240, 360];

  /// The caps offered for a display of [hertz] (60 when unknown): the low ones, the higher ones
  /// up to it, its own rate, and [kept] (a cap saved on another display) so it is not lost.
  static List<int> frameCapsFor(int? hertz, {int? kept}) {
    final rate = hertz == null || hertz < 30 ? 60 : hertz;
    final caps = {...frameCaps, for (final cap in higherCaps) if (cap <= rate) cap, rate};
    if (kept != null && kept > 0) caps.add(kept);
    return caps.toList()..sort();
  }

  static const battery = PowerProfile(
    on: true,
    frameCap: 40,
    lowerResolution: false,
    pauseFrameGeneration: true,
    dimEffects: true,
  );
  static const hot = battery;

  /// A saved profile; a field it lacks (or one of the wrong kind) is [defaults]'s.
  factory PowerProfile.fromJson(Object? json, PowerProfile defaults) {
    if (json is! Map) return defaults;
    bool flag(String key, bool fallback) => json[key] is bool ? json[key] as bool : fallback;
    final cap = json['frameCap'];
    return PowerProfile(
      on: flag('on', defaults.on),
      frameCap: cap is num ? cap.toInt() : defaults.frameCap,
      lowerResolution: flag('lowerResolution', defaults.lowerResolution),
      pauseFrameGeneration: flag('pauseFrameGeneration', defaults.pauseFrameGeneration),
      dimEffects: flag('dimEffects', defaults.dimEffects),
    );
  }

  final bool on;

  /// The game's frame rate cap, 0 for none.
  final int frameCap;

  /// The Mac starts a game one resolution step down. Kept for the settings file a Mac shares;
  /// this launcher writes the resolution at unlock time, so it does not act on it.
  final bool lowerResolution;
  final bool pauseFrameGeneration;

  /// The launcher's Glass blur and animations turned down.
  final bool dimEffects;

  /// What this profile changes, none when it is off.
  PowerAdjustment get adjustment => on
      ? PowerAdjustment(
          frameCap: frameCap,
          lowerResolution: lowerResolution,
          pauseFrameGeneration: pauseFrameGeneration,
          dimEffects: dimEffects,
        )
      : PowerAdjustment.none;

  PowerProfile copyWith({
    bool? on,
    int? frameCap,
    bool? lowerResolution,
    bool? pauseFrameGeneration,
    bool? dimEffects,
  }) => PowerProfile(
    on: on ?? this.on,
    frameCap: frameCap ?? this.frameCap,
    lowerResolution: lowerResolution ?? this.lowerResolution,
    pauseFrameGeneration: pauseFrameGeneration ?? this.pauseFrameGeneration,
    dimEffects: dimEffects ?? this.dimEffects,
  );

  Map<String, Object?> toJson() => {
    'on': on,
    'frameCap': frameCap,
    'lowerResolution': lowerResolution,
    'pauseFrameGeneration': pauseFrameGeneration,
    'dimEffects': dimEffects,
  };

  @override
  bool operator ==(Object other) =>
      other is PowerProfile &&
      other.on == on &&
      other.frameCap == frameCap &&
      other.lowerResolution == lowerResolution &&
      other.pauseFrameGeneration == pauseFrameGeneration &&
      other.dimEffects == dimEffects;

  @override
  int get hashCode => Object.hash(on, frameCap, lowerResolution, pauseFrameGeneration, dimEffects);
}

/// The two profiles the user sets (the preferences' "powerProfiles", as on the Mac).
class PowerProfiles {
  const PowerProfiles({this.battery = PowerProfile.battery, this.hot = PowerProfile.hot});

  factory PowerProfiles.fromJson(Object? json) {
    if (json is! Map) return const PowerProfiles();
    return PowerProfiles(
      battery: PowerProfile.fromJson(json['battery'], PowerProfile.battery),
      hot: PowerProfile.fromJson(json['hot'], PowerProfile.hot),
    );
  }

  final PowerProfile battery;
  final PowerProfile hot;

  bool get isDefault => this == const PowerProfiles();

  PowerProfiles copyWith({PowerProfile? battery, PowerProfile? hot}) =>
      PowerProfiles(battery: battery ?? this.battery, hot: hot ?? this.hot);

  Map<String, Object?> toJson() => {'battery': battery.toJson(), 'hot': hot.toJson()};

  @override
  bool operator ==(Object other) => other is PowerProfiles && other.battery == battery && other.hot == hot;

  @override
  int get hashCode => Object.hash(battery, hot);
}

/// What is changed for the game and the launcher now; [none] changes nothing.
class PowerAdjustment {
  const PowerAdjustment({
    required this.frameCap,
    required this.lowerResolution,
    required this.pauseFrameGeneration,
    required this.dimEffects,
  });

  static const none = PowerAdjustment(
    frameCap: 0,
    lowerResolution: false,
    pauseFrameGeneration: false,
    dimEffects: false,
  );

  final int frameCap;
  final bool lowerResolution;
  final bool pauseFrameGeneration;
  final bool dimEffects;

  bool get isNone => this == none;

  /// The stricter of the two in each part: the lower cap, any of the switches.
  PowerAdjustment merged(PowerAdjustment other) {
    final caps = [frameCap, other.frameCap].where((cap) => cap > 0);
    return PowerAdjustment(
      frameCap: caps.isEmpty ? 0 : caps.reduce(math.min),
      lowerResolution: lowerResolution || other.lowerResolution,
      pauseFrameGeneration: pauseFrameGeneration || other.pauseFrameGeneration,
      dimEffects: dimEffects || other.dimEffects,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PowerAdjustment &&
      other.frameCap == frameCap &&
      other.lowerResolution == lowerResolution &&
      other.pauseFrameGeneration == pauseFrameGeneration &&
      other.dimEffects == dimEffects;

  @override
  int get hashCode => Object.hash(frameCap, lowerResolution, pauseFrameGeneration, dimEffects);

  @override
  String toString() => 'cap $frameCap, frame gen ${pauseFrameGeneration ? 'paused' : 'on'}, dim $dimEffects';
}

/// Which profile is in force.
enum PowerMode { pluggedIn, battery, hot }

/// From readings to the adjustment in force, with hysteresis so it does not flap: a change of
/// power source counts once it has held [sourceSettle] (a cable that slips changes nothing), heat
/// counts at once and ends only after [coolDown] below serious. Undo lifts the heat's part (then
/// the battery's) until that episode ends; heat that rises past the level that was undone applies
/// again.
class PowerPolicy {
  PowerPolicy({this.profiles = const PowerProfiles()});

  static const sourceSettle = Duration(seconds: 10);
  static const coolDown = Duration(seconds: 90);

  PowerProfiles profiles;
  bool savingPower = false;
  bool hot = false;

  /// The latest reading entered a hot episode.
  bool becameHot = false;

  /// The heat level an undo was made at, null when the heat's part is not undone.
  ThermalLevel? hotUndoneAt;
  bool batteryUndone = false;

  bool _started = false;
  DateTime? _sourceChangeSince;
  DateTime? _coolSince;
  ThermalLevel _lastThermal = ThermalLevel.nominal;

  /// Feeds a reading taken at [now]; the adjustment in force after it.
  PowerAdjustment update(PowerReading state, DateTime now) {
    becameHot = false;
    if (!_started) {
      _started = true;
      savingPower = state.savingPower;
    } else if (state.savingPower != savingPower) {
      final since = _sourceChangeSince ??= now;
      if (now.difference(since) >= sourceSettle) {
        savingPower = state.savingPower;
        _sourceChangeSince = null;
        batteryUndone = false;
      }
    } else {
      _sourceChangeSince = null;
    }

    final thermal = state.thermal ?? ThermalLevel.nominal;
    if (state.hot) {
      _coolSince = null;
      if (!hot) {
        hot = true;
        becameHot = true;
      }
      if (hotUndoneAt case final ThermalLevel undone when thermal.index > undone.index) hotUndoneAt = null;
    } else if (hot) {
      final since = _coolSince ??= now;
      if (now.difference(since) >= coolDown) {
        hot = false;
        _coolSince = null;
        hotUndoneAt = null;
      }
    }
    _lastThermal = thermal;
    return adjustment;
  }

  PowerAdjustment get _heatPart => hot && hotUndoneAt == null ? profiles.hot.adjustment : PowerAdjustment.none;
  PowerAdjustment get _batteryPart =>
      savingPower && !batteryUndone ? profiles.battery.adjustment : PowerAdjustment.none;

  /// What is changed now.
  PowerAdjustment get adjustment => _heatPart.merged(_batteryPart);

  PowerMode get mode {
    if (hot && hotUndoneAt == null) return PowerMode.hot;
    return savingPower ? PowerMode.battery : PowerMode.pluggedIn;
  }

  /// Whether anything is changed that Undo would lift.
  bool get canUndo => !_heatPart.isNone || !_batteryPart.isNone;

  /// Lifts the heat's part, or with none the battery's; the adjustment after it.
  PowerAdjustment undo() {
    if (!_heatPart.isNone) {
      hotUndoneAt = _lastThermal.index > ThermalLevel.serious.index ? _lastThermal : ThermalLevel.serious;
    } else if (!_batteryPart.isNone) {
      batteryUndone = true;
    }
    return adjustment;
  }
}

/// How the launcher tells the engine about the frame cap and frame generation: at start through
/// the environment (ANYPS5_FPS_CAP, and ANYPS5_POWER_CONTROL naming a small file), then live by
/// rewriting that file, which AnyPS5-ARM's engine reads again every half second. Upstream's
/// engine reads neither.
abstract final class EngineControl {
  static String text(PowerAdjustment adjustment) =>
      'fps_cap=${math.max(0, adjustment.frameCap)}\nframe_gen=${adjustment.pauseFrameGeneration ? 0 : 1}\n';

  static Map<String, String> environment(String file, PowerAdjustment adjustment) => {
    'ANYPS5_POWER_CONTROL': file,
    'ANYPS5_FPS_CAP': '${math.max(0, adjustment.frameCap)}',
  };

  /// Writes the file whole (through a temporary file), so the engine never reads half of it.
  static void write(PowerAdjustment adjustment, String file) {
    Directory(p.dirname(file)).createSync(recursive: true);
    final temporary = File('$file.tmp')..writeAsStringSync(text(adjustment), flush: true);
    temporary.renameSync(file);
  }
}

/// Minutes of battery left: the system's estimate where it has one, else the drain measured
/// since the computer went on battery (at least 2 % over at least 3 minutes).
class BatteryEstimate {
  (int, DateTime)? _first;
  (int, DateTime)? _last;

  void add({required int percent, required bool onBattery, required DateTime at}) {
    if (!onBattery) {
      _first = null;
      _last = null;
      return;
    }
    if (_first case (final int first, _) when percent > first) _first = null;
    _first ??= (percent, at);
    _last = (percent, at);
  }

  int? minutesLeft({int? system}) {
    if (system != null && system > 0) return system;
    final first = _first;
    final last = _last;
    if (first == null || last == null) return null;
    final dropped = first.$1 - last.$1;
    final minutes = last.$2.difference(first.$2).inMilliseconds / 60000;
    if (dropped < 2 || minutes < 3) return null;
    return (last.$1 / (dropped / minutes)).round();
  }
}

/// Reads the power on Windows and Linux.
abstract final class PowerReader {
  /// [gaming]: a game runs, so a laptop's graphics card is awake and asking it wakes nothing.
  static PowerReading current({bool gaming = false}) {
    try {
      if (Platform.isWindows) return _windows(gaming: gaming);
      if (Platform.isLinux) {
        return fromSysfs(
          powerSupply: '/sys/class/power_supply',
          thermal: '/sys/class/thermal',
          hwmon: '/sys/class/hwmon',
          platformProfile: '/sys/firmware/acpi/platform_profile',
        );
      }
    } on Object {
      // Not known: as plugged in.
    }
    return const PowerReading(hasBattery: false, onBattery: false);
  }

  /// SYSTEM_POWER_STATUS: ACLineStatus (0 offline, 1 online, 255 unknown), BatteryFlag (128 no
  /// battery, 255 unknown), BatteryLifePercent (255 unknown), SystemStatusFlag (1 battery saver),
  /// BatteryLifeTime in seconds (0xFFFFFFFF unknown). The heat, [thermal], is WindowsHeat's.
  static PowerReading fromWindowsStatus({
    required int acLine,
    required int batteryFlag,
    required int percent,
    int systemStatus = 0,
    int lifeSeconds = 0xFFFFFFFF,
    ThermalLevel? thermal,
  }) {
    final hasBattery = batteryFlag != 128 && batteryFlag != 255;
    final onBattery = hasBattery && acLine == 0;
    return PowerReading(
      hasBattery: hasBattery,
      onBattery: onBattery,
      batteryPercent: hasBattery && percent != 255 ? percent.clamp(0, 100) : null,
      minutesToEmpty: onBattery && lifeSeconds != 0xFFFFFFFF && lifeSeconds > 0 ? lifeSeconds ~/ 60 : null,
      thermal: thermal,
      lowPowerMode: systemStatus == 1,
    );
  }

  static PowerReading _windows({required bool gaming}) {
    final kernel = DynamicLibrary.open('kernel32.dll');
    final status = kernel.lookupFunction<Int32 Function(Pointer<Uint8>), int Function(Pointer<Uint8>)>(
      'GetSystemPowerStatus',
    );
    final buffer = calloc<Uint8>(12);
    try {
      if (status(buffer) == 0) return const PowerReading(hasBattery: false, onBattery: false);
      final life = buffer[4] | buffer[5] << 8 | buffer[6] << 16 | buffer[7] << 24;
      final hasBattery = buffer[1] != 128 && buffer[1] != 255;
      ThermalLevel? thermal;
      try {
        // A desktop's card is always awake; a laptop's is asked only while a game runs.
        thermal = WindowsHeat.instance.level(graphics: gaming || !hasBattery);
      } on Object {
        // Not read.
      }
      return fromWindowsStatus(
        acLine: buffer[0],
        batteryFlag: buffer[1],
        percent: buffer[2],
        systemStatus: buffer[3],
        lifeSeconds: life,
        thermal: thermal,
      );
    } finally {
      calloc.free(buffer);
    }
  }

  /// The power from Linux's folders: a mains or USB supply online means plugged in; else a
  /// battery discharging is on battery. The minutes left from energy or charge over the draw.
  /// The heat from the CPU's thermal zones (or its hwmon sensor), against the zone's own trip
  /// points where it has them; null without any. Battery saver is the low-power platform
  /// profile.
  static PowerReading fromSysfs({
    required String powerSupply,
    required String thermal,
    required String hwmon,
    required String platformProfile,
  }) {
    var hasBattery = false;
    var plugged = false;
    var discharging = false;
    int? level;
    int? minutes;
    final supplies = Directory(powerSupply);
    if (supplies.existsSync()) {
      for (final entry in supplies.listSync()) {
        String read(String name) => _read(p.join(entry.path, name));
        final type = read('type');
        if (type == 'Mains' || type == 'USB' || type == 'USB_C' || type == 'USB_PD') {
          if (read('online') == '1') plugged = true;
        } else if (type == 'Battery') {
          // A peripheral's battery (a mouse, a pad) says scope=Device: not the computer's.
          if (read('scope') == 'Device') continue;
          hasBattery = true;
          if (read('status') == 'Discharging') discharging = true;
          final capacity = int.tryParse(read('capacity'));
          if (capacity != null && (level == null || capacity > level)) level = capacity;
          final energy = int.tryParse(read('energy_now')) ?? int.tryParse(read('charge_now'));
          final draw = int.tryParse(read('power_now')) ?? int.tryParse(read('current_now'));
          if (energy != null && draw != null && draw > 0) minutes = energy * 60 ~/ draw;
        }
      }
    }
    final onBattery = hasBattery && !plugged && discharging;
    return PowerReading(
      hasBattery: hasBattery,
      onBattery: onBattery,
      batteryPercent: hasBattery ? level : null,
      minutesToEmpty: onBattery ? minutes : null,
      thermal: thermalLevel(thermal: thermal, hwmon: hwmon),
      lowPowerMode: _read(platformProfile) == 'low-power',
    );
  }

  /// The zones that are the processor's (or the whole board's, on a laptop whose ACPI zone is
  /// its only one); a GPU's, a battery's or a Wi-Fi card's say nothing about the processor.
  static final _cpuZone = RegExp(r'x86_pkg_temp|cpu|soc|tctl|k10temp|coretemp|acpitz|zenpower', caseSensitive: false);
  static final _cpuSensor = RegExp(r'^(coretemp|k10temp|zenpower|cpu_thermal|soc_thermal|acpitz)$');

  /// How warm the processor is: fair from 75 °C, serious from 85 °C (or 15° below the zone's
  /// critical trip, whichever is lower), critical from 95 °C (or 5° below that trip); null when
  /// no sensor is there.
  static ThermalLevel? thermalLevel({required String thermal, required String hwmon}) {
    final readings = <(double, double?)>[];
    final zones = Directory(thermal);
    if (zones.existsSync()) {
      for (final zone in zones.listSync().where((entry) => p.basename(entry.path).startsWith('thermal_zone'))) {
        if (!_cpuZone.hasMatch(_read(p.join(zone.path, 'type')))) continue;
        final millis = int.tryParse(_read(p.join(zone.path, 'temp')));
        if (millis == null || millis <= 0) continue;
        double? critical;
        for (var trip = 0; trip < 16; trip++) {
          final type = _read(p.join(zone.path, 'trip_point_${trip}_type'));
          if (type.isEmpty) break;
          final at = int.tryParse(_read(p.join(zone.path, 'trip_point_${trip}_temp')));
          if (type == 'critical' && at != null && at > 0) critical = at / 1000;
        }
        readings.add((millis / 1000, critical));
      }
    }
    if (readings.isEmpty) {
      final sensors = Directory(hwmon);
      if (sensors.existsSync()) {
        for (final sensor in sensors.listSync()) {
          if (!_cpuSensor.hasMatch(_read(p.join(sensor.path, 'name')))) continue;
          for (var index = 1; index < 32; index++) {
            final millis = int.tryParse(_read(p.join(sensor.path, 'temp${index}_input')));
            if (millis == null) continue;
            final critical = int.tryParse(_read(p.join(sensor.path, 'temp${index}_crit')));
            if (millis > 0) readings.add((millis / 1000, critical != null && critical > 0 ? critical / 1000 : null));
          }
        }
      }
    }
    if (readings.isEmpty) return null;
    var level = ThermalLevel.nominal;
    for (final (celsius, critical) in readings) {
      final here = processorLevel(celsius, critical: critical);
      if (here.index > level.index) level = here;
    }
    return level;
  }

  /// A processor or a board's thermal zone: fair from 75 °C, serious from 85 °C (or 15° below
  /// the zone's [critical] trip, whichever is lower), critical from 95 °C (or 5° below it). A
  /// laptop's processor works at 80 to 90 °C under load and its makers set it to slow itself at
  /// about 100 °C: serious is where that is near, critical where it is close.
  static ThermalLevel processorLevel(double celsius, {double? critical}) {
    final seriousAt = critical == null ? 85.0 : math.min(85.0, critical - 15);
    final criticalAt = critical == null ? 95.0 : math.min(95.0, critical - 5);
    return celsius >= criticalAt
        ? ThermalLevel.critical
        : celsius >= seriousAt
        ? ThermalLevel.serious
        : celsius >= 75
        ? ThermalLevel.fair
        : ThermalLevel.nominal;
  }

  /// A graphics card's temperature, which runs cooler than a processor's: fair from 75 °C,
  /// serious from 85 °C (or 5° below the card's own [slowdown] temperature, whichever is lower),
  /// critical from 92 °C (or at the slowdown). A card in a game runs at 65 to 80 °C; GeForce
  /// cards' boost aims at about 83 °C and gives up clocks above it, and the slowdown temperature
  /// NVML reports, where the card cuts its clocks hard, lies above that.
  static ThermalLevel graphicsLevel(double celsius, {double? slowdown}) {
    final seriousAt = slowdown == null ? 85.0 : math.min(85.0, slowdown - 5);
    final criticalAt = slowdown == null ? 92.0 : math.min(92.0, slowdown);
    return celsius >= criticalAt
        ? ThermalLevel.critical
        : celsius >= seriousAt
        ? ThermalLevel.serious
        : celsius >= 75
        ? ThermalLevel.fair
        : ThermalLevel.nominal;
  }

  static String _read(String path) {
    try {
      return File(path).readAsStringSync().trim();
    } on FileSystemException {
      return '';
    }
  }
}
