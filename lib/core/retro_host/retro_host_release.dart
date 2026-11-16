import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../release_signing.dart';
import 'checked_file.dart';

/// Why the emulator host cannot be used: a release check failed (anyps5-retro-host
/// docs/protocol.md "Finding and checking the host"). The launcher then does not start the host and
/// shows that the emulator needs to be downloaded again.
class RetroHostReleaseFailure implements Exception {
  const RetroHostReleaseFailure(this.message);
  final String message;

  @override
  String toString() => message;
}

/// One system a host release is built for: `<os>-<arch>` in its file names, and the names of the
/// host and of SwanStation inside its zip (the host repository's tools/package_release.py).
class RetroHostSystem {
  const RetroHostSystem(this.name, {required this.executable, required this.core});

  final String name;
  final String executable;
  final String core;

  static const windowsX64 = RetroHostSystem(
    'windows-x64',
    executable: 'anyps5-retro-host.exe',
    core: 'swanstation_libretro.dll',
  );
  static const linuxX64 = RetroHostSystem(
    'linux-x64',
    executable: 'anyps5-retro-host',
    core: 'swanstation_libretro.so',
  );
  static const macosArm64 = RetroHostSystem(
    'macos-arm64',
    executable: 'anyps5-retro-host',
    core: 'swanstation_libretro.dylib',
  );

  /// The system this launcher runs on, or null where no host is released.
  static RetroHostSystem? get current => switch (Abi.current()) {
    Abi.windowsX64 => windowsX64,
    Abi.linuxX64 => linuxX64,
    Abi.macosArm64 => macosArm64,
    _ => null,
  };
}

/// A host release's version, `<major>.<minor>.<patch>` as in `welcome`'s `hostVersion`.
class RetroHostVersion implements Comparable<RetroHostVersion> {
  const RetroHostVersion(this.major, this.minor, this.patch);

  /// Null unless [text] is exactly three dot-separated decimal numbers.
  static RetroHostVersion? tryParse(String text) {
    final match = RegExp(r'^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$').firstMatch(text);
    if (match == null) return null;
    return RetroHostVersion(int.parse(match.group(1)!), int.parse(match.group(2)!), int.parse(match.group(3)!));
  }

  final int major;
  final int minor;
  final int patch;

  @override
  int compareTo(RetroHostVersion other) => major != other.major
      ? major.compareTo(other.major)
      : minor != other.minor
      ? minor.compareTo(other.minor)
      : patch.compareTo(other.patch);

  @override
  String toString() => '$major.$minor.$patch';
}

/// A host whose files were checked before a start: the client starts it from [program] when
/// there is one, and calls [release] once the host has exited, since the host loads the core again
/// for every game it starts.
class RetroHostChecked {
  RetroHostChecked({
    required this.version,
    required this.executable,
    required this.core,
    required this._files,
    this.program,
  });

  final RetroHostVersion version;

  /// The host executable's path, the command's first argument.
  final String executable;

  /// The SwanStation library the release ships: the only core a release launcher runs.
  final String core;

  /// Where the operating system takes the host from, when that is not [executable]: on Linux the
  /// checked descriptor, `/proc/self/fd/<n>`.
  final String? program;

  final List<CheckedFile> _files;

  /// Whether the checked files are still held.
  bool get held => _files.any((file) => file.isOpen);

  bool _claimed = false;

  /// Takes this check for one start: false when it was released or another start took it.
  bool claim() {
    if (_claimed || !held) return false;
    _claimed = true;
    return true;
  }

  /// Lets the checked files go. Calling it again does nothing.
  void release() {
    for (final file in _files) {
      file.close();
    }
  }
}

/// What to start for the emulator host: [command], and [checked] for a release host. [core] is the
/// release's SwanStation, or null when a debug build runs ANYPS5_RETRO_HOST with any core.
class RetroHostLaunch {
  const RetroHostLaunch({required this.command, this.checked, this.core});

