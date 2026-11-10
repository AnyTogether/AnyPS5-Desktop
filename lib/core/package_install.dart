import 'dart:io';

import 'package:path/path.dart' as p;

import 'host.dart';

/// A package manager that put this copy of the launcher on the computer and keeps it current.
/// The launcher's own update stays out of its way then: on Windows the installer it runs would
/// put a second copy beside Scoop's, and on Linux the files are the package's. The launcher still
/// says when a new version is out, and how to get it.
enum PackageManager {
  scoop,
  pacman;

  /// What updates the launcher, typed into a terminal; null where the system's package manager
  /// has ways of its own (pacman with an AUR helper, makepkg).
  String? get command => switch (this) {
    PackageManager.scoop => 'scoop update ${PackageInstall.scoopApp}',
    PackageManager.pacman => null,
  };
}

/// Whether this copy of the launcher was installed by a package manager: Scoop on Windows (the
/// AnyTogether bucket's portable zip), pacman on Arch Linux (anyps5-desktop-bin from
/// AnyTogether/linux-packages). winget runs the same installer as the launcher's own update, so
/// it is not one of them: the two keep one copy.
abstract final class PackageInstall {
  /// The app's name in the Scoop bucket (AnyTogether/scoop-bucket).
  static const scoopApp = 'anyps5-desktop';

  /// The Arch packages are named after the launcher: anyps5-desktop-bin, or another build of it.
  static const archPackage = 'anyps5-desktop';

  /// pacman's record of the installed packages: a folder per package, its files listed in `files`.
  static const pacmanDatabase = '/var/lib/pacman/local';

  /// Where anyps5-desktop-bin puts the launcher (the release's .deb, repacked).
  static const archFolder = '/opt/anyps5-desktop/';

  /// The package manager that installed the launcher running from [executable] (this process's
  /// own by default), or null when it was the installer, the zip, the AppImage, the .deb or the
  /// archive. An AppImage is never a package's, even on Arch.
  static PackageManager? detect(
    HostSystem system, {
    String? executable,
    Map<String, String>? environment,
    String database = pacmanDatabase,
  }) {
    final program = executable ?? Platform.resolvedExecutable;
    final env = environment ?? Platform.environment;
    return switch (system) {
      HostSystem.windows => isScoop(program, env, resolve: _resolve) ? PackageManager.scoop : null,
      HostSystem.linux =>
        (env['APPIMAGE'] ?? '').isEmpty && isPacman(program, database: database, resolve: _resolve)
            ? PackageManager.pacman
            : null,
    };
  }

  /// [path] with its links followed (Scoop's `current` is a junction to the version folder);
  /// null when it cannot be.
  static String? _resolve(String path) {
    try {
      return File(path).resolveSymbolicLinksSync();
    } on FileSystemException {
      return null;
    }
  }

  /// Whether [executable] lives in a Scoop app folder: `<root>\apps\<app>\<version or current>\`,
  /// the root being `%USERPROFILE%\scoop`, `%ProgramData%\scoop` (a global install) or the one
  /// SCOOP or SCOOP_GLOBAL names. [resolve] follows the `current` junction.
  static bool isScoop(String executable, Map<String, String> environment, {String? Function(String path)? resolve}) {
    String normal(String path) {
      var out = path.replaceAll('/', r'\').toLowerCase();
      if (out.startsWith(r'\\?\')) out = out.substring(4);
      while (out.endsWith(r'\')) {
        out = out.substring(0, out.length - 1);
      }
      return out;
    }

    // Windows' environment names are the same in any case.
    String? variable(String name) {
      for (final entry in environment.entries) {
        if (entry.key.toUpperCase() == name && entry.value.trim().isNotEmpty) return entry.value.trim();
      }
      return null;
    }

    final profile = variable('USERPROFILE');
    final programData = variable('PROGRAMDATA');
    final roots = [
      ?variable('SCOOP'),
      ?variable('SCOOP_GLOBAL'),
      if (profile != null) '$profile\\scoop',
      if (programData != null) '$programData\\scoop',
    ].map(normal).toSet();
    final paths = {executable, ?resolve?.call(executable)}.map(normal);
    return paths.any((path) => path.contains(r'\scoop\apps\') || roots.any((root) => path.startsWith('$root\\apps\\')));
  }

  /// Whether pacman owns [executable]: a package named after the launcher in pacman's
  /// [database] lists it among its files. When that list cannot be read, the package's own
  /// folder ([archFolder]) says it.
  static bool isPacman(String executable, {String database = pacmanDatabase, String? Function(String path)? resolve}) {
    final folder = Directory(database);
    if (!folder.existsSync()) return false;
    final paths = {executable, ?resolve?.call(executable)};
    final List<Directory> packages;
    try {
      packages = folder
          .listSync()
          .whereType<Directory>()
          .where((entry) => p.basename(entry.path).startsWith('$archPackage-'))
          .toList();
    } on FileSystemException {
      return false;
    }
    for (final package in packages) {
      final List<String> lines;
      try {
        lines = File(p.join(package.path, 'files')).readAsLinesSync();
      } on FileSystemException {
        if (paths.any((path) => path.startsWith(archFolder))) return true;
        continue;
      }
      // %FILES% and then one path a line, without the leading slash, up to the next section.
      final owned = lines
          .skipWhile((line) => line.trim() != '%FILES%')
          .skip(1)
          .takeWhile((line) => line.trim().isNotEmpty && !line.startsWith('%'))
          .map((line) => '/${line.trim()}')
          .toSet();
      if (paths.any(owned.contains)) return true;
    }
    return false;
  }
}
