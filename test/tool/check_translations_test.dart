import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/check_translations.dart';

/// The CI check of the language files: what stops a translation, and what is only counted.
void main() {
  const english = {
    'languageName': 'English',
    'gamesFound': '%d games found',
    'gameJoined': 'Starting %2\$@ with %1\$@',
    'back': 'Back',
  };

  test('a text with other placeholders than the English one is a problem', () {
    final report = checkLanguage(
      'de',
      '{"languageName": "Deutsch", "gamesFound": "%@ Spiele gefunden", "back": "Zurück"}',
      english,
    );
    expect(report.problems, hasLength(1));
    expect(report.problems.single, contains('gamesFound'));
  });

  test('placeholders may change places when they are numbered', () {
    final report = checkLanguage(
      'tr',
      '{"languageName": "Türkçe", '
          r'"gameJoined": "%1$@ ile %2$@ başlıyor", "gamesFound": "%d oyun bulundu"}',
      english,
    );
    expect(report.problems, isEmpty);
  });

  test('a key English does not have is a problem', () {
    final report = checkLanguage('de', '{"languageName": "Deutsch", "bakc": "Zurück"}', english);
    expect(report.problems, hasLength(1));
    expect(report.problems.single, contains('bakc'));
  });

  test('a key written twice is a problem, in English too: the launcher would show only the last one', () {
    final report = checkLanguage('de', '{"languageName": "Deutsch", "back": "Zurück", "back": "Zurueck"}', english);
    expect(report.problems.single, contains('"back"'));
    final (_, problems) = readTexts('en.json', '{"back": "Back", "gamesFound": "%d games found", "back": "Back"}');
    expect(problems.single, contains('"back"'));
    // Keys of a nested object, texts in a list and an escaped quote in a text are not keys of the file.
    expect(duplicateKeys(r'{"a": "x", "b": {"a": "y"}, "c": ["a", "a"], "d": "\"a\": \"a\": "}'), isEmpty);
    expect(duplicateKeys('{"a": "x", "b": "y", "a": "z", "b": "w", "a": "v"}'), ['a', 'b']);
  });

  test('missing keys are only counted, the language name too', () {
    final report = checkLanguage('de', '{"back": "Zurück"}', english);
    expect(report.problems, isEmpty);
    expect(report.notes.single, contains('languageName'));
    expect(report.translated, 1);
    expect(report.total, 4);
    expect(report.coverage, closeTo(25, 0.1));
  });

  test('a file that is not JSON, or has a value that is not a text, is a problem', () {
    expect(checkLanguage('de', '{"back": "Zurück",}', english).problems, hasLength(1));
    expect(checkLanguage('de', '["back"]', english).problems, hasLength(1));
    expect(checkLanguage('de', '{"languageName": "Deutsch", "back": 7}', english).problems, isNotEmpty);
    expect(checkLanguage('de', '{"languageName": "  "}', english).problems, isNotEmpty);
  });

  test('the old "@meta" object is a problem in the repository: Weblate reads every value as a text', () {
    final report = checkLanguage(
      'de',
      '{"@meta": {"name": "Deutsch", "consoleLanguage": 4}, "back": "Zurück"}',
      english,
    );
    expect(report.problems.single, contains('"languageName": "Deutsch"'));
  });

  test('a file is named by a locale code', () {
    for (final code in ['de', 'pt-BR', 'zh-Hant', 'es-419', 'pt_BR', 'fil']) {
      expect(checkLanguage(code, '{"languageName": "X"}', english).problems, isEmpty, reason: code);
    }
    for (final code in ['German', 'de copy', 'DE', 'de-']) {
      expect(checkLanguage(code, '{"languageName": "X"}', english).problems, isNotEmpty, reason: code);
    }
  });

  test('English itself has to be in the new format', () {
    final folder = Directory.systemTemp.createTempSync('anyps5_check');
    addTearDown(() => folder.deleteSync(recursive: true));
    File('${folder.path}/en.json').writeAsStringSync('{"@meta": {"name": "English"}, "back": "Back"}');
    final out = StringBuffer();
    expect(checkFolder(folder, out), 1);
    expect(out.toString(), contains('en.json'));
    File('${folder.path}/en.json').writeAsStringSync('{"languageName": "English", "back": "Back"}');
    File('${folder.path}/de.json').writeAsStringSync('{"back": "Zurück"}');
    final again = StringBuffer();
    expect(checkFolder(folder, again), 0, reason: again.toString());
    expect(again.toString(), contains('de: 50.0 %'));
  });

  test('a description ends as a sentence; a label, a placeholder or a line of facts need not', () {
    const descriptions = {
      'languageName': 'English',
      'back': 'Back',
      'gyroDetail': 'Turn the controller to move the right stick.',
      'clipsDetail': 'Saves the last %d seconds to the gallery',
      'presenceHint': 'Friends see you as offline!',
      'updateChoiceText': 'An update is ready for this game',
      'sdlMissingDetail': 'Reinstall AnyPS5 Desktop. (%@)',
      'profileNameHint': 'Name',
      'engineDownloadDetail': 'Version %@ · %@ · from GitHub',
    };
    final problems = punctuationProblems('en.json', descriptions);
    expect(problems, hasLength(2), reason: problems.join('\n'));
    expect(problems.join(), allOf(contains('clipsDetail'), contains('updateChoiceText')));
    expect(isDescription('back'), isFalse);
    expect(isDescription('profileNameHint'), isFalse);
    expect(isDescription('padTestDetail'), isTrue);
    // A translation too, in its own script's marks.
    final german = checkLanguage('de', '{"languageName": "Deutsch", "gyroDetail": "Den Controller drehen"}', {
      ...english,
      'gyroDetail': 'Turn the controller.',
    });
    expect(german.problems.single, contains('gyroDetail'));
    expect(
      checkLanguage('ja', '{"languageName": "日本語", "gyroDetail": "コントローラーを回します。"}', {
        ...english,
        'gyroDetail': 'Turn the controller.',
      }).problems,
      isEmpty,
    );
    // Khmer ends a sentence with its khan, Amharic with ።, Lao with a full stop, and Chinese may
    // put the placeholder in full-width brackets.
    final scripts = {
      'km': 'បង្វិលឧបករណ៍បញ្ជា។ (%@)',
      'am': 'መቆጣጠሪያውን ያዙሩ። (%@)',
      'lo': 'ໝຸນຕົວຄວບຄຸມ. (%@)',
      'zh-Hans': '请重新安装 AnyPS5 Desktop。（%@）',
    };
    for (final MapEntry(key: code, value: text) in scripts.entries) {
      expect(
        checkLanguage(code, jsonEncode({'languageName': code, 'sdlMissingDetail': text}), {
          ...english,
          'sdlMissingDetail': 'Reinstall AnyPS5 Desktop. (%@)',
        }).problems,
        isEmpty,
        reason: code,
      );
    }
    expect(
      checkLanguage('km', jsonEncode({'languageName': 'ខ្មែរ', 'gyroDetail': 'បង្វិលឧបករណ៍បញ្ជា'}), {
        ...english,
        'gyroDetail': 'Turn the controller.',
      }).problems.single,
      contains('gyroDetail'),
    );
  });

  test('the code may not pick a text by the language, or hold a Turkish one', () {
    final folder = Directory.systemTemp.createTempSync('anyps5_lib');
    addTearDown(() => folder.deleteSync(recursive: true));
    Directory('${folder.path}/lib/ui').createSync(recursive: true);
    File('${folder.path}/lib/ui/a.dart').writeAsStringSync('''
// A comment may say Yavaş yürüme.
String a(bool turkish) => turkish ? 'Mavi' : 'Blue';
String b() => T.language.code == 'tr' ? 'x' : 'y';
String c() => 'Sağ tık';
String d() => T.text('accentBlue'); // not 'Mavi'
String e() => 'Français, Español';
String f() => T.text('titleID').toUpperCase();
String g() => T.upper(T.text('titleID'));
''');
    final problems = checkSources(Directory('${folder.path}/lib'));
    expect(problems, hasLength(4), reason: problems.join('\n'));
    expect(problems.last, allOf(startsWith('lib/ui/a.dart:7:'), contains('T.upper')));
    expect(problems.first, startsWith('lib/ui/a.dart:2:'));
  });

  test('the launcher code passes', () {
    expect(checkSources(Directory('lib')), isEmpty);
  });

  test('the files in assets/l10n pass', () {
    final out = StringBuffer();
    expect(checkFolder(Directory('assets/l10n'), out), 0, reason: out.toString());
    expect(out.toString(), contains('tr: 100.0 %'));
  });
}
