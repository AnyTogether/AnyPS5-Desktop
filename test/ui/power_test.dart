import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/game_process.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/installer.dart';
import 'package:anyps5_desktop/core/power_profiles.dart';
import 'package:anyps5_desktop/core/windows_heat.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:anyps5_desktop/ui/theme.dart';
import 'package:anyps5_desktop/ui/launcher.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_process.dart';
import '../support/self_builder.dart';
import '../support/ui_support.dart';

/// Settings › Battery & heat: the readings, the profiles, what a game starts with and hears while
/// it runs, the note over a hot game and Undo in the quick menu.
void main() {
  late Fixture fixture;
  late AppModel model;
  late DateTime clock;

  setUp(() {
    fixture = makeFixture();
    model = fixture.model;
    clock = DateTime.utc(2026, 11, 1, 12);
    model.powerWatch.now = () => clock;
    model.powerWatch.displayHertz = () => 60;
  });

  tearDown(() {
    Motion.reduced = false;
    model.dispose();
    fixture.dispose();
  });

  Game orbit() => model.games.firstWhere((game) => game.titleId == 'PPSA01001');
  List<PanelRow> powerRows() {
    model.open(Layer.settings);
    model.panelCategory = model.panelCategories().indexWhere((category) => category.id == 'power');
    return model.panelCategories()[model.panelCategory].rows;
  }

  PanelRow row(String id) =>
      powerRows().firstWhere((row) => row.id == id, orElse: () => throw StateError('no row $id'));
  bool hasRow(String id) => powerRows().any((row) => row.id == id);

  const laptop = PowerReading(hasBattery: true, onBattery: false, batteryPercent: 90, thermal: ThermalLevel.nominal);
  const onBattery = PowerReading(
    hasBattery: true,
    onBattery: true,
    batteryPercent: 64,
    minutesToEmpty: 125,
    thermal: ThermalLevel.nominal,
  );

  test('a laptop plugged in: the profiles shown, nothing in force', () {
    model.powerWatch.take(laptop);
    powerRows();
    expect(model.panelCategories()[model.panelCategory].title, 'Battery & heat');
    expect(row('powerStatus').title, 'Plugged in');
    expect(row('powerStatus').detail, 'Games run as you set them\nTemperature: normal');
    expect(row('powerStatus').detail, startsWith('Games run as you set them'));
    expect(hasRow('powerUndo'), isFalse);
    expect((row('batteryOn').kind as ToggleRow).value, isTrue);
    expect((row('batteryCap').kind as ChoiceRow).options, ['Off', '30 FPS', '40 FPS', '45 FPS', '60 FPS (display)']);
    expect((row('batteryCap').kind as ChoiceRow).selected, 2);
    expect(hasRow('hotOn'), isTrue);
    expect(hasRow('powerUpstream'), isTrue, reason: 'the fixture runs upstream\'s engine');
  });

  test('a fast display offers caps up to its own rate; a cap saved on another stays', () {
    model.powerWatch.displayHertz = () => 165;
    model.powerWatch.take(onBattery);
    final cap = row('batteryCap').kind as ChoiceRow;
    expect(cap.options, [
      'Off',
      '30 FPS',
      '40 FPS',
      '45 FPS',
      '60 FPS',
      '90 FPS',
      '120 FPS',
      '144 FPS',
      '165 FPS (display)',
    ]);
    cap.set(cap.options.length - 1);
    expect(model.powerWatch.adjustment.frameCap, 165);
    // Moved to a 60 Hz screen: 165 is still there to pick, nothing changes on its own.
    model.powerWatch.displayHertz = () => 60;
    final again = row('batteryCap').kind as ChoiceRow;
    expect(again.options.last, '165 FPS');
    expect(again.selected, again.options.length - 1);
    // An unknown display gets the caps up to 60.
    expect(PowerProfile.frameCapsFor(null), [0, 30, 40, 45, 60]);
    expect(PowerProfile.frameCapsFor(75), [0, 30, 40, 45, 60, 75]);
  });

  test('on battery the battery profile holds: the line, Undo, the dimmed launcher', () {
    model.powerWatch.take(onBattery);
    expect(row('powerStatus').title, 'On battery at 64%, about 2 h 5 min left');
    expect(row('powerStatus').detail, startsWith('In force now: Battery profile with a 40 FPS cap'));
    expect(model.powerWatch.dimmed, isTrue);
    expect(model.solidGlass, isTrue);
    expect(Motion.reduced, isTrue);
    expect(row('powerUndo').title, 'Undo battery profile');
    (row('powerUndo').kind as ActionRow).run();
    expect(model.toast, T.text('powerUndone'));
    expect(hasRow('powerUndo'), isFalse);
    expect(row('powerStatus').detail, startsWith('Games run as you set them'));
    expect(row('powerStatus').title, startsWith('On battery'));
    expect(Motion.reduced, isFalse);
  });

  test('changing a profile is saved with the Mac\'s keys and applies at once', () {
    model.powerWatch.take(onBattery);
    (row('batteryCap').kind as ChoiceRow).set(1);
    expect(model.powerWatch.adjustment.frameCap, 30);
    expect(model.preferences.powerProfiles?['battery'], containsPair('frameCap', 30));
    expect(Preferences.fromJson(model.preferences.toJson()).powerProfiles, model.preferences.powerProfiles);
    (row('batteryOn').kind as ToggleRow).set(false);
    expect(hasRow('batteryCap'), isFalse);
    expect(model.powerWatch.adjustment, PowerAdjustment.none);
    // Back to the defaults: nothing kept.
    (row('batteryOn').kind as ToggleRow).set(true);
    (row('batteryCap').kind as ChoiceRow).set(2);
    expect(model.preferences.powerProfiles, isNull);
  });

  test('Lower resolution: saved with the Mac\'s key, a game unlocked while it holds is one step lower', () async {
    Directory(p.join(fixture.toolkit, 'patches')).createSync(recursive: true);
    File(p.join(fixture.toolkit, 'patches', 'PPSA02002.toml')).writeAsStringSync('''
format = 1

[[patch]]
name = "width"
va = 0x1234
type = "u32"
expected = 1920
value = 1920

[[patch]]
name = "height"
va = 0x1240
type = "u32"
expected = 1080
value = 1080
''');
    model.powerWatch.take(onBattery);
    final toggle = row('batteryResolution');
    expect(toggle.title, T.text('powerLowerResolution'));
    expect((toggle.kind as ToggleRow).value, isFalse);
    (toggle.kind as ToggleRow).set(true);
    expect(model.powerWatch.adjustment.lowerResolution, isTrue);
    expect(model.preferences.powerProfiles?['battery'], containsPair('lowerResolution', true));
    final neon = model.games.firstWhere((game) => game.titleId == 'PPSA02002');
    File(p.join(neon.folder, 'eboot.bin')).writeAsBytesSync(typicalSelf());
    Future<void> until(bool Function() condition) async {
      for (var tries = 0; tries < 2000 && !condition(); tries++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(condition(), isTrue);
    }

    model.unlock(neon);
    await until(() => !model.unlocking && model.records.containsKey(neon.id));
    expect(model.records[neon.id]?.resolution, '1600x900', reason: 'one step under the title\'s 1920x1080');
    // The same game unlocked off the profile keeps the title's own.
    (row('batteryResolution').kind as ToggleRow).set(false);
    model.unlock(neon);
    await until(() => !model.unlocking && model.records[neon.id]?.resolution == null);

    // At each start, as on the Mac: written into the executable, and back with the profile off.
    final executable = p.join(Installer.installedFolder(neon, model.root!), model.system.executableName);
    File(executable).writeAsBytesSync(_linuxExecutable(width: 1920, height: 1080));
    (row('batteryResolution').kind as ToggleRow).set(true);
    late FakeGameProcess process;
    model.startGame =
        ({
          required String installed,
          required Map<String, String> environment,
          List<String> arguments = const [],
          required String logFile,
          HostSystem? system,
          bool traced = false,
          List<String> notes = const [],
        }) async {
          process = FakeGameProcess();
          return RunningGame(process, process.exitCode, DateTime(2026, 11, 1));
        };
    Future<void> start() async {
      final playing = model.play(neon);
      await until(() => model.running != null);
      process.quit();
      await playing;
      await until(() => model.running == null);
    }

    await start();
    expect(_widthHeight(executable), (1600, 900));
    (row('batteryResolution').kind as ToggleRow).set(false);
    await start();
    expect(_widthHeight(executable), (1920, 1080));
  });

  test('where the heat cannot be read, only the battery profile is offered, and that is said', () {
    model.powerWatch.take(const PowerReading(hasBattery: true, onBattery: false, batteryPercent: 80));
    expect(row('powerStatus').detail, contains(T.text('powerNoHeat')));
    expect(hasRow('hotOn'), isFalse);
    expect(row('hotUnavailable').title, T.text('powerHeatUnavailable'));
    expect(hasRow('batteryOn'), isTrue);
  });

  group('on Windows', () {
    late FakeWindowsHeat heat;
    const noHeat = PowerReading(hasBattery: true, onBattery: false, batteryPercent: 80);
    setUp(() {
      model.powerWatch.windowsHeat = heat = FakeWindowsHeat();
      // What the model reads again by itself, not this computer's own.
      model.powerWatch.read = () => noHeat;
    });
    Future<void> settle() => Future<void>.delayed(Duration.zero);
    ToggleRow reader() => row('hotReader').kind as ToggleRow;

    test('without a zone or a card: the reader offered, with why it needs administrator rights', () {
      model.powerWatch.take(noHeat);
      expect(row('hotUnavailable').detail, T.text('powerHeatUnavailableWindowsDetail'));
      expect(row('hotReader').title, T.text('powerHeatReader'));
      expect(row('hotReader').detail, T.text('powerHeatReaderDetail'));
      expect(reader().value, isFalse);
      expect(heat.asked, 0, reason: 'nothing is asked before the user turns it on');
      expect(hasRow('batteryOn'), isTrue);
    });

    test('turned down at Windows\' prompt: said, not asked again, the battery profile still works', () async {
      model.powerWatch.take(noHeat);
      reader().set(true);
      expect(heat.asked, 1);
      expect(model.preferences.heatReader, isTrue);
      expect(reader().value, isTrue);
      expect(row('hotReader').detail, endsWith(T.text('powerHeatReaderAsking')));
      heat.answer(false);
      await settle();
      expect(model.preferences.heatReader, isFalse);
      expect(model.preferences.toJson().containsKey('heatReader'), isFalse);
      expect(reader().value, isFalse);
      expect(row('hotReader').detail, endsWith(T.text('powerHeatReaderDeclined')));
      expect(hasRow('hotUnavailable'), isTrue);
      expect((row('batteryOn').kind as ToggleRow).value, isTrue);
      // The next launch asks nothing.
      model.powerWatch.start();
      expect(heat.asked, 1);
    });

    test('allowed: the reader runs, the heat profile holds on its zones, and it starts with the launcher', () async {
      model.powerWatch.take(noHeat);
      reader().set(true);
      heat.answer(true);
      await settle();
      expect(row('hotReader').detail, endsWith(T.text('powerHeatReaderRunning')));
      expect(Preferences.fromJson(model.preferences.toJson()).heatReader, isTrue);
      model.powerWatch.take(const PowerReading(hasBattery: true, onBattery: false, thermal: ThermalLevel.nominal));
      expect(hasRow('hotOn'), isTrue);
      expect(row('hotOn').detail, T.text('powerHotProfileWindowsDetail'));
      heat.readerState = HeatReaderState.empty;
      expect(row('hotReader').detail, endsWith(T.text('powerHeatReaderEmpty')));
      // Off: the reader is told to end.
      reader().set(false);
      await settle();
      expect(heat.stoppedWith, model.powerWatch.readerStopFile);
      expect(model.preferences.heatReader, isFalse);
      // Turned on before: asked again as the launcher starts.
      model.preferences.heatReader = true;
      model.powerWatch.start();
      expect(heat.asked, 2);
    });

    test('a card read while a game runs: the heat profile offered; turning it on asks for the processor\'s too', () {
      heat.graphicsFound = true;
      model.powerWatch.take(noHeat);
      expect(row('powerStatus').detail, contains(T.text('powerThermalInGames')));
      expect(hasRow('hotUnavailable'), isFalse);
      (row('hotOn').kind as ToggleRow).set(false);
      expect(heat.asked, 0);
      (row('hotOn').kind as ToggleRow).set(true);
      expect(heat.asked, 1);
      expect(model.preferences.heatReader, isTrue);
    });

    test('zones read without administrator rights: no reader to offer', () {
      heat.zonesWithoutAdmin = true;
      model.powerWatch.take(const PowerReading(hasBattery: true, onBattery: false, thermal: ThermalLevel.fair));
      expect(hasRow('hotReader'), isFalse);
      expect(row('powerStatus').detail, contains(T.text('powerThermalFair')));
    });

    test('the reader stopping on its own is said', () {
      heat.readerState = HeatReaderState.stopped;
      model.preferences.heatReader = true;
      model.powerWatch.take(noHeat);
      expect(row('hotReader').detail, endsWith(T.text('powerHeatReaderStopped')));
    });
  });

  test('a desktop without a battery says so; battery saver holds the battery profile', () {
    model.powerWatch.take(PowerReading.pluggedIn);
    expect(row('powerStatus').title, T.text('powerNoBattery'));
    model.powerWatch.take(
      const PowerReading(hasBattery: true, onBattery: false, thermal: ThermalLevel.nominal, lowPowerMode: true),
    );
    clock = clock.add(PowerPolicy.sourceSettle);
    model.powerWatch.take(
      const PowerReading(hasBattery: true, onBattery: false, thermal: ThermalLevel.nominal, lowPowerMode: true),
    );
    expect(row('powerStatus').detail, contains(T.text('powerLowPowerMode')));
    expect(model.powerWatch.adjustment.frameCap, 40);
  });

  test('a game starts with the cap and the control file, which follows the profile while it runs', () async {
    model.powerWatch.take(onBattery);
    Map<String, String>? environment;
    final process = FakeGameProcess();
    model.startGame =
        ({
          required String installed,
          required Map<String, String> environment,
          List<String> arguments = const [],
          required String logFile,
          HostSystem? system,
          bool traced = false,
          List<String> notes = const [],
        }) async {
          seen = environment;
          return RunningGame(process, process.exitCode, DateTime(2026, 11, 1));
        };
    final playing = model.play(orbit());
    for (var tries = 0; tries < 400 && model.running == null; tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    environment = seen;
    expect(environment?['ANYPS5_FPS_CAP'], '40');
    expect(environment?['ANYPS5_POWER_CONTROL'], model.powerWatch.controlFile);
    // The fixture does not write to disk; the text the file would hold follows the adjustment.
    expect(EngineControl.text(model.powerWatch.adjustment), 'fps_cap=40\nframe_gen=0\n');
    // Hot while it plays: a note over the game, and Undo in the quick menu.
    model.powerWatch.take(
      const PowerReading(hasBattery: true, onBattery: true, batteryPercent: 63, thermal: ThermalLevel.serious),
    );
    expect(model.toast, 'Your computer is hot. AnyPS5 lowered the frame rate. To undo, open the quick menu with PS.');
    await model.openQuickMenu();
    final quick = model.panelCategories().single.rows;
    expect(quick.map((row) => row.id), contains('powerUndo'));
    final undo = quick.firstWhere((row) => row.id == 'powerUndo');
    expect(undo.title, 'Undo heat profile');
    (undo.kind as ActionRow).run();
    expect(model.powerWatch.mode, PowerMode.battery, reason: 'the battery profile still holds');
    process.quit();
    await playing;
  });

  test('the control file is written whole where the launcher keeps its files', () {
    final dir = Directory(fixture.temp.path);
    final file = '${dir.path}/Power/control.txt';
    EngineControl.write(model.powerWatch.adjustment, file);
    expect(File(file).readAsStringSync(), 'fps_cap=0\nframe_gen=1\n');
  });

  testWidgets('golden: Settings › Battery & heat on battery, the heat unknown', (tester) async {
    model.powerWatch.take(
      const PowerReading(hasBattery: true, onBattery: true, batteryPercent: 64, minutesToEmpty: 125),
    );
    model.open(Layer.settings);
    model.selectCategory(model.panelCategories().indexWhere((category) => category.id == 'power'));
    await pumpLauncher(tester, model);
    await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/settings_power.png'));
  });

  test('Turkish', () {
    T.language = Language.byCode('tr');
    addTearDown(() => T.language = Language.english);
    model.powerWatch.take(onBattery);
    expect(row('powerStatus').title, 'Pilde, %64, yaklaşık 2 sa 5 dk kaldı');
    expect(model.panelCategories()[model.panelCategory].title, 'Pil ve ısı');
  });
}

/// Windows' heat as a test sets it: the prompt answered by [answer].
class FakeWindowsHeat implements WindowsHeatSource {
  @override
  bool graphicsFound = false;

  @override
  bool zonesWithoutAdmin = false;

  @override
  HeatReaderState readerState = HeatReaderState.off;

  int asked = 0;
  String? stoppedWith;
  Completer<bool>? _prompt;

  void answer(bool yes) => _prompt?.complete(yes);

  @override
  Future<bool> startReader({required String stopFile}) {
    asked++;
    readerState = HeatReaderState.asking;
    final prompt = _prompt = Completer<bool>();
    return prompt.future.then((yes) {
      readerState = yes ? HeatReaderState.running : HeatReaderState.declined;
      return yes;
    });
  }

  @override
  void stopReader({required String stopFile}) {
    stoppedWith = stopFile;
    readerState = HeatReaderState.off;
  }
}

/// The environment the last fake start was given.
Map<String, String>? seen;

/// A relinked Linux game: its code placed at 0x400000, width and height at the patch file's
/// addresses (0x1234 and 0x1240), one load segment from file offset 0x1000.
Uint8List _linuxExecutable({required int width, required int height}) {
  final bytes = ByteData(0x3000);
  bytes
    ..setUint8(0, 0x7f)
    ..setUint8(1, 0x45)
    ..setUint8(2, 0x4c)
    ..setUint8(3, 0x46)
    ..setUint16(0x10, 2, Endian.little)
    ..setUint64(0x20, 0x40, Endian.little)
    ..setUint16(0x36, 56, Endian.little)
    ..setUint16(0x38, 1, Endian.little)
    ..setUint32(0x40, 1, Endian.little)
    ..setUint64(0x48, 0x1000, Endian.little)
    ..setUint64(0x50, 0x400000, Endian.little)
    ..setUint64(0x60, 0x2000, Endian.little)
    ..setUint32(0x2234, width, Endian.little)
    ..setUint32(0x2240, height, Endian.little);
  return bytes.buffer.asUint8List();
}

(int, int) _widthHeight(String executable) {
  final bytes = ByteData.sublistView(File(executable).readAsBytesSync());
  return (bytes.getUint32(0x2234, Endian.little), bytes.getUint32(0x2240, Endian.little));
}