  final List<String> command;
  final RetroHostChecked? checked;
  final String? core;
}

/// Finding and checking the emulator host as anyps5-retro-host docs/protocol.md "Finding and
/// checking the host" asks: releases signed like launcher releases (SHA256SUMS and
/// SHA256SUMS.sig), each system's zip listed file by file in its `.files`.
abstract final class RetroHostRelease {
  /// The oldest host this launcher runs, even signed, so an old host with a known fault cannot be
  /// put back.
  static const minimumVersion = RetroHostVersion(1, 0, 0);

  /// The folder beside the launcher's executable that holds the host: the unpacked zip with
  /// SHA256SUMS, SHA256SUMS.sig and the `.files` kept beside it.
  static const folderName = 'retro-host';

  /// Names a host for debug builds to run without any check.
  static const debugVariable = 'ANYPS5_RETRO_HOST';

  /// Whether this is a debug build: neither release (`dart.vm.product`) nor profile
  /// (`dart.vm.profile`), as Flutter's kDebugMode.
  static const debugBuild = !bool.fromEnvironment('dart.vm.product') && !bool.fromEnvironment('dart.vm.profile');

  /// The folder of [folderName] beside this launcher's executable (GetModuleFileNameW or
  /// /proc/self/exe, as Dart resolves it).
  static Directory get folder => Directory(p.join(p.dirname(Platform.resolvedExecutable), folderName));

  /// What to start: in a debug build the host ANYPS5_RETRO_HOST names, unchecked, when it is set;
  /// otherwise the host in [folder], checked by [checkBeforeStart]. Release and profile builds
  /// ignore the variable whatever [debug] says; [debug] false makes a debug build ignore it too.
  static Future<RetroHostLaunch> locate({
    Map<String, String>? environment,
    bool? debug,
    Directory? from,
    List<ReleaseKey>? keys,
    RetroHostSystem? system,
    RetroHostVersion minimum = minimumVersion,
  }) async {
    final override = (environment ?? Platform.environment)[debugVariable];
    if (debugBuild && (debug ?? true) && override != null && override.isNotEmpty) {
      return RetroHostLaunch(command: [File(override).absolute.path]);
    }
    final checked = await checkBeforeStart(from ?? folder, keys: keys, system: system, minimum: minimum);
    return RetroHostLaunch(command: [checked.executable], checked: checked, core: checked.core);
  }

  /// The checks before each start: the signature, the `.files` against SHA256SUMS, and the host
  /// executable and SwanStation against the `.files`, each hashed from a [CheckedFile] that stays
  /// held in the result.
  static Future<RetroHostChecked> checkBeforeStart(
    Directory folder, {
    List<ReleaseKey>? keys,
    RetroHostSystem? system,
    RetroHostVersion minimum = minimumVersion,
  }) async {
    final target = system ?? _currentSystem();
    final sums = _verify(
      _readSmall(p.join(folder.path, ReleaseSigning.sumsName)),
      _readSmall(p.join(folder.path, ReleaseSigning.signatureName)),
      keys,
    );
    final release = _releaseOf(sums, target, minimum);
    final listing = _readSmall(p.join(folder.path, release.filesName));
    if (sha256.convert(listing).toString() != sums.digestFor(release.filesName)) {
      throw RetroHostReleaseFailure('${release.filesName} does not match the signed release');
    }
    final files = parseFileList(listing);
    final held = <CheckedFile>[];
    try {
      for (final name in [target.executable, target.core]) {
        final expected = files[name];
        if (expected == null) throw RetroHostReleaseFailure('${release.filesName} does not list $name');
        final CheckedFile file;
        try {
          file = CheckedFile.open(p.join(folder.path, name));
        } on FileSystemException {
          throw RetroHostReleaseFailure('$name is missing or not a file');
        }
        held.add(file);
        if (await file.sha256Hex() != expected) {
          throw RetroHostReleaseFailure('$name does not match the signed release');
        }
      }
    } on Object {
      for (final file in held) {
        file.close();
      }
      rethrow;
    }
    if (!Platform.isWindows) {
      held[1].close();
    }
    return RetroHostChecked(
      version: release.version,
      executable: p.join(folder.path, target.executable),
      core: p.join(folder.path, target.core),
      files: held,
      program: held[0].execPath,
    );
  }

