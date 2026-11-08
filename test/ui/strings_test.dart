import 'dart:io';

import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/language_files.dart';

void main() {
  tearDown(() => T.language = Language.english);

  test('every text the interface asks for exists in both languages', () {
    final keys = <String>{};
    final pattern = RegExp(r"""T\.(?:text|format)\(\s*'([A-Za-z0-9]+)'""");
    final inSwitch = RegExp(r"""=> '([a-z][A-Za-z0-9]+)'""");
    for (final file in Directory('lib/ui').listSync().whereType<File>()) {
      final source = file.readAsStringSync();
      keys.addAll(pattern.allMatches(source).map((match) => match.group(1)!));
      // Keys chosen in a switch and passed to T.text afterwards.
      if (source.contains('T.text(switch')) keys.addAll(inSwitch.allMatches(source).map((match) => match.group(1)!));
    }
    expect(keys.length, greaterThan(80));
    final missing = <String>[];
    for (final code in ['en', 'tr']) {
      final texts = languageFile(code);
      missing.addAll([
        for (final key in keys)
          if (!texts.containsKey(key)) '$key ($code)',
      ]);
    }
    expect(missing, isEmpty);
  });

  test('Turkish has every English text and no other', () {
    expect(languageFile('tr').keys.toSet(), languageFile('en').keys.toSet());
  });

  test('the Mac is not named where the PC is meant', () {
    for (final language in T.languages) {
      T.language = language;
      for (final key in ['welcomeSubtitle', 'startingText', 'stepRelink', 'aboutText', 'showInFinder', 'themesOnMac']) {
        expect(T.text(key), isNot(contains('Mac')), reason: '$key in ${language.code}');
        expect(T.text(key), isNot(contains('Finder')), reason: '$key in ${language.code}');
      }
    }
    // Only the two texts of the macOS launcher's tables this one never shows name it, and a
    // friend's device in the encryption sheet, which can be a Mac.
    for (final code in ['en', 'tr']) {
      for (final MapEntry(:key, :value) in languageFile(code).entries) {
        if (key == 'rosettaMissing' || key == 'clipsDetail' || key == 'e2eeDeviceMac') continue;
        expect(value, isNot(contains('Mac')), reason: '$key in $code');
        expect(value, isNot(contains('⌥')), reason: '$key in $code');
      }
    }
  });

  test('format fills %@ and %d in order and keeps %%', () {
    T.language = Language.english;
    expect(T.format('gamesFound', [4]), '4 games found');
    expect(T.format('lastBackup', ['today']), 'Last backup: today');
    T.language = Language.byCode('tr');
    expect(T.format('gamesFound', [4]), '4 oyun bulundu');
    expect(T.format('updateDownloading', [42]), 'İndiriliyor… %42');
  });

  test('capitals follow the language: İ and I in Turkish; a game ID is never cased by it', () {
    T.language = Language.english;
    expect(T.upper('Title ID'), 'TITLE ID');
    expect(T.initial('ivy'), 'I');
    T.language = Language.byCode('tr');
    expect(T.upper(T.text('titleID')), 'OYUN K\u0130ML\u0130Ğ\u0130');
    expect(T.upper('ılık'), 'ILIK');
    expect(T.lower('IŞIK İZİ'), 'ışık izi');
    expect(T.initial('ilker'), '\u0130');
    expect(T.initial(''), '?');
    // The home screen's card shows the ID as the game has it, whatever the language.
    expect('ppsa01001'.toUpperCase(), 'PPSA01001');
  });

  test('the font and hidden trophy texts in both languages', () {
    T.language = Language.byCode('tr');
    expect(T.format('fontsCjkDownloading', [42]), 'İniyor… %42');
    expect(T.text('fontsBuiltIn'), 'Yerleşik');
    T.language = Language.english;
    expect(T.format('fontsCjkDownloading', [42]), 'Downloading… 42%');
  });

  test('the crash report and detailed logging texts are in both languages, the PC\'s words', () {
    bool crash(String key) =>
        key.startsWith('report') ||
        key.startsWith('trace') ||
        key.startsWith('lastSession') ||
        key.startsWith('diagnosis');
    final keys = languageFile('en').keys.where(crash).toSet();
    expect(keys, isNotEmpty);
    expect(languageFile('tr').keys.where(crash).toSet(), keys);
    for (final language in T.languages) {
      T.language = language;
      for (final key in keys) {
        expect(T.text(key), isNot(contains('Mac')), reason: '$key in ${language.code}');
      }
      expect(T.text('reportSave'), contains('crash_log.txt'));
    }
    T.language = Language.byCode('tr');
    expect(T.format('reportStopped', ['Stray']), 'Stray durdu');
  });

  test('positional placeholders take the argument they name', () {
    T.language = Language.english;
    expect(T.format('gameJoined', ['Utku', 'Orbit Runner']), 'Starting Orbit Runner with Utku');
    T.language = Language.byCode('tr');
    expect(T.format('gameJoined', ['Utku', 'Orbit Runner']), 'Utku ile Orbit Runner başlıyor');
  });
}
