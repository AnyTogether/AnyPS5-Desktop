import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/desktop/desktop.dart';
import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/installer.dart';
import 'package:anyps5_desktop/core/remote/remote_protocol.dart';
import 'package:anyps5_desktop/ui/app_model.dart' hide Command, GameState;
import 'package:anyps5_desktop/ui/app_model.dart' as launcher show Command;
import 'package:anyps5_desktop/ui/components.dart' show InputMode;
import 'package:anyps5_desktop/ui/engine_model.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_toolkit.dart';
import '../support/phone/fake_phone.dart';
import '../support/phone/messages.dart';
import '../support/phone/packets.dart' show PadButton;
import '../support/ui_support.dart';
import 'desktop_features_test.dart' show FakeDesktop;

/// The phone in a game on Windows and Linux: the launcher relays the phone's pad to the game's
/// engine (ANYPS5_REMOTE_PAD), which only AnyPS5-ARM's engine reads. A game on upstream's engine
/// used to ignore the phone without a word; the launcher now says so.
void main() {
  late Fixture fixture;
  late AppModel model;
  late FakeDesktop desktop;

  setUp(() async {
    desktop = FakeDesktop();
    fixture = makeFixture(
      desktop: desktop,
      renderNoticeCard: (title, detail, symbol, scale) async {
        desktop.noticeCards.add((title, detail));
        return RgbaImage(1, 1, Uint8List.fromList([1, 2, 3, 4]));
      },
    );
    model = fixture.model;
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

  /// Orbit Runner as unlocked with the engine of [toolkit] (its record's version.txt), and a
  /// stand-in game that runs until it is stopped.
  void unlockedWith(String toolkit) {
    final installed = Installer.installedFolder(orbit(), model.root!);
    File(p.join(installed, 'app.elf')).writeAsStringSync('#!/bin/sh\nsleep 5\n');
    if (!Platform.isWindows) Process.runSync('chmod', ['755', p.join(installed, 'app.elf')]);
    File(p.join(installed, Installer.recordName)).writeAsStringSync(
      '{"date":"2026-10-24T12:00:00Z","source":${jsonEncode(orbit().folder)},"system":"linux",'
      '"titleID":"PPSA01001","toolkit":"$toolkit"}',
    );
    model.rescan();
    expect(model.records[orbit().id]?.toolkit, toolkit);
  }

  Future<FakePhone> pairedPhone() async {
    final phone = await FakePhone.connect(model.remote!.port!);
    phone.hello('phone-1', 'Pixel');
    await phone.next<Pairing>();
    await until(() => model.pairing != null);
    model.handle(launcher.Command.select);
    await phone.next<Welcome>();
    await until(() => model.remote!.connectedDevices.isNotEmpty);
    return phone;
  }

  /// Starts Orbit Runner; the future completes once the game ended.
  Future<({Future<void> done})> play() async {
    // The copy as it is: these are about the engine it was made with, not about rebuilding it.
    final playing = model.play(orbit(), asItIs: true);
    await until(() => model.running != null);
    return (done: playing);
  }

  Future<void> stop(Future<void> playing) async {
    model.stopGame();
    await playing;
  }

  String gameLog() => File(model.paths.logFile('PPSA01001')).readAsStringSync();

  test('the engines: AnyPS5-ARM reads the phone, upstream does not, a folder of your own is unknown', () {
    expect(EngineModel.readsPhone('arm-5ca076a87'), isTrue);
    expect(EngineModel.readsPhone('upstream-v0.1.3'), isFalse);
    expect(EngineModel.readsPhone('toolkit-1'), isNull);
    expect(EngineModel.readsPhone(null), isNull);
  });

  test("a game on upstream's engine: the phone can't reach it, said at once and over the game", () async {
    unlockedWith('upstream-v0.1.3');
    final phone = await pairedPhone();
    desktop.focused = false;
    final playing = (await play()).done;
    expect(model.toast, T.text('phoneUpstreamGame'));
    await until(() => desktop.noticeCards.contains((T.text('phoneUpstreamGame'), null)));
    expect(gameLog(), contains("[anyps5-launcher] phones: 1 phone(s), 0 browser pad(s), upstream's engine"));
    await stop(playing);
    await phone.close();
  }, skip: Platform.isWindows ? 'the stand-in game is a shell script' : false);

  test('a phone that connects while an upstream game runs hears it then', () async {
    unlockedWith('upstream-v0.1.3');
    final playing = (await play()).done;
    expect(model.toast, isNot(T.text('phoneUpstreamGame')), reason: 'no phone yet, nothing to say');
    final phone = await pairedPhone();
    await until(() => model.toast == T.text('phoneUpstreamGame'));
    await stop(playing);
    await phone.close();
  }, skip: Platform.isWindows ? 'the stand-in game is a shell script' : false);

  test('no phone connected: nothing is said', () async {
    unlockedWith('upstream-v0.1.3');
    model.phoneAnswerWait = const Duration(milliseconds: 100);
    final playing = (await play()).done;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(model.toast, isNot(T.text('phoneUpstreamGame')));
    expect(model.toast, isNot(T.text('phoneNoAnswer')));
    expect(gameLog(), isNot(contains('[anyps5-launcher] phones:')));
    await stop(playing);
  }, skip: Platform.isWindows ? 'the stand-in game is a shell script' : false);

  test("a game on AnyPS5-ARM's engine gets the bridges and says hello: nothing is said", () async {
    unlockedWith('arm-5ca076a87');
    model.phoneAnswerWait = const Duration(milliseconds: 300);
    final phone = await pairedPhone();
    final playing = (await play()).done;
    final game = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    // The engine says hello every second on the bridge ANYPS5_REMOTE_PAD names.
    final hello = Timer.periodic(const Duration(milliseconds: 50), (_) {
      game.send(
        RemotePacket.hello(player: 1, takesPresses: true),
        InternetAddress.loopbackIPv4,
        model.remote!.bridgePorts.first,
      );
    });
    await until(() => model.remote!.gameHeard);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(model.toast, isNot(T.text('phoneNoAnswer')));
    expect(model.toast, isNot(T.text('phoneUpstreamGame')));
    expect(
      gameLog(),
      contains('[anyps5-launcher] phones: 1 phone(s), 0 browser pad(s), AnyPS5-ARM engine, reads them'),
    );
    hello.cancel();
    game.close();
    await stop(playing);
    await phone.close();
  }, skip: Platform.isWindows ? 'the stand-in game is a shell script' : false);

  test("an engine of the user's own that never answers on the bridges: said after the wait", () async {
    unlockedWith('toolkit-1');
    model.phoneAnswerWait = const Duration(milliseconds: 200);
    final phone = await pairedPhone();
    final playing = (await play()).done;
    expect(model.toast, isNot(T.text('phoneNoAnswer')), reason: 'the game gets its time to open its window');
    await until(() => model.toast == T.text('phoneNoAnswer'));
    await stop(playing);
    await phone.close();
  }, skip: Platform.isWindows ? 'the stand-in game is a shell script' : false);

  test("the phone's pad moves the launcher while no game plays; Options opens Settings; a game keeps it", () async {
    unlockedWith('arm-5ca076a87');
    final phone = await FakePhone.connect(model.remote!.port!);
    phone.hello('phone-1', 'Pixel');
    await phone.next<Pairing>();
    await until(() => model.pairing != null);
    model.handle(launcher.Command.select);
    final welcome = await phone.next<Welcome>();
    await until(() => model.remote!.connectedDevices.isNotEmpty);
    final udp = await phone.openUdp();
    var sequence = 0;
    void send(int buttons) => udp.send(
      phone.input(welcome.session, sequence: ++sequence, buttons: buttons),
      InternetAddress.loopbackIPv4,
      welcome.udpPort,
    );
    Future<void> press(int button) async {
      send(button);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      send(0);
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }

    expect(model.phonePadMovesLauncher, isTrue);
    // Options, the pad's settings button: Settings.
    await press(PadButton.options);
    await until(() => model.overlay == Layer.settings);
    expect(model.inputMode, InputMode.pad, reason: 'the hints are a controller\'s');
    // The D-pad moves through the rows as a controller's does.
    final row = model.panelRow;
    await press(PadButton.down);
    await until(() => model.panelRow != row);
    // Circle goes back, Options again leaves Settings too.
    await press(PadButton.options);
    await until(() => model.overlay == null);

    // A game playing (even with the launcher in front): the pad is the game's alone.
    final playing = (await play()).done;
    expect(model.phonePadMovesLauncher, isFalse);
    await press(PadButton.options);
    await press(PadButton.cross);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(model.overlay, isNull);
    await stop(playing);
    await phone.close();
  }, skip: Platform.isWindows ? 'the stand-in game is a shell script' : false);

  test("Settings › Phones says it while the engine in use is upstream's", () {
    model.open(Layer.settings);
    List<String> phoneRows() =>
        model.panelCategories().firstWhere((category) => category.id == 'phone').rows.map((row) => row.id).toList();
    expect(phoneRows(), isNot(contains('phoneUpstream')), reason: 'a folder of your own may be either');
    model.preferences.toolkitFolder = makeFakeToolkit(
      p.join(fixture.temp.path, 'upstream'),
      version: 'upstream-v0.1.3',
    );
    expect(model.toolkitVersion, 'upstream-v0.1.3');
    expect(phoneRows(), contains('phoneUpstream'));
    final row = model
        .panelCategories()
        .firstWhere((category) => category.id == 'phone')
        .rows
        .firstWhere((row) => row.id == 'phoneUpstream');
    expect(row.detail, T.text('phoneUpstreamSwitchDetail'));
    expect(row.kind, isA<ActionRow>(), reason: 'one press switches to AnyPS5-ARM\'s engine');
    model.preferences.toolkitFolder = makeFakeToolkit(p.join(fixture.temp.path, 'arm'), version: 'arm-5ca076a87');
    expect(phoneRows(), isNot(contains('phoneUpstream')));
  });
}
