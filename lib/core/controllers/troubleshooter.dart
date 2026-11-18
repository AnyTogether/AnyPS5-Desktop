import 'dart:async';
import 'dart:io';

import '../gamepad/linux_pads.dart';
import '../host.dart';
import 'pad_info.dart';

/// What can keep a controller from the launcher on Windows and Linux, and what to do about it.
/// The texts are the launcher's, in assets/l10n by [PadFinding.id] (`padFinding_<id>`).
class PadFinding {
  const PadFinding(this.id, {this.problem = false, this.arguments = const [], this.command});

  /// "steamPlayStation", "ds4windows", "linuxPermission"...
  final String id;

  /// Something in the way now (else a tip).
  final bool problem;

  /// What the text names: a controller, a percentage, a path.
  final List<Object> arguments;

  /// A command to copy (Linux's group and udev rule, HidHide's application path).
  final String? command;

  @override
  bool operator ==(Object other) =>
      other is PadFinding && other.id == id && other.problem == problem && other.command == command && '$arguments' == '${other.arguments}';

  @override
  int get hashCode => Object.hash(id, problem, command, '$arguments');

  @override
  String toString() => 'PadFinding($id${problem ? ', problem' : ''}${arguments.isEmpty ? '' : ', $arguments'})';
}

/// The facts the troubleshooter reads: the launcher's own (the pads, the reader) and the
/// system's (running programs, installed drivers, Steam's setting, device permissions).
class PadFacts {
  const PadFacts({
    required this.system,
    this.pads = const [],
    this.sdlLoaded = true,
    this.sdlFailure,
    this.unmapped = const [],
    this.refused = const [],
    this.processes = const {},
    this.services = const {},
    this.steamPlayStationSupport,
    this.launchedFromSteam = false,
    this.hidrawDenied = false,
    this.executable = '',
  });

  final HostSystem system;
  final List<PadInfo> pads;
  final bool sdlLoaded;
  final String? sdlFailure;

  /// Joysticks SDL lists without a game controller mapping.
  final List<String> unmapped;

  /// Linux: controllers whose /dev/input node the user may not read.
  final List<String> refused;

  /// Running programs' executable names, lower case ("steam.exe", "ds4windows.exe", "steam").
  final Set<String> processes;

  /// Windows services and drivers installed, lower case ("hidhide", "vigembus", "dshidmini",
  /// "bthps3").
  final Set<String> services;

  /// Steam's "PlayStation Controller Support" (config.vdf's SteamController_PSSupport: 0 off,
  /// 1 in games without their own support, 2 on); null when Steam's settings were not found.
  final int? steamPlayStationSupport;
  final bool launchedFromSteam;

  /// Linux: /dev/hidraw* exist and none can be opened (SDL then reads PlayStation pads through
  /// evdev, without their motors and light bars).
  final bool hidrawDenied;

  /// The launcher's executable, for HidHide's list of applications.
  final String executable;
}

abstract final class PadTroubleshooter {
  static const linuxGroupCommand = 'sudo usermod -aG input "\$USER"';

  /// A udev rule that gives the logged-in user PlayStation and Nintendo pads' hidraw nodes (the
  /// ones SDL drives their motors and lights through), over USB and Bluetooth.
  static const linuxUdevCommand =
      "printf '%s\\n' "
      "'KERNEL==\"hidraw*\", ATTRS{idVendor}==\"054c\", MODE=\"0660\", TAG+=\"uaccess\"' "
      "'KERNEL==\"hidraw*\", KERNELS==\"*054C:*\", MODE=\"0660\", TAG+=\"uaccess\"' "
      "'KERNEL==\"hidraw*\", ATTRS{idVendor}==\"057e\", MODE=\"0660\", TAG+=\"uaccess\"' "
      "'KERNEL==\"hidraw*\", KERNELS==\"*057E:*\", MODE=\"0660\", TAG+=\"uaccess\"' "
      '| sudo tee /etc/udev/rules.d/70-anyps5-controllers.rules && sudo udevadm control --reload-rules && sudo udevadm trigger';

  static const linuxSdlCommand = 'sudo apt install libsdl2-2.0-0   # Fedora: sudo dnf install SDL2   Arch: sudo pacman -S sdl2';

  static bool _running(PadFacts facts, List<String> names) => names.any(facts.processes.contains);

  /// Sony's own DualShock 3 (054c:0268), not a pad that only has PS3 in its name: those are
  /// ordinary HID pads that need nothing.
  static bool sonyDualShock3(PadInfo pad) => pad.vendor == PadKind.sony && pad.product == 0x0268;

  /// The services the troubleshooter asks Windows about: DsHidMini (the DualShock 3's driver)
  /// and BthPS3 (its Bluetooth) beside the remappers'.
  static const windowsServices = ['HidHide', 'ViGEmBus', 'dshidmini', 'BthPS3'];

