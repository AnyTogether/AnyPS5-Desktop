import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import 'power_profiles.dart';

// The heat on Windows, for Settings › Battery & Heat (power_profiles.dart). Windows tells programs
// without administrator rights little: the graphics card's temperature comes from its vendor's
// library, which the driver installs (NVIDIA's nvml.dll, AMD's atiadlxx.dll), and the ACPI
// thermal zones from the "Thermal Zone Information" performance counters. Where those give no
// zone, the user can turn on a small reader that runs with administrator rights (Windows asks
// through its own prompt): PowerShell reading root/wmi's MSAcpi_ThermalZoneTemperature every five
// seconds and leaving it in a volatile registry key only administrators can write, which the
// launcher reads. The launcher itself never runs elevated and no driver is installed. Every part
// is optional: a library that is not there, or a call that fails, reads nothing.

/// One temperature Windows gave, in °C: the graphics card's or an ACPI thermal zone's, with the
/// limit its own hardware names (the card's slowdown temperature, the zone's critical trip point),
/// null where it names none.
class HeatSensor {
  const HeatSensor.graphics(this.celsius, {this.limit}) : graphics = true;
  const HeatSensor.zone(this.celsius, {this.limit}) : graphics = false;

  final bool graphics;
  final double celsius;
  final double? limit;

  /// A reading outside 5 to 149 °C is a sensor that is not there: a zone left at 0 K or 0 °C
  /// by its firmware, a card that answers 0.
  bool get plausible => celsius >= 5 && celsius < 150;

  ThermalLevel get level => graphics
      ? PowerReader.graphicsLevel(celsius, slowdown: limit)
      : PowerReader.processorLevel(celsius, critical: limit);

  @override
  bool operator ==(Object other) =>
      other is HeatSensor && other.graphics == graphics && other.celsius == celsius && other.limit == limit;

  @override
  int get hashCode => Object.hash(graphics, celsius, limit);

  @override
  String toString() => '${graphics ? 'graphics' : 'zone'} $celsius °C${limit == null ? '' : ' (limit $limit)'}';
}

/// Where the reader with administrator rights is.
enum HeatReaderState {
  /// Not asked for.
  off,

  /// Windows' prompt is up.
  asking,

  /// Running, with a zone to read.
  running,

  /// Running, but the computer gives Windows no zone either.
  empty,

  /// The user said no at the prompt, or Windows could not start it.
  declined,

  /// It stopped on its own (its last reading is old).
  stopped,
}

/// What Settings › Battery & Heat needs from the heat on Windows; tests give their own.
abstract class WindowsHeatSource {
  /// A graphics card's library gave a temperature.
  bool get graphicsFound;

  /// A thermal zone was read without administrator rights: the reader is not needed.
  bool get zonesWithoutAdmin;

  HeatReaderState get readerState;

  /// Asks Windows for administrator rights and starts the reader; whether it started.
  Future<bool> startReader({required String stopFile});

  void stopReader({required String stopFile});
}

/// The heat on Windows, read every few seconds by PowerReader.
class WindowsHeat implements WindowsHeatSource {
  WindowsHeat._();

  static final instance = WindowsHeat._();

  /// A reading of the reader older than this means it stopped.
  static const readerStale = Duration(seconds: 20);

  /// Where the reader leaves its readings: a volatile key (gone at the next restart) under
  /// HKEY_LOCAL_MACHINE, which every user can read and only administrators can write, so nothing
  /// without the rights can write there or point the reader somewhere else.
  static const readerKey = r'SOFTWARE\AnyPS5HeatReader';
  static const readerValue = 'Readings';

  _Nvml? _nvml;
  _Adl? _adl;
  _PdhZones? _zones;
  bool _loaded = false;
  bool _graphicsProbed = false;
  DateTime? _readerStarted;

  @override
  bool graphicsFound = false;

  @override
  bool zonesWithoutAdmin = false;

  @override
  HeatReaderState readerState = HeatReaderState.off;

  /// The level of everything read now; null when nothing could be. [graphics] false leaves the
  /// graphics card alone after the first look: on a laptop a card that sleeps between games
  /// would be woken by the question.
  ThermalLevel? level({required bool graphics}) => levelOf(read(graphics: graphics, now: DateTime.now()));