  /// The checks on download, then the unpacking: the signature, the zip and the `.files` against
  /// SHA256SUMS, and every file of the zip against the `.files`. [download] holds the files as
  /// published; [into] is replaced by the unpacked zip with SHA256SUMS, SHA256SUMS.sig and the
  /// `.files` beside it. Gives the version installed.
  static Future<RetroHostVersion> install(
    Directory download,
    Directory into, {
    List<ReleaseKey>? keys,
    RetroHostSystem? system,
    RetroHostVersion minimum = minimumVersion,
  }) async {
    final target = system ?? _currentSystem();
    final sumsBytes = _readSmall(p.join(download.path, ReleaseSigning.sumsName));
    final signatureBytes = _readSmall(p.join(download.path, ReleaseSigning.signatureName));
    final sums = _verify(sumsBytes, signatureBytes, keys);
    final release = _releaseOf(sums, target, minimum);
    final listing = _readSmall(p.join(download.path, release.filesName));
    if (sha256.convert(listing).toString() != sums.digestFor(release.filesName)) {
      throw RetroHostReleaseFailure('${release.filesName} does not match the signed release');
    }
    final zipPath = p.join(download.path, release.zipName);
    final List<int> zipBytes;
    try {
      zipBytes = await File(zipPath).readAsBytes();
    } on FileSystemException {
      throw RetroHostReleaseFailure('${release.zipName} is missing');
    }
    if (sums.digestFor(release.zipName) != sha256.convert(zipBytes).toString()) {
      throw RetroHostReleaseFailure('${release.zipName} does not match the signed release');
    }
    final files = parseFileList(listing);
    for (final name in [target.executable, target.core]) {
      if (!files.containsKey(name)) throw RetroHostReleaseFailure('${release.filesName} does not list $name');
    }
    final unpacked = _unpack(zipBytes, files, release.zipName);

    final staging = Directory('${into.path}.new');
    if (staging.existsSync()) staging.deleteSync(recursive: true);
    staging.createSync(recursive: true);
    try {
      for (final MapEntry(key: name, value: bytes) in unpacked.entries) {
        final file = File(p.joinAll([staging.path, ...name.split('/')]));
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync(bytes, flush: true);
      }
      File(p.join(staging.path, ReleaseSigning.sumsName)).writeAsBytesSync(sumsBytes, flush: true);
      File(p.join(staging.path, ReleaseSigning.signatureName)).writeAsBytesSync(signatureBytes, flush: true);
      File(p.join(staging.path, release.filesName)).writeAsBytesSync(listing, flush: true);
      if (!Platform.isWindows) {
        final made = await Process.run('chmod', ['755', p.join(staging.path, target.executable)]);
        if (made.exitCode != 0) throw const RetroHostReleaseFailure('the host could not be made executable');
      }
      if (into.existsSync()) into.deleteSync(recursive: true);
      staging.renameSync(into.path);
    } on Object {
      if (staging.existsSync()) staging.deleteSync(recursive: true);
      rethrow;
    }
    return release.version;
  }

