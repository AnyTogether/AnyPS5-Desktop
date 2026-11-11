import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'strings.dart';

/// The countries a profile can show (ISO 3166-1 alpha-2, the ones AnyTogether accepts), by their
/// name in the launcher's language. The names and their alphabetical order come from ICU's data
/// (assets/countries.json, made by tool/make_countries.mjs), not from translations of ours.
class Countries {
  static const asset = 'assets/countries.json';

  /// Each language's countries as (code, name), in that language's alphabetical order.
  static Map<String, List<(String, String)>> _names = const {};

  /// Reads the names: from [file] (tests, which have no asset bundle) or the launcher's assets.
  /// Without them a country is shown by its code.
  static Future<void> load({AssetBundle? bundle, File? file}) async {
    try {
      read(file != null ? await file.readAsString() : await (bundle ?? rootBundle).loadString(asset, cache: false));
    } on Object catch (error) {
      debugPrint('[anyps5-launcher] no country names: $error');
    }
  }

  static void read(String text) {
    final json = jsonDecode(text) as Map<String, dynamic>;
    _names = {
      for (final MapEntry(key: language, value: list) in json.entries)
        language: [
          for (final entry in list as List<dynamic>) ((entry as List<dynamic>)[0] as String, entry[1] as String),
        ],
    };
  }

  /// The countries in the launcher's language (its base language for de-AT, then English).
  static List<(String, String)> get all {
    final code = T.language.code;
    return _names[code] ?? _names[code.split(RegExp('[-_]')).first] ?? _names['en'] ?? const [];
  }

  /// The country's name in the launcher's language; the code itself for one the list lacks, null
  /// for no country.
  static String? name(String? code) {
    final wanted = code?.trim().toUpperCase() ?? '';
    if (wanted.isEmpty) return null;
    for (final (known, name) in all) {
      if (known == wanted) return name;
    }
    return wanted;
  }

  /// The countries whose name has every word of [query], whatever the case and the accents
  /// ("turk" finds Türkiye, "isvec" İsveç); a two-letter code finds its country first, then the
  /// names that begin with it, and the English name finds a country in any language. All of them
  /// for an empty query.
  static List<(String, String)> search(String query) {
    final words = fold(query).split(RegExp(r'\s+')).where((word) => word.isNotEmpty).toList();
    if (words.isEmpty) return all;
    final english = {for (final (code, name) in _names['en'] ?? const <(String, String)>[]) code: fold(name)};
    final code = query.trim().toUpperCase();
    final found = [
      for (final entry in all)
        if (words.every((word) => fold(entry.$2).contains(word) || (english[entry.$1]?.contains(word) ?? false))) entry,
    ];
    final exact = all.where((entry) => entry.$1 == code).toList();
    // A name (or one of its words) that begins with what was typed comes before one that only
    // has it somewhere inside: "al" is Almanya before Adaları.
    final typed = words.join(' ');
    bool begins((String, String) entry) {
      final name = fold(entry.$2);
      return name.startsWith(typed) || name.contains(' $typed');
    }

    final rest = found.where((entry) => entry.$1 != code).toList();
    return [...exact, ...rest.where(begins), ...rest.where((entry) => !begins(entry))];
  }

  static const _accents = {
    'àáâãäåāăą': 'a',
    'çćĉċč': 'c',
    'ďđ': 'd',
    'èéêëēĕėęě': 'e',
    'ĝğġģ': 'g', // not a text
    'ìíîïĩīĭįı': 'i', // not a text
    'ñńņň': 'n',
    'òóôõöøōŏő': 'o',
    'ŕŗř': 'r',
    'śŝşšș': 's', // not a text
    'ţťț': 't',
    'ùúûüũūŭůűų': 'u',
    'ýÿ': 'y',
    'źżž': 'z',
  };

  static final Map<int, String> _plain = {
    for (final MapEntry(key: letters, value: plain) in _accents.entries)
      for (final rune in letters.runes) rune: plain,
  };

  /// [text] in small letters without accents, for comparing what is typed with a name.
  static String fold(String text) {
    final out = StringBuffer();
    // İ becomes i and a combining dot (U+0307) in small letters: the dot goes.
    for (final rune in text.toLowerCase().replaceAll('̇', '').runes) {
      out.write(_plain[rune] ?? String.fromCharCode(rune));
    }
    return out.toString().trim();
  }
}