  /// The hottest of [sensors] that are plausible, null without any.
  static ThermalLevel? levelOf(Iterable<HeatSensor> sensors) {
    ThermalLevel? level;
    for (final sensor in sensors.where((sensor) => sensor.plausible)) {
      final here = sensor.level;
      if (level == null || here.index > level.index) level = here;
    }
    return level;
  }

  List<HeatSensor> read({required bool graphics, required DateTime now}) {
    if (!Platform.isWindows) return const [];
    if (!_loaded) {
      _loaded = true;
      _nvml = _guard(_Nvml.load);
      _adl = _guard(_Adl.load);
      _zones = _guard(_PdhZones.open);
    }
    final sensors = <HeatSensor>[];
    if (graphics || !_graphicsProbed) {
      _graphicsProbed = true;
      for (final source in [_nvml?.read, _adl?.read]) {
        if (source == null) continue;
        final found = _guard(source) ?? const <HeatSensor>[];
        sensors.addAll(found);
        if (found.any((sensor) => sensor.plausible)) graphicsFound = true;
      }
    }
    final zones = (_guard(() => _zones?.read()) ?? const <HeatSensor>[]).where((zone) => zone.plausible).toList();
    if (zones.isNotEmpty) zonesWithoutAdmin = true;
    sensors.addAll(zones);
    if (readerState == HeatReaderState.running || readerState == HeatReaderState.empty) {
      final report = ReaderReport.parse(_guard(_readReaderKey) ?? '', now);
      if (report.fresh) {
        readerState = report.zones.isEmpty ? HeatReaderState.empty : HeatReaderState.running;
        sensors.addAll(report.zones);
      } else if (now.difference(_readerStarted ?? now) > readerStale) {
        readerState = HeatReaderState.stopped;
      }
    }
    return sensors;
  }

  @override
  Future<bool> startReader({required String stopFile}) async {
    if (!Platform.isWindows) return false;
    switch (readerState) {
      case HeatReaderState.asking:
        return false;
      case HeatReaderState.running || HeatReaderState.empty:
        return true;
      case HeatReaderState.off || HeatReaderState.declined || HeatReaderState.stopped:
        break;
    }
    readerState = HeatReaderState.asking;
    try {
      File(stopFile).deleteSync();
    } on FileSystemException {
      // Not there.
    }
    final arguments = readerArguments(readerScript(parent: pid, stopFile: stopFile));
    final powershell = windowsPowerShell(Platform.environment);
    bool started;
    try {
      // Off the interface's thread: ShellExecuteExW waits for the user's answer at the prompt.
      started = await _elevated(powershell, arguments);
    } on Object {
      started = false;
    }
    if (readerState != HeatReaderState.asking) return started; // Turned off meanwhile.
    if (!started) {
      readerState = HeatReaderState.declined;
      return false;
    }
    _readerStarted = DateTime.now();
    readerState = HeatReaderState.running;
    return true;
  }

  @override
  void stopReader({required String stopFile}) {
    readerState = HeatReaderState.off;
    _readerStarted = null;
    try {
      // The reader looks for this file between readings and ends; it never writes or deletes it.
      File(stopFile)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('stop\n');
    } on FileSystemException {
      // It still ends with the launcher.
    }
  }

  /// [file] started with administrator rights on an isolate of its own, which carries nothing
  /// but the two texts.
  static Future<bool> _elevated(String file, String arguments) => Isolate.run(() => _runElevated(file, arguments));

  /// Windows' own PowerShell, by its full path: what runs elevated never comes from a folder
  /// the user can write.
  static String windowsPowerShell(Map<String, String> environment) => p.windows.join(
    environment['SystemRoot'] ?? r'C:\Windows',
    'System32',
    'WindowsPowerShell',
    'v1.0',
    'powershell.exe',
  );

  static String readerArguments(String script) =>
      '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand ${encodeCommand(script)}';

  /// PowerShell's -EncodedCommand: the script as UTF-16LE in Base64.
  static String encodeCommand(String script) => base64.encode([
    for (final unit in script.codeUnits) ...[unit & 0xff, unit >> 8],
  ]);