  /// Where Windows keeps a service: a kernel driver's under Services, a user-mode (UMDF) driver's
  /// such as DsHidMini's under WUDF\Services.
  static List<String> serviceKeys(String name) => [
    'HKLM\\SYSTEM\\CurrentControlSet\\Services\\$name',
    'HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\WUDF\\Services\\$name',
  ];

  static List<PadFinding> diagnose(PadFacts facts) {
    final windows = facts.system == HostSystem.windows;
    final findings = <PadFinding>[];
    final none = facts.pads.isEmpty;
    if (none && facts.unmapped.isEmpty && facts.refused.isEmpty) findings.add(const PadFinding('noControllers', problem: true));
    for (final name in facts.refused) {
      findings.add(PadFinding('linuxPermission', problem: true, arguments: [name], command: linuxGroupCommand));
    }
    for (final name in facts.unmapped) {
      findings.add(PadFinding('unmapped', problem: true, arguments: [name]));
    }
    for (final pad in facts.pads) {
      if (pad.battery case final battery? when battery.low) {
        findings.add(switch (battery.percent) {
          final int percent => PadFinding('lowBattery', problem: true, arguments: [pad.name, percent]),
          // Only a level: no number to give.
          null => PadFinding('lowBatteryLevel', problem: true, arguments: [pad.name]),
        });
      }
    }
    // Steam: from Steam its virtual pad is used; outside, its PlayStation support turns the pad
    // into its desktop layout (a mouse, keys) on top of what the launcher reads.
    final steam = _running(facts, ['steam.exe', 'steam', 'steamwebhelper.exe']);
    if (facts.launchedFromSteam) {
      findings.add(const PadFinding('steamLaunched'));
    } else if (steam) {
      // Unknown (settings not found) counts as on: it is Steam's default.
      final playStation = (facts.steamPlayStationSupport ?? 1) > 0;
      findings.add(playStation && (none || facts.pads.any((pad) => pad.kind.isPlayStation))
          ? const PadFinding('steamPlayStation', problem: true)
          : const PadFinding('steamRunning'));
    }
    if (windows) {
      if (_running(facts, ['ds4windows.exe'])) findings.add(const PadFinding('ds4windows', problem: true));
      if (_running(facts, ['dualsensex.exe', 'dsx.exe'])) findings.add(const PadFinding('dualSenseX', problem: true));
      if (facts.services.contains('hidhide')) {
        findings.add(PadFinding('hidHide', problem: none, command: facts.executable.isEmpty ? null : facts.executable));
      }
      if (facts.services.contains('vigembus') && !_running(facts, ['ds4windows.exe', 'dualsensex.exe', 'dsx.exe'])) {
        findings.add(const PadFinding('vigem'));
      }
      // Windows' own drivers cannot start a DualShock 3 (SDL keeps its HIDAPI driver off there
      // for that reason): one listed without DsHidMini has nothing to start it.
      if (!facts.services.contains('dshidmini') && facts.pads.any(sonyDualShock3)) {
        findings.add(const PadFinding('dualShock3Windows', problem: true));
      }
    } else {
      // A DualShock 3 is Linux's hid-sony's, read through evdev with its motors (SDL leaves its
      // HIDAPI driver off on Linux): hidraw is no help to it.
      final playStationWithout = facts.pads.any(
        (pad) => pad.kind.isPlayStation && pad.kind != PadKind.dualShock3 && !pad.driver.contains('HIDAPI'),
      );
      if (facts.hidrawDenied && (playStationWithout || none)) {
        findings.add(const PadFinding('linuxHidraw', command: linuxUdevCommand));
      }
    }
    if (!facts.sdlLoaded) {
      findings.add(PadFinding(windows ? 'sdlMissingWindows' : 'sdlMissingLinux', problem: true,
          arguments: [facts.sdlFailure ?? ''], command: windows ? null : linuxSdlCommand));
    }
    if (none) {
      findings.addAll([
        const PadFinding('usbCable'),
        const PadFinding('bluetoothPairing'),
        ?_dualShock3Tip(facts),
      ]);
    }
    return findings;
  }

  /// With nothing connected, what a DualShock 3 needs: on Windows DsHidMini, and once it is
  /// there BthPS3 for Bluetooth (Windows' own Bluetooth refuses the pad); on Linux nothing on its
  /// cable.
  static PadFinding? _dualShock3Tip(PadFacts facts) {
    if (facts.system != HostSystem.windows) return const PadFinding('dualShock3Linux');
    if (!facts.services.contains('dshidmini')) return const PadFinding('dualShock3Windows');
    if (!facts.services.contains('bthps3')) return const PadFinding('dualShock3WindowsBluetooth');
    return null;
  }

  /// The controller the top bar's indicator is about (one running out of battery): null when
  /// there is nothing to say.
  static PadInfo? statusPad(List<PadInfo> pads) {
    for (final pad in pads) {
      if (pad.battery case final battery? when battery.low) return pad;
    }
    return null;
  }

