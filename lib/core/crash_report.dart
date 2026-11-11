import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import 'game_log.dart';
import 'game_settings.dart';
import 'host.dart';
import 'launcher_health.dart';

/// Takes out of a report what names the user or lets someone act as them: the home folder and
/// other users' folders, the user's names and the computer's, e-mail addresses, private network
/// addresses and the AnyTogether tokens.
class ReportPrivacy {
  const ReportPrivacy({required this.home, this.names = const [], this.secrets = const []});

  /// This user's: the home folder from [environment] (USERPROFILE on Windows, HOME on Linux),
  /// the account name, and [names] (the computer's name, the AnyTogether handle) and [secrets]
  /// (the AnyTogether tokens).
  factory ReportPrivacy.current({
    required HostSystem system,
    Map<String, String>? environment,
    List<String> names = const [],
    List<String> secrets = const [],
  }) {
    final env = environment ?? Platform.environment;
    final windows = system == HostSystem.windows;
    return ReportPrivacy(
      home: (windows ? env['USERPROFILE'] : env['HOME']) ?? '',
      names: [?(windows ? env['USERNAME'] : env['USER'] ?? env['LOGNAME']), ...names],
      secrets: secrets,
    );
  }

  final String home;

  /// The account name, the computer's name, the AnyTogether handle and display name.
  final List<String> names;

  /// Values known to be secret (the AnyTogether tokens), taken out wherever they appear.
  final List<String> secrets;

  static const _keys =
      'access_?token|refresh_?token|relay_?token|session_?token|id_?token|token|secret|password|passwd|api_?key';

