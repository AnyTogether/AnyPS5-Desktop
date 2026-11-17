import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

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

/// A signed release that has no host for this system: nothing is wrong with it, it is just not
/// for this launcher.
class RetroHostNotReleased extends RetroHostReleaseFailure {
  const RetroHostNotReleased(super.message);
}

/// One system a host release is built for: `<os>-<arch>` in its file names, and the names of the
/// host, of SwanStation and of LRPS2 inside its zip (the host repository's
/// tools/package_release.py). A release that does not ship LRPS2 has no [ps2Core] in its zip.
class RetroHostSystem {
  const RetroHostSystem(this.name, {required this.executable, required this.core, required this.ps2Core});

  final String name;
  final String executable;
  final String core;
  final String ps2Core;

  static const windowsX64 = RetroHostSystem(
    'windows-x64',
    executable: 'anyps5-retro-host.exe',
    core: 'swanstation_libretro.dll',
    ps2Core: 'pcsx2_libretro.dll',
  );
  static const linuxX64 = RetroHostSystem(
    'linux-x64',
    executable: 'anyps5-retro-host',
    core: 'swanstation_libretro.so',
    ps2Core: 'pcsx2_libretro.so',
  );
  static const macosArm64 = RetroHostSystem(
    'macos-arm64',
    executable: 'anyps5-retro-host',
    core: 'swanstation_libretro.dylib',
    ps2Core: 'pcsx2_libretro.dylib',
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
  bool operator ==(Object other) =>
      other is RetroHostVersion && other.major == major && other.minor == minor && other.patch == patch;

  @override
  int get hashCode => Object.hash(major, minor, patch);

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
    this.ps2Core,
    this.program,
  });

  final RetroHostVersion version;

  /// The host executable's path, the command's first argument.
  final String executable;

  /// The SwanStation library the release ships: with [ps2Core], the only cores a release launcher
  /// runs.
  final String core;

  /// The LRPS2 library the release ships, checked with the others, or null when its `.files` lists
  /// none: a release without PS2.
  final String? ps2Core;

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

/// A release whose SHA256SUMS is signed by a trusted key, and the names of this system's files in
/// it: [zipName] and [filesName], with their digests in [sums].
class RetroHostSignedRelease {
  const RetroHostSignedRelease({
    required this.version,
    required this.zipName,
    required this.filesName,
    required this.sums,
  });

  final RetroHostVersion version;
  final String zipName;
  final String filesName;
  final SignedSums sums;
}

/// Finding and checking the emulator host as anyps5-retro-host docs/protocol.md "Finding and
/// checking the host" asks: releases signed like launcher releases (SHA256SUMS and
/// SHA256SUMS.sig), each system's zip listed file by file in its `.files`.
abstract final class RetroHostRelease {
  /// The oldest host this launcher runs, even signed, so an old host with a known fault cannot be
  /// put back.
  static const minimumVersion = RetroHostVersion(1, 0, 0);

  /// The file beside an installed host that keeps the tag it was published under, so the check
  /// before each start holds the signed version to it too. Its name starts with a dot, which no
  /// file of a release may ([parseFileList]).
  static const tagName = '.release-tag';

  /// Refuses a release whose signed [version] is not the one its [tag] gives: the launcher picks a
  /// release by its tag, so an older signed host published again under a higher tag would
  /// otherwise be taken for an update.
  static void checkTag(String tag, RetroHostVersion version) {
    if (tag != 'v$version') throw RetroHostReleaseFailure('the release tagged $tag is signed as host $version');
  }

  /// The checks before each start: the signature, the tag kept on install against the signed
  /// version, the `.files` against SHA256SUMS, and the host executable, SwanStation and, when the
  /// `.files` lists it, LRPS2 against the `.files`, each hashed from a [CheckedFile] that stays held
  /// in the result. LRPS2 is checked for a PS1 game too, since one host plays the next game, PS1 or
  /// PS2, on the cores checked when it started.
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
    checkTag(_readTag(folder), release.version);
    final listing = _readSmall(p.join(folder.path, release.filesName));
    if (sha256.convert(listing).toString() != sums.digestFor(release.filesName)) {
      throw RetroHostReleaseFailure('${release.filesName} does not match the signed release');
    }
    final files = parseFileList(listing);
    final ps2 = files.containsKey(target.ps2Core);
    final held = <CheckedFile>[];
    try {
      for (final name in [target.executable, target.core, if (ps2) target.ps2Core]) {
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
      for (final core in held.skip(1)) {
        core.close();
      }
    }
    return RetroHostChecked(
      version: release.version,
      executable: p.join(folder.path, target.executable),
      core: p.join(folder.path, target.core),
      ps2Core: ps2 ? p.join(folder.path, target.ps2Core) : null,
      files: held,
      program: held[0].execPath,
    );
  }

