import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/installer.dart';
import 'package:anyps5_desktop/core/toolkit_download.dart';
import 'package:anyps5_desktop/ui/app_model.dart' hide Command, GameState;
import 'package:anyps5_desktop/ui/app_model.dart' as launcher show Command;
import 'package:anyps5_desktop/ui/components.dart' show byteText;
import 'package:anyps5_desktop/ui/engine_model.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_github.dart';
import '../support/fake_toolkit.dart';
import '../support/phone/fake_phone.dart';
import '../support/phone/messages.dart';
import '../support/signing.dart';
import '../support/ui_support.dart';

/// The phone and the engine on Windows and Linux: only AnyPS5-ARM's engine reads the phone. A
/// first start downloads that one; a launcher that had upstream's keeps it, and is offered the
/// switch in one press when a phone connects or a game ran with one.
void main() {
  final key = TestReleaseKey('release');
  late FakeGitHub upstream;
  late FakeGitHub arm;
  late Fixture fixture;
  late AppModel model;
  var started = false;

  Future<void> until(bool Function() condition) async {
    for (var tries = 0; tries < 1000 && !condition(); tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(condition(), isTrue);
  }

  Future<void> start({bool onboarded = true, bool withToolkit = true}) async {
    upstream = await FakeGitHub.start();
    arm = await FakeGitHub.start(repository: ArmToolkitPackage.repository);
    upstream.releases.add(upstreamRelease('0.1.4'));
    arm.releases.add(signed(armRelease('v0.2.35-arm', '26d785b'), [key]));
    fixture = makeFixture(
      onboarded: onboarded,
      withToolkit: withToolkit,
      engine: upstream.api,
      armEngine: arm.api,
      armKeys: [key.key],
    );
    model = fixture.model;
    started = true;
  }

  tearDown(() async {
    if (!started) return;
    started = false;
    await model.stopPhoneServer();
    model.dispose();
    await upstream.close();
    await arm.close();
    T.language = Language.english;
    fixture.dispose();
  });

  /// Upstream's engine v0.1.4 in use, as a launcher that had it chosen before.
  void upstreamInUse() {
    model.preferences.toolkitFolder = makeFakeToolkit(
      p.join(fixture.temp.path, 'upstream'),
      version: 'upstream-v0.1.4',
    );
    expect(model.toolkitVersion, 'upstream-v0.1.4');
    expect(model.phoneEngineMissing, isTrue);
  }

  /// The key the launcher gave the phone, for it to come back without pairing again.
  String? phoneKey;

  Future<FakePhone> pairedPhone() async {
    final phone = await FakePhone.connect(model.remote!.port!);
    phone.hello('phone-1', 'Pixel');
    await phone.next<Pairing>();
    await until(() => model.pairing != null);
    model.handle(launcher.Command.select);
    phoneKey = (await phone.next<Welcome>()).key;
    await until(() => model.remote!.connectedDevices.isNotEmpty);
    return phone;
  }

  PanelRow row(String id) => model
      .panelCategories()
      .expand((category) => category.rows)
      .firstWhere((row) => row.id == id, orElse: () => throw StateError('no row $id'));

  group('a first start', () {
    test('chooses AnyPS5-ARM\'s engine; choices saved before keep the engine they had', () {
      final folder = Directory.systemTemp.createTempSync('preferences');
      addTearDown(() => folder.deleteSync(recursive: true));
      final file = p.join(folder.path, 'preferences.json');
      expect(Preferences.load(file, systemLocales: ['en-US']).engineSource, 'arm');
      // A launcher from before there was a choice saved none: upstream's, as it had.
      File(file).writeAsStringSync(jsonEncode({'onboarded': true, 'toolkitFolder': '/engines/v0.1.4'}));
      expect(Preferences.load(file).engineSource, 'upstream');
      File(file).writeAsStringSync(jsonEncode({'onboarded': true, 'engineSource': 'upstream'}));
      expect(Preferences.load(file).engineSource, 'upstream');
    });

    test('the welcome\'s engine step downloads AnyPS5-ARM\'s engine and uses it', () async {
      await start(onboarded: false, withToolkit: false);
      model.preferences.engineSource = 'arm';
      model.onboardingStep = 2;
      model.onboardingChoice = 1;
      model.onboardingConfirm();
      expect(model.onboardingStep, 3);
      await until(() => model.engine.armChecked);
      expect(model.engine.offered, isA<ArmToolkitPackage>());
      expect(EngineModel.offeredName(model.engine.offered!), 'AnyPS5-ARM 26d785b');
      expect(model.engine.latest, isNull, reason: 'upstream\'s releases are not asked');
      model.onboardingChoice = 0;
      model.onboardingConfirm();
      await until(() => model.engine.downloading == null && model.toolkitVersion == 'arm-26d785b');
      expect(model.onboardingChoice, 2, reason: 'on to the next card once it is in place');
      expect(EngineModel.readsPhone(model.toolkitVersion), isTrue);
    });

    test('a launcher that had upstream\'s engine chosen still downloads upstream\'s at the welcome', () async {
      await start(onboarded: false, withToolkit: false);
      model.onboardingStep = 2;
      model.onboardingChoice = 1;
      model.onboardingConfirm();
      await until(() => model.engine.latest != null);
      expect(EngineModel.offeredName(model.engine.offered!), 'v0.1.4');
      expect(model.engine.armChecked, isFalse);
    });
  });

  group('a phone with upstream\'s engine in use', () {
    test('connecting offers the switch over Home, once, and one press downloads and uses it', () async {
      await start();
      upstreamInUse();
      await model.startPhoneServer();
      final phone = await pairedPhone();
      await until(() => model.overlay == Layer.phoneEngine);
      expect(model.preferences.engineSource, 'upstream', reason: 'nothing is switched before the press');
      expect(model.panelCategories().single.title, T.text('phoneEngineTitle'));
      final rows = model.panelCategories().single.rows.map((row) => row.id).toList();
      expect(rows, ['phoneEngineWhy', 'phoneEngineSwitch', 'phoneEngineLater']);
      await until(() => model.engine.armChecked);
      expect(
        row('phoneEngineSwitch').detail,
        T.format('phoneEngineSwitchSize', [byteText(model.engine.armPackage!.size)]),
      );

      (row('phoneEngineSwitch').kind as ActionRow).run();
      await until(() => model.engine.downloading == null && model.toolkitVersion == 'arm-26d785b');
      await until(() => model.overlay == null);
      expect(model.preferences.engineSource, 'arm');
      expect(model.phoneEngineMissing, isFalse);
      await phone.close();
    });

    test('Not now closes it, and the next phone of the run is not asked about again', () async {
      await start();
      upstreamInUse();
      await model.startPhoneServer();
      final phone = await pairedPhone();
      await until(() => model.overlay == Layer.phoneEngine);
      (row('phoneEngineLater').kind as ActionRow).run();
      expect(model.overlay, isNull);
      await phone.close();
      await until(() => model.remote!.connectedDevices.isEmpty);
      final again = await FakePhone.connect(model.remote!.port!);
      again.hello('phone-1', 'Pixel', key: phoneKey);
      await again.next<Welcome>();
      await until(() => model.remote!.connectedDevices.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(model.overlay, isNull);
      expect(model.preferences.engineSource, 'upstream');
      await again.close();
    });

    test('with AnyPS5-ARM\'s engine in use nothing is asked', () async {
      await start();
      makeFakeToolkit(p.join(model.engine.store.root, 'arm-26d785b'), version: 'arm-26d785b');
      model.engine.refresh();
      model.engine.use(model.engine.downloaded.single);
      expect(model.phoneEngineMissing, isFalse);
      await model.startPhoneServer();
      final phone = await pairedPhone();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(model.overlay, isNull);
      await phone.close();
    });

    test('Settings › Phones: the row says why and switches in one press', () async {
      await start();
      upstreamInUse();
      makeFakeToolkit(p.join(model.engine.store.root, 'arm-26d785b'), version: 'arm-26d785b');
      model.engine.refresh();
      await model.startPhoneServer();
      model.open(Layer.settings);
      model.panelCategory = model.panelCategories().indexWhere((category) => category.id == 'phone');
      expect(row('phoneUpstream').detail, T.text('phoneUpstreamSwitchDetail'));
      (row('phoneUpstream').kind as ActionRow).run();
      await until(() => model.toolkitVersion == 'arm-26d785b');
      expect(model.preferences.engineSource, 'arm');
      expect(
        model.panelCategories().expand((category) => category.rows).map((row) => row.id),
        isNot(contains('phoneUpstream')),
      );
    });

    test('a game that ran on upstream\'s engine with a phone: the switch is offered when it ends', () async {
      await start();
      upstreamInUse();
      final orbit = model.games.firstWhere((game) => game.titleId == 'PPSA01001');
      final installed = Installer.installedFolder(orbit, model.root!);
      File(p.join(installed, 'app.elf')).writeAsStringSync('#!/bin/sh\nsleep 1\n');
      Process.runSync('chmod', ['755', p.join(installed, 'app.elf')]);
      File(p.join(installed, Installer.recordName)).writeAsStringSync(
        '{"date":"2026-10-24T12:00:00Z","source":${jsonEncode(orbit.folder)},"system":"linux",'
        '"titleID":"PPSA01001","toolkit":"upstream-v0.1.4"}',
      );
      model.rescan();
      await model.startPhoneServer();
      final phone = await pairedPhone();
      await until(() => model.overlay == Layer.phoneEngine);
      (row('phoneEngineLater').kind as ActionRow).run();
      final playing = model.play(orbit);
      await until(() => model.running != null);
      expect(model.toast, T.text('phoneUpstreamGame'));
      expect(model.overlay, isNull, reason: 'never over a game');
      await playing;
      expect(model.overlay, Layer.phoneEngine, reason: 'asked again once the game ended');
      await phone.close();
    }, skip: Platform.isWindows ? 'the stand-in game is a shell script' : false);
  });
}
