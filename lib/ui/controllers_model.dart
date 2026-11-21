import 'dart:async';
import 'dart:io';

import '../core/controllers/pad_info.dart';
import '../core/controllers/pad_inventory.dart';
import '../core/controllers/pad_reader.dart';
import '../core/controllers/sdl_pads.dart';
import '../core/controllers/troubleshooter.dart';
import '../core/gamepad/pad_navigation.dart';
import '../core/host.dart';
import '../core/remote/assist.dart';
import 'app_model.dart';
import 'strings.dart';

/// Settings › Controllers: the controllers connected (Player 1 the one used last), their log,
/// the light bar, the test, vibration and the troubleshooter. The reader (SDL, or the older
/// ones) tells which pads there are; this keeps the roster, logs every connect and disconnect
/// for crash reports and the game's log, and asks the system what may be in the way.
class ControllersModel {
  ControllersModel(this.app);

  final AppModel app;
  final PadRoster roster = PadRoster();
  final PadLog log = PadLog();

  PadInventory? _inventory;
  PadFacts _system = PadFacts(system: HostSystem.current);
  DateTime? _lastProbe;
  bool _probing = false;

  /// The reader's inventory, once the pads are read.
  PadInventory? get inventory => _inventory;

  List<PadInfo> get pads => roster.ordered;
  PadInfo? get playerOne => roster.playerOne == null ? null : roster.pad(roster.playerOne!);

  /// The reader started: its pads are followed from now on.
  void attach(PadSource source) {
    if (source is! PadInventory) return;
    final inventory = source as PadInventory;
    _inventory = inventory;
    inventory.onPadsChanged = _sync;
    _sync();
    unawaited(probe());
  }

  void _sync() {
    final inventory = _inventory;
    if (inventory == null) return;
    final known = {for (final pad in roster.pads) pad.id};
    final lines = roster.sync(inventory.pads);
    for (final line in lines) {
      _record(line);
    }
    final arrived = [for (final pad in roster.pads) if (!known.contains(pad.id)) pad];
    if (lines.isNotEmpty) {
      applyLights();
      _applyPlayerLights();
      // A pad came or went: what may be in the way is asked again (not more than every few seconds).
      unawaited(probe());
      // A toast for the user, not in the first seconds (the pads there at launch) nor over a game.
      if (_toastsFrom.isBefore(DateTime.now()) && app.running == null) {
        if (arrived.isNotEmpty) {
          app.show(T.format('padArrived', [arrived.last.name]));
        } else if (lines.any((line) => line.startsWith('controller disconnected'))) {
          final name = RegExp(r'^controller disconnected: (.*) \(').firstMatch(lines.last)?.group(1) ?? '';
          app.show(T.format('padLeft', [name]));
        }
      }
    }
    app.refresh();
  }

  final DateTime _toastsFrom = DateTime.now().add(const Duration(seconds: 3));

  void _record(String line) {
    log.add(line);
    app.padLogLine(line);
  }

  Map<String, PadState>? _previewStates;
  PadFacts? _previewFacts;

  /// Everything [id] holds now, for the controller test.
  PadState? stateOf(String id) => _previewStates?[id] ?? _inventory?.state(id);

  /// Tests and screenshots: these pads, states and troubleshooter facts in place of the real ones.
  void preview(List<PadInfo> pads, {Map<String, PadState> states = const {}, String? playerOne, PadFacts? facts}) {
    roster.sync(pads);
    if (playerOne != null) roster.used(playerOne);
    _previewStates = states;
    _previewFacts = facts;
    app.refresh();
  }

  /// A press from [pad]: it is Player 1 now.
  void used(String? pad) {
    if (pad == null || !roster.used(pad)) return;
    _applyPlayerLights();
    app.refresh();
  }

  /// The report's lines: the controllers now and the recent connects and disconnects.
  List<String> get reportLines => PadLog.report(roster, log);

  // Lights.

  PadLight get light => PadLight.parse(app.preferences.controllerLight);

  /// The light bars in the setting's colour (the theme's accent for Theme Colour), while the
  /// launcher is in front: a game sets its own.
  void applyLights() {
    final inventory = _inventory;
    if (inventory == null || !app.launcherInFront) return;
    final (red, green, blue) = light.rgb ?? app.accentRgb;
    for (final pad in roster.pads) {
      if (pad.hasLight) inventory.setLight(pad.id, red, green, blue);
    }
  }

  void _applyPlayerLights() => _inventory?.setPlayerLights([for (final pad in roster.ordered) pad.id]);

  // Vibration.

