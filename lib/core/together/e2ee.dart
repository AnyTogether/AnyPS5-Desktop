/// End-to-end encryption of direct messages, protocol v1 (AnyTogether's docs/e2ee.md).
///
/// The same steps as the web app's packages/e2ee (noble) and the macOS launcher's CryptoKit
/// code, checked byte for byte against the shared vectors (test/fixtures/e2ee-v1.json). Only
/// package:cryptography does the cryptography: X25519, Ed25519, ChaCha20-Poly1305 (RFC 8439,
/// 12-byte nonce), HKDF-SHA-256 and SHA-256. Nothing here is hand-rolled.
///
/// This file stands alone (dart:convert, dart:math, dart:typed_data and package:cryptography),
/// so the phone app can take it as it is. Everything is async because package:cryptography is.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

const e2eeVersion = 1;
const _tag = 'AnyTogether-E2EE-v1';

final _x25519 = X25519();
final _ed25519 = Ed25519();
final _aead = Chacha20.poly1305Aead();
final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
final _sha256 = Sha256();

/// Why something could not be read: `bad_encoding` (not base64, or the wrong length),
/// `bad_device` (a key that is no key, an all-zero X25519 result), `no_key` (the message was not
/// sealed for this device: it was sent before the device was added), `bad_message` (anything
/// moved, changed or signed by someone else), `bad_payload` (it opened, but says nothing a
/// client understands).
class E2eeError implements Exception {
  const E2eeError(this.code);

  final String code;

  @override
  String toString() => 'E2eeError($code)';
}

// --- encodings -------------------------------------------------------------------------------

final _base64Text = RegExp(r'^[A-Za-z0-9+/]*={0,2}$');

String toBase64(List<int> bytes) => base64.encode(bytes);

/// Standard base64 with padding; anything else (or a wrong [length]) throws bad_encoding.
Uint8List fromBase64(Object? text, [int? length]) {
  if (text is! String || text.length % 4 != 0 || !_base64Text.hasMatch(text)) {
    throw const E2eeError('bad_encoding');
  }
  final Uint8List bytes;
  try {
    bytes = base64.decode(text);
  } on FormatException {
    throw const E2eeError('bad_encoding');
  }
  if (length != null && bytes.length != length) throw const E2eeError('bad_encoding');
  return bytes;
}

String toHex(List<int> bytes) => [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join();

Uint8List fromHex(String hex) {
  if (hex.length.isOdd || !RegExp(r'^[0-9a-fA-F]*$').hasMatch(hex)) throw const E2eeError('bad_encoding');
  return Uint8List.fromList([for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)]);
}

Uint8List _utf8(String text) => Uint8List.fromList(utf8.encode(text));

Uint8List _join(List<List<int>> parts) {
  final out = BytesBuilder(copy: false);
  for (final part in parts) {
    out.add(part);
  }
  return out.toBytes();
}

/// [length] bytes from the system's secure random source.
Uint8List randomBytes(int length, [Random? random]) {
  final source = random ?? Random.secure();
  return Uint8List.fromList(List<int>.generate(length, (_) => source.nextInt(256)));
}

Future<Uint8List> _hash(List<int> bytes) async => Uint8List.fromList((await _sha256.hash(bytes)).bytes);

// --- the primitives, as package:cryptography has them ----------------------------------------

Future<Uint8List> _aeadSeal(List<int> key, List<int> nonce, List<int> aad, List<int> plain) async {
  final box = await _aead.encrypt(plain, secretKey: SecretKey(key), nonce: nonce, aad: aad);
  return box.concatenation(nonce: false);
}

/// Ciphertext and its 16-byte tag in; the plain bytes out, or bad_message.
Future<Uint8List> _aeadOpen(List<int> key, List<int> nonce, List<int> aad, List<int> sealed) async {
  if (sealed.length < 16) throw const E2eeError('bad_message');
  try {
    final box = SecretBox(
      sealed.sublist(0, sealed.length - 16),
      nonce: nonce,
      mac: Mac(sealed.sublist(sealed.length - 16)),
    );
    return Uint8List.fromList(await _aead.decrypt(box, secretKey: SecretKey(key), aad: aad));
  } on SecretBoxAuthenticationError {
    throw const E2eeError('bad_message');
  } on ArgumentError {
    throw const E2eeError('bad_message');
  }
}

