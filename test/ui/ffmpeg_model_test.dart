import 'dart:io';

import 'package:anyps5_desktop/core/ffmpeg_download.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/replay_buffer.dart' show ProcessRunner;
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/ffmpeg_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_github.dart';
import '../support/signing.dart';
import '../support/ui_support.dart';

void main() {
  final key = TestReleaseKey('release');
  late FakeGitHub github;
  late List<List<String>> ran;
  late Directory folder;
  Fixture? fixture;

  ProcessRunner runner({int exit = 0, String out = ''}) => (executable, arguments) async {
    ran.add([executable, ...arguments]);
    return ProcessResult(1, exit, out, '');
  };

  AppModel start({Map<String, String> environment = const {}, ProcessRunner? run}) {
    fixture = makeFixture(
      environment: {'DISPLAY': ':0', ...environment},
      ffmpegApi: github.api,
      ffmpegKeys: [key.key],
      ffmpegRun: run ?? runner(),
    );
    return fixture!.model..open(Layer.settings);
  }

  FakeRelease release({bool signedOk = true, TestReleaseKey? by}) {
    final made = FakeRelease(FfmpegBuild.tag, {
      FfmpegBuild.assetName(HostSystem.linux): tarGzOf({
        'ffmpeg': filler('ffmpeg', 9000),
        'LICENSE.txt': filler('gpl', 80),
      }),
      FfmpegBuild.assetName(HostSystem.windows): zipOf({
        'ffmpeg.exe': filler('ffmpeg', 9000),
        'LICENSE.txt': filler('gpl', 80),
      }),
    }, prerelease: true);
    return signedOk ? signed(made, [by ?? key]) : made;
  }

  List<PanelRow> captures(AppModel model) =>
      model.panelCategories().firstWhere((category) => category.id == 'captures').rows;
  List<PanelRow> broadcast(AppModel model) =>
      model.panelCategories().firstWhere((category) => category.id == 'broadcast').rows;
  PanelRow? offerIn(List<PanelRow> rows) => rows.where((row) => row.id == 'ffmpeg-download').firstOrNull;

  setUp(() async {
    github = await FakeGitHub.start(repository: FfmpegBuild.repository);
    ran = [];
    folder = Directory.systemTemp.createTempSync('anyps5_ffmpeg_path');
  });

  tearDown(() async {
    await github.close();
    fixture?.dispose();
    folder.deleteSync(recursive: true);
  });

  Future<void> until(bool Function() condition) async {
    for (var i = 0; i < 400 && !condition(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(condition(), isTrue);
  }

  void press(PanelRow row) => (row.kind as ActionRow).run();

  group('none found', () {
    test('one row offers it where a feature needs it, and nothing is fetched until it is pressed', () async {
      final model = start();
      expect(model.ffmpegTool.need, FfmpegNeed.missing);
      expect(model.replayUnavailable, contains('ffmpeg'));
      final offer = offerIn(captures(model))!;
      expect(offer.detail, contains('Nothing is downloaded until you select this'));
      expect(offerIn(broadcast(model)), isNotNull);
      expect(github.requests, isEmpty);
    });

    test('pressing downloads it, shows progress, and the features then use it', () async {
      github.releases.add(release());
      final model = start();
      press(offerIn(captures(model))!);
      expect(model.ffmpegTool.downloading, isTrue);
      expect(offerIn(captures(model))!.title, contains('Downloading ffmpeg'));
      await until(() => !model.ffmpegTool.downloading);
      final path = model.replayFfmpeg!;
      expect(path, contains(p.join('FFmpeg', FfmpegBuild.tag)));
      expect(model.ffmpegTool.need, isNull);
      expect(offerIn(captures(model)), isNull);
      expect(model.replayUnavailable, isNull);
      expect(model.toast, 'ffmpeg is ready');
    });

    test('with no release yet it says it is not available yet, and can be asked again', () async {
      final model = start();
      await model.ffmpegTool.download();
      expect(model.ffmpegTool.notYet, isTrue);
      expect(model.toast, contains('not available yet'));
      final row = offerIn(captures(model))!;
      expect(row.detail, contains('not available yet'));
      expect(row.kind, isA<ActionRow>());
      expect(model.replayFfmpeg, isNull);
    });

    test('a release not signed yet counts as not available yet', () async {
      github.releases.add(release(signedOk: false));
      final model = start();
      await model.ffmpegTool.download();
      expect(model.ffmpegTool.notYet, isTrue);
      expect(github.downloads, isEmpty);
    });

    test('a refused signature is said, in its own words, and nothing is put in place', () async {
      github.releases.add(release(by: TestReleaseKey('stranger')));
      final model = start();
      await model.ffmpegTool.download();
      expect(model.ffmpegTool.error, contains('signed with a key this launcher does not trust'));
      expect(offerIn(captures(model))!.detail, contains('does not trust'));
      expect(model.replayFfmpeg, isNull);
      expect(github.downloads.where((path) => !path.contains('SHA256SUMS')), isEmpty);
    });

    test('the download can be stopped: no message, and the offer is back', () async {
      github.releases.add(release());
      github.holdAfter[FfmpegBuild.assetName(HostSystem.linux)] = 200;
      final model = start();
      final done = model.ffmpegTool.download();
      await until(() => github.downloads.any((path) => path.contains('anyps5-ffmpeg')));
      model.ffmpegTool.cancel();
      github.release();
      await done;
      expect(model.ffmpegTool.downloading, isFalse);
      expect(model.ffmpegTool.error, isNull);
      expect(model.replayFfmpeg, isNull);
      expect(offerIn(captures(model))!.title, 'Download ffmpeg');
    });
  });

  group('ffmpeg already on this computer', () {
    late String system;

    setUp(() {
      system = p.join(folder.path, 'ffmpeg');
      File(system).writeAsStringSync('#!/bin/sh\n');
    });

    test('it keeps being used, and nothing is offered', () async {
      final model = start(environment: {'PATH': folder.path});
      expect(model.replayFfmpeg, system);
      expect(model.ffmpegTool.need, isNull);
      expect(offerIn(captures(model)), isNull);
      expect(github.requests, isEmpty);
    });

    test('when no encoder works with it the offer says so, and its download is then the one used', () async {
      github.releases.add(release());
      final model = start(environment: {'PATH': folder.path});
      model.ffmpegTool.noteNoEncoder(system);
      expect(model.ffmpegTool.need, FfmpegNeed.noEncoder);
      expect(offerIn(captures(model))!.detail, contains('no H.264 encoder'));
      await model.ffmpegTool.download();
      expect(model.replayFfmpeg, contains('FFmpeg'));
      expect(model.ffmpegTool.need, isNull);
      expect(model.ffmpegTool.store.preferred, isTrue);
      expect(offerIn(captures(model)), isNull);

      // The next start of the launcher keeps to it.
      expect(FfmpegModel(model).path, contains('FFmpeg'));
    });

    test('another ffmpeg lacking an encoder says nothing about this one', () async {
      final model = start(environment: {'PATH': folder.path});
      model.ffmpegTool.noteNoEncoder(p.join(folder.path, 'other-ffmpeg'));
      expect(model.ffmpegTool.need, isNull);
    });

    test('an ffmpeg without x264 is noticed for clip tools', () async {
      final model = start(
        environment: {'PATH': folder.path},
        run: runner(out: ' V..... h264_vaapi  H.264 (VAAPI)\n'),
      );
      expect(await model.ffmpegTool.systemLacksX264(), isTrue);
      expect(model.ffmpegTool.need, FfmpegNeed.noEncoder);
    });

    test('one with x264 is left alone', () async {
      final model = start(
        environment: {'PATH': folder.path},
        run: runner(out: ' V..... libx264  x264\n'),
      );
      expect(await model.ffmpegTool.systemLacksX264(), isFalse);
      expect(model.ffmpegTool.need, isNull);
    });
  });

  test('without a release source nothing is offered, whatever is missing', () {
    fixture = makeFixture(environment: const {});
    fixture!.model.open(Layer.settings);
    expect(fixture!.model.ffmpegTool.offered, isFalse);
    expect(offerIn(captures(fixture!.model)), isNull);
  });
}
