import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'replay_buffer.dart' show ProcessRunner;

/// What the operating system kept of how a launcher run ended, for the report of a run that
/// ended without closing (as the Mac adds macOS's crash report):
///
/// - Windows: the newest Windows Error Reporting report (Report.wer) of the launcher's program
///   since the run started: the event, the module that faulted, the exception code and offset.
/// - Linux: systemd-coredump's core dump of that process (coredumpctl): the signal and the
///   crashed thread's first frames; else the kernel's out-of-memory kill of it.
class SystemCrashReport {
  SystemCrashReport._();

  /// The start of the part of a report that tells what the system kept of the run.
  static const heading = 'System crash report';

  /// The crashed thread's frames a report keeps.
  static const frames = 14;

  /// What Windows or Linux kept of the run [pid] that started at [since], or a line saying it
  /// kept nothing.
  static Future<String> find({
    required DateTime since,
    required int pid,
    String? executable,
    Map<String, String>? environment,
    ProcessRunner? run,
  }) async {
    final program = executable ?? Platform.resolvedExecutable;
    if (Platform.isWindows) {
      return windows(werFolders(environment ?? Platform.environment), since: since, executable: program) ??
          noneOnWindows;
    }
    if (Platform.isLinux) return await linux(pid, since: since, run: run ?? _run) ?? noneOnLinux;
    return '$heading: none looked for on this system.';
  }

  static const noneOnWindows =
      '$heading: none for this run in Windows Error Reporting. A crash usually leaves one there; ending it from '
      'the task manager leaves none.';

  static const noneOnLinux =
      '$heading: none for this run (coredumpctl has no core dump of it, or systemd-coredump is not installed), '
      'and the kernel log readable here names no out-of-memory kill of it.';

  // Windows.

  /// Where Windows Error Reporting keeps reports: the user's and the computer's, sent or not.
  static List<String> werFolders(Map<String, String> environment) {
    final local = environment['LOCALAPPDATA'];
    final shared = environment['ProgramData'] ?? environment['PROGRAMDATA'];
    return [
      for (final root in [?local, ?shared])
        for (final kind in ['ReportArchive', 'ReportQueue']) p.windows.join(root, 'Microsoft', 'Windows', 'WER', kind),
    ];
  }

  /// The newest crash or hang report of [executable] in [folders] written since [since].
  static String? windows(List<String> folders, {required DateTime since, required String executable}) {
    final program = p.windows.basename(executable).toLowerCase();
    final found = <(File, DateTime)>[];
    for (final folder in folders) {
      try {
        for (final entity in Directory(folder).listSync()) {
          final name = p.basename(entity.path);
          if (entity is! Directory || !(name.startsWith('AppCrash_') || name.startsWith('AppHang'))) continue;
          final file = File(p.join(entity.path, 'Report.wer'));
          if (!file.existsSync()) continue;
          final written = file.lastModifiedSync();
          if (!written.isBefore(since)) found.add((file, written));
        }
      } on FileSystemException {
        // Not there, or not readable: nothing from it.
      }
    }
    found.sort((a, b) => b.$2.compareTo(a.$2));
    for (final (file, _) in found) {
      final String text;
      try {
        text = decodeWer(file.readAsBytesSync());
      } on FileSystemException {
        continue;
      }
      final values = werValues(text);
      final names = [values['NsAppName'], values['Sig[0].Value'], values['AppPath']].nonNulls;
      if (!names.any((name) => p.windows.basename(name).toLowerCase() == program)) continue;
      return werSummary(values, file.path);
    }
    return null;
  }

