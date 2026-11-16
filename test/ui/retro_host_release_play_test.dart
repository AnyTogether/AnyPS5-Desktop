import 'dart:io';

import 'package:anyps5_desktop/core/retro_host/retro_host_store.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_github.dart';
import '../support/ps1_launcher.dart';
import '../support/retro_host_release_fixture.dart';
import 'retro_host/real_host_support.dart' show until;

/// A release build's PS1 host: downloaded in Settings › Emulators from the host repository's signed
/// releases (the recorded release of test/fixtures/retro_host_release on a fake GitHub), checked
/// before every start and started through the checked files, with no ANYPS5_RETRO_HOST.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Ps1Launcher launcher;
  // The test binding answers every HTTP request with 400; these talk to a fake GitHub on loopback.
  setUp(() => HttpOverrides.global = null);
  tearDown(() => launcher.dispose());

  PanelRow? row(String id) => launcher.emulatorSettings().rows.where((row) => row.id == id).firstOrNull;

  test('the installed release plays through its checked files, held for the host', () async {
    launcher = await Ps1Launcher.withRelease();
    final model = launcher.model..setRetroHostPs1(true);
    final install = model.retroHostInstall!;
    expect(install.checked, isTrue);
    expect(p.isWithin(model.paths.retroHost, install.host), isTrue, reason: "the launcher's own storage");
    expect(row('retro-host-download')!.title, T.format('retroHostInstalled', ['1.0.0']));
    expect(row('retro-host-ps1'), isNotNull);
    expect(row('retro-host-unchecked'), isNull, reason: 'a signed host is checked');
    model.closeOverlay();
    expect(model.stateOf(launcher.game), isA<Installed>());

    final playing = model.play(launcher.game);
    await until(() => launcher.opened.isNotEmpty, const Duration(seconds: 10));
    final checked = launcher.checked.single!;
    expect(checked.held, isTrue);
    expect((checked.executable, checked.core), (install.host, install.core));
    launcher.session.readyCompleter.complete();
    await playing;
    expect(launcher.session.startArgs?['core'], install.core);
    expect(launcher.play.core, install.core);
  });

  test('a host whose files changed is not started, and its row offers it again', () async {
    launcher = await Ps1Launcher.withRelease();
    final model = launcher.model..setRetroHostPs1(true);
    File(model.retroHostInstall!.core).writeAsStringSync('changed\n');
    model.closeOverlay();
    await model.play(launcher.game);
    expect(launcher.opened, isEmpty);
    expect(model.retroPlay, isNull);
    expect(model.toast, T.text('retroHostCheckFailed'));
    final download = row('retro-host-download')!;
    expect((download.title, download.detail), (T.text('retroHostDownload'), T.text('retroHostBrokenDetail')));
  });

  test('a kept host is checked again before its next game, and shut down when its core changed', () async {
    launcher = await Ps1Launcher.withRelease();
    final model = launcher.model..setRetroHostPs1(true);
    model.select(model.games.indexOf(launcher.game));
    await launcher.start();
    await model.closeRetroGame();
    expect(model.retroHostKeeper.holding, isTrue);

    await launcher.start();
    expect(launcher.opened, hasLength(1), reason: 'an unchanged host plays the next game');
    await model.closeRetroGame();
    expect(model.retroHostKeeper.holding, isTrue);

    launcher.checked.single!.release();
    File(model.retroHostInstall!.core).writeAsStringSync('changed\n');
    await model.play(launcher.game);
    await pumpEventQueue();
    expect(model.retroPlay, isNull);
    expect(launcher.opened, hasLength(1));
    expect(model.toast, T.text('retroHostCheckFailed'));
    expect(launcher.session.shutdownAsked, isTrue, reason: 'the kept host is not used again');
  });

  test('no host starts while a download puts a new one in place', () async {
    launcher = await Ps1Launcher.withRelease();
    final model = launcher.model..setRetroHostPs1(true);
    model.retroHostDownload.installing = true;
    await model.play(launcher.game);
    expect(launcher.opened, isEmpty);
    expect(model.toast, T.text('retroHostUpdating'));
  });

  group('downloading', () {
    late FakeGitHub github;
    setUp(() async => github = await FakeGitHub.start(repository: RetroHostStore.repository));
    tearDown(() async => github.close());

    test('offered in Settings, then checked, installed, turned on and played', () async {
      github.releases.add(retroHostFixtureRelease());
      launcher = Ps1Launcher(hostFound: false, retroHostApi: github.api);
      final model = launcher.model;
      expect(model.retroHostInstall, isNull);
      expect(row('retro-host-ps1'), isNull);
      final offer = row('retro-host-download')!;
      expect((offer.title, offer.detail), (T.text('retroHostDownload'), T.text('retroHostDownloadDetail')));
      expect(github.requests, isEmpty, reason: 'nothing is asked of GitHub before the player presses');

      await model.retroHostDownload.download();
      expect(model.toast, T.format('retroHostReady', ['1.0.0']));
      expect(model.retroHostInstall?.checked, isTrue);
      expect(model.preferences.retroHostPs1, isTrue, reason: 'the first host turns the setting on');
      expect(row('retro-host-download')!.title, T.format('retroHostInstalled', ['1.0.0']));
      expect(row('retro-host-ps1'), isNotNull);

      final asked = github.downloads.length;
      await model.retroHostDownload.download();
      expect(model.toast, T.format('retroHostUpToDate', ['1.0.0']));
      expect(github.downloads, hasLength(asked), reason: 'nothing newer: nothing downloaded');

      model.closeOverlay();
      final playing = model.play(launcher.game);
      await until(() => launcher.opened.isNotEmpty, const Duration(seconds: 10));
      expect(launcher.checked.single?.held, isTrue);
      launcher.session.readyCompleter.complete();
      await playing;
    });

    test('a broken host is downloaded again, even at the same version', () async {
      github.releases.add(retroHostFixtureRelease());
      launcher = Ps1Launcher(hostFound: false, retroHostApi: github.api);
      final model = launcher.model;
      await model.retroHostDownload.download();
      File(model.retroHostInstall!.host).writeAsStringSync('changed\n');
      model.closeOverlay();
      await model.play(launcher.game);
      expect(model.toast, T.text('retroHostCheckFailed'));
      await model.retroHostDownload.download();
      expect(model.toast, T.format('retroHostReady', ['1.0.0']));
      expect(model.retroHostDownload.broken, isNull);
      final checked = await model.retroHostDownload.store.check();
      checked.release();
    });

    test('a host with a file missing is downloaded again at the same version', () async {
      github.releases.add(retroHostFixtureRelease());
      launcher = Ps1Launcher(hostFound: false, retroHostApi: github.api);
      final model = launcher.model;
      await model.retroHostDownload.download();
      final core = model.retroHostInstall!.core;
      File(core).deleteSync();
      expect(model.retroHostInstall, isNull);
      expect(row('retro-host-download')!.title, T.text('retroHostDownload'));
      await model.retroHostDownload.download();
      expect(model.toast, T.format('retroHostReady', ['1.0.0']));
      expect(File(core).existsSync(), isTrue);
    });

    test('a download shuts the kept host down and waits for it before the new host goes in', () async {
      github.releases.add(retroHostFixtureRelease(tag: 'v1.0.1'));
      launcher = await Ps1Launcher.withRelease(retroHostApi: github.api);
      final model = launcher.model..setRetroHostPs1(true);
      model.select(model.games.indexOf(launcher.game));
      await launcher.start();
      await model.closeRetroGame();
      expect(model.retroHostKeeper.holding, isTrue);
      expect(model.retroHostKeeper.keeps(program: model.retroHostInstall!.host), isTrue);
      launcher.checked.single!.release();
      await model.retroHostDownload.download();
      expect(launcher.session.shutdownAsked, isTrue);
      expect(launcher.session.closed, isTrue, reason: 'waited for before the files were replaced');
      expect(model.retroHostKeeper.holding, isFalse);
      expect(model.toast, T.format('retroHostReady', ['1.0.0']), reason: 'v1.0.1 carries the 1.0.0 files');
    });

    test('a download while a game is starting in the host refuses and leaves the kept host', () async {
      github.releases.add(retroHostFixtureRelease(tag: 'v1.0.1'));
      launcher = await Ps1Launcher.withRelease(retroHostApi: github.api);
      final model = launcher.model..setRetroHostPs1(true);
      model.select(model.games.indexOf(launcher.game));
      await launcher.start();
      await model.closeRetroGame();
      expect(model.retroHostDownload.holdForStart(), isTrue, reason: 'as a start between its checks and its play');
      await model.retroHostDownload.download();
      expect(model.toast, T.text('retroHostDownloadCloseGame'));
      expect(launcher.session.shutdownAsked, isFalse, reason: 'the starting game may still take it');
      expect(model.retroHostKeeper.holding, isTrue);
      expect(model.retroHostDownload.installing, isFalse);
      model.retroHostDownload.releaseStart();
      expect(model.retroHostDownload.holdForStart(), isTrue);
      model.retroHostDownload.releaseStart();
    });

    test('a download the launcher closes during is not put in place, and none starts after', () async {
      github.releases.add(retroHostFixtureRelease(tag: 'v1.0.1'));
      launcher = await Ps1Launcher.withRelease(retroHostApi: github.api);
      final model = launcher.model;
      final download = model.retroHostDownload;
      final installed = File(model.retroHostInstall!.host).lastModifiedSync();
      final going = download.download();
      download.close();
      await going;
      expect(model.toast, isNot(T.format('retroHostReady', ['1.0.0'])));
      expect(download.installing, isFalse);
      expect(File(model.retroHostInstall!.host).lastModifiedSync(), installed);
      final asked = github.requests.length;
      await download.download();
      expect(github.requests, hasLength(asked), reason: 'a closed launcher downloads nothing');
    });

    test('with no signed release yet, the row says so', () async {
      launcher = Ps1Launcher(hostFound: false, retroHostApi: github.api);
      final model = launcher.model;
      await model.retroHostDownload.download();
      expect(model.toast, T.text('retroHostNotYet'));
      expect(row('retro-host-download')!.detail, T.text('retroHostNotYet'));
      expect(model.retroHostInstall, isNull);
    });

    test('not while a PS1 game plays', () async {
      github.releases.add(retroHostFixtureRelease());
      launcher = Ps1Launcher(retroHostApi: github.api);
      final model = launcher.model..setRetroHostPs1(true);
      await launcher.start();
      expect(model.retroPlay, isNotNull);
      await model.retroHostDownload.download();
      expect(model.toast, T.text('retroHostDownloadCloseGame'));
      expect(github.requests, isEmpty);
    });

    test('a debug build running ANYPS5_RETRO_HOST offers no download and says its host is unchecked', () async {
      launcher = Ps1Launcher(retroHostApi: github.api);
      expect(row('retro-host-download'), isNull);
      expect(row('retro-host-ps1'), isNotNull);
      expect(row('retro-host-unchecked')?.title, T.text('retroHostUnchecked'));
      expect(launcher.model.retroHostInstall?.checked, isFalse);
    });
  });
}