  /// The reader: every five seconds the ACPI thermal zones Windows reads with administrator
  /// rights, as lines in [readerKey]; it ends when the launcher ([parent]) does or [stopFile]
  /// appears, and takes its key with it. The stop file's path goes in as Base64, so no character
  /// in a user's folder name is read as PowerShell.
  static String readerScript({required int parent, required String stopFile}) {
    final stop = encodeCommand(stopFile);
    return '''
\$ErrorActionPreference = 'SilentlyContinue'
\$parent = Get-Process -Id $parent
if (-not \$parent) { exit }
\$stop = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('$stop'))
\$name = '$readerKey'
try {
  while (-not (Test-Path -LiteralPath \$stop)) {
    \$lines = @('anyps5-heat 1', "time \$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())")
    foreach (\$zone in @(Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature)) {
      \$lines += "zone \$([int]\$zone.CurrentTemperature) \$([int]\$zone.CriticalTripPoint)"
    }
    \$key = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey(\$name, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, [Microsoft.Win32.RegistryOptions]::Volatile)
    if (\$key) { \$key.SetValue('$readerValue', (\$lines -join "`n")); \$key.Close() }
    if (\$parent.WaitForExit(5000)) { break }
  }
} finally {
  [Microsoft.Win32.Registry]::LocalMachine.DeleteSubKey(\$name, \$false)
}
''';
  }

  static T? _guard<T>(T? Function() read) {
    try {
      return read();
    } on Object {
      return null;
    }
  }
}

/// What the reader left: fresh when its time is within [WindowsHeat.readerStale] of now, and its
/// zones (tenths of a kelvin, the critical trip 0 when the zone names none).
class ReaderReport {
  const ReaderReport({required this.fresh, this.zones = const []});

  static const none = ReaderReport(fresh: false);

  final bool fresh;
  final List<HeatSensor> zones;

  static ReaderReport parse(String text, DateTime now) {
    final lines = const LineSplitter().convert(text).map((line) => line.trim().split(RegExp(r'\s+'))).toList();
    if (lines.isEmpty || lines.first.join(' ') != 'anyps5-heat 1') return none;
    int? time;
    final zones = <HeatSensor>[];
    for (final words in lines.skip(1)) {
      if (words.length == 2 && words[0] == 'time') time = int.tryParse(words[1]);
      if (words.length >= 2 && words[0] == 'zone') {
        final tenths = int.tryParse(words[1]);
        if (tenths == null) continue;
        final critical = words.length > 2 ? int.tryParse(words[2]) : null;
        final zone = HeatSensor.zone(_celsius(tenths), limit: critical == null ? null : _limit(_celsius(critical)));
        if (zone.plausible) zones.add(zone);
      }
    }
    if (time == null) return none;
    final age = now.difference(DateTime.fromMillisecondsSinceEpoch(time * 1000, isUtc: true)).abs();
    if (age > WindowsHeat.readerStale) return none;
    return ReaderReport(fresh: true, zones: zones);
  }

  static double _celsius(int tenthsOfKelvin) => tenthsOfKelvin / 10 - 273.15;

  /// A trip point outside 40 to 150 °C is firmware that left it unset.
  static double? _limit(double celsius) => celsius >= 40 && celsius <= 150 ? celsius : null;
}

// NVIDIA: nvml.dll, in System32 with the DCH driver, else in the NVSMI folder.

typedef _NvmlCall = Int32 Function();
typedef _NvmlCount = Int32 Function(Pointer<Uint32>);
typedef _NvmlHandle = Int32 Function(Uint32, Pointer<Pointer<Void>>);
typedef _NvmlTemperature = Int32 Function(Pointer<Void>, Int32, Pointer<Uint32>);

final class _Nvml {
  _Nvml(DynamicLibrary library)
    : _count = library.lookupFunction<_NvmlCount, int Function(Pointer<Uint32>)>('nvmlDeviceGetCount_v2'),
      _handle = library.lookupFunction<_NvmlHandle, int Function(int, Pointer<Pointer<Void>>)>(
        'nvmlDeviceGetHandleByIndex_v2',
      ),
      _temperature = library.lookupFunction<_NvmlTemperature, int Function(Pointer<Void>, int, Pointer<Uint32>)>(
        'nvmlDeviceGetTemperature',
      ),
      _threshold = library.lookupFunction<_NvmlTemperature, int Function(Pointer<Void>, int, Pointer<Uint32>)>(
        'nvmlDeviceGetTemperatureThreshold',
      );