  /// A `.files` list: `<64 hex digits>  <name>` a line, as shasum writes it, with `/` between
  /// directories. Each name is relative and plain: no `\`, no empty, `.` or `..` part, no `:`.
  static Map<String, String> parseFileList(List<int> bytes) {
    final String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      throw const RetroHostReleaseFailure('the file list cannot be read');
    }
    final line = RegExp(r'^([0-9a-f]{64})  (.+)$');
    final files = <String, String>{};
    for (final raw in const LineSplitter().convert(text)) {
      if (raw.isEmpty) continue;
      final match = line.firstMatch(raw);
      if (match == null) throw const RetroHostReleaseFailure('the file list has a line it cannot read');
      final name = match.group(2)!;
      final parts = name.split('/');
      if (name.contains(r'\') ||
          name.contains(':') ||
          parts.any((part) => part.isEmpty || part == '.' || part == '..') ||
          files.containsKey(name)) {
        throw const RetroHostReleaseFailure('the file list names a file it cannot');
      }
      files[name] = match.group(1)!;
    }
    if (files.isEmpty) throw const RetroHostReleaseFailure('the file list lists no file');
    return files;
  }

  static final _releaseName = RegExp(r'^anyps5-retro-host-([^-]+)-([a-z0-9]+-[a-z0-9]+)\.(zip|files)$');

  static ({RetroHostVersion version, String zipName, String filesName}) _releaseOf(
    SignedSums sums,
    RetroHostSystem system,
    RetroHostVersion minimum,
  ) {
    final listed = <String>[];
    for (final name in sums.digests.keys) {
      final match = _releaseName.firstMatch(name);
      if (match != null && match.group(2) == system.name && match.group(3) == 'files') listed.add(name);
    }
    if (listed.isEmpty) throw RetroHostReleaseFailure('the release has no host for ${system.name}');
    if (listed.length > 1) throw RetroHostReleaseFailure('the release lists more than one host for ${system.name}');
    final filesName = listed.single;
    final versionText = _releaseName.firstMatch(filesName)!.group(1)!;
    final version = RetroHostVersion.tryParse(versionText);
    if (version == null) throw RetroHostReleaseFailure('the host version $versionText cannot be read');
    if (version.compareTo(minimum) < 0) {
      throw RetroHostReleaseFailure('the host $version is older than $minimum, the oldest this launcher runs');
    }
    return (version: version, zipName: 'anyps5-retro-host-$versionText-${system.name}.zip', filesName: filesName);
  }

  static Map<String, List<int>> _unpack(List<int> zipBytes, Map<String, String> files, String zipName) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(zipBytes);
    } on Object {
      throw RetroHostReleaseFailure('$zipName cannot be read');
    }
    final unpacked = <String, List<int>>{};
    for (final entry in archive) {
      if (!entry.isFile && !entry.isSymbolicLink) continue;
      final expected = files[entry.name];
      if (entry.isSymbolicLink || expected == null || unpacked.containsKey(entry.name)) {
        throw RetroHostReleaseFailure('$zipName holds ${entry.name}, which its file list does not');
      }
      final bytes = entry.content;
      if (sha256.convert(bytes).toString() != expected) {
        throw RetroHostReleaseFailure('${entry.name} in $zipName does not match its file list');
      }
      unpacked[entry.name] = bytes;
    }
    for (final name in files.keys) {
      if (!unpacked.containsKey(name)) throw RetroHostReleaseFailure('$zipName does not hold $name');
    }
    return unpacked;
  }

  static SignedSums _verify(List<int> sums, List<int> signature, List<ReleaseKey>? keys) {
    try {
      return ReleaseSigning.verify(sums, signature, keys: keys);
    } on SigningFailure catch (failure) {
      throw RetroHostReleaseFailure(failure.message);
    }
  }

  static List<int> _readSmall(String path) {
    final file = File(path);
    try {
      if (file.lengthSync() > ReleaseSigning.largestFile) {
        throw RetroHostReleaseFailure('${p.basename(path)} is too large');
      }
      return file.readAsBytesSync();
    } on FileSystemException {
      throw RetroHostReleaseFailure('${p.basename(path)} is missing');
    }
  }

  static RetroHostSystem _currentSystem() =>
      RetroHostSystem.current ?? (throw const RetroHostReleaseFailure('no emulator host is released for this system'));
}