Future<Uint8List> _sign(List<int> seed, List<int> message) async {
  final pair = await _ed25519.newKeyPairFromSeed(seed);
  return Uint8List.fromList((await _ed25519.sign(message, keyPair: pair)).bytes);
}

Future<bool> _verify(List<int> signKey, List<int> message, List<int> signature) async {
  if (signKey.length != 32 || signature.length != 64) return false;
  try {
    return await _ed25519.verify(
      message,
      signature: Signature(signature, publicKey: SimplePublicKey(signKey, type: KeyPairType.ed25519)),
    );
  } on Object {
    return false;
  }
}

Future<Uint8List> _x25519Public(List<int> secret) async {
  final pair = await _x25519.newKeyPairFromSeed(secret);
  return Uint8List.fromList((await pair.extractPublicKey()).bytes);
}

/// HKDF-SHA-256 over X25519([secret], [peer]), salted with the message's ephemeral key and the
/// recipient's key. An all-zero X25519 result (a low-order key) is refused.
Future<Uint8List> _wrapKey(List<int> secret, List<int> peer, List<int> eph, List<int> recipient) async {
  final List<int> shared;
  try {
    final pair = await _x25519.newKeyPairFromSeed(secret);
    final key = await _x25519.sharedSecretKey(
      keyPair: pair,
      remotePublicKey: SimplePublicKey(peer, type: KeyPairType.x25519),
    );
    shared = await key.extractBytes();
  } on ArgumentError {
    throw const E2eeError('bad_device');
  }
  if (shared.every((b) => b == 0)) throw const E2eeError('bad_device');
  final derived = await _hkdf.deriveKey(
    secretKey: SecretKey(shared),
    nonce: _join([eph, recipient]),
    info: _utf8('$_tag/wrap'),
  );
  return Uint8List.fromList(await derived.extractBytes());
}

// --- devices ---------------------------------------------------------------------------------

/// The first 16 bytes of SHA-256(signKey), lowercase hex.
Future<String> deviceIdOf(List<int> signKey) async => toHex((await _hash(signKey)).sublist(0, 16));

/// What one device keeps and never sends: its Ed25519 seed and its X25519 secret, with the
/// public keys and the device ID they give.
class DeviceSecrets {
  const DeviceSecrets._({
    required this.signSeed,
    required this.boxSecret,
    required this.signKey,
    required this.boxKey,
    required this.deviceId,
  });

  final Uint8List signSeed;
  final Uint8List boxSecret;
  final Uint8List signKey;
  final Uint8List boxKey;
  final String deviceId;

  static Future<DeviceSecrets> fromSeeds(List<int> signSeed, List<int> boxSecret) async {
    if (signSeed.length != 32 || boxSecret.length != 32) throw const E2eeError('bad_device');
    final pair = await _ed25519.newKeyPairFromSeed(signSeed);
    final signKey = Uint8List.fromList((await pair.extractPublicKey()).bytes);
    return DeviceSecrets._(
      signSeed: Uint8List.fromList(signSeed),
      boxSecret: Uint8List.fromList(boxSecret),
      signKey: signKey,
      boxKey: await _x25519Public(boxSecret),
      deviceId: await deviceIdOf(signKey),
    );
  }

  /// A new device: both secrets from the secure random source.
  static Future<DeviceSecrets> generate([Random? random]) =>
      fromSeeds(randomBytes(32, random), randomBytes(32, random));

  /// The secrets as the device keeps them (in its secret store, never sent).
  Map<String, Object> toJson() => {'v': e2eeVersion, 'signSeed': toBase64(signSeed), 'boxSecret': toBase64(boxSecret)};

  /// From what [toJson] kept; null for anything else.
  static Future<DeviceSecrets?> fromJson(Object? json) async {
    if (json is! Map || json['v'] != e2eeVersion) return null;
    try {
      return await fromSeeds(fromBase64(json['signSeed'], 32), fromBase64(json['boxSecret'], 32));
    } on E2eeError {
      return null;
    }
  }
}

/// What kind of device a device key is on, read from the name its app registered (docs/e2ee.md
/// in AnyTogether). Lists show this, never the name: older launchers registered the computer's
/// own name, which often holds a person's name.
enum DeviceKind { windows, mac, linux, iphone, ipad, android, browser, device }

