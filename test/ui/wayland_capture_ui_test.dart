import 'dart:io';

import 'package:anyps5_desktop/core/capture/wayland_capture.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/replay_buffer.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../core/capture/wayland_capture_test.dart' show FakePortal;
import '../core/replay_buffer_test.dart' show FakeProcess;
import '../support/ui_support.dart';

/// Turning the replay buffer on under Wayland: Settings › Captures reaches the portal's checks,
/// says what is missing, and tells the user the desktop will ask.
void main() {
  late Fixture fixture;
  late AppModel model;
  late FakePortal portal;
  late bool toolsInstalled;

  const environment = {'XDG_SESSION_TYPE': 'wayland', 'XDG_RUNTIME_DIR': '/run/user/1000'};

  setUp(() {
    portal = FakePortal();
    toolsInstalled = true;
    fixture = makeFixture(
      environment: environment,
      waylandCapture: WaylandCapture(
        portal: portal,
        environment: environment,
        exists: (_) => true,
        run: (executable, arguments) async {
          if (!toolsInstalled) throw ProcessException(executable, arguments);
          return ProcessResult(1, 0, '', '');
        },
      ),
      replay: (seconds) => ReplayBuffer(
        ffmpeg: 'ffmpeg',
        folder: p.join(Directory.systemTemp.path, 'anyps5-replay-wayland-${DateTime.now().microsecondsSinceEpoch}'),
        seconds: seconds,
        system: HostSystem.linux,
        start: (_, _) async => FakeProcess(),
        run: (_, _) async => ProcessResult(1, 0, '', ''),
      ),
    );
    model = fixture.model;
  });
  tearDown(() {
    model.dispose();
    fixture.dispose();
  });

  Future<void> until(bool Function() condition) async {
    for (var tries = 0; tries < 200 && !condition(); tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(condition(), isTrue);
  }

  ToggleRow replayToggle() {
    model.open(Layer.settings);
    model.selectCategory(model.panelCategories().indexWhere((category) => category.id == 'captures'));
    return model.panelCategories()[model.panelCategory].rows.firstWhere((row) => row.id == 'replayBuffer').kind
        as ToggleRow;
  }

  test('the row is offered: Wayland no longer says it cannot record', () {
    expect(model.replayUnavailable, isNull);
    expect(replayToggle().value, isFalse);
  });

  test('turned on with no game: on, nothing asked yet, and the user is told the desktop will ask', () async {
    replayToggle().set(true);
    await until(() => model.preferences.replayBuffer);
    expect(portal.asked, isEmpty);
    expect(model.toast, contains(T.text('waylandAskTitle')));
  });

  test('turned on with GStreamer missing: stays off and says so', () async {
    toolsInstalled = false;
    replayToggle().set(true);
    await until(() => model.toast != null);
    expect(model.toast, T.text('waylandNoGstreamer'));
    expect(model.preferences.replayBuffer, isFalse);
  });

  test('turned on with no portal: stays off and says so', () async {
    portal.info = null;
    replayToggle().set(true);
    await until(() => model.toast != null);
    expect(model.toast, T.text('waylandNoPortal'));
    expect(model.preferences.replayBuffer, isFalse);
  });

  test('the restore token is kept with the preferences', () {
    final preferences = model.preferences..waylandRestoreToken = 'kept';
    expect(preferences.toJson()['waylandRestoreToken'], 'kept');
  });
}
