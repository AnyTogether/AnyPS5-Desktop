import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/controllers/pad_info.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_client.dart';
import 'package:anyps5_desktop/core/gamepad/pad_navigation.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_protocol.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_session.dart';
import 'package:anyps5_desktop/ui/retro_host/retro_game_menu.dart';
import 'package:anyps5_desktop/ui/retro_host/retro_host_controls.dart';
import 'package:anyps5_desktop/ui/retro_host/retro_host_game.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fake_retro_host_session.dart';
import 'real_host_support.dart';

/// [RetroHostGame], [RetroHostControls] and [RetroGameMenu] against the real emulator host.
///
/// ANYPS5_RETRO_HOST_REAL names the JSON file of test/core/retro_host/retro_host_real_test.dart,
/// with one more optional key, `fakeCore`: the host repository's test core (tests/fake_core.c,
/// built beside the host as fake_core.dll or libfake_core.so). Without the variable both tests
/// are skipped; without `fakeCore` the second one is.
///
/// - SwanStation: OpenBIOS boots the PS-EXE, and the game's picture shows and changes; two
///   controllers connect port 2.
/// - The test core: Cross held on the controller at port 1 reaches the core, whose vibration comes
///   back to that controller's motors; the menu changes the core's colour option and the disc.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final configPath = Platform.environment['ANYPS5_RETRO_HOST_REAL'];
  if (configPath == null || configPath.isEmpty) {
    test('a game in the real host shows its frames and takes input', () {}, skip: 'ANYPS5_RETRO_HOST_REAL is not set');
    return;
  }
  final config = jsonDecode(File(configPath).readAsStringSync()) as Map<String, Object?>;
  String path(String key) => File(config[key]! as String).absolute.path;
  final environment = (config['environment'] as Map<String, Object?>?)?.cast<String, String>();

  late Directory work;
  setUp(() => work = Directory.systemTemp.createTempSync('retro-host-game-real-'));
  tearDown(() => work.deleteSync(recursive: true));

  test('SwanStation shows a changing picture and takes two controllers', () async {
    final system = Directory(p.join(work.path, 'system'))..createSync();
    File(path('bios')).copySync(p.join(system.path, 'openbios.bin'));
    final disc = p.join(work.path, 'program.cue');
    final built = Process.runSync(pythonPath(), [path('discBuilder'), path('program'), disc]);
    expect(built.exitCode, 0, reason: 'make_test_disc.py: ${built.stderr}');

    final session = RecordingSession(
      RetroHostClient.start(command: [path('host')], environment: environment, volume: 0, muted: true),
    );
    final game = RetroHostGame(session, volume: 0, muted: true);
    final pads = FakePads()..connect('one');
    final controls = RetroHostControls(game, pads: pads.reader);
    try {
      await game.start(
        RetroHostStartRequest(
          core: path('core'),
          disc: disc,
          system: system.path,
          saves: p.join(work.path, 'saves'),
          options: const {
            'swanstation_BIOS_PathNTSCU': 'openbios.bin',
            'swanstation_BIOS_PathNTSCJ': 'openbios.bin',
            'swanstation_BIOS_PathPAL': 'openbios.bin',
            'swanstation_GPU_ResolutionScale': '2',
          },
        ),
      );
      await until(() => game.phase != RetroHostGamePhase.loading, const Duration(seconds: 60));
      expect(game.phase, RetroHostGamePhase.playing, reason: 'status ${game.status?.toJson()} ${game.failure}');

      final pictures = <Uint8List>[];
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (pictures.length < 2 && DateTime.now().isBefore(deadline)) {
        final pixels = await framePixels(game.picture.value);
        if (pixels != null && showsPicture(pixels) && (pictures.isEmpty || !samePixels(pictures.first, pixels))) {
          pictures.add(pixels);
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      final image = game.picture.value;
      stdout.writeln('${game.picture.shown} pictures shown, last ${image?.width}x${image?.height}');
      expect(pictures, hasLength(2), reason: 'two pictures on screen that are not black and differ');

      pads.connect('two', const PadState(pressed: {PadButton.south}));
      Iterable<(String, Object?, Object?)> ports() => session.answers.where((answer) => answer.$1 == 'connectedPorts');
      await until(() => ports().isNotEmpty, const Duration(seconds: 2));
      pads.disconnect('two');
      await until(() => ports().length == 2, const Duration(seconds: 2));
      expect(ports(), [
        ('connectedPorts', 2, true),
        ('connectedPorts', 1, true),
      ], reason: 'the controls connected port 2 and let it go, and the host took both');
      await game.refresh();
      expect(game.phase, RetroHostGamePhase.playing);

      final stopped = await game.stop();
      expect(stopped?.ended, isTrue);
      expect(stopped?.errorCode, RetroErrorCode.none);
    } finally {
      controls.dispose();
      await game.shutdown();
      game.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test(
    'input reaches the core and its vibration, colour option and disc change come back',
    () async {
      final discs = Directory(p.join(work.path, 'discs'))..createSync();
      for (final name in ['disc1.cue', 'disc2.cue']) {
        File(p.join(discs.path, name)).writeAsStringSync('FILE "game.bin" BINARY\n');
      }
      final playlist = File(p.join(discs.path, 'game.m3u'))..writeAsStringSync('disc1.cue\ndisc2.cue\n');
      final system = Directory(p.join(work.path, 'system'))..createSync();
      File(p.join(system.path, 'fake-bios.bin')).writeAsBytesSync(Uint8List(16));

      final game = RetroHostGame.launch(command: [path('host')], environment: environment, volume: 0, muted: true);
      final pads = FakePads()..connect('pad');
      final motors = FakeMotors()..vibrating.add('pad');
      final controls = RetroHostControls(game, pads: pads.reader, motors: motors);
      final menu = RetroGameMenu(game, controls: controls);
      try {
        await game.start(
          RetroHostStartRequest(
            core: path('fakeCore'),
            disc: playlist.path,
            system: system.path,
            saves: p.join(work.path, 'saves'),
          ),
        );
        await until(() => game.phase != RetroHostGamePhase.loading, const Duration(seconds: 30));
        expect(game.phase, RetroHostGamePhase.playing, reason: 'status ${game.status?.toJson()} ${game.failure}');
        await until(() => game.picture.value != null, const Duration(seconds: 10));
        expect(_colour(await framePixels(game.picture.value)), 'blue');

        pads.states['pad'] = const PadState(pressed: {PadButton.south});
        await until(() => motors.orders.any((order) => order.$1 == 'pad' && order.$2 == 1), const Duration(seconds: 5));
        pads.states['pad'] = PadState.idle;
        await until(() => motors.orders.last.$2 == 0, const Duration(seconds: 5));
        stdout.writeln('motor orders: ${motors.orders}');

        await game.refresh();
        final option = menu.rows.whereType<RetroOptionRow>().firstWhere((row) => row.key == 'fake_color');
        expect(option.choice, 'Blue');
        expect(await menu.stepOption('fake_color', 1), isTrue);
        await until(() async => _colour(await framePixels(game.picture.value)) == 'green', const Duration(seconds: 5));

        final secondDisc = menu.rows.whereType<RetroDiscRow>().last;
        expect(secondDisc.enabled, isTrue);
        expect(await menu.chooseDisc(secondDisc), isTrue);
        await until(() async {
          await game.refresh();
          final discs = game.status?.discs;
          return discs != null && !discs.busy && discs.inserted == 1;
        }, const Duration(seconds: 10));
        expect(menu.discChangeFailed, isFalse);
        stdout.writeln('discs: ${game.status?.discs?.toJson()}');

        final stopped = await game.stop();
        expect(stopped?.errorCode, RetroErrorCode.none);
      } finally {
        menu.dispose();
        controls.dispose();
        await game.shutdown();
        game.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: config['fakeCore'] == null ? 'ANYPS5_RETRO_HOST_REAL names no fakeCore' : false,
  );
}

/// The test core's colour: its frames are blue (0xC0) or green (0xC0), with red counting frames.
String? _colour(Uint8List? pixels) {
  if (pixels == null) return null;
  final (green, blue) = (pixels[1], pixels[2]);
  if (blue == 0xC0 && green == 0) return 'blue';
  if (green == 0xC0 && blue == 0) return 'green';
  return 'rgb ${pixels[0]} $green $blue';
}
