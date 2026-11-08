import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/together/e2ee.dart';
import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';

/// End-to-end encryption, protocol v1, against the vectors every client shares
/// (test/fixtures/e2ee-v1.json, from AnyTogether's packages/e2ee): the RFC answers for
/// package:cryptography, each vector device from its seeds, both vector messages opened on all
/// three devices and sealed again byte for byte, the files, the safety number; then everything
/// that must be refused.
void main() {
  final vectors = jsonDecode(File('test/fixtures/e2ee-v1.json').readAsStringSync()) as Map<String, dynamic>;
  final conversationId = vectors['conversationId'] as String;
  final users = (vectors['users'] as Map).cast<String, String>();
  final deviceJson = (vectors['devices'] as Map).cast<String, Map<String, dynamic>>();
  final messages = (vectors['messages'] as List).cast<Map<String, dynamic>>();

  Future<String> code(Future<Object?> Function() run) async {
    try {
      await run();
    } on E2eeError catch (error) {
      return error.code;
    } on Object catch (error) {
      return 'other: $error';
    }
    return 'none';
  }

  PublicDevice publicOf(String name) => PublicDevice.fromJson(deviceJson[name]!['public'])!;
  Future<DeviceSecrets> secretsOf(String name) => DeviceSecrets.fromSeeds(
    fromHex(deviceJson[name]!['signSeed'] as String),
    fromHex(deviceJson[name]!['boxSecret'] as String),
  );
  List<PublicDevice> devicesOf(String userId) => [
    for (final entry in deviceJson.entries)
      if (entry.value['userId'] == userId) publicOf(entry.key),
  ];

  group('the RFC answers, for package:cryptography', () {
    final rfc = vectors['rfc'] as Map<String, dynamic>;

    test('X25519 (RFC 7748 6.1)', () async {
      final x = rfc['x25519'] as Map<String, dynamic>;
      final pair = await X25519().newKeyPairFromSeed(fromHex(x['aliceSecretHex'] as String));
      expect(toHex((await pair.extractPublicKey()).bytes), x['alicePublicHex']);
      final shared = await X25519().sharedSecretKey(
        keyPair: pair,
        remotePublicKey: SimplePublicKey(fromHex(x['bobPublicHex'] as String), type: KeyPairType.x25519),
      );
      expect(toHex(await shared.extractBytes()), x['sharedHex']);
    });

    test('Ed25519 (RFC 8032 7.1, test 1)', () async {
      final e = rfc['ed25519'] as Map<String, dynamic>;
      final pair = await Ed25519().newKeyPairFromSeed(fromHex(e['seedHex'] as String));
      expect(toHex((await pair.extractPublicKey()).bytes), e['publicHex']);
      final signature = await Ed25519().sign(fromHex(e['messageHex'] as String), keyPair: pair);
      expect(toHex(signature.bytes), e['signatureHex']);
    });

    test('ChaCha20-Poly1305 (RFC 8439 2.8.2)', () async {
      final c = rfc['chacha20poly1305'] as Map<String, dynamic>;
      final box = await Chacha20.poly1305Aead().encrypt(
        utf8.encode(c['plaintext'] as String),
        secretKey: SecretKey(fromHex(c['keyHex'] as String)),
        nonce: fromHex(c['nonceHex'] as String),
        aad: fromHex(c['aadHex'] as String),
      );
      expect(toHex(box.cipherText), c['ciphertextHex']);
      expect(toHex(box.mac.bytes), c['tagHex']);
    });
  });

  group('the vector devices', () {
    test('come out of their seeds with the same keys, IDs and signatures', () async {
      for (final name in deviceJson.keys) {
        final secrets = await secretsOf(name);
        final listed = publicOf(name);
        final userId = deviceJson[name]!['userId'] as String;
        expect(secrets.deviceId, listed.id, reason: name);
        expect(toBase64(secrets.signKey), listed.signKey, reason: name);
        expect(toBase64(secrets.boxKey), listed.boxKey, reason: name);
        final made = await publicDevice(secrets, userId);
        expect(made.sig, listed.sig, reason: '$name: Ed25519 is deterministic, so the signature is the same');
        expect(await verifyDevice(userId, listed), isTrue, reason: name);
      }
    });

    test('verify for their own user only, and not when anything is swapped', () async {
      final mac = publicOf('aliceMac');
      PublicDevice changed({String? id, String? signKey, String? boxKey, String? sig}) => PublicDevice(
        id: id ?? mac.id,
        signKey: signKey ?? mac.signKey,
        boxKey: boxKey ?? mac.boxKey,
        sig: sig ?? mac.sig,
      );
      expect(await verifyDevice(users['bob']!, mac), isFalse);
      expect(await verifyDevice(users['alice']!, changed(id: '0' * 32)), isFalse);
      expect(await verifyDevice(users['alice']!, changed(boxKey: publicOf('alicePhone').boxKey)), isFalse);
      expect(await verifyDevice(users['alice']!, changed(signKey: publicOf('alicePhone').signKey)), isFalse);
      expect(await verifyDevice(users['alice']!, changed(sig: publicOf('alicePhone').sig)), isFalse);
      expect(await verifyDevice(users['alice']!, changed(sig: 'nope')), isFalse);
    });

    test('keep their secrets in a form that comes back as the same device', () async {
      final secrets = await secretsOf('bobDesktop');
      final again = await DeviceSecrets.fromJson(jsonDecode(jsonEncode(secrets.toJson())));
      expect(again!.deviceId, secrets.deviceId);
      expect(again.boxKey, secrets.boxKey);
      expect(await DeviceSecrets.fromJson({'v': 2, 'signSeed': '', 'boxSecret': ''}), isNull);
      expect(await DeviceSecrets.fromJson('nope'), isNull);
    });
  });

  group('the vector messages', () {
    test('open on every device, with the content key they were sealed with and a good signature', () async {
      for (final message in messages) {
        final sealed = SealedMessage.fromJson(message['sealed'])!;
        final random = message['random'] as Map<String, dynamic>;
        for (final name in deviceJson.keys) {
          final opened = await open(
            sealed,
            conversationId: conversationId,
            messageId: message['messageId'] as String,
            authorId: message['authorId'] as String,
            me: await secretsOf(name),
            authorDevices: devicesOf(message['authorId'] as String),
          );
          expect(toBase64(opened.contentKey), random['contentKey'], reason: '${message['name']} on $name');
          expect(
            utf8.decode(opened.payload.encode()),
            message['payload'],
            reason: '${message['name']} on $name: read and written again, the same JSON',
          );
        }
      }
    });

    test('read what they say', () async {
      final clip = messages[1];
      final opened = await open(
        SealedMessage.fromJson(clip['sealed'])!,
        conversationId: conversationId,
        messageId: clip['messageId'] as String,
        authorId: clip['authorId'] as String,
        me: await secretsOf('aliceMac'),
        authorDevices: devicesOf(users['bob']!),
      );
      expect(opened.payload.text, 'a caption');
      final attachment = opened.payload.attachment!;
      expect(attachment.kind, 'clip');
      expect(attachment.mediaId, '0190f1a2-0000-7000-8000-00000000f11e');
      expect(attachment.durationMs, 4200);
      expect([attachment.width, attachment.height], [1280, 720]);
      expect(attachment.poster!.type, 'image/jpeg');
    });

    test('seal again byte for byte with their randomness: body, keys and signature', () async {
      for (final message in messages) {
        final random = message['random'] as Map<String, dynamic>;
        final author = message['authorId'] == users['alice'] ? 'aliceMac' : 'bobDesktop';
        final again = await seal(
          conversationId: conversationId,
          messageId: message['messageId'] as String,
          senderUserId: message['authorId'] as String,
          sender: await secretsOf(author),
          recipients: [for (final name in deviceJson.keys) publicOf(name)],
          payloadBytes: utf8.encode(message['payload'] as String),
          random: SealRandom(
            contentKey: fromBase64(random['contentKey']),
            nonce: fromBase64(random['nonce']),
            ephSecret: fromBase64(random['ephSecret']),
          ),
        );
        expect(again.sealed.toJson(), message['sealed'], reason: message['name'] as String);
        expect(toBase64(again.contentKey), random['contentKey']);
        // The payload as this code writes it is the vector's, byte for byte.
        final payload = E2eePayload.parse(utf8.encode(message['payload'] as String));
        final fromObject = await seal(
          conversationId: conversationId,
          messageId: message['messageId'] as String,
          senderUserId: message['authorId'] as String,
          sender: await secretsOf(author),
          recipients: [for (final name in deviceJson.keys) publicOf(name)],
          payload: payload,
          random: SealRandom(
            contentKey: fromBase64(random['contentKey']),
            nonce: fromBase64(random['nonce']),
            ephSecret: fromBase64(random['ephSecret']),
          ),
        );
        expect(fromObject.sealed.body, (message['sealed'] as Map)['body']);
      }
    });
  });

  test('the vector files open, and seal again byte for byte', () async {
    for (final file in (vectors['files'] as List).cast<Map<String, dynamic>>()) {
      final part = FilePart.values.byName(file['part'] as String);
      final plain = await openFile(
        fromBase64(file['ciphertext']),
        part,
        file['key'] as String,
        file['nonce'] as String,
      );
      expect(toBase64(plain), file['plaintext']);
      final again = await sealFile(
        fromBase64(file['plaintext']),
        part,
        key: fromBase64(file['key']),
        nonce: fromBase64(file['nonce']),
      );
      expect(toBase64(again.ciphertext), file['ciphertext']);
    }
  });

  group('the safety number', () {
    final safety = vectors['safetyNumber'] as Map<String, dynamic>;
    final alice = (safety['alice'] as List).cast<String>();
    final bob = (safety['bob'] as List).cast<String>();

    test('is the vector one, the same from both sides and in any order of devices', () async {
      final digits = await safetyNumber(users['alice']!, alice, users['bob']!, bob);
      expect(digits, safety['digits']);
      expect(await safetyNumber(users['bob']!, bob, users['alice']!, alice), safety['digits']);
      expect(await safetyNumber(users['alice']!, alice.reversed.toList(), users['bob']!, bob), safety['digits']);
      final groups = safetyGroups(digits!);
      expect(groups, hasLength(12));
      expect(groups.every((g) => RegExp(r'^\d{5}$').hasMatch(g)), isTrue);
    });

    test('changes with a device, and is not there without devices', () async {
      expect(await safetyNumber(users['alice']!, alice.sublist(1), users['bob']!, bob), isNot(safety['digits']));
      expect(await safetyNumber(users['alice']!, alice, users['bob']!, const []), isNull);
    });
  });

  group('a message sealed here', () {
    late DeviceSecrets mac;
    late DeviceSecrets phone;
    late DeviceSecrets desktop;
    late DeviceSecrets later;
    late Map<String, PublicDevice> listed;
    late Sealed sent;
    const messageId = '0190f1a2-0000-7000-8000-0000000000aa';

    setUpAll(() async {
      mac = await DeviceSecrets.generate();
      phone = await DeviceSecrets.generate();
      desktop = await DeviceSecrets.generate();
      later = await DeviceSecrets.generate();
      listed = {
        'mac': await publicDevice(mac, users['alice']!),
        'phone': await publicDevice(phone, users['alice']!),
        'desktop': await publicDevice(desktop, users['bob']!),
      };
      sent = await seal(
        conversationId: conversationId,
        messageId: messageId,
        senderUserId: users['alice']!,
        sender: mac,
        recipients: listed.values.toList(),
        payload: const E2eePayload(text: 'GG 🔥'),
      );
    });

    Future<Opened> openAs(
      DeviceSecrets me, {
      SealedMessage? sealed,
      String? conversation,
      String? message,
      String? author,
      List<PublicDevice>? authors,
    }) => open(
      sealed ?? sent.sealed,
      conversationId: conversation ?? conversationId,
      messageId: message ?? messageId,
      authorId: author ?? users['alice']!,
      me: me,
      authorDevices: authors ?? [listed['mac']!, listed['phone']!],
    );

    SealedMessage changed({String? body, String? sig, String? nonce, String? eph, Map<String, String>? keys}) =>
        SealedMessage(
          device: sent.sealed.device,
          eph: eph ?? sent.sealed.eph,
          nonce: nonce ?? sent.sealed.nonce,
          body: body ?? sent.sealed.body,
          sig: sig ?? sent.sealed.sig,
          keys: keys ?? sent.sealed.keys,
        );

    String flip(String text) {
      final bytes = fromBase64(text);
      bytes[0] ^= 1;
      return toBase64(bytes);
    }

    test('opens on every device it was sealed for, the sender\'s own included', () async {
      for (final device in [mac, phone, desktop]) {
        expect((await openAs(device)).payload.text, 'GG 🔥');
      }
      expect(sent.sealed.keys.keys.toSet(), {mac.deviceId, phone.deviceId, desktop.deviceId});
    });

    test('says so on a device added later, which has no key for it', () async {
      expect(await code(() => openAs(later)), 'no_key');
    });

    test('is refused when anything is moved or changed', () async {
      expect(await code(() => openAs(desktop, sealed: changed(body: flip(sent.sealed.body)))), 'bad_message');
      expect(await code(() => openAs(desktop, sealed: changed(sig: flip(sent.sealed.sig)))), 'bad_message');
      expect(await code(() => openAs(desktop, sealed: changed(nonce: flip(sent.sealed.nonce)))), 'bad_message');
      expect(await code(() => openAs(desktop, sealed: changed(eph: flip(sent.sealed.eph)))), 'bad_message');
      expect(await code(() => openAs(desktop, sealed: changed(body: 'AAAA'))), 'bad_message');
      // Another conversation, another message ID or another author: the header no longer matches.
      expect(await code(() => openAs(desktop, conversation: messageId)), 'bad_message');
      expect(await code(() => openAs(desktop, message: conversationId)), 'bad_message');
      expect(await code(() => openAs(desktop, author: users['bob'])), 'bad_message');
      // Signed by a device that is not the author's.
      expect(await code(() => openAs(desktop, authors: [listed['desktop']!])), 'bad_message');
      // A key wrapped for one device does not open on another.
      final swapped = {...sent.sealed.keys, desktop.deviceId: sent.sealed.keys[phone.deviceId]!};
      expect(await code(() => openAs(desktop, sealed: changed(keys: swapped))), 'bad_message');
      expect(await code(() => openAs(desktop, sealed: changed(keys: {desktop.deviceId: 'nope'}))), 'bad_message');
    });

    test('opens with its content key alone, as a report does, and only for its author', () async {
      final key = await unwrapKey(
        sent.sealed,
        conversationId: conversationId,
        messageId: messageId,
        senderUserId: users['alice']!,
        me: desktop,
      );
      expect(key, sent.contentKey);
      Future<E2eePayload> withKey(List<int> key, String signKey) => openWithKey(
        sent.sealed,
        conversationId: conversationId,
        messageId: messageId,
        senderUserId: users['alice']!,
        contentKey: key,
        authorSignKey: signKey,
      );
      expect((await withKey(key, listed['mac']!.signKey)).text, 'GG 🔥');
      expect(await code(() => withKey(Uint8List(32), listed['mac']!.signKey)), 'bad_message');
      expect(await code(() => withKey(key, listed['phone']!.signKey)), 'bad_message');
    });

    test('with something that is no payload opens to bad_payload', () async {
      for (final bytes in [
        utf8.encode('not json'),
        utf8.encode('{"v":2,"text":"x"}'),
        utf8.encode('{"v":1,"text":5}'),
      ]) {
        final odd = await seal(
          conversationId: conversationId,
          messageId: messageId,
          senderUserId: users['alice']!,
          sender: mac,
          recipients: [listed['desktop']!],
          payloadBytes: bytes,
        );
        expect(await code(() => openAs(desktop, sealed: odd.sealed)), 'bad_payload');
      }
    });

    test('refuses a recipient key whose X25519 result is all zero', () async {
      final lowOrder = PublicDevice(
        id: '0' * 32,
        signKey: listed['desktop']!.signKey,
        boxKey: toBase64(Uint8List(32)),
        sig: '',
      );
      expect(
        await code(
          () => seal(
            conversationId: conversationId,
            messageId: messageId,
            senderUserId: users['alice']!,
            sender: mac,
            recipients: [lowOrder],
            payload: const E2eePayload(text: 'x'),
          ),
        ),
        'bad_device',
      );
    });
  });

  test('a file opens with its key and nonce, and only as the part it was sealed as', () async {
    final bytes = Uint8List.fromList(List<int>.generate(70000, (i) => i % 251));
    final sealed = await sealFile(bytes, FilePart.file);
    expect(sealed.ciphertext.length, bytes.length + 16);
    expect(await openFile(sealed.ciphertext, FilePart.file, sealed.key, sealed.nonce), bytes);
    expect(await code(() => openFile(sealed.ciphertext, FilePart.poster, sealed.key, sealed.nonce)), 'bad_message');
    final changed = Uint8List.fromList(sealed.ciphertext)..[5] ^= 1;
    expect(await code(() => openFile(changed, FilePart.file, sealed.key, sealed.nonce)), 'bad_message');
  });

  test('base64 is standard with padding, of the length asked', () {
    expect(fromBase64('AAAA', 3), Uint8List(3));
    for (final bad in ['AAA', 'AA-_', 'AAAA', null, 7]) {
      expect(() => fromBase64(bad, bad == 'AAAA' ? 4 : null), throwsA(isA<E2eeError>()), reason: '$bad');
    }
  });

  test('a device goes by its kind, read from its name as AnyTogether reads it', () {
    final cases = {
      'AnyPS5 on Windows': DeviceKind.windows,
      'AnyPS5 on Linux': DeviceKind.linux,
      'AnyPS5 on Mac': DeviceKind.mac,
      'Chrome on Windows': DeviceKind.browser,
      'Safari on iOS': DeviceKind.browser,
      // Older launchers' names: the computer's own.
      'Utku’s MacBook Pro · AnyPS5': DeviceKind.mac,
      'DESKTOP-7F3K2LQ': DeviceKind.windows,
      'LAPTOP-Q1W2E3': DeviceKind.windows,
      'Slick’s iPhone': DeviceKind.iphone,
      'Pixel 8': DeviceKind.android,
      'steamdeck': DeviceKind.linux,
      'gokalp-rig': DeviceKind.device,
      'Machine': DeviceKind.device,
      // The names the server gives other people's devices keep their kind.
      'Windows PC': DeviceKind.windows,
      'Linux PC': DeviceKind.linux,
      'Mac': DeviceKind.mac,
      'iPad': DeviceKind.ipad,
      'Android phone': DeviceKind.android,
      'Web browser': DeviceKind.browser,
      'Device': DeviceKind.device,
    };
    for (final MapEntry(key: name, value: kind) in cases.entries) {
      expect(deviceKindOf(name), kind, reason: name);
    }
    final listed = PublicDevice.fromJson({
      'id': 'a',
      'signKey': 's',
      'boxKey': 'b',
      'sig': 'g',
      'name': 'DESKTOP-7F3K2LQ',
      'createdAt': '2026-11-03T10:00:00.000Z',
      'removedAt': null,
    })!;
    expect(listed.kind, DeviceKind.windows);
    expect(listed.createdAt, DateTime.utc(2026, 11, 3, 10));
  });
}
