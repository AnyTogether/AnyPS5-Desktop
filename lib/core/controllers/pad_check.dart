import 'dart:async';

import '../host.dart';
import 'pad_info.dart';
import 'sdl_pads.dart';
import 'troubleshooter.dart';

/// `anyps5_tool pads`: the controllers as the launcher sees them, without its window. SDL2 is
/// loaded (from [sdlPath], else where the launcher looks), the pads are read for [seconds] with
/// every connect, disconnect and press printed, then the troubleshooter's findings for this
/// system. For bug reports and checks on a machine without the interface.
Future<int> padCheck({
  required StringSink out,
  required HostSystem system,
  String? sdlPath,
  int seconds = 3,
  SystemProbe? probe,
  List<String>? candidates,
  String executable = '',
}) async {
  String? failure;
  final sdl = SdlLibrary.load(
    paths: sdlPath != null ? [sdlPath] : candidates,
    failure: (why) => failure = why,
  );
  final roster = PadRoster();
  var unmapped = const <String>[];
  if (sdl == null) {
    out.writeln('SDL2: not loaded: $failure');
  } else {
    out.writeln('SDL2: ${sdl.version} loaded');
    final source = SdlPadSource(sdl, every: const Duration(milliseconds: 16));
    source.onPadsChanged = () {
      for (final line in roster.sync(source.pads)) {
        out.writeln(line);
      }
    };
    source.start((event) {
      if (event.toString().contains('down')) out.writeln('  $event');
    });
    await Future<void>.delayed(Duration(seconds: seconds));
    unmapped = source.unmapped;
    source.stop();
    out.writeln(roster.pads.isEmpty ? 'controllers: none' : 'controllers: ${roster.pads.length}');
    for (final pad in roster.pads) {
      out.writeln('  ${pad.reportLine}');
    }
    for (final name in unmapped) {
      out.writeln('  no mapping: $name');
    }
  }
  final facts = probe == null
      ? PadFacts(system: system)
      : await () async {
          final results = await Future.wait<Object?>([
            probe.processes(),
            probe.services(PadTroubleshooter.windowsServices),
            probe.steamPlayStationSupport(),
            probe.hidrawDenied(),
            probe.unreadableControllers(),
          ]);
          return PadFacts(
            system: system,
            pads: roster.pads,
            sdlLoaded: sdl != null,
            sdlFailure: failure,
            unmapped: unmapped,
            processes: results[0]! as Set<String>,
            services: results[1]! as Set<String>,
            steamPlayStationSupport: results[2] as int?,
            hidrawDenied: results[3]! as bool,
            refused: results[4]! as List<String>,
            executable: executable,
          );
        }();
  out.writeln('steam PlayStation support: ${facts.steamPlayStationSupport ?? 'not found'}');
  out.writeln('drivers: ${facts.services.isEmpty ? 'none of HidHide, ViGEmBus, DsHidMini, BthPS3' : (facts.services.toList()..sort()).join(', ')}');
  final findings = PadTroubleshooter.diagnose(
    probe == null ? PadFacts(system: system, pads: roster.pads, sdlLoaded: sdl != null, sdlFailure: failure, unmapped: unmapped) : facts,
  );
  out.writeln('findings:');
  for (final finding in findings) {
    out.writeln('  ${finding.problem ? 'problem' : 'tip'} ${finding.id}${finding.arguments.isEmpty ? '' : ' ${finding.arguments}'}'
        '${finding.command == null ? '' : '\n    ${finding.command}'}');
  }
  return 0;
}