  static const _gpu = 0; // NVML_TEMPERATURE_GPU
  static const _slowdown = 1; // NVML_TEMPERATURE_THRESHOLD_SLOWDOWN

  final int Function(Pointer<Uint32>) _count;
  final int Function(int, Pointer<Pointer<Void>>) _handle;
  final int Function(Pointer<Void>, int, Pointer<Uint32>) _temperature;
  final int Function(Pointer<Void>, int, Pointer<Uint32>) _threshold;
  final Map<int, double?> _slowdowns = {};

  static _Nvml? load() {
    final environment = Platform.environment;
    final root = environment['SystemRoot'] ?? r'C:\Windows';
    final programs = environment['ProgramW6432'] ?? environment['ProgramFiles'] ?? r'C:\Program Files';
    for (final path in [
      p.windows.join(root, 'System32', 'nvml.dll'),
      p.windows.join(programs, 'NVIDIA Corporation', 'NVSMI', 'nvml.dll'),
    ]) {
      if (!File(path).existsSync()) continue;
      try {
        final library = DynamicLibrary.open(path);
        final init = library.lookupFunction<_NvmlCall, int Function()>('nvmlInit_v2');
        if (init() == 0) return _Nvml(library);
      } on Object {
        // The next place.
      }
    }
    return null;
  }

  List<HeatSensor> read() => using((arena) {
    final count = arena<Uint32>();
    if (_count(count) != 0) return const <HeatSensor>[];
    final device = arena<Pointer<Void>>();
    final value = arena<Uint32>();
    final sensors = <HeatSensor>[];
    for (var index = 0; index < count.value && index < 16; index++) {
      if (_handle(index, device) != 0 || _temperature(device.value, _gpu, value) != 0) continue;
      final celsius = value.value.toDouble();
      final slowdown = _slowdowns.putIfAbsent(index, () {
        if (_threshold(device.value, _slowdown, value) != 0) return null;
        final limit = value.value.toDouble();
        return limit >= 60 && limit <= 130 ? limit : null;
      });
      sensors.add(HeatSensor.graphics(celsius, limit: slowdown));
    }
    return sensors;
  });
}

// AMD: atiadlxx.dll in System32, through ADL2 (Overdrive 8's PM log, Overdrive N or 5 before it).

typedef _AdlAlloc = Pointer<Void> Function(Int32);
typedef _AdlCreate = Int32 Function(Pointer<NativeFunction<_AdlAlloc>>, Int32, Pointer<Pointer<Void>>);
typedef _AdlIntOut = Int32 Function(Pointer<Void>, Pointer<Int32>);
typedef _AdlInfo = Int32 Function(Pointer<Void>, Pointer<Uint8>, Int32);
typedef _AdlCaps = Int32 Function(Pointer<Void>, Int32, Pointer<Int32>, Pointer<Int32>, Pointer<Int32>);
typedef _AdlLog = Int32 Function(Pointer<Void>, Int32, Pointer<Uint8>);
typedef _AdlOdn = Int32 Function(Pointer<Void>, Int32, Int32, Pointer<Int32>);

/// ADL asks for its memory through this; it calls it during the calls made here, on this thread.
Pointer<Void> _adlAlloc(int size) => calloc<Uint8>(size < 1 ? 1 : size).cast();

final class _Adl {
  _Adl(this._context, this._adapters, DynamicLibrary library)
    : _log = library.providesSymbol('ADL2_New_QueryPMLogData_Get')
          ? library.lookupFunction<_AdlLog, int Function(Pointer<Void>, int, Pointer<Uint8>)>(
              'ADL2_New_QueryPMLogData_Get',
            )
          : null,
      _odn = library.providesSymbol('ADL2_OverdriveN_Temperature_Get')
          ? library.lookupFunction<_AdlOdn, int Function(Pointer<Void>, int, int, Pointer<Int32>)>(
              'ADL2_OverdriveN_Temperature_Get',
            )
          : null,
      _od5 = library.providesSymbol('ADL2_Overdrive5_Temperature_Get')
          ? library.lookupFunction<_AdlOdn, int Function(Pointer<Void>, int, int, Pointer<Int32>)>(
              'ADL2_Overdrive5_Temperature_Get',
            )
          : null;

