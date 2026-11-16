import 'dart:convert';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/retro_host/strict_json.dart';
import 'package:test/test.dart';

Map<String, Object?> decode(String text) => StrictJson.decodeObject(Uint8List.fromList(utf8.encode(text)));

Matcher refuses(String part) => throwsA(isA<StrictJsonError>().having((e) => e.message, 'message', contains(part)));

void main() {
  test('reads objects, arrays, strings, literals and numbers', () {
    expect(decode(r'{"a":[1,-2.5,true,false,null],"b":{"c":"d\né😀"}}'), {
      'a': [1, -2.5, true, false, null],
      'b': {'c': 'd\né😀'},
    });
  });

  test('judges integers by value, as protocol.md "Values" says', () {
    final value = decode('{"a":1.0,"b":1e0,"c":4294967295,"d":-0,"e":0.5}');
    expect(value['a'], isA<int>().having((v) => v, 'value', 1));
    expect(value['b'], isA<int>().having((v) => v, 'value', 1));
    expect(value['c'], 4294967295);
    expect(value['d'], isA<int>());
    expect(value['e'], isA<double>());
  });

  test('refuses a key twice in one object, at any depth', () {
    expect(() => decode('{"type":"ping","type":"ping"}'), refuses('appears twice'));
    expect(() => decode('{"a":{"b":1,"b":2}}'), refuses('appears twice'));
    expect(decode('{"a":{"b":1},"c":{"b":2}}'), isNotNull);
  });

  test('refuses lone surrogates in escapes', () {
    expect(() => decode(r'{"a":"\ud800"}'), refuses('no low surrogate'));
    expect(() => decode(r'{"a":"\ud800x"}'), refuses('no low surrogate'));
    expect(() => decode(r'{"a":"\udc00"}'), refuses('no high surrogate'));
    expect(() => decode(r'{"a":"\ud800A"}'), refuses('no low surrogate'));
  });

  test('refuses bodies that are not UTF-8 or not one object', () {
    expect(() => StrictJson.decodeObject(Uint8List.fromList([0x7B, 0xFF, 0x7D])), refuses('UTF-8'));
    expect(() => StrictJson.decodeObject(Uint8List.fromList([0x7B, 0xED, 0xA0, 0x80, 0x7D])), refuses('UTF-8'));
    expect(() => decode('[1]'), refuses('one JSON object'));
    expect(() => decode('{} {}'), refuses('follows'));
    expect(() => decode('{"a":1,}'), throwsA(isA<StrictJsonError>()));
    expect(() => decode('{"a":01}'), throwsA(isA<StrictJsonError>()));
    expect(() => decode('{"a":"\t"}'), refuses('control character'));
  });

  test('refuses numbers that are not finite doubles', () {
    expect(() => decode('{"a":1e400}'), refuses('not finite'));
    expect(() => decode('{"a":-1e400}'), refuses('not finite'));
  });

  test('refuses nesting deeper than the limit instead of exhausting the stack', () {
    final deep = '{"a":${'[' * 100000}${']' * 100000}}';
    expect(() => decode(deep), refuses('nested too deeply'));
  });

  test('finds lone surrogates in values the launcher would send', () {
    expect(StrictJson.hasLoneSurrogate({'disc': 'a\uD800b'}), isTrue);
    expect(StrictJson.hasLoneSurrogate(['ok', 'x\uDC00']), isTrue);
    expect(StrictJson.hasLoneSurrogate({'disc': 'é😀'}), isFalse);
  });
}
