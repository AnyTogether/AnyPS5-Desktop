import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_install.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_protocol.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_release.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_store.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../ui/retro_host/fake_retro_host_session.dart';
import 'fixtures.dart';
import 'retro_host_release_fixture.dart';
import 'ui_support.dart';

/// A launcher with one PS1 disc in its games folder, a host where ANYPS5_RETRO_HOST says (or, with
/// [release], the recorded signed host release downloaded into the launcher's storage and no
/// variable), and a fake host session for every host started in it: [sessions] in order, a new one
/// made for a host started once every session there was used. With `ps2`, LRPS2 is beside the
/// host too (the signed release with PS2 for [withRelease]), and the games folder also has a PS2
/// disc ([ps2Game]).
class Ps1Launcher {
  Ps1Launcher._({
    required bool hostFound,
    required this.release,
    FakeRetroHostSession? session,
    Uri? retroHostApi,
    bool ps2 = false,
  }) : sessions = [session ?? FakeRetroHostSession()] {
    final temp = temporaryFolder('ps1-host');
    final hostFolder = Directory(p.join(temp.path, 'host'))..createSync();
    host = (File(p.join(hostFolder.path, 'anyps5-retro-host'))..createSync()).path;
    core = (File(p.join(hostFolder.path, RetroHostInstall.coreName(HostSystem.current)))..createSync()).path;
    if (ps2 && !release) File(p.join(hostFolder.path, RetroHostInstall.ps2CoreName(HostSystem.current))).createSync();
    fixture = makeFixture(
      withToolkit: false,
      environment: {if (hostFound && !release) RetroHostInstall.variable: host},
      retroHostApi: retroHostApi,
      retroHostKeys: release || retroHostApi != null ? retroHostFixtureKeys() : null,
    );
    folders.add(temp);
    final folder = Directory(p.join(model.root!, 'Night Racer'))..createSync();
    disc = (File(p.join(folder.path, 'game.cue'))..createSync()).path;
    File(p.join(folder.path, 'retro.json')).writeAsStringSync(
      jsonEncode({'platform': 'ps1', 'titleId': 'SLUS00001', 'name': 'Night Racer', 'disc': 'game.cue'}),
    );
    if (ps2) {
      final ps2Folder = Directory(p.join(model.root!, 'Sky Racer'))..createSync();
      ps2Disc = (File(p.join(ps2Folder.path, 'Sky Racer.iso'))..createSync()).path;
      File(p.join(ps2Folder.path, 'retro.json')).writeAsStringSync(
        jsonEncode({'platform': 'ps2', 'titleId': 'SLUS20001', 'name': 'Sky Racer', 'disc': 'Sky Racer.iso'}),
      );
    }
    model.setRetroLibrary(true);
    game = model.games.singleWhere((game) => game.retro?.platform == RetroPlatform.ps1);
    model.retroStatusEvery = const Duration(hours: 1);
    model.openRetroHost = (install, {checked, required volume, required muted}) {
      opened.add((install, volume, muted));
      this.checked.add(checked);
      if (opened.length > sessions.length) sessions.add(FakeRetroHostSession());
      return sessions[opened.length - 1];
    };
  }

  /// A launcher on the debug host [host] (ANYPS5_RETRO_HOST), or none with [hostFound] false; with
  /// [ps2], LRPS2 beside it and a PS2 disc in the games folder.
  Ps1Launcher({bool hostFound = true, FakeRetroHostSession? session, Uri? retroHostApi, bool ps2 = false})
    : this._(hostFound: hostFound, release: false, session: session, retroHostApi: retroHostApi, ps2: ps2);

  /// A launcher whose host is the recorded signed release, installed into its storage, as a
  /// release build has it; with [ps2], the release with LRPS2 and a PS2 disc in the games folder.
  static Future<Ps1Launcher> withRelease({FakeRetroHostSession? session, Uri? retroHostApi, bool ps2 = false}) async {
    final launcher = Ps1Launcher._(
      hostFound: true,
      release: true,
      session: session,
      retroHostApi: retroHostApi,
      ps2: ps2,
    );
    await installRetroHostFixture(RetroHostStore(launcher.model.paths.retroHost).folder, ps2: ps2);
    return launcher;
  }

  /// Whether the host is the signed release rather than the debug host.
  final bool release;

  late final Fixture fixture;
  late final String host;
  late final String core;
  late final String disc;
  late final Game game;

  /// The PS2 disc, when the launcher was made with `ps2`.
  String? ps2Disc;

