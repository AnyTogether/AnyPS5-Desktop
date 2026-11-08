import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/capture/broadcast.dart';
import 'package:anyps5_desktop/core/capture/game_sound.dart';
import 'package:anyps5_desktop/core/capture/stream_packet.dart';
import 'package:anyps5_desktop/core/capture/video_encoders.dart';
import 'package:anyps5_desktop/core/desktop/desktop.dart';
import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/installer.dart';
import 'package:anyps5_desktop/ui/app_model.dart' hide Command, GameState;
import 'package:anyps5_desktop/ui/app_model.dart' as launcher show Command;
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/capture_fakes.dart';
import '../support/phone/fake_phone.dart';
import '../support/phone/messages.dart';
import '../support/ui_support.dart';
import 'desktop_features_test.dart' show FakeDesktop;

/// Remote Play and broadcasting in the launcher: the phone asks for the game, the launcher sends
/// it in the Mac's packets; Settings › Broadcasting, the quick menu and the phone's Go Live.
void main() {
  late Fixture fixture;
  late AppModel model;
  late List<List<String>> started;
  late List<StreamingProcess> processes;

  setUp(() async {
    fixture = makeFixture(
      desktop: FakeDesktop(),
      renderLiveBadge: (live, time, scale) async => RgbaImage(1, 1, Uint8List(4)),
    );
    model = fixture.model;
    started = [];
    processes = [];
    model.media
      ..ffmpegOverride = 'ffmpeg'
      ..encodersOverride = EncoderChoice(
        ffmpeg: 'ffmpeg',
        system: HostSystem.linux,
        run: (executable, arguments) async => ProcessResult(1, arguments.contains('libx264') ? 0 : 1, '', ''),
      )
      ..areaOverride = ((_) => const ScreenArea(0, 0, 1920, 1080))
      ..soundOverride = ((_) => SilentGameSound())
      ..startOverride = (executable, arguments) async {
        started.add(arguments);
        final process = StreamingProcess();
        processes.add(process);
        return process;
      };
    await model.startPhoneServer();
  });

  tearDown(() async {
    await model.stopPhoneServer();
    model.dispose();
    T.language = Language.english;
    fixture.dispose();
  });

  Future<void> until(bool Function() condition) async {
    for (var tries = 0; tries < 500 && !condition(); tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(condition(), isTrue);
  }

  Game orbit() => model.games.firstWhere((game) => game.titleId == 'PPSA01001');

  Future<({Future<void> done})> play() async {
    final installed = Installer.installedFolder(orbit(), model.root!);
    File(p.join(installed, 'app.elf')).writeAsStringSync('#!/bin/sh\nsleep 5\n');
    Process.runSync('chmod', ['755', p.join(installed, 'app.elf')]);
    File(p.join(installed, Installer.recordName)).writeAsStringSync(
      '{"date":"2026-10-24T12:00:00Z","source":${jsonEncode(orbit().folder)},"system":"linux",'
      '"titleID":"PPSA01001","toolkit":"arm-5ca076a87"}',
    );
    model.rescan();
    final playing = model.play(orbit());
    await until(() => model.running != null);
    return (done: playing);
  }

  Future<(FakePhone, Welcome)> pairedPhone() async {
    final phone = await FakePhone.connect(model.remote!.port!);
    phone.hello('phone-1', 'Pixel');
    await phone.next<Pairing>();
    await until(() => model.pairing != null);
    model.handle(launcher.Command.select);
    final welcome = await phone.next<Welcome>();
    await until(() => model.remote!.connectedDevices.isNotEmpty);
    return (phone, welcome);
  }

  test('Remote Play: the phone that asks gets the game\'s picture in the Mac\'s packets', () async {
    final playing = (await play()).done;
    final (phone, welcome) = await pairedPhone();
    // On a cable: the stream comes back on the control channel.
    phone.socket.add(phone.input(welcome.session));
    final video = phone.binary.stream
        .firstWhere((data) => ByteData.sublistView(data).getUint32(0, Endian.little) == StreamPacket.videoMagic)
        .timeout(const Duration(seconds: 5));
    phone.send(const StreamRequest(on: true, width: 2400, height: 1080));
    expect((await phone.next<Streaming>()).state, 'on');
    expect(started.single.join(' '), contains('-f x11grab'));
    expect(started.single.join(' '), contains('scale=1280:720'));
    processes.single
      ..write(FlvBuilder.header())
      ..write(FlvBuilder.sequence())
      ..write(
        FlvBuilder.frame([
          [0x65, 1, 2, 3],
        ], key: true),
      );
    final piece = await video;
    expect(ByteData.sublistView(piece).getUint16(16, Endian.little), 1, reason: 'a key frame');
    phone.send(const StreamRequest(on: false));
    await until(() => processes.single.ended);
    model.stopGame();
    await playing;
    await phone.close();
  }, skip: Platform.isWindows ? 'the stand-in game is a shell script' : false);

  test('Remote Play with no game says so', () async {
    final (phone, _) = await pairedPhone();
    phone.send(const StreamRequest(on: true, width: 1280, height: 720));
    expect((await phone.next<Streaming>()).state, 'noGame');
    expect(started, isEmpty);
    await phone.close();
  });

  test('Settings › Broadcasting sets up the service and the key, never showing it', () {
    model.open(Layer.settings);
    List<PanelRow> rows() => model.panelCategories().firstWhere((category) => category.id == 'broadcast').rows;
    expect(
      rows().map((row) => row.id),
      containsAllInOrder([
        'broadcast-service',
        'broadcast-key',
        'broadcast-paste',
        'broadcast-page',
        'broadcast-quality',
        'broadcast-link',
        'broadcast-private',
      ]),
    );
    final key = rows().firstWhere((row) => row.id == 'broadcast-key').kind as TextRow;
    expect(key.obscure, isTrue);
    expect(key.hint, T.text('broadcastKeyNone'));
    key.set('live_secret_9a8b');
    final saved = rows().firstWhere((row) => row.id == 'broadcast-key').kind as TextRow;
    expect(saved.value, isEmpty);
    expect(saved.hint, endsWith('9a8b'));
    expect(saved.hint, isNot(contains('secret')));
    (rows().firstWhere((row) => row.id == 'broadcast-service').kind as ChoiceRow).set(2);
    expect(rows().map((row) => row.id), contains('broadcast-server'));
    expect(rows().map((row) => row.id), isNot(contains('broadcast-page')));
    expect(File(Broadcaster.settingsFile(model.paths.config)).readAsStringSync(), isNot(contains('secret')));
  });

  test('the phone\'s Go Live broadcasts the game and is told it is live', () async {
    model.media.setKey('live_key');
    final playing = (await play()).done;
    final (phone, _) = await pairedPhone();
    phone.send(const Command('broadcastStart'));
    expect((await phone.next<Broadcasting>()).on, isTrue);
    await until(() => started.isNotEmpty);
    expect(started.single.last, 'rtmps://ingest.global-contribute.live-video.net/app/live_key');
    processes.single.write(utf8.encode('frame=30\nbitrate=3000.0kbits/s\nprogress=continue\n'));
    await until(() => model.media.phase is BroadcastLive);
    expect(model.toast, T.format('broadcastStartedNotice', ['Twitch']));
    model.open(Layer.quickMenu);
    final quick = model.panelCategories().single.rows.map((row) => row.id);
    expect(quick, containsAllInOrder(['resume', 'gameSettings', 'broadcast-state', 'broadcast-stop', 'closeGame']));
    phone.send(const Command('broadcastStop'));
    // Told as the state changes and again in answer to the ask, as the Mac does.
    var told = await phone.next<Broadcasting>();
    while (told.on) {
      told = await phone.next<Broadcasting>();
    }
    expect(told.on, isFalse);
    expect(processes.single.ended, isTrue);
    model.stopGame();
    await playing;
    await phone.close();
  }, skip: Platform.isWindows ? 'the stand-in game is a shell script' : false);

  test('Settings › Broadcasting sets the microphone, its level and the LIVE badge; Linux says why it has no badge', () {
    model.open(Layer.settings);
    List<PanelRow> rows() => model.panelCategories().firstWhere((category) => category.id == 'broadcast').rows;
    PanelRow row(String id) => rows().firstWhere((row) => row.id == id);
    bool has(String id) => rows().any((row) => row.id == id);
    final mic = row('broadcast-mic').kind as ToggleRow;
    expect(mic.value, isFalse);
    expect(has('broadcast-mic-level'), isFalse);
    mic.set(true);
    expect(model.media.settings.microphone, isTrue);
    final level = row('broadcast-mic-level').kind as StepperRow;
    expect(level.value, 80);
    level.set(50);
    expect(model.media.settings.microphoneLevel, 50);
    expect(File(Broadcaster.settingsFile(model.paths.config)).readAsStringSync(), contains('"microphoneLevel":50'));
    final badge = row('broadcast-badge').kind;
    expect(badge, isA<InfoRow>());
    expect((badge as InfoRow).text, T.text('broadcastBadgeLinux'));
    model.media.badgeOverride = true;
    final toggle = row('broadcast-badge').kind as ToggleRow;
    expect(toggle.value, isTrue);
    toggle.set(false);
    expect(model.media.settings.liveBadge, isFalse);
    expect((row('broadcast-badge').kind as ToggleRow).value, isFalse);
    expect(
      rows().map((row) => row.id),
      isNot(contains('broadcast-live-mic')),
      reason: 'the game rows leave it out here',
    );
  });

  test('the badge shows over the game while live and goes away when it ends', () async {
    final desktop = model.desktop as FakeDesktop;
    model.media
      ..badgeOverride = true
      ..setKey('live_key');
    final playing = (await play()).done;
    model.media.toggleBroadcast();
    await until(() => processes.isNotEmpty);
    expect(desktop.calls, isNot(contains('badge')), reason: 'not until frames go out');
    processes.single.write(utf8.encode('frame=30\nbitrate=3000.0kbits/s\nprogress=continue\n'));
    await until(() => model.media.phase is BroadcastLive);
    await until(() => desktop.calls.contains('badge'));
    model.open(Layer.quickMenu);
    expect(
      model.panelCategories().single.rows.map((row) => row.id),
      containsAllInOrder(['broadcast-state', 'broadcast-live-mic', 'broadcast-stop']),
    );
    model.closeOverlay();
    model.media.toggleBroadcast();
    await until(() => desktop.calls.contains('badge-off'));
    model.stopGame();
    await playing;
  }, skip: Platform.isWindows ? 'the stand-in game is a shell script' : false);

  test('Go Live with no key asks to set up first', () async {
    final playing = (await play()).done;
    model.open(Layer.quickMenu);
    final setup = model.panelCategories().single.rows.firstWhere((row) => row.id == 'broadcast-setup');
    expect(setup.detail, T.text('broadcastSetUpFirstDetail'));
    (setup.kind as ActionRow).run();
    expect(model.overlay, Layer.settings);
    expect(model.panelCategories()[model.panelCategory].id, 'broadcast');
    model.stopGame();
    await playing;
  }, skip: Platform.isWindows ? 'the stand-in game is a shell script' : false);
}
