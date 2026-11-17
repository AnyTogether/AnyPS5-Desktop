import 'dart:convert';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/release_signing.dart';
import 'package:crypto/crypto.dart';
import 'package:pinenacl/ed25519.dart' as nacl;

import 'fake_github.dart';

/// A throwaway release key for tests, made from [seed].
class TestReleaseKey {
  TestReleaseKey(String seed, {this.name = 'test'})
    : signing = nacl.SigningKey.fromSeed(Uint8List.fromList(sha256.convert(utf8.encode(seed)).bytes));

  /// The key in [pem], as `openssl genpkey -algorithm ed25519` writes it (PKCS#8, whose last 32
  /// bytes are the seed); text before the PEM block is skipped, as OpenSSL skips it.
  factory TestReleaseKey.fromPem(String pem, {String name = 'test'}) {
    final body = RegExp(r'-----BEGIN PRIVATE KEY-----([A-Za-z0-9+/=\s]+)-----END PRIVATE KEY-----').firstMatch(pem);
    if (body == null) throw const FormatException('no PKCS#8 private key');
    final der = base64.decode(body.group(1)!.replaceAll(RegExp(r'\s'), ''));
    if (der.length != 48) throw const FormatException('not an Ed25519 private key');
    return TestReleaseKey._(nacl.SigningKey.fromSeed(Uint8List.fromList(der.sublist(16))), name);
  }

  TestReleaseKey._(this.signing, this.name);

  final nacl.SigningKey signing;
  final String name;

  ReleaseKey get key => ReleaseKey.of(name, signing.verifyKey.asTypedList)!;

  /// A SHA256SUMS.sig line: this key's signature of [sums].
  String signatureLine(List<int> sums) =>
      'ed25519 ${key.id} ${base64.encode(signing.sign(Uint8List.fromList(sums)).signature.asTypedList)}';
}

/// SHA256SUMS of [files] as tools/release/sign.sh writes it.
List<int> sumsOf(Map<String, List<int>> files) {
  final names = files.keys.toList()..sort();
  return utf8.encode(names.map((name) => '${sha256.convert(files[name]!)}  $name\n').join());
}

/// Adds SHA256SUMS and SHA256SUMS.sig (signed by [keys]) to [release], as sign.sh does.
FakeRelease signed(FakeRelease release, List<TestReleaseKey> keys) {
  final sums = sumsOf(release.files);
  release.files['SHA256SUMS'] = sums;
  release.files['SHA256SUMS.sig'] = utf8.encode(keys.map((key) => '${key.signatureLine(sums)}\n').join());
  return release;
}

/// What tools/release/sign.sh (OpenSSL) wrote for throwaway keys; the macOS launcher's
/// ReleaseSigningTests check the same.
abstract final class SignShFixture {
  static const current = 'kROA0TId0RtgYOojGyrCoDWfPv4zC6lbwYEhy4ATi88=';
  static const next = 'eKk4w/0mBtLssFqKbHTbxDiHjsDzGqWjv7HtyQu8hs4=';
  static const stray = 'wVmRvxWgPu5CoiT02zTCcKvSai4tFo107xYNRLEMb0w=';
  static final app = utf8.encode('AnyPS5 0.2.17\n');
  static final toolkit = utf8.encode('toolkit\n');
  static final sums = utf8.encode(
    '8c4f364e8a663e1affcb5020608c70ef48b9582fc3fa123f5c89fcb8888ed4ec  AnyPS5-macOS.zip\n'
    '61061033c4741ae85f12fc0ddd9b8a0d19660b551f33d8ef1e098b1ff7b15584  AnyPS5-toolkit-macos-0.2.17-arm.zip\n',
  );
  static const byCurrent =
      'ed25519 c7095b742ad5c7a1 S6W2AwDD9sBnWySE1ThvR3AK7b/iyy5v/5loaR2EyBvpV+AYfKvhFEh1aG34Hg0y/cm9JbGVzmTPIJWNobsaAw==';
  static const byNext =
      'ed25519 a8e2582b8f333670 9S+4Oviq0bbehR1JXDwU6HZg0U8F3Mr8R99r69O42d08GOgujiHQyk4WjS5xgHEbaaOoULxML56ku9lrRvC0Aw==';
  static const byStray =
      'ed25519 f91ae443c133eeec fvCHYI/l42E8NgUHU6hau5F7Kk6mBzLiirAPnt2Z1p6Ii3RkM8gGhDyB6wmkgiL3KfiRrQzEcZMrjyUdEjuHBw==';

  static List<ReleaseKey> keys(List<String> lines) => [
    for (final (index, line) in lines.indexed) ReleaseKey.parse('ed25519 $line key$index')!,
  ];
}