  /// The PS2 game, when the launcher was made with `ps2`.
  Game get ps2Game => model.games.singleWhere((game) => game.retro?.platform == RetroPlatform.ps2);

  /// Puts the PS2 cue sheet [name] (and its bin) under a PS2 folder in the games folder: a disc
  /// PCSX2 does not boot, so the library lists it only while PS2 discs play in the host.
  void addPs2CueSheet(String name) {
    final folder = Directory(p.join(model.root!, 'PS2', name))..createSync(recursive: true);
    File(p.join(folder.path, '$name.bin')).createSync();
    File(p.join(folder.path, '$name.cue')).writeAsStringSync('FILE "$name.bin" BINARY\n  TRACK 01 MODE2/2352\n');
  }

  /// Whether the library lists a game named [name].
  bool lists(String name) => model.games.any((game) => game.name == name);
  final folders = <Directory>[];

  /// The fake hosts, in the order they are started; the first is the one given, if any.
  final List<FakeRetroHostSession> sessions;

  /// The session made last: the host the next game starts on, until another is made.
  FakeRetroHostSession get session => sessions.last;
  final opened = <(RetroHostInstall, double, bool)>[];

  /// The check each host was started with, in [opened]'s order: null for the debug host. Each is
  /// let go when the launcher goes, as the client lets it go when its host exits.
  final checked = <RetroHostChecked?>[];

  AppModel get model => fixture.model;
  RetroPlay get play => model.retroPlay!;

  /// Plays the game ([ps2Game] with [ps2]), the host greets the launcher (unless it did before) and
  /// the game loads.
  Future<void> start({RetroStatus? status, bool ps2 = false}) async {
    session.nextStatus = status ?? fakeStatus();
    final playing = model.play(ps2 ? ps2Game : game);
    if (!session.readyCompleter.isCompleted) session.readyCompleter.complete();
    await playing;
    await pumpEventQueue();
  }

  /// Settings › Emulators, opened.
  PanelCategory emulatorSettings() {
    model.open(Layer.settings);
    return model.panelCategories().singleWhere((category) => category.id == 'emulators');
  }

  PanelRow row(String id) => model.panelCategories().single.rows.singleWhere((row) => row.id == id);

  bool _modelDisposed = false;

  /// The launcher goes away now (as when it quits), before the test ends.
  void disposeModel() {
    _modelDisposed = true;
    model.dispose();
  }

  void dispose() {
    for (final check in checked) {
      check?.release();
    }
    if (!_modelDisposed) model.dispose();
    fixture.dispose();
    for (final folder in folders) {
      folder.deleteSync(recursive: true);
    }
  }
}

/// A two-disc game's status with the internal resolution option, as protocol.md "status" shows.
RetroStatus menuStatus({int selected = 0, bool busy = false, bool failed = false}) => RetroStatus(
  ready: true,
  ended: false,
  error: '',
  errorCode: '',
  options: {
    'swanstation_GPU_ResolutionScale': RetroOption(
      key: 'swanstation_GPU_ResolutionScale',
      title: 'Internal Resolution',
      values: const ['1', '2', '4'],
      labels: const ['1x', '2x', '4x'],
      selected: selected,
      activeValue: const ['1', '2', '4'][selected],
      restart: false,
    ),
  },
  discs: RetroDiscs(
    labels: const ['Disc 1', 'Disc 2'],
    inserted: 0,
    insertedDiscPath: null,
    playedDiscPath: '',
    busy: busy,
    failed: failed,
  ),
);

/// The real host's status once a game was ready, with its fifty SwanStation options in the host's
/// order (test/fixtures/retro-host-swanstation-status.json), and the two discs of [menuStatus].
/// [selected] chooses an option's value by its index, and makes it the value in effect.
RetroStatus recordedStatus({Map<String, int> selected = const {}}) {
  final file = jsonDecode(File('test/fixtures/retro-host-swanstation-status.json').readAsStringSync()) as Map;
  final status = (file['status'] as Map).cast<String, Object?>();
  final options = (status['options']! as Map).cast<String, Object?>();
  for (final MapEntry(:key, :value) in selected.entries) {
    final option = (options[key]! as Map).cast<String, Object?>();
    option['selected'] = value;
    option['activeValue'] = (option['values']! as List)[value];
    options[key] = option;
  }
  status['options'] = options;
  status['discs'] = menuStatus().discs!.toJson();
  return RetroStatus.parse(status);
}