  /// Steam's PlayStation setting from config.vdf's text.
  static int? steamPlayStationSupport(String configText) {
    final match = RegExp(r'"SteamController_PSSupport"\s+"(\d+)"', caseSensitive: false).firstMatch(configText);
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  /// Executable names out of `tasklist /fo csv /nh` ("steam.exe","1234",...).
  static Set<String> tasklistNames(String output) => {
    for (final line in output.split(RegExp(r'\r?\n')))
      if (RegExp(r'^"([^"]+)"').firstMatch(line.trim()) case final match?) match.group(1)!.toLowerCase(),
  };
}

/// Asks the system what the troubleshooter needs: running programs, installed drivers, Steam's
/// setting, hidraw permissions. A fake in tests.
abstract class SystemProbe {
  Future<Set<String>> processes();
  Future<Set<String>> services(List<String> names);
  Future<int?> steamPlayStationSupport();
  Future<bool> hidrawDenied();

  /// Linux: the controllers the kernel lists whose /dev/input node the user may not read.
  Future<List<String>> unreadableControllers();
}

/// The real system: tasklist and reg on Windows, /proc and /dev on Linux.
class HostProbe implements SystemProbe {
  HostProbe(this.system, {Map<String, String>? environment}) : environment = environment ?? Platform.environment;

  final HostSystem system;
  final Map<String, String> environment;

  Future<ProcessResult?> _run(String executable, List<String> arguments) async {
    try {
      return await Process.run(executable, arguments).timeout(const Duration(seconds: 5));
    } on Object {
      return null;
    }
  }

  @override
  Future<Set<String>> processes() async {
    if (system == HostSystem.windows) {
      final result = await _run('tasklist', ['/fo', 'csv', '/nh']);
      return result == null ? {} : PadTroubleshooter.tasklistNames('${result.stdout}');
    }
    final names = <String>{};
    try {
      for (final entry in Directory('/proc').listSync()) {
        if (!RegExp(r'/\d+$').hasMatch(entry.path)) continue;
        try {
          names.add(File('${entry.path}/comm').readAsStringSync().trim().toLowerCase());
        } on FileSystemException {
          // Gone meanwhile.
        }
      }
    } on FileSystemException {
      // No /proc: nothing known.
    }
    return names;
  }

  @override
  Future<Set<String>> services(List<String> names) async {
    if (system != HostSystem.windows) return {};
    final found = <String>{};
    for (final name in names) {
      for (final key in PadTroubleshooter.serviceKeys(name)) {
        if ((await _run('reg', ['query', key]))?.exitCode == 0) {
          found.add(name.toLowerCase());
          break;
        }
      }
    }
    return found;
  }

  @override
  Future<int?> steamPlayStationSupport() async {
    final places = <String>[];
    if (system == HostSystem.windows) {
      final result = await _run('reg', ['query', r'HKCU\Software\Valve\Steam', '/v', 'SteamPath']);
      final path = RegExp(r'SteamPath\s+REG_SZ\s+(.+)').firstMatch('${result?.stdout ?? ''}')?.group(1)?.trim();
      if (path != null) places.add('$path/config/config.vdf');
      places.add(r'C:\Program Files (x86)\Steam\config\config.vdf');
    } else {
      final home = environment['HOME'] ?? '';
      places.addAll([
        '$home/.steam/steam/config/config.vdf',
        '$home/.local/share/Steam/config/config.vdf',
        '$home/.var/app/com.valvesoftware.Steam/.local/share/Steam/config/config.vdf',
      ]);
    }
    for (final place in places) {
      try {
        final value = PadTroubleshooter.steamPlayStationSupport(File(place).readAsStringSync());
        if (value != null) return value;
      } on FileSystemException {
        continue;
      }
    }
    return null;
  }

  @override
  Future<List<String>> unreadableControllers() async {
    if (system != HostSystem.linux) return const [];
    try {
      final devices = LinuxPadSource.parseDevices(File('/proc/bus/input/devices').readAsStringSync());
      return [
        for (final device in devices)
          if (!_readable('/dev/input/${device.event}')) device.name,
      ];
    } on FileSystemException {
      return const [];
    }
  }

  static bool _readable(String path) {
    try {
      File(path).openSync().closeSync();
      return true;
    } on FileSystemException {
      return false;
    }
  }

  @override
  Future<bool> hidrawDenied() async {
    if (system != HostSystem.linux) return false;
    try {
      final nodes = Directory('/dev').listSync().where((entry) => RegExp(r'/hidraw\d+$').hasMatch(entry.path)).toList();
      if (nodes.isEmpty) return false;
      for (final node in nodes) {
        try {
          File(node.path).openSync().closeSync();
          return false;
        } on FileSystemException {
          continue;
        }
      }
      return true;
    } on FileSystemException {
      return false;
    }
  }
}