  /// Three strong pulses on Player 1, whatever the vibration setting (it is a test); false when
  /// that pad cannot vibrate here.
  bool testVibration() {
    final pad = playerOne;
    final motors = app.padMotors;
    if (pad == null || motors == null || !motors.canRumble(pad.id)) return false;
    const pulses = [(0, 180, 1.0, 0.2), (300, 180, 0.2, 1.0), (600, 300, 0.8, 0.8)];
    for (final (start, length, strong, weak) in pulses) {
      Timer(Duration(milliseconds: start), () => motors.rumble(pad.id, strong, weak, Duration(milliseconds: length)));
      Timer(Duration(milliseconds: start + length), () => motors.rumble(pad.id, 0, 0, Duration.zero));
    }
    return true;
  }

  // The troubleshooter.

  SystemProbe? get _probe => app.services.systemProbe?.call();

  /// Asks the system again (programs running, drivers, Steam's setting, permissions); at most
  /// every five seconds unless [force].
  Future<void> probe({bool force = false}) async {
    final probe = _probe;
    if (probe == null || _probing) return;
    if (!force && _lastProbe != null && DateTime.now().difference(_lastProbe!) < const Duration(seconds: 5)) return;
    _probing = true;
    _lastProbe = DateTime.now();
    try {
      final results = await Future.wait<Object?>([
        probe.processes(),
        probe.services(PadTroubleshooter.windowsServices),
        probe.steamPlayStationSupport(),
        probe.hidrawDenied(),
        probe.unreadableControllers(),
      ]);
      final processes = results[0]! as Set<String>;
      PadReader.remapperRunning = processes.any(const {'ds4windows.exe', 'dualsensex.exe', 'dsx.exe'}.contains);
      _system = PadFacts(
        system: app.system,
        processes: processes,
        services: results[1]! as Set<String>,
        steamPlayStationSupport: results[2] as int?,
        hidrawDenied: results[3]! as bool,
        refused: results[4]! as List<String>,
      );
    } on Object {
      // The troubleshooter says what it found; nothing found is no reason to stop.
    } finally {
      _probing = false;
    }
    app.refresh();
  }

  PadFacts get facts {
    if (_previewFacts case final facts?) return facts;
    final inventory = _inventory;
    return PadFacts(
      system: app.system,
      pads: roster.pads,
      sdlLoaded: PadReader.sdlLoaded(inventory),
      sdlFailure: PadReader.sdlFailure,
      unmapped: switch (PadReader.current(inventory)) {
        final SdlPadSource sdl => sdl.unmapped,
        _ => const [],
      },
      refused: {...?inventory?.refused, ..._system.refused}.toList(),
      processes: _system.processes,
      services: _system.services,
      steamPlayStationSupport: _system.steamPlayStationSupport,
      launchedFromSteam: app.launchedFromSteam,
      hidrawDenied: _system.hidrawDenied,
      executable: Platform.resolvedExecutable,
    );
  }

  List<PadFinding> get findings => PadTroubleshooter.diagnose(facts);

  // Settings › Controllers.

  static String kindName(PadKind kind) => kind == PadKind.generic ? T.text('padGeneric') : kind.reportName;

  static String connectionName(PadConnection connection) => switch (connection) {
    PadConnection.usb => T.text('padUsb'),
    PadConnection.bluetooth => T.text('padBluetooth'),
    PadConnection.unknown => T.text('padConnected'),
  };

  /// A battery in words: its percentage where the reader measures one ("80%"), else its level
  /// ("Low"), never a number made up from a level.
  static String batteryText(PadBattery battery) => switch (battery.percent) {
    final int percent => T.format('padBattery', [percent]),
    null => T.text(switch (battery.level) {
      PadBatteryLevel.empty => 'padLevelEmpty',
      PadBatteryLevel.low => 'padLevelLow',
      PadBatteryLevel.medium => 'padLevelMedium',
      PadBatteryLevel.full => 'padLevelFull',
    }),
  };

  /// "DualSense · Bluetooth · 80% · charging", or "Xbox · Bluetooth · Battery: Low".
  static String summary(PadInfo pad) => [
    kindName(pad.kind),
    connectionName(pad.connection),
    if (pad.battery case final battery?) ...[
      if (battery.approximate) T.format('padBatteryLevel', [batteryText(battery)]) else batteryText(battery),
      if (battery.charging == true) T.text('padCharging'),
    ],
  ].join(' · ');

