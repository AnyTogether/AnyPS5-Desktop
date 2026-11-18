import 'package:anyps5_desktop/core/controllers/pad_info.dart';
import 'package:anyps5_desktop/core/controllers/troubleshooter.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:test/test.dart';

void main() {
  final sense = PadInfo(id: 'sdl0', name: 'PS5 Controller', kind: PadKind.dualSense, battery: PadBattery(60), driver: 'SDL HIDAPI');
  const xbox = PadInfo(id: 'sdl1', name: 'Xbox Controller', kind: PadKind.xbox, driver: 'SDL XInput');

  List<String> ids(PadFacts facts) => [for (final finding in PadTroubleshooter.diagnose(facts)) finding.id];

  group('Windows', () {
    test('nothing connected: the tips, the DualShock 3 driver', () {
      expect(ids(const PadFacts(system: HostSystem.windows)), ['noControllers', 'usbCable', 'bluetoothPairing', 'dualShock3Windows']);
    });

    test('a DualShock 3 tip follows the drivers installed: DsHidMini, then BthPS3 for Bluetooth', () {
      expect(ids(const PadFacts(system: HostSystem.windows, services: {'dshidmini'})), [
        'noControllers',
        'usbCable',
        'bluetoothPairing',
        'dualShock3WindowsBluetooth',
      ]);
      expect(ids(const PadFacts(system: HostSystem.windows, services: {'dshidmini', 'bthps3'})), [
        'noControllers',
        'usbCable',
        'bluetoothPairing',
      ]);
      // BthPS3 alone does not start the pad: DsHidMini first.
      expect(ids(const PadFacts(system: HostSystem.windows, services: {'bthps3'})).last, 'dualShock3Windows');
    });

    test('a DualShock 3 listed without DsHidMini is in the way: Windows cannot start it', () {
      const ds3 = PadInfo(
        id: 'sdl2',
        name: 'PS3 Controller',
        kind: PadKind.dualShock3,
        driver: 'SDL DirectInput',
        vendor: 0x054C,
        product: 0x0268,
      );
      final finding = PadTroubleshooter.diagnose(const PadFacts(system: HostSystem.windows, pads: [ds3])).single;
      expect(finding.id, 'dualShock3Windows');
      expect(finding.problem, isTrue);
      // With DsHidMini it is started: nothing to say.
      expect(ids(const PadFacts(system: HostSystem.windows, pads: [ds3], services: {'dshidmini'})), isEmpty);
      // A third-party pad named after it is an ordinary HID pad.
      const afterglow = PadInfo(
        id: 'sdl3',
        name: 'Afterglow PS3 Controller',
        kind: PadKind.dualShock3,
        driver: 'SDL DirectInput',
        vendor: 0x0E6F,
        product: 0x0263,
      );
      expect(ids(const PadFacts(system: HostSystem.windows, pads: [afterglow])), isEmpty);
      expect(PadTroubleshooter.sonyDualShock3(ds3), isTrue);
      expect(PadTroubleshooter.sonyDualShock3(afterglow), isFalse);
    });

    test('a service is looked for where kernel and user-mode drivers keep theirs', () {
      expect(PadTroubleshooter.serviceKeys('dshidmini'), [
        r'HKLM\SYSTEM\CurrentControlSet\Services\dshidmini',
        r'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\WUDF\Services\dshidmini',
      ]);
      expect(PadTroubleshooter.windowsServices, containsAll(['dshidmini', 'BthPS3']));
    });

    test('Steam with PlayStation support on is in the way of a PlayStation pad', () {
      final facts = PadFacts(system: HostSystem.windows, pads: [sense], processes: {'steam.exe'}, steamPlayStationSupport: 2);
      final finding = PadTroubleshooter.diagnose(facts).single;
      expect(finding.id, 'steamPlayStation');
      expect(finding.problem, isTrue);
      // Turned off in Steam: only a tip that it runs.
      expect(ids(PadFacts(system: HostSystem.windows, pads: [sense], processes: {'steam.exe'}, steamPlayStationSupport: 0)), ['steamRunning']);
      // An Xbox pad only: Steam's PlayStation support is beside the point.
      expect(ids(const PadFacts(system: HostSystem.windows, pads: [xbox], processes: {'steam.exe'}, steamPlayStationSupport: 2)), ['steamRunning']);
      // Its setting unknown counts as on (Steam's default).
      expect(ids(PadFacts(system: HostSystem.windows, pads: [sense], processes: {'steam.exe'})), ['steamPlayStation']);
      // Started from Steam: its virtual pad is the one used.
      expect(ids(PadFacts(system: HostSystem.windows, pads: [sense], processes: {'steam.exe'}, launchedFromSteam: true)), ['steamLaunched']);
    });

    test('DS4Windows, DualSenseX, HidHide and ViGEm', () {
      final facts = PadFacts(
        system: HostSystem.windows,
        pads: [sense],
        processes: {'ds4windows.exe', 'dsx.exe'},
        services: {'hidhide', 'vigembus'},
        executable: r'C:\Program Files\AnyPS5 Desktop\anyps5_desktop.exe',
      );
      final findings = PadTroubleshooter.diagnose(facts);
      expect(findings.map((finding) => finding.id), ['ds4windows', 'dualSenseX', 'hidHide']);
      expect(findings[2].command, r'C:\Program Files\AnyPS5 Desktop\anyps5_desktop.exe');
      expect(findings[2].problem, isFalse, reason: 'a pad gets through: HidHide is only a tip');
      // Nothing gets through with HidHide installed: it may be hiding the pad.
      final hidden = PadTroubleshooter.diagnose(const PadFacts(system: HostSystem.windows, services: {'hidhide'}));
      expect(hidden.firstWhere((finding) => finding.id == 'hidHide').problem, isTrue);
      // ViGEm alone (no remapper running): a tip.
      expect(ids(PadFacts(system: HostSystem.windows, pads: [sense], services: {'vigembus'})), ['vigem']);
    });

    test('SDL2 missing: the older readers, said so', () {
      final findings = PadTroubleshooter.diagnose(
        const PadFacts(system: HostSystem.windows, pads: [xbox], sdlLoaded: false, sdlFailure: 'SDL2 not found'),
      );
      expect(findings.single.id, 'sdlMissingWindows');
      expect(findings.single.arguments, ['SDL2 not found']);
    });

    test('a joystick without a mapping and a low battery are named', () {
      final findings = PadTroubleshooter.diagnose(
        PadFacts(system: HostSystem.windows, pads: [sense.copyWith(battery: PadBattery(9))], unmapped: ['Thrustmaster Wheel']),
      );
      expect(findings.map((finding) => finding.id), ['unmapped', 'lowBattery']);
      expect(findings[0].arguments, ['Thrustmaster Wheel']);
      expect(findings[1].arguments, ['PS5 Controller', 9]);
      final xbox = PadInfo(id: 'sdl1', name: 'Xbox Controller', kind: PadKind.xbox, battery: PadBattery(9), driver: 'SDL XInput');
      expect(PadTroubleshooter.statusPad([sense, xbox]), xbox);
      expect(PadTroubleshooter.statusPad([sense]), isNull);
    });

    test('a battery known only as a level is named without a number', () {
      final empty = sense.copyWith(battery: const PadBattery.level(PadBatteryLevel.empty, charging: false));
      final findings = PadTroubleshooter.diagnose(PadFacts(system: HostSystem.windows, pads: [empty]));
      expect(findings.single.id, 'lowBatteryLevel');
      expect(findings.single.arguments, ['PS5 Controller']);
      expect(PadTroubleshooter.statusPad([empty]), empty);
      final low = sense.copyWith(battery: const PadBattery.level(PadBatteryLevel.low, charging: false));
      expect(PadTroubleshooter.diagnose(PadFacts(system: HostSystem.windows, pads: [low])), isEmpty);
      expect(PadTroubleshooter.statusPad([low]), isNull);
    });

    test('tasklist and Steam config are read', () {
      expect(
        PadTroubleshooter.tasklistNames('"System Idle Process","0","Services","0","8 K"\r\n"steam.exe","1234","Console","1","90,000 K"\r\n"DS4Windows.exe","4321","Console","1","50 K"\r\n'),
        {'system idle process', 'steam.exe', 'ds4windows.exe'},
      );
      expect(
        PadTroubleshooter.steamPlayStationSupport(
          '"InstallConfigStore"\n{\n\t"Software"\n\t{\n\t\t"Valve"\n\t\t{\n\t\t\t"Steam"\n\t\t\t{\n\t\t\t\t"SteamController_PSSupport"\t\t"2"\n',
        ),
        2,
      );
      expect(PadTroubleshooter.steamPlayStationSupport('"InstallConfigStore" {}'), isNull);
    });
  });

  group('Linux', () {
    test('a controller the user may not read: the input group, with the command', () {
      final findings = PadTroubleshooter.diagnose(const PadFacts(system: HostSystem.linux, refused: ['Sony Interactive Entertainment Wireless Controller']));
      expect(findings.first.id, 'linuxPermission');
      expect(findings.first.problem, isTrue);
      expect(findings.first.command, 'sudo usermod -aG input "\$USER"');
      expect(findings.map((finding) => finding.id), isNot(contains('noControllers')));
    });

    test('hidraw closed: the udev rule for PlayStation pads read without their motors', () {
      const evdevSense = PadInfo(id: 'sdl0', name: 'PS5 Controller', kind: PadKind.dualSense, driver: 'SDL evdev');
      final findings = PadTroubleshooter.diagnose(const PadFacts(system: HostSystem.linux, pads: [evdevSense], hidrawDenied: true));
      expect(findings.single.id, 'linuxHidraw');
      expect(findings.single.command, contains('/etc/udev/rules.d/70-anyps5-controllers.rules'));
      expect(findings.single.command, contains('ATTRS{idVendor}=="054c"'));
      // Read through HIDAPI already: nothing to say.
      expect(ids(PadFacts(system: HostSystem.linux, pads: [sense], hidrawDenied: true)), isEmpty);
    });

    test("a DualShock 3 is hid-sony's through evdev, motors included: no udev rule for it", () {
      const ds3 = PadInfo(
        id: 'sdl0',
        name: 'PS3 Controller',
        kind: PadKind.dualShock3,
        driver: 'SDL evdev',
        vendor: 0x054C,
        product: 0x0268,
      );
      expect(ids(const PadFacts(system: HostSystem.linux, pads: [ds3], hidrawDenied: true)), isEmpty);
      expect(ids(const PadFacts(system: HostSystem.linux, pads: [ds3])), isEmpty, reason: 'nothing to install on Linux');
    });

    test('SDL2 missing on Linux says how to install it', () {
      final findings = PadTroubleshooter.diagnose(const PadFacts(system: HostSystem.linux, pads: [xbox], sdlLoaded: false));
      expect(findings.single.id, 'sdlMissingLinux');
      expect(findings.single.command, startsWith('sudo apt install libsdl2-2.0-0'));
    });

    test('nothing connected on Linux', () {
      expect(ids(const PadFacts(system: HostSystem.linux, processes: {'steam'})), [
        'noControllers',
        'steamPlayStation',
        'usbCable',
        'bluetoothPairing',
        'dualShock3Linux',
      ]);
    });
  });
}
