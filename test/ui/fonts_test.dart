import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/font_download.dart';
import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/installer.dart';
import 'package:anyps5_desktop/core/system_fonts.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_file_server.dart';
import '../support/ui_support.dart';

/// The system fonts games get: the folder every game is started with, the Japanese, Chinese and
/// Korean fonts downloaded before a game in those languages starts or after one asked for them,
/// and Settings › Fonts.
void main() {
  late Fixture fixture;
  late AppModel model;
  late FakeFileServer server;
  late FontArchive archive;
  final toasts = <String>[];
  final random = Random(9);
  final regular = Uint8List.fromList(List.generate(50000, (_) => random.nextInt(256)));
  final licence = utf8.encode('SIL Open Font License, Version 1.1');
  final builtIn = p.absolute(SystemFonts.assetFolder);

  FontArchive package({String? sha}) => FontArchive(
    url: server.url,
    size: server.body.length,
    sha256: sha ?? sha256.convert(server.body).toString(),
    members: [
      FontArchiveMember('NotoSansCJK-Regular.ttc', size: regular.length, sha256: sha256.convert(regular).toString()),
      FontArchiveMember(
        'LICENSE',
        savedAs: 'LICENSE-NotoSansCJK.txt',
        size: licence.length,
        sha256: sha256.convert(licence).toString(),
      ),
    ],
  );

  void setUpModel({String? sha}) {
    archive = package(sha: sha);
    fixture = makeFixture(cjkFonts: archive, builtInFonts: builtIn);
    model = fixture.model;
    model.addListener(() {
      if (model.toast case final String toast when toasts.lastOrNull != toast) toasts.add(toast);
    });
  }

  setUp(() async {
    toasts.clear();
    server = await FakeFileServer.start(
      ZipEncoder().encodeBytes(
        Archive()
          ..addFile(ArchiveFile.bytes('NotoSansCJK-Regular.ttc', regular))
          ..addFile(ArchiveFile.bytes('LICENSE', licence)),
      ),
    );
  });

  tearDown(() async {
    model.dispose();
    T.language = Language.english;
    fixture.dispose();
    await server.close();
  });

  Future<void> until(bool Function() condition) async {
    for (var tries = 0; tries < 500 && !condition(); tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(condition(), isTrue);
  }

  Game orbit() => model.games.firstWhere((game) => game.titleId == 'PPSA01001');

  /// The installed game becomes a script that prints its fonts folder, and [also].
  void gameScript({String also = ''}) {
    final installed = Installer.installedFolder(orbit(), model.root!);
    File(p.join(installed, 'app.elf')).writeAsStringSync('#!/bin/sh\nenv | grep ^ANYPS5_SYSTEM_FONTS\n$also\n');
    Process.runSync('chmod', ['755', p.join(installed, 'app.elf')]);
  }

  String log() => File(model.paths.logFile('PPSA01001')).readAsStringSync();

  PanelRow row(String id) {
    model.open(Layer.settings);
    final fonts = model.panelCategories().firstWhere((category) => category.id == 'fonts');
    return fonts.rows.firstWhere((row) => row.id == id);
  }

  String info(String id) => (row(id).kind as InfoRow).text;

  group('starting a game', () {
    test('every game gets the folder the fonts are put together in', () async {
      setUpModel();
      gameScript();
      await model.play(orbit());
      expect(log(), contains('ANYPS5_SYSTEM_FONTS=${model.paths.gameFonts}'));
      expect(SystemFonts.fontsIn(model.paths.gameFonts), hasLength(20));
      expect(server.seen, isEmpty, reason: 'an English game needs no CJK fonts');
    });

    test('the fixed fonts folder of earlier releases still comes first', () async {
      setUpModel();
      File(p.join(model.paths.fontsFolder, 'SST-Roman.otf'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('console');
      gameScript();
      await model.play(orbit());
      expect(File(p.join(model.paths.gameFonts, 'SST-Roman.otf')).readAsStringSync(), 'console');
      expect(File(p.join(model.paths.gameFonts, 'NotoSans-Bold.ttf')).existsSync(), isTrue);
    });

    test('a game in Japanese waits for the CJK fonts, then starts with them', () async {
      setUpModel();
      model.saveSettings(orbit(), model.currentSettings(orbit()).copyWith(language: 0));
      gameScript();
      final playing = model.play(orbit());
      expect(model.stateOf(orbit()), isA<Starting>());
      await playing;
      expect(server.seen, hasLength(1));
      expect(model.fonts.cjkInstalled, isTrue);
      expect(File(p.join(model.paths.gameFonts, 'NotoSansCJK-Regular.ttc')).readAsBytesSync(), regular);
      expect(log(), contains('ANYPS5_SYSTEM_FONTS=${model.paths.gameFonts}'));
      expect(toasts.first, startsWith('Downloading Japanese, Chinese and Korean fonts for Orbit Runner'));
      expect(toasts, contains('Japanese, Chinese and Korean fonts are ready'));
      // The next start finds them.
      await model.play(orbit());
      expect(server.seen, hasLength(1));
    });

    test('a failed download is said, and the game starts all the same', () async {
      setUpModel(sha: 'f' * 64);
      model.saveSettings(orbit(), model.currentSettings(orbit()).copyWith(language: 11));
      gameScript();
      await model.play(orbit());
      expect(toasts.where((toast) => toast.startsWith('The Japanese, Chinese and Korean fonts were not downloaded')), [
        isNotEmpty,
      ]);
      expect(log(), contains('ANYPS5_SYSTEM_FONTS='));
      expect(model.fonts.cjkInstalled, isFalse);
    });

    test('a game seen asking for CJK fonts gets them in the background, and waits for them next time', () async {
      setUpModel();
      gameScript(also: 'echo "[libSceFont] sceFontOpenFontSet fontSetType=0x18080444 file=(none)"');
      await model.play(orbit());
      await until(() => model.fonts.cjkInstalled && model.toast == T.text('fontsCjkReadyRestart'));
      expect(toasts, contains('Orbit Runner needs Japanese, Chinese or Korean fonts: downloading them (100 MB)'));
      expect(model.preferences.cjkGames, {'PPSA01001'});
      expect(File(p.join(model.paths.gameFonts, 'NotoSansCJK-Regular.ttc')).existsSync(), isTrue);
      // Removed, its next start waits for them again.
      await model.fonts.removeCjk();
      expect(File(p.join(model.paths.gameFonts, 'NotoSansCJK-Regular.ttc')).existsSync(), isFalse);
      toasts.clear();
      gameScript();
      await model.play(orbit());
      expect(server.seen, hasLength(2));
      expect(
        toasts.where((toast) => toast.startsWith('Downloading Japanese, Chinese and Korean fonts for')),
        isNotEmpty,
      );
    });

    test('Latin sets in the log ask for nothing', () async {
      setUpModel();
      gameScript(also: 'echo "fontSetType=0x18070044 file=x"; echo "fontSetType=0x180700C4 file=y"');
      await model.play(orbit());
      model.fonts.ended();
      expect(server.seen, isEmpty);
      expect(model.preferences.cjkGames, isEmpty);
    });
  }, skip: Platform.isWindows ? 'the fake game is a shell script' : false);

  group('Settings › Fonts', () {
    test('shows where each script\'s font comes from and the CJK state', () async {
      setUpModel();
      expect(info('fontLatin'), 'Noto Sans · Built in');
      expect(info('fontTypewriter'), 'Noto Sans Mono · Built in');
      expect(info('fontThai'), 'Noto Sans Thai · Built in');
      expect(info('fontArabic'), 'Noto Sans Arabic · Built in');
      expect(info('fontCjk'), 'Downloads the first time a game needs it (100 MB)');
      expect(row('cjkDownload').title, 'Download Japanese, Chinese and Korean now');
      expect(row('fontsFolder').detail, startsWith('None'));
      expect(info('fontsOrder'), contains('SIL Open Font License 1.1'));
      expect(row('cjkDownload').focusable, isTrue);

      // Downloading, then downloaded.
      final download = model.fonts.downloadNow();
      expect(info('fontCjk'), 'Downloading… 0%');
      expect(row('cjkDownload').title, 'Downloading… 0%');
      await download;
      expect(info('fontCjk'), 'Noto Sans CJK · Downloaded');
      expect(row('cjkRemove').title, 'Remove Japanese, Chinese and Korean fonts');
      expect(model.toast, 'Japanese, Chinese and Korean fonts are ready');

      await model.fonts.removeCjk();
      expect(info('fontCjk'), 'Downloads the first time a game needs it (100 MB)');
      expect(Directory(model.paths.downloadedFonts).listSync().whereType<File>(), isEmpty);
    });

    test('a folder of the user\'s own: chosen, its console fonts first, then forgotten', () async {
      setUpModel();
      await model.fonts.chooseFolder();
      final chosen = model.preferences.fontsFolder!;
      File(p.join(chosen, 'SST-Roman.otf')).writeAsStringSync('console');
      model.fonts.refresh();
      expect(row('fontsFolder').detail, chosen);
      expect(info('fontLatin'), 'SST · Your folder');
      expect(info('fontItalic'), 'Noto Sans · Built in', reason: 'the folder has no italic: the launcher\'s fills in');
      expect(info('fontThai'), 'Noto Sans Thai · Built in');
      row('fontsFolderForget');
      model.fonts.forgetFolder();
      expect(model.preferences.fontsFolder, isNull);
      expect(info('fontLatin'), 'Noto Sans · Built in');
      expect(
        model.panelCategories().firstWhere((category) => category.id == 'fonts').rows.map((row) => row.id),
        isNot(contains('fontsFolderForget')),
      );
    });

    test('in Turkish', () {
      setUpModel();
      T.language = Language.byCode('tr');
      expect(info('fontLatin'), 'Noto Sans · Yerleşik');
      expect(info('fontCjk'), 'Bir oyun ilk istediğinde iner (100 MB)');
      expect(row('cjkDownload').title, 'Japonca, Çince ve Korece fontları şimdi indir');
      expect(model.panelCategories().map((category) => category.title), contains('Fontlar'));
    });

    test('the controller moves to the font rows that do something, past the ones that only say', () {
      setUpModel();
      model.open(Layer.settings);
      final categories = model.panelCategories();
      model.selectCategory(categories.indexWhere((category) => category.id == 'fonts'));
      final rows = categories.firstWhere((category) => category.id == 'fonts').rows;
      expect(rows[model.panelRow].id, 'cjkDownload');
      model.handle(Command.down);
      expect(rows[model.panelRow].id, 'fontsFolder');
      model.handle(Command.down);
      expect(rows[model.panelRow].id, 'fontsFolder', reason: 'the last row');
    });
  });
}