/// The same reading as deviceKindOf in AnyTogether's packages/e2ee, so the server's names for
/// other people's devices ("Windows PC", "iPhone") keep their kind.
DeviceKind deviceKindOf(String name) {
  final n = name.toLowerCase();
  bool has(String pattern) => RegExp(pattern).hasMatch(n);
  if (has(r'chrome|firefox|safari|\bedge\b|opera|browser')) return DeviceKind.browser;
  if (has(r'iphone|\bios\b')) return DeviceKind.iphone;
  if (has(r'ipad')) return DeviceKind.ipad;
  if (has(r'android|pixel|galaxy|samsung|oneplus|xiaomi|redmi|huawei')) return DeviceKind.android;
  if (has(r'\bmac\b|macbook|imac|mac ?mini|mac ?studio|mac ?pro|macos')) return DeviceKind.mac;
  if (has(r'linux|ubuntu|fedora|debian|\barch\b|steam ?deck|steamos')) return DeviceKind.linux;
  if (has(r'windows|\bpc\b|^desktop-|^laptop-')) return DeviceKind.windows;
  return DeviceKind.device;
}

/// A device as the server lists it: public keys and the device's signature over them.
class PublicDevice {
  const PublicDevice({
    required this.id,
    required this.signKey,
    required this.boxKey,
    required this.sig,
    this.name = '',
    this.removed = false,
    this.createdAt,
  });

  /// From an E2eeDeviceView; null when a field is missing or not a text.
  static PublicDevice? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final signKey = json['signKey'];
    final boxKey = json['boxKey'];
    final sig = json['sig'];
    if (id is! String || signKey is! String || boxKey is! String || sig is! String) return null;
    return PublicDevice(
      id: id,
      signKey: signKey,
      boxKey: boxKey,
      sig: sig,
      name: json['name'] is String ? json['name'] as String : '',
      removed: json['removedAt'] != null,
      createdAt: json['createdAt'] is String ? DateTime.tryParse(json['createdAt'] as String) : null,
    );
  }

  final String id;
  final String signKey;
  final String boxKey;
  final String sig;
  final String name;
  final bool removed;

  /// When it was added; null from a list without it.
  final DateTime? createdAt;

  DeviceKind get kind => deviceKindOf(name);

  /// What PUT /me/e2ee/device takes.
  Map<String, String> toRegister(String name) => {'signKey': signKey, 'boxKey': boxKey, 'sig': sig, 'name': name};
}

Uint8List _deviceStatement(String userId, List<int> boxKey) => _join([_utf8('$_tag/device\n$userId\n'), boxKey]);

/// The device's public record for [userId], as PUT /me/e2ee/device takes it.
Future<PublicDevice> publicDevice(DeviceSecrets device, String userId) async => PublicDevice(
  id: device.deviceId,
  signKey: toBase64(device.signKey),
  boxKey: toBase64(device.boxKey),
  sig: toBase64(await _sign(device.signSeed, _deviceStatement(userId, device.boxKey))),
);

/// A listed device belongs to [userId] as far as its keys can tell: its ID is its signing
/// key's, and its signature over its X25519 key and the user ID holds.
Future<bool> verifyDevice(String userId, PublicDevice device) async {
  try {
    final signKey = fromBase64(device.signKey, 32);
    final boxKey = fromBase64(device.boxKey, 32);
    if (await deviceIdOf(signKey) != device.id) return false;
    return await _verify(signKey, _deviceStatement(userId, boxKey), fromBase64(device.sig, 64));
  } on E2eeError {
    return false;
  }
}

// --- messages --------------------------------------------------------------------------------

/// A message's encrypted form, as the API stores and returns it.
class SealedMessage {
  const SealedMessage({
    required this.device,
    required this.eph,
    required this.nonce,
    required this.body,
    required this.sig,
    required this.keys,
    this.v = e2eeVersion,
  });

  /// null for anything that is not one.
  static SealedMessage? fromJson(Object? json) {
    if (json is! Map) return null;
    final keys = json['keys'];
    final fields = [json['device'], json['eph'], json['nonce'], json['body'], json['sig']];
    if (fields.any((f) => f is! String) || keys is! Map || json['v'] is! num) return null;
    final wrapped = <String, String>{};
    for (final entry in keys.entries) {
      if (entry.key is! String || entry.value is! String) return null;
      wrapped[entry.key as String] = entry.value as String;
    }
    return SealedMessage(
      v: (json['v'] as num).toInt(),
      device: fields[0] as String,
      eph: fields[1] as String,
      nonce: fields[2] as String,
      body: fields[3] as String,
      sig: fields[4] as String,
      keys: wrapped,
    );
  }

