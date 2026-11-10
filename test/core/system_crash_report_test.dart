import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/system_crash_report.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// What Windows or Linux kept of how a launcher run ended, for the report of its crash (as the
/// Mac's report carries macOS's crash report).
void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('anyps5_system_crash'));
  tearDown(() => temp.deleteSync(recursive: true));

  List<int> utf16(String text) => [
    0xFF,
    0xFE,
    for (final unit in text.codeUnits) ...[unit & 0xFF, unit >> 8],
  ];

  String wer(String program, {String code = 'c0000005'}) => [
    'Version=1',
    'EventType=APPCRASH',
    'NsAppName=$program',
    'Sig[0].Name=Application Name',
    'Sig[0].Value=$program',
    'Sig[3].Name=Fault Module Name',
    'Sig[3].Value=flutter_windows.dll',
    'Sig[6].Name=Exception Code',
    'Sig[6].Value=$code',
    'Sig[7].Name=Exception Offset',
    'Sig[7].Value=00000000001a2b3c',
    'FriendlyEventName=Stopped working',
    r'AppPath=C:\Users\ada\AnyPS5\' + program,
  ].join('\r\n');

  File report(String folder, String name, String text, DateTime written) {
    final file = File(p.join(temp.path, folder, name, 'Report.wer'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(utf16(text))
      ..setLastModifiedSync(written);
    return file;
  }

  group('Windows Error Reporting', () {
    test('the user\'s and the computer\'s folders, sent or not', () {
      expect(
        SystemCrashReport.werFolders({
          r'LOCALAPPDATA': r'C:\Users\ada\AppData\Local',
          'ProgramData': r'C:\ProgramData',
        }),
        [
          r'C:\Users\ada\AppData\Local\Microsoft\Windows\WER\ReportArchive',
          r'C:\Users\ada\AppData\Local\Microsoft\Windows\WER\ReportQueue',
          r'C:\ProgramData\Microsoft\Windows\WER\ReportArchive',
          r'C:\ProgramData\Microsoft\Windows\WER\ReportQueue',
        ],
      );
      expect(SystemCrashReport.werFolders(const {}), isEmpty);
    });

    test('the newest report of the launcher\'s program since the run started', () {
      final since = DateTime.utc(2026, 11, 9, 4);
      final folders = [p.join(temp.path, 'ReportArchive'), p.join(temp.path, 'ReportQueue'), p.join(temp.path, 'none')];
      const program = r'C:\Users\ada\AnyPS5\anyps5_desktop.exe';
      expect(
        SystemCrashReport.windows(folders, since: since, executable: program),
        isNull,
        reason: 'none written',
      );
      report(
        'ReportArchive',
        'AppCrash_anyps5_desktop._old_1',
        wer('anyps5_desktop.exe', code: 'c0000409'),
        DateTime.utc(2026, 11, 8),
      );
      report('ReportArchive', 'AppCrash_other.exe_abc_2', wer('other.exe'), DateTime.utc(2026, 11, 9, 4, 12));
      expect(
        SystemCrashReport.windows(folders, since: since, executable: program),
        isNull,
        reason: 'one from before this run, and another program\'s',
      );
      final file = report(
        'ReportQueue',
        'AppCrash_anyps5_desktop._abc_3',
        wer('anyps5_desktop.exe'),
        DateTime.utc(2026, 11, 9, 4, 11, 30),
      );
      final told = SystemCrashReport.windows(folders, since: since, executable: program)!;
      expect(
        told.split('\n').first,
        '${SystemCrashReport.heading} (Windows Error Reporting, ${file.path}, attach it to the issue):',
      );
      expect(told, contains('  Event: APPCRASH, Stopped working'));
      expect(told, contains('  Fault Module Name: flutter_windows.dll'));
      expect(told, contains('  Exception Code: c0000005'));
      expect(told, contains('  Exception Offset: 00000000001a2b3c'));
    });

    test('an old report in plain text is read too', () {
      expect(SystemCrashReport.decodeWer(utf8.encode('EventType=APPCRASH')), 'EventType=APPCRASH');
      expect(SystemCrashReport.decodeWer(utf16('EventType=APPCRASH')), 'EventType=APPCRASH');
    });
  });

  group('Linux', () {
    const coredump = '''
           PID: 4242 (anyps5_desktop)
           UID: 1000 (ada)
        Signal: 11 (SEGV)
     Timestamp: Mon 2026-11-09 04:11:30 UTC (2min ago)
    Executable: /home/ada/AnyPS5/anyps5_desktop
       Message: Process 4242 (anyps5_desktop) of user 1000 dumped core.

                Stack trace of thread 4242:
                #0  0x00007f0000001000 raise (libc.so.6 + 0x3e9fc)
                #1  0x00007f0000002000 abort (libc.so.6 + 0x2687f)
                #2  0x00007f0000003000 n/a (libflutter_linux_gtk.so + 0x1234)

                Stack trace of thread 4243:
                #0  0x00007f0000004000 futex_wait (libc.so.6 + 0x91234)
''';

    test('the core dump\'s signal, time and the crashed thread', () {
      final told = SystemCrashReport.coreDumpSummary(coredump)!;
      expect(told.split('\n'), [
        '${SystemCrashReport.heading} (systemd-coredump, coredumpctl info):',
        '  Signal: 11 (SEGV)',
        '  Timestamp: Mon 2026-11-09 04:11:30 UTC (2min ago)',
        '  Executable: /home/ada/AnyPS5/anyps5_desktop',
        '  Stack trace of thread 4242:',
        '    #0  0x00007f0000001000 raise (libc.so.6 + 0x3e9fc)',
        '    #1  0x00007f0000002000 abort (libc.so.6 + 0x2687f)',
        '    #2  0x00007f0000003000 n/a (libflutter_linux_gtk.so + 0x1234)',
      ]);
      expect(SystemCrashReport.coreDumpSummary('No coredumps found.'), isNull);
    });

    test('coredumpctl for the process, else the kernel\'s out-of-memory kill of it, else nothing', () async {
      final asked = <String>[];
      var dumps = '';
      var kernel = '';
      Future<ProcessResult> run(String executable, List<String> arguments) async {
        asked.add('$executable ${arguments.join(' ')}');
        final out = executable == 'coredumpctl' ? dumps : kernel;
        return ProcessResult(1, out.isEmpty ? 1 : 0, out, '');
      }

      final since = DateTime.utc(2026, 11, 9, 4);
      dumps = coredump;
      expect(await SystemCrashReport.linux(4242, since: since, run: run), startsWith(SystemCrashReport.heading));
      expect(asked.single, 'coredumpctl info --no-pager --since=@${since.millisecondsSinceEpoch ~/ 1000} 4242');

      dumps = '';
      kernel =
          '2026-11-09T04:11:30+0000 host kernel: Out of memory: Killed process 4242 (anyps5_desktop) total-vm:9000000kB, '
          'anon-rss:6000000kB\n';
      expect(
        await SystemCrashReport.linux(4242, since: since, run: run),
        '${SystemCrashReport.heading}: no core dump. The kernel ended it for memory: ${kernel.trim()}',
      );
      expect(
        await SystemCrashReport.linux(4243, since: since, run: run),
        isNull,
        reason: 'another process was killed',
      );
      Future<ProcessResult> missing(String executable, List<String> arguments) =>
          throw const ProcessException('coredumpctl', [], 'not found');
      expect(
        await SystemCrashReport.linux(4242, since: since, run: missing),
        isNull,
        reason: 'no systemd here',
      );
    });
  });
}