  /// Settings › Controllers › Assist Player 1: off, the other controllers, or a phone or browser
  /// pad connected now (the chosen one stays listed while it is away).
  PanelRow assistRow() {
    final preferences = app.preferences;
    final chosen = AssistTarget.stored(preferences.assistPlayerOne);
    final remote = app.remote;
    final ids = remote?.connectedDeviceIds ?? const <String>[];
    final names = remote?.connectedDevices ?? const <String>[];
    final connected = [
      for (var index = 0; index < ids.length; index++) (ids[index], index < names.length ? names[index] : ids[index]),
    ];
    final choices = AssistTarget.choices(connected, chosen, {for (final (id, name) in connected) id: name});
    final labels = [
      for (final (target, name) in choices)
        switch (target) {
          AssistOff() => T.text('padAssistOff'),
          AssistControllers() => T.text('padAssistControllers'),
          AssistDevice() => name ?? '',
        },
    ];
    final selected = choices.indexWhere((choice) => choice.$1 == chosen);
    return PanelRow(
      id: 'padAssist',
      title: T.text('padAssist'),
      detail: chosen is AssistOff
          ? T.text('padAssistDetail')
          : T.format('padAssistOn', [labels[selected < 0 ? 0 : selected]]),
      kind: ChoiceRow(labels, selected < 0 ? 0 : selected, (index) {
        if (index < 0 || index >= choices.length) return;
        preferences.assistPlayerOne = choices[index].$1.stored;
        app.savePreferences();
      }),
    );
  }

  List<PanelRow> rows() {
    final preferences = app.preferences;
    final one = roster.playerOne;
    final findings = this.findings;
    return [
      if (roster.pads.isEmpty)
        PanelRow(id: 'padNone', title: T.text('padNone'), detail: T.text('padNoneDetail'), kind: const InfoRow('')),
      for (final pad in roster.ordered)
        PanelRow(
          id: 'pad-${pad.id}',
          title: pad.id == one ? '${pad.name} · ${T.text('padPlayerOne')}' : pad.name,
          detail: summary(pad),
          kind: ActionRow(() {
            used(pad.id);
            app.openControllerTest();
          }),
        ),
      PanelRow(
        id: 'padTest',
        title: T.text('padTest'),
        detail: T.text('padTestDetail'),
        kind: ActionRow(app.openControllerTest),
      ),
      PanelRow(
        id: 'padVibrate',
        title: T.text('padVibrate'),
        detail: T.text('padVibrateDetail'),
        kind: ActionRow(() {
          final pad = playerOne;
          if (pad == null) return;
          app.show(T.format(testVibration() ? 'padVibrating' : 'padNoVibration', [pad.name]));
        }),
      ),
      PanelRow(
        id: 'padLight',
        title: T.text('padLight'),
        detail: T.text('padLightDetail'),
        kind: ChoiceRow([for (final light in PadLight.values) T.text('padLight_${light.name}')], light.index, (index) {
          final chosen = PadLight.values[index];
          preferences.controllerLight = chosen == PadLight.theme ? null : chosen.name;
          app.savePreferences();
          applyLights();
        }),
      ),
      PanelRow(
        id: 'padConfirm',
        title: T.text('padConfirm'),
        detail: T.text('padConfirmDetail'),
        kind: ChoiceRow([T.text('padConfirmCross'), T.text('padConfirmCircle')], preferences.confirmCircle ? 1 : 0, (
          index,
        ) {
          preferences.confirmCircle = index == 1;
          app.savePreferences();
        }),
      ),
      assistRow(),
      PanelRow(
        id: 'padDeadzone',
        title: T.text('padDeadzone'),
        detail: T.text('padDeadzoneDetail'),
        kind: StepperRow(
          value: preferences.stickDeadzone,
          min: 0,
          max: StickDeadzone.maximum,
          step: StickDeadzone.step,
          format: (value) => value == 0 ? T.text('off') : T.percent(value),
          set: (value) {
            preferences.stickDeadzone = value;
            app.savePreferences();
          },
        ),
      ),
      PanelRow(id: 'padTroubleshoot', title: T.text('padTroubleshoot'), kind: const InfoRow('')),
      if (roster.pads.isNotEmpty && !findings.any((finding) => finding.problem))
        PanelRow(
          id: 'padOk',
          title: T.text('padAllGood'),
          detail: T.format('padAllGoodDetail', [_inventory?.readerName ?? 'SDL']),
          kind: ActionRow(() => unawaited(probe(force: true))),
        ),
      for (final (index, finding) in findings.indexed)
        PanelRow(
          id: 'padFinding-$index-${finding.id}',
          title: T.format('padFinding_${finding.id}', finding.arguments),
          detail: T.format('padFinding_${finding.id}Detail', finding.arguments),
          kind: ActionRow(() {
            final command = finding.command;
            if (command == null) return unawaited(probe(force: true));
            app.services.copyText?.call(command);
            app.show(T.text(finding.id == 'hidHide' ? 'padCopiedPath' : 'padCopied'));
          }),
        ),
    ];
  }
}