  /// The checks on download, then the unpacking: the signature, the signed version against [tag],
  /// the zip and the `.files` against SHA256SUMS, and every file of the zip against the `.files`.
  /// [download] holds the files as published under [tag]; [into] is replaced by the unpacked zip
  /// with SHA256SUMS, SHA256SUMS.sig, the `.files` and the tag ([tagName]) beside it. The reading,
  /// hashing and writing run on another isolate, so the window stays responsive; only the two
  /// renames that put the new host in place run here. Gives the version installed.
  static Future<RetroHostVersion> install(
    Directory download,
    Directory into, {
    required String tag,
    List<ReleaseKey>? keys,
    RetroHostSystem? system,
    RetroHostVersion minimum = minimumVersion,
  }) async {
    final target = system ?? _currentSystem();
    final from = download.path;
    final staging = Directory('${into.path}.new');
    final stagingPath = staging.path;
    final version = await Isolate.run(
      () => _stage(from, stagingPath, tag: tag, keys: keys, system: target, minimum: minimum),
    );
    try {
      _replace(into, staging);
    } on Object {
      if (staging.existsSync()) staging.deleteSync(recursive: true);
      rethrow;
    }
    return version;
  }

  /// [install]'s checks and unpacking into [stagingPath], on its own isolate.
  static Future<RetroHostVersion> _stage(
    String download,
    String stagingPath, {
    required String tag,
    required List<ReleaseKey>? keys,
    required RetroHostSystem system,
    required RetroHostVersion minimum,
  }) async {
    final sumsBytes = _readSmall(p.join(download, ReleaseSigning.sumsName));
    final signatureBytes = _readSmall(p.join(download, ReleaseSigning.signatureName));
    final release = signed(sumsBytes, signatureBytes, tag: tag, keys: keys, system: system, minimum: minimum);
    final sums = release.sums;
    final listing = _readSmall(p.join(download, release.filesName));
    if (sha256.convert(listing).toString() != sums.digestFor(release.filesName)) {
      throw RetroHostReleaseFailure('${release.filesName} does not match the signed release');
    }
    final List<int> zipBytes;
    try {
      zipBytes = File(p.join(download, release.zipName)).readAsBytesSync();
    } on FileSystemException {
      throw RetroHostReleaseFailure('${release.zipName} is missing');
    }
    if (sums.digestFor(release.zipName) != sha256.convert(zipBytes).toString()) {
      throw RetroHostReleaseFailure('${release.zipName} does not match the signed release');
    }
    final files = parseFileList(listing);
    for (final name in [system.executable, system.core]) {
      if (!files.containsKey(name)) throw RetroHostReleaseFailure('${release.filesName} does not list $name');
    }
    final unpacked = _unpack(zipBytes, files, release.zipName);

    final staging = Directory(stagingPath);
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
      File(p.join(staging.path, tagName)).writeAsStringSync(tag, flush: true);
      if (!Platform.isWindows) {
        final made = await Process.run('chmod', ['755', p.join(staging.path, system.executable)]);
        if (made.exitCode != 0) throw const RetroHostReleaseFailure('the host could not be made executable');
      }
    } on Object {
      if (staging.existsSync()) staging.deleteSync(recursive: true);
      rethrow;
    }
    return release.version;
  }

  /// Puts the host back after a launcher stopped between [_replace]'s two renames: [into] is
  /// missing and `<into>.old` is there. Every start checks the host put back all the same.
  static void restore(Directory into) {
    final old = Directory('${into.path}.old');
    if (into.existsSync() || !old.existsSync()) return;
    try {
      old.renameSync(into.path);
    } on FileSystemException {
      // Left for the next look or install.
    }
  }

  /// Puts [staging] in the place of [into] whole or not at all: [into] is first moved aside to
  /// `<into>.old`, which fails while a host started from it holds its files on Windows, so a host
  /// in use is never left half deleted. The old folder is removed afterwards when it can be. A
  /// launcher stopped between the two renames leaves only `<into>.old`, which [restore] puts back.
  static void _replace(Directory into, Directory staging) {
    restore(into);
    final old = Directory('${into.path}.old');
    if (old.existsSync()) {
      try {
        old.deleteSync(recursive: true);
      } on FileSystemException {
        throw const RetroHostReleaseFailure('an older host is still in use; close it and try again');
      }
    }
    if (into.existsSync()) {
      try {
        into.renameSync(old.path);
      } on FileSystemException {
        throw const RetroHostReleaseFailure('the host is in use; close it and try again');
      }
    }
    try {
      staging.renameSync(into.path);
    } on FileSystemException {
      if (old.existsSync()) old.renameSync(into.path);
      throw const RetroHostReleaseFailure('the new host could not be put in place');
    }
    try {
      if (old.existsSync()) old.deleteSync(recursive: true);
    } on FileSystemException {
      // Removed by the next install.
    }
  }

  /// The signature of a release and the names it gives this [system]'s files: [sums] (SHA256SUMS)
  /// and [signature] (SHA256SUMS.sig) as downloaded from the release tagged [tag], whose version
  /// must be the signed one ([checkTag]). The first check on download, before anything else of the
  /// release is fetched.
  static RetroHostSignedRelease signed(
    List<int> sums,
    List<int> signature, {
    required String tag,
    List<ReleaseKey>? keys,
    RetroHostSystem? system,
    RetroHostVersion minimum = minimumVersion,
  }) {
    final signed = _verify(sums, signature, keys);
    final release = _releaseOf(signed, system ?? _currentSystem(), minimum);
    checkTag(tag, release.version);
    return RetroHostSignedRelease(
      version: release.version,
      zipName: release.zipName,
      filesName: release.filesName,
      sums: signed,
    );
  }

  /// The version of the host in [folder] as its SHA256SUMS names it, read without any check, for
  /// showing; null when the folder holds no host release for [system] (the sums list every
  /// system's `.files`, but only this system's is kept beside the host). Before a start
  /// [checkBeforeStart] checks it.
  static RetroHostVersion? installedVersion(Directory folder, {RetroHostSystem? system}) {
    final target = system ?? RetroHostSystem.current;
    if (target == null) return null;
    try {
      final digests = ReleaseSigning.parseSums(File(p.join(folder.path, ReleaseSigning.sumsName)).readAsBytesSync());
      for (final name in digests.keys) {
        final match = _releaseName.firstMatch(name);
        if (match != null &&
            match.group(2) == target.name &&
            match.group(3) == 'files' &&
            File(p.join(folder.path, name)).existsSync()) {
          return RetroHostVersion.tryParse(match.group(1)!);
        }
      }
    } on FileSystemException {
      return null;
    } on SigningFailure {
      return null;
    }
    return null;
  }

  /// A `.files` list: `<64 hex digits>  <name>` a line, as shasum writes it, with `/` between
  /// directories. The names follow the host's `package_release.py --check`: each part is letters,
  /// digits and `._+-`, does not start or end with a dot and is no Windows device name, and no two
  /// names differ only in case, nor is one name a file and a folder of another; so no file
  /// unpacks outside its folder, or over another, on any system.
  static Map<String, String> parseFileList(List<int> bytes) {
    final String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      throw const RetroHostReleaseFailure('the file list cannot be read');
    }
    final line = RegExp(r'^([0-9a-f]{64})  (.+)$');
    final files = <String, String>{};
    final seenFiles = <String>{};
    final seenFolders = <String>{};
    for (final raw in const LineSplitter().convert(text)) {
      if (raw.isEmpty) continue;
      final match = line.firstMatch(raw);
      if (match == null) throw const RetroHostReleaseFailure('the file list has a line it cannot read');
      final name = match.group(2)!;
      final parts = name.split('/');
      if (!parts.every((part) => _memberPart.hasMatch(part) && !_deviceName.hasMatch(part))) {
        throw const RetroHostReleaseFailure('the file list names a file it cannot');
      }
      final key = name.toLowerCase();
      final folders = [for (var count = 1; count < parts.length; count++) parts.take(count).join('/').toLowerCase()];
      if (seenFiles.contains(key) || seenFolders.contains(key) || folders.any(seenFiles.contains)) {
        throw RetroHostReleaseFailure('the file list names $name twice, or as a file and a folder, ignoring case');
      }
      seenFiles.add(key);
      seenFolders.addAll(folders);
      files[name] = match.group(1)!;
    }
    if (files.isEmpty) throw const RetroHostReleaseFailure('the file list lists no file');
    return files;
  }

  static final _memberPart = RegExp(r'^[A-Za-z0-9_+-](?:[A-Za-z0-9._+-]*[A-Za-z0-9_+-])?$');
  static final _deviceName = RegExp(r'^(?:con|prn|aux|nul|com[0-9]|lpt[0-9])(?:\..*)?$', caseSensitive: false);

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
    if (listed.isEmpty) throw RetroHostNotReleased('the release has no host for ${system.name}');
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

  static String _readTag(Directory folder) {
    try {
      return utf8.decode(_readSmall(p.join(folder.path, tagName)));
    } on FormatException {
      throw const RetroHostReleaseFailure('the release tag beside the host cannot be read');
    }
  }

  static RetroHostSystem _currentSystem() =>
      RetroHostSystem.current ?? (throw const RetroHostReleaseFailure('no emulator host is released for this system'));
}