  /// Report.wer is UTF-16 (little endian, with its mark); an old one may be plain text.
  static String decodeWer(List<int> bytes) {
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
      final units = <int>[for (var i = 2; i + 1 < bytes.length; i += 2) bytes[i] | bytes[i + 1] << 8];
      return String.fromCharCodes(units);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// Report.wer's key=value lines.
  static Map<String, String> werValues(String text) => {
    for (final line in const LineSplitter().convert(text))
      if (line.indexOf('=') case final at when at > 0) line.substring(0, at).trim(): line.substring(at + 1).trim(),
  };

  /// `System crash report (Windows Error Reporting, <file>, attach it to the issue):`, the event
  /// and each of its signature's names and values (the module that faulted, the exception code).
  static String werSummary(Map<String, String> values, String file) {
    final lines = ['$heading (Windows Error Reporting, $file, attach it to the issue):'];
    final event = [values['EventType'], values['FriendlyEventName']].nonNulls.join(', ');
    if (event.isNotEmpty) lines.add('  Event: $event');
    for (var i = 0; i < 16; i++) {
      final name = values['Sig[$i].Name'];
      final value = values['Sig[$i].Value'];
      if (name != null && value != null) lines.add('  $name: $value');
    }
    return lines.join('\n');
  }

  // Linux.

  /// The core dump of [pid] (coredumpctl), else the kernel's out-of-memory kill of it.
  static Future<String?> linux(int pid, {required DateTime since, required ProcessRunner run}) async {
    final after = '--since=@${since.toUtc().millisecondsSinceEpoch ~/ 1000}';
    final dump = await _output(run, 'coredumpctl', ['info', '--no-pager', after, '$pid']);
    final told = dump == null ? null : coreDumpSummary(dump);
    if (told != null) return told;
    final kernel = await _output(run, 'journalctl', ['-k', '-q', '--no-pager', '-o', 'short-iso', after]);
    final killed = kernel == null ? null : memoryKill(kernel, pid);
    return killed == null ? null : '$heading: no core dump. $killed';
  }

  /// coredumpctl info's signal, time and the first thread's first frames.
  static String? coreDumpSummary(String output) {
    final lines = const LineSplitter().convert(output);
    String? field(String name) {
      for (final line in lines) {
        final trimmed = line.trimLeft();
        if (trimmed.startsWith('$name: ')) return trimmed.substring(name.length + 2).trim();
      }
      return null;
    }

    final signal = field('Signal');
    if (signal == null) return null;
    final told = ['$heading (systemd-coredump, coredumpctl info):', '  Signal: $signal'];
    if (field('Timestamp') case final at?) told.add('  Timestamp: $at');
    if (field('Executable') case final executable?) told.add('  Executable: $executable');
    final stack = lines.indexWhere((line) => line.trimLeft().startsWith('Stack trace of thread'));
    if (stack >= 0) {
      told.add('  ${lines[stack].trim()}');
      told.addAll(
        lines
            .skip(stack + 1)
            .map((line) => line.trim())
            .takeWhile((line) => line.startsWith('#'))
            .take(frames)
            .map((frame) => '    $frame'),
      );
    }
    return told.join('\n');
  }

  /// The kernel's `Out of memory: Killed process <pid> (…)` line for [pid].
  static String? memoryKill(String kernelLog, int pid) {
    for (final line in const LineSplitter().convert(kernelLog)) {
      if (line.contains('Killed process $pid ')) return 'The kernel ended it for memory: ${line.trim()}';
    }
    return null;
  }

  static Future<String?> _output(ProcessRunner run, String executable, List<String> arguments) async {
    try {
      final result = await run(executable, arguments);
      return result.exitCode == 0 ? '${result.stdout}' : null;
    } on Object {
      return null;
    }
  }

  /// A tool that does not answer within a few seconds is left: the report goes without it.
  static Future<ProcessResult> _run(String executable, List<String> arguments) async {
    final process = await Process.start(executable, arguments);
    final out = process.stdout.transform(const SystemEncoding().decoder).join();
    unawaited(process.stderr.drain<void>());
    final code = await process.exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        process.kill();
        return -1;
      },
    );
    return ProcessResult(process.pid, code, code == -1 ? '' : await out, '');
  }
}