  /// AdapterInfo on Windows: 1572 bytes; iAdapterIndex at 4, iBusNumber at 264, iDeviceNumber
  /// at 268, iVendorID at 276 (adl_structures.h).
  static const _infoSize = 1572;
  static const _amd = 0x1002;

  /// ADLPMLogDataOutput: int size, then 256 sensors of {int supported, int value}.
  static const _logSize = 4 + 256 * 8;
  static const _edge = 8; // PMLOG_TEMPERATURE_EDGE, °C
  static const _gfx = 28; // PMLOG_TEMPERATURE_GFX, °C

  final Pointer<Void> _context;

  /// Each card once (ADL lists one entry per output): its index and Overdrive version.
  final List<(int, int)> _adapters;
  final int Function(Pointer<Void>, int, Pointer<Uint8>)? _log;
  final int Function(Pointer<Void>, int, int, Pointer<Int32>)? _odn;
  final int Function(Pointer<Void>, int, int, Pointer<Int32>)? _od5;

  static _Adl? load() {
    final path = p.windows.join(Platform.environment['SystemRoot'] ?? r'C:\Windows', 'System32', 'atiadlxx.dll');
    if (!File(path).existsSync()) return null;
    final library = DynamicLibrary.open(path);
    final create = library
        .lookupFunction<_AdlCreate, int Function(Pointer<NativeFunction<_AdlAlloc>>, int, Pointer<Pointer<Void>>)>(
          'ADL2_Main_Control_Create',
        );
    final number = library.lookupFunction<_AdlIntOut, int Function(Pointer<Void>, Pointer<Int32>)>(
      'ADL2_Adapter_NumberOfAdapters_Get',
    );
    final info = library.lookupFunction<_AdlInfo, int Function(Pointer<Void>, Pointer<Uint8>, int)>(
      'ADL2_Adapter_AdapterInfo_Get',
    );
    final caps = library.providesSymbol('ADL2_Overdrive_Caps')
        ? library.lookupFunction<
            _AdlCaps,
            int Function(Pointer<Void>, int, Pointer<Int32>, Pointer<Int32>, Pointer<Int32>)
          >('ADL2_Overdrive_Caps')
        : null;
    final context = calloc<Pointer<Void>>();
    try {
      if (create(Pointer.fromFunction<_AdlAlloc>(_adlAlloc), 1, context) != 0) return null;
      return using((arena) {
        final count = arena<Int32>();
        if (number(context.value, count) != 0 || count.value <= 0 || count.value > 64) return null;
        final buffer = arena<Uint8>(_infoSize * count.value);
        if (info(context.value, buffer, _infoSize * count.value) != 0) return null;
        final view = _Bytes(buffer, _infoSize * count.value);
        final seen = <(int, int)>{};
        final adapters = <(int, int)>[];
        for (var entry = 0; entry < count.value; entry++) {
          final at = entry * _infoSize;
          final index = view.int32(at + 4);
          final bus = view.int32(at + 264);
          final device = view.int32(at + 268);
          final vendor = view.int32(at + 276);
          if (vendor != _amd || bus < 0 || !seen.add((bus, device))) continue;
          var version = 0;
          if (caps != null) {
            final supported = arena<Int32>();
            final enabled = arena<Int32>();
            final found = arena<Int32>();
            if (caps(context.value, index, supported, enabled, found) == 0) version = found.value;
          }
          adapters.add((index, version));
        }
        return adapters.isEmpty ? null : _Adl(context.value, adapters, library);
      });
    } finally {
      calloc.free(context);
    }
  }