  final int v;

  /// The sending device's ID.
  final String device;

  /// The message's ephemeral X25519 public key.
  final String eph;
  final String nonce;
  final String body;
  final String sig;

  /// The content key, wrapped for each device of both people, by device ID.
  final Map<String, String> keys;

  Map<String, Object> toJson() => {
    'v': v,
    'device': device,
    'eph': eph,
    'nonce': nonce,
    'body': body,
    'sig': sig,
    'keys': keys,
  };
}

/// A clip's still, sealed with its own key.
class SealedPoster {
  const SealedPoster({required this.key, required this.nonce, required this.type});

  final String key;
  final String nonce;
  final String type;

  Map<String, Object> toJson() => {'key': key, 'nonce': nonce, 'type': type};
}

/// A photo, clip or voice note in a sealed message: where it is and how to open it.
class SealedAttachment {
  const SealedAttachment({
    required this.mediaId,
    required this.kind,
    required this.type,
    required this.size,
    required this.key,
    required this.nonce,
    this.width,
    this.height,
    this.durationMs,
    this.poster,
  });

  static const kinds = ['image', 'clip', 'voice'];

  final String mediaId;

  /// image, clip or voice.
  final String kind;

  /// The plain file's media type (image/png, video/mp4, audio/ogg).
  final String type;
  final int size;
  final String key;
  final String nonce;
  final int? width;
  final int? height;
  final int? durationMs;
  final SealedPoster? poster;

  /// In the order every client writes it.
  Map<String, Object> toJson() => {
    'mediaId': mediaId,
    'kind': kind,
    'type': type,
    'size': size,
    'key': key,
    'nonce': nonce,
    'width': ?width,
    'height': ?height,
    'durationMs': ?durationMs,
    if (poster != null) 'poster': poster!.toJson(),
  };

  static SealedAttachment? _fromJson(Object? json) {
    if (json is! Map) return null;
    final mediaId = json['mediaId'];
    final kind = json['kind'];
    final key = json['key'];
    final nonce = json['nonce'];
    final type = json['type'];
    if (mediaId is! String || !kinds.contains(kind) || key is! String || nonce is! String || type is! String) {
      return null;
    }
    int? number(Object? value) => value is num ? value.toInt() : null;
    final poster = json['poster'];
    SealedPoster? still;
    if (poster != null) {
      if (poster is! Map || poster['key'] is! String || poster['nonce'] is! String || poster['type'] is! String) {
        return null;
      }
      still = SealedPoster(
        key: poster['key'] as String,
        nonce: poster['nonce'] as String,
        type: poster['type'] as String,
      );
    }
    return SealedAttachment(
      mediaId: mediaId,
      kind: kind as String,
      type: type,
      size: number(json['size']) ?? 0,
      key: key,
      nonce: nonce,
      width: number(json['width']),
      height: number(json['height']),
      durationMs: number(json['durationMs']),
      poster: still,
    );
  }
}

/// What a sealed message says: its text (a caption with an attachment) and/or an attachment.
class E2eePayload {
  const E2eePayload({this.text, this.attachment});

  final String? text;
  final SealedAttachment? attachment;

  Map<String, Object> toJson() => {
    'v': e2eeVersion,
    'text': ?text,
    if (attachment != null) 'attachment': attachment!.toJson(),
  };

  Uint8List encode() => _utf8(jsonEncode(toJson()));

  /// The opened bytes read: bad_payload for anything that is not a v1 payload.
  static E2eePayload parse(List<int> bytes) {
    Object? value;
    try {
      value = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw const E2eeError('bad_payload');
    }
    if (value is! Map || value['v'] != e2eeVersion) throw const E2eeError('bad_payload');
    final text = value['text'];
    if (text != null && text is! String) throw const E2eeError('bad_payload');
    SealedAttachment? attachment;
    if (value['attachment'] != null) {
      attachment = SealedAttachment._fromJson(value['attachment']);
      if (attachment == null) throw const E2eeError('bad_payload');
    }
    return E2eePayload(text: text as String?, attachment: attachment);
  }
}

/// Fixed randomness, for the test vectors only.
class SealRandom {
  const SealRandom({required this.contentKey, required this.nonce, required this.ephSecret});

