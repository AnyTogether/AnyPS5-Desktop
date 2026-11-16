import 'dart:convert';
import 'dart:typed_data';

/// A message body the emulator host's protocol does not accept (anyps5-retro-host
/// docs/protocol.md, "Values"): not UTF-8, not one JSON object, a key twice in one object, a lone
/// surrogate, or a number that is not finite.
class StrictJsonError implements Exception {
  const StrictJsonError(this.message);

  final String message;

  @override
  String toString() => 'StrictJsonError: $message';
}

/// Reads one message body as protocol.md "Values" says. dart:convert's decoder lets a repeated key
/// win silently and keeps lone surrogates, which the protocol makes errors, so this parses by hand.
///
/// Objects become `Map<String, Object?>` in key order and arrays `List<Object?>`. A number whose
/// value is whole becomes an [int] (the protocol judges integers by value, so `1.0` and `1e0` are
/// 1); any other becomes a [double].
abstract final class StrictJson {
  /// Nesting deeper than this is refused, so a 1 MiB body of brackets cannot exhaust the stack.
  static const maxDepth = 256;

  /// The JSON object in [body], or throws [StrictJsonError].
  static Map<String, Object?> decodeObject(Uint8List body) {
    final String text;
    try {
      text = const Utf8Decoder().convert(body);
    } on FormatException {
      throw const StrictJsonError('The body is not valid UTF-8.');
    }
    final value = _Parser(text).parseDocument();
    if (value is! Map<String, Object?>) throw const StrictJsonError('The body is not one JSON object.');
    return value;
  }

  /// Whether [value], or any string inside it, holds a surrogate without its pair; such a string
  /// cannot be sent as UTF-8 (protocol.md "Paths").
  static bool hasLoneSurrogate(Object? value) => switch (value) {
    final String text => _loneSurrogateIn(text),
    final Map<Object?, Object?> map => map.entries.any((e) => hasLoneSurrogate(e.key) || hasLoneSurrogate(e.value)),
    final List<Object?> list => list.any(hasLoneSurrogate),
    _ => false,
  };

  static bool _loneSurrogateIn(String text) {
    for (var i = 0; i < text.length; i++) {
      final unit = text.codeUnitAt(i);
      if (unit >= 0xD800 && unit <= 0xDBFF) {
        if (i + 1 >= text.length) return true;
        final next = text.codeUnitAt(i + 1);
        if (next < 0xDC00 || next > 0xDFFF) return true;
        i++;
      } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
        return true;
      }
    }
    return false;
  }
}

class _Parser {
  _Parser(this.text);

  final String text;
  int at = 0;
  int depth = 0;

  Object? parseDocument() {
    skipSpace();
    final value = parseValue();
    skipSpace();
    if (at != text.length) fail('Text follows the JSON value.');
    return value;
  }

  Never fail(String message) => throw StrictJsonError('$message (at $at)');

  void skipSpace() {
    while (at < text.length) {
      final unit = text.codeUnitAt(at);
      if (unit != 0x20 && unit != 0x09 && unit != 0x0A && unit != 0x0D) return;
      at++;
    }
  }

  Object? parseValue() {
    if (at >= text.length) fail('A value is missing.');
    final unit = text.codeUnitAt(at);
    switch (unit) {
      case 0x7B:
        return parseObject();
      case 0x5B:
        return parseArray();
      case 0x22:
        return parseString();
      case 0x74:
        return literal('true', true);
      case 0x66:
        return literal('false', false);
      case 0x6E:
        return literal('null', null);
      default:
        if (unit == 0x2D || (unit >= 0x30 && unit <= 0x39)) return parseNumber();
        fail('Unexpected character.');
    }
  }

  Object? literal(String word, Object? value) {
    if (!text.startsWith(word, at)) fail('Unexpected word.');
    at += word.length;
    return value;
  }

  void enter() {
    if (++depth > StrictJson.maxDepth) fail('The JSON is nested too deeply.');
  }

  Map<String, Object?> parseObject() {
    enter();
    at++;
    final map = <String, Object?>{};
    skipSpace();
    if (at < text.length && text.codeUnitAt(at) == 0x7D) {
      at++;
      depth--;
      return map;
    }
    while (true) {
      skipSpace();
      if (at >= text.length || text.codeUnitAt(at) != 0x22) fail('An object key is missing.');
      final key = parseString();
      if (map.containsKey(key)) fail('The key "$key" appears twice in one object.');
      skipSpace();
      if (at >= text.length || text.codeUnitAt(at) != 0x3A) fail('A colon is missing.');
      at++;
      skipSpace();
      map[key] = parseValue();
      skipSpace();
      if (at >= text.length) fail('An object is not closed.');
      final unit = text.codeUnitAt(at++);
      if (unit == 0x7D) break;
      if (unit != 0x2C) fail('A comma or closing brace is missing.');
    }
    depth--;
    return map;
  }