  List<HeatSensor> read() => using((arena) {
    final sensors = <HeatSensor>[];
    final log = arena<Uint8>(_logSize);
    final value = arena<Int32>();
    for (final (index, version) in _adapters) {
      double? celsius;
      // As AMD's samples and LibreHardwareMonitor: the PM log from Overdrive 8 on (or where
      // Overdrive says nothing), Overdrive N's edge in thousandths of a degree before it.
      if ((version >= 8 || version == 0) && _log != null) {
        log.asTypedList(_logSize).fillRange(0, _logSize, 0);
        if (_log(_context, index, log) == 0) {
          final view = _Bytes(log, _logSize);
          for (final sensor in [_edge, _gfx]) {
            final at = 4 + sensor * 8;
            if (view.int32(at) != 0 && view.int32(at + 4) > 0) {
              celsius = view.int32(at + 4).toDouble();
              break;
            }
          }
        }
      }
      if (celsius == null && version == 7 && _odn != null && _odn(_context, index, 1, value) == 0) {
        celsius = value.value / 1000;
      }
      if (celsius == null && version > 0 && version < 7 && _od5 != null) {
        // ADLTemperature: {int iSize, int iTemperature}, thousandths of a degree.
        final temperature = arena<Int32>(2)..[0] = 8;
        if (_od5(_context, index, 0, temperature) == 0) celsius = temperature[1] / 1000;
      }
      if (celsius != null) sensors.add(HeatSensor.graphics(celsius));
    }
    return sensors;
  });
}

/// Little-endian ints out of native memory.
final class _Bytes {
  _Bytes(Pointer<Uint8> pointer, int length) : _data = ByteData.sublistView(pointer.asTypedList(length));

  final ByteData _data;

  int int32(int offset) => _data.getInt32(offset, Endian.little);
}

// The ACPI thermal zones through the performance counters, which Windows gives every user of an
// interactive session (the "Thermal Zone Information" counter set, Temperature in kelvin).

final class _PdhValue extends Struct {
  @Uint32()
  external int status;

  @Double()
  external double value;
}

final class _PdhItem extends Struct {
  external Pointer<Utf16> name;

  external _PdhValue value;
}

typedef _PdhOpen = Uint32 Function(Pointer<Utf16>, IntPtr, Pointer<IntPtr>);
typedef _PdhAdd = Uint32 Function(IntPtr, Pointer<Utf16>, IntPtr, Pointer<IntPtr>);
typedef _PdhCollect = Uint32 Function(IntPtr);
typedef _PdhArray = Uint32 Function(IntPtr, Uint32, Pointer<Uint32>, Pointer<Uint32>, Pointer<_PdhItem>);

final class _PdhZones {
  _PdhZones(this._query, this._counter, this._collect, this._array);

  static const _double = 0x00000200; // PDH_FMT_DOUBLE
  static const _moreData = 0x800007D2; // PDH_MORE_DATA

  final int _query;
  final int _counter;
  final int Function(int) _collect;
  final int Function(int, int, Pointer<Uint32>, Pointer<Uint32>, Pointer<_PdhItem>) _array;

  static _PdhZones? open() {
    final pdh = DynamicLibrary.open('pdh.dll');
    final open = pdh.lookupFunction<_PdhOpen, int Function(Pointer<Utf16>, int, Pointer<IntPtr>)>('PdhOpenQueryW');
    final add = pdh.lookupFunction<_PdhAdd, int Function(int, Pointer<Utf16>, int, Pointer<IntPtr>)>(
      'PdhAddEnglishCounterW',
    );
    final close = pdh.lookupFunction<Uint32 Function(IntPtr), int Function(int)>('PdhCloseQuery');
    final collect = pdh.lookupFunction<_PdhCollect, int Function(int)>('PdhCollectQueryData');
    final array = pdh
        .lookupFunction<_PdhArray, int Function(int, int, Pointer<Uint32>, Pointer<Uint32>, Pointer<_PdhItem>)>(
          'PdhGetFormattedCounterArrayW',
        );
    return using((arena) {
      final query = arena<IntPtr>();
      if (open(nullptr, 0, query) != 0) return null;
      final counter = arena<IntPtr>();
      final path = r'\Thermal Zone Information(*)\Temperature'.toNativeUtf16(allocator: arena);
      if (add(query.value, path, 0, counter) != 0) {
        close(query.value);
        return null;
      }
      return _PdhZones(query.value, counter.value, collect, array);
    });
  }

