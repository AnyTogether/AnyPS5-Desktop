import 'dart:io';

/// The processor the launcher runs on, as far as relinking cares: whose it is.
///
/// The PS5's CPU is an AMD Zen 2, and games use instructions only AMD processors have
/// (MONITORX/MWAITX, CLZERO, RDPRU, the SSE4a EXTRQ/INSERTQ/MOVNTSS/MOVNTSD). A game relinked as
/// it is stops on any other CPU with SIGILL the first time it reaches one; the relinker's
/// `--to-intel` rewrites them ([RelinkerFlag.toIntel]).
class HostCpu {
  const HostCpu(this.vendor);

  /// The CPUID vendor string (`GenuineIntel`, `AuthenticAMD`, ...); null when it cannot be read.
  final String? vendor;

  /// AMD's processors, and Hygon's (built from AMD's Zen), have every instruction a PS5 game uses.
  static const amdVendors = {'AuthenticAMD', 'HygonGenuine'};

  /// Whether a game has to be relinked with `--to-intel` to run here: a processor that is known
  /// and is not AMD's. One that cannot be read is relinked as before.
  bool get needsIntelConversion => vendor != null && !amdVendors.contains(vendor);

  /// This computer's processor, read once. Tests set it.
  static HostCpu current = read();

  /// The vendor from /proc/cpuinfo on Linux, from PROCESSOR_IDENTIFIER on Windows
  /// (`Intel64 Family 6 Model 158 Stepping 10, GenuineIntel`).
  static HostCpu read() {
    if (Platform.isWindows) return fromProcessorIdentifier(Platform.environment['PROCESSOR_IDENTIFIER']);
    try {
      return fromCpuinfo(File('/proc/cpuinfo').readAsStringSync());
    } on FileSystemException {
      return const HostCpu(null);
    }
  }

  /// The first `vendor_id` line of a Linux /proc/cpuinfo.
  static HostCpu fromCpuinfo(String text) {
    final vendor = RegExp(r'^vendor_id\s*:\s*(\S+)', multiLine: true).firstMatch(text)?.group(1);
    return HostCpu(vendor);
  }

  /// What follows the last comma of Windows' PROCESSOR_IDENTIFIER.
  static HostCpu fromProcessorIdentifier(String? identifier) {
    if (identifier == null) return const HostCpu(null);
    final comma = identifier.lastIndexOf(',');
    final vendor = (comma < 0 ? '' : identifier.substring(comma + 1)).trim();
    return HostCpu(vendor.isEmpty ? null : vendor);
  }
}