  final List<int> contentKey;
  final List<int> nonce;
  final List<int> ephSecret;
}

/// A message sealed: what is sent, and its content key (kept to report it).
class Sealed {
  const Sealed(this.sealed, this.contentKey);

  final SealedMessage sealed;
  final Uint8List contentKey;
}

/// A message opened: what it says, and its content key (a report sends it).
class Opened {
  const Opened(this.payload, this.contentKey);

  final E2eePayload payload;
  final Uint8List contentKey;
}

Uint8List _header(String conversationId, String messageId, String senderUserId, String senderDeviceId) =>
    _utf8('$_tag/msg\n$conversationId\n$messageId\n$senderUserId\n$senderDeviceId');

Future<Uint8List> _signed(List<int> head, List<int> eph, List<int> nonce, List<int> body) async => _join([
  head,
  const [0],
  eph,
  nonce,
  await _hash(body),
]);

final _zeroNonce = Uint8List(12);

/// Encrypts [payload] once and wraps its key for each of [recipients] (every active device of
/// both people, the sender's own devices and the sending one among them). [payloadBytes]
/// overrides the JSON and [random] the randomness, so the vectors can fix them byte for byte.
Future<Sealed> seal({
  required String conversationId,
  required String messageId,
  required String senderUserId,
  required DeviceSecrets sender,
  required List<PublicDevice> recipients,
  E2eePayload? payload,
  List<int>? payloadBytes,
  SealRandom? random,
}) async {
  final head = _header(conversationId, messageId, senderUserId, sender.deviceId);
  final contentKey = Uint8List.fromList(random?.contentKey ?? randomBytes(32));
  final nonce = Uint8List.fromList(random?.nonce ?? randomBytes(12));
  final ephSecret = random?.ephSecret ?? randomBytes(32);
  if (contentKey.length != 32 || nonce.length != 12 || ephSecret.length != 32) throw const E2eeError('bad_encoding');
  final eph = await _x25519Public(ephSecret);
  final plain = payloadBytes ?? (payload ?? const E2eePayload()).encode();
  final body = await _aeadSeal(contentKey, nonce, head, plain);
  final keys = <String, String>{};
  for (final recipient in recipients) {
    final boxKey = fromBase64(recipient.boxKey, 32);
    final wrapKey = await _wrapKey(ephSecret, boxKey, eph, boxKey);
    final aad = _join([head, _utf8('\n${recipient.id}')]);
    keys[recipient.id] = toBase64(await _aeadSeal(wrapKey, _zeroNonce, aad, contentKey));
  }
  final sig = await _sign(sender.signSeed, await _signed(head, eph, nonce, body));
  return Sealed(
    SealedMessage(
      device: sender.deviceId,
      eph: toBase64(eph),
      nonce: toBase64(nonce),
      body: toBase64(body),
      sig: toBase64(sig),
      keys: keys,
    ),
    contentKey,
  );
}

/// The content key of a sealed message, unwrapped with this device's key: no_key when it was
/// not sealed for this device (sent before the device was added), bad_message otherwise.
Future<Uint8List> unwrapKey(
  SealedMessage sealed, {
  required String conversationId,
  required String messageId,
  required String senderUserId,
  required DeviceSecrets me,
}) async {
  final wrapped = sealed.keys[me.deviceId];
  if (wrapped == null) throw const E2eeError('no_key');
  try {
    final eph = fromBase64(sealed.eph, 32);
    final wrapKey = await _wrapKey(me.boxSecret, eph, eph, me.boxKey);
    final aad = _join([_header(conversationId, messageId, senderUserId, sealed.device), _utf8('\n${me.deviceId}')]);
    return await _aeadOpen(wrapKey, _zeroNonce, aad, fromBase64(wrapped, 48));
  } on E2eeError {
    throw const E2eeError('bad_message');
  }
}

