import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

/// The system's libmpv, which the clip player and the voice notes play through on Linux. The
/// Linux packages do not carry one (Ubuntu's is built with GPL parts and links libcdio, which is
/// GPL-3.0-or-later, and the launcher is GPL-2.0-only): the .deb depends on
/// libmpv2 or libmpv1, the Arch package on mpv, and the AppImage and the .tar.gz use the one the
/// system has. The media_kit_video plugin links the launcher's own libanyps5_mpv.so
/// (linux/mpv_shim), which opens that libmpv only when a clip plays, so the launcher starts
/// without one and only those two say how to install it.
abstract final class SystemLibmpv {
  /// The names media_kit opens on Linux, in its order (NativeLibrary.ensureInitialized); the
  /// plugin's libanyps5_mpv.so tries the same ones.
  static const names = ['libmpv.so', 'libmpv.so.2', 'libmpv.so.1'];

  /// The first of [names] that [opens] (dlopen by default) can load, or LIBMPV_LIBRARY_PATH
  /// first when it is set, as media_kit reads it. Null when there is none.
  static String? find({bool Function(String name)? opens, Map<String, String>? environment}) {
    final open = opens ?? _opens;
    final custom = (environment ?? Platform.environment)['LIBMPV_LIBRARY_PATH'];
    for (final name in [if (custom != null && custom.isNotEmpty) custom, ...names]) {
      if (open(name)) return name;
    }
    return null;
  }

  static bool _opens(String name) {
    try {
      DynamicLibrary.open(name);
      return true;
    } on Object {
      return false;
    }
  }

  static bool? _missing;

  /// Whether this is Linux without a libmpv, looked for once: at startup (main.dart), then
  /// remembered. Never on Windows, whose package carries libmpv-2.dll.
  static bool get missing => _missing ??= Platform.isLinux && find() == null;

  /// What the players throw when [missing]: the commands that install libmpv here.
  static LibmpvMissing missingError() => LibmpvMissing(installCommands(_osRelease()));

  static String _osRelease() {
    for (final path in const ['/etc/os-release', '/usr/lib/os-release']) {
      try {
        return File(path).readAsStringSync();
      } on FileSystemException {
        continue;
      }
    }
    return '';
  }

  /// Ubuntu 22.04 and Debian 11 (and what is built on them: Linux Mint 21, Pop!_OS 22.04) have
  /// libmpv1, the newer ones libmpv2.
  static const _libmpv1Codenames = {'focal', 'jammy', 'buster', 'bullseye'};

  /// The commands that install libmpv on the distribution an os-release file ([osRelease])
  /// describes, by its ID and ID_LIKE: one for a family it knows, all of them otherwise.
  static List<String> installCommands(String osRelease) {
    final values = _values(osRelease);
    final family = {
      ...?values['ID']?.toLowerCase().split(RegExp(r'\s+')),
      ...?values['ID_LIKE']?.toLowerCase().split(RegExp(r'\s+')),
    };
    final codename = (values['UBUNTU_CODENAME'] ?? values['DEBIAN_CODENAME'] ?? values['VERSION_CODENAME'] ?? '')
        .toLowerCase();
    if (family.contains('debian') || family.contains('ubuntu')) {
      return ['sudo apt install ${_libmpv1Codenames.contains(codename) ? 'libmpv1' : 'libmpv2'}'];
    }
    if (family.contains('fedora')) return [fedora];
    if (family.contains('arch')) return [arch];
    if (family.any((id) => id.contains('suse'))) return [openSuse];
    return all;
  }

  static const fedora = 'sudo dnf install mpv-libs';
  static const arch = 'sudo pacman -S mpv';
  static const openSuse = 'sudo zypper install libmpv2';

  /// Ubuntu 24.04, Debian 12 and newer first; Ubuntu 22.04's package is libmpv1.
  static const all = ['sudo apt install libmpv2', 'sudo apt install libmpv1', fedora, arch, openSuse];

  static Map<String, String> _values(String release) {
    final values = <String, String>{};
    for (final line in const LineSplitter().convert(release)) {
      final match = RegExp(r'^\s*([A-Z_][A-Z0-9_]*)=(.*)$').firstMatch(line);
      if (match == null) continue;
      var value = match[2]!.trim();
      if (value.length >= 2 &&
          (value.startsWith('"') && value.endsWith('"') || value.startsWith("'") && value.endsWith("'"))) {
        value = value.substring(1, value.length - 1);
      }
      values[match[1]!] = value.trim();
    }
    return values;
  }
}

/// libmpv could not be loaded (Linux): the clip player shows [commands] over the clip's picture
/// and the voice notes say the first one, instead of failing.
class LibmpvMissing implements Exception {
  const LibmpvMissing(this.commands);

  /// The commands that install it on this system: one, or one per distribution family.
  final List<String> commands;

  @override
  String toString() => 'libmpv is not installed (${commands.join(', ')})';
}
