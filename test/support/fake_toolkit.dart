import 'dart:io';

import 'package:path/path.dart' as p;

/// A toolkit whose relinker is a shell script that behaves like the real one on the outside:
/// it reads its arguments, prints a progress display rewritten with carriage returns, checks that
/// its input is an ELF and writes the output executable and a relinked guest module under app0/.
///
/// [mode] picks a behaviour: `ok`, `fail` (exits 3 after a message), `slow` (sleeps, to be
/// cancelled), `silent` (exits 0 but writes nothing). With [failOn] (a path relative to its
/// working directory) it fails as the real one fails a conversion, exit 2 with `FAIL:` and
/// `Input:` lines, while that file is in its input; every run's input files go to inputs.txt.
/// Like the real one it stops when two modules in its working directory share a file name
/// (whatever their case with --windows; fakelib, which it is never pointed at, aside), naming the
/// later of the two by path.
/// With [traceImports] it knows --trace-imports and libc.prx exports what the option needs; with
/// [refuseTrace] it stops as the real one does for a game without libc.prx when given the option;
/// with [refuseOption] it stops the same way whenever its arguments hold that option.
String makeFakeToolkit(
  String folder, {
  String mode = 'ok',
  String version = 'toolkit-1',
  bool windowsDlls = false,
  String? failOn,
  bool traceImports = false,
  bool refuseTrace = false,
  String? refuseOption,
}) {
  Directory(p.join(folder, 'libs')).createSync(recursive: true);
  File(p.join(folder, 'libs', 'libkernel.prx')).writeAsStringSync('kernel library');
  File(p.join(folder, 'libs', 'libSceVideoOut.prx')).writeAsStringSync('video library');
  File(p.join(folder, 'libs', 'README.txt')).writeAsStringSync('not a library');
  if (traceImports) File(p.join(folder, 'libs', 'libc.prx')).writeAsStringSync('exports TraceImport_nid_no_patch');
  if (windowsDlls) File(p.join(folder, 'libs', 'libwinpthread-1.dll')).writeAsStringSync('dll');
  File(p.join(folder, 'version.txt')).writeAsStringSync('$version\n');
  final argumentsFile = p.join(folder, 'arguments.txt');
  final inputsFile = p.join(folder, 'inputs.txt');
  if (File(inputsFile).existsSync()) File(inputsFile).deleteSync();
  final runsFile = p.join(folder, 'runs.txt');
  if (File(runsFile).existsSync()) File(runsFile).deleteSync();
  final script =
      '''
#!/bin/sh
${traceImports ? '# knows --trace-imports' : '# plain'}
printf '%s\\n' "\$*" >> "$runsFile"
${refuseTrace ? 'case "\$*" in *--trace-imports*) echo "FAIL: --trace-imports requires libc.prx among the libraries" >&2; echo "Input: \$PWD/eboot.bin" >&2; exit 2;; esac' : ''}
${refuseOption != null ? 'case "\$*" in *$refuseOption*) echo "FAIL: unknown option $refuseOption" >&2; echo "Input: \$PWD/eboot.bin" >&2; exit 2;; esac' : ''}
printf '%s\\n' "\$PWD" > "$argumentsFile"
for argument in "\$@"; do printf '%s\\n' "\$argument" >> "$argumentsFile"; done
for last; do :; done
output="\$last"
mode="$mode"
fold=0
case " \$* " in *" --windows "*) fold=1;; esac
echo "run" >> "$inputsFile"
find . -type f | sed 's|^\\./||' | sort >> "$inputsFile"
if [ "\$mode" = slow ]; then sleep 30; fi
if [ "\$mode" = silent ]; then exit 0; fi
head=\$(head -c 4 eboot.bin | od -An -tx1 | tr -d ' \\n')
if [ "\$head" != 7f454c46 ]; then echo "eboot.bin is not an ELF" >&2; exit 4; fi
printf 'Instruction scan | eboot.bin | 10%%\\rInstruction scan | eboot.bin | 100%%\\n'
printf 'Instruction conversion | eboot.bin | 50%%\\n'
printf 'PRX conversion | libgame.prx | 100%% (1/2)\\r'
printf 'PRX conversion | libgame.prx | 100%% (2/2)\\n'
if [ "\$mode" = fail ]; then echo "relink: unsupported relocation" >&2; exit 3; fi
conflict=\$(find . -type f ! -name eboot.bin ! -path './fakelib/*' | sed 's|^\\./||' | LC_ALL=C sort | awk -F/ -v fold="\$fold" '{ name = \$NF; if (fold) name = tolower(name); if (name in seen) { print; exit } seen[name] = 1 }')
if [ -n "\$conflict" ]; then
  echo "FAIL: Conflicting guest output filename: \${conflict##*/}.guest.prx" >&2
  echo "Input: \$PWD/\$conflict" >&2
  exit 2
fi
fail_on="${failOn ?? ''}"
if [ -n "\$fail_on" ] && [ -f "\$fail_on" ]; then
  echo "FAIL: Unsupported relocation type 0x25 (offset 0x1234)" >&2
  echo "Input: \$PWD/\$fail_on" >&2
  exit 2
fi
printf 'Write output | eboot.bin | 100%%\\n'
mkdir -p "\$(dirname "\$output")/app0/sce_module"
printf '#!/bin/sh\\necho relinked game "\$@"\\nenv | grep ^ANYPS5_ | sort\\npwd\\n' > "\$output"
printf 'relinked module' > "\$(dirname "\$output")/app0/sce_module/libgame.prx"
echo "Guest module: app0/sce_module/libgame.prx"
''';
  final relinker = p.join(folder, 'relinker');
  File(relinker).writeAsStringSync(script);
  if (!Platform.isWindows) Process.runSync('chmod', ['755', relinker]);
  // The same script under the Windows name, for tests of the Windows layout on a POSIX host.
  File(p.join(folder, 'relinker.exe')).writeAsStringSync(script);
  if (!Platform.isWindows) Process.runSync('chmod', ['755', p.join(folder, 'relinker.exe')]);
  return folder;
}

/// The files in the relinker's working directory, run by run.
List<List<String>> fakeRelinkerInputs(String toolkit) {
  final runs = <List<String>>[];
  final file = File(p.join(toolkit, 'inputs.txt'));
  if (!file.existsSync()) return runs;
  for (final line in file.readAsLinesSync()) {
    if (line == 'run') {
      runs.add([]);
    } else {
      runs.last.add(line);
    }
  }
  return runs;
}

/// The relinker's arguments of each run, joined by spaces.
List<String> fakeRelinkerRuns(String toolkit) {
  final file = File(p.join(toolkit, 'runs.txt'));
  return file.existsSync() ? file.readAsLinesSync() : const [];
}

/// The relinker's working directory and arguments from its last run.
List<String> fakeRelinkerArguments(String toolkit) => File(p.join(toolkit, 'arguments.txt')).readAsLinesSync();