  List<Object?> parseArray() {
    enter();
    at++;
    final list = <Object?>[];
    skipSpace();
    if (at < text.length && text.codeUnitAt(at) == 0x5D) {
      at++;
      depth--;
      return list;
    }
    while (true) {
      skipSpace();
      list.add(parseValue());
      skipSpace();
      if (at >= text.length) fail('An array is not closed.');
      final unit = text.codeUnitAt(at++);
      if (unit == 0x5D) break;
      if (unit != 0x2C) fail('A comma or closing bracket is missing.');
    }
    depth--;
    return list;
  }

  String parseString() {
    at++;
    final out = StringBuffer();
    while (true) {
      if (at >= text.length) fail('A string is not closed.');
      final unit = text.codeUnitAt(at++);
      if (unit == 0x22) break;
      if (unit < 0x20) fail('A control character is not escaped.');
      if (unit != 0x5C) {
        out.writeCharCode(unit);
        continue;
      }
      if (at >= text.length) fail('An escape is not finished.');
      final escape = text.codeUnitAt(at++);
      switch (escape) {
        case 0x22:
        case 0x5C:
        case 0x2F:
          out.writeCharCode(escape);
        case 0x62:
          out.writeCharCode(0x08);
        case 0x66:
          out.writeCharCode(0x0C);
        case 0x6E:
          out.writeCharCode(0x0A);
        case 0x72:
          out.writeCharCode(0x0D);
        case 0x74:
          out.writeCharCode(0x09);
        case 0x75:
          final first = hex4();
          if (first >= 0xDC00 && first <= 0xDFFF) fail('A low surrogate has no high surrogate before it.');
          if (first >= 0xD800 && first <= 0xDBFF) {
            if (!text.startsWith(r'\u', at)) fail('A high surrogate has no low surrogate after it.');
            at += 2;
            final second = hex4();
            if (second < 0xDC00 || second > 0xDFFF) fail('A high surrogate has no low surrogate after it.');
            out
              ..writeCharCode(first)
              ..writeCharCode(second);
          } else {
            out.writeCharCode(first);
          }
        default:
          fail('Unknown escape.');
      }
    }
    return out.toString();
  }

  int hex4() {
    if (at + 4 > text.length) fail('A \\u escape is too short.');
    final value = int.tryParse(text.substring(at, at + 4), radix: 16);
    if (value == null || text.substring(at, at + 4).contains(RegExp('[^0-9A-Fa-f]'))) fail('A \\u escape is not hex.');
    at += 4;
    return value;
  }

  num parseNumber() {
    final start = at;
    if (text.codeUnitAt(at) == 0x2D) at++;
    if (at >= text.length) fail('A number is not finished.');
    if (text.codeUnitAt(at) == 0x30) {
      at++;
    } else if (isDigit(text.codeUnitAt(at))) {
      while (at < text.length && isDigit(text.codeUnitAt(at))) {
        at++;
      }
    } else {
      fail('A number has no digits.');
    }
    if (at < text.length && text.codeUnitAt(at) == 0x2E) {
      at++;
      if (at >= text.length || !isDigit(text.codeUnitAt(at))) fail('A fraction has no digits.');
      while (at < text.length && isDigit(text.codeUnitAt(at))) {
        at++;
      }
    }
    if (at < text.length && (text.codeUnitAt(at) == 0x65 || text.codeUnitAt(at) == 0x45)) {
      at++;
      if (at < text.length && (text.codeUnitAt(at) == 0x2B || text.codeUnitAt(at) == 0x2D)) at++;
      if (at >= text.length || !isDigit(text.codeUnitAt(at))) fail('An exponent has no digits.');
      while (at < text.length && isDigit(text.codeUnitAt(at))) {
        at++;
      }
    }
    final value = double.parse(text.substring(start, at));
    if (!value.isFinite) fail('A number is not finite as a 64-bit double.');
    if (value == value.truncateToDouble() && value.abs() <= 9007199254740992) return value.toInt();
    return value;
  }

  static bool isDigit(int unit) => unit >= 0x30 && unit <= 0x39;
}