  static final _rules = <(RegExp, String Function(Match))>[
    (RegExp(r'eyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}'), (_) => '<token>'),
    (RegExp(r'\bbearer\s+[A-Za-z0-9._~+/=-]{6,}', caseSensitive: false), (_) => 'Bearer <token>'),
    (
      RegExp('("?\\b(?:$_keys)\\b"?\\s*[:=]\\s*"?)([^\\s"\',;&]{4,})', caseSensitive: false),
      (match) => '${match[1]}<redacted>',
    ),
    (RegExp(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'), (_) => '<email>'),
    (
      RegExp(r'\b(?:192\.168(?:\.\d{1,3}){2}|172\.(?:1[6-9]|2\d|3[01])(?:\.\d{1,3}){2}|10(?:\.\d{1,3}){3})\b'),
      (_) => '<ip>',
    ),
  ];

  /// Where a path's folder name ends.
  static const _end = r'''[\\/\s"':,;)\]}>]''';

  static final _windowsUsers = RegExp(
    r'''\b([A-Za-z]:[\\/]+Users[\\/]+)(?!(?:Public|Default|Default User|All Users)(?:[\\/"':,;)\]}>\s]|$))[^\\/"':,;)\]}>\r\n]+''',
    caseSensitive: false,
  );
  static final _linuxUsers = RegExp(r'''/home/[^/\s"':,;)\]}>]+''');

  String clean(String text) {
    var out = text;
    for (final secret in secrets) {
      if (secret.length >= 6) out = out.replaceAll(secret, '<redacted>');
    }
    for (final (expression, replace) in _rules) {
      out = out.replaceAllMapped(expression, replace);
    }
    final parts = home.split(RegExp(r'[\\/]+')).where((part) => part.isNotEmpty).toList();
    if (parts.isNotEmpty && home.length > 1) {
      final windows = RegExp(r'^[A-Za-z]:').hasMatch(home) || home.contains(r'\');
      final start = home.startsWith('/') ? r'[\\/]+' : '';
      final pattern = '$start${parts.map(RegExp.escape).join(r'[\\/]+')}(?!(?!$_end).)';
      out = out.replaceAll(RegExp(pattern, caseSensitive: !windows), '~');
    }
    out = out.replaceAllMapped(_windowsUsers, (match) => '${match[1]}<user>');
    out = out.replaceAll(_linuxUsers, '/home/<user>');
    // The longest first, so "Ada Lovelace" goes before "Ada"; a word that only holds a name stays.
    final variants = <String>{
      for (final name in names)
        for (final variant in [
          name.trim(),
          name.trim().replaceAll(' ', '-'),
          name.trim().replaceAll(' ', '_'),
          name.trim().replaceAll(' ', ''),
        ])
          if (variant.length >= 3) variant,
    }.toList()..sort((a, b) => b.length.compareTo(a.length));
    for (final name in variants) {
      out = out.replaceAll(
        RegExp('(?<![A-Za-z0-9])${RegExp.escape(name)}(?![A-Za-z0-9])', caseSensitive: false),
        '<user>',
      );
    }
    return out;
  }
}

/// The computer a report comes from. The GPU is read from the game's log, where the engine names
/// the one it chose.
class SystemInfo {
  const SystemInfo({required this.os, this.cpu, this.memoryGB, this.gpu});

  /// "Windows 11 Pro 24H2 (Build 26100.4351)", "Ubuntu 24.04.1 LTS, kernel 6.8.0-45-generic".
  final String os;
  final String? cpu;
  final int? memoryGB;
  final String? gpu;

  SystemInfo withGpu(String? gpu) => SystemInfo(os: os, cpu: cpu, memoryGB: memoryGB, gpu: gpu ?? this.gpu);

  /// "Windows 11 Pro 24H2 (Build 26100.4351) · AMD Ryzen 7 5800X · 32 GB · NVIDIA GeForce RTX 3070".
  String get line => [os, ?cpu, if (memoryGB != null) '$memoryGB GB', ?gpu].join(' · ');

  /// This computer, read from /etc/os-release and /proc on Linux, the registry and
  /// GlobalMemoryStatusEx on Windows; what cannot be read is left out.
  static Future<SystemInfo> current(HostSystem system, {Map<String, String>? environment}) async {
    final env = environment ?? Platform.environment;
    if (system == HostSystem.windows) {
      Future<Map<String, String>> query(String key) async {
        try {
          final result = await Process.run('reg', ['query', key]).timeout(const Duration(seconds: 3));
          return registryValues('${result.stdout}');
        } on Object {
          return const {};
        }
      }

      final version = await query(r'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion');
      final processor = await query(r'HKLM\HARDWARE\DESCRIPTION\System\CentralProcessor\0');
      return SystemInfo(
        os: windowsName(
          Platform.operatingSystemVersion,
          // ReleaseId (2009 and earlier) before Windows 10 20H2 had DisplayVersion.
          displayVersion: version['DisplayVersion'] ?? version['ReleaseId'],
          revision: registryNumber(version['UBR']),
        ),
        cpu: processor['ProcessorNameString']?.trim() ?? env['PROCESSOR_IDENTIFIER'],
        memoryGB: _windowsMemory(),
      );
    }
    String? read(String path) {
      try {
        return File(path).readAsStringSync();
      } on FileSystemException {
        return null;
      }
    }

    // /etc/os-release, or the vendor's copy it usually links to.
    final pretty = osReleaseName(read('/etc/os-release') ?? read('/usr/lib/os-release') ?? '');
    final kernel = read('/proc/sys/kernel/osrelease')?.trim();
    final cpu = RegExp(r'^model name\s*:\s*(.+)$', multiLine: true).firstMatch(read('/proc/cpuinfo') ?? '')?.group(1);
    final kb = RegExp(r'^MemTotal:\s+(\d+) kB', multiLine: true).firstMatch(read('/proc/meminfo') ?? '')?.group(1);
    return SystemInfo(
      os: [pretty ?? 'Linux', if (kernel != null && kernel.isNotEmpty) 'kernel $kernel'].join(', '),
      cpu: cpu?.trim(),
      memoryGB: kb == null ? null : (int.parse(kb) / 1048576).round(),
    );
  }

  /// "Windows 11 Home 25H2 (Build 26200.6899)" from Dart's operating system version
  /// ('"Windows 10 Home" 10.0 (Build 26200)', read from the registry's ProductName, which still
  /// says Windows 10 on Windows 11): 11 from build 22000 on, with [displayVersion] (25H2) and
  /// the update revision (UBR) when known.
  static String windowsName(String dartVersion, {String? displayVersion, int? revision}) {
    final text = dartVersion.replaceAll('"', '').trim();
    final build = int.tryParse(RegExp(r'Build (\d+)').firstMatch(text)?.group(1) ?? '');
    var product = text.replaceFirst(RegExp(r'\s*\d+\.\d+(\.\d+)?\s*\(Build \d+\)\s*$'), '').trim();
    if (product.isEmpty) product = 'Windows';
    if (build != null && build >= 22000) product = product.replaceFirst('Windows 10', 'Windows 11');
    final shown = displayVersion?.trim();
    return [
      product,
      if (shown != null && shown.isNotEmpty) shown,
      if (build != null) '(Build $build${revision == null ? '' : '.$revision'})',
    ].join(' ');
  }

  /// The values `reg query <key>` printed, by name ("    UBR    REG_DWORD    0x1aeb").
  static Map<String, String> registryValues(String output) => {
    for (final match in RegExp(r'^\s+(\S+)\s+REG_\w+\s+(.*?)\s*$', multiLine: true).allMatches(output))
      match[1]!: match[2]!,
  };

  /// A REG_DWORD as reg prints it (0x1aeb), or a plain number.
  static int? registryNumber(String? value) {
    if (value == null) return null;
    final text = value.trim().toLowerCase();
    return text.startsWith('0x') ? int.tryParse(text.substring(2), radix: 16) : int.tryParse(text);
  }

  /// The distribution's name from an os-release file: PRETTY_NAME, else NAME and VERSION_ID (or
  /// VERSION); values in double or single quotes or none, with shell escapes.
  static String? osReleaseName(String release) {
    final values = <String, String>{};
    for (final line in const LineSplitter().convert(release)) {
      final match = RegExp(r'^\s*([A-Z_][A-Z0-9_]*)=(.*)$').firstMatch(line);
      if (match == null) continue;
      var value = match[2]!.trim();
      if (value.length >= 2 && value.startsWith("'") && value.endsWith("'")) {
        value = value.substring(1, value.length - 1);
      } else {
        if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
          value = value.substring(1, value.length - 1);
        }
        value = value.replaceAllMapped(RegExp(r'\\(.)'), (escaped) => escaped[1]!);
      }
      values[match[1]!] = value.trim();
    }
    final pretty = values['PRETTY_NAME'];
    if (pretty != null && pretty.isNotEmpty) return pretty;
    final name = values['NAME'];
    if (name == null || name.isEmpty) return null;
    final version = values['VERSION_ID'] ?? values['VERSION'];
    return version == null || version.isEmpty ? name : '$name $version';
  }

  static int? _windowsMemory() {
    if (!Platform.isWindows) return null;
    final status = calloc<_MemoryStatus>();
    try {
      final call = DynamicLibrary.open('kernel32.dll')
          .lookupFunction<Int32 Function(Pointer<_MemoryStatus>), int Function(Pointer<_MemoryStatus>)>(
            'GlobalMemoryStatusEx',
          );
      status.ref.length = sizeOf<_MemoryStatus>();
      if (call(status) == 0) return null;
      return (status.ref.totalPhys / (1 << 30)).round();
    } on Object {
      return null;
    } finally {
      calloc.free(status);
    }
  }
}

/// MEMORYSTATUSEX.
final class _MemoryStatus extends Struct {
  @Uint32()
  external int length;
  @Uint32()
  external int memoryLoad;
  @Uint64()
  external int totalPhys;
  @Uint64()
  external int availPhys;
  @Uint64()
  external int totalPageFile;
  @Uint64()
  external int availPageFile;
  @Uint64()
  external int totalVirtual;
  @Uint64()
  external int availVirtual;
  @Uint64()
  external int availExtendedVirtual;
}

/// Why a game stopped, read from what its last start wrote to the log and from its exit code.
sealed class Diagnosis {
  const Diagnosis();

  /// What happened, in English for a bug report (the launcher shows its own translation).
  String get report;

  /// The reason in [session] (the log of one start) and [exitCode], null for a game that ended
  /// without a sign of trouble.
  static Diagnosis? read(String session, {int? exitCode}) {
    if (exitCode == 0) return null;
    final module = RegExp(r'error while loading shared libraries: ([^:\s]+):').firstMatch(session)?.group(1);
    if (module != null) return MissingModule(p.posix.basename(module));
    final message =
        RegExp(r'uncaught C\+\+ exception \S+ of type [^\n,]+, what\(\): ([^\n]+)').firstMatch(session)?.group(1) ??
        RegExp(r'terminating (?:due to|with) uncaught exception of type \S+?: ([^\n]+)')
            .firstMatch(session)
            ?.group(1) ??
        RegExp(r"terminate called after throwing an instance of '[^']+'\s*\n\s*what\(\):\s*([^\n]+)")
            .firstMatch(session)
            ?.group(1);
    if (message != null) return _classify(message);
    if (session.contains('VK_ERROR_DEVICE_LOST')) return const GpuLost();
    if (session.contains('VK_ERROR_OUT_OF_DEVICE_MEMORY') || session.contains('std::bad_alloc')) {
      return const OutOfMemory();
    }
    if (session.contains('[libc] abort() called')) return const Aborted();
    final fatal = RegExp(r'FATAL: unhandled exception 0x([0-9A-Fa-f]+)').allMatches(session).lastOrNull?.group(1);
    if (fatal != null) return Crashed(exceptionName(int.parse(fatal, radix: 16)) ?? 'exception 0x$fatal');
    if (exitCode == null) return null;
    final name = exceptionName(exitCode);
    return name == null ? Exited(exitCode) : Crashed(name);
  }

  static Diagnosis _classify(String message) {
    final trimmed = message.trim();
    final function = RegExp(r'^(\S+) not implemented').firstMatch(trimmed)?.group(1);
    if (function != null) return Unsupported(function);
    final lower = trimmed.toLowerCase();
    if (trimmed.contains('VK_ERROR_DEVICE_LOST') || lower.contains('device lost')) return const GpuLost();
    if (trimmed.contains('VK_ERROR_OUT_OF_DEVICE_MEMORY') || lower.contains('out of memory')) {
      return const OutOfMemory();
    }
    return EngineError(trimmed.length > 200 ? '${trimmed.substring(0, 200)}…' : trimmed);
  }

  static const _signals = {
    1: 'SIGHUP',
    2: 'SIGINT',
    3: 'SIGQUIT',
    4: 'SIGILL',
    5: 'SIGTRAP',
    6: 'SIGABRT',
    7: 'SIGBUS',
    8: 'SIGFPE',
    9: 'SIGKILL',
    11: 'SIGSEGV',
    13: 'SIGPIPE',
    15: 'SIGTERM',
  };

  static const _statuses = {
    0x80000003: 'breakpoint',
    0xC0000005: 'access violation',
    0xC0000006: 'in-page error',
    0xC0000017: 'out of memory',
    0xC000001D: 'illegal instruction',
    0xC000008E: 'float divide by zero',
    0xC0000094: 'integer divide by zero',
    0xC0000096: 'privileged instruction',
    0xC00000FD: 'stack overflow',
    0xC0000135: 'a DLL was not found',
    0xC0000142: 'a DLL failed to initialise',
    0xC0000374: 'heap corruption',
    0xC0000409: 'stack buffer overrun',
  };

  /// A Linux signal (a negative exit code, as dart:io gives it) or a Windows exception status
  /// (an exit code or the code in the engine's crash report): "SIGSEGV (signal 11)",
  /// "access violation (0xC0000005)"; null for an ordinary exit status.
  static String? exceptionName(int code) {
    if (code < 0 && code >= -64) {
      final signal = -code;
      return '${_signals[signal] ?? 'signal'} (signal $signal)';
    }
    final status = code & 0xFFFFFFFF;
    if (status < 0x80000000) return null;
    final hex = '0x${status.toRadixString(16).toUpperCase().padLeft(8, '0')}';
    final name = _statuses[status];
    if (name != null) return '$name ($hex)';
    return status >= 0xC0000000 ? 'exception $hex' : null;
  }

  /// The engine's crash report in the log: the last `FATAL: unhandled exception` line (Windows)
  /// and the indented lines under it, else the abort line.
  static List<String> crashLines(String session, {int limit = 24}) {
    final lines = const LineSplitter().convert(session);
    final start = lines.lastIndexWhere((line) => line.startsWith('FATAL: unhandled exception'));
    if (start >= 0) {
      final block = [lines[start]];
      for (var index = start + 1; index < lines.length && block.length < limit; index++) {
        if (!lines[index].startsWith(' ')) break;
        block.add(lines[index]);
      }
      return block;
    }
    final abort = lines.lastWhere((line) => line.startsWith('[libc] abort() called'), orElse: () => '');
    return abort.isEmpty ? const [] : [abort];
  }

  /// The GPU the engine chose, as it says in the log.
  static String? gpu(String session) =>
      RegExp(r'Selected GPU name=(.+?) vendor=0x').firstMatch(session)?.group(1)?.trim();

  @override
  bool operator ==(Object other) => other is Diagnosis && other.runtimeType == runtimeType && other.report == report;

  @override
  int get hashCode => Object.hash(runtimeType, report);

  @override
  String toString() => '$runtimeType($report)';
}

/// The game's executable could not load a library it links.
class MissingModule extends Diagnosis {
  const MissingModule(this.name);
  final String name;
  @override
  String get report => 'Missing module: $name';
}

/// The game called a system function the engine does not implement yet.
class Unsupported extends Diagnosis {
  const Unsupported(this.function);
  final String function;
  @override
  String get report => 'Unsupported system function: $function';
}

/// The GPU device was lost.
class GpuLost extends Diagnosis {
  const GpuLost();
  @override
  String get report => 'The GPU device was lost (VK_ERROR_DEVICE_LOST)';
}

/// The engine or the GPU ran out of memory.
class OutOfMemory extends Diagnosis {
  const OutOfMemory();
  @override
  String get report => 'Out of memory';
}

/// Any other error the engine stopped on, with its message.
class EngineError extends Diagnosis {
  const EngineError(this.message);
  final String message;
  @override
  String get report => 'Engine error: $message';
}

/// The process ended on a signal or an exception.
class Crashed extends Diagnosis {
  const Crashed(this.exception);
  final String exception;
  @override
  String get report => 'The game crashed: $exception';
}

/// The engine stopped the game with abort() ("[libc] abort() called from …").
class Aborted extends Diagnosis {
  const Aborted();
  @override
  String get report => 'The engine stopped the game (abort)';
}

/// The game exited with a status other than 0.
class Exited extends Diagnosis {
  const Exited(this.code);
  final int code;
  @override
  String get report => 'The game exited with status $code';
}

extension ReportSettings on GameSettings {
  /// The settings in one line of English, for a bug report.
  String get reportSummary {
    const corners = {
      OverlayCorner.topLeft: 'top left',
      OverlayCorner.topRight: 'top right',
      OverlayCorner.bottomLeft: 'bottom left',
      OverlayCorner.bottomRight: 'bottom right',
    };
    return [
      'Resolution ${resolution ?? 'default'}',
      if (fullscreen) 'Fullscreen' else 'Windowed $windowSize%',
      'V-sync ${vsync || frameGeneration == true ? 'on' : 'off'}',
      'Frame generation ${frameGeneration == true ? 'on' : 'off'}',
      if (upscaler == Upscaler.fsr1)
        'Upscaling FSR 1 (sharpness ${sharpness.toStringAsFixed(1)})'
      else
        'Upscaling bilinear',
      switch (corners[overlay]) {
        final String corner => 'Overlay $corner (${style.name})',
        null => 'Overlay off',
      },
      'Language ${language ?? 'follows the launcher'}',
      'Shader cache ${shaderCache == false ? 'off' : 'on'}',
      'Controls ${(controls ?? const {}).isEmpty ? 'default' : '${controls!.length} changed'}',
      if (tuning != null) 'Stick and mouse tuning changed',
      'Detailed logging ${trace == true ? 'on' : 'off'}',
      if (chosenRelinkerFlags.isNotEmpty) 'Relinker flags ${chosenRelinkerFlags.map((flag) => flag.option).join(' ')}',
      if (customRelinkerOptions case final String text) 'Custom relinker options $text',
      if (launchOptions case final String text) 'Launch options $text',
    ].join(' · ');
  }
}

/// Everything known about one start of a game, for crash_log.txt and the issue: what the
/// launcher and the log say. Every text it gives out has been through [privacy].
class SessionReport {
  SessionReport({
    required this.gameName,
    required this.titleId,
    required this.gameVersion,
    required this.settings,
    required this.system,
    required this.launcherVersion,
    required this.platform,
    required this.session,
    required this.privacy,
    DateTime? created,
    this.unlockedWith,
    this.engineNow,
    this.relinkerFlags = const [],
    this.customRelinkerOptions = const [],
    this.exitCode,
    this.stoppedByUser = false,
    this.traced = false,
    this.started,
    this.ended,
    this.unlockLog,
    this.controllers = const [],
    this.onlineLines = const [],
  }) : created = created ?? DateTime.now(),
       diagnosis = stoppedByUser ? null : Diagnosis.read(session, exitCode: exitCode);

  final String gameName;
  final String titleId;
  final String gameVersion;
  final GameSettings settings;
  final SystemInfo system;
  final String launcherVersion;

  /// "Windows" or "Linux".
  final String platform;

  /// The log of the start.
  final String session;
  final ReportPrivacy privacy;
  final DateTime created;

  /// The engine toolkit the game was unlocked with, and the one chosen now (version.txt).
  final String? unlockedWith;
  final String? engineNow;

  /// The relinker options the game was unlocked with ([RelinkerFlag]).
  final List<String> relinkerFlags;

  /// The Custom relinker options the game was unlocked with, word by word.
  final List<String> customRelinkerOptions;

  /// The game's exit code; null when the launcher no longer knows it.
  final int? exitCode;

  /// The game was closed from the launcher (or the phone).
  final bool stoppedByUser;

  /// The start ran with detailed logging.
  final bool traced;
  final DateTime? started;
  final DateTime? ended;

  /// What the last unlock of the game printed.
  final String? unlockLog;

  /// The controllers connected and the last connects and disconnects (PadLog.report).
  final List<String> controllers;

  /// The engine stopped because the dump has no PlayGo chunk table to check a chunk ID against
  /// (no sce_sys/playgo-chunk.dat, and no playgo-scenario.json or one that lists no chunks):
  /// upstream's "playgo-chunk.dat and playgo-scenario.json are missing, so chunk ID 1 cannot be
  /// checked", and the same for an ID outside a scenario's list. APS5_PLAYGO_UNLISTED_CHUNKS
  /// answers it, and AnyPS5-ARM's engine takes a dump without any playgo file as installed.
  bool get playGoChunksUnknown => !stoppedByUser && playGoChunksUnknownIn(session);

  static final _playGoUnknown = RegExp(r'scePlayGo: [^\n]*playgo-chunk\.dat[^\n]*cannot be checked');

  /// Whether [log] says so (any title: the rule is the engine's message).
  static bool playGoChunksUnknownIn(String log) => _playGoUnknown.hasMatch(log);

  /// The last lines of the game's online observation log, when online play wrote one during this
  /// start (what the game asked of the platform's online libraries just before it stopped).
  final List<String> onlineLines;
  final Diagnosis? diagnosis;

  /// The log lines the copied text and the panel carry; the saved file has the whole start.
  static const tailLines = 200;

  /// The online log lines a report carries.
  static const onlineTail = 20;

  /// The file the report is saved as, as the Discord request named it.
  String get fileName => 'crash_log.txt';

  /// The game stopped on an error or a crash.
  bool get abnormal => diagnosis != null;

  /// Why the game stopped, in English.
  String get reason =>
      diagnosis?.report ?? (stoppedByUser ? 'Stopped from the launcher' : 'No error found: the game closed normally');

  /// The system, with the GPU the engine named in the log.
  SystemInfo get systemInfo => system.gpu == null ? system.withGpu(Diagnosis.gpu(session)) : system;

  /// The game was unlocked with (or is now set to) AnyPS5-ARM's engine (`arm-<commit>`).
  bool get armEngine => (unlockedWith ?? engineNow)?.startsWith('arm-') ?? false;

  /// The last [count] lines of the log, cleaned.
  List<String> logTail(int count) {
    final end = session.length > count * 600 ? session.substring(session.length - count * 600) : session;
    final lines = const LineSplitter().convert(privacy.clean(end));
    while (lines.isNotEmpty && lines.last.trim().isEmpty) {
      lines.removeLast();
    }
    return lines.length > count ? lines.sublist(lines.length - count) : lines;
  }

  /// The engine's crash report in the log, cleaned.
  List<String> crashSummary(int limit) => Diagnosis.crashLines(session, limit: limit).map(privacy.clean).toList();

  /// "0.1.4 (Windows)".
  String get launcherLine => '$launcherVersion ($platform)';

  String get versionsLine => [
    'Launcher $launcherLine',
    if (unlockedWith != null) 'unlocked with engine $unlockedWith',
    if (engineNow != null && engineNow != unlockedWith) 'engine chosen now $engineNow',
  ].join(' · ');

  /// "-1073741819 (0xC0000005)".
  String? get exitLine {
    final code = exitCode;
    if (code == null) return null;
    final name = Diagnosis.exceptionName(code);
    if (name == null) return '$code';
    final short = RegExp(r'\((0x[0-9A-F]+|signal \d+)\)$').firstMatch(name)?.group(1);
    final signal = RegExp(r'^(SIG[A-Z]+)').firstMatch(name)?.group(1);
    return '$code (${signal ?? short ?? name})';
  }

  String get sessionLine {
    String two(int value) => value.toString().padLeft(2, '0');
    final from = started;
    final to = ended;
    return [
      if (from != null) 'started ${two(from.hour)}:${two(from.minute)}:${two(from.second)}',
      if (from != null && to != null) _ran(to.difference(from)),
      if (exitLine != null) 'exit code $exitLine',
      if (stoppedByUser) 'stopped from the launcher',
      'detailed logging ${traced ? 'on' : 'off'}',
    ].join(', ');
  }

  static String _ran(Duration duration) {
    final seconds = duration.inSeconds < 0 ? 0 : duration.inSeconds;
    return 'ran ${seconds ~/ 60} min ${seconds % 60} s';
  }

  /// The report: the game, why it stopped, the system, the versions, the settings, the crash and
  /// the end of the log; [whole] gives the whole log of the start and the last unlock's output
  /// (crash_log.txt) instead of its last [tailLines] lines (the copied text).
  String text({bool whole = false}) {
    final lines = [
      'AnyPS5 crash report, ${created.toIso8601String()}',
      '',
      'Game: $gameName ($titleId), version $gameVersion',
      'What happened: $reason',
      'Session: $sessionLine',
      '',
      'System: ${systemInfo.line}',
      'Launcher: AnyPS5 Desktop $launcherLine',
      'Engine the game was unlocked with: ${unlockedWith ?? 'unknown'}',
      'Engine chosen for it now: ${engineNow ?? 'unknown'}',
      if (relinkerFlags.isNotEmpty) 'Relinker flags the game was unlocked with: ${relinkerFlags.join(' ')}',
      if (customRelinkerOptions.isNotEmpty)
        'Custom relinker options the game was unlocked with: ${customRelinkerOptions.join(' ')}',
      '',
      'Settings: ${settings.reportSummary}',
      if (traced) 'Detailed logging: ${TraceMode.environment.entries.map((e) => '${e.key}=${e.value}').join(' ')}',
      if (controllers.isNotEmpty) ...['', 'Controllers:', for (final line in controllers) '  $line'],
      if (onlineLines.isNotEmpty) ...[
        '',
        'Online play, the end of the game\'s online log (${onlineLines.length} ${onlineLines.length == 1 ? 'line' : 'lines'}):',
        for (final line in onlineLines) '  $line',
      ],
    ];
    final crash = Diagnosis.crashLines(session);
    if (crash.isNotEmpty) {
      lines.addAll(['', 'The engine\'s crash report:', ...crash.map((line) => '  ${line.trimLeft()}')]);
    }
    final log = const LineSplitter().convert(session);
    while (log.isNotEmpty && log.last.trim().isEmpty) {
      log.removeLast();
    }
    if (whole) {
      lines.addAll(['', 'The log of this start (${log.length} lines):', ...log]);
      if (unlockLog case final String unlock when unlock.trim().isNotEmpty) {
        lines.addAll(['', 'The last unlock\'s output:', ...const LineSplitter().convert(unlock)]);
      }
    } else {
      final tail = log.length > tailLines ? log.sublist(log.length - tailLines) : log;
      lines.addAll([
        '',
        log.length > tailLines ? 'The last ${tail.length} log lines (the whole log: crash_log.txt):' : 'The log:',
        ...tail,
      ]);
    }
    return '${privacy.clean(lines.join('\n'))}\n';
  }
}

/// One field of a GitHub issue form, by its id.
class IssueField {
  const IssueField(this.id, this.label, this.value);
  final String id;
  final String label;
  final String value;
}

/// A GitHub "new issue" page filled in from a report: its title and form fields, as a link that
/// stays under the length browsers and GitHub take.
class IssueDraft {
  const IssueDraft._(this.repository, this.title, this.fields, this.url, {this.linesLeftOut = 0});

  /// Upstream's engine, which the launcher downloads by default: a game's crash is most often its.
  static const engineRepository = 'boykopovar/AnyPS5';

  /// AnyPS5-ARM, for a game run with its engine.
  static const armRepository = 'AnyTogether/AnyPS5-ARM';

  /// This launcher, for a bug in the launcher itself.
  static const launcherRepository = 'AnyTogether/AnyPS5-Desktop';

  static const maximumLength = 7000;

  /// One log line longer than this is cut, so it cannot crowd out the rest.
  static const lineLimit = 300;

  final String repository;
  final String title;
  final List<IssueField> fields;
  final Uri url;

  /// How many of the oldest lines the link has no room for (the whole report goes to the
  /// clipboard then, for the user to paste).
  final int linesLeftOut;

  /// What the link sends, as the user is shown it before it opens.
  String get preview => [title, for (final field in fields) '\n${field.label}\n${field.value}'].join('\n');

  static String _attach(SessionReport report) =>
      'Attach the report the launcher saved (Save ${report.fileName}): drag ${report.fileName} into this box.';

  /// The engine's bug form (bug_report.yml, the same on boykopovar/AnyPS5 and AnyPS5-ARM).
  static IssueDraft engine(SessionReport report, {int logLines = 60}) {
    final engine = report.unlockedWith ?? report.engineNow ?? 'unknown';
    final now = report.engineNow != null && report.engineNow != report.unlockedWith
        ? ', engine chosen now ${report.engineNow}'
        : '';
    final crash = report.crashSummary(6);
    final fixed = [
      IssueField('summary', 'What happens', report.reason),
      IssueField(
        'commit',
        'AnyPS5 commit',
        '${report.armEngine ? 'AnyPS5-ARM engine' : 'Release toolkit'} $engine$now, '
            'unlocked and started by AnyPS5 Desktop ${report.launcherLine}',
      ),
      IssueField('system', 'System', report.systemInfo.line),
      IssueField(
        'steps',
        'Steps to reproduce',
        [
          'Started ${report.gameName} from the AnyPS5 Desktop launcher on ${report.platform}.',
          'Settings: ${report.settings.reportSummary}',
          'Session: ${report.sessionLine}',
          if (report.traced) 'Detailed logging: ${TraceMode.environment.keys.join(', ')}',
        ].join('\n'),
      ),
    ];
    final notes = IssueField(
      'notes',
      'What was checked',
      [...crash, if (crash.isNotEmpty) '', _attach(report)].join('\n'),
    );
    // Their form's "title" field takes the issue title's parameter too: one value for both.
    return _fit(
      repository: report.armEngine ? armRepository : engineRepository,
      template: 'bug_report.yml',
      title: 'Crash: ${report.gameName} (${report.titleId}) ${report.gameVersion}',
      fixed: fixed,
      log: ('log', 'Log'),
      after: [notes],
      report: report,
      logLines: logLines,
    );
  }

  /// This launcher's crash form (.github/ISSUE_TEMPLATE/crash.yml in AnyPS5-Desktop).
  static IssueDraft launcher(SessionReport report, {int logLines = 60}) {
    final crash = report.crashSummary(6);
    final fixed = [
      IssueField('game', 'Game', '${report.gameName} (${report.titleId}), version ${report.gameVersion}'),
      IssueField('reason', 'What happened', [report.reason, ...crash].join('\n')),
      IssueField('system', 'System', report.systemInfo.line),
      IssueField('versions', 'Versions', report.versionsLine),
      IssueField(
        'settings',
        'Game settings',
        [
          report.settings.reportSummary,
          'Session: ${report.sessionLine}',
          if (report.controllers.firstOrNull case final controller?) 'Controller: $controller',
        ].join('\n'),
      ),
    ];
    return _fit(
      repository: launcherRepository,
      template: 'crash.yml',
      title: 'Crash: ${report.gameName} (${report.titleId})',
      fixed: fixed,
      log: ('log', 'Last log lines'),
      // The Report File box stays empty for the file the user drags in, and What You Were
      // Doing for their words: a box filled from the link can be put back by GitHub over what
      // was typed or dropped in it.
      after: const [],
      report: report,
      logLines: logLines,
    );
  }

  /// This launcher's own crash or stall (.github/ISSUE_TEMPLATE/launcher_crash.yml): what the
  /// launcher noticed, the system, the version, the first uncaught error and the launcher's last
  /// seconds, every field through [privacy]. What the user was doing is the form's own empty
  /// box ("doing"): a box filled from the link can be put back by GitHub over what is typed. The
  /// oldest lines go first until the link is short enough, and the log then says so.
  static IssueDraft launcherProblem(
    LauncherProblem problem, {
    required SystemInfo system,
    required ReportPrivacy privacy,
  }) {
    final (:title, :what, :error, :lines) = _problemParts(problem, privacy);
    var shownError = error;
    final kept = [...lines];
    while (true) {
      final leftOut = lines.length - kept.length;
      final log = [
        if (leftOut > 0)
          '($leftOut older lines left out to fit the link: the whole report is on the clipboard, paste it below.)',
        ...kept,
      ];
      final fields = [
        IssueField('what', 'What the launcher noticed', what),
        IssueField('system', 'System', privacy.clean(system.line)),
        IssueField('versions', 'Version', 'Launcher ${problem.version} (${problem.platform})'),
        IssueField('error', 'Uncaught error', shownError),
        IssueField('log', 'Last seconds', log.isEmpty ? '(none kept)' : log.join('\n')),
      ];
      final link = _link(launcherRepository, 'launcher_crash.yml', title, fields);
      if (link.length <= maximumLength) {
        return IssueDraft._(launcherRepository, title, fields, Uri.parse(link), linesLeftOut: leftOut);
      }
      if (kept.isNotEmpty) {
        kept.removeAt(0);
      } else {
        shownError = '${shownError.substring(0, shownError.length * 3 ~/ 4)}…';
      }
    }
  }

  /// The whole report of [problem], nothing left out, as the clipboard gets it when the link
  /// could not take every line.
  static String launcherProblemText(
    LauncherProblem problem, {
    required SystemInfo system,
    required ReportPrivacy privacy,
  }) {
    final (:title, :what, :error, :lines) = _problemParts(problem, privacy);
    return [
      title,
      '',
      what,
      privacy.clean(system.line),
      'Launcher ${problem.version} (${problem.platform})',
      '',
      'Uncaught error:',
      error,
      '',
      'Last seconds:',
      if (lines.isEmpty) '(none kept)' else ...lines,
    ].join('\n');
  }

  static ({String title, String what, String error, List<String> lines}) _problemParts(
    LauncherProblem problem,
    ReportPrivacy privacy,
  ) {
    final at = problem.at.toUtc().toIso8601String().substring(0, 19).replaceFirst('T', ' ');
    final seconds = problem.stalledFor?.inSeconds;
    final (title, what) = switch (problem.kind) {
      LauncherProblemKind.crash when problem.whileClosing => (
        'Launcher crash while closing',
        'The launcher crashed while closing: it began to close (Quit or the window\'s close) at $at UTC and did not '
            'finish shutting down.',
      ),
      LauncherProblemKind.crash => (
        'Launcher crash',
        'The launcher closed without being closed (a crash, or ended from the task manager). Last seen alive $at UTC.',
      ),
      LauncherProblemKind.hang when problem.recovered => (
        'Launcher stopped responding (${seconds}s)',
        'The interface did not answer for $seconds s from $at UTC, then went on.',
      ),
      LauncherProblemKind.hang => (
        'Launcher stopped responding',
        'The interface stopped answering at $at UTC and did not answer again (${seconds}s or more) before it was closed.',
      ),
    };
    String cut(String line) => line.length > lineLimit ? '${line.substring(0, lineLimit)}…' : line;
    final error = problem.error == null
        ? 'None caught.'
        : const LineSplitter().convert(privacy.clean(problem.error!)).take(40).map(cut).join('\n');
    return (
      title: title,
      what: what,
      error: error,
      lines: [for (final line in problem.lines) cut(privacy.clean(line))],
    );
  }

  /// The newest log lines that fit: the oldest go first until the link is short enough.
  static IssueDraft _fit({
    required String repository,
    required String template,
    required String title,
    required List<IssueField> fixed,
    required (String, String) log,
    required List<IssueField> after,
    required SessionReport report,
    required int logLines,
  }) {
    IssueField clean(IssueField field) => IssueField(field.id, field.label, report.privacy.clean(field.value));
    final cleanTitle = report.privacy.clean(title);
    var fields = fixed.map(clean).toList();
    var trailing = after.map(clean).toList();
    final tail = [
      for (final line in report.logTail(logLines)) line.length > lineLimit ? '${line.substring(0, lineLimit)}…' : line,
    ];
    while (true) {
      final all = [...fields, IssueField(log.$1, log.$2, tail.join('\n')), ...trailing];
      final link = _link(repository, template, cleanTitle, all);
      if (link.length <= maximumLength) return IssueDraft._(repository, cleanTitle, all, Uri.parse(link));
      if (tail.isNotEmpty) {
        tail.removeAt(0);
        continue;
      }
      // Only a form of very long settings gets here: its longest field is shortened.
      final every = [...fields, ...trailing];
      var longest = 0;
      for (var index = 1; index < every.length; index++) {
        if (every[index].value.length > every[longest].value.length) longest = index;
      }
      final field = every[longest];
      every[longest] = IssueField(field.id, field.label, '${field.value.substring(0, field.value.length * 3 ~/ 4)}…');
      fields = every.sublist(0, fields.length);
      trailing = every.sublist(fields.length);
    }
  }

  static String _link(String repository, String template, String title, List<IssueField> fields) {
    final parameters = [
      ('template', template),
      ('title', title),
      // A form field with the id "title" is filled from the title parameter already.
      for (final field in fields)
        if (field.id != 'title') (field.id, field.value),
    ];
    final query = parameters.map((entry) => '${entry.$1}=${_encode(entry.$2)}').join('&');
    return 'https://github.com/$repository/issues/new?$query';
  }

  /// Percent-encodes all but RFC 3986's unreserved characters: a "+" left as it is would read
  /// as a space.
  static String _encode(String text) {
    final out = StringBuffer();
    for (final byte in utf8.encode(text)) {
      final unreserved =
          (byte >= 0x30 && byte <= 0x39) ||
          (byte >= 0x41 && byte <= 0x5A) ||
          (byte >= 0x61 && byte <= 0x7A) ||
          byte == 0x2D ||
          byte == 0x2E ||
          byte == 0x5F ||
          byte == 0x7E;
      if (unreserved) {
        out.writeCharCode(byte);
      } else {
        out.write('%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}');
      }
    }
    return out.toString();
  }
}
