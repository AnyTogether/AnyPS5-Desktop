import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/game_process.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/installer.dart';
import 'package:anyps5_desktop/core/screenshots.dart';
import 'package:anyps5_desktop/ui/app_model.dart' hide Command, GameState;
import 'package:anyps5_desktop/ui/phone_art.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_process.dart';
import '../support/phone/fake_phone.dart';
import '../support/phone/messages.dart';
import '../support/ui_support.dart';
import 'desktop_features_test.dart' show FakeDesktop;

/// The phone drives the launcher as it does on the Mac: Play on a second game, the start the phone
/// can give up, what it is told the launcher is busy with, and the words over a game in front.
void main() {
  late Fixture fixture;
  late AppModel model;
  late FakeDesktop desktop;
  late FakeGameStarts starts;

  setUp(() async {
    desktop = FakeDesktop();
    fixture = makeFixture(desktop: desktop);
    model = fixture.model;
    starts = FakeGameStarts();
    model.startGame = starts.call;
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

  Game game(String titleId) => model.games.firstWhere((game) => game.titleId == titleId);
  Game orbit() => game('PPSA01001');
  Game neon() => game('PPSA02002');

  /// [game] unlocked with the engine in use: Play starts it.
  void installed(Game game) {
    final folder = Installer.installedFolder(game, model.root!);
    Directory(folder).createSync(recursive: true);
    File(p.join(folder, 'app.elf')).writeAsStringSync('#!/bin/sh\n');
    File(p.join(folder, Installer.recordName)).writeAsStringSync(
      '{"date":"2026-10-24T12:00:00Z","source":${jsonEncode(game.folder)},"system":"linux",'
      '"titleID":"${game.titleId}","toolkit":"${model.toolkitVersion}"}',
    );
  }

  void bothInstalled() {
    installed(orbit());
    installed(neon());
    model.rescan();
  }

  Future<FakePhone> pairedPhone() async {
    final phone = await FakePhone.connect(model.remote!.port!);
    phone.hello('phone-1', 'Pixel');
    await phone.next<Pairing>();
    await until(() => model.pairing != null);
    model.answerPairing(true);
    await phone.next<Welcome>();
    await until(() => model.remote!.connectedDevices.isNotEmpty);
    return phone;
  }

  group('item 1: Play on a second game', () {
    test('the first closes and the second starts once it has gone', () async {
      bothInstalled();
      final phone = await pairedPhone();
      phone.send(Launch(orbit().id));
      await until(() => model.running?.$1 == orbit());
      phone.send(Launch(neon().id));
      await until(() => model.running?.$1 == neon());
      expect(starts.started, hasLength(2));
      expect(starts.processes.first.ended, isTrue, reason: 'the first game is gone');
      expect(starts.processes.last.ended, isFalse);
      expect(model.selectedGame, neon());
      model.stopGame();
      await until(() => model.running == null);
      await phone.close();
    });

    test('with Save Sync on, the second waits for the first one\'s saves to sync', () async {
      bothInstalled();
      final sync = p.join(fixture.temp.path, 'OneDrive');
      Directory(sync).createSync();
      model.preferences
        ..saveSync = true
        ..syncFolder = sync;
      final phone = await pairedPhone();
      phone.send(Launch(orbit().id));
      await until(() => model.running?.$1 == orbit());
      phone.send(Launch(neon().id));
      await until(() => model.running?.$1 == neon());
      expect(starts.started, hasLength(2));
      model.stopGame();
      await until(() => model.running == null);
      await phone.close();
    });

    test('Launch on the game playing starts nothing and closes nothing', () async {
      bothInstalled();
      final phone = await pairedPhone();
      phone.send(Launch(orbit().id));
      await until(() => model.running?.$1 == orbit());
      phone.send(Launch(orbit().id));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(starts.started, hasLength(1));
      expect(starts.last.ended, isFalse);
      model.stopGame();
      await until(() => model.running == null);
      await phone.close();
    });
  });

  group('item 3 and 4: what the phone hears', () {
    test('a game starting is running for the phone, and Close gives the start up', () async {
      bothInstalled();
      final gate = Completer<void>();
      Future<RunningGame> held({
        required String installed,
        required Map<String, String> environment,
        List<String> arguments = const [],
        required String logFile,
        HostSystem? system,
        bool traced = false,
        List<String> notes = const [],
      }) async {
        await gate.future;
        return starts.call(installed: installed, environment: environment, logFile: logFile);
      }

      model.startGame = held;
      final phone = await pairedPhone();
      await phone.next<Library>();
      phone.send(Launch(orbit().id));
      await until(() => model.starting == orbit());
      final told = await phone.nextWhere<Library>((library) => library.running == orbit().id);
      expect(told.games.firstWhere((game) => game.id == orbit().id).state, GameState.starting);
      final activity = await phone.nextWhere<ActivityUpdate>(
        (update) => update.activity?.phase == ActivityPhase.starting,
      );
      expect(activity.activity!.id, orbit().id);
      phone.send(const CloseGame());
      await until(() => model.starting == null);
      expect(model.running, isNull);
      await phone.nextWhere<ActivityUpdate>((update) => update.activity == null);
      gate.complete();
      await until(() => starts.processes.isNotEmpty);
      await until(() => starts.last.ended);
      expect(model.running, isNull, reason: 'the start was given up: the process goes again');
      await phone.close();
    });

    test('a game waiting is told as queued, with the time since it began, to a phone that comes later', () async {
      model.queue.add(neon().id);
      model.refresh();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final phone = await pairedPhone();
      final update = await phone.nextWhere<ActivityUpdate>((update) => update.activity != null);
      expect(update.activity!.id, neon().id);
      expect(update.activity!.phase, ActivityPhase.queued);
      expect(update.activity!.elapsed, greaterThan(const Duration(milliseconds: 40)));
      model.queue.clear();
      model.refresh();
      await phone.nextWhere<ActivityUpdate>((update) => update.activity == null);
      await phone.close();
    });
  });

  group('item 5 and 6: with the launcher behind', () {
    test('a D-pad command brings the launcher forward', () async {
      desktop.focused = false;
      final phone = await pairedPhone();
      phone.send(const Command('down'));
      await until(() => desktop.calls.contains('raise'));
      await phone.close();
    });

    test('pairing and connecting are said over the game', () async {
      desktop.focused = false;
      final phone = await pairedPhone();
      await until(() => desktop.calls.contains('notify ${T.format('phoneOpenLauncher', ['Pixel'])}'));
      await until(() => desktop.calls.contains('notify ${T.text('phoneConnectedDetail')}'));
      expect(model.toast, T.format('phoneConnected', ['Pixel']));
      await phone.close();
    });

    test('with the launcher in front, no notice is added', () async {
      desktop.focused = true;
      final phone = await pairedPhone();
      await phone.close();
      expect(desktop.calls.where((call) => call.startsWith('notify')), isEmpty);
    });
  });

  group('item 2: art at the phone\'s size', () {
    Uint8List noise(int width, int height) {
      final random = Random(7);
      final pixels = Uint8List(width * height * 4);
      for (var index = 0; index < pixels.length; index++) {
        pixels[index] = index % 4 == 3 ? 255 : random.nextInt(256);
      }
      return PngEncoder.rgba(width, height, pixels);
    }

    Future<(int, int)> size(List<int> bytes) async {
      final codec = await ui.instantiateImageCodec(Uint8List.fromList(bytes));
      final frame = await codec.getNextFrame();
      final dimensions = (frame.image.width, frame.image.height);
      frame.image.dispose();
      codec.dispose();
      return dimensions;
    }

    test('a big picture comes down to the side asked for, keeping its shape', () async {
      final made = await PhoneArt.smaller(noise(1600, 800), PhoneArt.iconSide);
      expect(await size(made), (256, 128));
    });

    test('a picture no larger than the side goes as it is', () async {
      final source = noise(100, 80);
      expect(identical(await PhoneArt.smaller(source, PhoneArt.iconSide), source), isTrue);
    });

    test('bytes that are not a picture go as they are', () async {
      final source = Uint8List.fromList(const [1, 2, 3, 4]);
      expect(identical(await PhoneArt.smaller(source, PhoneArt.iconSide), source), isTrue);
    });

    test('a file is kept until it changes, and a missing one is no art', () async {
      final art = PhoneArt();
      expect(await art.encoded(p.join(fixture.temp.path, 'none.png'), 256), isNull);
      expect(await art.encoded(null, 256), isNull);
      final file = File(p.join(fixture.temp.path, 'art.png'))..writeAsBytesSync(noise(400, 400));
      final first = await art.encoded(file.path, 256);
      expect(await size(base64.decode(first!)), (256, 256));
      // Other pixels under the same time stamp: what was made is what goes.
      final stamp = file.lastModifiedSync();
      file
        ..writeAsBytesSync(noise(300, 300))
        ..setLastModifiedSync(stamp);
      expect(await art.encoded(file.path, 256), first);
      file.setLastModifiedSync(stamp.add(const Duration(seconds: 5)));
      expect(await art.encoded(file.path, 256), isNot(first));
    });

    test('the phone gets the small pictures', () async {
      // The fixture's art is small; a big background shows the resize reach the phone.
      File(orbit().background!).writeAsBytesSync(noise(1920, 1080));
      final phone = await pairedPhone();
      phone.send(WantArt(orbit().id));
      final art = await phone.next<Art>();
      expect(await size(base64.decode(art.background!)), (1280, 720));
      await phone.close();
    });
  });
}