/// Decrypts a sealed message with its content key and checks the author device's signature
/// (the server does this for a report, with the key the reporter sent).
Future<E2eePayload> openWithKey(
  SealedMessage sealed, {
  required String conversationId,
  required String messageId,
  required String senderUserId,
  required List<int> contentKey,
  required String authorSignKey,
}) async {
  final Uint8List plain;
  try {
    if (sealed.v != e2eeVersion || contentKey.length != 32) throw const E2eeError('bad_message');
    final head = _header(conversationId, messageId, senderUserId, sealed.device);
    final eph = fromBase64(sealed.eph, 32);
    final nonce = fromBase64(sealed.nonce, 12);
    final body = fromBase64(sealed.body);
    final signKey = fromBase64(authorSignKey, 32);
    if (await deviceIdOf(signKey) != sealed.device) throw const E2eeError('bad_message');
    if (!await _verify(signKey, await _signed(head, eph, nonce, body), fromBase64(sealed.sig, 64))) {
      throw const E2eeError('bad_message');
    }
    plain = await _aeadOpen(contentKey, nonce, head, body);
  } on E2eeError {
    throw const E2eeError('bad_message');
  }
  return E2eePayload.parse(plain);
}

/// A sealed message as this device reads it. [authorDevices] are the author's devices, active
/// and removed, each already checked with [verifyDevice].
Future<Opened> open(
  SealedMessage sealed, {
  required String conversationId,
  required String messageId,
  required String authorId,
  required DeviceSecrets me,
  required List<PublicDevice> authorDevices,
}) async {
  final contentKey = await unwrapKey(
    sealed,
    conversationId: conversationId,
    messageId: messageId,
    senderUserId: authorId,
    me: me,
  );
  final author = authorDevices.where((d) => d.id == sealed.device).firstOrNull;
  if (author == null) throw const E2eeError('bad_message');
  final payload = await openWithKey(
    sealed,
    conversationId: conversationId,
    messageId: messageId,
    senderUserId: authorId,
    contentKey: contentKey,
    authorSignKey: author.signKey,
  );
  return Opened(payload, contentKey);
}

// --- attachments -----------------------------------------------------------------------------

/// What a sealed file is: the attachment itself, or a clip's poster.
enum FilePart { file, poster }

/// A file sealed: the ciphertext to upload, and the key and nonce the payload carries.
class SealedFile {
  const SealedFile(this.ciphertext, this.key, this.nonce);

  final Uint8List ciphertext;
  final String key;
  final String nonce;
}

/// A photo, clip, voice note or poster, encrypted with a key of its own before it is uploaded.
Future<SealedFile> sealFile(List<int> bytes, FilePart part, {List<int>? key, List<int>? nonce}) async {
  final k = key ?? randomBytes(32);
  final n = nonce ?? randomBytes(12);
  if (k.length != 32 || n.length != 12) throw const E2eeError('bad_encoding');
  final ciphertext = await _aeadSeal(k, n, _utf8('$_tag/${part.name}'), bytes);
  return SealedFile(ciphertext, toBase64(k), toBase64(n));
}

/// The plain file, or bad_message (another key, another part, anything changed).
Future<Uint8List> openFile(List<int> ciphertext, FilePart part, String key, String nonce) async {
  try {
    return await _aeadOpen(fromBase64(key, 32), fromBase64(nonce, 12), _utf8('$_tag/${part.name}'), ciphertext);
  } on E2eeError {
    throw const E2eeError('bad_message');
  }
}

// --- safety number ---------------------------------------------------------------------------

Future<String> _personDigits(String userId, List<String> signKeys) async {
  final hex = [for (final key in signKeys) toHex(fromBase64(key, 32))]..sort();
  final digest = await _hash(_utf8('$_tag/safety\n$userId\n${hex.join(',')}'));
  final digits = StringBuffer();
  for (var i = 0; i < 30; i += 5) {
    var n = 0;
    for (var j = 0; j < 5; j++) {
      n = n * 256 + digest[i + j];
    }
    digits.write((n % 100000).toString().padLeft(5, '0'));
  }
  return digits.toString();
}

/// The 60 digits both people see, the smaller user ID's half first; null while either person
/// has no device. [aKeys] and [bKeys] are each person's active devices' signing keys (base64).
Future<String?> safetyNumber(String aUser, List<String> aKeys, String bUser, List<String> bKeys) async {
  if (aKeys.isEmpty || bKeys.isEmpty) return null;
  final aFirst = aUser.compareTo(bUser) < 0;
  final first = aFirst ? (aUser, aKeys) : (bUser, bKeys);
  final second = aFirst ? (bUser, bKeys) : (aUser, aKeys);
  return await _personDigits(first.$1, first.$2) + await _personDigits(second.$1, second.$2);
}

/// Twelve groups of five.
List<String> safetyGroups(String digits) => [
  for (var i = 0; i + 5 <= digits.length; i += 5) digits.substring(i, i + 5),
];