  List<HeatSensor> read() => using((arena) {
    if (_collect(_query) != 0) return const <HeatSensor>[];
    final size = arena<Uint32>();
    final count = arena<Uint32>();
    if (_array(_counter, _double, size, count, nullptr) != _moreData || size.value == 0) {
      return const <HeatSensor>[];
    }
    final items = arena<Uint8>(size.value).cast<_PdhItem>();
    if (_array(_counter, _double, size, count, items) != 0) return const <HeatSensor>[];
    return [
      for (var index = 0; index < count.value; index++)
        // PDH_CSTATUS_VALID_DATA or PDH_CSTATUS_NEW_DATA.
        if (items[index].value.status <= 1) HeatSensor.zone(items[index].value.value - 273.15),
    ];
  });
}

// Starting the reader with administrator rights: ShellExecuteExW with the "runas" verb, which
// brings up Windows' prompt and fails when the user says no.

final class _ShellExecuteInfo extends Struct {
  @Uint32()
  external int cbSize;

  @Uint32()
  external int fMask;

  external Pointer<Void> hwnd;
  external Pointer<Utf16> lpVerb;
  external Pointer<Utf16> lpFile;
  external Pointer<Utf16> lpParameters;
  external Pointer<Utf16> lpDirectory;

  @Int32()
  external int nShow;

  external Pointer<Void> hInstApp;
  external Pointer<Void> lpIDList;
  external Pointer<Utf16> lpClass;
  external Pointer<Void> hkeyClass;

  @Uint32()
  external int dwHotKey;

  external Pointer<Void> hIconOrMonitor;
  external Pointer<Void> hProcess;
}

bool _runElevated(String file, String parameters) {
  final shell = DynamicLibrary.open('shell32.dll');
  final execute = shell
      .lookupFunction<Int32 Function(Pointer<_ShellExecuteInfo>), int Function(Pointer<_ShellExecuteInfo>)>(
        'ShellExecuteExW',
      );
  final ole = DynamicLibrary.open('ole32.dll');
  final initialize = ole.lookupFunction<Int32 Function(Pointer<Void>, Uint32), int Function(Pointer<Void>, int)>(
    'CoInitializeEx',
  );
  final uninitialize = ole.lookupFunction<Void Function(), void Function()>('CoUninitialize');
  final foreground = DynamicLibrary.open('user32.dll')
      .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>('GetForegroundWindow');
  // COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE, as ShellExecuteEx's documentation asks.
  final initialized = initialize(nullptr, 0x2 | 0x4);
  try {
    return using((arena) {
      final info = arena<_ShellExecuteInfo>();
      info.ref
        ..cbSize = sizeOf<_ShellExecuteInfo>()
        ..fMask =
            0x100 // SEE_MASK_NOASYNC
        ..hwnd = foreground()
        ..lpVerb = 'runas'.toNativeUtf16(allocator: arena)
        ..lpFile = file.toNativeUtf16(allocator: arena)
        ..lpParameters = parameters.toNativeUtf16(allocator: arena)
        ..nShow = 0; // SW_HIDE
      return execute(info) != 0;
    });
  } finally {
    if (initialized >= 0) uninitialize();
  }
}

/// The reader's lines from the registry, null when it has left none.
String? _readReaderKey() {
  final get = DynamicLibrary.open('advapi32.dll')
      .lookupFunction<
        Int32 Function(IntPtr, Pointer<Utf16>, Pointer<Utf16>, Uint32, Pointer<Uint32>, Pointer<Void>, Pointer<Uint32>),
        int Function(int, Pointer<Utf16>, Pointer<Utf16>, int, Pointer<Uint32>, Pointer<Void>, Pointer<Uint32>)
      >('RegGetValueW');
  // HKEY_LOCAL_MACHINE, sign-extended as Windows' headers make it; RRF_RT_REG_SZ in the 64-bit view.
  const machine = -0x7FFFFFFE;
  const flags = 0x00000002 | 0x00010000;
  return using((arena) {
    final key = WindowsHeat.readerKey.toNativeUtf16(allocator: arena);
    final value = WindowsHeat.readerValue.toNativeUtf16(allocator: arena);
    final size = arena<Uint32>();
    if (get(machine, key, value, flags, nullptr, nullptr, size) != 0 || size.value == 0 || size.value > 65536) {
      return null;
    }
    final buffer = arena<Uint8>(size.value + 2);
    if (get(machine, key, value, flags, nullptr, buffer.cast(), size) != 0) return null;
    return buffer.cast<Utf16>().toDartString();
  });
}
